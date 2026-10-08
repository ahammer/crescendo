defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Governor, ModelRouting, Project, PromptBuilder, Startup, Tracker, Workspace}
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

      {:yield, :deployment_drain} ->
        exit({:shutdown, :deployment_drain})

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
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)

    codex = Keyword.get(opts, :codex_settings, Config.settings!().codex)
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
        project: SymphonyElixir.Project.current(),
        issue_id: issue.id,
        identifier: issue.identifier,
        workspace: workspace,
        recipient: codex_update_recipient,
        codex_settings: codex,
        worker_host: worker_host
      }
    ]

    with {:ok, route} <- model_route(issue, opts),
         :ok <- log_route(issue, route),
         :ok <- send_worker_message(codex_update_recipient, issue, :worker_model_route, route, opts),
         {:ok, session} <-
           startup_step(:session_start, fn ->
             start_session(workspace, route, session_opts)
           end) do
      send_worker_message(codex_update_recipient, issue, :worker_admitted, %{}, opts)

      try do
        do_run_codex_turns(
          session,
          workspace,
          issue,
          codex_update_recipient,
          Keyword.put(opts, :resumed, session.resumed),
          issue_state_fetcher,
          1,
          max_turns
        )
      after
        try do
          AppServer.read_account_usage(session, on_message: on_message)
        after
          AppServer.stop_session(session)
          SymphonyElixir.Helpers.cancel_owned()
        end
      end
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
      case SymphonyElixir.Helpers.enabled?() do
        true -> SymphonyElixir.Helpers.lead_session(codex, model)
        false -> {:ok, codex, nil}
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
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with :ok <- persist_checkpoint(app_session, issue, codex_update_recipient, opts, %{eligible: false}),
         {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue, opts)
           ),
         :ok <- persist_completed_checkpoint(app_session, turn_session, issue, codex_update_recipient, opts) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continuation_at_boundary(issue, issue_state_fetcher) do
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

  defp continuation_at_boundary(issue, issue_state_fetcher) do
    with {:continue, refreshed_issue} <- continue_with_issue?(issue, issue_state_fetcher) do
      if Project.current() != nil and Governor.draining?(),
        do: {:yield, refreshed_issue},
        else: {:continue, refreshed_issue}
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
