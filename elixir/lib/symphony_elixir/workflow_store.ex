defmodule SymphonyElixir.WorkflowStore do
  @moduledoc """
  Caches the last known good workflow and reloads it when `WORKFLOW.md` changes.

  The single-workflow runtime has one store under this module's name that
  follows `Workflow.workflow_file_path/0`. A service project has its own store
  (`Project.via(id, :workflow_store)`) with a fixed path and service defaults
  merged under its front matter; calls resolve the current project's store.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{Project, Workflow}

  @poll_interval_ms 1_000

  defmodule State do
    @moduledoc false

    # `fixed_path` and `defaults` are set for service projects; the legacy
    # store follows `Workflow.workflow_file_path/0` and has no defaults.
    defstruct [:path, :stamp, :workflow, :settings, :fixed_path, defaults: %{}]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec current() :: {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def current do
    case server() do
      {:ok, server} -> GenServer.call(server, :current)
      :legacy_file -> Workflow.load()
      error -> error
    end
  end

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case server() do
      {:ok, server} -> GenServer.call(server, :settings)
      :legacy_file -> with {:ok, %State{} = state} <- load_legacy_file(), do: {:ok, state.settings}
      error -> error
    end
  end

  @spec force_reload() :: :ok | {:error, term()}
  def force_reload do
    case server() do
      {:ok, server} -> GenServer.call(server, :force_reload)
      :legacy_file -> with {:ok, _state} <- load_legacy_file(), do: :ok
      error -> error
    end
  end

  defp load_legacy_file, do: load_state(Workflow.workflow_file_path(), %{})

  # Without a running store, the single-workflow runtime reads the file
  # directly; a project's store must be running.
  defp server do
    case {Project.current(), GenServer.whereis(Project.name(:workflow_store, __MODULE__))} do
      {_project, pid} when is_pid(pid) -> {:ok, pid}
      {nil, nil} -> :legacy_file
      {project, nil} -> {:error, {:project_not_running, project}}
    end
  end

  @impl true
  def init(opts) do
    :ok = Project.put(Keyword.get(opts, :project))
    fixed_path = Keyword.get(opts, :path)
    defaults = Keyword.get(opts, :defaults, %{})

    case load_state(fixed_path || Workflow.workflow_file_path(), defaults) do
      {:ok, state} ->
        schedule_poll()
        {:ok, %{state | fixed_path: fixed_path}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:current, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}
    end
  end

  def handle_call(:force_reload, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:settings, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.settings}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.settings}, new_state}
    end
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    schedule_poll()

    case reload_state(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp reload_state(%State{} = state) do
    path = state.fixed_path || Workflow.workflow_file_path()

    if path != state.path do
      reload_path(path, state)
    else
      reload_current_path(path, state)
    end
  end

  defp reload_path(path, state) do
    case load_state(path, state.defaults) do
      {:ok, new_state} ->
        {:ok, %{new_state | fixed_path: state.fixed_path}}

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp reload_current_path(path, state) do
    case current_stamp(path, state.workflow.prompt_paths) do
      {:ok, stamp} when stamp == state.stamp ->
        {:ok, state}

      {:ok, _stamp} ->
        reload_path(path, state)

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp load_state(path, defaults) do
    with {:ok, workflow} <- Workflow.load(path, defaults),
         {:ok, settings} <- Schema.parse(workflow.config),
         :ok <- Config.validate_settings(settings),
         {:ok, stamp} <- current_stamp(path, workflow.prompt_paths) do
      {:ok, %State{path: path, stamp: stamp, workflow: workflow, settings: settings, defaults: defaults}}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Prompt files referenced from WORKFLOW.md are part of the stamp so edits to
  # them hot-reload like WORKFLOW.md itself.
  defp current_stamp(path, prompt_paths) when is_binary(path) do
    Enum.reduce_while([path | prompt_paths], {:ok, []}, fn file, {:ok, acc} ->
      case file_stamp(file) do
        {:ok, stamp} -> {:cont, {:ok, [stamp | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp file_stamp(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, content} <- File.read(path) do
      {:ok, {stat.mtime, stat.size, :erlang.phash2(content)}}
    end
  end

  defp log_reload_error(path, reason) do
    Logger.error("Failed to reload workflow path=#{path} reason=#{inspect(reason)}; keeping last known good configuration")
  end
end
