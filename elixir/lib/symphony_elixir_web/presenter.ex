defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Governor, Operations, Orchestrator, Project, Projects, Quota, Service}
  alias SymphonyElixir.{SourceRevision, StatusDashboard, Transcript, Workspace}
  alias SymphonyElixirWeb.{Redaction, ServiceSnapshot}

  # Quota older than this is shown as stale (throttling settings refine it).
  @quota_stale_ms 7_200_000

  @doc """
  The dashboard and `/api/v1/state` projection. Running entries carry a light
  workspace summary; `transcripts: true` adds every running agent's full
  transcript, and `transcripts: identifier` adds only that agent's (the agent
  inspector needs one; the state API serves transcripts per item instead).
  """
  @spec state_payload(GenServer.name(), timeout(), keyword()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms, opts \\ []) do
    now = DateTime.utc_now()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms, opts) do
      %{} = snapshot ->
        build(snapshot, settings(), runtime_context(), now, opts)

      :timeout ->
        %{
          generated_at: generated_at(now),
          service: SourceRevision.metadata(),
          error: %{code: "snapshot_timeout", message: "Snapshot timed out"}
        }

      :unavailable ->
        %{
          generated_at: generated_at(now),
          service: SourceRevision.metadata(),
          error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}
        }
    end
  end

  @doc """
  The dashboard and state API payload wherever it runs: the single-workflow
  runtime's orchestrator (`orchestrator:`), or under a service every project
  merged, or only `project:`, with the service's projects for filtering.
  """
  @spec payload(keyword()) :: map()
  def payload(opts) do
    case Service.current() do
      nil -> state_payload(Keyword.fetch!(opts, :orchestrator), Keyword.fetch!(opts, :timeout), opts)
      service -> service_payload(service, opts)
    end
  end

  defp service_payload(service, opts) do
    now = DateTime.utc_now()
    ids = service |> Service.projects() |> Enum.map(& &1.id)
    project = if opts[:project] in ids, do: opts[:project]
    selected = if project, do: [project], else: ids
    snapshots = for id <- selected, do: {id, project_snapshot(id, Keyword.fetch!(opts, :timeout), opts)}
    governor = if Governor.running?(), do: Governor.snapshot()

    snapshots
    |> ServiceSnapshot.merge(governor, opts)
    |> build(service_settings(service, selected, project), service_runtime(selected, project), now, opts)
    |> Map.merge(%{project: project, projects: project_list(service, snapshots)})
    |> Redaction.payload(redacted(service))
  end

  # Private projects' work stays off the public dashboard and API.
  defp redacted(service), do: for(project <- Service.projects(service), project.redact, into: MapSet.new(), do: project.id)

  defp project_snapshot(id, timeout, opts),
    do: Project.with_project(id, fn -> Orchestrator.snapshot(Project.via(id, :orchestrator), timeout, opts) end)

  # A service view of the settings: its slots (or one project's share), budget and pricing.
  defp service_settings(service, [first | _], project) do
    case Project.with_project(first, &Config.settings/0) do
      {:ok, settings} ->
        slots = if project, do: min(settings.agent.max_concurrent_agents, service.slots), else: service.slots
        %{settings | agent: %{settings.agent | max_concurrent_agents: slots}, throttle: service.throttle, pricing: service.pricing}

      {:error, _reason} ->
        nil
    end
  end

  defp service_settings(_service, [], _project), do: nil

  # One project (filtered, or the only one) reads as that project.
  defp service_runtime([id], _project), do: Project.with_project(id, &runtime_context/0)
  defp service_runtime(ids, _project), do: %{tracker: "#{length(ids)} projects", max_turns: nil}

  defp project_list(service, snapshots) do
    failures = Projects.failures()
    by_id = Map.new(snapshots)

    for project <- Service.projects(service) do
      snapshot = by_id[project.id]

      %{
        id: project.id,
        weight: project.weight,
        started: is_pid(GenServer.whereis(Project.via(project.id, :orchestrator))),
        snapshot_status: snapshot_status(snapshot),
        running: if(is_map(snapshot), do: length(snapshot[:running] || [])),
        ready: if(is_map(snapshot), do: length(get_in(snapshot, [:upcoming, :ready]) || [])),
        failure: failures[project.id]
      }
    end
  end

  defp snapshot_status(%{}), do: "ok"
  defp snapshot_status(nil), do: "not_selected"
  defp snapshot_status(status), do: to_string(status)

  defp generated_at(now), do: now |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp build(snapshot, settings, runtime, now, opts) do
    transcripts = Keyword.get(opts, :transcripts, false)
    usage = usage_payload(snapshot, settings)

    counts = %{
      running: length(snapshot.running),
      retrying: length(snapshot.retrying),
      blocked: length(Map.get(snapshot, :blocked, [])),
      ready: length(get_in(snapshot, [:upcoming, :ready]) || []),
      waiting: length(get_in(snapshot, [:upcoming, :waiting]) || []),
      open_prs: length(get_in(snapshot, [:pull_requests, :items]) || [])
    }

    counts = if snapshot[:snapshot_status] == "partial", do: Map.new(counts, fn {key, _value} -> {key, nil} end), else: counts

    %{
      generated_at: generated_at(now),
      service: SourceRevision.metadata(),
      counts: counts,
      running: Enum.map(snapshot.running, &running_entry_payload(&1, transcripts)),
      retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
      blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
      codex_totals: snapshot.codex_totals,
      rate_limits: snapshot.rate_limits,
      quota: quota_payload(Map.get(snapshot, :quota), now),
      throttle: throttle_payload(Map.get(snapshot, :throttle)),
      usage: usage,
      usage_error: Map.get(snapshot, :operations_error),
      upcoming: upcoming_payload(Map.get(snapshot, :upcoming), usage, settings),
      autopilot: Map.get(snapshot, :autopilot) || %{enabled: false},
      polling: Map.get(snapshot, :polling),
      runtime: runtime,
      pull_requests: pulls_payload(Map.get(snapshot, :pull_requests)),
      header: header_payload(snapshot, usage, settings, counts),
      history: history_payload(usage),
      health: health_payload(snapshot, usage, settings, now),
      run_stats: run_stats(usage)
    }
    |> Map.merge(Map.take(snapshot, [:snapshot_status, :snapshot_errors]))
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @doc """
  One work item's payload wherever it runs: the single-workflow runtime's
  orchestrator, or under a service the given project (or the first project
  that has it).
  """
  @spec item_payload(String.t(), keyword()) :: {:ok, map()} | {:error, :issue_not_found}
  def item_payload(issue_identifier, opts) do
    case Service.current() do
      nil ->
        issue_payload(issue_identifier, Keyword.fetch!(opts, :orchestrator), Keyword.fetch!(opts, :timeout))

      service ->
        ids = service |> Service.projects() |> Enum.map(& &1.id)

        ids
        |> Enum.filter(&(opts[:project] in [nil, &1]))
        |> Enum.find_value({:error, :issue_not_found}, &project_item(&1, issue_identifier, Keyword.fetch!(opts, :timeout)))
        |> redact_item(redacted(service))
    end
  end

  defp redact_item({:ok, %{project: project} = payload}, redacted) do
    if project in redacted, do: {:ok, Redaction.item(payload)}, else: {:ok, payload}
  end

  defp redact_item(error, _redacted), do: error

  defp project_item(id, issue_identifier, timeout) do
    Project.with_project(id, fn ->
      case issue_payload(issue_identifier, Project.via(id, :orchestrator), timeout) do
        {:ok, payload} -> {:ok, Map.put(payload, :project, id)}
        {:error, :issue_not_found} -> nil
      end
    end)
  end

  # Static context the dashboard shows beside live state: which tracker scope
  # this runtime serves and the per-run turn budget.
  defp runtime_context do
    case Config.settings() do
      {:ok, settings} ->
        %{tracker: tracker_scope(settings.tracker), max_turns: settings.agent.max_turns}

      {:error, _reason} ->
        %{tracker: nil, max_turns: nil}
    end
  end

  defp tracker_scope(%{kind: "github", provider: provider}), do: "github:#{provider["repo"] || provider[:repo]}"
  defp tracker_scope(%{kind: kind, project_slug: slug}) when is_binary(slug), do: "#{kind}:#{slug}"
  defp tracker_scope(%{kind: kind}), do: kind

  defp issue_payload_body(issue_identifier, running, retry, blocked) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked),
      status: issue_status(running, retry, blocked),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked),
        host: workspace_host(running, retry, blocked)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      blocked: blocked && blocked_issue_payload(blocked),
      logs: %{
        codex_session_logs: []
      },
      recent_events: recent_events_payload(running || blocked),
      last_error: (blocked && blocked.error) || (retry && retry.error),
      tracked: %{}
    }
    |> Map.merge(transcript_payload(running))
  end

  # Only a running item has a live transcript.
  defp transcript_payload(nil), do: %{transcript: nil, workspace_summary: nil}

  defp transcript_payload(running) do
    transcript = Map.get(running, :transcript)
    %{transcript: transcript_entries(transcript), workspace_summary: workspace_payload(transcript)}
  end

  defp issue_id_from_entries(running, retry, blocked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _blocked) when not is_nil(running), do: "running"
  defp issue_status(nil, retry, _blocked) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, _blocked), do: "blocked"

  defp running_entry_payload(entry, transcripts) do
    payload =
      entry
      |> running_entry_payload()
      |> Map.merge(%{
        run_id: Map.get(entry, :run_id),
        description: excerpt(Map.get(entry, :description)),
        branch: Map.get(entry, :branch_name) || get_in(entry, [:pull_request, :head_ref]),
        workspace: workspace_payload(Map.get(entry, :transcript))
      })

    if transcripts in [true, entry.identifier],
      do: Map.put(payload, :transcript, transcript_entries(Map.get(entry, :transcript))),
      else: payload
  end

  defp running_entry_payload(entry) do
    %{
      project: Map.get(entry, :project),
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      model: Map.get(entry, :model),
      route: Map.get(entry, :route),
      codex_provenance: Map.get(entry, :codex_provenance, %{}),
      title: Map.get(entry, :title),
      labels: Map.get(entry, :labels, []),
      kind: Map.get(entry, :kind, :issue),
      pull_request: Map.get(entry, :pull_request),
      research: Map.get(entry, :research),
      attempt: Map.get(entry, :attempt, 0),
      item_attempt: Map.get(entry, :item_attempt, 1),
      final_attempt: Map.get(entry, :final_attempt, false),
      recent_events: Enum.map(Map.get(entry, :recent_events, []), &%{at: iso8601(&1.at), event: &1.event, text: &1.text}),
      cost: %{run: Map.get(entry, :run_usage), item: Map.get(entry, :item_usage)},
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        cached_input_tokens: Map.get(entry, :codex_cached_input_tokens, 0),
        cache_write_input_tokens: Map.get(entry, :codex_cache_write_input_tokens, 0),
        reasoning_output_tokens: Map.get(entry, :codex_reasoning_output_tokens, 0),
        reported_total_tokens: Map.get(entry, :codex_reported_total_tokens),
        model_context_window: Map.get(entry, :codex_model_context_window),
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      project: Map.get(entry, :project),
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
    |> with_startup(entry)
  end

  defp blocked_entry_payload(entry) do
    %{
      project: Map.get(entry, :project),
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      blocked_at: iso8601(entry.blocked_at),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      last_event_at: iso8601(entry.last_codex_timestamp)
    }
    |> with_startup(entry)
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      model: Map.get(running, :model),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
    |> with_startup(retry)
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: blocked.session_id,
      state: blocked.state,
      error: blocked.error,
      blocked_at: iso8601(blocked.blocked_at),
      last_event: blocked.last_codex_event,
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp)
    }
    |> with_startup(blocked)
  end

  defp with_startup(payload, %{startup: startup} = entry) when is_map(startup) do
    payload
    |> Map.merge(Map.take(entry, [:startup, :run_id, :worker_pid]))
    |> Map.put(:startup_attempt, entry[:count] || entry[:startup_attempt])
    |> Map.put(:retry_at, entry[:due_at_ms])
  end

  defp with_startup(payload, _entry), do: payload

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, Workspace.workspace_key(issue_identifier))
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    [
      %{
        at: iso8601(entry.last_codex_timestamp),
        event: entry.last_codex_event,
        message: summarize_message(entry.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp upcoming_payload(nil, _usage, _settings), do: %{ready: [], waiting: [], observed_at: nil, error: nil, available_slots: nil}

  # Ready items get a rough ETA: the recent median run time for their kind, one
  # wave of `max_concurrent_agents` runs per step down the queue.
  defp upcoming_payload(value, usage, settings) do
    medians = Map.get(usage, :median_run_seconds, %{})
    slots = max((settings && settings.agent.max_concurrent_agents) || 1, 1)

    ready =
      value
      |> Map.get(:ready, [])
      |> Enum.with_index()
      |> Enum.map(fn {item, index} ->
        eta = with seconds when is_integer(seconds) <- Map.get(medians, item_kind(item.issue_identifier)), do: seconds * (div(index, slots) + 1)
        Map.put(item, :eta_seconds, eta)
      end)

    value |> Map.put(:ready, ready) |> Map.update(:observed_at, nil, &iso8601/1)
  end

  defp item_kind("PR-" <> _), do: "pull_request"
  defp item_kind("research" <> _), do: "research"
  defp item_kind(_identifier), do: "issue"

  defp usage_payload(snapshot, settings) do
    pricing = if settings, do: settings.pricing
    (Map.get(snapshot, :operations) || Operations.snapshot(nil)) |> Map.put(:pricing_as_of, Operations.price_date(pricing))
  end

  defp settings do
    case Config.settings() do
      {:ok, settings} -> settings
      {:error, _reason} -> nil
    end
  end

  defp header_payload(snapshot, usage, settings, counts) do
    longest = Enum.max_by(snapshot.running, &Map.get(&1, :runtime_seconds, 0), fn -> nil end)
    today = usage |> Map.get(:daily, []) |> List.last() || %{}

    %{
      budget_usd_micro: budget_usd_micro(settings),
      runs_today: Map.get(today, :completed, 0) + Map.get(today, :failed, 0) + Map.get(today, :interrupted, 0) + Map.get(today, :stopped, 0),
      max_agents: settings && settings.agent.max_concurrent_agents,
      queued: counts.ready,
      longest: longest && %{issue_identifier: longest.identifier, seconds: Map.get(longest, :runtime_seconds, 0), model: Map.get(longest, :model)}
    }
  end

  @doc """
  The daily worker spend budget in micro-USD: the enforced
  `throttle.daily_budget_usd`, else the display-only `observability.daily_budget_usd`.
  """
  @spec budget_usd_micro(map() | nil) :: non_neg_integer()
  def budget_usd_micro(%{throttle: %{daily_budget_usd: budget}}) when is_number(budget), do: round(budget * 1_000_000)
  def budget_usd_micro(%{observability: %{daily_budget_usd: budget}}) when is_number(budget), do: round(budget * 1_000_000)
  def budget_usd_micro(_settings), do: 50_000_000

  defp throttle_payload(%{} = throttle) do
    %{
      budget_usd_micro: throttle.budget_usd_micro,
      spent_usd_micro: throttle.spent_usd_micro,
      over_budget: throttle.over_budget,
      paused: throttle.paused,
      allow: throttle.allow,
      avoid: throttle.avoid |> Enum.sort() |> Enum.map(fn {model, reason} -> %{model: model, reason: reason} end),
      # A service's shared slots (absent for a single workflow).
      service_slots: throttle[:service_slots],
      busy: throttle[:busy]
    }
  end

  defp throttle_payload(_throttle), do: nil

  # Five-minute samples are folded into 15-minute peaks so a 12-hour sparkline
  # stays readable (48 points).
  defp history_payload(usage) do
    groups = usage |> Map.get(:samples, []) |> Enum.chunk_every(3)

    for key <- [:running, :ready, :waiting, :attention, :open_prs, :spend_micro], into: %{} do
      {key, Enum.map(groups, fn group -> group |> Enum.map(&Map.get(&1, key, 0)) |> Enum.max() end)}
    end
  end

  defp run_stats(usage) do
    days = Map.get(usage, :daily, [])
    sum = fn key -> days |> Enum.map(&Map.get(&1, key, 0)) |> Enum.sum() end
    [completed, interrupted, failed, merged, closed] = Enum.map([:completed, :interrupted, :failed, :merged, :closed], sum)

    %{
      total: completed + interrupted + failed + sum.(:stopped),
      stopped: sum.(:stopped),
      blocked_attempts: sum.(:blocked_attempts),
      accepted_deliveries: sum.(:accepted_deliveries),
      retirements: sum.(:retirements),
      unknown_dispositions: sum.(:unknown_dispositions),
      completed: completed,
      interrupted: interrupted,
      failed: failed,
      merged: merged,
      closed: closed
    }
  end

  # Health comes only from signals Symphony actually observes; a check that
  # cannot be judged is left out rather than shown as healthy.
  defp health_payload(snapshot, usage, settings, now) do
    coordinator =
      Enum.reject(
        [
          snapshot_check(snapshot),
          polling_check(Map.get(snapshot, :polling)),
          dispatch_check(snapshot, settings),
          throttle_check(throttle_payload(Map.get(snapshot, :throttle))),
          attention_check(snapshot),
          research_check(Map.get(snapshot, :autopilot))
        ],
        &is_nil/1
      )

    system =
      Enum.reject(
        [
          snapshot_check(snapshot),
          tracker_check(Map.get(snapshot, :upcoming), settings, now),
          pulls_check(Map.get(snapshot, :pull_requests), now),
          model_check(Map.get(snapshot, :quota), usage, now),
          store_check(usage),
          disk_check(settings)
        ],
        &is_nil/1
      )

    %{
      coordinator: %{status: overall(coordinator), checks: coordinator},
      system: %{status: overall(system), checks: system}
    }
  end

  defp overall(checks) do
    cond do
      Enum.any?(checks, &(&1.status == "critical")) -> "down"
      Enum.any?(checks, &(&1.status == "warning")) -> "degraded"
      true -> "operational"
    end
  end

  defp check(name, status, detail), do: %{name: name, status: status, detail: detail}

  defp polling_check(%{checking?: true}), do: check("Polling loop", "healthy", "Polling now")
  defp polling_check(%{poll_interval_ms: ms}) when is_integer(ms), do: check("Polling loop", "healthy", "Every #{div(ms, 1_000)}s")
  defp polling_check(_polling), do: check("Polling loop", "idle", "No polling data yet")

  defp snapshot_check(%{snapshot_errors: [_ | _] = errors}) do
    detail = Enum.map_join(errors, " · ", &"#{&1.project}: #{&1.status}")
    check("Project snapshots", "warning", "Snapshot incomplete · #{detail}")
  end

  defp snapshot_check(_snapshot), do: nil

  defp dispatch_check(%{snapshot_status: "partial"} = snapshot, _settings) do
    slots =
      case snapshot.throttle do
        %{busy: busy, service_slots: slots} -> "#{busy} of #{slots} service slots held · "
        _ -> ""
      end

    check("Dispatch", "warning", "#{slots}Running and queue counts unknown")
  end

  defp dispatch_check(snapshot, settings) do
    max = (settings && settings.agent.max_concurrent_agents) || length(snapshot.running)
    queued = length(get_in(snapshot, [:upcoming, :ready]) || [])
    check("Dispatch", "healthy", "#{length(snapshot.running)} of #{max} slots busy · #{queued} queued")
  end

  # Holding work back is the throttle doing its job, so only a pause or the
  # budget's closing-only mode is worth a warning.
  defp throttle_check(%{paused: reason}) when is_binary(reason), do: check("Throttle", "warning", "New runs paused: #{reason}")
  defp throttle_check(%{over_budget: reason}) when is_binary(reason), do: check("Throttle", "warning", "Closing open work only: #{reason}")
  defp throttle_check(%{avoid: [_ | _] = avoid}), do: check("Throttle", "healthy", Enum.map_join(avoid, " · ", &"#{&1.model} backed off: #{&1.reason}"))

  defp throttle_check(%{budget_usd_micro: budget, spent_usd_micro: spent}) when is_integer(budget),
    do: check("Throttle", "healthy", "#{usd(spent)} of #{usd(budget)} budget spent today")

  defp throttle_check(%{}), do: check("Throttle", "healthy", "No limits in effect")
  defp throttle_check(nil), do: nil

  defp usd(micro), do: :io_lib.format("$~.2f", [micro / 1_000_000]) |> to_string()

  # Retrying is the normal path for a failed attempt; only a blocked item,
  # which waits on someone, is a problem.
  defp attention_check(snapshot) do
    blocked = length(Map.get(snapshot, :blocked, []))
    retrying = length(snapshot.retrying)

    cond do
      blocked > 0 -> check("Retries", "warning", "#{blocked} blocked · #{retrying} retrying")
      retrying > 0 -> check("Retries", "healthy", "#{retrying} retrying automatically")
      true -> check("Retries", "healthy", "Nothing blocked or retrying")
    end
  end

  defp research_check(%{enabled: true} = autopilot) do
    cond do
      Map.get(autopilot, :research_running, 0) > 0 -> check("Research", "healthy", "Planning new work")
      (pending = Map.get(autopilot, :research_pending, [])) != [] -> check("Research", "healthy", "Due: #{Enum.join(pending, ", ")}")
      true -> check("Research", "healthy", "Starts when the queue is empty")
    end
  end

  defp research_check(_autopilot), do: check("Research", "idle", "Autopilot off")

  defp tracker_check(%{error: error}, _settings, _now) when is_binary(error), do: check("Tracker", "critical", "Read failed: #{error}")

  defp tracker_check(%{observed_at: %DateTime{} = at}, settings, now) do
    age = DateTime.diff(now, at)
    interval = if settings, do: div(settings.polling.interval_ms, 1_000), else: 30
    if age > interval * 5, do: check("Tracker", "warning", "Last read #{age_text(age)} ago"), else: check("Tracker", "healthy", "Read #{age_text(age)} ago")
  end

  defp tracker_check(_upcoming, _settings, _now), do: nil

  defp pulls_check(%{enabled: true, error: error}, _now) when is_binary(error), do: check("GitHub pull requests", "warning", error)

  defp pulls_check(%{enabled: true, observed_at: %DateTime{} = at}, now) do
    age = DateTime.diff(now, at)
    if age > 1_800, do: check("GitHub pull requests", "warning", "Synced #{age_text(age)} ago"), else: check("GitHub pull requests", "healthy", "Synced #{age_text(age)} ago")
  end

  defp pulls_check(_pulls, _now), do: nil

  # The tightest quota window speaks for the provider; failures come second.
  defp model_check(quota, usage, now) do
    cutoff = DateTime.add(now, -3_600, :second)
    failures = usage |> Map.get(:activity, []) |> Enum.count(&(&1[:kind] == "attempt_failed" and after?(&1[:at], cutoff)))

    tightest =
      quota
      |> quota_windows(now)
      |> Enum.filter(&is_number(&1.remaining_percent))
      |> Enum.min_by(& &1.remaining_percent, fn -> nil end)

    cond do
      tightest && tightest.remaining_percent <= 10 -> check("Model provider", "warning", quota_text(tightest))
      failures >= 3 -> check("Model provider", "warning", "#{failures} failed runs in the last hour")
      tightest -> check("Model provider", "healthy", quota_text(tightest))
      true -> check("Model provider", "healthy", "No recent failures")
    end
  end

  defp quota_text(window), do: "#{String.capitalize(window.name)} quota #{round(window.remaining_percent)}% left"

  defp quota_payload(nil, _now), do: nil

  defp quota_payload(quota, now) do
    %{limit_id: quota.limit_id, plan: quota.plan, observed_at: iso8601(quota.observed_at), windows: quota_windows(quota, now)}
  end

  # Longest window first: the weekly quota is the one throttling watches.
  defp quota_windows(nil, _now), do: []

  defp quota_windows(quota, now) do
    quota.windows
    |> Map.values()
    |> Enum.sort_by(&(&1.window_minutes || 0), :desc)
    |> Enum.map(fn window ->
      {state, remaining} = Quota.remaining(quota, window.name, now, @quota_stale_ms)

      %{
        name: window.name,
        state: state,
        used_percent: window.used_percent,
        remaining_percent: remaining,
        window_minutes: window.window_minutes,
        resets_at: window.resets_at && window.resets_at |> DateTime.from_unix!() |> DateTime.to_iso8601()
      }
    end)
  end

  defp after?(at, cutoff) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, time, _offset} -> DateTime.compare(time, cutoff) == :gt
      _ -> false
    end
  end

  defp after?(_at, _cutoff), do: false

  defp store_check(%{status: "ok"}), do: check("Usage history", "healthy", "Recording runs and spend")
  defp store_check(_usage), do: check("Usage history", "critical", "History unavailable")

  defp disk_check(settings) do
    case settings && free_bytes(settings.workspace.root) do
      bytes when is_integer(bytes) ->
        gb = div(bytes, 1024 * 1024 * 1024)

        cond do
          gb < 20 -> check("Workspace disk", "critical", "#{gb} GB free")
          gb < 60 -> check("Workspace disk", "warning", "#{gb} GB free")
          true -> check("Workspace disk", "healthy", "#{gb} GB free")
        end

      _ ->
        nil
    end
  end

  # `df` is cheap but not free; the answer is cached for a minute per root.
  defp free_bytes(root) when is_binary(root) do
    key = {__MODULE__, :free_bytes, root}
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(key, nil) do
      {at, value} when now - at < 60_000 ->
        value

      _ ->
        value = df_available(root)
        :persistent_term.put(key, {now, value})
        value
    end
  end

  defp free_bytes(_root), do: nil

  defp df_available(root) do
    with true <- File.dir?(root),
         {output, 0} <- System.cmd("df", ["-Pk", root], stderr_to_stdout: true),
         [_header, line | _] <- String.split(output, "\n", trim: true),
         [_fs, _size, _used, available | _] <- String.split(line),
         {kb, ""} <- Integer.parse(available) do
      kb * 1024
    else
      _ -> nil
    end
  end

  defp age_text(seconds) when seconds < 90, do: "#{max(seconds, 0)}s"
  defp age_text(seconds) when seconds < 5_400, do: "#{div(seconds, 60)}m"
  defp age_text(seconds), do: "#{div(seconds, 3_600)}h"

  # What a glance at one agent needs: plan progress, changed files, its images,
  # its latest step (`now`) and the last thing it said (`said`).
  defp workspace_payload(transcript) do
    transcript = transcript || Transcript.new()
    images = Enum.flat_map(transcript.entries, &Map.get(&1, :images, []))
    said = transcript.entries |> Enum.filter(&(&1.kind == "message")) |> List.last()

    %{
      progress: Transcript.progress(transcript),
      plan: transcript.plan,
      plan_explanation: transcript.plan_explanation,
      files: transcript.files,
      latest_image: List.last(images),
      images: length(images),
      entries: length(transcript.entries),
      now: transcript.entries |> List.last() |> glance(),
      said: said && excerpt(said.text, 240)
    }
  end

  defp glance(nil), do: nil

  defp glance(entry) do
    entry
    |> Map.drop([:output, :images])
    |> Map.replace_lazy(:files, fn files -> Enum.map(files, &Map.delete(&1, :diff)) end)
    |> Map.replace_lazy(:text, &excerpt(&1, 240))
    |> Map.update(:at, nil, &iso8601/1)
    |> Map.delete(:started_at)
  end

  defp transcript_entries(nil), do: []

  defp transcript_entries(transcript) do
    Enum.map(transcript.entries, fn entry ->
      entry
      |> Map.update(:at, nil, &iso8601/1)
      |> Map.update(:started_at, nil, &iso8601/1)
    end)
  end

  # Issue bodies are Markdown; the excerpt keeps the words and drops the markup.
  defp excerpt(text, limit \\ 400)

  defp excerpt(text, limit) when is_binary(text) do
    compact =
      text
      |> String.replace(~r/<!--.*?-->/s, " ")
      |> String.replace(~r/!?\[([^\]]*)\]\([^)]*\)/, "\\1")
      |> String.replace(~r/^\s*(?:\#{1,6}|[-*+]|\d+\.|>)\s+/m, "")
      |> String.replace(~r/\*\*|__|`/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.length(compact) > limit, do: String.slice(compact, 0, limit - 1) <> "…", else: compact
  end

  defp excerpt(_text, _limit), do: nil

  defp pulls_payload(nil), do: %{items: [], observed_at: nil, error: nil, enabled: false}
  defp pulls_payload(value), do: Map.update(value, :observed_at, nil, &iso8601/1)
end
