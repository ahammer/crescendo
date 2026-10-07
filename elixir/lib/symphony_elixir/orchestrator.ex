defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls the configured issue tracker and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{
    AgentRunner,
    Artifacts,
    Autopilot,
    Config,
    Governor,
    Handoff,
    ModelRouting,
    Operations,
    Project,
    Quota,
    Startup,
    StatusDashboard,
    Throttle,
    Tracker,
    Transcript,
    Workspace
  }

  alias SymphonyElixir.Codex.Usage
  alias SymphonyElixir.GitHub.Client, as: GitHubClient
  alias SymphonyElixir.Tracker.Issue

  @worker_updates ~w(worker_runtime_info worker_model_route codex_worker_update worker_startup_failure worker_admitted)a

  @continuation_retry_delay_ms 1_000
  # A retry held for a slot, the throttle, or a backed-off route checks again after this.
  @held_retry_delay_ms 30_000
  @failure_retry_base_ms 10_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    # One coordinator per project owns both budgets; another owner would duplicate retry state.
    # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :operations,
      :operations_error,
      :operations_last_sync_ms,
      task_supervisor: SymphonyElixir.TaskSupervisor,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      blocked: %{},
      startup_failures: %{},
      retry_attempts: %{},
      polled_issues: [],
      issues_observed_at: nil,
      issues_error: nil,
      pull_requests: [],
      pulls_observed_at: nil,
      pulls_error: nil,
      pulls_fetching: false,
      pulls_task_ref: nil,
      next_pulls_due_at_ms: 0,
      delivery_cursor: 0,
      codex_totals: nil,
      codex_rate_limits: nil,
      codex_quota: nil,
      throttle: nil,
      artifacts_root: nil,
      artifacts_swept_ms: nil,
      autopilot: %{pr_handled: %{}, tasks: %{}, item_attempts: %{}}
    ]
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    # Everything this process (and every task it starts) reads resolves the project's configuration.
    :ok = Project.put(Keyword.get(opts, :project))

    case Config.settings() do
      {:ok, config} ->
        now_ms = System.monotonic_time(:millisecond)
        {operations, operations_error} = open_operations(opts, Keyword.get(opts, :name, __MODULE__))
        {pull_requests, pulls_observed_at} = Operations.pull_inventory(operations)

        state = %State{
          poll_interval_ms: config.polling.interval_ms,
          max_concurrent_agents: config.agent.max_concurrent_agents,
          next_poll_due_at_ms: now_ms,
          poll_check_in_progress: false,
          tick_timer_ref: nil,
          tick_token: nil,
          task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor),
          operations: operations,
          operations_error: operations_error,
          operations_last_sync_ms: now_ms,
          pull_requests: pull_requests,
          pulls_observed_at: pulls_observed_at,
          next_pulls_due_at_ms: now_ms,
          codex_totals: @empty_codex_totals,
          codex_rate_limits: nil,
          codex_quota: Operations.quota(operations),
          artifacts_root: artifacts_root(opts),
          startup_failures: Operations.startup_state(operations),
          autopilot: Operations.autopilot_state(operations)
        }

        run_terminal_workspace_cleanup()
        # A restarted service learns the last known quota before the first run reports a new one.
        if state.codex_quota && governed?(), do: Governor.report_quota(state.codex_quota)
        state = state |> restore_startup_retries() |> schedule_tick(0)

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_fetch_pull_requests(state)
    state = maybe_dispatch(state)
    state = maybe_sync_operations(state)
    record_sample(state)
    state = maybe_sweep_artifacts(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    if ref == state.pulls_task_ref do
      Logger.warning("GitHub pull request inventory task exited: #{inspect(reason)}")
      notify_dashboard()

      {:noreply, %{state | pulls_fetching: false, pulls_task_ref: nil, pulls_error: "GitHub inventory task exited"}}
    else
      handle_worker_down(ref, reason, running, state)
    end
  end

  def handle_info({:worker_phase, issue_id, worker_pid, phase}, %{running: running} = state)
      when phase in [:codex, :cleanup] do
    case Map.get(running, issue_id) do
      %{pid: ^worker_pid} = entry ->
        entry = entry |> Map.put(:phase, phase) |> Map.put(:phase_started_at, DateTime.utc_now())
        {:noreply, %{state | running: Map.put(running, issue_id, entry)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({type, issue_id, run_id, payload}, state)
      when type in @worker_updates do
    case state.running[issue_id] do
      %{run_id: ^run_id} ->
        apply_worker_update(type, issue_id, payload, state)

      _ ->
        if type == :codex_worker_update do
          Operations.reconcile_usage(state.operations, issue_id, run_id, payload)
          notify_dashboard()
        end

        {:noreply, state}
    end
  end

  def handle_info({type, issue_id, payload}, state)
      when type in @worker_updates do
    case state.running[issue_id] do
      %{run_id: _} -> {:noreply, state}
      _ -> apply_worker_update(type, issue_id, payload, state)
    end
  end

  def handle_info({:pull_requests_fetched, result}, state) do
    if state.pulls_task_ref, do: Process.demonitor(state.pulls_task_ref, [:flush])
    state = %{state | pulls_fetching: false, pulls_task_ref: nil}

    result =
      case result do
        {:ok, pulls, statuses, deliveries} ->
          Enum.each(deliveries, &Operations.observe_delivery(state.operations, &1, Config.settings!().labels.prefix))
          {:ok, pulls, statuses}

        other ->
          other
      end

    state =
      case result do
        {:ok, pulls, statuses} ->
          record_pull_changes(state.operations, state.pull_requests, pulls, state.pulls_observed_at, statuses)
          observed_at = DateTime.utc_now()
          Operations.save_pull_inventory(state.operations, pulls, observed_at)
          %{state | pull_requests: pulls, pulls_observed_at: observed_at, pulls_error: nil}

        {:ok, pulls} ->
          record_pull_changes(state.operations, state.pull_requests, pulls, state.pulls_observed_at, %{})
          observed_at = DateTime.utc_now()
          Operations.save_pull_inventory(state.operations, pulls, observed_at)
          %{state | pull_requests: pulls, pulls_observed_at: observed_at, pulls_error: nil}

        {:error, reason} ->
          Logger.warning("GitHub pull request inventory failed: #{inspect(reason)}")
          %{state | pulls_error: safe_pull_error(reason)}
      end

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  # The service Governor kept a slot for this project: poll now to use it.
  def handle_info(:governor_wake, state) do
    {:noreply, if(poll_due?(state), do: state, else: schedule_tick(state, 0))}
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Operations.sync(state.operations)
    Operations.close(state.operations)
  end

  defp apply_worker_update(:worker_startup_failure, issue_id, diagnostic, state) do
    case state.running[issue_id] do
      %{model_admitted: false} = entry ->
        entry = Map.put(entry, :startup_failure, diagnostic)
        {:noreply, %{state | running: Map.put(state.running, issue_id, entry)}}

      _ ->
        {:noreply, state}
    end
  end

  defp apply_worker_update(:worker_admitted, issue_id, _payload, state) do
    case state.running[issue_id] do
      %{model_admitted: false} = entry ->
        entry = Map.put(entry, :model_admitted, true)
        state = %{state | running: Map.put(state.running, issue_id, entry)}
        state = put_startup(state, Map.delete(state.startup_failures, issue_id))
        {:noreply, put_autopilot(state, Autopilot.record_pull_dispatch(state.autopilot, entry.issue))}

      _ ->
        {:noreply, state}
    end
  end

  defp apply_worker_update(:worker_runtime_info, issue_id, runtime, state) when is_map(runtime) do
    case state.running[issue_id] do
      nil ->
        {:noreply, state}

      entry ->
        entry =
          entry
          |> maybe_put_runtime_value(:worker_host, runtime[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(state.running, issue_id, entry)}}
    end
  end

  defp apply_worker_update(:worker_model_route, issue_id, route, state) do
    case state.running[issue_id] do
      nil ->
        {:noreply, state}

      entry ->
        entry = entry |> Map.put(:model, route && route["model"]) |> Map.put(:route, route_summary(route))
        {:noreply, %{state | running: Map.put(state.running, issue_id, entry)}}
    end
  end

  defp apply_worker_update(:codex_worker_update, issue_id, %{event: _, timestamp: _} = update, state) do
    case state.running[issue_id] do
      nil ->
        {:noreply, state}

      entry ->
        {entry, update} = account_thread_update(state.operations, entry, update)
        {entry, delta} = integrate_codex_update(entry, update)
        entry = record_transcript(state, entry, update)
        state = state |> apply_codex_token_delta(delta) |> apply_codex_rate_limits(update)
        maybe_record_turn_event(state.operations, entry, update)
        notify_dashboard()
        {:noreply, %{state | running: Map.put(state.running, issue_id, entry)}}
    end
  end

  defp apply_worker_update(_type, _issue_id, _payload, state), do: {:noreply, state}

  defp account_thread_update(
         table,
         entry,
         %{event: :thread_initialized, thread_id: thread, thread_key: key} = update
       ) do
    context =
      Map.take(update, [
        :model,
        :model_provider,
        :requested_model,
        :effort,
        :effort_source,
        :service_tier,
        :codex_version,
        :user_agent,
        :instruction_sources_hash,
        :instruction_files_hash,
        :dynamic_tools_hash,
        :effective_settings_hash,
        :native_storage_hash,
        :resumed
      ])
      |> Map.put(:run_id, entry.run_id)

    attribution = %{
      issue_id: entry.issue.id,
      thread_id: thread,
      thread_key: key,
      identifier: entry.identifier,
      model: update[:model] || entry[:model],
      date: Date.to_iso8601(Date.utc_today()),
      rates: Map.get_lazy(entry, :pricing_rates, fn -> Operations.rates(Config.settings!().pricing) end)
    }

    result =
      with :ok <- Operations.thread_context(table, key, context),
           do: Operations.bind_accounting(table, entry.run_id, attribution)

    entry =
      entry |> Map.put(:thread_id, thread) |> Map.put(:thread_key, key) |> Map.put(:codex_provenance, context)

    {if(result == :ok, do: entry, else: Map.put(entry, :accounting_error, result)), update}
  end

  defp account_thread_update(table, entry, update) do
    case Operations.reconcile_usage(table, entry.issue.id, entry[:run_id], update, true) do
      {:ok, delta} ->
        {entry, Map.put(update, :accounted_delta, delta)}

      {:error, reason} ->
        Logger.error("Thread accounting unavailable for #{entry.identifier}: #{inspect(reason)}")
        {Map.put(entry, :accounting_error, reason), Map.put(update, :accounted_delta, Usage.normalize(%{}))}

      :ignored ->
        {entry, if(entry[:thread_key], do: Map.put(update, :accounted_delta, Usage.normalize(%{})), else: update)}
    end
  end

  defp handle_worker_down(ref, reason, running, state) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        :ok = release_slot(issue_id)
        state = record_session_completion_totals(state, running_entry)
        running_entry = startup_exit_evidence(running_entry, reason)
        session_id = running_entry_session_id(running_entry)

        {outcome, summary, interruption} =
          if running_entry[:startup_failure],
            do: {"startup_failed", "Startup admission failed", nil},
            else: worker_outcome(reason)

        Operations.finish_run(
          state.operations,
          Map.get(running_entry, :run_id),
          outcome,
          %{
            issue_identifier: running_entry.identifier,
            issue_url: running_entry.issue.url,
            title: running_entry.issue.title,
            model: Map.get(running_entry, :model),
            summary: summary,
            reason: interruption,
            startup: running_entry[:startup_failure],
            worker_host: running_entry[:worker_host]
          }
        )

        state = handle_agent_down(reason, state, issue_id, running_entry, session_id)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  defp startup_exit_evidence(entry, {:shutdown, :deployment_drain}), do: entry

  defp startup_exit_evidence(%{model_admitted: false} = entry, reason) when reason != :normal do
    Map.put_new(entry, :startup_failure, Startup.diagnostic(:worker_start, reason))
  end

  defp startup_exit_evidence(entry, _reason), do: entry

  defp worker_outcome(:normal), do: {"completed", "Worker finished", nil}

  defp worker_outcome({:shutdown, :deployment_drain}),
    do: {"interrupted", "Worker yielded for deployment drain", "deployment_drain"}

  defp worker_outcome({:shutdown, {:protocol_buffer_overflow, _}}),
    do: {"interrupted", "App-server protocol overflow", "protocol_buffer_overflow"}

  defp worker_outcome(_reason), do: {"failed", "Worker failed", nil}

  defp handle_agent_down(_reason, state, issue_id, %{startup_failure: diagnostic} = entry, _session_id) do
    startup_failed(state, issue_id, entry, diagnostic)
  end

  defp handle_agent_down({:shutdown, :deployment_drain}, state, issue_id, running_entry, _session_id) do
    schedule_issue_retry(state, issue_id, Map.get(running_entry, :retry_attempt, 0), %{
      identifier: running_entry.identifier,
      issue_url: running_entry.issue.url,
      delay_type: :continuation,
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    })
  end

  defp handle_agent_down(
         {:shutdown, {:protocol_buffer_overflow, _}},
         state,
         issue_id,
         %{issue: %Issue{kind: :research, research: %{channel: channel}}},
         _session
       ) do
    settings = Config.settings!().autopilot
    autopilot = Autopilot.record_research_finished(state.autopilot, channel, :interrupted, now(), settings)
    state |> put_autopilot(autopilot) |> release_issue_claim(issue_id)
  end

  defp handle_agent_down({:shutdown, {:protocol_buffer_overflow, diagnostic}}, state, issue_id, entry, _session) do
    schedule_issue_retry(state, issue_id, Map.get(entry, :retry_attempt, 0), %{
      identifier: entry.identifier,
      issue_url: entry.issue.url,
      delay_type: :held,
      delay_ms: 30_000,
      error: "App-server transport interrupted: #{inspect(diagnostic)}",
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    })
  end

  # Research runs are one-shot: their deliveries are checked, and the task is
  # due again after its interval, or retried sooner when it fell short.
  defp handle_agent_down(
         reason,
         state,
         issue_id,
         %{issue: %Issue{kind: :research}} = running_entry,
         _session_id
       ) do
    finish_research(state, issue_id, running_entry, if(reason == :normal, do: :normal, else: :failed))
  end

  # A review pass ends at its head commit; the pull request is picked up again
  # after a new push or the recheck cooldown, once CI settles, not through
  # continuation retries.
  defp handle_agent_down(
         :normal,
         state,
         issue_id,
         %{issue: %Issue{kind: :pull_request} = issue} = running_entry,
         session_id
       ) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)
    else
      state
      |> put_autopilot(Autopilot.record_pull_handled(state.autopilot, issue, Map.get(running_entry, :dispatched_head)))
      |> complete_issue(issue_id)
      |> release_issue_claim(issue_id)
    end
  end

  defp handle_agent_down(:normal, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)
    else
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

      state
      |> complete_issue(issue_id)
      |> schedule_issue_retry(issue_id, 1, %{
        identifier: running_entry.identifier,
        issue_url: running_entry.issue.url,
        delay_type: :continuation,
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path)
      })
    end
  end

  defp handle_agent_down(reason, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, reason)
    else
      retry_agent_down(state, issue_id, running_entry, session_id, reason)
    end
  end

  defp block_input_required_agent_down(state, issue_id, running_entry, session_id, reason) do
    error = blocker_error(running_entry, "agent exited: #{inspect(reason)}")

    Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

    fail_attempt_or_block(state, issue_id, running_entry, error, "Operator input or approval required")
  end

  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

    retry_failed_issue(state, issue_id, running_entry, %{
      identifier: running_entry.identifier,
      issue_url: running_entry.issue.url,
      error: "agent exited: #{inspect(reason)}",
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    })
  end

  # Failed runs back off until `agent.max_attempts`; then the issue is blocked
  # until its tracker state or labels change.
  defp retry_failed_issue(state, issue_id, running_entry, metadata) do
    attempt = next_retry_attempt_from_running(running_entry) || 1
    max_attempts = Config.settings!().agent.max_attempts

    if is_integer(max_attempts) and attempt > max_attempts do
      error = "gave up after #{max_attempts} attempts; last error: #{metadata.error}"
      Logger.warning("Issue failed: issue_id=#{issue_id} issue_identifier=#{metadata.identifier}; #{error}")
      fail_attempt_or_block(state, issue_id, running_entry, error, "Gave up after #{max_attempts} attempts")
    else
      schedule_issue_retry(state, issue_id, attempt, metadata)
    end
  end

  defp maybe_dispatch(%State{} = state) do
    state =
      state
      |> refresh_startup_retries()
      |> reconcile_running_issues()
      |> reconcile_blocked_issues()
      |> reconcile_startup_issues()

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_issues_by_states(Config.settings!().tracker.active_states) do
      state =
        %{
          state
          | polled_issues: sort_issues_for_dispatch(issues),
            issues_observed_at: DateTime.utc_now(),
            issues_error: nil
        }
        |> put_autopilot(Autopilot.prune_pull_requests(state.autopilot, issues))

      state = %{state | throttle: evaluate_throttle(state)}

      {state, issues} = settle_autopilot_items(state, issues)
      state = choose_issues(issues, state)
      maybe_dispatch_research(state, issues)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Tracker API token missing in WORKFLOW.md")
        %{state | issues_error: "missing Linear API token"}

      {:error, :missing_linear_project_slug} ->
        Logger.error("Tracker project scope missing in WORKFLOW.md")
        %{state | issues_error: "missing Linear project scope"}

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        %{state | issues_error: "missing tracker kind"}

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        %{state | issues_error: "unsupported tracker kind #{inspect(kind)}"}

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        %{state | issues_error: message}

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        %{state | issues_error: "missing workflow file #{path}: #{inspect(reason)}"}

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        %{state | issues_error: "workflow front matter is not a map"}

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        %{state | issues_error: "workflow parse error: #{inspect(reason)}"}

      {:error, reason} ->
        Logger.error("Failed to fetch from issue tracker: #{inspect(reason)}")
        %{state | issues_error: "tracker fetch failed"}
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = tracker_backed_ids(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issues_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  defp reconcile_blocked_issues(%State{} = state) do
    blocked_ids = tracker_backed_ids(state.blocked)

    if blocked_ids == [] do
      state
    else
      case Tracker.fetch_issues_by_ids(blocked_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_blocked_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_blocked_issue_ids(blocked_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh blocked issue states: #{inspect(reason)}; keeping blocked issues")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec reconcile_blocked_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_blocked_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_blocked_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec handle_retry_issue_lookup_for_test(Issue.t(), term(), String.t(), non_neg_integer(), map()) ::
          term()
  def handle_retry_issue_lookup_for_test(%Issue{} = issue, %State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_integer(attempt) and attempt >= 0 and is_map(metadata) do
    {:noreply, updated_state} = handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)
    updated_state
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        Operations.disposition(state.operations, Map.from_struct(issue), Config.settings!().labels.prefix)

        terminate_running_issue(state, issue.id, true)

      !issue_routable?(issue) or not handoff_owner?(issue, state.autopilot) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; releasing block")

        Operations.disposition(state.operations, Map.from_struct(issue), Config.settings!().labels.prefix)
        cleanup_issue_workspace(issue, Map.get(state.blocked, issue.id, %{}))
        release_issue_claim(state, issue.id)

      !issue_routable?(issue) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing block")

        release_issue_claim(state, issue.id)

      active_issue_state?(issue.state, active_states) ->
        refresh_blocked_issue_state(state, issue)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing block")

        release_issue_claim(state, issue.id)
    end
  end

  defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp reconcile_missing_blocked_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        Logger.info("Blocked issue no longer visible during state refresh: issue_id=#{issue_id}; releasing block")

        release_issue_claim(state_acc, issue_id)
      end
    end)
  end

  defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp refresh_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.blocked, issue.id) do
      %{issue: _} = blocked_entry ->
        %{state | blocked: Map.put(state.blocked, issue.id, %{blocked_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)

        stop_running_task(pid, ref, state.task_supervisor)
        # The stopped task's DOWN is flushed, so its service slot is released here.
        :ok = release_slot(issue_id)
        record_stopped_run(state, running_entry, "Worker stopped by reconciliation")

        if cleanup_workspace do
          cleanup_issue_workspace(Map.get(running_entry, :issue, identifier), running_entry)
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            blocked: Map.delete(state.blocked, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          maybe_restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp maybe_restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    if Map.has_key?(state.blocked, issue_id) or Map.get(running_entry, :phase) in [:workspace, :cleanup] do
      state
    else
      restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      cond do
        running_entry[:model_admitted] == false ->
          diagnostic = Startup.diagnostic(:session_start, "stalled for #{elapsed_ms}ms without codex activity")

          state
          |> terminate_running_issue(issue_id, false)
          |> startup_failed(issue_id, running_entry, diagnostic)

        research_entry?(running_entry) ->
          Logger.warning("Research stalled: issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; ending round")

          state
          |> terminate_running_issue(issue_id, false)
          |> finish_research(issue_id, running_entry, :failed)

        input_required_blocker?(running_entry) ->
          error =
            blocker_error(running_entry, "stalled for #{elapsed_ms}ms after Codex requested operator input")

          Logger.warning("Issue blocked: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; #{error}")

          state
          |> record_session_completion_totals(running_entry)
          |> stop_and_block_issue(issue_id, running_entry, error)

        true ->
          Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

          state
          |> terminate_running_issue(issue_id, false)
          |> retry_failed_issue(issue_id, running_entry, %{
            identifier: identifier,
            issue_url: running_entry.issue.url,
            error: "stalled for #{elapsed_ms}ms without codex activity"
          })
      end
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :phase_started_at) ||
      Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp input_required_blocker?(running_entry) do
    Map.get(running_entry, :last_codex_event) in [:turn_input_required, :approval_required] or
      not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
      codex_message_method(Map.get(running_entry, :last_codex_message)) ==
        "mcpServer/elicitation/request"
  end

  defp input_required_completion_outcome(completion) when is_map(completion) do
    outcome = Map.get(completion, :outcome) || Map.get(completion, "outcome")
    normalize_input_required_outcome(outcome)
  end

  defp input_required_completion_outcome(_completion), do: nil

  defp normalize_input_required_outcome(outcome)
       when outcome in [:input_required, :needs_input, :approval_required],
       do: outcome

  defp normalize_input_required_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "input_required" -> :input_required
      "needs_input" -> :needs_input
      "approval_required" -> :approval_required
      _ -> nil
    end
  end

  defp normalize_input_required_outcome(_outcome), do: nil

  defp blocker_error(running_entry, fallback) do
    codex_event_blocker_error(Map.get(running_entry, :last_codex_event)) ||
      completion_blocker_error(Map.get(running_entry, :completion)) ||
      codex_message_blocker_error(Map.get(running_entry, :last_codex_message)) ||
      fallback
  end

  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
  defp codex_event_blocker_error(_event), do: nil

  defp completion_blocker_error(completion) do
    case input_required_completion_outcome(completion) do
      outcome when outcome in [:input_required, :needs_input] -> "codex turn requires operator input"
      :approval_required -> "codex turn requires approval"
      nil -> nil
    end
  end

  defp codex_message_blocker_error(message) do
    if codex_message_method(message) == "mcpServer/elicitation/request" do
      "codex MCP elicitation requires operator input"
    end
  end

  defp codex_message_method(%{message: %{"method" => method}}) when is_binary(method), do: method
  defp codex_message_method(%{message: %{method: method}}) when is_binary(method), do: method
  defp codex_message_method(%{"method" => method}) when is_binary(method), do: method
  defp codex_message_method(%{method: method}) when is_binary(method), do: method
  defp codex_message_method(_message), do: nil

  defp terminate_task(pid, task_supervisor) when is_pid(pid) do
    case Task.Supervisor.terminate_child(task_supervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid, _task_supervisor), do: :ok

  defp stop_running_task(pid, ref, task_supervisor) do
    if is_pid(pid) do
      terminate_task(pid, task_supervisor)
    end

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp stop_and_block_issue(%State{} = state, issue_id, running_entry, error) do
    stop_running_task(
      Map.get(running_entry, :pid),
      Map.get(running_entry, :ref),
      state.task_supervisor
    )

    :ok = release_slot(issue_id)
    record_stopped_run(state, running_entry, "Worker stopped for operator input")

    fail_attempt_or_block(state, issue_id, running_entry, error, "Operator input or approval required")
  end

  # Autopilot never parks work: a failed run counts one attempt, the item goes
  # back behind other work, and it is retired after `max_item_attempts`.
  # Without autopilot the item is blocked for an operator as before.
  defp fail_attempt_or_block(state, issue_id, running_entry, error, summary) do
    case Map.get(running_entry, :issue) do
      %Issue{kind: kind} = issue when kind != :research ->
        if Config.settings!().autopilot.enabled do
          state
          |> Map.update!(:running, &Map.delete(&1, issue_id))
          |> record_failed_attempt(issue, error)
        else
          block_issue_from_entry(state, issue_id, running_entry, error, summary)
        end

      _ ->
        block_issue_from_entry(state, issue_id, running_entry, error, summary)
    end
  end

  defp record_failed_attempt(state, %Issue{} = issue, reason) do
    settings = Config.settings!().autopilot
    {autopilot, attempts} = Autopilot.record_failed_attempt(state.autopilot, Autopilot.delivery_key(issue))

    Logger.info("Autopilot attempt failed: #{issue_context(issue)} attempt=#{attempts}/#{settings.max_item_attempts} reason=#{inspect(reason)}")

    Operations.event(state.operations, "attempt_failed", %{
      issue_identifier: issue.identifier,
      issue_url: issue.url,
      item_attempt: attempts,
      summary: "Attempt #{attempts}/#{settings.max_item_attempts}: #{reason}"
    })

    state = state |> put_autopilot(autopilot) |> release_issue_claim(issue.id)
    if attempts >= settings.max_item_attempts, do: retire_item(state, issue, reason), else: state
  end

  defp retire_item(state, %Issue{} = issue, reason) do
    comment =
      "Crescendo retired this #{if issue.kind == :pull_request, do: "pull request", else: "issue"} " <>
        "after exhausting its attempts, so it will not be retried. Last blocker: #{reason}"

    case Tracker.retire(issue, comment) do
      :ok ->
        Logger.info("Autopilot retired #{issue_context(issue)}: #{reason}")

        Operations.disposition(
          state.operations,
          issue |> Map.from_struct() |> Map.put(:state_reason, "not_planned"),
          Config.settings!().labels.prefix
        )

        state = put_autopilot(state, Map.update(state.autopilot, :retired_items, %{issue.id => true}, &Map.put(&1, issue.id, true)))
        cleanup_issue_workspace(issue)
        state

      {:error, error} ->
        Logger.warning("Autopilot could not retire #{issue_context(issue)}: #{inspect(error)}; retrying next poll")
        state
    end
  end

  # A stopped task delivers no :DOWN, so its run is closed here; otherwise the
  # next restart would report it as interrupted.
  defp record_stopped_run(state, running_entry, summary) do
    Operations.finish_run(state.operations, Map.get(running_entry, :run_id), "stopped", %{
      issue_identifier: Map.get(running_entry, :identifier),
      issue_url: Map.get(Map.get(running_entry, :issue) || %{}, :url),
      title: Map.get(Map.get(running_entry, :issue) || %{}, :title),
      model: Map.get(running_entry, :model),
      summary: summary
    })
  end

  defp block_issue_from_entry(%State{} = state, issue_id, running_entry, error, summary) do
    Operations.event(state.operations, "blocked", %{
      run_id: Map.get(running_entry, :run_id),
      item_attempt: nil,
      issue_identifier: Map.get(running_entry, :identifier, issue_id),
      issue_url: Map.get(Map.get(running_entry, :issue) || %{}, :url),
      summary: summary
    })

    blocked_entry = %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier, issue_id),
      issue: Map.get(running_entry, :issue),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      session_id: running_entry_session_id(running_entry),
      error: error,
      blocked_at: DateTime.utc_now(),
      last_codex_message: Map.get(running_entry, :last_codex_message),
      last_codex_event: Map.get(running_entry, :last_codex_event),
      last_codex_timestamp: Map.get(running_entry, :last_codex_timestamp)
    }

    %{
      state
      | running: Map.delete(state.running, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }
  end

  # Consumes blocked markers left by workers (each is one failed attempt) and
  # retires items that exhausted their attempts or review runs, so nothing waits
  # on an operator. Returns the items still eligible for this poll.
  defp settle_autopilot_items(%State{} = state, issues) do
    settings = Config.settings!().autopilot

    {autopilot, issues} = Autopilot.admit_handoffs(state.autopilot, issues, settlement_tracker(settings))
    state = put_autopilot(state, autopilot)

    if settings.enabled do
      {kept, state} = Enum.flat_map_reduce(issues, state, &settle_autopilot_item(&2, &1, settings))
      {state, kept}
    else
      {state, issues}
    end
  end

  defp settle_autopilot_item(state, %Issue{} = issue, settings) do
    case autopilot_item_status(state, issue, settings) do
      :blocked -> consume_blocked_marker(state, issue, settings)
      :retired -> {[], state}
      :exhausted -> {[], retire_item(state, issue, "attempts exhausted")}
      :review_capped -> {[], retire_item(state, issue, "review run cap reached without merging")}
      :active -> {[issue], state}
    end
  end

  defp autopilot_item_status(state, issue, settings) do
    tracker = settlement_tracker(settings)
    eligible = Issue.routable?(issue, tracker.required_labels, tracker.excluded_labels)

    if Map.has_key?(state.running, issue.id) or not Issue.tracker_backed?(issue) or not eligible,
      do: :active,
      else: delivery_item_status(state, issue, settings)
  end

  defp settlement_tracker(settings) do
    tracker = Config.settings!().tracker
    %{tracker | excluded_labels: List.delete(tracker.excluded_labels, settings.blocked_label)}
  end

  defp delivery_item_status(state, issue, settings) do
    cond do
      Map.get(state.autopilot, :retired_items, %{})[issue.id] == true -> :retired
      issue.kind == :issue and settings.blocked_label in Issue.label_names(issue) -> :blocked
      Autopilot.exhausted?(state.autopilot, Autopilot.delivery_key(issue), settings) -> :exhausted
      review_capped?(state, issue, settings) -> :review_capped
      true -> :active
    end
  end

  defp review_capped?(state, %Issue{kind: :pull_request} = issue, settings),
    do: Autopilot.pull_request_waiting_reason(issue, state.autopilot, settings) == "review run cap reached"

  defp review_capped?(_state, _issue, _settings), do: false

  # A worker ends a failed attempt with the blocked label; clearing it here
  # records the attempt exactly once and requeues the item behind fresh work.
  defp consume_blocked_marker(state, issue, settings) do
    case Tracker.clear_label(issue, settings.blocked_label) do
      :ok ->
        state = record_failed_attempt(state, issue, "worker reported a blocker (see workpad)")
        remaining = %{issue | labels: List.delete(issue.labels, settings.blocked_label)}
        exhausted = Autopilot.exhausted?(state.autopilot, Autopilot.delivery_key(issue), settings)
        kept = if exhausted, do: [], else: [remaining]
        {kept, state}

      {:error, error} ->
        Logger.warning("Could not clear #{settings.blocked_label} on #{issue_context(issue)}: #{inspect(error)}")

        {[issue], state}
    end
  end

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch(state.autopilot)
    |> Enum.reduce(state, fn issue, state_acc ->
      if ready_for_dispatch?(issue, state_acc, active_states, terminal_states),
        do: Operations.observe_eligible(state_acc.operations, issue.id)

      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  # Items that already failed go behind fresh work, so a blocked item is
  # retried later instead of starving the queue.
  defp sort_issues_for_dispatch(issues, autopilot \\ %{}) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {kind_rank(issue.kind), Autopilot.failed_attempts(autopilot, Autopilot.delivery_key(issue)), priority_rank(issue.priority), issue_created_at_sort_key(issue),
         issue.identifier || issue.id || ""}

      _ ->
        {kind_rank(nil), 0, priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  # Pull requests always outrank issues: finishing delivery beats starting work.
  defp kind_rank(:pull_request), do: 0
  defp kind_rank(_kind), do: 1

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(%Issue{} = issue, %State{} = state, active_states, terminal_states) do
    ready_for_dispatch?(issue, state, active_states, terminal_states) and
      available_slots(state) > 0 and
      state_slots_available?(issue, state.running) and
      worker_slots_available?(state)
  end

  # Everything but capacity: the item could start as soon as a slot frees.
  defp ready_for_dispatch?(%Issue{} = issue, %State{} = state, active_states, terminal_states) do
    candidate_issue?(issue, active_states, terminal_states) and
      !MapSet.member?(state.claimed, issue.id) and
      !Map.has_key?(state.running, issue.id) and
      !Map.has_key?(state.retry_attempts, issue.id) and
      !Map.has_key?(state.blocked, issue.id) and
      handoff_owner?(issue, state.autopilot) and
      Startup.ready?(state.startup_failures[issue.id]) and
      Autopilot.pull_request_ready?(issue, state.autopilot, Config.settings!().autopilot) and
      dispatch_admission(state, issue) == :ok
  end

  defp handoff_owner?(%Issue{delivery_key: nil, id: id}, autopilot),
    do: not Enum.any?(Map.get(autopilot, :handoff_owners, %{}), fn {_key, owner} -> owner == id end)

  defp handoff_owner?(issue, autopilot), do: Map.get(autopilot, :handoff_owners, %{})[issue.delivery_key] == issue.id

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    Enum.all?([id, identifier, title, state_name], &present_string?/1) and
      issue_routable?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable?(%Issue{} = issue) do
    tracker = Config.settings!().tracker
    Issue.routable?(issue, tracker.required_labels, tracker.excluded_labels)
  end

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    startup = state.startup_failures[issue.id]
    attempt = if startup, do: startup.delivery_attempt, else: attempt

    case refresh_issue_for_dispatch(issue) do
      {:ok, %Issue{} = refreshed_issue} ->
        case admit_run(state, refreshed_issue, dispatch_class(state, refreshed_issue)) do
          {:ok, state, route} ->
            do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host, route)

          {:wait, reason} ->
            Logger.debug("Holding dispatch for #{issue_context(refreshed_issue)}: #{reason}")
            state
        end

      {:skip, _reason} ->
        state

      {:error, _reason} ->
        state
    end
  end

  defp refresh_issue_for_dispatch(%Issue{kind: :research} = issue), do: {:ok, issue}

  defp refresh_issue_for_dispatch(issue) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issues_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{kind: :pull_request} = refreshed_issue} ->
        pull_request_ci_gate(refreshed_issue)

      {:ok, %Issue{} = refreshed_issue} ->
        {:ok, refreshed_issue}

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        {:skip, :missing}

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        {:skip, refreshed_issue}

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")

        {:error, reason}
    end
  end

  # Reviewers never sit on running CI: a pull request with pending checks is
  # skipped and picked up again once they settle. Unknown CI fails closed.
  defp pull_request_ci_gate(%Issue{pull_request: %{head_sha: head_sha}} = issue) when is_binary(head_sha) do
    client = Application.get_env(:symphony_elixir, :github_client_module, GitHubClient)

    case client.fetch_commit_ci_state(head_sha) do
      {:ok, "pending"} ->
        Logger.debug("Skipping dispatch; CI pending for #{issue_context(issue)}")
        {:skip, :ci_pending}

      {:ok, ci_state} ->
        {:ok, put_in(issue.pull_request[:ci_state], ci_state)}

      {:error, reason} ->
        Logger.warning("Skipping dispatch; CI lookup failed for #{issue_context(issue)}: #{inspect(reason)}")
        {:skip, :ci_pending}
    end
  end

  defp pull_request_ci_gate(issue) do
    Logger.info("Skipping dispatch; pull request details unavailable for #{issue_context(issue)}")
    {:skip, :ci_pending}
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, route) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")

        :ok = release_slot(issue.id)
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, {worker_host, route})
    end
  end

  # The route is chosen here, before a slot is spent, so quota back-off can
  # swap the model or hold the item; a route error still fails in the runner.
  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, {worker_host, route}) do
    settings = Config.settings!().autopilot
    item_attempt = Autopilot.failed_attempts(state.autopilot, Autopilot.delivery_key(issue)) + 1
    final_attempt = settings.enabled and Autopilot.final_run?(state.autopilot, issue, settings)
    selected = selected_route(route)
    run_id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    codex = Config.settings!().codex
    {candidate, claim} = claim_checkpoint(state.operations, issue, item_attempt, worker_host, codex)

    spawn_result =
      with :ok <- claim do
        start_worker_task(state.task_supervisor, fn ->
          AgentRunner.run(issue, recipient,
            attempt: attempt,
            worker_host: worker_host,
            item_attempt: item_attempt,
            final_attempt: final_attempt,
            model_route: route,
            run_id: run_id,
            codex_settings: codex,
            checkpoint: candidate
          )
        end)
      end

    case spawn_result do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            phase: :workspace,
            model_admitted: false,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            codex_last_reported_cached_input_tokens: 0,
            run_id: run_id,
            model: selected && selected["model"],
            route: route_summary(selected),
            pricing_rates: Operations.rates(Config.settings!().pricing),
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            # Reconciliation refreshes `issue`; the reviewed head stays the dispatched one.
            dispatched_head: Autopilot.dispatched_head(issue),
            item_attempt: item_attempt,
            final_attempt: final_attempt,
            started_at: DateTime.utc_now()
          })

        entry = Map.fetch!(running, issue.id)

        Operations.start_run(state.operations, entry.run_id, %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          issue_url: issue.url,
          kind: issue.kind,
          delivery_key: issue.delivery_key,
          handoff: Handoff.record(issue),
          reduced_scope: "#{Config.settings!().labels.prefix}:delivery:split" in issue.labels,
          review_head: entry.dispatched_head,
          requested_route: entry.route,
          item_attempt: item_attempt,
          summary: "Dispatched to #{worker_host || "local"}"
        })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        :ok = release_slot(issue.id)

        entry = %{
          issue: issue,
          identifier: issue.identifier,
          run_id: run_id,
          worker_host: worker_host,
          retry_attempt: normalize_retry_attempt(attempt)
        }

        startup_failed(state, issue.id, entry, Startup.diagnostic(:worker_spawn, reason))
    end
  end

  defp start_worker_task(supervisor, fun) do
    Task.Supervisor.start_child(supervisor, fun)
  catch
    :exit, reason -> {:error, {:worker_spawn_exit, reason}}
  end

  defp claim_checkpoint(table, issue, item_attempt, host, codex) do
    checkpoint = Operations.checkpoint(table, issue.id)
    candidate = if eligible_checkpoint?(checkpoint, issue, item_attempt, host, codex), do: checkpoint
    # Claim the prior boundary before a new process can submit any actions.
    claim =
      if checkpoint,
        do: Operations.save_checkpoint(table, issue.id, Map.put(checkpoint, :eligible, false)),
        else: :ok

    {candidate, claim}
  end

  defp eligible_checkpoint?(
         %{eligible: true, item_attempt: attempt, worker_host: host},
         issue,
         attempt,
         host,
         codex
       ),
       do: codex.resume_threads and issue.kind == :issue

  defp eligible_checkpoint?(_checkpoint, _issue, _attempt, _host, _codex), do: false

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp startup_failed(state, issue_id, entry, diagnostic) do
    identity = %{
      issue_id: issue_id,
      kind: entry.issue.kind,
      research_channel: entry.issue.research && entry.issue.research[:channel],
      identifier: entry.identifier,
      issue_url: entry.issue.url,
      worker_host: entry[:worker_host],
      run_id: entry[:run_id],
      worker_pid: inspect(entry[:pid])
    }

    failure = Startup.failed(state.startup_failures[issue_id], identity, diagnostic, entry[:retry_attempt] || 0)

    Operations.event(
      state.operations,
      if(failure.count >= 3, do: "startup_blocked", else: "startup_retry"),
      Map.merge(identity, %{
        issue_identifier: entry.identifier,
        startup: diagnostic,
        startup_attempt: failure.count,
        summary: failure.error
      })
    )

    state = state |> release_issue_claim(issue_id) |> put_startup(Map.put(state.startup_failures, issue_id, failure))
    schedule_startup_retry(state, issue_id, failure)
  end

  defp put_startup(state, failures) do
    :ok = Operations.save_startup_state(state.operations, failures)
    %{state | startup_failures: failures}
  end

  defp schedule_startup_retry(state, issue_id, %{count: count} = failure) when count < 3 do
    schedule_issue_retry(state, issue_id, failure.delivery_attempt, %{
      identifier: failure.identifier,
      issue_url: failure.issue_url,
      error: failure.error,
      worker_host: failure.worker_host,
      delay_type: :startup,
      delay_ms: max(0, failure.due_at_ms - System.system_time(:millisecond))
    })
  end

  defp schedule_startup_retry(state, _issue_id, _failure), do: state

  defp restore_startup_retries(state) do
    Enum.reduce(state.startup_failures, state, fn {id, failure}, acc -> schedule_startup_retry(acc, id, failure) end)
  end

  defp reconcile_startup_issues(state) do
    ids = for {id, entry} <- state.startup_failures, entry[:kind] != :research, do: id
    refresh_startup_visibility(state, ids)
  end

  defp refresh_startup_visibility(state, []), do: state

  defp refresh_startup_visibility(state, ids) do
    case Tracker.fetch_issues_by_ids(ids) do
      {:ok, issues} -> prune_startup_failures(state, ids, issues)
      {:error, _reason} -> state
    end
  end

  defp prune_startup_failures(state, ids, issues) do
    visible = for issue <- issues, issue_routable?(issue) and active_issue_state?(issue.state, active_state_set()), into: MapSet.new(), do: issue.id
    removed = Enum.reject(ids, &MapSet.member?(visible, &1))
    state = Enum.reduce(removed, state, &release_issue_claim(&2, &1))
    put_startup(state, Map.drop(state.startup_failures, removed))
  end

  defp refresh_startup_retries(state) do
    fingerprint = Startup.fingerprint()

    state.startup_failures
    |> Enum.filter(fn {_id, failure} -> failure.fingerprint != fingerprint end)
    |> Enum.reduce(state, fn {id, _failure}, acc -> cancel_startup_timer(acc, id) end)
  end

  defp cancel_startup_timer(state, id) do
    case state.retry_attempts[id] do
      %{timer_ref: timer} when is_reference(timer) -> Process.cancel_timer(timer)
      _ -> :ok
    end

    %{state | retry_attempts: Map.delete(state.retry_attempts, id)}
  end

  defp scheduled_retry_delay(state, issue_id, attempt, metadata) do
    metadata[:delay_ms] ||
      if(state.startup_failures[issue_id], do: @held_retry_delay_ms, else: retry_delay(attempt, metadata))
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1

    delay_ms = scheduled_retry_delay(state, issue_id, next_attempt, metadata)

    state =
      if failure = state.startup_failures[issue_id] do
        failure = %{failure | due_at_ms: System.system_time(:millisecond) + delay_ms}
        put_startup(state, Map.put(state.startup_failures, issue_id, failure))
      else
        state
      end

    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    issue_url = pick_retry_issue_url(previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    if metadata[:delay_type] != :held do
      error_suffix = if is_binary(error), do: " error=#{error}", else: ""

      Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

      Operations.event(state.operations, "retry_scheduled", %{
        issue_identifier: identifier,
        issue_url: issue_url,
        summary:
          if(state.startup_failures[issue_id],
            do: "Startup recovery check in #{div(delay_ms, 1_000)}s",
            else: "Attempt #{next_attempt} in #{div(delay_ms, 1_000)}s"
          )
      })
    end

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            issue_url: issue_url,
            error: error,
            delay_type: metadata[:delay_type],
            worker_host: worker_host,
            workspace_path: workspace_path
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        state = %{state | throttle: evaluate_throttle(state)}

        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          issue_url: Map.get(retry_entry, :issue_url),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  # Research retries use their configured channels, never synthetic tracker IDs.
  # With every slot busy an issue retry waits without asking the tracker.
  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    cond do
      match?(%{kind: :research}, state.startup_failures[issue_id]) ->
        {:noreply, maybe_dispatch_research(state, state.polled_issues)}

      available_slots(state) > 0 ->
        fetch_retry_issue(state, issue_id, attempt, metadata)

      true ->
        {:noreply, hold_retry(state, issue_id, attempt, metadata, "no available orchestrator slots")}
    end
  end

  defp fetch_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_issues_by_ids([issue_id]) do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           if(state.startup_failures[issue_id], do: attempt, else: attempt + 1),
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        Operations.disposition(state.operations, Map.from_struct(issue), Config.settings!().labels.prefix)
        cleanup_issue_workspace(issue, metadata)
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(issue_or_identifier, metadata) when is_map(metadata) do
    case Map.get(metadata, :workspace_path) do
      workspace_path when is_binary(workspace_path) and workspace_path != "" ->
        Workspace.remove_recorded(workspace_path, Map.get(metadata, :worker_host))

      _ ->
        cleanup_issue_workspace(issue_or_identifier, Map.get(metadata, :worker_host))
    end
  end

  defp cleanup_issue_workspace(%Issue{} = issue, worker_host) do
    Workspace.remove_issue_workspaces(issue, worker_host)
  end

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_issue_or_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{} = issue ->
            cleanup_issue_workspace(issue)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    metadata = Map.merge(metadata, %{identifier: issue.identifier, issue_url: issue.url})

    case retry_admission(state, issue, metadata) do
      :ok -> dispatch_retry(state, issue, attempt, metadata)
      {:wait, reason} -> {:noreply, hold_retry(state, issue.id, attempt, metadata, reason)}
    end
  end

  defp retry_admission(state, issue, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]),
       do: Throttle.admit(state.throttle, retry_class(issue)),
       else: {:wait, "no available orchestrator slots"}
  end

  defp dispatch_retry(state, issue, attempt, metadata) do
    case refresh_issue_for_dispatch(issue) do
      {:ok, %Issue{} = refreshed_issue} ->
        case admit_run(state, refreshed_issue, retry_class(refreshed_issue)) do
          {:ok, state, route} ->
            {:noreply, do_dispatch_issue(state, refreshed_issue, attempt, metadata[:worker_host], route)}

          {:wait, reason} ->
            {:noreply, hold_retry(state, issue.id, attempt, metadata, reason)}
        end

      {:skip, reason} when reason in [:missing, :ci_pending] ->
        {:noreply, release_issue_claim(state, issue.id)}

      {:skip, %Issue{} = refreshed_issue} ->
        handle_retry_issue_lookup(refreshed_issue, state, issue.id, attempt, metadata)

      {:error, reason} ->
        {:noreply,
         schedule_issue_retry(
           state,
           issue.id,
           if(state.startup_failures[issue.id], do: attempt, else: attempt + 1),
           Map.put(metadata, :error, "retry dispatch refresh failed: #{inspect(reason)}")
         )}
    end
  end

  # A retry that cannot start yet (no free slot, the throttle, or a backed-off
  # route) keeps its attempt number and checks again shortly: waiting never
  # counts toward giving up on the item, and it is not logged as a new retry.
  defp hold_retry(state, issue_id, attempt, metadata, reason) do
    schedule_issue_retry(state, issue_id, attempt, Map.merge(metadata, %{delay_type: :held, error: reason}))
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt >= 0 and is_map(metadata) do
    case metadata[:delay_type] do
      :held -> @held_retry_delay_ms
      :continuation -> @continuation_retry_delay_ms
      _failure -> failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = max(0, min(attempt - 1, 10))
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_issue_url(previous_retry, metadata) do
    metadata[:issue_url] || Map.get(previous_retry, :issue_url)
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp tracker_backed_ids(entries) do
    for {issue_id, entry} <- entries, not research_entry?(entry), do: issue_id
  end

  defp research_entry?(%{issue: %Issue{} = issue}), do: not Issue.tracker_backed?(issue)
  defp research_entry?(_entry), do: false

  defp put_autopilot(%State{autopilot: autopilot} = state, autopilot), do: state

  defp put_autopilot(%State{} = state, autopilot) do
    Operations.save_autopilot_state(state.operations, autopilot)
    %{state | autopilot: autopilot}
  end

  defp finish_research(state, issue_id, running_entry, exit) do
    research = running_entry.issue.research
    autopilot = Config.settings!().autopilot
    {outcome, summary} = task_outcome(exit, running_entry, state.operations)

    Logger.info("Research run finished: issue_identifier=#{Map.get(running_entry, :identifier)} outcome=#{outcome} #{summary}")

    cleanup_issue_workspace(running_entry.issue, running_entry)

    event = if outcome in [:delivered, :unverified], do: "task_delivered", else: "task_short"
    identifier = running_entry.identifier

    details = %{
      issue_identifier: identifier,
      run_id: running_entry[:run_id],
      category: Operations.task_category(identifier),
      summary: summary
    }

    Operations.event(state.operations, event, details)

    state
    |> put_autopilot(Autopilot.record_research_finished(state.autopilot, research.channel, outcome, now(), autopilot))
    |> release_issue_claim(issue_id)
  end

  defp now, do: DateTime.utc_now()

  # What a task run produced, checked against its declared minimums: issues and
  # pull requests opened with its channel label since it started. A failed run
  # delivers nothing; a failed check leaves the run unverified.
  defp task_outcome(:failed, _running_entry, _table), do: {:failed, "run failed"}

  defp task_outcome(:normal, %{issue: %Issue{research: research} = issue} = running_entry, table) do
    label = Enum.find(issue.labels, &String.contains?(&1, ":channel:"))
    since = Map.get(running_entry, :started_at) || DateTime.utc_now()
    min_prs = (research[:pull_requests] || %{min: 0}).min

    case task_deliveries(label, since) do
      {:ok, %{issues: issues, pull_requests: prs} = deliveries} ->
        evidence = Map.merge(deliveries, %{channel_label: label, started_at: since})
        Operations.record_lineage(table, "research", running_entry[:run_id], evidence)
        summary = "#{issues} issues · #{prs} PRs"

        if issues >= research.min_issues and prs >= min_prs,
          do: {:delivered, summary},
          else: {:short, summary <> " (asked for #{research.min_issues} issues, #{min_prs} PRs)"}

      {:error, reason} ->
        {:unverified, "deliveries unchecked: #{inspect(reason)}"}
    end
  end

  defp task_deliveries(label, since) do
    cond do
      fun = Application.get_env(:symphony_elixir, :task_deliveries_fun) -> fun.(label, since)
      Config.settings!().tracker.kind == "github" -> GitHubClient.fetch_task_deliveries(label, since)
      true -> {:error, :untracked}
    end
  end

  # When the machine is idle and nothing is ready, one research channel runs at
  # a time so planners' tests, headed journeys, and measurements never overlap.
  # Idle-only tasks start when nothing else runs or waits; `anytime` tasks
  # start whenever a slot is free and no other task is running.
  defp maybe_dispatch_research(%State{} = state, issues) do
    config = Config.settings!()
    idle = state.running == %{} and not Enum.any?(issues, &work_ready?(&1, state))

    if config.autopilot.enabled and (idle or (available_slots(state) > 0 and not research_running?(state))) and
         Throttle.admit(state.throttle, :research) == :ok do
      open_issues = open_issue_count(issues, config)

      opts = [idle: idle, open_pull_requests: state.polled_issues, running: startup_held_channels(state)]

      case Autopilot.next_research(state.autopilot, config.autopilot, open_issues, DateTime.utc_now(), opts) do
        {autopilot, nil} ->
          put_autopilot(state, autopilot)

        {autopilot, item} ->
          state |> put_autopilot(autopilot) |> dispatch_issue(item)
      end
    else
      state
    end
  end

  defp work_ready?(%Issue{} = issue, %State{} = state) do
    candidate_issue?(issue, active_state_set(), terminal_state_set()) and
      not MapSet.member?(state.claimed, issue.id) and
      not Map.has_key?(state.blocked, issue.id) and
      handoff_owner?(issue, state.autopilot) and
      Startup.ready?(state.startup_failures[issue.id]) and
      Autopilot.pull_request_ready?(issue, state.autopilot, Config.settings!().autopilot)
  end

  defp open_issue_count(issues, config) do
    Enum.count(
      issues,
      &(&1.kind == :issue and Issue.has_required_labels?(&1, config.tracker.required_labels))
    )
  end

  # A research run has the project to itself (unless its exclusivity is
  # `none`): nothing else dispatches, including retries, until it finishes.
  # Under a service the Governor's share of the slots applies on top.
  defp available_slots(%State{} = state) do
    local =
      if research_running?(state) and state.throttle[:research_exclusive] != "none",
        do: 0,
        else: free_slots(state)

    case state.throttle do
      %{slots: slots} when is_integer(slots) -> min(local, slots)
      _ -> local
    end
  end

  defp research_running?(%State{running: running}),
    do: Enum.any?(running, fn {_id, entry} -> research_entry?(entry) end)

  defp free_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if GenServer.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout(), keyword()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout, opts \\ []) do
    if GenServer.whereis(server) do
      try do
        GenServer.call(server, if(opts[:history], do: {:snapshot, opts}, else: :snapshot), timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call({:thread_checkpoint, issue_id, run_id, checkpoint}, {worker, _}, state) do
    result =
      case state.running[issue_id] do
        %{run_id: ^run_id, pid: ^worker, issue: %Issue{kind: :issue}, thread_id: thread} = entry ->
          if thread == checkpoint[:thread_id] and is_nil(entry[:accounting_error]),
            do: Operations.save_checkpoint(state.operations, issue_id, checkpoint),
            else: {:error, :checkpoint_thread_unaccounted}

        _ ->
          {:error, :stale_checkpoint}
      end

    {:reply, result, state}
  end

  def handle_call(:snapshot, from, state), do: handle_call({:snapshot, []}, from, state)

  def handle_call({:snapshot, opts}, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          issue_url: metadata.issue.url,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          model: Map.get(metadata, :model),
          route: Map.get(metadata, :route),
          title: metadata.issue.title,
          labels: metadata.issue.labels,
          kind: metadata.issue.kind,
          pull_request: metadata.issue.pull_request,
          research: metadata.issue.research,
          attempt: Map.get(metadata, :retry_attempt, 0),
          item_attempt: Map.get(metadata, :item_attempt, 1),
          final_attempt: Map.get(metadata, :final_attempt, false),
          recent_events: Map.get(metadata, :recent_events, []),
          transcript: Map.get(metadata, :transcript),
          run_id: Map.get(metadata, :run_id),
          description: metadata.issue.description,
          branch_name: metadata.issue.branch_name,
          codex_cached_input_tokens: Map.get(metadata, :codex_cached_input_tokens, 0),
          codex_cache_write_input_tokens: Map.get(metadata, :codex_cache_write_input_tokens, 0),
          codex_reasoning_output_tokens: Map.get(metadata, :codex_reasoning_output_tokens, 0),
          codex_reported_total_tokens: Map.get(metadata, :codex_reported_total_tokens),
          codex_model_context_window: Map.get(metadata, :codex_model_context_window),
          codex_provenance: Map.drop(Map.get(metadata, :codex_provenance, %{}), [:run_id]),
          run_usage: Operations.run_usage(state.operations, Map.get(metadata, :run_id)),
          item_usage: Operations.item_usage(state.operations, metadata.identifier),
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          issue_url: Map.get(retry, :issue_url),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path),
          startup: state.startup_failures[issue_id] && state.startup_failures[issue_id].diagnostic,
          startup_attempt: state.startup_failures[issue_id] && state.startup_failures[issue_id].count
        }
      end)

    blocked =
      state.blocked
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: Map.get(metadata, :identifier),
          issue_url: blocked_issue_url(metadata),
          state: blocked_issue_state(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: Map.get(metadata, :session_id),
          error: Map.get(metadata, :error),
          blocked_at: Map.get(metadata, :blocked_at),
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: Map.get(metadata, :last_codex_message),
          last_codex_event: Map.get(metadata, :last_codex_event)
        }
      end)

    startup_blocked =
      for {issue_id, entry} <- state.startup_failures, entry.count >= 3, not Map.has_key?(state.running, issue_id) do
        entry
        |> Map.drop([:fingerprint, :delivery_attempt])
        |> Map.put(:issue_id, issue_id)
        |> Map.put(:startup, entry.diagnostic)
        |> Map.merge(%{state: "Startup blocked", session_id: nil, last_codex_event: nil, last_codex_message: nil, last_codex_timestamp: nil})
      end

    {:reply,
     %{
       running: running,
       retrying: retrying,
       blocked: blocked ++ startup_blocked,
       codex_totals: state.codex_totals,
       operations: Operations.snapshot(state.operations, opts),
       operations_error: state.operations_error,
       upcoming: upcoming_issues(state),
       autopilot: autopilot_snapshot(state),
       pull_requests: %{
         items: state.pull_requests,
         observed_at: state.pulls_observed_at,
         error: state.pulls_error,
         enabled: Config.settings!().tracker.kind == "github"
       },
       rate_limits: Map.get(state, :codex_rate_limits),
       quota: Map.get(state, :codex_quota),
       throttle: Map.get(state, :throttle),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    coalesced = poll_due?(state)
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  # A poll is running or already due, so another request adds nothing.
  defp poll_due?(state) do
    due_at = state.next_poll_due_at_ms

    state.poll_check_in_progress == true or
      (is_integer(due_at) and due_at <= System.monotonic_time(:millisecond))
  end

  defp autopilot_snapshot(state) do
    settings = Config.settings!().autopilot
    now = DateTime.utc_now()
    tasks = Autopilot.task_statuses(state.autopilot, settings, now)

    upcoming =
      tasks
      |> Enum.map(& &1.due_at)
      |> Enum.filter(&(DateTime.compare(&1, now) == :gt))
      |> Enum.min(DateTime, fn -> nil end)

    %{
      enabled: settings.enabled,
      channels: settings.channels |> Map.keys() |> Enum.sort(),
      open_issues: open_issue_count(state.polled_issues, Config.settings!()),
      max_open_issues: settings.max_open_issues,
      research_running: Enum.count(state.running, fn {_id, entry} -> research_entry?(entry) end),
      # Tasks due now, waiting for their turn (idle tasks wait for an idle project).
      research_pending: for(task <- tasks, DateTime.compare(task.due_at, now) != :gt, do: task.name),
      research_finished_at: Autopilot.last_finished_at(state.autopilot),
      next_research_at: upcoming,
      tasks: tasks,
      repo: repo_autopilot_status()
    }
  end

  defp repo_autopilot_status do
    status = SymphonyElixir.RepoAutopilot.status(Project.current())

    Map.put(
      status,
      :tasks_from_repo,
      Config.settings!().autopilot.channels |> Map.values() |> Enum.any?(&match?(%{"source" => "repo"}, &1))
    )
  end

  defp blocked_issue_state(%{issue: %Issue{state: state}}), do: state
  defp blocked_issue_state(_metadata), do: nil

  defp blocked_issue_url(%{issue: %Issue{url: url}}), do: url
  defp blocked_issue_url(_metadata), do: nil

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    last_reported_cached = Map.get(running_entry, :codex_last_reported_cached_input_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)
    summary = summarize_codex_update(update)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summary,
        recent_events: remember_event(Map.get(running_entry, :recent_events, []), summary, timestamp),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_cached_input_tokens: Map.get(running_entry, :codex_cached_input_tokens, 0) + token_delta.cached_input_tokens,
        codex_cache_write_input_tokens: Map.get(running_entry, :codex_cache_write_input_tokens, 0) + token_delta.cache_write_input_tokens,
        codex_reasoning_output_tokens: Map.get(running_entry, :codex_reasoning_output_tokens, 0) + token_delta.reasoning_output_tokens,
        codex_reported_total_tokens: token_delta.reported_total_tokens || Map.get(running_entry, :codex_reported_total_tokens),
        codex_model_context_window: token_delta.model_context_window || Map.get(running_entry, :codex_model_context_window),
        usage_watermark: token_delta.watermark,
        usage_source: token_delta.source,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        codex_last_reported_cached_input_tokens: max(last_reported_cached, token_delta.cached_input_reported),
        model: model_for_update(Map.get(running_entry, :model), update),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  @recent_event_limit 6
  @noisy_methods ~r/delta|tokenUsage|rateLimits|status\/changed|item\/started/

  # A short, human-readable history of what the agent did: streaming deltas and
  # token or rate-limit bookkeeping are skipped, and repeats collapse.
  defp remember_event(events, summary, timestamp) do
    if Regex.match?(@noisy_methods, to_string(codex_message_method(summary))) do
      events
    else
      text = StatusDashboard.humanize_codex_message(summary)

      case events do
        [%{text: ^text} | _] -> events
        _ -> Enum.take([%{at: timestamp, event: summary.event, text: text} | events], @recent_event_limit)
      end
    end
  end

  # Only the named orchestrator (or one given an explicit root) keeps images,
  # mirroring how operational history is opened.
  defp artifacts_root(opts) do
    cond do
      is_binary(Keyword.get(opts, :artifacts_root)) -> Keyword.fetch!(opts, :artifacts_root)
      Keyword.get(opts, :name, __MODULE__) == __MODULE__ -> Artifacts.root()
      true -> nil
    end
  end

  defp record_transcript(%State{} = state, running_entry, update) do
    maybe_capture_notification(running_entry, update)

    store_image =
      case {state.artifacts_root, Map.get(running_entry, :run_id)} do
        {root, run_id} when is_binary(root) and is_binary(run_id) ->
          &store_image(state.operations, running_entry, run_id, &1, root)

        _ ->
          nil
      end

    transcript =
      Transcript.apply(Map.get(running_entry, :transcript) || Transcript.new(), update, store_image: store_image)

    Map.put(running_entry, :transcript, transcript)
  end

  # A stored image also lands in the picture timeline, tagged with its work item.
  defp store_image(operations, running_entry, run_id, source, root) do
    with {:ok, image} <- Artifacts.store(run_id, source, root) do
      issue = Map.get(running_entry, :issue) || %{}

      Operations.record_image(operations, %{
        src: image.src,
        issue_identifier: running_entry.identifier,
        issue_url: Map.get(issue, :url),
        title: Map.get(issue, :title)
      })

      {:ok, image}
    end
  end

  @captured_methods [
    "item/started",
    "item/completed",
    "turn/plan/updated",
    "turn/diff/updated",
    "turn/completed",
    "error",
    "account/rateLimits/updated"
  ]

  # Opt-in protocol capture for building transcript support against real payloads.
  defp maybe_capture_notification(running_entry, update) do
    with directory when is_binary(directory) and directory != "" <-
           System.get_env("SYMPHONY_NOTIFICATION_CAPTURE_DIR"),
         {method, _params} when method in @captured_methods <- notification_fields(update) do
      file = "#{running_entry.identifier}-#{Map.get(running_entry, :run_id) || "run"}.jsonl"
      Transcript.capture(update, Path.join(directory, file))
    else
      _ -> :ok
    end
  end

  defp record_sample(%State{operations: nil}), do: :ok

  defp record_sample(%State{} = state) do
    upcoming = upcoming_issues(state)

    Operations.record_sample(state.operations, %{
      observed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      admission: Governor.observe(),
      running: map_size(state.running),
      ready: length(upcoming.ready),
      waiting: length(upcoming.waiting),
      attention: map_size(state.blocked) + map_size(state.retry_attempts) + map_size(state.startup_failures),
      open_prs: length(state.pull_requests),
      spend_micro: Operations.spend_today(state.operations)
    })
  end

  @artifact_sweep_interval_ms 3_600_000

  defp maybe_sweep_artifacts(%State{artifacts_root: root} = state) when is_binary(root) do
    now_ms = System.monotonic_time(:millisecond)

    if is_nil(state.artifacts_swept_ms) or now_ms - state.artifacts_swept_ms >= @artifact_sweep_interval_ms do
      active = state.running |> Map.values() |> Enum.map(&Map.get(&1, :run_id)) |> Enum.filter(&is_binary/1)
      Artifacts.sweep(active, root)
      %{state | artifacts_swept_ms: now_ms}
    else
      state
    end
  end

  defp maybe_sweep_artifacts(state), do: state

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  # Under a service the Governor owns the budget, quota and slots of every
  # project; the check-in reports this project's spend and waiting work.
  defp evaluate_throttle(%State{} = state) do
    spent = Operations.spend_today(state.operations)

    if governed?(),
      do: Governor.checkin(Project.current(), spent, demand(state)),
      else: Throttle.evaluate(Config.settings!().throttle, state.codex_quota, spent, DateTime.utc_now())
  end

  defp governed?, do: Project.current() != nil and Governor.running?()

  # Waiting work: ready items, or a research run the project would start now.
  defp demand(%State{} = state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()
    now_ms = System.monotonic_time(:millisecond)

    ready =
      Enum.count(state.polled_issues, fn issue ->
        ready_for_dispatch?(issue, state, active_states, terminal_states) or
          (candidate_issue?(issue, active_states, terminal_states) and retry_waiting?(state, issue, now_ms))
      end)

    if ready == 0 and research_wanted?(state), do: 1, else: ready
  end

  defp retry_waiting?(state, issue, now_ms) do
    case Map.get(state.retry_attempts, issue.id) do
      %{due_at_ms: due_at_ms} = retry ->
        (retry[:delay_type] == :held or due_at_ms <= now_ms) and
          dispatch_admission(state, issue, retry_class(issue)) == :ok

      _ ->
        false
    end
  end

  defp research_wanted?(%State{} = state) do
    config = Config.settings!()
    open_issues = open_issue_count(state.polled_issues, config)
    idle = state.running == %{}

    opts = [idle: idle, open_pull_requests: state.polled_issues, running: startup_held_channels(state)]
    next = Autopilot.next_research(state.autopilot, config.autopilot, open_issues, DateTime.utc_now(), opts)

    config.autopilot.enabled and not research_running?(state) and
      Throttle.admit(state.throttle, :research) == :ok and
      research_startup_ready?(next, state)
  end

  defp startup_held_channels(state) do
    for {_id, failure} <- state.startup_failures, failure[:kind] == :research and not Startup.ready?(failure), do: failure.research_channel
  end

  defp research_startup_ready?({_autopilot, %Issue{} = item}, state),
    do: Startup.ready?(state.startup_failures[item.id])

  defp research_startup_ready?(_next, _state), do: false

  # The route and a service slot are settled before a run starts; either can make it wait.
  defp admit_run(%State{} = state, %Issue{} = issue, class) do
    with :ok <- delivery_admission(state, issue),
         {:ok, route} <- routed(select_route(state, issue)),
         {:ok, state} <- acquire_slot(state, issue, class) do
      {:ok, state, route}
    end
  end

  defp delivery_admission(state, issue) do
    settings = Config.settings!().autopilot
    exhausted = settings.enabled and Autopilot.exhausted?(state.autopilot, Autopilot.delivery_key(issue), settings)
    retired = Map.get(state.autopilot, :retired_items, %{})[issue.id] == true

    if handoff_owner?(issue, state.autopilot) and not exhausted and not retired,
      do: :ok,
      else: {:wait, "canonical delivery budget unavailable"}
  end

  defp routed({:wait, _reason} = wait), do: wait
  defp routed(route), do: {:ok, route}

  defp acquire_slot(%State{} = state, %Issue{} = issue, class) do
    if governed?() do
      with :ok <- Governor.acquire(Project.current(), issue.id, class), do: {:ok, consume_slot(state)}
    else
      {:ok, state}
    end
  end

  defp consume_slot(%State{throttle: %{slots: slots} = throttle} = state) when is_integer(slots),
    do: %{state | throttle: %{throttle | slots: max(slots - 1, 0)}}

  defp consume_slot(state), do: state

  defp release_slot(issue_id) do
    if governed?(), do: Governor.release(Project.current(), issue_id), else: :ok
  end

  # Why an otherwise dispatchable item must wait: the throttle (the budget or
  # a quota pause), or a route whose model is backed off with no step allowed.
  defp dispatch_admission(%State{} = state, %Issue{} = issue) do
    dispatch_admission(state, issue, dispatch_class(state, issue))
  end

  defp dispatch_admission(state, issue, class) do
    with :ok <- Throttle.admit(state.throttle, class) do
      case select_route(state, issue) do
        {:wait, _reason} = wait -> wait
        _route -> :ok
      end
    end
  end

  defp dispatch_class(_state, %Issue{kind: :research}), do: :research
  defp dispatch_class(_state, %Issue{kind: :pull_request}), do: :pull_request

  defp dispatch_class(state, %Issue{} = issue) do
    settings = Config.settings!().autopilot

    if settings.enabled and Autopilot.final_attempt?(state.autopilot, Autopilot.delivery_key(issue), settings),
      do: :final_attempt,
      else: :issue
  end

  # A retry continues work already in flight.
  defp retry_class(%Issue{kind: :pull_request}), do: :pull_request
  defp retry_class(%Issue{}), do: :continuation

  defp select_route(%State{} = state, %Issue{} = issue) do
    settings = Config.settings!()

    fixed_routes = %{
      research: settings.autopilot.research_route,
      pull_request: settings.autopilot.review_route
    }

    item_attempt = Autopilot.failed_attempts(state.autopilot, Autopilot.delivery_key(issue)) + 1
    avoid = if is_map(state.throttle), do: state.throttle.avoid, else: %{}
    ModelRouting.select_for_run(settings.codex.routing, fixed_routes, issue, item_attempt, avoid: avoid)
  end

  defp selected_route({:ok, %{} = route}), do: route
  defp selected_route(_result), do: nil

  defp route_summary(%{} = route) do
    %{
      model: route["model"],
      effort: route["effort"],
      label: route["label"],
      tier: route["tier"],
      size: route["size"],
      backoff: route["backoff"]
    }
  end

  defp route_summary(_route), do: nil

  defp share_quota(operations, quota) do
    Operations.save_quota(operations, quota)
    if governed?(), do: Governor.report_quota(quota)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  # The raw snapshot feeds the terminal view; the normalized quota feeds the
  # dashboard and throttling and is persisted so it survives a restart.
  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        quota = Quota.normalize(rate_limits, DateTime.utc_now()) || state.codex_quota
        if quota != state.codex_quota, do: share_quota(state.operations, quota)
        %{state | codex_rate_limits: rate_limits, codex_quota: quota}

      _ ->
        state
    end
  end

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(entry, update) do
    snapshot = preferred_snapshot(entry[:usage_source], Usage.snapshot(update))

    previous =
      entry[:usage_watermark] ||
        %{
          input_tokens: Map.get(entry, :codex_last_reported_input_tokens, 0),
          output_tokens: Map.get(entry, :codex_last_reported_output_tokens, 0),
          cached_input_tokens: Map.get(entry, :codex_last_reported_cached_input_tokens, 0)
        }

    total = if snapshot, do: snapshot.total, else: previous
    {watermark, computed} = Usage.delta(previous, total)
    delta = update[:accounted_delta] || computed

    Map.merge(delta, %{
      watermark: watermark,
      source: if(snapshot, do: snapshot.source, else: entry[:usage_source]),
      reported_total_tokens: snapshot && snapshot.reported_total_tokens,
      model_context_window: snapshot && snapshot.model_context_window,
      input_reported: watermark.input_tokens,
      output_reported: watermark.output_tokens,
      total_reported: watermark.total_tokens,
      cached_input_reported: watermark.cached_input_tokens
    })
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp preferred_snapshot(:canonical, %{source: :legacy}), do: nil
  defp preferred_snapshot(_source, snapshot), do: snapshot

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    # The v2 app server names these limitId/limitName; older builds used snake_case.
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limitId") ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name) ||
        Map.get(payload, "limitName")

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp open_operations(opts, name) do
    path = Keyword.get(opts, :operations_path)

    if name == __MODULE__ or is_binary(path) do
      log_file = Application.get_env(:symphony_elixir, :log_file, SymphonyElixir.LogFile.default_log_file())
      path = path || Path.join(Path.dirname(log_file), "operations.dets")

      open_result =
        case Keyword.fetch(opts, :operations_table) do
          {:ok, table} -> Operations.open(path, table)
          :error -> Operations.open(path)
        end

      case open_result do
        {:ok, table} ->
          {table, nil}

        {:error, reason} ->
          Logger.warning("Operations history unavailable: #{inspect(reason)}")
          {nil, inspect(reason)}
      end
    else
      {nil, nil}
    end
  end

  defp maybe_sync_operations(%State{operations: nil} = state), do: state

  defp maybe_sync_operations(state) do
    now_ms = System.monotonic_time(:millisecond)

    if now_ms - state.operations_last_sync_ms >= 30_000 do
      :ok = Operations.sync(state.operations)
      %{state | operations_last_sync_ms: now_ms}
    else
      state
    end
  end

  defp maybe_fetch_pull_requests(state) do
    now_ms = System.monotonic_time(:millisecond)

    if Config.settings!().tracker.kind == "github" and not state.pulls_fetching and
         now_ms >= state.next_pulls_due_at_ms do
      retained_ids = Operations.delivery_issue_ids(state.operations) |> Enum.sort()

      issue_ids =
        Enum.take(
          Enum.drop(retained_ids, state.delivery_cursor) ++
            Enum.take(retained_ids, state.delivery_cursor),
          10
        )

      case start_pull_inventory_task(state.task_supervisor, state.pull_requests, issue_ids) do
        {:ok, pid} ->
          %{
            state
            | pulls_fetching: true,
              delivery_cursor: rem(state.delivery_cursor + 10, max(length(retained_ids), 1)),
              pulls_task_ref: Process.monitor(pid),
              next_pulls_due_at_ms: now_ms + 60_000
          }

        {:error, reason} ->
          Logger.warning("GitHub pull request inventory task failed: #{inspect(reason)}")
          %{state | pulls_error: "GitHub inventory task failed", next_pulls_due_at_ms: now_ms + 60_000}
      end
    else
      state
    end
  end

  defp start_pull_inventory_task(supervisor, previous, issue_ids) do
    recipient = self()

    Task.Supervisor.start_child(supervisor, fn ->
      send(recipient, {:pull_requests_fetched, fetch_pull_inventory(previous, issue_ids)})
    end)
  end

  defp fetch_pull_inventory(previous, issue_ids) do
    client = Application.get_env(:symphony_elixir, :github_client_module, GitHubClient)

    if function_exported?(client, :fetch_open_pull_requests, 0),
      do: fetch_pulls_with_deliveries(client, previous, issue_ids),
      else: {:error, :pull_request_inventory_unavailable}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp fetch_pulls_with_deliveries(client, previous, issue_ids) do
    with {:ok, pulls, statuses} <- fetch_pulls_with_statuses(client, previous) do
      deliveries =
        if function_exported?(client, :fetch_delivery_observation, 1) do
          Enum.flat_map(issue_ids, &fetch_delivery(client, &1))
        else
          []
        end

      {:ok, pulls, statuses, deliveries}
    end
  end

  defp fetch_delivery(client, id) do
    case client.fetch_delivery_observation(id) do
      {:ok, %{issue: %Issue{}} = observation} -> [observation]
      _ -> []
    end
  end

  defp fetch_pulls_with_statuses(client, previous) do
    case client.fetch_open_pull_requests() do
      {:ok, pulls} ->
        current_numbers = MapSet.new(pulls, & &1.number)

        statuses =
          previous
          |> Enum.reject(&MapSet.member?(current_numbers, &1.number))
          |> Map.new(&{&1.number, pull_status(client, &1.number)})

        {:ok, pulls, statuses}

      error ->
        error
    end
  end

  defp pull_status(client, number) do
    if function_exported?(client, :fetch_pull_observation, 1) do
      case client.fetch_pull_observation(number) do
        {:ok, observation} -> observation
        _ -> "left open list"
      end
    else
      legacy_pull_status(client, number)
    end
  end

  defp legacy_pull_status(client, number) do
    if function_exported?(client, :fetch_pull_status, 1) do
      case client.fetch_pull_status(number) do
        {:ok, value} -> value
        _ -> "left open list"
      end
    else
      "left open list"
    end
  end

  defp record_pull_changes(_table, _previous, _current, nil, _statuses), do: :ok

  defp record_pull_changes(table, previous, current, _observed_at, statuses) do
    before = Map.new(previous, &{&1.number, &1})
    after_pulls = Map.new(current, &{&1.number, &1})

    Enum.each(current, fn pull ->
      kind = pull_change_kind(Map.get(before, pull.number), pull)

      if kind,
        do: Operations.event(table, kind, %{pr_number: pull.number, pr_url: pull.url, summary: pull.title})
    end)

    previous
    |> Enum.reject(&Map.has_key?(after_pulls, &1.number))
    |> Enum.each(fn pull ->
      status = Map.get(statuses, pull.number)

      if is_map(status),
        do: Operations.record_lineage(table, "pull_request", {pull.number, status[:head_sha]}, status)

      kind = pull_departure_kind(if(is_map(status), do: status[:status], else: status))
      Operations.event(table, kind, %{pr_number: pull.number, pr_url: pull.url, summary: pull.title})
    end)
  end

  defp pull_change_kind(nil, _pull), do: "pr_opened"
  defp pull_change_kind(%{draft: true}, %{draft: false}), do: "pr_ready_for_review"
  defp pull_change_kind(%{draft: false}, %{draft: true}), do: "pr_drafted"
  defp pull_change_kind(_, _), do: nil

  defp pull_departure_kind("merged"), do: "pr_merged"
  defp pull_departure_kind("closed"), do: "pr_closed"
  defp pull_departure_kind(_), do: "pr_left_open_list"

  defp upcoming_issues(state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    entries =
      state.polled_issues
      |> Enum.filter(fn issue ->
        active_issue_state?(issue.state, active_states) and
          not terminal_issue_state?(issue.state, terminal_states)
      end)
      |> Enum.reject(&Map.has_key?(state.running, &1.id))
      |> Enum.map(fn issue ->
        reason = upcoming_reason(state, issue, active_states, terminal_states)

        %{
          issue_identifier: issue.identifier,
          title: issue.title,
          issue_url: issue.url,
          priority: issue.priority,
          reason: reason,
          blocked_by: Enum.map(issue.blocked_by, &Map.get(&1, :identifier))
        }
      end)

    %{
      ready: Enum.filter(entries, &is_nil(&1.reason)),
      waiting: Enum.reject(entries, &is_nil(&1.reason)),
      observed_at: state.issues_observed_at,
      error: state.issues_error,
      available_slots: available_slots(state)
    }
  end

  defp upcoming_reason(state, issue, active_states, terminal_states) do
    cond do
      reason = startup_blocking_reason(state, issue) -> reason
      Map.has_key?(state.retry_attempts, issue.id) -> "retry scheduled"
      reason = item_waiting_reason(issue, state) -> reason
      issue.blocked_by != [] and not issue.dispatchable -> "dependency blocked"
      MapSet.member?(state.claimed, issue.id) -> "continuation pending"
      not candidate_issue?(issue, active_states, terminal_states) -> "not queued"
      true -> admission_reason(state, issue)
    end
  end

  defp startup_blocking_reason(state, issue) do
    cond do
      Map.has_key?(state.blocked, issue.id) -> "operator blocked"
      not Startup.ready?(state.startup_failures[issue.id]) -> "startup admission blocked"
      true -> nil
    end
  end

  defp admission_reason(state, issue) do
    case dispatch_admission(state, issue) do
      {:wait, reason} -> reason
      :ok -> nil
    end
  end

  defp item_waiting_reason(issue, state) do
    config = Config.settings!()

    cond do
      label = Issue.excluded_label(issue, config.tracker.excluded_labels) -> "excluded by #{label}"
      reason = pull_request_admission_reason(issue) -> reason
      true -> Autopilot.pull_request_waiting_reason(issue, state.autopilot, config.autopilot)
    end
  end

  defp pull_request_admission_reason(%Issue{
         kind: :pull_request,
         dispatchable: false,
         pull_request: %{draft: true}
       }),
       do: "draft"

  defp pull_request_admission_reason(%Issue{
         kind: :pull_request,
         dispatchable: false,
         pull_request: %{trusted: false}
       }),
       do: "awaiting maintainer label"

  defp pull_request_admission_reason(_issue), do: nil

  defp maybe_record_turn_event(table, entry, update) do
    {method, params} = notification_fields(update)

    status =
      case params do
        %{"turn" => %{"status" => status}} -> status
        _ -> nil
      end

    if update[:event] == :turn_completed or (method == "turn/completed" and status == "completed") do
      Operations.event(table, "turn_completed", %{
        issue_identifier: entry.identifier,
        issue_url: entry.issue.url,
        model: Map.get(entry, :model),
        run_id: entry[:run_id],
        reviewed_head: if(entry.issue.kind == :pull_request, do: entry[:dispatched_head]),
        summary: "Codex turn completed"
      })

      Operations.sync(table)
    end

    if method == "model/rerouted" do
      Operations.event(table, "model_rerouted", %{
        issue_identifier: entry.identifier,
        issue_url: entry.issue.url,
        model: entry.model,
        summary: "Codex rerouted this run"
      })
    end
  end

  defp model_for_update(existing, update) do
    case notification_fields(update) do
      {"model/rerouted", params} when is_map(params) ->
        case Map.get(params, "toModel") || Map.get(params, :toModel) do
          model when is_binary(model) -> model
          _ -> existing
        end

      _ ->
        update[:model] || existing
    end
  end

  defp notification_fields(%{payload: payload}) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)
    params = Map.get(payload, "params") || Map.get(payload, :params)
    {method, params}
  end

  defp notification_fields(_update), do: {nil, nil}

  defp safe_pull_error({:github_api_status, status}) when is_integer(status), do: "GitHub HTTP #{status}"
  defp safe_pull_error(_), do: "GitHub fetch failed"
end
