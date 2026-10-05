defmodule SymphonyElixir.Startup do
  @moduledoc "Startup admission policy; no model work has been admitted at this boundary."

  alias SymphonyElixir.Config

  @spec fingerprint() :: binary()
  def fingerprint do
    Config.settings!()
    |> Map.take([:hooks, :workspace, :worker, :codex])
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  @spec diagnostic(atom(), term()) :: map()
  def diagnostic(phase, {:workspace_hook_failed, hook, status, output}) do
    %{
      reason: :workspace_hook_failed,
      phase: phase,
      hook: hook,
      status: status,
      context: sanitize(output),
      empty_output: output == ""
    }
  end

  def diagnostic(phase, {:workspace_hook_timeout, hook, timeout}) do
    %{
      reason: :workspace_hook_timeout,
      phase: phase,
      hook: hook,
      status: "timeout",
      timeout_ms: timeout,
      context: "No output captured",
      empty_output: true
    }
  end

  def diagnostic(phase, {:workspace_prepare_failed, _host, status, output}) do
    %{
      reason: :workspace_prepare_failed,
      phase: phase,
      hook: nil,
      status: status,
      context: sanitize(output),
      empty_output: output == ""
    }
  end

  def diagnostic(phase, {:port_exit, status}) do
    %{phase: phase, hook: nil, status: status, context: "App-server exited before admission"}
  end

  def diagnostic(phase, :response_timeout) do
    %{phase: phase, hook: nil, status: "timeout", context: "App-server startup response timed out"}
  end

  def diagnostic(phase, reason) do
    %{phase: phase, hook: nil, status: "error", context: sanitize(inspect(reason, limit: 20, printable_limit: 2_048))}
  end

  @spec sanitize(String.t()) :: String.t()
  def sanitize(text) do
    text
    |> String.replace_invalid()
    |> String.replace(~r/\e\[[0-?]*[ -\/]*[@-~]/, "")
    |> String.replace(~r/[\x00-\x08\x0b-\x1f\x7f]/, "")
    |> String.replace(~r/(?:Bearer\s+|(?:token|password|secret|api[_-]?key)[\"\']?\s*[=:]\s*[\"\']?)[^\s]+/i, "[REDACTED]")
    |> String.replace(~r/\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+)\b/, "[REDACTED]")
    |> String.replace(~r{(https?://)[^/\s:@]+:[^/\s@]+@}, "\\1[REDACTED]@")
    |> String.slice(0, 2_048)
  end

  @spec failed(map() | nil, map(), map(), integer()) :: map()
  def failed(previous, identity, diagnostic, delivery_attempt) do
    fingerprint = fingerprint()
    count = if previous && previous.fingerprint == fingerprint, do: min(previous.count + 1, 3), else: 1
    delay = if count >= 3, do: 1_800_000, else: 10_000 * count

    Map.merge(identity, %{
      count: count,
      fingerprint: fingerprint,
      diagnostic: diagnostic,
      delivery_attempt: delivery_attempt,
      due_at_ms: System.system_time(:millisecond) + delay,
      blocked_at: DateTime.utc_now(),
      error: "Startup #{count}/3: #{inspect(diagnostic)}; retry in #{div(delay, 1_000)}s"
    })
  end

  @spec ready?(map() | nil) :: boolean()
  def ready?(nil), do: true
  def ready?(entry), do: entry.fingerprint != fingerprint() or entry.due_at_ms <= System.system_time(:millisecond)
end
