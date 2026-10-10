defmodule SymphonyElixir.DeployDrain do
  @moduledoc "Credential-free managed drain observation and reconciliation through the deployment policy."

  @policy_path Path.expand("../../../ops/bin/deploy-state.py", __DIR__)
  @external_resource @policy_path
  # An escript's priv path is inside its archive and cannot be opened by Python.
  @policy File.read!(@policy_path)

  @spec observe(String.t(), boolean()) :: map() | nil
  def observe(root, reconcile \\ false) do
    if File.exists?(Path.join(root, "deploy-drain.json")) do
      mode = if reconcile, do: "reconcile", else: "observe"

      case System.cmd("python3", ["-c", @policy, mode, root], stderr_to_stdout: true) do
        {output, 0} -> decode(output)
        _error -> unknown()
      end
    end
  rescue
    _error in ErlangError -> unknown()
  end

  @spec manual(String.t()) :: map()
  def manual(root) do
    with {:ok, value} <- File.read(Path.join(root, "drain")),
         {:ok, %{"kind" => "manual", "started_at" => started}} when is_binary(started) <- Jason.decode(value),
         {:ok, _time, 0} <- DateTime.from_iso8601(started) do
      %{"kind" => "manual", "phase" => "held", "started_at" => started}
    else
      _unknown -> %{"kind" => "legacy_unknown", "phase" => "held"}
    end
  end

  defp decode(output) do
    case Jason.decode(output) do
      {:ok, nil} -> nil
      {:ok, %{"kind" => "managed"} = owner} -> Map.take(owner, ["kind", "phase", "owner_status", "started_at", "release"])
      _error -> unknown()
    end
  end

  defp unknown, do: %{"kind" => "managed", "phase" => "unknown", "owner_status" => "unknown"}
end
