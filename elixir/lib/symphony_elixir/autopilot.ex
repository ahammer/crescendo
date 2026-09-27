defmodule SymphonyElixir.Autopilot do
  @moduledoc """
  Pure policy for autopilot work: when a pull request deserves another review
  pass, and when the idle queue should be re-hydrated by research runs.

  The orchestrator owns the state (persisted through `Operations`) and applies
  these decisions; this module never talks to the tracker.
  """

  alias SymphonyElixir.Tracker.Issue

  @type state :: %{
          pr_handled: %{optional(String.t()) => map()},
          research_finished_at: DateTime.t() | nil,
          research_pending: [String.t()],
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

  @doc "Drops pull request and attempt records for items that are no longer open."
  @spec prune_pull_requests(state(), [Issue.t()]) :: state()
  def prune_pull_requests(state, open_issues) do
    open_prs = for %Issue{kind: :pull_request, id: id} <- open_issues, into: MapSet.new(), do: id
    open_items = for %Issue{id: id} <- open_issues, into: MapSet.new(), do: id

    state
    |> Map.put(:pr_handled, Map.filter(state.pr_handled, fn {id, _} -> MapSet.member?(open_prs, id) end))
    |> Map.put(:item_attempts, state |> item_attempts() |> Map.filter(fn {id, _} -> MapSet.member?(open_items, id) end))
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
  def final_run?(state, %Issue{kind: :issue, id: id}, autopilot_settings), do: final_attempt?(state, id, autopilot_settings)

  def final_run?(state, %Issue{kind: :pull_request, id: id}, autopilot_settings) do
    runs = state.pr_handled |> Map.get(id, %{}) |> Map.get(:runs, 0)
    runs + 1 >= autopilot_settings.max_pr_runs
  end

  def final_run?(_state, %Issue{}, _autopilot_settings), do: false

  defp item_attempts(state), do: Map.get(state, :item_attempts, %{})

  @doc """
  Picks the next research channel to run, if any. Research runs as rounds:
  a round covers every configured channel one at a time, so planners never
  share the machine. An unfinished round continues without waiting for the
  cooldown; a new round starts once the cooldown since the last round has
  elapsed. Either way the open issue backlog must be below its cap. The caller
  checks that the machine is otherwise idle.
  """
  @spec next_research(state(), map(), non_neg_integer(), DateTime.t()) :: {state(), Issue.t() | nil}
  def next_research(state, autopilot_settings, open_issue_count, now) do
    channels = autopilot_settings.channels |> Map.keys() |> Enum.sort()
    pending = Enum.filter(Map.get(state, :research_pending, []), &(&1 in channels))

    cond do
      not autopilot_settings.enabled or open_issue_count >= autopilot_settings.max_open_issues ->
        {state, nil}

      pending != [] ->
        {%{state | research_pending: pending}, research_item(autopilot_settings, hd(pending))}

      cooled_down?(state.research_finished_at, autopilot_settings.research_cooldown_ms, now) ->
        {%{state | research_pending: channels}, research_item(autopilot_settings, hd(channels))}

      true ->
        {state, nil}
    end
  end

  @doc """
  Ends one channel's research run, whatever its outcome. The cooldown starts
  when the round's last channel finishes.
  """
  @spec record_research_finished(state(), String.t(), DateTime.t()) :: state()
  def record_research_finished(state, channel, now) do
    case List.delete(Map.get(state, :research_pending, []), channel) do
      [] -> %{state | research_pending: [], research_finished_at: now}
      pending -> %{state | research_pending: pending}
    end
  end

  defp cooled_down?(nil, _cooldown_ms, _now), do: true
  defp cooled_down?(finished_at, cooldown_ms, now), do: DateTime.diff(now, finished_at, :millisecond) >= cooldown_ms

  @doc "One synthetic research item per configured channel, in name order."
  @spec research_items(map()) :: [Issue.t()]
  def research_items(autopilot_settings) do
    autopilot_settings.channels
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&research_item(autopilot_settings, &1))
  end

  defp research_item(autopilot_settings, channel) do
    focus = Map.fetch!(autopilot_settings.channels, channel)

    %Issue{
      id: "research:#{channel}",
      kind: :research,
      identifier: "research-#{channel}",
      title: "Research #{channel} improvements",
      state: @research_state,
      labels: ["symphony:research", "symphony:channel:#{channel}"],
      dispatchable: true,
      research: %{
        channel: channel,
        focus: focus,
        min_issues: autopilot_settings.min_issues_per_channel,
        max_issues: autopilot_settings.max_issues_per_channel
      }
    }
  end
end
