defmodule SymphonyElixir.Quota do
  @moduledoc """
  Codex account quota: the latest rate-limit snapshot from the app server,
  normalized into windows keyed by their length (`weekly`, `daily`, `5h`, or
  `<n>m`) whatever the protocol calls them (`primary`/`secondary`, camelCase in
  the v2 app server, snake_case in older builds).

  `remaining/4` reads one window as a state and a remaining share: `:fresh`,
  `:stale` (older than the caller's limit; used share only grows within a
  window, so the stale value still bounds it), `:reset` (the window has rolled
  over since the snapshot), or `:unknown` (never observed).
  """

  @type window :: %{
          name: String.t(),
          used_percent: float(),
          window_minutes: pos_integer() | nil,
          resets_at: integer() | nil
        }
  @type t :: %{
          limit_id: String.t() | nil,
          plan: String.t() | nil,
          observed_at: DateTime.t(),
          windows: %{String.t() => window()}
        }
  @type state :: :fresh | :stale | :reset | :unknown

  @doc "Normalizes a raw rate-limit snapshot; nil when it carries no usable window."
  @spec normalize(term(), DateTime.t()) :: t() | nil
  def normalize(raw, %DateTime{} = observed_at) when is_map(raw) do
    windows =
      for key <- ["primary", "secondary"],
          %{} = window <- [get(raw, key)],
          normalized = window(key, window),
          normalized != nil,
          into: %{},
          do: {normalized.name, normalized}

    if windows == %{} do
      nil
    else
      %{
        limit_id: get(raw, "limitId") || get(raw, "limit_id"),
        plan: get(raw, "planType") || get(raw, "plan_type"),
        observed_at: observed_at,
        windows: windows
      }
    end
  end

  def normalize(_raw, _observed_at), do: nil

  @doc "The state and remaining percent (0-100) of one window."
  @spec remaining(t() | nil, String.t(), DateTime.t(), non_neg_integer()) :: {state(), float() | nil}
  def remaining(%{windows: windows} = snapshot, name, %DateTime{} = now, stale_after_ms) do
    case Map.get(windows, name) do
      nil -> {:unknown, nil}
      window -> window_state(snapshot, window, now, stale_after_ms)
    end
  end

  def remaining(_snapshot, _name, _now, _stale_after_ms), do: {:unknown, nil}

  @doc "Tracks observed weekly epochs, including an early usage drop or changed reset deadline."
  @spec epoch(map() | nil, t() | nil, t()) :: map() | nil
  def epoch(epoch, previous, %{windows: %{"weekly" => window}, observed_at: at}) do
    old = previous && previous.windows["weekly"]
    reset? = old && (window.used_percent + 0.1 < old.used_percent or changed_deadline?(old.resets_at, window.resets_at))

    if is_nil(epoch) or reset?,
      do: %{started_at: at, initial_used_percent: window.used_percent, origin: if(reset?, do: "observed_reset", else: "first_observation")},
      else: epoch
  end

  def epoch(_epoch, _previous, _quota), do: nil

  @doc "A soft 90% account-usage pacing target; admission remains owned by Throttle."
  @spec pacing(t() | nil, map() | nil, DateTime.t()) :: map()
  def pacing(%{windows: %{"weekly" => %{resets_at: deadline, used_percent: used}}} = quota, %{started_at: %DateTime{} = start, initial_used_percent: initial} = epoch, now) when is_integer(deadline) do
    {freshness, _remaining} = remaining(quota, "weekly", now, 7_200_000)
    horizon = max(deadline - DateTime.to_unix(start), 1)
    elapsed = min(max(DateTime.diff(now, start, :second), 0), horizon)
    target = initial + max(90.0 - initial, 0.0) * elapsed / horizon

    signal =
      cond do
        freshness != :fresh -> "unknown"
        used < target - 5 -> "behind"
        used > target + 5 -> "ahead"
        true -> "on_pace"
      end

    %{
      signal: signal,
      freshness: freshness,
      target_percent: 90,
      target_now_percent: Float.round(target, 1),
      used_percent: used,
      epoch_started_at: DateTime.to_iso8601(start),
      epoch_origin: epoch.origin,
      resets_at: deadline,
      interactive_allowance_percent: 10,
      scope: "account",
      projected_percent: if(elapsed >= 1_800, do: Float.round(initial + (used - initial) * horizon / elapsed, 1))
    }
  end

  def pacing(_quota, _epoch, _now), do: %{signal: "unknown", scope: "account", target_percent: 90, interactive_allowance_percent: 10}

  defp changed_deadline?(old, new) when is_integer(old) and is_integer(new), do: abs(old - new) > 60
  defp changed_deadline?(_old, _new), do: false

  defp window_state(snapshot, window, now, stale_after_ms) do
    remaining = max(100.0 - window.used_percent, 0.0)

    cond do
      is_integer(window.resets_at) and DateTime.to_unix(now) >= window.resets_at -> {:reset, 100.0}
      DateTime.diff(now, snapshot.observed_at, :millisecond) > stale_after_ms -> {:stale, remaining}
      true -> {:fresh, remaining}
    end
  end

  defp window(key, window) do
    used = get(window, "usedPercent") || get(window, "used_percent")
    minutes = get(window, "windowDurationMins") || get(window, "window_minutes")

    if is_number(used) do
      %{
        name: window_name(minutes, key),
        used_percent: used / 1,
        window_minutes: if(is_integer(minutes), do: minutes),
        resets_at: resets_at(get(window, "resetsAt") || get(window, "resets_at"))
      }
    end
  end

  # Windows are named by length so rules survive a provider renaming primary
  # and secondary; an unknown length keeps the protocol's own name.
  defp window_name(10_080, _key), do: "weekly"
  defp window_name(1_440, _key), do: "daily"
  defp window_name(minutes, _key) when is_integer(minutes) and minutes > 0 and rem(minutes, 60) == 0, do: "#{div(minutes, 60)}h"
  defp window_name(minutes, _key) when is_integer(minutes) and minutes > 0, do: "#{minutes}m"
  defp window_name(_minutes, key), do: key

  defp resets_at(seconds) when is_integer(seconds), do: seconds

  defp resets_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> DateTime.to_unix(at)
      _ -> nil
    end
  end

  defp resets_at(_value), do: nil

  defp get(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_atom(key))
    end
  end
end
