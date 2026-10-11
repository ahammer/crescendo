defmodule SymphonyElixir.QuietContinuation do
  @moduledoc "One prepared quiet acceptance continuation per canonical logical attempt."

  alias SymphonyElixir.{Governor, ProcessGroup, Service}

  @name "defer_quiet_acceptance"
  @fields ~w(reason source_sha pull_request evidence unmet_acceptance)

  @spec configured?() :: boolean()
  def configured?, do: match?(%{quiet_window: %Service.QuietWindow{}}, Service.current())

  @spec available?(map()) :: boolean()
  def available?(context) do
    context[:kind] == :issue and is_pid(context[:recipient]) and is_binary(context[:run_id]) and
      is_nil(context[:worker_host]) and configured?()
  end

  @spec tool_spec() :: map()
  def tool_spec do
    %{
      "name" => @name,
      "description" =>
        "Yield prepared delivery until the existing quiet acceptance window, once per logical attempt. Commit evidence first; retain the same PR and list every unmet gate, including product failures. On success, update the workpad and end the turn without a blocked label.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "reason" => %{"type" => "string"},
          "source_sha" => %{"type" => "string"},
          "pull_request" => %{"type" => "string"},
          "evidence" => %{"type" => "array", "items" => %{"type" => "string"}, "minItems" => 1, "maxItems" => 12},
          "unmet_acceptance" => %{"type" => "array", "items" => %{"type" => "string"}, "minItems" => 1, "maxItems" => 12}
        },
        "required" => @fields
      }
    }
  end

  @spec execute(term(), map()) :: map()
  def execute(args, context) do
    result =
      with true <- available?(context),
           {:ok, prepared} <- prepare(args, context.workspace),
           do: GenServer.call(context.recipient, {:defer_quiet, context.issue_id, context.run_id, prepared})

    %{"success" => match?({:ok, _}, result), "output" => inspect(result)}
  catch
    :exit, _ -> %{"success" => false, "output" => "quiet continuation owner unavailable"}
  end

  @spec prepare(term(), Path.t()) :: {:ok, map()} | {:error, atom()}
  def prepare(args, workspace) when is_map(args) do
    with true <- Enum.sort(Map.keys(args)) == Enum.sort(@fields),
         true <- text?(args["reason"]) and text?(args["pull_request"]),
         true <- is_binary(args["source_sha"]) and Regex.match?(~r/\A[0-9a-f]{40,64}\z/, args["source_sha"]),
         true <- texts?(args["evidence"]) and texts?(args["unmet_acceptance"]),
         sha when is_binary(sha) <- source(workspace),
         true <- sha == args["source_sha"],
         evidence <- Enum.map(args["evidence"], &%{path: &1, sha256: digest(workspace, sha, &1)}),
         true <- Enum.all?(evidence, &is_binary(&1.sha256)) do
      prepared = %{
        reason: args["reason"],
        source_sha: sha,
        pull_request: args["pull_request"],
        evidence: evidence,
        unmet_acceptance: args["unmet_acceptance"]
      }

      {:ok, prepared}
    else
      _ -> {:error, :invalid_prepared_evidence}
    end
  end

  def prepare(_args, _workspace), do: {:error, :invalid_prepared_evidence}

  @spec revalidate(map(), Path.t()) :: map()
  def revalidate(prepared, workspace) do
    sha = source(workspace)
    evidence_match = Enum.all?(prepared.evidence, &(is_binary(sha) and digest(workspace, sha, &1.path) == &1.sha256))
    Map.merge(prepared, %{current_source_sha: sha, evidence_applicable: sha == prepared.source_sha and evidence_match})
  end

  @spec window() :: map()
  def window do
    if Governor.running?(), do: Governor.quiet_schedule(), else: %{}
  end

  defp texts?(values), do: is_list(values) and length(values) in 1..12 and Enum.all?(values, &text?/1)

  defp text?(value) do
    is_binary(value) and byte_size(value) in 1..2_048 and String.trim(value) != "" and not String.contains?(value, <<0>>)
  end

  defp source(workspace) do
    with "" <- git(workspace, ["diff", "--name-only", "HEAD", "--"]),
         sha when is_binary(sha) <- git(workspace, ["rev-parse", "--verify", "HEAD^{commit}"]) do
      String.trim(sha)
    else
      _ -> nil
    end
  end

  defp digest(workspace, sha, path) do
    if Path.type(path) == :relative and not Enum.any?(Path.split(path), &(&1 in ["..", ".git"])) and
         git(workspace, ["cat-file", "-t", "#{sha}:#{path}"]) == "blob\n" do
      case git(workspace, ["show", "#{sha}:#{path}"]) do
        nil -> nil
        content -> :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      end
    end
  end

  defp git(workspace, args) do
    port = Port.open({:spawn_executable, System.find_executable("git")}, [:binary, :exit_status, :stderr_to_stdout, {:cd, workspace}, {:args, ["--no-replace-objects" | args]}])

    case ProcessGroup.run(port, 5_000, output_limit: 131_072) do
      {:ok, {output, 0}} -> output
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
