defmodule SymphonyElixir.SchedulingTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Scheduling

  defp schedule(slots, projects), do: Scheduling.new(slots, Enum.map(projects, fn {id, weight} -> {id, weight, nil, "project"} end))

  # Every project always has work; whoever may take the free slot runs one item.
  defp run_rounds(schedule, ids, rounds) do
    Enum.reduce(1..rounds, {schedule, Map.new(ids, &{&1, 0})}, fn round, {schedule, counts} ->
      schedule = Enum.reduce(ids, schedule, &Scheduling.report_demand(&2, &1, 1))

      {winner, schedule} = Enum.reduce_while(ids, {nil, schedule}, &try_acquire(&1, &2, round))
      {schedule, _wake} = Scheduling.release(schedule, winner, "#{winner}-#{round}")
      {schedule, Map.update!(counts, winner, &(&1 + 1))}
    end)
  end

  defp try_acquire(id, {nil, schedule}, round) do
    case Scheduling.acquire(schedule, id, "#{id}-#{round}", :issue, 0) do
      {:ok, schedule} -> {:halt, {id, schedule}}
      {:wait, _reason, schedule, _wake} -> {:cont, {nil, schedule}}
    end
  end

  test "weights 3, 1, 1 share the slots about 3:1:1" do
    {_schedule, counts} = run_rounds(schedule(1, [{"metalrain", 3}, {"nubu3d", 1}, {"shimmer", 1}]), ["nubu3d", "shimmer", "metalrain"], 500)

    assert_in_delta counts["metalrain"], 300, 5
    assert_in_delta counts["nubu3d"], 100, 5
    assert_in_delta counts["shimmer"], 100, 5
  end

  test "equal weights alternate, and a project that asks out of turn is told who goes first" do
    {_schedule, counts} = run_rounds(schedule(1, [{"a", 1}, {"b", 1}]), ["a", "b"], 100)
    assert counts == %{"a" => 50, "b" => 50}

    s = schedule(2, [{"a", 1}, {"b", 1}]) |> Scheduling.report_demand("a", 2) |> Scheduling.report_demand("b", 2)
    assert {:ok, s} = Scheduling.acquire(s, "a", "a1", :issue, 0)
    assert {:wait, "the next slot is b's turn", s, ["b"]} = Scheduling.acquire(s, "a", "a2", :issue, 0)
    assert Scheduling.free_for(s, "a", 0) == 0
    assert Scheduling.free_for(s, "b", 0) == 1
    assert {:ok, s} = Scheduling.acquire(s, "b", "b1", :pull_request, 0)
    assert {:wait, "all 2 slots are busy", _s, []} = Scheduling.acquire(s, "b", "b2", :issue, 0)

    # Asking again for a held item is harmless, and a freed slot wakes the waiting project.
    assert {:ok, ^s} = Scheduling.acquire(s, "a", "a1", :issue, 0)
    assert {_s, ["a"]} = Scheduling.release(s, "b", "b1")
  end

  test "the heavier project goes first, and wins ties" do
    s = schedule(3, [{"metalrain", 4}, {"babelfit", 1}, {"dartboard", 1}])
    s = Enum.reduce(["metalrain", "babelfit", "dartboard"], s, &Scheduling.report_demand(&2, &1, 5))

    # Research and review elsewhere wait while the heavy project has work and a better turn.
    assert {:wait, "the next slot is metalrain's turn", s, ["metalrain"]} = Scheduling.acquire(s, "babelfit", "research:qa", :research, 0)
    {:ok, s} = Scheduling.acquire(s, "metalrain", "GH-1", :issue, 0)
    {:ok, s} = Scheduling.acquire(s, "metalrain", "GH-2", :issue, 0)
    {:ok, s} = Scheduling.acquire(s, "metalrain", "GH-3", :issue, 0)
    # At an equal pass (1.0) the heavier project still goes first.
    assert s.projects["metalrain"].pass == s.projects["babelfit"].pass
    {s, ["metalrain"]} = Scheduling.release(s, "metalrain", "GH-1")
    assert {:wait, "the next slot is metalrain's turn", _s, ["metalrain"]} = Scheduling.acquire(s, "dartboard", "PR-9", :pull_request, 0)

    {_s, counts} = run_rounds(schedule(1, [{"metalrain", 4}, {"babelfit", 1}, {"dartboard", 1}]), ["babelfit", "dartboard", "metalrain"], 600)
    assert_in_delta counts["metalrain"], 400, 5
  end

  test "caps limit a project on top of the shared slots" do
    s = Scheduling.new(3, [{"a", 1, 1, "project"}, {"b", 1, nil, "project"}]) |> Scheduling.report_demand("a", 3)
    assert {:ok, s} = Scheduling.acquire(s, "a", "a1", :issue, 0)
    assert {:wait, "a is at its cap of 1", s, []} = Scheduling.acquire(s, "a", "a2", :issue, 0)
    assert Scheduling.free_for(s, "a", 0) == 0
    # A capped project does not compete, so it never holds a slot back from others.
    assert {:ok, s} = Scheduling.acquire(s, "b", "b1", :issue, 0)
    assert {:ok, _s} = Scheduling.acquire(s, "b", "b2", :issue, 0)
  end

  test "a project back from idle does not spend credit it banked while idle" do
    s = schedule(1, [{"busy", 1}, {"idle", 1}])
    {s, _counts} = run_rounds(s, ["busy"], 20)
    assert s.projects["busy"].pass == 21.0

    s = s |> Scheduling.report_demand("busy", 1) |> Scheduling.report_demand("idle", 1)
    assert s.projects["idle"].pass == 21.0
    {_s, counts} = run_rounds(s, ["idle", "busy"], 10)
    assert counts == %{"busy" => 5, "idle" => 5}
  end

  test "global research waits for an idle service, holding it meanwhile, then has it to itself" do
    s = Scheduling.new(3, [{"metalrain", 1, nil, "global"}, {"nubu3d", 1, nil, "project"}])
    assert {:ok, s} = Scheduling.acquire(s, "nubu3d", "GH-1", :issue, 0)

    assert {:wait, "waiting for the service to go idle for research", s, []} = Scheduling.acquire(s, "metalrain", "research:qa", :research, 1_000)
    assert {:wait, "the service is held for metalrain's research", s, []} = Scheduling.acquire(s, "nubu3d", "GH-2", :issue, 2_000)
    assert Scheduling.free_for(s, "nubu3d", 2_000) == 0

    # A reservation that is not renewed lapses.
    assert {:ok, _s} = Scheduling.acquire(s, "nubu3d", "GH-2", :issue, 91_001)

    {s, _wake} = Scheduling.release(s, "nubu3d", "GH-1")
    assert {:ok, s} = Scheduling.acquire(s, "metalrain", "research:qa", :research, 3_000)
    assert s.reservation == nil
    assert {:wait, "metalrain is researching with the service to itself", _s, []} = Scheduling.acquire(s, "nubu3d", "GH-3", :pull_request, 4_000)

    # Research in other modes is an ordinary run.
    s = Scheduling.new(2, [{"a", 1, nil, "project"}, {"b", 1, nil, "none"}])
    assert {:ok, s} = Scheduling.acquire(s, "a", "research:x", :research, 0)
    assert {:ok, _s} = Scheduling.acquire(s, "b", "GH-1", :issue, 0)
  end

  test "a stopped project's slots and demand are forgotten" do
    s = schedule(2, [{"a", 1}, {"b", 1}])
    {:ok, s} = Scheduling.acquire(s, "a", "a1", :issue, 0)
    {:ok, s} = Scheduling.acquire(s, "a", "a2", :issue, 0)
    s = Scheduling.report_demand(s, "b", 1)
    assert Scheduling.used(s) == 2
    assert {s, ["b"]} = Scheduling.drop(s, "a")
    assert Scheduling.used(s) == 0
    assert s.projects["a"].demand == 0

    # Unknown projects are ignored.
    assert {^s, []} = Scheduling.drop(s, "zzz")
    assert {^s, []} = Scheduling.release(s, "zzz", "x")
    assert Scheduling.report_demand(s, "zzz", 3) == s
    assert {_s, []} = Scheduling.release(Scheduling.report_demand(s, "b", 0), "a", "a1")
  end
end
