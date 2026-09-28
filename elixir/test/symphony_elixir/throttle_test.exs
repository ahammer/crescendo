defmodule SymphonyElixir.ThrottleTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{Quota, Throttle}

  @now ~U[2026-09-27 20:00:00Z]
  @astra_rule %{"window" => "weekly", "remaining_below_percent" => 40, "avoid" => ["gpt-6-astra"]}
  @pause_rule %{"window" => "weekly", "remaining_below_percent" => 3, "pause" => true}

  defp settings(overrides \\ %{}) do
    {:ok, settings} = Schema.parse(%{"throttle" => Map.merge(%{"backoff" => [@astra_rule, @pause_rule]}, overrides)})
    settings.throttle
  end

  defp quota(used_percent, observed_at \\ @now) do
    Quota.normalize(%{"primary" => %{"usedPercent" => used_percent, "windowDurationMins" => 10_080, "resetsAt" => 1_790_716_234}}, observed_at)
  end

  test "defaults keep closing work over budget and restrict on unknown quota" do
    assert %{daily_budget_usd: nil, over_budget_allow: ["pull_request", "final_attempt", "continuation"], backoff: [], on_unknown_quota: "restrict"} =
             settings(%{"backoff" => []})

    assert Throttle.evaluate(settings(%{"backoff" => []}), nil, 5_000_000, @now) == %{
             avoid: %{},
             paused: nil,
             over_budget: nil,
             allow: ["pull_request", "final_attempt", "continuation"],
             budget_usd_micro: nil,
             spent_usd_micro: 5_000_000
           }

    assert Throttle.admit(nil, :issue) == :ok
  end

  test "over budget only closing work starts" do
    policy = Throttle.evaluate(settings(%{"daily_budget_usd" => 200}), quota(10), 201_400_000, @now)

    assert policy.over_budget == "$201.40 of $200.00 spent today"
    assert policy.budget_usd_micro == 200_000_000
    assert Throttle.admit(policy, :issue) == {:wait, "over budget: $201.40 of $200.00 spent today"}
    assert {:wait, _} = Throttle.admit(policy, :research)

    for class <- [:pull_request, :final_attempt, :continuation], do: assert(Throttle.admit(policy, class) == :ok)

    under = Throttle.evaluate(settings(%{"daily_budget_usd" => 200}), quota(10), 199_000_000, @now)
    assert under.over_budget == nil
    assert Throttle.admit(under, :research) == :ok
  end

  test "a low weekly quota backs Astra off, and a nearly spent one pauses every run" do
    assert %{avoid: %{"gpt-6-astra" => "weekly quota 25% left"}, paused: nil} = Throttle.evaluate(settings(), quota(75), 0, @now)
    assert %{avoid: avoid, paused: nil} = Throttle.evaluate(settings(), quota(40), 0, @now)
    assert avoid == %{}

    paused = Throttle.evaluate(settings(), quota(98.5), 0, @now)
    assert paused.paused == "weekly quota 1% left"
    assert paused.avoid == %{"gpt-6-astra" => "weekly quota 1% left"}
    assert Throttle.admit(paused, :pull_request) == {:wait, "paused: weekly quota 1% left"}
  end

  test "stale, reset and unknown quota readings" do
    # A stale reading below the threshold still holds: used share only grows within a window.
    stale = quota(75, DateTime.add(@now, -3, :hour))
    assert %{avoid: %{"gpt-6-astra" => "weekly quota 25% left"}} = Throttle.evaluate(settings(), stale, 0, @now)

    stale_high = quota(20, DateTime.add(@now, -3, :hour))
    assert %{avoid: %{"gpt-6-astra" => "weekly quota not seen recently"}, paused: nil} = Throttle.evaluate(settings(), stale_high, 0, @now)
    assert %{avoid: %{}} = Throttle.evaluate(settings(%{"on_unknown_quota" => "allow"}), stale_high, 0, @now)

    # Unknown quota avoids models but never pauses: only a run can observe the quota again.
    assert %{avoid: %{"gpt-6-astra" => "weekly quota not seen yet"}, paused: nil} = Throttle.evaluate(settings(), nil, 0, @now)
    assert %{avoid: %{}, paused: nil} = Throttle.evaluate(settings(%{"on_unknown_quota" => "allow"}), nil, 0, @now)

    # Once the window has reset the old reading no longer counts.
    assert %{avoid: %{}, paused: nil} = Throttle.evaluate(settings(), quota(99), 0, DateTime.from_unix!(1_790_716_234))
  end

  test "throttle settings are validated" do
    for {throttle, message} <- [
          {%{"daily_budget_usd" => 0}, "daily_budget_usd"},
          {%{"over_budget_allow" => ["pull_request", "everything"]}, "over_budget_allow"},
          {%{"quota_stale_ms" => 0}, "quota_stale_ms"},
          {%{"on_unknown_quota" => "panic"}, "on_unknown_quota"},
          {%{"backoff" => [%{"window" => "weekly", "remaining_below_percent" => 40}]}, "backoff"},
          {%{"backoff" => [Map.put(@astra_rule, "remaining_below_percent", 0)]}, "backoff"},
          {%{"backoff" => [Map.put(@astra_rule, "avoid", [" "])]}, "backoff"},
          {%{"backoff" => [Map.put(@astra_rule, "pause", "yes")]}, "backoff"},
          {%{"backoff" => [Map.put(@astra_rule, "models", ["x"])]}, "backoff"},
          {%{"backoff" => ["weekly"]}, "backoff"}
        ] do
      assert {:error, {:invalid_workflow_config, error}} = Schema.parse(%{"throttle" => throttle})
      assert error =~ message
    end
  end
end
