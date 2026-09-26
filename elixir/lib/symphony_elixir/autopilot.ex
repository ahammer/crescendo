defmodule SymphonyElixir.Autopilot do
  @moduledoc """
  Pure policy for autopilot work: when a pull request deserves another review
  pass, and when the idle queue should be re-hydrated by research runs.

  The orchestrator owns the state (persisted through `Operations`) and applies
  these decisions; this module never talks to the tracker.
  """

  alias SymphonyElixir.Tracker.Issue

  @type state :: %{pr_handled: %{optional(String.t()) => map()}, research_finished_at: DateTime.t() | nil}

  @research_state "research"

  @doc """
  A pull request is ready for a review pass when its head commit has not been
  handled yet and it is under the per-PR run cap. CI is checked separately at
  dispatch time because it needs an extra API call.
  """
  @spec pull_request_ready?(Issue.t(), state(), map()) :: boolean()
  def pull_request_ready?(%Issue{kind: :pull_request} = issue, state, autopilot_settings) do
    is_nil(pull_request_waiting_reason(issue, state, autopilot_settings))
  end

  def pull_request_ready?(%Issue{}, _state, _autopilot_settings), do: true

  @doc "Why a pull request is not ready for another pass, or nil when it is."
  @spec pull_request_waiting_reason(Issue.t(), state(), map()) :: String.t() | nil
  def pull_request_waiting_reason(%Issue{kind: :pull_request, id: id, pull_request: pull}, state, autopilot_settings) do
    handled = Map.get(state.pr_handled, id, %{})

    cond do
      not is_map(pull) or not is_binary(pull[:head_sha]) -> "pull request details unavailable"
      Map.get(handled, :runs, 0) >= autopilot_settings.max_pr_runs -> "review run cap reached"
      Map.get(handled, :head_sha) == pull.head_sha -> "reviewed at current head"
      true -> nil
    end
  end

  def pull_request_waiting_reason(%Issue{}, _state, _autopilot_settings), do: nil

  @doc "Counts a review run against the pull request's cap."
  @spec record_pull_dispatch(state(), Issue.t()) :: state()
  def record_pull_dispatch(state, %Issue{kind: :pull_request, id: id}) do
    update_in(state, [:pr_handled, Access.key(id, %{})], &Map.update(&1, :runs, 1, fn runs -> runs + 1 end))
  end

  def record_pull_dispatch(state, %Issue{}), do: state

  @doc """
  Marks the head commit a review pass was dispatched at, so the pull request
  waits for a new push (by its author or by the reviewer's own fixes).
  """
  @spec record_pull_handled(state(), Issue.t(), String.t() | nil) :: state()
  def record_pull_handled(state, %Issue{kind: :pull_request, id: id}, head_sha) when is_binary(head_sha) do
    update_in(state, [:pr_handled, Access.key(id, %{})], &Map.put(&1, :head_sha, head_sha))
  end

  def record_pull_handled(state, %Issue{}, _head_sha), do: state

  @doc "The head commit a pull request run was dispatched at, if any."
  @spec dispatched_head(Issue.t()) :: String.t() | nil
  def dispatched_head(%Issue{kind: :pull_request, pull_request: %{head_sha: head_sha}}), do: head_sha
  def dispatched_head(%Issue{}), do: nil

  @doc "Drops handled records for pull requests that are no longer open."
  @spec prune_pull_requests(state(), [Issue.t()]) :: state()
  def prune_pull_requests(state, open_issues) do
    open_ids = for %Issue{kind: :pull_request, id: id} <- open_issues, into: MapSet.new(), do: id
    %{state | pr_handled: Map.filter(state.pr_handled, fn {id, _} -> MapSet.member?(open_ids, id) end)}
  end

  @spec record_research_finished(state(), DateTime.t()) :: state()
  def record_research_finished(state, now), do: %{state | research_finished_at: now}

  @doc """
  Whether a research round may start: autopilot is on, the cooldown since the
  last research run has elapsed, and the open issue backlog is below its cap.
  The caller checks that no work is ready and no research is running.
  """
  @spec research_due?(state(), map(), non_neg_integer(), DateTime.t()) :: boolean()
  def research_due?(state, autopilot_settings, open_issue_count, now) do
    autopilot_settings.enabled and open_issue_count < autopilot_settings.max_open_issues and
      cooled_down?(state.research_finished_at, autopilot_settings.research_cooldown_ms, now)
  end

  defp cooled_down?(nil, _cooldown_ms, _now), do: true
  defp cooled_down?(finished_at, cooldown_ms, now), do: DateTime.diff(now, finished_at, :millisecond) >= cooldown_ms

  @doc "One synthetic research item per configured channel, in name order."
  @spec research_items(map()) :: [Issue.t()]
  def research_items(autopilot_settings) do
    autopilot_settings.channels
    |> Enum.sort()
    |> Enum.map(fn {channel, focus} ->
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
          max_issues: autopilot_settings.max_issues_per_channel
        }
      }
    end)
  end
end
