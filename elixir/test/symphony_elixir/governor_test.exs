defmodule SymphonyElixir.GovernorTest do
  use ExUnit.Case

  alias SymphonyElixir.{Governor, Project, Quota, Service}

  test "the cached local schedule refreshes on the next day and remains unknown until observed", %{service: service} do
    service = %{service | quiet_window: %Service.QuietWindow{}}
    Application.put_env(:symphony_elixir, :governor_now, fn -> ~U[2026-10-08 10:00:00Z] end)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :governor_now) end)
    start_supervised!({Governor, service})
    Governor.checkin("a", 0, 0, 1)
    Governor.checkin("b", 0, 0)
    assert Governor.snapshot().quiet_window.phase == "active"
    Application.put_env(:symphony_elixir, :governor_now, fn -> ~U[2026-10-09 10:00:00Z] end)
    assert Governor.snapshot().quiet_window.phase == "unknown"
    assert {:wait, _} = Governor.acquire("a", "acceptance", :issue, quiet: true)
    send(Process.whereis(Governor), :helper_heartbeat)
    assert Governor.snapshot().quiet_window.phase == "active"
  end

  test "pending quiet work drains at turn boundaries, waits for all capacity, and releases after its window", %{service: service} do
    service = %{service | quiet_window: %Service.QuietWindow{}}
    Application.put_env(:symphony_elixir, :governor_now, fn -> ~U[2026-10-08 08:00:00Z] end)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :governor_now) end)
    start_supervised!({Governor, service})
    Governor.checkin("a", 0, 0, 1)
    Governor.checkin("b", 0, 0)
    assert {:wait, "waiting for the owner-confirmed quiet acceptance window"} = Governor.acquire("a", "acceptance", :issue, quiet: true)
    assert :ok = Governor.acquire("b", "ordinary", :issue)
    Application.put_env(:symphony_elixir, :governor_now, fn -> ~U[2026-10-08 09:30:00Z] end)
    assert Governor.draining?()
    assert Governor.checkin("a", 0, 0, 1).slots == 0
    assert {:wait, "draining for a deploy"} = Governor.acquire("b", "new", :issue)
    Application.put_env(:symphony_elixir, :governor_now, fn -> ~U[2026-10-08 10:00:00Z] end)
    refute Governor.draining?()
    assert {:wait, "holding the service for quiet acceptance"} = Governor.acquire("b", "new", :issue)
    assert {:wait, _} = Governor.acquire("a", "acceptance", :issue, quiet: true)
    Governor.release("b", "ordinary")
    assert :ok = Governor.acquire("a", "acceptance", :issue, quiet: true)
    assert Governor.snapshot().busy == 1
    assert Governor.snapshot().quiet_window.phase == "active"
    Application.put_env(:symphony_elixir, :governor_now, fn -> ~U[2026-10-08 11:00:00Z] end)
    assert Governor.draining?()
    Governor.release("a", "acceptance")
    refute Governor.draining?()
    assert :ok = Governor.acquire("b", "new", :issue)
    Governor.checkin("a", 0, 0, 0)
    assert Governor.snapshot().quiet_window == %{phase: "idle"}
  end

  test "helper history is bounded, raw exits fail visibly, and start errors do not consume capacity", %{service: service, state_root: root} do
    {service, context} = helper_fixture(service, root, 2)
    start_supervised!({Governor, service})
    Governor.checkin("a", 0, 0)
    Governor.checkin("b", 0, 0)
    Governor.acquire("a", "parent", :issue)
    Application.put_env(:symphony_elixir, :helper_runner, fn _, _, _ -> receive do: (:stop -> {:ok, %{}}) end)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :helper_runner) end)
    assert {:ok, first} = Governor.helper_start(context, %{"question" => "Inspect"})
    child = :sys.get_state(Governor).helpers[first.helper_id].pid
    Process.exit(child, :kill)
    assert_eventually(fn -> Governor.snapshot().helpers.busy == 0 end)
    assert {:ok, %{status: "failed"}} = Governor.helper_status(first.helper_id)

    :sys.replace_state(Governor, fn state ->
      sample = state.helpers[first.helper_id]
      %{state | helpers: Map.new(1..130, fn n -> {"old-#{n}", %{sample | id: "old-#{n}"}} end)}
    end)

    assert {:ok, _} = Governor.helper_start(context, %{"question" => "Inspect"})
    assert map_size(:sys.get_state(Governor).helpers) == 128
    start_supervised!({Task.Supervisor, name: Project.via("b", :task_supervisor), max_children: 0}, id: :rejected_helpers)
    Governor.acquire("b", "other-parent", :issue)
    other_context = %{context | project: "b", issue_id: "other-parent"}
    assert {:error, {:helper_start_failed, :max_children}} = Governor.helper_start(other_context, %{"question" => "Inspect"})
    assert SymphonyElixir.Helpers.execute("helper_status", %{"helper_id" => "missing"}, context)["success"] == false
    assert SymphonyElixir.Helpers.execute("helper_start", %{"question" => "Inspect"}, context)["success"] == true
    state = :sys.get_state(Governor)
    id = Enum.find_value(state.helpers, fn {id, helper} -> if is_pid(helper.pid), do: id end)
    assert SymphonyElixir.Helpers.execute("helper_cancel", %{"helper_id" => id}, context)["success"] == true
    stop_supervised!(Governor)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "quota-epoch.term"), "corrupt")
    start_supervised!({Governor, service})
    assert Governor.snapshot().pacing.signal == "unknown"
  end

  test "five helpers share one global cap without taking primary slots; completion events stay ordered", %{service: service, state_root: root} do
    {service, context} = helper_fixture(service, root, 5)
    start_supervised!({Governor, service})
    Governor.checkin("a", 0, 0)
    Governor.checkin("b", 0, 0)
    assert :ok = Governor.acquire("a", "parent", :issue)
    assert :ok = Governor.acquire("b", "other-parent", :issue)
    parent = self()

    Application.put_env(:symphony_elixir, :helper_runner, fn prepared, details, _ ->
      send(parent, {:helper_running, self(), details.run_id})
      receive do: (:complete -> :ok)
      usage = %{event: :observed_usage, timestamp: DateTime.utc_now(), total_tokens: 123}
      send(prepared.context.recipient, {:helper_update, details, usage})
      {:ok, %{summary: "done", source_sha: prepared.source_sha}}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :helper_runner) end)

    helpers =
      for n <- 1..5 do
        ctx = if rem(n, 2) == 0, do: %{context | project: "b", issue_id: "other-parent"}, else: context
        assert {:ok, helper} = Governor.helper_start(ctx, %{"question" => "Inspect #{n}"})
        assert_receive {:helper_running, pid, id}
        assert id == helper.helper_id
        {pid, helper}
      end

    assert %{busy: 2, helpers: %{busy: 5, slots: 5}} = Governor.snapshot()
    assert {:error, :helper_capacity} = Governor.helper_start(context, %{"question" => "Sixth"})
    assert {:error, :helper_not_found} = Task.async(fn -> Governor.helper_status(elem(hd(helpers), 1).helper_id) end) |> Task.await()
    assert Governor.observe().helpers.busy == 5

    {pid, first} = hd(helpers)
    assert {:ok, %{status: "running"}} = Governor.helper_status(first.helper_id)
    send(pid, :complete)
    assert_receive {:helper_update, %{run_id: id}, %{event: :helper_started}}
    assert id == first.helper_id
    assert_receive {:helper_update, %{run_id: ^id}, %{event: :observed_usage}}
    assert_receive {:helper_update, %{run_id: ^id}, %{event: :helper_finished, status: "completed"}}
    assert %{helpers: %{busy: 4}, busy: 2} = Governor.snapshot()
    assert {:ok, %{status: "completed", result: %{summary: "done"}}} = Governor.helper_status(id)

    send(Process.whereis(Governor), :helper_heartbeat)
    assert_receive {:helper_update, _, %{event: :helper_heartbeat}}
    Governor.cancel_helpers(self())

    for {pid, _helper} <- tl(helpers) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
    end

    assert_eventually(fn -> Governor.snapshot().helpers.busy == 0 end)
    assert :ok = SymphonyElixir.Helpers.cancel_owned()
    assert Governor.snapshot().busy == 2
  end

  test "helpers refuse drain, quiet reservations and throttle; cancel retains the PID until DOWN", %{service: service, state_root: root} do
    {service, context} = helper_fixture(service, root, 2)
    start_supervised!({Governor, service})
    Governor.checkin("a", 0, 0)
    Governor.checkin("b", 0, 0)
    assert :ok = Governor.acquire("a", "parent", :issue)
    assert {:error, :parent_not_running} = Governor.helper_start(%{context | issue_id: "missing"}, %{"question" => "Inspect"})
    File.mkdir_p!(root)
    File.write!(Path.join(root, "drain"), "")
    assert {:error, :service_draining_or_starting} = Governor.helper_start(context, %{"question" => "Inspect"})
    File.rm!(Path.join(root, "drain"))
    assert {:wait, _} = Governor.acquire("b", "quiet", :research, exclusive: "global")
    assert {:error, :quiet_research_reserved} = Governor.helper_start(context, %{"question" => "Inspect"})
    :sys.replace_state(Governor, fn state -> put_in(state.schedule.reservation, nil) end)
    Governor.checkin("a", 11_000_000, 0)
    assert {:error, :helper_throttled} = Governor.helper_start(context, %{"question" => "Inspect"})
    Governor.checkin("a", 0, 0)

    Application.put_env(:symphony_elixir, :helper_runner, fn _, _, _ -> receive do: (:stop -> {:ok, %{}}) end)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :helper_runner) end)
    assert {:ok, helper} = Governor.helper_start(context, %{"question" => "Inspect"})
    state = :sys.get_state(Governor)
    assert {:ok, %{status: "cancelling"}} = Governor.helper_cancel(helper.helper_id)
    request = {:helper_cancel, helper.helper_id}
    assert {:reply, {:ok, %{status: "cancelling"}}, cancelled} = Governor.handle_call(request, {self(), make_ref()}, state)
    assert is_pid(cancelled.helpers[helper.helper_id].pid)
    assert_eventually(fn -> Governor.snapshot().helpers.busy == 0 end)
    assert {:ok, %{status: "stopped"}} = Governor.helper_status(helper.helper_id)
    assert {:ok, %{status: "stopped"}} = Governor.helper_cancel(helper.helper_id)
    send(Process.whereis(Governor), {:helper_result, helper.helper_id, {:ok, %{summary: "stale"}}})
    send(Process.whereis(Governor), {:helper_timeout, helper.helper_id})
    send(Process.whereis(Governor), {:helper_update, helper, %{event: :stale}})
    assert {:ok, %{status: "stopped"}} = Governor.helper_status(helper.helper_id)
  end

  test "parent exit, absolute timeout, runner failure and absent supervision free helper capacity", %{service: service, state_root: root} do
    {service, context} = helper_fixture(service, root, 2)
    start_supervised!({Governor, service})
    Governor.checkin("a", 0, 0)
    Governor.checkin("b", 0, 0)
    Governor.acquire("a", "parent", :issue)
    Application.put_env(:symphony_elixir, :helper_runner, fn _, _, _ -> receive do: (:stop -> {:ok, %{}}) end)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :helper_runner) end)
    recipient = self()

    owner =
      spawn(fn ->
        send(recipient, {:started, Governor.helper_start(context, %{"question" => "Inspect"})})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:started, {:ok, helper}}
    send(owner, :stop)
    assert_eventually(fn -> Governor.snapshot().helpers.busy == 0 end)
    refute Process.alive?(owner)
    assert {:error, :helper_not_found} = Governor.helper_status(helper.helper_id)

    assert {:ok, helper} = Governor.helper_start(context, %{"question" => "Inspect"})
    send(Process.whereis(Governor), {:helper_timeout, helper.helper_id})
    assert_eventually(fn -> Governor.snapshot().helpers.busy == 0 end)
    assert {:ok, %{status: "failed", result: %{error: error}}} = Governor.helper_status(helper.helper_id)
    assert error =~ "helper_timeout"
    Application.put_env(:symphony_elixir, :helper_runner, fn _, _, _ -> raise "failure" end)
    assert {:ok, helper} = Governor.helper_start(context, %{"question" => "Inspect"})
    assert_eventually(fn -> Governor.snapshot().helpers.busy == 0 end)
    assert {:ok, %{status: "failed"}} = Governor.helper_status(helper.helper_id)
    Application.put_env(:symphony_elixir, :helper_runner, fn _, _, _ -> throw(:failure) end)
    assert {:ok, _} = Governor.helper_start(context, %{"question" => "Inspect"})
    assert_eventually(fn -> Governor.snapshot().helpers.busy == 0 end)
    Governor.acquire("b", "other-parent", :issue)
    other_context = %{context | project: "b", issue_id: "other-parent"}
    assert {:error, :helper_supervisor_unavailable} = Governor.helper_start(other_context, %{"question" => "Inspect"})
    :sys.replace_state(Governor, fn state -> put_in(state.service.helpers.slots, 0) end)
    assert {:error, :helpers_disabled} = Governor.helper_start(context, %{"question" => "Inspect"})
  end

  defp helper_fixture(service, root, slots) do
    workspace = Path.join(root, "source")
    File.mkdir_p!(workspace)
    System.cmd("git", ["init", "-q"], cd: workspace)
    System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "--allow-empty", "-qm", "source"], cd: workspace)
    start_supervised!({Task.Supervisor, name: Project.via("a", :task_supervisor)})
    service = %{service | helpers: %Service.Helpers{slots: slots}}
    # The second supervisor is needed only by the cross-project capacity test.
    if slots == 5, do: start_supervised!({Task.Supervisor, name: Project.via("b", :task_supervisor)}, id: :other_helpers)
    context = %{workspace: workspace, run_id: "parent-run", project: "a", issue_id: "parent", recipient: self()}
    {service, context}
  end

  defp assert_eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("helper lifecycle did not settle")
      true -> Process.sleep(10) && assert_eventually(fun, attempts - 1)
    end
  end

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

  test "capacity observations follow reservation, expiry, research and drain lifecycle", %{service: service, state_root: root} do
    assert Governor.observe() == nil

    global = %{
      service
      | project_list:
          Enum.map(service.project_list, fn project ->
            if project.id == "a", do: %{project | research_exclusive: "global"}, else: project
          end)
    }

    start_supervised!({Governor, global})
    Governor.checkin("a", 0, 0)
    Governor.checkin("b", 0, 0)
    assert :ok = Governor.acquire("b", "private-task", :issue)
    assert {:wait, _} = Governor.acquire("a", "research:secret", :research)
    reserved = Governor.observe()
    assert %{slots: 2, busy: 1, source: "governor", scope: "service", draining: false} = reserved
    assert reserved.research_hold == %{project: "a", phase: "reserved"}
    assert {:ok, _, _} = DateTime.from_iso8601(reserved.observed_at)
    refute inspect(reserved) =~ "secret"
    refute inspect(reserved) =~ "private-task"
    refute inspect(reserved) =~ root

    # Place the real Governor's reservation exactly at the expiry boundary.
    :sys.replace_state(Governor, fn state ->
      put_in(state.schedule.reservation.until_ms, System.monotonic_time(:millisecond))
    end)

    assert Governor.observe().research_hold == nil
    assert {:wait, _} = Governor.acquire("a", "research:secret", :research)
    Governor.release("b", "private-task")
    assert :ok = Governor.acquire("a", "research:secret", :research)
    assert %{busy: 1, research_hold: %{project: "a", phase: "running"}} = Governor.observe()
    Governor.release("a", "research:secret")
    assert %{busy: 0, research_hold: nil} = Governor.observe()
    assert :ok = Governor.acquire("b", "research:none", :research)
    assert Governor.observe().research_hold == nil
    Governor.release("b", "research:none")

    File.mkdir_p!(root)
    File.write!(Path.join(root, "drain"), "")
    assert Governor.observe().draining
    File.rm!(Path.join(root, "drain"))
    refute Governor.observe().draining
    stop_supervised!(Governor)
    assert Governor.observe() == nil

    start_supervised!({Governor, service})
    Governor.checkin("a", 0, 0)
    Governor.checkin("b", 0, 0)
    assert :ok = Governor.acquire("a", "research:project", :research)
    assert Governor.observe().research_hold == nil
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
