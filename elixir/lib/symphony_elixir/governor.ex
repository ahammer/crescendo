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

  alias SymphonyElixir.{Helpers, Project, Quota, QuotaProbe, Scheduling, Service, Throttle}

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
  @spec checkin(Project.id(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: policy()
  def checkin(project, spend_micro, demand, quiet_demand \\ 0), do: GenServer.call(__MODULE__, {:checkin, project, spend_micro, demand, quiet_demand})

  @doc "Asks for a slot for one run of `item`."
  @spec acquire(Project.id(), String.t(), Throttle.class(), keyword()) :: :ok | {:wait, String.t()}
  def acquire(project, item, class, opts \\ []), do: GenServer.call(__MODULE__, {:acquire, project, item, class, opts})

  @spec helper_start(map(), map()) :: {:ok, map()} | {:error, term()}
  def helper_start(context, args) do
    with {:ok, prepared} <- Helpers.prepare(context, args),
         do: GenServer.call(__MODULE__, {:helper_start, prepared})
  end

  @spec helper_status(String.t()) :: {:ok, map()} | {:error, term()}
  def helper_status(id), do: GenServer.call(__MODULE__, {:helper_status, id})

  @spec helper_cancel(String.t()) :: {:ok, map()} | {:error, term()}
  def helper_cancel(id), do: GenServer.call(__MODULE__, {:helper_cancel, id})

  @spec cancel_helpers(pid()) :: :ok
  def cancel_helpers(owner), do: GenServer.cast(__MODULE__, {:cancel_helpers, owner})

  @spec release(Project.id(), String.t()) :: :ok
  def release(project, item), do: GenServer.cast(__MODULE__, {:release, project, item})

  @doc "Shares a newer Codex quota snapshot (the quota belongs to the account, not a project)."
  @spec report_quota(Quota.t()) :: :ok
  def report_quota(quota), do: GenServer.cast(__MODULE__, {:quota, quota})

  @doc "Whether a service drain is active at a completed-turn boundary."
  @spec draining?() :: boolean()
  def draining?, do: running?() and GenServer.call(__MODULE__, :draining)

  @spec snapshot() :: map()
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "A credential-free service capacity observation; unavailable Governors remain unknown."
  @spec observe() :: map() | nil
  def observe do
    snapshot()
    |> Map.take([:observed_at, :slots, :busy, :draining, :research_hold, :helpers])
    |> Map.put(:source, "governor")
    |> Map.put(:scope, "service")
  catch
    :exit, _reason -> nil
  end

  @impl true
  def init(service) do
    schedule_probe(0)
    Process.send_after(self(), :helper_heartbeat, 30_000)
    projects = for project <- Service.projects(service), do: {project.id, project.weight, project.cap, project.research_exclusive}

    {:ok,
     %{
       service: service,
       schedule: Scheduling.new(service.slots, projects),
       spend: %{},
       quota: load_quota(service),
       quota_epoch: load_epoch(service),
       monitors: %{},
       helpers: %{},
       quiet_demand: %{},
       quiet_runs: MapSet.new(),
       quiet_schedule: Service.QuietWindow.observe(service.quiet_window, governor_now()),
       started_ms: System.monotonic_time(:millisecond),
       warm_up_ms: Application.get_env(:symphony_elixir, :governor_warm_up_ms, 120_000),
       checked_in: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:checkin, project, spend_micro, demand, quiet_demand}, {pid, _tag}, state) do
    now = DateTime.utc_now()
    warming_up = warming_up?(state)
    state = state |> monitor(project, pid) |> Map.update!(:spend, &Map.put(&1, project, {Date.utc_today(), spend_micro}))

    state = %{
      state
      | schedule: Scheduling.report_demand(state.schedule, project, demand),
        checked_in: MapSet.put(state.checked_in, project),
        quiet_demand: Map.put(state.quiet_demand, project, quiet_demand)
    }

    # The last check-in ends the warm-up: every project polls now and the weights decide.
    if warming_up and not warming_up?(state), do: wake(Map.keys(state.schedule.projects) -- [project])
    {:reply, policy(state, project, now), state}
  end

  def handle_call({:acquire, project, item, class, opts}, {pid, _tag}, state) do
    state = monitor(state, project, pid)

    cond do
      draining?(state) ->
        {:reply, {:wait, "draining for a deploy"}, state}

      warming_up?(state) ->
        {:reply, {:wait, "starting up: waiting for every project to check in"}, state}

      true ->
        acquire_ready(state, project, item, class, opts)
    end
  end

  def handle_call({:helper_start, %{context: context} = prepared}, {owner, _tag}, state) do
    cond do
      state.service.helpers.slots == 0 -> {:reply, {:error, :helpers_disabled}, state}
      not valid_helper_owner?(state, context) -> {:reply, {:error, :parent_not_running}, state}
      helpers_paused?(state) -> {:reply, {:error, :service_draining_or_starting}, state}
      research_reserved?(state) -> {:reply, {:error, :quiet_research_reserved}, state}
      helper_busy(state) >= state.service.helpers.slots -> {:reply, {:error, :helper_capacity}, state}
      helpers_throttled?(state) -> {:reply, {:error, :helper_throttled}, state}
      true -> start_helper(state, owner, prepared)
    end
  end

  def handle_call({action, id}, {owner, _tag}, state) when action in [:helper_status, :helper_cancel] do
    case state.helpers[id] do
      %{owner: ^owner} = helper ->
        helper = if action == :helper_cancel, do: cancel_helper(helper), else: helper
        {:reply, {:ok, helper_view(helper)}, put_in(state.helpers[id], helper)}

      _ ->
        {:reply, {:error, :helper_not_found}, state}
    end
  end

  def handle_call(:draining, _from, state), do: {:reply, draining?(state), state}

  def handle_call(:snapshot, _from, state) do
    now = DateTime.utc_now()

    projects =
      for {id, project} <- Enum.sort(state.schedule.projects) do
        %{id: id, weight: project.weight, cap: project.cap, research_exclusive: project.exclusive, running: map_size(project.held), waiting: project.demand}
      end

    {:reply,
     %{
       observed_at: DateTime.to_iso8601(now),
       slots: state.schedule.slots,
       busy: Scheduling.used(state.schedule),
       projects: projects,
       reservation: state.schedule.reservation && state.schedule.reservation.project,
       research_hold: Scheduling.research_hold(state.schedule, System.monotonic_time(:millisecond)),
       draining: draining?(state),
       spend_micro: total_spend(state),
       quota: state.quota,
       pacing: Quota.pacing(state.quota, state.quota_epoch, now),
       quiet_window: quiet_window(state),
       throttle: throttle(state, now),
       helpers: %{slots: state.service.helpers.slots, busy: helper_busy(state), model: state.service.helpers.model, effort: state.service.helpers.effort}
     }, state}
  end

  @impl true
  def handle_cast({:cancel_helpers, owner}, state) do
    helpers = Map.new(state.helpers, fn {id, helper} -> {id, if(helper.owner == owner, do: cancel_helper(helper), else: helper)} end)
    {:noreply, %{state | helpers: helpers}}
  end

  def handle_cast({:release, project, item}, state) do
    {schedule, wake} = Scheduling.release(state.schedule, project, item)
    wake(wake)
    {:noreply, %{state | schedule: schedule, quiet_runs: MapSet.delete(state.quiet_runs, {project, item})}}
  end

  def handle_cast({:quota, quota}, state) do
    if newer?(quota, state.quota) do
      epoch = Quota.epoch(state.quota_epoch, state.quota, quota)
      save_quota(state.service, quota)
      save_epoch(state.service, epoch)
      {:noreply, %{state | quota: quota, quota_epoch: epoch}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Enum.find(state.helpers, fn {_id, helper} -> helper.ref == ref end) do
      {id, helper} ->
        Process.cancel_timer(helper.timer)
        Process.demonitor(helper.owner_ref, [:flush])
        {status, result} = helper_outcome(helper, reason)
        update = %{event: :helper_finished, status: status, reason: result, timestamp: DateTime.utc_now()}
        notify_helper(helper, update)
        stored = if status == "completed", do: {:ok, result}, else: {:error, result}
        helper = %{helper | status: status, result: stored, pid: nil}
        wake(Map.keys(state.schedule.projects))
        {:noreply, put_in(state.helpers[id], helper)}

      nil ->
        helpers = Map.new(state.helpers, fn {id, helper} -> {id, if(helper.owner == pid, do: cancel_helper(helper), else: helper)} end)
        orchestrator_down(ref, %{state | helpers: helpers})
    end
  end

  def handle_info({:helper_result, id, result}, state) do
    result =
      case result do
        {:error, reason} -> {:error, Helpers.error_text(reason)}
        other -> other
      end

    case state.helpers[id] do
      %{pid: pid} = helper when is_pid(pid) -> {:noreply, put_in(state.helpers[id], %{helper | result: result})}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:helper_update, details, update}, state) do
    case state.helpers[details.run_id] do
      %{pid: pid, context: %{recipient: recipient}} when is_pid(pid) ->
        send(recipient, {:helper_update, details, update})

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(:helper_heartbeat, state) do
    state = refresh_quiet_schedule(state)

    for {_id, %{pid: pid} = helper} <- state.helpers, is_pid(pid) do
      notify_helper(helper, %{event: :helper_heartbeat, timestamp: DateTime.utc_now()})
    end

    Process.send_after(self(), :helper_heartbeat, 30_000)
    {:noreply, state}
  end

  def handle_info({:helper_timeout, id}, state) do
    case state.helpers[id] do
      %{pid: pid} = helper when is_pid(pid) ->
        helper = cancel_helper(%{helper | result: {:error, :helper_timeout}})
        {:noreply, put_in(state.helpers[id], helper)}

      _ ->
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

  defp orchestrator_down(ref, state) do
    case Enum.find(state.monitors, fn {_project, {_pid, monitor}} -> monitor == ref end) do
      {project, _monitor} ->
        Logger.warning("Orchestrator for #{project} stopped; freeing its slots")
        {schedule, wake} = Scheduling.drop(state.schedule, project)
        wake(wake)
        quiet_runs = MapSet.reject(state.quiet_runs, fn {id, _item} -> id == project end)
        monitors = Map.delete(state.monitors, project)
        quiet_demand = Map.delete(state.quiet_demand, project)
        state = %{state | schedule: schedule, monitors: monitors, quiet_demand: quiet_demand, quiet_runs: quiet_runs}
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  defp probe do
    with %{} = quota <- QuotaProbe.read(), do: report_quota(quota)
  end

  defp load_epoch(service) do
    with {:ok, bytes} <- File.read(Path.join(Service.state_root(service), "quota-epoch.term")),
         decoded = :erlang.binary_to_term(bytes, [:safe]),
         %{started_at: %DateTime{}, initial_used_percent: used, origin: origin} = epoch <- decoded,
         true <- is_number(used) and origin in ["observed_reset", "first_observation"] do
      epoch
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp save_epoch(service, epoch) do
    root = Service.state_root(service)
    with :ok <- File.mkdir_p(root), do: File.write(Path.join(root, "quota-epoch.term"), :erlang.term_to_binary(epoch))
  end

  defp schedule_probe(delay_ms), do: Process.send_after(self(), :probe_quota, delay_ms)

  defp stale?(%{observed_at: %DateTime{} = observed_at}, stale_ms), do: DateTime.diff(DateTime.utc_now(), observed_at, :millisecond) > stale_ms
  defp stale?(_quota, _stale_ms), do: true

  defp grant(state, project, item, class, opts) do
    opts = Keyword.put(opts, :auxiliary_busy, helper_busy(state))

    case Scheduling.acquire(state.schedule, project, item, class, System.monotonic_time(:millisecond), opts) do
      {:ok, schedule} ->
        {:reply, :ok, %{state | schedule: schedule}}

      {:wait, reason, schedule, wake} ->
        wake(wake)
        {:reply, {:wait, reason}, %{state | schedule: schedule}}
    end
  end

  defp valid_helper_owner?(state, context) do
    is_binary(context[:run_id]) and is_pid(context[:recipient]) and
      match?(%{held: held} when is_map_key(held, context.issue_id), state.schedule.projects[context[:project]])
  end

  defp start_helper(state, owner, prepared) do
    context = prepared.context
    id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    governor = self()
    settings = state.service.helpers

    details = %{
      run_id: id,
      issue_id: id,
      issue_identifier: "helper-" <> id,
      parent_run_id: context.run_id,
      parent_issue_id: context.issue_id,
      project: context.project,
      source_sha: prepared.source_sha,
      model: settings.model,
      effort: settings.effort
    }

    result =
      Task.Supervisor.start_child(Project.via(context.project, :task_supervisor), fn ->
        Project.put(context.project)
        send(governor, {:helper_update, details, %{event: :helper_started, timestamp: DateTime.utc_now()}})
        runner = Application.get_env(:symphony_elixir, :helper_runner, &Helpers.run/3)
        prepared = put_in(prepared.context.recipient, governor)

        result =
          try do
            runner.(prepared, details, settings)
          rescue
            error -> {:error, Exception.message(error)}
          catch
            kind, reason -> {:error, {kind, inspect(reason)}}
          end

        send(governor, {:helper_result, id, result})
      end)

    case result do
      {:ok, pid} ->
        helper = %{
          id: id,
          pid: pid,
          ref: Process.monitor(pid),
          owner: owner,
          owner_ref: Process.monitor(owner),
          context: context,
          details: details,
          status: "running",
          result: nil,
          timer: Process.send_after(self(), {:helper_timeout, id}, settings.timeout_ms)
        }

        {:reply, {:ok, helper_view(helper)}, %{state | helpers: retain_helpers(Map.put(state.helpers, id, helper))}}

      {:error, reason} ->
        {:reply, {:error, {:helper_start_failed, reason}}, state}
    end
  catch
    :exit, _ -> {:reply, {:error, :helper_supervisor_unavailable}, state}
  end

  defp acquire_ready(state, project, item, class, opts) do
    case {opts[:quiet] == true, quiet_window(state).phase} do
      {true, "active"} ->
        case grant(state, project, item, :research, Keyword.put(opts, :exclusive, "global")) do
          {:reply, :ok, state} -> {:reply, :ok, %{state | quiet_runs: MapSet.put(state.quiet_runs, {project, item})}}
          waiting -> waiting
        end

      {true, _} ->
        {:reply, {:wait, "waiting for the owner-confirmed quiet acceptance window"}, state}

      {false, phase} when phase in ["preparing", "active"] ->
        {:reply, {:wait, "holding the service for quiet acceptance"}, state}

      _ ->
        grant(state, project, item, class, opts)
    end
  end

  defp research_reserved?(state), do: Scheduling.research_hold(state.schedule, System.monotonic_time(:millisecond))
  defp helpers_throttled?(state), do: Throttle.admit(throttle(state, DateTime.utc_now()), :research) != :ok

  defp notify_helper(helper, update) do
    recipient = helper.context.recipient
    if is_pid(recipient), do: send(recipient, {:helper_update, helper.details, update})
  end

  defp helpers_paused?(state), do: draining?(state) or warming_up?(state) or quiet_window(state).phase == "active"

  defp retain_helpers(helpers) when map_size(helpers) > 128 do
    completed = for {id, %{pid: nil}} <- helpers, do: id
    Map.drop(helpers, Enum.take(completed, map_size(helpers) - 128))
  end

  defp retain_helpers(helpers), do: helpers
  defp helper_busy(state), do: Enum.count(state.helpers, fn {_id, helper} -> is_pid(helper.pid) end)
  defp helper_view(helper), do: Map.merge(helper.details, %{helper_id: helper.id, status: helper.status, result: public_helper_result(helper.result)})
  defp public_helper_result({:ok, value}), do: value
  defp public_helper_result({:error, reason}), do: %{error: Helpers.error_text(reason)}
  defp public_helper_result(_), do: nil

  defp cancel_helper(%{pid: pid} = helper) when is_pid(pid) do
    Process.exit(pid, :kill)
    %{helper | status: "cancelling"}
  end

  defp cancel_helper(helper), do: helper
  defp helper_outcome(%{result: {:ok, value}}, :normal), do: {"completed", value}
  defp helper_outcome(%{result: {:error, reason}}, _), do: {"failed", Helpers.error_text(reason)}
  defp helper_outcome(%{status: "cancelling"}, _), do: {"stopped", "cancelled"}
  defp helper_outcome(_helper, reason), do: {"failed", Helpers.error_text(reason)}

  defp policy(state, project, now) do
    draining = draining?(state)
    free = Scheduling.free_for(state.schedule, project, System.monotonic_time(:millisecond))

    state
    |> throttle(now)
    |> Map.merge(%{
      slots: if(draining or warming_up?(state), do: 0, else: free),
      research_exclusive: state.schedule.projects[project].exclusive,
      quiet_window: quiet_window(state),
      draining: draining
    })
  end

  defp quiet_window(state) do
    pending = Enum.any?(state.quiet_demand, fn {_project, count} -> count > 0 end) or MapSet.size(state.quiet_runs) > 0

    if pending and not is_nil(state.service.quiet_window),
      do: Map.put(state.quiet_schedule, :phase, quiet_phase(state)),
      else: %{phase: "idle"}
  end

  defp quiet_phase(state) do
    time = DateTime.to_unix(governor_now())
    window = state.quiet_schedule
    prepare_at = (window[:starts_at] || 0) - state.service.quiet_window.drain_minutes * 60

    cond do
      is_nil(window[:refresh_at]) or time >= window.refresh_at -> "unknown"
      time >= window.starts_at and time < window.ends_at -> "active"
      time >= prepare_at and time < window.starts_at -> "preparing"
      true -> "idle"
    end
  end

  defp refresh_quiet_schedule(state) do
    stale = DateTime.to_unix(governor_now()) >= (state.quiet_schedule[:refresh_at] || 0)

    if not is_nil(state.service.quiet_window) and stale,
      do: %{state | quiet_schedule: Service.QuietWindow.observe(state.service.quiet_window, governor_now())},
      else: state
  end

  defp governor_now, do: Application.get_env(:symphony_elixir, :governor_now, &DateTime.utc_now/0).()

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

  defp draining?(state) do
    quiet = quiet_window(state)

    File.exists?(Path.join(Service.state_root(state.service), "drain")) or quiet.phase == "preparing" or
      (MapSet.size(state.quiet_runs) > 0 and quiet.phase != "active")
  end

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
