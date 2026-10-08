defmodule SymphonyElixir.Autopilot do
  @moduledoc """
  Pure policy for autopilot work: when a pull request deserves another review
  pass, and when each autopilot task (a research channel: local, or from the
  repository's `.crescendo/autopilot/`) is due to run again.

  The orchestrator owns the state (persisted through `Operations`) and applies
  these decisions; this module never talks to the tracker.
  """

  alias SymphonyElixir.Tracker.Issue

  @type state :: %{
          optional(:handoff_owners) => %{optional(String.t()) => String.t()},
          optional(:retired_items) => %{optional(String.t()) => boolean()},
          pr_handled: %{optional(String.t()) => map()},
          tasks: %{optional(String.t()) => map()},
          item_attempts: %{optional(String.t()) => pos_integer()}
        }

  @research_state "research"

  @doc """
  A pull request is ready for a review pass when its head commit has not been
  handled yet, or was handled longer than `pr_recheck_ms` ago, and it is under
  the per-PR run cap. CI is checked separately at dispatch time because it
  needs an extra API call.
  """
  @spec pull_request_ready?(Issue.t(), state(), map(), integer()) :: boolean()
  def pull_request_ready?(issue, state, autopilot_settings, now_ms \\ System.system_time(:millisecond)),
    do: is_nil(pull_request_waiting_reason(issue, state, autopilot_settings, now_ms))

  @doc """
  Why a pull request is not ready for another pass, or nil when it is. A pass
  that ended without merging or pushing is rechecked after `pr_recheck_ms`, so
  a reviewed pull request never waits indefinitely for a push; the run cap
  bounds the rechecks.
  """
  @spec pull_request_waiting_reason(Issue.t(), state(), map(), integer()) :: String.t() | nil
  def pull_request_waiting_reason(issue, state, autopilot_settings, now_ms \\ System.system_time(:millisecond)),
    do: waiting_reason(issue, state, autopilot_settings, now_ms)

  defp waiting_reason(%Issue{kind: :pull_request, id: id, pull_request: pull}, state, autopilot_settings, now_ms) do
    handled = Map.get(state.pr_handled, id, %{})

    cond do
      not is_map(pull) or not is_binary(pull[:head_sha]) -> "pull request details unavailable"
      Map.get(handled, :runs, 0) >= autopilot_settings.max_pr_runs -> "review run cap reached"
      Map.get(handled, :head_sha) == pull.head_sha and recheck_pending?(handled, autopilot_settings, now_ms) -> "reviewed at current head"
      true -> nil
    end
  end

  defp waiting_reason(%Issue{}, _state, _autopilot_settings, _now_ms), do: nil

  # Records persisted before rechecks carried no timestamp; they are due now.
  defp recheck_pending?(%{handled_at_ms: handled_at_ms}, autopilot_settings, now_ms) when is_integer(handled_at_ms),
    do: now_ms - handled_at_ms < autopilot_settings.pr_recheck_ms

  defp recheck_pending?(_handled, _autopilot_settings, _now_ms), do: false

  @doc "Counts a review run against the pull request's cap."
  @spec record_pull_dispatch(state(), Issue.t()) :: state()
  def record_pull_dispatch(state, %Issue{kind: :pull_request, id: id}) do
    update_in(state, [:pr_handled, Access.key(id, %{})], &Map.update(&1, :runs, 1, fn runs -> runs + 1 end))
  end

  def record_pull_dispatch(state, %Issue{}), do: state

  @doc """
  Marks the head commit a review pass was dispatched at, so the pull request
  waits for a new push (by its author or by the reviewer's own fixes) or for
  the recheck cooldown.
  """
  @spec record_pull_handled(state(), Issue.t(), String.t() | nil, integer()) :: state()
  def record_pull_handled(state, issue, head_sha, now_ms \\ System.system_time(:millisecond)) do
    case issue do
      %Issue{kind: :pull_request, id: id} when is_binary(head_sha) ->
        update_in(state, [:pr_handled, Access.key(id, %{})], &Map.merge(&1, %{head_sha: head_sha, handled_at_ms: now_ms}))

      %Issue{} ->
        state
    end
  end

  @doc "The head commit a pull request run was dispatched at, if any."
  @spec dispatched_head(Issue.t()) :: String.t() | nil
  def dispatched_head(%Issue{kind: :pull_request, pull_request: %{head_sha: head_sha}}), do: head_sha
  def dispatched_head(%Issue{}), do: nil

  @doc "Drops closed pull request records; issue delivery budgets survive closure and reopening."
  @spec prune_pull_requests(state(), [Issue.t()]) :: state()
  def prune_pull_requests(state, open_issues) do
    open_prs = for %Issue{kind: :pull_request, id: id} <- open_issues, into: MapSet.new(), do: id
    closed_prs = Enum.reject(Map.keys(state.pr_handled), &MapSet.member?(open_prs, &1))

    state
    |> Map.put(:pr_handled, Map.filter(state.pr_handled, fn {id, _} -> MapSet.member?(open_prs, id) end))
    |> Map.put(:item_attempts, Map.drop(item_attempts(state), closed_prs))
    |> Map.update(:retired_items, %{}, &Map.drop(&1, closed_prs))
  end

  @doc """
  Records one failed attempt at an item (a blocked run, exhausted crash
  retries, or a stop for operator input). Nothing is parked: the item is
  retried behind other work until `max_item_attempts`, then retired.
  """
  @spec record_failed_attempt(state(), String.t()) :: {state(), pos_integer()}
  def record_failed_attempt(state, id) do
    attempts = Map.get(item_attempts(state), id, 0) + 1
    {Map.put(state, :item_attempts, Map.put(item_attempts(state), id, attempts)), attempts}
  end

  @spec failed_attempts(state(), String.t()) :: non_neg_integer()
  def failed_attempts(state, id), do: Map.get(item_attempts(state), id, 0)

  @doc "Whether the item has used up its attempts and must be retired."
  @spec exhausted?(state(), String.t(), map()) :: boolean()
  def exhausted?(state, id, autopilot_settings), do: failed_attempts(state, id) >= autopilot_settings.max_item_attempts

  @doc "Whether the next run of the item is its last chance to deliver."
  @spec final_attempt?(state(), String.t(), map()) :: boolean()
  def final_attempt?(state, id, autopilot_settings),
    do: failed_attempts(state, id) + 1 >= autopilot_settings.max_item_attempts

  @doc """
  Whether the next run is the work item's last: an issue's final attempt, or
  a pull request's last review run before the cap retires it.
  """
  @spec final_run?(state(), Issue.t(), map()) :: boolean()
  def final_run?(state, %Issue{kind: :issue} = issue, autopilot_settings), do: final_attempt?(state, delivery_key(issue), autopilot_settings)

  def final_run?(state, %Issue{kind: :pull_request, id: id}, autopilot_settings) do
    runs = state.pr_handled |> Map.get(id, %{}) |> Map.get(:runs, 0)
    runs + 1 >= autopilot_settings.max_pr_runs
  end

  def final_run?(_state, %Issue{}, _autopilot_settings), do: false

  @doc "Stable delivery budget identity, independent of a successor's issue number."
  @spec delivery_key(Issue.t()) :: String.t()
  def delivery_key(%Issue{delivery_key: key, id: id}), do: key || id

  @doc "Binds each routable verified successor budget to one ticket, including across restarts."
  @spec admit_handoffs(state(), [Issue.t()], map()) :: {state(), [Issue.t()]}
  def admit_handoffs(state, issues, tracker \\ %{required_labels: [], excluded_labels: []}) do
    {issues, owners} =
      Enum.map_reduce(issues, Map.get(state, :handoff_owners, %{}), fn issue, owners ->
        if Issue.routable?(issue, tracker.required_labels, tracker.excluded_labels),
          do: admit_handoff_item(issue, owners),
          else: {issue, owners}
      end)

    {Map.put(state, :handoff_owners, owners), issues}
  end

  defp admit_handoff_item(%Issue{kind: :issue, dispatchable: true, delivery_key: key} = issue, owners)
       when is_binary(key) do
    root = key |> String.split(":") |> Enum.at(1)
    rebound = Enum.any?(owners, fn {bound_key, id} -> id == root or (id == issue.id and bound_key != key) end)
    owner = Map.get(owners, key, issue.id)

    if rebound,
      do: {%{issue | dispatchable: false}, owners},
      else: {%{issue | dispatchable: owner == issue.id}, Map.put(owners, key, owner)}
  end

  defp admit_handoff_item(%Issue{kind: :issue} = issue, owners) do
    bound = Enum.any?(owners, fn {key, id} -> id == issue.id and key != issue.delivery_key end)
    {%{issue | dispatchable: issue.dispatchable and not bound}, owners}
  end

  defp admit_handoff_item(issue, owners), do: {issue, owners}

  defp item_attempts(state), do: Map.get(state, :item_attempts, %{})

  @doc """
  Picks the next autopilot task (research channel) to run, if any. Each task
  has its own schedule: it is due when it never ran, when `every` has passed
  since it last finished, or when a retry of a short run falls due. Tasks
  with `when: idle` only start when the project has nothing else to do
  (`idle: true`); `when: anytime` tasks start whenever a slot is free. The
  most overdue task goes first. Tasks that ask for issues wait while the open
  issue backlog is at its cap; `running` names tasks already in flight.
  `open_pull_requests` holds tasks requiring a PR while a channel-labelled PR is open.
  """
  @spec next_research(state(), map(), non_neg_integer(), DateTime.t(), keyword()) :: {state(), Issue.t() | nil}
  def next_research(state, autopilot_settings, open_issue_count, now, opts \\ []) do
    idle = Keyword.get(opts, :idle, true)
    running = Keyword.get(opts, :running, [])
    open_pulls = Keyword.get(opts, :open_pull_requests, [])
    capped = open_issue_count >= autopilot_settings.max_open_issues

    next =
      if autopilot_settings.enabled do
        autopilot_settings
        |> research_items()
        |> Enum.filter(&startable?(&1.research, idle, running, capped))
        |> Enum.reject(&pending_pull?(&1, open_pulls))
        |> Enum.map(&{&1, due_at(state, &1.research, now)})
        |> Enum.filter(fn {_item, due_at} -> DateTime.compare(due_at, now) != :gt end)
        |> Enum.min_by(&overdue_order/1, fn -> nil end)
      end

    {state, next && elem(next, 0)}
  end

  defp startable?(research, idle, running, capped) do
    research.channel not in running and (idle or research.when == "anytime") and not (capped and research.min_issues > 0)
  end

  defp pending_pull?(item, open_pulls) do
    pulls = item.research.pull_requests
    label = List.last(item.labels)

    pulls != nil and pulls.min > 0 and
      Enum.any?(open_pulls, &(&1.kind == :pull_request and &1.state == "open" and Issue.has_required_labels?(&1, [label])))
  end

  defp overdue_order({item, due_at}), do: {DateTime.to_unix(due_at, :microsecond), item.research.channel}

  @retry_ms 30 * 60 * 1000

  @doc """
  Ends one task run. A delivered run (or one whose deliveries could not be
  checked) starts the task's interval. A short or failed run is retried
  30 minutes later, behind other work; its last allowed attempt
  ends the task until it is next due. A transport interruption retries after
  30 seconds without spending an attempt. Nothing waits for an operator.
  """
  @spec record_research_finished(state(), String.t(), atom(), DateTime.t(), map()) :: state()
  def record_research_finished(state, channel, outcome, now, autopilot_settings) do
    task = state |> tasks() |> Map.get(channel, %{attempts: 0})
    attempts = Map.get(task, :attempts, 0) + if(outcome in [:short, :failed], do: 1, else: 0)

    preserved = Map.take(task, [:preflight_key, :preflight_at, :preflight_run_at])

    task =
      cond do
        outcome in [:delivered, :unverified] -> %{done(now) | last: outcome}
        attempts >= autopilot_settings.max_item_attempts and outcome != :interrupted -> %{done(now) | last: :gave_up}
        true -> retry(task, attempts, outcome, now)
      end

    Map.put(state, :tasks, Map.put(tasks(state), channel, Map.merge(preserved, task)))
  end

  @doc "Records a cheap input check without claiming a completed model run or coverage."
  @spec record_preflight(state(), String.t(), String.t(), DateTime.t(), boolean()) :: state()
  def record_preflight(state, channel, key, now, ran?) do
    task = Map.get(tasks(state), channel, %{}) |> Map.merge(%{preflight_key: key, preflight_at: now})
    task = if ran?, do: Map.put(task, :preflight_run_at, now), else: task
    Map.put(state, :tasks, Map.put(tasks(state), channel, task))
  end

  @doc "Unchanged successful inputs can skip model work; revisit at least daily."
  @spec unchanged?(state(), String.t(), String.t(), DateTime.t()) :: boolean()
  def unchanged?(state, channel, key, now) do
    case Map.get(tasks(state), channel) do
      %{preflight_key: ^key, preflight_run_at: %DateTime{} = at} -> DateTime.diff(now, at, :second) < 86_400
      _ -> false
    end
  end

  defp done(now), do: %{finished_at: now, attempts: 0, retry_at: nil, last: nil}

  defp retry(task, attempts, outcome, now) do
    delay = if outcome == :interrupted, do: 30_000, else: @retry_ms
    Map.merge(%{finished_at: nil}, task) |> Map.merge(%{attempts: attempts, retry_at: DateTime.add(now, delay, :millisecond), last: outcome})
  end

  @doc "When each configured task is next due, for the dashboard and health checks."
  @spec task_statuses(state(), map(), DateTime.t()) :: [map()]
  def task_statuses(state, autopilot_settings, now) do
    for %Issue{research: research} <- research_items(autopilot_settings) do
      task = Map.get(tasks(state), research.channel, %{})

      %{
        name: research.channel,
        source: research.source,
        when: research.when,
        every_ms: research.every_ms,
        at: research.at,
        due_at: due_at(state, research, now),
        attempts: Map.get(task, :attempts, 0),
        last: Map.get(task, :last),
        finished_at: Map.get(task, :finished_at),
        exclusive: research[:exclusive],
        preflight_checked_at: task[:preflight_at]
      }
    end
  end

  @doc "When the last task run finished, if any."
  @spec last_finished_at(state()) :: DateTime.t() | nil
  def last_finished_at(state) do
    state |> tasks() |> Map.values() |> Enum.map(&Map.get(&1, :finished_at)) |> Enum.reject(&is_nil/1) |> Enum.max(DateTime, fn -> nil end)
  end

  defp tasks(state), do: Map.get(state, :tasks, %{})

  # A task with `at` runs at that time of day (UTC): first at the latest past
  # occurrence, then that anchor at completion plus the interval rounded up
  # to calendar days. No missed occurrences are replayed.
  defp due_at(state, research, now) do
    task = Map.get(tasks(state), research.channel, %{})
    scheduled = scheduled_at(state, research, now)

    case task[:preflight_at] do
      %DateTime{} = checked -> Enum.max([scheduled, DateTime.add(checked, research.every_ms, :millisecond)], DateTime)
      _ -> scheduled
    end
  end

  defp scheduled_at(state, research, now) do
    case {Map.get(tasks(state), research.channel, %{}), time_of_day(research[:at])} do
      {%{retry_at: %DateTime{} = retry_at}, _at} ->
        retry_at

      {%{finished_at: %DateTime{} = finished_at}, nil} ->
        DateTime.add(finished_at, research.every_ms, :millisecond)

      {%{finished_at: %DateTime{} = finished_at}, at} ->
        days = max(1, div(research.every_ms + 86_399_999, 86_400_000))
        finished_at |> latest_occurrence(at) |> DateTime.add(days, :day)

      {_never, nil} ->
        ~U[1970-01-01 00:00:00Z]

      {_never, at} ->
        latest_occurrence(now, at)
    end
  end

  defp latest_occurrence(from, at) do
    candidate = DateTime.new!(DateTime.to_date(from), at)
    if DateTime.compare(candidate, from) == :gt, do: DateTime.add(candidate, -1, :day), else: candidate
  end

  @doc "Parses a UTC time of day such as `06:00`."
  @spec time_of_day(term()) :: Time.t() | nil
  def time_of_day(text) when is_binary(text) do
    with [_all, hour, minute] <- Regex.run(~r/^([01]\d|2[0-3]):([0-5]\d)$/, String.trim(text)),
         do: Time.new!(String.to_integer(hour), String.to_integer(minute), 0)
  end

  def time_of_day(_value), do: nil

  @doc "One synthetic research item per configured channel, in name order."
  @spec research_items(map()) :: [Issue.t()]
  def research_items(autopilot_settings) do
    autopilot_settings.channels
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&research_item(autopilot_settings, &1))
  end

  # A channel is its focus text or an object that may also set its own
  # schedule, deliveries, expectations and route; its own prompt is chosen by
  # the prompt builder.
  defp research_item(autopilot_settings, channel) do
    spec = channel_spec(Map.fetch!(autopilot_settings.channels, channel))
    prefix = Map.get(autopilot_settings, :label_prefix, "symphony")
    {min_issues, max_issues} = issue_counts(spec, autopilot_settings)

    %Issue{
      id: "research:#{channel}",
      kind: :research,
      identifier: "research-#{channel}",
      title: "Research #{channel} improvements",
      state: @research_state,
      labels: ["#{prefix}:research", "#{prefix}:channel:#{channel}"],
      dispatchable: true,
      research: %{
        channel: channel,
        focus: spec["focus"],
        min_issues: min_issues,
        max_issues: max_issues,
        pull_requests: pull_requests(get_in(spec, ["delivers", "pull_requests"])),
        expectations: Map.get(spec, "expectations") || [],
        route: spec["route"] || effort_route(autopilot_settings, spec["effort"]),
        every_ms: duration_ms(spec["every"]) || autopilot_settings.research_cooldown_ms,
        at: spec["at"],
        when: Map.get(spec, "when") || "idle",
        source: Map.get(spec, "source") || "local",
        exclusive: spec["exclusive"],
        skip_unchanged: spec["skip_unchanged"] == true
      }
    }
  end

  # `delivers.issues` (repository tasks) or `min_issues`/`max_issues` (local channels).
  defp issue_counts(spec, settings) do
    issues = get_in(spec, ["delivers", "issues"]) || %{}
    min = issues["min"] || spec["min_issues"] || settings.min_issues_per_channel
    {min, issues["max"] || spec["max_issues"] || settings.max_issues_per_channel}
  end

  defp pull_requests(nil), do: nil
  defp pull_requests(pulls), do: %{min: pulls["min"] || 0, max: pulls["max"], paths: pulls["paths"] || []}

  # An effort names a rung of the research model's ladder; the model stays the service's.
  defp effort_route(_autopilot_settings, nil), do: nil
  defp effort_route(%{research_route: %{"model" => model}}, effort), do: %{"model" => model, "effort" => effort}
  defp effort_route(_autopilot_settings, _effort), do: nil

  defp channel_spec(focus) when is_binary(focus), do: %{"focus" => focus}
  defp channel_spec(%{} = spec), do: spec

  @doc "Parses a schedule interval such as `30m`, `6h`, `1d` or `2w` (or milliseconds) to milliseconds."
  @spec duration_ms(term()) :: pos_integer() | nil
  def duration_ms(ms) when is_integer(ms) and ms > 0, do: ms

  def duration_ms(text) when is_binary(text) do
    case Regex.run(~r/^\s*(\d+)\s*(m|h|d|w)\s*$/, text) do
      [_all, count, unit] when count != "0" -> String.to_integer(count) * Map.fetch!(%{"m" => 60_000, "h" => 3_600_000, "d" => 86_400_000, "w" => 604_800_000}, unit)
      _ -> nil
    end
  end

  def duration_ms(_value), do: nil
end
