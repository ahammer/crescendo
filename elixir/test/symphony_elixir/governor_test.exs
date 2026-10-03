defmodule SymphonyElixir.GovernorTest do
  use ExUnit.Case

  alias SymphonyElixir.{Governor, Project, Quota, Service}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-governor-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    raw = %{
      "paths" => %{"state" => "state"},
      "pool" => %{"slots" => 2},
      "throttle" => %{"daily_budget_usd" => 10, "backoff" => [%{"window" => "weekly", "remaining_below_percent" => 40, "avoid" => ["gpt-6-astra"]}]},
      "projects" => %{"a" => %{}, "b" => %{"research_exclusive" => "none"}}
    }

    {:ok, service} = Service.parse(raw, Path.join(root, "crescendo.yml"))
    %{service: service, state_root: Path.join(root, "state")}
  end

  defp quota(used, observed_at \\ DateTime.utc_now()),
    do: Quota.normalize(%{"primary" => %{"usedPercent" => used, "windowDurationMins" => 10_080}}, observed_at)

  test "check-ins share one budget across projects and return each project's slots", %{service: service} do
    start_supervised!({Governor, service})
    assert Governor.running?()
    refute Governor.draining?()

    assert %{slots: 2, over_budget: nil, research_exclusive: "project", draining: false} = Governor.checkin("a", 6_000_000, 1)
    # Unknown quota restricts Astra until a run reports it.
    assert %{avoid: %{"gpt-6-astra" => "weekly quota not seen yet"}} = Governor.checkin("b", 5_000_000, 0)

    assert %{over_budget: "$11.00 of $10.00 spent today", research_exclusive: "none"} = Governor.checkin("b", 5_000_000, 0)
    assert %{spend_micro: 11_000_000, slots: 2, busy: 0, projects: projects} = Governor.snapshot()
    assert [%{id: "a", waiting: 1}, %{id: "b", waiting: 0}] = projects
  end

  test "slots are acquired, kept for the project whose turn it is, and released", %{service: service} do
    start_supervised!({Governor, service})
    {:ok, _owner} = Registry.register(SymphonyElixir.ProjectRegistry, {:orchestrator, "b"}, nil)

    Governor.checkin("a", 0, 2)
    Governor.checkin("b", 0, 1)
    assert :ok = Governor.acquire("a", "GH-1", :issue)
    assert {:wait, "the next slot is b's turn"} = Governor.acquire("a", "GH-2", :issue)
    assert_receive :governor_wake
    assert :ok = Governor.acquire("b", "GH-9", :pull_request)
    assert {:wait, "all 2 slots are busy"} = Governor.acquire("a", "GH-2", :issue)

    :ok = Governor.release("a", "GH-1")
    assert %{busy: 1} = Governor.snapshot()
  end

  test "after a start no slot is granted until every project checks in", %{service: service} do
    Application.put_env(:symphony_elixir, :governor_warm_up_ms, 60_000)
    on_exit(fn -> Application.put_env(:symphony_elixir, :governor_warm_up_ms, 0) end)
    start_supervised!({Governor, service})
    {:ok, _owner} = Registry.register(SymphonyElixir.ProjectRegistry, {:orchestrator, "a"}, nil)

    assert %{slots: 0} = Governor.checkin("a", 0, 3)
    assert {:wait, "starting up: waiting for every project to check in"} = Governor.acquire("a", "GH-1", :issue)
    refute_received :governor_wake

    # The last check-in ends the warm-up and wakes the others to poll now.
    assert %{slots: 2} = Governor.checkin("b", 0, 0)
    assert_receive :governor_wake
    assert :ok = Governor.acquire("a", "GH-1", :issue)
  end

  test "the drain flag holds all new dispatch", %{service: service, state_root: state_root} do
    start_supervised!({Governor, service})
    File.mkdir_p!(state_root)
    File.write!(Path.join(state_root, "drain"), "")

    assert {:wait, "draining for a deploy"} = Governor.acquire("a", "GH-1", :pull_request)
    assert Governor.draining?()
    assert %{slots: 0, draining: true} = Governor.checkin("a", 0, 1)
  end

  test "the newest quota is shared and survives a restart", %{service: service, state_root: state_root} do
    start_supervised!({Governor, service})
    newer = quota(75)
    Governor.report_quota(newer)
    Governor.report_quota(quota(10, DateTime.add(DateTime.utc_now(), -60, :second)))
    Governor.report_quota(%{not: :a_quota})

    assert %{quota: ^newer, throttle: %{avoid: %{"gpt-6-astra" => "weekly quota 25% left"}}} = Governor.snapshot()
    assert File.exists?(Path.join(state_root, "quota.term"))

    stop_supervised!(Governor)
    start_supervised!({Governor, service})
    assert %{quota: ^newer} = Governor.snapshot()

    stop_supervised!(Governor)
    File.write!(Path.join(state_root, "quota.term"), "not a term")
    start_supervised!({Governor, service})
    assert %{quota: nil} = Governor.snapshot()
  end

  test "an unwritable state directory only loses the saved quota", %{service: service, state_root: state_root} do
    File.write!(state_root, "a file where the directory should be")
    start_supervised!({Governor, service})

    ExUnit.CaptureLog.capture_log(fn ->
      Governor.report_quota(quota(20))
      assert %{quota: %{}} = Governor.snapshot()
    end) =~ "Could not save the Codex quota"
  end

  test "a stopped orchestrator's slots are freed", %{service: service} do
    start_supervised!({Governor, service})
    parent = self()

    orchestrator =
      spawn(fn ->
        Governor.checkin("a", 0, 1)
        send(parent, {:acquired, Governor.acquire("a", "GH-1", :issue), Governor.acquire("a", "GH-2", :issue)})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:acquired, :ok, :ok}
    assert %{busy: 2} = Governor.snapshot()

    ExUnit.CaptureLog.capture_log(fn ->
      send(orchestrator, :stop)
      Process.sleep(50)
      assert %{busy: 0} = Governor.snapshot()
    end)

    # A new orchestrator for the project replaces the old monitor.
    Governor.checkin("a", 0, 0)
    spawn(fn -> Governor.checkin("a", 0, 0) end)
    Process.sleep(20)
    send(Process.whereis(Governor), :unrelated)
    send(Process.whereis(Governor), {:DOWN, make_ref(), :process, self(), :normal})
    assert %{busy: 0} = Governor.snapshot()
    assert Project.via("a", :orchestrator) |> GenServer.whereis() == nil
  end
end
