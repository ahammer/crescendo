defmodule SymphonyElixir.QuotaTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Quota

  test "pacing uses observed epochs and resets on early drops rather than inventing natural weeks" do
    start = ~U[2026-10-07 00:00:00Z]
    deadline = DateTime.to_unix(DateTime.add(start, 4, :hour))
    first = Quota.normalize(%{"primary" => %{"usedPercent" => 10, "windowDurationMins" => 10_080, "resetsAt" => deadline}}, start)
    epoch = Quota.epoch(nil, nil, first)
    assert epoch.origin == "first_observation"
    assert Quota.pacing(first, epoch, start).signal == "on_pace"
    middle = DateTime.add(start, 2, :hour)
    assert Quota.pacing(%{first | observed_at: middle}, epoch, middle).signal == "behind"
    assert Quota.pacing(%{first | observed_at: middle}, epoch, middle).target_now_percent == 50.0
    high = put_in(first.windows["weekly"].used_percent, 75.0)
    assert Quota.pacing(%{high | observed_at: middle}, epoch, middle).signal == "ahead"
    assert Quota.pacing(first, epoch, DateTime.add(start, 3, :hour)).signal == "unknown"
    assert Quota.pacing(first, epoch, DateTime.from_unix!(deadline)).freshness == :reset
    assert Quota.pacing(nil, nil, start).signal == "unknown"
    assert Quota.epoch(epoch, first, put_in(first.windows["weekly"].resets_at, deadline + 5)) == epoch
    assert Quota.epoch(epoch, first, put_in(first.windows["weekly"].resets_at, deadline + 3600)).origin == "observed_reset"
    reset = put_in(first.windows["weekly"].used_percent, 0.0)
    assert Quota.epoch(epoch, first, reset).origin == "observed_reset"
    assert Quota.epoch(epoch, first, %{first | windows: %{}}) == nil
    assert Quota.epoch(epoch, first, put_in(first.windows["weekly"].resets_at, nil)) == epoch
  end

  @now ~U[2026-09-27 20:00:00Z]

  # The shape the v2 app server sends in `account/rateLimits/updated` for a Pro account.
  @v2 %{
    "credits" => %{"balance" => "0", "hasCredits" => false, "unlimited" => false},
    "individualLimit" => nil,
    "limitId" => "codex",
    "limitName" => nil,
    "planType" => "pro",
    "primary" => %{"resetsAt" => 1_790_716_234, "usedPercent" => 75, "windowDurationMins" => 10_080},
    "secondary" => nil
  }

  test "a v2 snapshot becomes windows named by their length" do
    assert %{limit_id: "codex", plan: "pro", observed_at: @now, windows: %{"weekly" => weekly}} = Quota.normalize(@v2, @now)
    assert weekly == %{name: "weekly", used_percent: 75.0, window_minutes: 10_080, resets_at: 1_790_716_234}
  end

  test "legacy snake_case snapshots and other window lengths normalize too" do
    raw = %{
      limit_id: "codex",
      plan_type: "plus",
      primary: %{used_percent: 12.5, window_minutes: 300, resets_at: "2026-09-27T23:00:00Z"},
      secondary: %{"used_percent" => 40, "window_minutes" => 1_440, "resets_at" => "not a time"}
    }

    assert %{limit_id: "codex", plan: "plus", windows: windows} = Quota.normalize(raw, @now)
    assert %{"5h" => %{used_percent: 12.5, resets_at: 1_790_550_000}} = windows
    assert %{"daily" => %{used_percent: 40.0, resets_at: nil}} = windows

    assert %{windows: %{"90m" => _}} = Quota.normalize(%{"primary" => %{"usedPercent" => 1, "windowDurationMins" => 90}}, @now)
    assert %{windows: %{"primary" => %{window_minutes: nil}}} = Quota.normalize(%{"primary" => %{"usedPercent" => 1}}, @now)
  end

  test "snapshots without a usable window are ignored" do
    assert Quota.normalize(%{"limitId" => "codex", "primary" => nil, "secondary" => %{"usedPercent" => "n/a"}}, @now) == nil
    assert Quota.normalize("nope", @now) == nil
  end

  test "remaining share reads fresh, stale, reset and unknown windows" do
    quota = Quota.normalize(@v2, @now)

    assert Quota.remaining(quota, "weekly", DateTime.add(@now, 60, :second), 7_200_000) == {:fresh, 25.0}
    assert Quota.remaining(quota, "weekly", DateTime.add(@now, 3, :hour), 7_200_000) == {:stale, 25.0}
    assert Quota.remaining(quota, "weekly", DateTime.from_unix!(1_790_716_234), 7_200_000) == {:reset, 100.0}
    assert Quota.remaining(quota, "5h", @now, 7_200_000) == {:unknown, nil}
    assert Quota.remaining(nil, "weekly", @now, 7_200_000) == {:unknown, nil}

    over = Quota.normalize(put_in(@v2, ["primary", "usedPercent"], 130), @now)
    assert Quota.remaining(over, "weekly", @now, 7_200_000) == {:fresh, 0.0}
  end
end
