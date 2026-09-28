defmodule SymphonyElixir.Throttle do
  @moduledoc """
  The dispatch policy for one poll, from the `throttle` settings, today's
  estimated spend and the latest Codex quota snapshot.

  - Quota back-off rules name models to avoid while a quota window is low
    (routing then swaps them for a weaker ladder step), or pause every new run
    while a window is nearly spent.
  - Over the daily budget only the `over_budget_allow` classes start: by
    default pull request reviews, final attempts, and continuations of work in
    flight, so open work keeps closing while nothing new begins.

  A wait is never a failed attempt; the item simply dispatches later.
  """

  alias SymphonyElixir.Quota

  @type class :: :research | :issue | :pull_request | :final_attempt | :continuation
  @type t :: %{
          avoid: %{String.t() => String.t()},
          paused: String.t() | nil,
          over_budget: String.t() | nil,
          allow: [String.t()],
          budget_usd_micro: pos_integer() | nil,
          spent_usd_micro: non_neg_integer()
        }

  @doc "Evaluates the throttle settings against today's spend (micro-USD) and the quota."
  @spec evaluate(map(), Quota.t() | nil, non_neg_integer(), DateTime.t()) :: t()
  def evaluate(settings, quota, spent_usd_micro, %DateTime{} = now) do
    triggered = Enum.flat_map(settings.backoff, &trigger(&1, quota, now, settings))
    budget = if is_number(settings.daily_budget_usd), do: round(settings.daily_budget_usd * 1_000_000)

    %{
      avoid: Enum.reduce(triggered, %{}, fn {rule, reason}, acc -> Enum.reduce(Map.get(rule, "avoid", []), acc, &Map.put_new(&2, &1, reason)) end),
      paused: Enum.find_value(triggered, fn {rule, reason} -> if Map.get(rule, "pause") == true, do: reason end),
      over_budget: over_budget(budget, spent_usd_micro),
      allow: settings.over_budget_allow,
      budget_usd_micro: budget,
      spent_usd_micro: spent_usd_micro
    }
  end

  @doc "Whether a run of this class may start now."
  @spec admit(t() | nil, class()) :: :ok | {:wait, String.t()}
  def admit(%{paused: reason}, _class) when is_binary(reason), do: {:wait, "paused: #{reason}"}

  def admit(%{over_budget: reason, allow: allow}, class) when is_binary(reason) do
    if Atom.to_string(class) in allow, do: :ok, else: {:wait, "over budget: #{reason}"}
  end

  def admit(_policy, _class), do: :ok

  # Used share only grows within a window, so a stale reading below the
  # threshold still holds. Otherwise a stale or missing reading is unknown:
  # under `on_unknown_quota: restrict` it still avoids models, but it never
  # pauses, because only a run can observe the quota again.
  defp trigger(rule, quota, now, settings) do
    window = rule["window"]
    threshold = rule["remaining_below_percent"]
    restrict? = settings.on_unknown_quota == "restrict"

    case Quota.remaining(quota, window, now, settings.quota_stale_ms) do
      {state, remaining} when state in [:fresh, :stale] and remaining < threshold ->
        [{rule, "#{window} quota #{trunc(remaining)}% left"}]

      {state, _remaining} when state in [:fresh, :reset] ->
        []

      {:stale, _remaining} when restrict? ->
        [{Map.delete(rule, "pause"), "#{window} quota not seen recently"}]

      {:unknown, _remaining} when restrict? ->
        [{Map.delete(rule, "pause"), "#{window} quota not seen yet"}]

      _allowed ->
        []
    end
  end

  defp over_budget(budget, spent) when is_integer(budget) and spent >= budget, do: "#{usd(spent)} of #{usd(budget)} spent today"
  defp over_budget(_budget, _spent), do: nil

  defp usd(micro), do: :io_lib.format("$~.2f", [micro / 1_000_000]) |> to_string()
end
