defmodule SymphonyElixir.Projects do
  @moduledoc """
  Starts every enabled project of the service. A project whose workflow
  cannot load is reported and left out, so one broken project never keeps
  the others (or the dashboard) from running.
  """

  use Supervisor
  require Logger

  alias SymphonyElixir.{ProjectRuntime, Service}

  @failures {__MODULE__, :failures}

  @spec start_link(Service.t()) :: Supervisor.on_start()
  def start_link(%Service{} = service), do: Supervisor.start_link(__MODULE__, service, name: __MODULE__)

  @impl true
  def init(service) do
    :persistent_term.put(@failures, %{})

    children = [
      {DynamicSupervisor, name: SymphonyElixir.ProjectSupervisor, strategy: :one_for_one},
      Supervisor.child_spec({Task, fn -> start_projects(service) end}, restart: :temporary)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Projects that failed to start, by id, with the reason."
  @spec failures() :: %{optional(String.t()) => String.t()}
  def failures, do: :persistent_term.get(@failures, %{})

  @doc false
  @spec start_projects(Service.t()) :: :ok
  def start_projects(service) do
    failures =
      service
      |> Service.projects()
      |> Enum.reduce(%{}, fn project, failures ->
        case DynamicSupervisor.start_child(SymphonyElixir.ProjectSupervisor, {ProjectRuntime, {service, project}}) do
          {:ok, _pid} ->
            failures

          {:error, reason} ->
            Logger.error("Project #{project.id} failed to start from #{project.workflow}: #{inspect(reason)}")
            Map.put(failures, project.id, inspect(reason))
        end
      end)

    :persistent_term.put(@failures, failures)
  end
end
