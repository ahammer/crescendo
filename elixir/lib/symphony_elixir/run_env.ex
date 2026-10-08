defmodule SymphonyElixir.RunEnv do
  @moduledoc """
  The environment every command of a run inherits, agent and workspace hooks
  alike: the project and work item it belongs to, the selected route label,
  and where the service's read-only state lives, so workstation tooling (the
  machine lease, reconcilers) can attribute work across projects.

  `CRESCENDO_WORK_ITEM` is qualified by project (`metalrain/GH-12`) under a
  service, and `CRESCENDO_LABEL_PREFIX` is the project's `labels.prefix`, so
  repository tooling follows a label migration. The `SYMPHONY_*` names stay
  for tools that predate the service.
  """

  alias SymphonyElixir.{Config, HttpServer, Project}

  @spec vars(String.t() | nil, String.t() | nil, String.t() | nil) :: [{String.t(), String.t()}]
  def vars(work_item, route_label \\ nil, run_id \\ nil) do
    project = Project.current()
    state_url = state_url(HttpServer.bound_port())

    [
      pair("SYMPHONY_SELECTED_MODEL_LABEL", route_label),
      pair("SYMPHONY_WORK_ITEM", work_item),
      pair("CRESCENDO_RUN_ID", run_id),
      pair("CRESCENDO_WORK_ITEM", qualified(project, work_item)),
      pair("CRESCENDO_PROJECT", project),
      pair("CRESCENDO_LABEL_PREFIX", label_prefix()),
      pair("CRESCENDO_STATE_URL", state_url),
      pair("SYMPHONY_STATE_URL", state_url)
    ]
    |> Enum.filter(& &1)
  end

  defp pair(_key, nil), do: nil
  defp pair(key, value), do: {key, value}
  defp qualified(_project, nil), do: nil
  defp qualified(nil, item), do: item
  defp qualified(project, item), do: "#{project}/#{item}"

  defp label_prefix do
    case Config.settings() do
      {:ok, settings} -> settings.labels.prefix
      {:error, _reason} -> nil
    end
  end

  defp state_url(port) when is_integer(port) and port > 0, do: "http://127.0.0.1:#{port}/api/v1/state"
  defp state_url(_port), do: nil
end
