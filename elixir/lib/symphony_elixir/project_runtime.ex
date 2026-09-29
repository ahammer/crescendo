defmodule SymphonyElixir.ProjectRuntime do
  @moduledoc """
  One service project: its workflow store, agent task supervisor,
  orchestrator and repository autopilot mirror, all registered under the
  project's id. A crashed store takes
  the processes after it down with it (`rest_for_one`), so the orchestrator
  never runs on a missing configuration.
  """

  use Supervisor

  alias SymphonyElixir.{Artifacts, Orchestrator, Project, RepoAutopilot, Service, WorkflowStore}

  @spec start_link({Service.t(), Service.Project.t()}) :: Supervisor.on_start()
  def start_link({%Service{} = service, %Service.Project{} = project}) do
    Supervisor.start_link(__MODULE__, {service, project}, name: Project.via(project.id, :runtime))
  end

  @spec child_spec({Service.t(), Service.Project.t()}) :: Supervisor.child_spec()
  def child_spec({_service, %Service.Project{id: id}} = args) do
    %{id: {__MODULE__, id}, start: {__MODULE__, :start_link, [args]}, type: :supervisor}
  end

  @impl true
  def init({service, project}) do
    id = project.id
    tasks = Project.via(id, :task_supervisor)
    state_dir = Path.join([Service.state_root(service), "projects", id])
    overlay = RepoAutopilot.mirror_dir(state_dir)

    children = [
      {WorkflowStore, name: Project.via(id, :workflow_store), project: id, path: project.workflow, defaults: project.defaults, overlay: overlay},
      Supervisor.child_spec({Task.Supervisor, name: tasks}, id: :task_supervisor),
      {Orchestrator,
       name: Project.via(id, :orchestrator),
       project: id,
       task_supervisor: tasks,
       operations_path: Path.join(state_dir, "operations.dets"),
       operations_table: String.to_atom("symphony_operations_" <> id),
       artifacts_root: Artifacts.root()},
      # Last, so a failing repository read never restarts the orchestrator.
      {RepoAutopilot, name: Project.via(id, :repo_autopilot), project: id, dir: overlay}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
