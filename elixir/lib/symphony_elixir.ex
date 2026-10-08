defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the agent runtime in the current BEAM node.
  """
  @spec start_link() :: Supervisor.on_start()
  def start_link do
    SymphonyElixir.AgentRuntimeSupervisor.start_link([])
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @dialyzer {:nowarn_function, start_burrito_cli: 0}

  @impl true
  def start(_type, _args) do
    if burrito_runtime?() do
      start_burrito_cli()
    else
      start_runtime()
    end
  end

  @doc false
  @spec start_runtime() :: Supervisor.on_start()
  def start_runtime do
    :ok = SymphonyElixir.LogFile.configure()
    :ok = SymphonyElixir.SourceRevision.initialize()

    shared = [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry},
      SymphonyElixir.GitHub.ETagCache
    ]

    with {:ok, children} <- runtime_children(Application.get_env(:symphony_elixir, :service_config_path)) do
      Supervisor.start_link(shared ++ children, strategy: :one_for_one, name: SymphonyElixir.Supervisor)
    end
  end

  # A single WORKFLOW.md runs one unnamed project under the legacy names; a
  # service file runs every configured project side by side.
  defp runtime_children(nil) do
    {:ok,
     [
       SymphonyElixir.WorkflowStore,
       SymphonyElixir.AgentRuntimeSupervisor,
       SymphonyElixir.HttpServer,
       SymphonyElixir.StatusDashboard
     ]}
  end

  defp runtime_children(path) do
    case SymphonyElixir.Service.load(path) do
      {:ok, service} ->
        :ok = SymphonyElixir.Service.put_current(service)
        port = Application.get_env(:symphony_elixir, :server_port_override) || service.port

        children = [{SymphonyElixir.Governor, service}, {SymphonyElixir.Projects, service}]

        {:ok,
         [
           %{
             id: :service_runtime,
             type: :supervisor,
             start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]}
           },
           {SymphonyElixir.HttpServer, host: service.host, port: port}
         ]}

      {:error, message} ->
        {:error, {:invalid_service_config, message}}
    end
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end

  defp start_burrito_cli do
    Task.start_link(fn ->
      SymphonyElixir.CLI.main(
        plain_arguments(),
        &start_runtime/0
      )
    end)
  end

  defp burrito_runtime?, do: System.get_env("__BURRITO") == "1"

  defp plain_arguments, do: Enum.map(:init.get_plain_arguments(), &to_string/1)
end
