defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Governor, ModelRouting, Project, PromptBuilder, QuietContinuation, SmartassMode}
  alias SymphonyElixir.{Startup, Tracker, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, {:gain_policy_hold, _budget}} ->
        exit({:shutdown, :gain_policy_hold})

      {:error, :smartass_required} ->
        exit({:shutdown, :model_policy_hold})

      {:yield, :deployment_drain} ->
        exit({:shutdown, :deployment_drain})

      {:yield, :quiet_acceptance} ->
        exit({:shutdown, :quiet_acceptance})

      {:error, {:startup_failed, diagnostic} = reason} ->
        send_worker_message(codex_update_recipient, issue, :worker_startup_failure, diagnostic, opts)
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"

      {:error, {:protocol_buffer_overflow, diagnostic}} ->
        exit({:shutdown, {:protocol_buffer_overflow, diagnostic}})

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case startup_step(:workspace, fn -> Workspace.create_for_issue(issue, worker_host) end) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace, opts)

        try do
          before_run = fn -> Workspace.run_before_run_hook(workspace, issue, worker_host) end

          with :ok <- startup_step(:before_run, before_run) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          send_worker_phase(codex_update_recipient, issue, :cleanup)
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp startup_step(phase, fun) do
    case fun.() do
      {:error, :smartass_required} = hold -> hold
      {:error, reason} -> {:error, {:startup_failed, Startup.diagnostic(phase, reason)}}
      result -> result
    end
  end

  defp send_worker_phase(recipient, %Issue{id: issue_id}, phase) when is_pid(recipient) do
    send(recipient, {:worker_phase, issue_id, self(), phase})
    :ok
  end

  defp send_worker_phase(_recipient, _issue, _phase), do: :ok

  defp codex_message_handler(recipient, issue, opts) do
    fn message ->
      send_worker_message(recipient, issue, :codex_worker_update, message, opts)
    end
  end

  defp send_worker_message(recipient, %Issue{id: issue_id}, type, message, opts)
       when is_binary(issue_id) and is_pid(recipient) do
    case Keyword.get(opts, :run_id) do
      nil -> send(recipient, {type, issue_id, message})
      run_id -> send(recipient, {type, issue_id, run_id, message})
    end

    :ok
  end

  defp send_worker_message(_recipient, _issue, _type, _message, _opts), do: :ok

  defp send_worker_runtime_info(recipient, issue, worker_host, workspace, opts) do
    send_worker_message(
      recipient,
      issue,
      :worker_runtime_info,
      %{worker_host: worker_host, workspace_path: workspace},
      opts
    )
  end

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    send_worker_phase(codex_update_recipient, issue, :codex)
    continuation = opts[:gain_continuation] || %{}
    max_turns = continuation[:max_turns] || Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    first_turn = continuation[:next_turn] || 1
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)

    codex = Keyword.get(opts, :codex_settings, Config.settings!().codex)
    opts = revalidate_quiet_continuation(opts, workspace)
    opts = Keyword.put(opts, :quiet_continuation_available, QuietContinuation.available?(%{kind: issue.kind, recipient: codex_update_recipient, run_id: opts[:run_id], worker_host: worker_host}))
    prompt = PromptBuilder.build_prompt(issue, opts)
    opts = Keyword.merge(opts, initial_prompt: prompt, codex_settings: codex)
    on_message = codex_message_handler(codex_update_recipient, issue, opts)

    session_opts = [
      worker_host: worker_host,
      work_item: issue.identifier,
      run_id: Keyword.get(opts, :run_id),
      kind: issue.kind,
      codex_settings: codex,
      checkpoint: Keyword.get(opts, :checkpoint),
      contract_hash: contract_hash(issue, opts),
      on_message: on_message,
      helper_context: %{
        run_id: Keyword.get(opts, :run_id),
        kind: issue.kind,
        project: SymphonyElixir.Project.current(),
        issue_id: issue.id,
        identifier: issue.identifier,
        workspace: workspace,
        recipient: codex_update_recipient,
        codex_settings: codex,
        worker_host: worker_host
      }
    ]

    opts = Keyword.put(opts, :gain_session_opts, session_opts)

    with {:ok, route} <- startup_step(:session_start, fn -> adaptive_route(workspace, issue, opts, session_opts) end),
         :ok <- log_route(issue, route),
         :ok <- send_worker_message(codex_update_recipient, issue, :worker_model_route, route, opts),
         {:ok, session} <-
           startup_step(:session_start, fn ->
             start_session(workspace, route, session_opts)
           end) do
      send_worker_message(codex_update_recipient, issue, :worker_admitted, %{}, opts)

      Process.put(:gain_sessions, [session])

      try do
        do_run_codex_turns(
          session,
          workspace,
          issue,
          codex_update_recipient,
          Keyword.put(opts, :resumed, session.resumed),
          issue_state_fetcher,
          first_turn,
          max_turns
        )
      after
        try do
          current = List.first(Process.get(:gain_sessions, [session]))
          if Port.info(current.port), do: AppServer.read_account_usage(current, on_message: on_message)
        after
          Enum.each(Process.delete(:gain_sessions) || [session], &AppServer.stop_session/1)
          SymphonyElixir.Helpers.cancel_owned()
        end
      end
    end
  end

  defp adaptive_route(workspace, issue, opts, session_opts) do
    runtime = Path.join(workspace, "tools/symphony-codex.py")
    compatible = not File.regular?(runtime) or String.contains?(File.read!(runtime), "GAIN_PROTOCOL = 1")

    if SymphonyElixir.IntelligencePolicy.enabled?() and not compatible do
      {:error, :workspace_routing_protocol_outdated}
    else
      adaptive_host_route(issue, opts, session_opts)
    end
  end

  defp adaptive_host_route(issue, opts, session_opts) do
    cond do
      not SymphonyElixir.IntelligencePolicy.enabled?() -> model_route(issue, opts)
      is_binary(session_opts[:worker_host]) -> {:error, :remote_intelligence_policy_unavailable}
      true -> gain_route_for_issue(issue, opts, session_opts)
    end
  end

  defp gain_route_for_issue(issue, opts, session_opts) do
    alias SymphonyElixir.IntelligencePolicy

    role =
      case issue.kind do
        :research -> "scorecard"
        :pull_request -> "reviewer"
        _ -> "delivery"
      end

    identity = {Project.current(), issue.identifier}

    with {:ok, profile} <- task_profile(issue, role, opts, session_opts),
         contract = IntelligencePolicy.digest({issue.title, issue.description}),
         {:ok, profile} <- baseline_hints(Map.put(profile, "contract", contract), issue),
         feedback = difficulty_feedback(opts, issue, profile),
         {:ok, route} <- IntelligencePolicy.resolve(profile, role, identity, feedback: feedback) do
      {:ok, Map.put(route, "size", legacy_size(issue))}
    end
  end

  defp task_profile(issue, role, opts, session_opts) do
    alias SymphonyElixir.{IntelligencePolicy, Operations}

    case IntelligencePolicy.profile(issue) do
      %{} = profile -> {:ok, profile}
      nil when role == "scorecard" -> {:ok, IntelligencePolicy.role_profile(role)}
      nil -> Operations.routing_profile(issue, fn -> classify_profile(issue, opts, session_opts) end)
    end
  end

  defp classify_profile(issue, opts, session_opts) do
    alias SymphonyElixir.{Helpers, IntelligencePolicy}

    identity = {Project.current(), issue.identifier}
    profile = IntelligencePolicy.role_profile("classifier")

    with {:ok, route} <- IntelligencePolicy.resolve(profile, "classifier", identity),
         context = Map.put(session_opts[:helper_context], :resolved_route, route),
         {:ok, prepared} <- Helpers.prepare(context, %{"question" => classification_question()}),
         prepared = add_task_contract(prepared, issue),
         settings = %SymphonyElixir.Service.Helpers{model: route["model"], effort: route["effort"], timeout_ms: 120_000},
         {:ok, result} <- run_classifier(prepared, classification_details(issue, opts, route, prepared), settings),
         {:ok, profile} when is_map(profile) <- Jason.decode(String.trim(result.summary) |> String.replace(~r/\A```(?:json)?\s*|\s*```\z/, "")) do
      {:ok, Map.put(Map.take(profile, ~w(complexity risk reason evidence_refs)), "source_sha", result.source_sha)}
    else
      {:ok, _} -> {:error, :classification_not_an_object}
      error -> error
    end
  end

  defp classification_question do
    "Classify cognitive complexity and risk, not line count or priority. Read evidence ID task-contract for full title and acceptance; " <>
      "inspect source owners as needed. Return ONLY JSON: complexity (routine,standard,complex,exceptional), risk (low,normal,high), " <>
      "reason (named mental coupling/uncertainty for complex/exceptional), evidence_refs (source locations)."
  end

  defp add_task_contract(prepared, issue) do
    contract = "Task: " <> issue.title <> "\n" <> (issue.description || "")
    evidence = %{content: contract, digest: SymphonyElixir.IntelligencePolicy.digest(contract)}
    %{prepared | evidence: Map.put(prepared.evidence, "task-contract", evidence)}
  end

  defp classification_details(issue, opts, route, prepared) do
    id = "classifier-" <> SymphonyElixir.IntelligencePolicy.digest({issue.id, opts[:run_id]})

    %{
      run_id: id,
      issue_id: id,
      issue_identifier: id,
      model: route["model"],
      effort: route["effort"],
      role: "classifier",
      routing_decision: route,
      parent_run_id: opts[:run_id],
      parent_issue_id: issue.id,
      project: Project.current(),
      source_sha: prepared.source_sha
    }
  end

  defp run_classifier(prepared, details, settings) do
    started = DateTime.utc_now()
    recipient = prepared.context[:recipient]
    if is_pid(recipient), do: send(recipient, {:helper_update, details, %{event: :helper_started, timestamp: started}})

    task = Task.async(fn -> classifier_result(prepared, details, settings) end)

    result =
      case Task.yield(task, settings.timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, value} -> value
        _ -> {:error, :classification_timeout}
      end

    if is_pid(recipient),
      do:
        send(
          recipient,
          {:helper_update, details,
           %{
             event: :helper_finished,
             timestamp: DateTime.utc_now(),
             status: if(match?({:ok, _}, result), do: "completed", else: "failed"),
             reason: if(match?({:ok, _}, result), do: nil, else: inspect(result))
           }}
        )

    result
  end

  defp classifier_result(prepared, details, settings) do
    SymphonyElixir.Helpers.run(prepared, details, settings)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp baseline_hints(profile, issue) do
    case ModelRouting.select(Config.settings!().codex.routing, issue) do
      {:ok, %{"label" => label} = hint} when label != "default" ->
        prefix = Config.settings!().codex.routing["label_prefix"]
        profile = Map.put(profile, "legacy_label", label)
        if String.starts_with?(label, prefix), do: {:ok, Map.put(profile, "baseline", Map.take(hint, ["model", "effort"]))}, else: {:ok, profile}

      {:ok, _} ->
        {:ok, profile}

      error ->
        error
    end
  end

  defp difficulty_feedback(opts, issue, profile) do
    case get_in(opts[:gain_session_opts] || [], [:helper_context, :recipient]) do
      pid when is_pid(pid) -> GenServer.call(pid, {:routing_feedback, issue.id, profile["contract"]}, 2_000)
      _ -> %{}
    end
  catch
    :exit, _ -> %{}
  end

  defp legacy_size(issue) do
    prefix = Config.settings!().labels.prefix <> ":size:"

    Enum.find_value(Issue.label_names(issue), fn label ->
      if String.starts_with?(label, prefix), do: String.replace_prefix(label, prefix, "")
    end)
  end

  defp boundary_session(session, workspace, issue, opts) do
    adaptive = SymphonyElixir.IntelligencePolicy.enabled?() and get_in(session, [:model_route, "profile"])
    if adaptive, do: resolve_boundary(session, workspace, issue, opts), else: {:ok, session}
  end

  defp resolve_boundary(session, workspace, issue, opts) do
    old = session.model_route

    feedback = difficulty_feedback(opts, issue, old["profile"])

    with {:ok, route} <- SymphonyElixir.IntelligencePolicy.resolve(old["profile"], old["role"], old["identity"], feedback: feedback),
         :ok <- SymphonyElixir.IntelligencePolicy.admit_native(route) do
      apply_boundary(session, Map.merge(route, Map.take(old, ["label", "size"])), workspace, issue, opts)
    else
      {:error, reason} -> wait_policy_boundary(session, workspace, issue, opts, reason)
    end
  end

  defp wait_policy_boundary(session, workspace, issue, opts, reason) do
    now = System.monotonic_time(:millisecond)
    deadline = opts[:policy_deadline]
    wait_limit = if reason == :background_jobs_running, do: deadline, else: min(deadline, now + 30_000)
    opts = Keyword.put_new(opts, :wait_deadline, wait_limit)

    cond do
      is_nil(Port.info(session.port)) ->
        {:error, :port_closed}

      System.monotonic_time(:millisecond) >= opts[:wait_deadline] and AppServer.quiescent?(session) ->
        deadline_at = System.system_time(:millisecond) + opts[:wait_deadline] - System.monotonic_time(:millisecond)

        budget = %{
          next_turn: opts[:logical_turn],
          max_turns: opts[:logical_max],
          item_attempt: opts[:item_attempt] || 1,
          contract: SymphonyElixir.IntelligencePolicy.digest({issue.title, issue.description}),
          reason: inspect(reason),
          final_attempt: opts[:final_attempt] || false,
          wait_deadline_at: deadline_at
        }

        acknowledge_gain_hold(issue, opts, budget)

      System.monotonic_time(:millisecond) >= opts[:policy_deadline] ->
        {:error, :background_job_deadline_exceeded}

      true ->
        # Status is separate from native progress; this wait keeps its original absolute deadline.
        send_worker_phase(opts[:gain_session_opts][:helper_context][:recipient], issue, :policy_boundary)
        AppServer.wait_background(session)
        boundary_session(session, workspace, issue, opts)
    end
  end

  defp acknowledge_gain_hold(issue, opts, budget) do
    recipient = opts[:gain_session_opts][:helper_context][:recipient]

    if is_pid(recipient) do
      case GenServer.call(recipient, {:hold_gain_run, issue.id, opts[:run_id], budget}) do
        :ok -> {:error, {:gain_policy_hold, budget}}
        {:error, _} = error -> error
      end
    else
      {:error, {:gain_policy_hold, budget}}
    end
  end

  defp apply_boundary(session, route, workspace, issue, opts) do
    cond do
      is_nil(Port.info(session.port)) ->
        {:error, :port_closed}

      route["model"] == session.model_route["model"] ->
        {:ok, %{session | model_route: route}}

      is_binary(session.worker_host) ->
        {:error, :remote_policy_boundary_unavailable}

      not AppServer.quiescent?(session) ->
        wait_policy_boundary(session, workspace, issue, opts, :background_jobs_running)

      true ->
        swap_session(session, route, workspace, issue, opts)
    end
  end

  defp swap_session(session, route, workspace, issue, opts) do
    handoff =
      "Resume the same task from the workspace, workpad, PR and evidence. Preserve acceptance, attempts and deadlines. " <> issue.identifier <> ": " <> issue.title <> "\n" <> (issue.description || "")

    startup = Keyword.put(opts[:gain_session_opts], :checkpoint, nil)

    AppServer.read_account_usage(session, on_message: opts[:on_message])

    case start_session(workspace, route, startup) do
      {:ok, replacement} ->
        Process.put(:gain_sessions, [replacement | Process.get(:gain_sessions, [])])
        AppServer.stop_session(session)
        {:ok, Map.put(replacement, :gain_handoff, handoff)}

      {:error, reason} ->
        wait_policy_boundary(session, workspace, issue, opts, {:replacement_startup, reason})
    end
  end

  defp policy_deadline(opts), do: System.monotonic_time(:millisecond) + opts[:codex_settings].turn_timeout_ms

  defp boundary_prompt(session, issue, opts, turn, max_turns) do
    if session[:gain_handoff] || opts[:gain_continuation] do
      context = session[:gain_handoff] || "Resume #{issue.identifier}: #{issue.title}\n#{issue.description}"
      opts[:initial_prompt] <> "\n\n" <> context <> "\nLogical turn #{turn} of #{max_turns}; do not reset budgets."
    else
      build_turn_prompt(issue, opts, turn, max_turns)
    end
  end

  defp contract_hash(issue, opts) do
    # Transport retry counters and tracker timestamps are not the task contract.
    # Template/source changes, task content, routing labels and bindings are.
    contract =
      {SymphonyElixir.Workflow.current(), Config.settings!().tracker, Map.take(Map.from_struct(issue), [:id, :identifier, :title, :description, :labels, :kind, :branch_name]),
       Keyword.get(opts, :item_attempt, 1), Keyword.get(opts, :final_attempt, false)}

    :crypto.hash(:sha256, :erlang.term_to_binary(contract)) |> Base.encode16(case: :lower)
  end

  # The orchestrator selects the route at dispatch (with quota back-off);
  # direct callers get the plain label route.
  defp model_route(issue, opts) do
    case Keyword.get_lazy(opts, :model_route, fn ->
           select_route(issue, Keyword.get(opts, :item_attempt, 1))
         end) do
      {:wait, reason} -> {:error, {:model_route_waiting, reason}}
      {:ok, route} -> with :ok <- SmartassMode.admit_route(route), do: {:ok, route}
      result -> result
    end
  end

  defp select_route(issue, item_attempt) do
    settings = Config.settings!()

    fixed_routes = %{
      research: settings.autopilot.research_route,
      pull_request: settings.autopilot.review_route
    }

    ModelRouting.select_for_run(settings.codex.routing, fixed_routes, issue, item_attempt)
  end

  defp log_route(_issue, nil), do: :ok

  defp log_route(issue, route) do
    backoff =
      if route["backoff"],
        do: " backed_off_from=#{route["backoff"]["from"]} reason=#{route["backoff"]["reason"]}",
        else: ""

    Logger.info("Selected model route for #{issue_context(issue)} label=#{route["label"]} model=#{route["model"]} effort=#{route["effort"]} tier=#{route["tier"] || "none"}#{backoff}")
  end

  defp start_session(workspace, route, opts) do
    codex = opts[:codex_settings]

    model = (route || %{})["model"]

    session =
      cond do
        SymphonyElixir.Helpers.enabled?() -> SymphonyElixir.Helpers.lead_session(codex, model)
        Project.current() != nil -> {:ok, codex, %{"features.multi_agent" => false, "features.multi_agent_v2" => false, "agents.max_threads" => 1}}
        true -> {:ok, codex, nil}
      end

    with {:ok, codex, config} <- session do
      options = [model_route: route, thread_config: config, codex_settings: codex]
      AppServer.start_session(workspace, options ++ opts)
    end
  end

  defp do_run_codex_turns(
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns
       ) do
    opts = opts |> Keyword.put(:logical_turn, turn_number) |> Keyword.put(:logical_max, max_turns)
    opts = Keyword.put_new_lazy(opts, :policy_deadline, fn -> policy_deadline(opts) end)

    with {:ok, app_session} <- boundary_session(app_session, workspace, issue, Keyword.put(opts, :on_message, codex_message_handler(codex_update_recipient, issue, opts))),
         prompt = boundary_prompt(app_session, issue, opts, turn_number, max_turns),
         app_session = Map.delete(app_session, :gain_handoff),
         opts = opts |> Keyword.delete(:gain_continuation) |> Keyword.delete(:wait_deadline) |> Keyword.put(:policy_deadline, policy_deadline(opts)),
         :ok <- send_worker_phase(codex_update_recipient, issue, :codex),
         :ok <- send_worker_message(codex_update_recipient, issue, :worker_model_route, app_session.model_route, opts),
         :ok <- SmartassMode.admit_route(app_session.model_route),
         :ok <- SmartassMode.admit_effective(app_session.model_route, app_session.metadata[:model]),
         :ok <- persist_checkpoint(app_session, issue, codex_update_recipient, opts, %{eligible: false}),
         {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue, opts)
           ),
         :ok <- persist_completed_checkpoint(app_session, turn_session, issue, codex_update_recipient, opts) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continuation_at_boundary(issue, issue_state_fetcher, codex_update_recipient, opts) do
        :quiet_acceptance ->
          {:yield, :quiet_acceptance}

        {:yield, refreshed_issue} ->
          Logger.info("Yielding agent run for #{issue_context(refreshed_issue)} session_id=#{turn_session[:session_id]} reason=deployment_drain turn=#{turn_number}/#{max_turns}")
          {:yield, :deployment_drain}

        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp continuation_at_boundary(issue, issue_state_fetcher, recipient, opts) do
    run_id = Keyword.get(opts, :run_id)

    if Keyword.get(opts, :quiet_continuation_available, false) and
         GenServer.call(recipient, {:quiet_deferred?, issue.id, run_id}),
       do: :quiet_acceptance,
       else: active_continuation_at_boundary(issue, issue_state_fetcher)
  end

  defp active_continuation_at_boundary(issue, issue_state_fetcher) do
    with {:continue, refreshed_issue} <- continue_with_issue?(issue, issue_state_fetcher) do
      if Project.current() != nil and Governor.draining?(),
        do: {:yield, refreshed_issue},
        else: {:continue, refreshed_issue}
    end
  end

  defp revalidate_quiet_continuation(opts, workspace) do
    case Keyword.get(opts, :quiet_continuation) do
      nil -> opts
      prepared -> Keyword.put(opts, :quiet_continuation, QuietContinuation.revalidate(prepared, workspace))
    end
  end

  defp build_turn_prompt(issue, opts, 1, max_turns) do
    if Keyword.get(opts, :resumed, false),
      do: continuation_prompt(1, max_turns),
      else: Keyword.get_lazy(opts, :initial_prompt, fn -> PromptBuilder.build_prompt(issue, opts) end)
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    continuation_prompt(turn_number, max_turns)
  end

  defp continuation_prompt(turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp persist_completed_checkpoint(session, turn, issue, recipient, opts) do
    checkpoint =
      if Keyword.fetch!(opts, :codex_settings).resume_threads and issue.kind == :issue,
        do:
          AppServer.checkpoint(
            session,
            turn,
            Keyword.put(opts, :on_message, codex_message_handler(recipient, issue, opts))
          )

    case checkpoint do
      {:error, _} = error -> error
      _ -> persist_checkpoint(session, issue, recipient, opts, checkpoint || %{eligible: false})
    end
  end

  defp persist_checkpoint(session, issue, recipient, opts, checkpoint) do
    if Keyword.fetch!(opts, :codex_settings).resume_threads and issue.kind == :issue do
      run_id = Keyword.get(opts, :run_id)

      if is_pid(recipient) and is_binary(run_id) do
        checkpoint =
          Map.merge(checkpoint, %{
            run_id: run_id,
            thread_id: session.thread_id,
            thread_key: session.metadata.thread_key
          })

        GenServer.call(recipient, {:thread_checkpoint, issue.id, run_id, checkpoint})
      else
        {:error, :checkpoint_owner_unavailable}
      end
    else
      :ok
    end
  end

  # Pull request reviews and research runs are single passes; only tracker
  # issues continue while they stay active.
  defp continue_with_issue?(%Issue{kind: kind} = issue, _issue_state_fetcher) when kind != :issue,
    do: {:done, issue}

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    tracker = Config.settings!().tracker
    Issue.routable?(issue, tracker.required_labels, tracker.excluded_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
