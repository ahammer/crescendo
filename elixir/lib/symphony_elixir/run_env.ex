defmodule SymphonyElixir.RunEnv do
  @moduledoc """
  The environment every command of a run inherits, agent and workspace hooks
  alike: the project and work item it belongs to, the selected route label,
  and where the service's read-only state lives, so workstation tooling (the
  machine lease, reconcilers) can attribute work across projects.

  `CRESCENDO_WORK_ITEM` is qualified by project (`metalrain/GH-12`) under a
  service. The `SYMPHONY_*` names stay for tools that predate the service.
  """

  alias SymphonyElixir.{HttpServer, Project}

  @spec vars(String.t() | nil, String.t() | nil) :: [{String.t(), String.t()}]
  def vars(work_item, route_label \\ nil) do
    project = Project.current()
    state_url = state_url(HttpServer.bound_port())

    [
      route_label && {"SYMPHONY_SELECTED_MODEL_LABEL", route_label},
      work_item && {"SYMPHONY_WORK_ITEM", work_item},
      work_item && {"CRESCENDO_WORK_ITEM", if(project, do: "#{project}/#{work_item}", else: work_item)},
      project && {"CRESCENDO_PROJECT", project},
      state_url && {"CRESCENDO_STATE_URL", state_url},
      state_url && {"SYMPHONY_STATE_URL", state_url}
    ]
    |> Enum.filter(& &1)
  end

  defp state_url(port) when is_integer(port) and port > 0, do: "http://127.0.0.1:#{port}/api/v1/state"
  defp state_url(_port), do: nil
end
