defmodule SymphonyElixir.Governor do
  @moduledoc """
  The one owner of everything a service's projects share: worker slots
  (weighted, with caps and research exclusivity, see `Scheduling`), the daily
  budget, the Codex quota, and the drain flag.

  Orchestrators check in every poll (reporting today's spend and their
  waiting work, and getting back the dispatch policy), acquire a slot right
  before a run starts, and release it when the run ends. The Governor only
  ever sends messages back (a wake-up when a slot is kept for a project), so
  no call cycle can form. It monitors each orchestrator and frees the slots
  of one that stops.

  `<state>/drain` holds all new dispatch while it exists, for deploys.

  After a start no slot is granted until every project has checked in (or
  two minutes pass), so the first slots go by weight to the projects with
  waiting work rather than to whichever orchestrator started fastest.

  Runs keep the quota current. While it is stale (no run reported it within
  `quota_stale_ms`) or a quota rule pauses new runs, the Governor reads it
  with `QuotaProbe` every five minutes, so an early reset resumes work
  instead of waiting for the reset time last seen.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Project, Quota, QuotaProbe, Scheduling, Service, Throttle}

  @type policy :: %{
          required(:avoid) => map(),
          required(:paused) => String.t() | nil,
          required(:over_budget) => String.t() | nil,
          required(:slots) => non_neg_integer(),
          required(:research_exclusive) => String.t(),
          required(:draining) => boolean(),
          optional(atom()) => term()
        }

  @spec start_link(Service.t()) :: GenServer.on_start()
  def start_link(%Service{} = service), do: GenServer.start_link(__MODULE__, service, name: __MODULE__)

  @doc "Whether a service Governor runs (false in the single-workflow runtime)."
  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(__MODULE__))

  @doc "Reports a project's spend today and waiting work; returns its dispatch policy."
  @spec checkin(Project.id(), non_neg_integer(), non_neg_integer()) :: policy()
  def checkin(project, spend_micro, demand), do: GenServer.call(__MODULE__, {:checkin, project, spend_micro, demand})

  @doc "Asks for a slot for one run of `item`."
  @spec acquire(Project.id(), String.t(), Throttle.class()) :: :ok | {:wait, String.t()}
  def acquire(project, item, class), do: GenServer.call(__MODULE__, {:acquire, project, item, class})

  @spec release(Project.id(), String.t()) :: :ok
  def release(project, item), do: GenServer.cast(__MODULE__, {:release, project, item})

  @doc "Shares a newer Codex quota snapshot (the quota belongs to the account, not a project)."
  @spec report_quota(Quota.t()) :: :ok
  def report_quota(quota), do: GenServer.cast(__MODULE__, {:quota, quota})

  @spec snapshot() :: map()
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @impl true
  def init(service) do
    schedule_probe(0)
    projects = for project <- Service.projects(service), do: {project.id, project.weight, project.cap, project.research_exclusive}

    {:ok,
     %{
       service: service,
       schedule: Scheduling.new(service.slots, projects),
       spend: %{},
       quota: load_quota(service),
       monitors: %{},
       started_ms: System.monotonic_time(:millisecond),
       warm_up_ms: Application.get_env(:symphony_elixir, :governor_warm_up_ms, 120_000),
       checked_in: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:checkin, project, spend_micro, demand}, {pid, _tag}, state) do
    now = DateTime.utc_now()
    warming_up = warming_up?(state)
    state = state |> monitor(project, pid) |> Map.update!(:spend, &Map.put(&1, project, {Date.utc_today(), spend_micro}))
    state = %{state | schedule: Scheduling.report_demand(state.schedule, project, demand), checked_in: MapSet.put(state.checked_in, project)}

    # The last check-in ends the warm-up: every project polls now and the weights decide.
    if warming_up and not warming_up?(state), do: wake(Map.keys(state.schedule.projects) -- [project])
    {:reply, policy(state, project, now), state}
  end

  def handle_call({:acquire, project, item, class}, {pid, _tag}, state) do
    state = monitor(state, project, pid)

    cond do
      draining?(state) ->
        {:reply, {:wait, "draining for a deploy"}, state}

      warming_up?(state) ->
        {:reply, {:wait, "starting up: waiting for every project to check in"}, state}

      true ->
        grant(state, project, item, class)
    end
  end

  def handle_call(:snapshot, _from, state) do
    now = DateTime.utc_now()

    projects =
      for {id, project} <- Enum.sort(state.schedule.projects) do
        %{id: id, weight: project.weight, cap: project.cap, research_exclusive: project.exclusive, running: map_size(project.held), waiting: project.demand}
      end

    {:reply,
     %{
       slots: state.schedule.slots,
       busy: Scheduling.used(state.schedule),
       projects: projects,
       reservation: state.schedule.reservation && state.schedule.reservation.project,
       draining: draining?(state),
       spend_micro: total_spend(state),
       quota: state.quota,
       throttle: throttle(state, now)
     }, state}
  end

  @impl true
  def handle_cast({:release, project, item}, state) do
    {schedule, wake} = Scheduling.release(state.schedule, project, item)
    wake(wake)
    {:noreply, %{state | schedule: schedule}}
  end

  def handle_cast({:quota, quota}, state) do
    if newer?(quota, state.quota) do
      save_quota(state.service, quota)
      {:noreply, %{state | quota: quota}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.monitors, fn {_project, {_pid, monitor}} -> monitor == ref end) do
      {project, _monitor} ->
        Logger.warning("Orchestrator for #{project} stopped; freeing its slots")
        {schedule, wake} = Scheduling.drop(state.schedule, project)
        wake(wake)
        {:noreply, %{state | schedule: schedule, monitors: Map.delete(state.monitors, project)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(:probe_quota, state) do
    # Paused, no run reports the quota, so a reset shows only through the probe.
    if stale?(state.quota, state.service.throttle.quota_stale_ms) or throttle(state, DateTime.utc_now()).paused do
      Task.start(&probe/0)
    end

    schedule_probe(Application.get_env(:symphony_elixir, :quota_probe_ms, 300_000))
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp probe do
    with %{} = quota <- QuotaProbe.read(), do: report_quota(quota)
  end

  defp schedule_probe(delay_ms), do: Process.send_after(self(), :probe_quota, delay_ms)

  defp stale?(%{observed_at: %DateTime{} = observed_at}, stale_ms), do: DateTime.diff(DateTime.utc_now(), observed_at, :millisecond) > stale_ms
  defp stale?(_quota, _stale_ms), do: true

  defp grant(state, project, item, class) do
    case Scheduling.acquire(state.schedule, project, item, class, System.monotonic_time(:millisecond)) do
      {:ok, schedule} ->
        {:reply, :ok, %{state | schedule: schedule}}

      {:wait, reason, schedule, wake} ->
        wake(wake)
        {:reply, {:wait, reason}, %{state | schedule: schedule}}
    end
  end

  defp policy(state, project, now) do
    draining = draining?(state)
    free = Scheduling.free_for(state.schedule, project, System.monotonic_time(:millisecond))

    state
    |> throttle(now)
    |> Map.merge(%{
      slots: if(draining or warming_up?(state), do: 0, else: free),
      research_exclusive: state.schedule.projects[project].exclusive,
      draining: draining
    })
  end

  defp throttle(state, now), do: Throttle.evaluate(state.service.throttle, state.quota, total_spend(state), now)

  defp total_spend(state) do
    today = Date.utc_today()
    for {_project, {^today, micro}} <- state.spend, reduce: 0, do: (sum -> sum + micro)
  end

  defp monitor(state, project, pid) do
    case state.monitors do
      %{^project => {^pid, _ref}} ->
        state

      monitors ->
        with {_old, ref} <- monitors[project], do: Process.demonitor(ref, [:flush])
        %{state | monitors: Map.put(monitors, project, {pid, Process.monitor(pid)})}
    end
  end

  defp wake(projects) do
    for project <- projects, pid = GenServer.whereis(Project.via(project, :orchestrator)), is_pid(pid), do: send(pid, :governor_wake)
    :ok
  end

  defp draining?(state), do: File.exists?(Path.join(Service.state_root(state.service), "drain"))

  defp warming_up?(state) do
    MapSet.size(state.checked_in) < map_size(state.schedule.projects) and
      System.monotonic_time(:millisecond) - state.started_ms < state.warm_up_ms
  end

  defp newer?(%{observed_at: %DateTime{} = new}, %{observed_at: %DateTime{} = old}), do: DateTime.compare(new, old) == :gt
  defp newer?(%{observed_at: %DateTime{}}, _old), do: true
  defp newer?(_new, _old), do: false

  defp quota_path(service), do: Path.join(Service.state_root(service), "quota.term")

  defp load_quota(service) do
    case File.read(quota_path(service)) do
      {:ok, binary} -> :erlang.binary_to_term(binary, [:safe])
      {:error, _reason} -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp save_quota(service, quota) do
    path = quota_path(service)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, :erlang.term_to_binary(quota)) do
      :ok
    else
      {:error, reason} -> Logger.warning("Could not save the Codex quota to #{path}: #{inspect(reason)}")
    end
  end
end
