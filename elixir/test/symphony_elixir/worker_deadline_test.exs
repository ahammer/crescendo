defmodule SymphonyElixir.WorkerDeadlineTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Governor, Project, Projects, Service}

  defmodule RetryTracker do
    alias SymphonyElixir.Tracker.Memory
    def fetch_issues_by_states(states), do: Memory.fetch_issues_by_states(states)

    def fetch_issues_by_ids(["research:" <> _]), do: {:error, :invalid_github_issue_id}

    def fetch_issues_by_ids(ids) do
      if Application.get_env(:symphony_elixir, :startup_tracker_down) do
        {:error, :offline_tracker}
      else
        Memory.fetch_issues_by_ids(ids)
      end
    end
  end

  defmodule ReviewCI do
    def fetch_commit_ci_state(_sha), do: {:ok, "success"}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "worker-deadline-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "workspace hooks and cleanup outlive Codex inactivity, including a config reload", %{root: root} do
    ctx =
      start_worker(root,
        hook_after_create: "echo started > after_create; sleep 0.7; echo done >> after_create",
        hook_before_run: "echo started > before_run; sleep 0.7; echo done >> before_run",
        hook_after_run: "echo started > after_run; sleep 0.7; echo done >> after_run"
      )

    entry = await_entry(ctx, :workspace)
    assert %{busy: 1} = Governor.snapshot()
    await(fn -> File.exists?(Path.join(ctx.workspace, "after_create")) end)
    Process.sleep(150)
    assert state(ctx).running[ctx.issue.id].pid == entry.pid
    refute Map.has_key?(state(ctx).retry_attempts, ctx.issue.id)

    write_workflow_file!(ctx.workflow, Keyword.put(ctx.config, :codex_stall_timeout_ms, 500))
    assert :ok = Project.with_project("deadline", &WorkflowStore.force_reload/0)
    await(fn -> File.exists?(Path.join(ctx.workspace, "before_run")) end)
    Process.sleep(150)
    assert state(ctx).running[ctx.issue.id].pid == entry.pid

    cleanup = await_entry(ctx, :cleanup)
    send(ctx.orchestrator, {:worker_phase, ctx.issue.id, self(), :codex})
    send(ctx.orchestrator, {:worker_phase, "missing", entry.pid, :codex})
    assert state(ctx).running[ctx.issue.id].phase == :cleanup
    assert cleanup.pid == entry.pid
    assert cleanup.session_id == "thread-deadline-turn-deadline"
    Process.sleep(150)
    assert state(ctx).running[ctx.issue.id].phase == :cleanup
    assert %{busy: 1} = Governor.snapshot()
    await(fn -> Map.has_key?(state(ctx).retry_attempts, ctx.issue.id) end)
    assert state(ctx).retry_attempts[ctx.issue.id].error == nil
    assert %{busy: 0} = Governor.snapshot()
    assert File.read!(Path.join(root, "sessions")) == "start\n"

    for hook <- ["after_create", "before_run", "after_run"] do
      assert File.read!(Path.join(ctx.workspace, hook)) == "started\ndone\n"
    end
  end

  test "admitted protocol overflow interrupts and retries without failing the implementation attempt", %{root: root} do
    ctx = start_worker(root, [hook_before_run: "sleep 0.2", max_attempts: 1], :protocol_overflow)
    entry = await_entry(ctx, :workspace)
    await(fn -> Map.has_key?(state(ctx).retry_attempts, ctx.issue.id) end)
    current = state(ctx)
    retry = current.retry_attempts[ctx.issue.id]
    assert retry.attempt == 0
    assert retry.error =~ "frame_assembly"
    assert current.startup_failures == %{}
    assert current.blocked == %{}
    assert current.autopilot.item_attempts == %{}
    refute MapSet.member?(current.completed, ctx.issue.id)
    assert %{busy: 0} = Governor.snapshot()

    assert [{_, %{status: "interrupted", reason: "protocol_buffer_overflow"}}] =
             :dets.lookup(current.operations, {:lineage_run, entry.run_id})

    send(ctx.orchestrator, {:DOWN, entry.ref, :process, entry.pid, :normal})
    assert state(ctx).retry_attempts[ctx.issue.id].retry_token == retry.retry_token
    refute Enum.any?(SymphonyElixir.Operations.snapshot(current.operations).activity, &(&1.kind == "attempt_failed"))
  end

  test "an over-deadline hook releases its slot and retries once", %{root: root} do
    ctx = start_worker(root, hook_after_create: "exec sleep 0.3", hook_timeout_ms: 200)
    entry = await_entry(ctx, :workspace)
    ref = Process.monitor(entry.pid)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    await(fn -> Map.has_key?(state(ctx).retry_attempts, ctx.issue.id) end)
    retry = state(ctx).retry_attempts[ctx.issue.id]
    assert retry.attempt == 0
    assert retry.error =~ "workspace_hook_timeout"
    assert %{busy: 0} = Governor.snapshot()
    refute File.exists?(Path.join(root, "sessions"))
    refute File.exists?(ctx.workspace)

    config = Keyword.merge(ctx.config, hook_after_create: nil, hook_before_run: "exec sleep 0.3", hook_timeout_ms: 1_500)
    write_workflow_file!(ctx.workflow, config)
    assert :ok = Project.with_project("deadline", &WorkflowStore.force_reload/0)
    send(ctx.orchestrator, {:retry_issue, ctx.issue.id, retry.retry_token})
    replacement = await_entry(ctx, :workspace)
    assert replacement.pid != entry.pid
    # Old notifications cannot release or alter the replacement's slot.
    send(ctx.orchestrator, {:DOWN, entry.ref, :process, entry.pid, :normal})
    send(ctx.orchestrator, {:worker_phase, ctx.issue.id, entry.pid, :cleanup})
    assert state(ctx).running[ctx.issue.id].phase == :workspace
    assert %{busy: 1} = Governor.snapshot()

    await(fn -> File.exists?(Path.join(root, "sessions")) end)
    await(fn -> Map.has_key?(state(ctx).retry_attempts, ctx.issue.id) end)
    assert state(ctx).retry_attempts[ctx.issue.id].error == nil
    assert %{busy: 0} = Governor.snapshot()
    assert File.read!(Path.join(root, "sessions")) == "start\n"
  end

  test "research transport recovery uses the channel schedule without spending an attempt", %{root: root} do
    previous = Application.get_env(:symphony_elixir, :task_deliveries_fun)
    Application.put_env(:symphony_elixir, :task_deliveries_fun, fn _, _ -> {:ok, %{issues: 0, pull_requests: 0}} end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :task_deliveries_fun, previous),
        else: Application.delete_env(:symphony_elixir, :task_deliveries_fun)
    end)

    ctx =
      start_worker(
        root,
        [
          poll_interval_ms: 1_000_000,
          hook_before_run: "exit 1",
          autopilot: %{
            "enabled" => true,
            "repo_tasks" => false,
            "max_item_attempts" => 1,
            "channels" => %{"fixture" => %{"focus" => "Offline fixture", "min_issues" => 0}}
          }
        ],
        :protocol_overflow
      )

    await(fn -> Map.has_key?(state(ctx).startup_failures, ctx.issue.id) end)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    write_workflow_file!(ctx.workflow, Keyword.put(ctx.config, :hook_before_run, "sleep 0.2"))
    assert :ok = Project.with_project("deadline", &WorkflowStore.force_reload/0)
    :sys.replace_state(ctx.orchestrator, &%{&1 | autopilot: %{&1.autopilot | tasks: %{}}})
    send(ctx.orchestrator, :run_poll_cycle)
    id = "research:fixture"
    await(fn -> get_in(state(ctx).running, [id, :phase]) == :workspace end)
    entry = state(ctx).running[id]
    await(fn -> state(ctx).running == %{} and File.exists?(Path.join(root, "sessions")) end)
    current = state(ctx)
    assert %{attempts: 0, last: :interrupted, retry_at: retry_at} = current.autopilot.tasks["fixture"]
    assert DateTime.diff(retry_at, DateTime.utc_now(), :second) in 25..30
    refute Map.has_key?(current.retry_attempts, id)
    refute MapSet.member?(current.claimed, id)
    refute Map.has_key?(current.startup_failures, id)
    assert [{_, %{status: "interrupted"}}] = :dets.lookup(current.operations, {:lineage_run, entry.run_id})
    assert %{busy: 0} = Governor.snapshot()

    Process.exit(ctx.orchestrator, :kill)

    await(fn ->
      replacement = GenServer.whereis(Project.via("deadline", :orchestrator))
      replacement != nil and replacement != ctx.orchestrator
    end)

    ctx = %{ctx | orchestrator: GenServer.whereis(Project.via("deadline", :orchestrator))}
    assert state(ctx).autopilot.tasks["fixture"].retry_at == retry_at
    send(ctx.orchestrator, :run_poll_cycle)
    assert state(ctx).running == %{}
    assert File.read!(Path.join(root, "sessions")) == "start\n"
    File.write!(Path.join(root, "recovered"), "")
    :sys.replace_state(ctx.orchestrator, &put_in(&1.autopilot.tasks["fixture"].retry_at, DateTime.add(DateTime.utc_now(), -1, :second)))
    send(ctx.orchestrator, :run_poll_cycle)
    await(fn -> get_in(state(ctx).autopilot, [:tasks, "fixture", :last]) == :delivered end)
    assert state(ctx).autopilot.tasks["fixture"].attempts == 0
    assert File.read!(Path.join(root, "sessions")) == "start\nstart\n"
    assert %{busy: 0} = Governor.snapshot()
  end

  test "Codex startup has a fresh inactivity deadline after a long hook", %{root: root} do
    ctx = start_worker(root, [hook_before_run: "exec sleep 0.3", codex_read_timeout_ms: 2_000], :startup)
    entry = await_entry(ctx, :codex)
    assert entry.session_id == nil
    assert DateTime.diff(entry.phase_started_at, entry.started_at, :millisecond) >= 300
    ref = Process.monitor(entry.pid)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    await(fn -> Map.has_key?(state(ctx).retry_attempts, ctx.issue.id) end)
    assert state(ctx).retry_attempts[ctx.issue.id].error =~ "without codex activity"
    assert %{busy: 0} = Governor.snapshot()
  end

  test "startup read failure runs bounded cleanup even with stall detection disabled", %{root: root} do
    ctx =
      start_worker(
        root,
        [
          codex_stall_timeout_ms: 0,
          codex_read_timeout_ms: 50,
          hook_after_run: "echo started > after_run; exec sleep 0.3",
          hook_timeout_ms: 200
        ],
        :startup
      )

    await_entry(ctx, :cleanup)
    assert %{busy: 1} = Governor.snapshot()
    await(fn -> Map.has_key?(state(ctx).retry_attempts, ctx.issue.id) end)
    assert state(ctx).startup_failures[ctx.issue.id].diagnostic.status == "timeout"
    assert File.read!(Path.join(ctx.workspace, "after_run")) == "started\n"
    assert %{busy: 0} = Governor.snapshot()
  end

  test "an established inactive session stalls, while service restart cancels a hook and frees its slot", %{root: root} do
    ctx = start_worker(root, [], :inactive)
    await(fn -> get_in(state(ctx).running, [ctx.issue.id, :session_id]) != nil end)
    await(fn -> Map.has_key?(state(ctx).retry_attempts, ctx.issue.id) end)
    assert state(ctx).retry_attempts[ctx.issue.id].error =~ "without codex activity"
    assert %{busy: 0} = Governor.snapshot()

    write_workflow_file!(ctx.workflow, Keyword.put(ctx.config, :hook_before_run, "exec sleep 0.3"))
    assert :ok = Project.with_project("deadline", &WorkflowStore.force_reload/0)
    retry = state(ctx).retry_attempts[ctx.issue.id]
    await(fn -> state(ctx).throttle && state(ctx).throttle.slots > 0 end)
    send(ctx.orchestrator, {:retry_issue, ctx.issue.id, retry.retry_token})
    worker = await_entry(ctx, :workspace)
    worker_ref = Process.monitor(worker.pid)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Process.exit(ctx.orchestrator, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, _, _}, 2_000
    await(fn -> Governor.snapshot().busy == 0 end)

    await(fn ->
      match?(%{running: [], retrying: []}, Orchestrator.snapshot(Project.via("deadline", :orchestrator), 5_000))
    end)

    assert Project.with_project("deadline", &Config.settings!/0).hooks.before_run == "exec sleep 0.3\n"
  end

  test "a research session stall ends its round without an issue retry", %{root: root} do
    ctx = start_worker(root, [codex_stall_timeout_ms: 300], :inactive)
    await(fn -> get_in(state(ctx).running, [ctx.issue.id, :session_id]) != nil end)
    # Keep the real worker/session, but exercise the research completion policy.
    :sys.replace_state(ctx.orchestrator, fn state ->
      entry = state.running[ctx.issue.id]
      issue = %{entry.issue | kind: :research, research: %{channel: "deadline"}}
      %{state | running: Map.put(state.running, ctx.issue.id, %{entry | issue: issue})}
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    await(fn -> get_in(state(ctx).autopilot, [:tasks, "deadline", :last]) == :failed end)
    assert state(ctx).running == %{}
    assert state(ctx).retry_attempts == %{}
    assert %{attempts: 1, retry_at: %DateTime{}} = state(ctx).autopilot.tasks["deadline"]
    assert %{busy: 0} = Governor.snapshot()
    refute File.exists?(ctx.workspace)
  end

  test "a stalled retry respects backoff and gets a turn beside a higher-weight project", %{root: root} do
    marker = Path.join(root, "dispatched")

    for id <- ["light", "heavy"] do
      workflow = Path.join([root, "projects", id, "WORKFLOW.md"])
      File.mkdir_p!(Path.dirname(workflow))

      write_workflow_file!(workflow,
        tracker_kind: "memory",
        tracker_required_labels: [id],
        poll_interval_ms: 1_000_000,
        workspace_root: Path.join(root, "workspaces"),
        hook_before_run: "touch '#{marker}'; exit 1"
      )
    end

    path = Path.join(root, "crescendo.yml")
    File.write!(path, "paths: {state: state}\npool: {slots: 1}\nprojects: {light: {}, heavy: {weight: 3}}")
    {:ok, service} = Service.load(path)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    start_supervised!({Governor, service})
    start_supervised!({Projects, service})
    await(fn -> Enum.all?(["light", "heavy"], &(GenServer.whereis(Project.via(&1, :orchestrator)) != nil)) end)

    await(fn ->
      Enum.all?(["light", "heavy"], &(:sys.get_state(Project.via(&1, :orchestrator)).issues_observed_at != nil))
    end)

    orchestrator = GenServer.whereis(Project.via("light", :orchestrator))
    issue = %Issue{id: "retry", identifier: "GH-RETRY", title: "Retry", state: "In Progress", labels: ["light"], dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    retry = %{
      attempt: 1,
      timer_ref: nil,
      retry_token: make_ref(),
      due_at_ms: System.monotonic_time(:millisecond) + 60_000,
      identifier: issue.identifier,
      error: "stalled without codex activity"
    }

    :sys.replace_state(orchestrator, &%{&1 | retry_attempts: %{issue.id => retry}, claimed: MapSet.new()})
    Governor.checkin("heavy", 0, 1)
    send(orchestrator, :run_poll_cycle)
    assert :sys.get_state(orchestrator).running == %{}
    refute File.exists?(marker)
    assert Enum.find(Governor.snapshot().projects, &(&1.id == "light")).waiting == 0

    :sys.replace_state(orchestrator, fn state ->
      put_in(state.retry_attempts[issue.id].due_at_ms, System.monotonic_time(:millisecond))
    end)

    send(orchestrator, {:retry_issue, issue.id, retry.retry_token})
    assert :sys.get_state(orchestrator).retry_attempts[issue.id].attempt == 1
    assert Enum.find(Governor.snapshot().projects, &(&1.id == "light")).waiting == 1

    for round <- 1..6 do
      case Governor.acquire("heavy", "rival-#{round}", :issue) do
        :ok -> Governor.release("heavy", "rival-#{round}")
        {:wait, _reason} -> :ok
      end

      Governor.snapshot()
      send(orchestrator, :run_poll_cycle)

      if pending = :sys.get_state(orchestrator).retry_attempts[issue.id] do
        send(orchestrator, {:retry_issue, issue.id, pending.retry_token})
        :sys.get_state(orchestrator)
      end
    end

    await(fn -> File.exists?(marker) end)
  end

  test "empty before-run failures under autopilot exhaust only startup admission and recover", %{root: root} do
    Application.put_env(:symphony_elixir, :memory_tracker_writes, [])
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_writes) end)
    ctx = start_worker(root, hook_before_run: "exit 1", max_attempts: 1, autopilot: %{"enabled" => true, "max_item_attempts" => 1, "max_open_issues" => 1})

    for count <- 1..3 do
      await(fn -> get_in(state(ctx).startup_failures, [ctx.issue.id, :count]) == count end)
      assert %{busy: 0} = Governor.snapshot()
      assert state(ctx).autopilot.item_attempts == %{}
      refute MapSet.member?(state(ctx).claimed, ctx.issue.id)
      refute File.exists?(Path.join(root, "sessions"))
      assert Application.get_env(:symphony_elixir, :memory_tracker_writes) == []
      if count < 3, do: retry_now(ctx)
    end

    assert state(ctx).retry_attempts == %{}
    assert [blocked] = Orchestrator.snapshot(ctx.orchestrator, 5_000).blocked

    assert blocked.startup == %{
             reason: :workspace_hook_failed,
             phase: :before_run,
             hook: "before_run",
             status: 1,
             context: "",
             empty_output: true
           }

    assert blocked.run_id
    assert blocked.worker_pid
    for _ <- 1..5, do: send(ctx.orchestrator, :run_poll_cycle)
    assert state(ctx).running == %{}
    assert state(ctx).startup_failures[ctx.issue.id].count == 3
    old_failure = state(ctx).startup_failures[ctx.issue.id]

    # Restart cannot reset the blocked budget or the wall-clock deadline.
    Process.exit(ctx.orchestrator, :kill)
    await(fn -> GenServer.whereis(Project.via("deadline", :orchestrator)) not in [nil, ctx.orchestrator] end)
    ctx = %{ctx | orchestrator: GenServer.whereis(Project.via("deadline", :orchestrator))}
    assert state(ctx).startup_failures[ctx.issue.id] == old_failure
    assert state(ctx).running == %{}
    assert state(ctx).autopilot.item_attempts == %{}

    write_workflow_file!(ctx.workflow, Keyword.put(ctx.config, :hook_before_run, "sleep 0.2"))
    assert :ok = Project.with_project("deadline", &WorkflowStore.force_reload/0)
    worker = await_entry(ctx, :workspace)
    send(ctx.orchestrator, {:worker_admitted, ctx.issue.id, old_failure.run_id, %{}})
    send(ctx.orchestrator, {:worker_startup_failure, ctx.issue.id, old_failure.run_id, blocked.startup})
    send(ctx.orchestrator, {:DOWN, make_ref(), :process, self(), :failed})
    assert state(ctx).running[ctx.issue.id].pid == worker.pid
    assert state(ctx).running[ctx.issue.id].model_admitted == false
    await(fn -> File.exists?(Path.join(root, "sessions")) end)
    await(fn -> Map.has_key?(state(ctx).retry_attempts, ctx.issue.id) end)
    assert state(ctx).startup_failures == %{}
    assert state(ctx).autopilot.item_attempts == %{}
    assert File.read!(Path.join(root, "sessions")) == "start\n"
  end

  test "environment recovery uses one cooldown probe without resetting delivery counters", %{root: root} do
    marker = Path.join(root, "fixed")
    ctx = start_worker(root, hook_before_run: "test -f '#{marker}'", max_attempts: 1)

    for count <- 1..3 do
      await(fn -> get_in(state(ctx).startup_failures, [ctx.issue.id, :count]) == count end)
      if count < 3, do: retry_now(ctx)
    end

    File.write!(marker, "fixed")

    :sys.replace_state(ctx.orchestrator, fn state ->
      put_in(state.startup_failures[ctx.issue.id].due_at_ms, 0)
    end)

    send(ctx.orchestrator, :run_poll_cycle)
    send(ctx.orchestrator, :run_poll_cycle)
    await(fn -> Map.has_key?(state(ctx).retry_attempts, ctx.issue.id) end)
    assert state(ctx).startup_failures == %{}
    assert File.read!(Path.join(root, "sessions")) == "start\n"
    assert %{busy: 0} = Governor.snapshot()
  end

  test "hook timeout kills a grandchild before releasing the governor slot", %{root: root} do
    pid_file = Path.join(root, "child")
    ctx = start_worker(root, hook_before_run: "sleep 60 & echo $! > '#{pid_file}'; wait", hook_timeout_ms: 200)
    await(fn -> File.exists?(pid_file) end)
    child = pid_file |> File.read!() |> String.trim()
    await(fn -> Map.has_key?(state(ctx).startup_failures, ctx.issue.id) end)
    await(fn -> not os_running?(child) end)
    assert %{busy: 0} = Governor.snapshot()
    assert state(ctx).startup_failures[ctx.issue.id].diagnostic.status == "timeout"
    refute File.exists?(Path.join(root, "sessions"))
  end

  test "remote worker admission reports transport exit and recovers without a delivery attempt", %{root: root} do
    fake_ssh(root, "exit 75")
    ctx = start_worker(root, worker_ssh_hosts: ["fixture-worker"])
    await(fn -> Map.has_key?(state(ctx).startup_failures, ctx.issue.id) end)
    failure = state(ctx).startup_failures[ctx.issue.id]
    assert failure.worker_host == "fixture-worker"
    assert failure.diagnostic.status == 75
    assert failure.diagnostic.empty_output
    assert failure.diagnostic.phase == :workspace
    refute File.exists?(Path.join(root, "sessions"))
    fake_ssh(root, "for command do :; done; exec sh -c \"$command\"")
    retry_now(ctx)
    await(fn -> File.exists?(Path.join(root, "sessions")) end)
    await(fn -> Map.has_key?(state(ctx).retry_attempts, ctx.issue.id) end)
    assert state(ctx).startup_failures == %{}
    assert %{busy: 0} = Governor.snapshot()
  end

  test "remote after-create deadline retains the hook name and kills its child", %{root: root} do
    fake_ssh(root, "for command do :; done; exec sh -c \"$command\"")
    pid_file = Path.join(root, "remote-child")
    ctx = start_worker(root, worker_ssh_hosts: ["fixture-worker"], hook_timeout_ms: 500, hook_after_create: "sleep 60 & echo $! > '#{pid_file}'; wait")
    await(fn -> File.exists?(pid_file) end)
    child = pid_file |> File.read!() |> String.trim()
    await(fn -> Map.has_key?(state(ctx).startup_failures, ctx.issue.id) end)
    assert state(ctx).startup_failures[ctx.issue.id].diagnostic.hook == "after_create"
    assert state(ctx).startup_failures[ctx.issue.id].diagnostic.status == "timeout"
    await(fn -> not os_running?(child) end)
    assert %{busy: 0} = Governor.snapshot()
    refute File.exists?(Path.join(root, "sessions"))
  end

  test "OTP spawn refusal is a bounded admission failure and restores backoff on restart", %{root: root} do
    ctx = start_worker(root, hook_before_run: "exit 1")
    await(fn -> Map.has_key?(state(ctx).startup_failures, ctx.issue.id) end)
    first = state(ctx).startup_failures[ctx.issue.id]
    Process.exit(ctx.orchestrator, :kill)
    await(fn -> GenServer.whereis(Project.via("deadline", :orchestrator)) not in [nil, ctx.orchestrator] end)
    ctx = %{ctx | orchestrator: GenServer.whereis(Project.via("deadline", :orchestrator))}
    assert state(ctx).startup_failures[ctx.issue.id] == first
    assert state(ctx).retry_attempts[ctx.issue.id].due_at_ms > System.monotonic_time(:millisecond)
    refusing = start_supervised!({Task.Supervisor, max_children: 0})
    :sys.replace_state(ctx.orchestrator, &%{&1 | task_supervisor: refusing})
    retry_now(ctx)
    await(fn -> state(ctx).startup_failures[ctx.issue.id].count == 2 end)
    assert state(ctx).startup_failures[ctx.issue.id].diagnostic.phase == :worker_spawn
    assert state(ctx).startup_failures[ctx.issue.id].diagnostic.context =~ "max_children"
    assert %{busy: 0} = Governor.snapshot()
    refute MapSet.member?(state(ctx).claimed, ctx.issue.id)
  end

  test "a zero-token failure after model admission still exhausts delivery attempts", %{root: root} do
    Application.put_env(:symphony_elixir, :memory_tracker_writes, [])
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_writes) end)
    ctx = start_worker(root, [max_attempts: 1, autopilot: %{"enabled" => true, "max_item_attempts" => 1, "max_open_issues" => 1}], :turn_failure)
    await(fn -> Map.has_key?(state(ctx).retry_attempts, ctx.issue.id) end)
    assert state(ctx).startup_failures == %{}
    assert state(ctx).retry_attempts[ctx.issue.id].attempt == 1
    retry_now(ctx, 1)

    await(fn ->
      Enum.any?(
        Application.get_env(:symphony_elixir, :memory_tracker_writes),
        &match?({:retire, _, _}, &1)
      )
    end)

    activity = SymphonyElixir.Operations.snapshot(state(ctx).operations).activity
    assert Enum.any?(activity, &match?(%{kind: "attempt_failed", item_attempt: 1}, &1))

    assert Enum.count(
             Application.get_env(:symphony_elixir, :memory_tracker_writes),
             &match?({:retire, _, _}, &1)
           ) == 1

    assert state(ctx).startup_failures == %{}
    assert state(ctx).codex_totals.total_tokens == 0
    assert %{busy: 0} = Governor.snapshot()
  end

  test "tracker outage during attempt-zero recovery holds durable backoff", %{root: root} do
    previous = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, RetryTracker)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :linear_client_module, previous),
        else: Application.delete_env(:symphony_elixir, :linear_client_module)

      Application.delete_env(:symphony_elixir, :startup_tracker_down)
    end)

    ctx = start_worker(root, tracker_kind: "linear", hook_before_run: "exit 1")
    await(fn -> Map.has_key?(state(ctx).startup_failures, ctx.issue.id) end)
    Application.put_env(:symphony_elixir, :startup_tracker_down, true)
    retry_now(ctx)
    retry = state(ctx).retry_attempts[ctx.issue.id]
    assert retry.attempt == 0
    assert retry.error =~ "offline_tracker"
    assert retry.due_at_ms - System.monotonic_time(:millisecond) >= 25_000
    failure = state(ctx).startup_failures[ctx.issue.id]
    assert failure.count == 1
    assert failure.due_at_ms - System.system_time(:millisecond) >= 25_000
    Process.exit(ctx.orchestrator, :kill)
    await(fn -> GenServer.whereis(Project.via("deadline", :orchestrator)) not in [nil, ctx.orchestrator] end)
    ctx = %{ctx | orchestrator: GenServer.whereis(Project.via("deadline", :orchestrator))}
    assert state(ctx).startup_failures[ctx.issue.id].due_at_ms >= failure.due_at_ms
    assert state(ctx).retry_attempts[ctx.issue.id].due_at_ms - System.monotonic_time(:millisecond) >= 25_000
    refute File.exists?(Path.join(root, "sessions"))
    assert %{busy: 0} = Governor.snapshot()
  end

  test "PR startup hooks cannot spend the independent review cap", %{root: root} do
    previous = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, ReviewCI)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :github_client_module, previous),
        else: Application.delete_env(:symphony_elixir, :github_client_module)
    end)

    ctx = start_worker(root, issue_kind: :pull_request, hook_before_run: "exit 1", autopilot: %{"enabled" => true, "max_pr_runs" => 1, "max_open_issues" => 1})

    for count <- 1..3 do
      await(fn -> get_in(state(ctx).startup_failures, [ctx.issue.id, :count]) == count end)
      assert state(ctx).autopilot.pr_handled == %{}
      if count < 3, do: retry_now(ctx)
    end

    assert state(ctx).autopilot.item_attempts == %{}
    write_workflow_file!(ctx.workflow, Keyword.put(ctx.config, :hook_before_run, "true"))
    assert :ok = Project.with_project("deadline", &WorkflowStore.force_reload/0)
    await(fn -> get_in(state(ctx).autopilot, [:pr_handled, ctx.issue.id, :runs]) == 1 end)
    assert state(ctx).startup_failures == %{}
    assert File.read!(Path.join(root, "sessions")) == "start\n"
  end

  test "research startup retries use configured channels and recover without delivery exhaustion", %{root: root} do
    previous = Application.get_env(:symphony_elixir, :github_client_module)
    previous_deliveries = Application.get_env(:symphony_elixir, :task_deliveries_fun)
    previous_repo = System.get_env("GITHUB_REPO")
    previous_token = System.get_env("GITHUB_TOKEN")
    Application.put_env(:symphony_elixir, :github_client_module, RetryTracker)

    Application.put_env(:symphony_elixir, :task_deliveries_fun, fn _label, _since ->
      {:ok, %{issues: 0, pull_requests: 0}}
    end)

    System.put_env("GITHUB_REPO", "fixture/repo")
    System.put_env("GITHUB_TOKEN", "offline-fixture")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :github_client_module, previous),
        else: Application.delete_env(:symphony_elixir, :github_client_module)

      if previous_deliveries,
        do: Application.put_env(:symphony_elixir, :task_deliveries_fun, previous_deliveries),
        else: Application.delete_env(:symphony_elixir, :task_deliveries_fun)

      restore_env("GITHUB_REPO", previous_repo)
      restore_env("GITHUB_TOKEN", previous_token)
    end)

    marker = Path.join(root, "fixed")

    ctx =
      start_worker(root,
        tracker_kind: "github",
        tracker_active_states: ["open"],
        tracker_terminal_states: ["closed"],
        issue_state: "open",
        hook_before_run: "test -f '#{marker}'",
        autopilot: %{
          "enabled" => true,
          "repo_tasks" => false,
          "max_item_attempts" => 1,
          "max_open_issues" => 1,
          "channels" => %{"fixture" => %{"focus" => "Offline fixture", "min_issues" => 0}}
        }
      )

    await(fn -> Map.has_key?(state(ctx).startup_failures, ctx.issue.id) end)
    :sys.replace_state(ctx.orchestrator, &%{&1 | autopilot: %{&1.autopilot | tasks: %{}}})
    send(ctx.orchestrator, :run_poll_cycle)
    id = "research:fixture"

    for count <- 1..3 do
      await(fn -> get_in(state(ctx).startup_failures, [id, :count]) == count end)
      assert state(ctx).autopilot.tasks == %{}
      assert state(ctx).autopilot.item_attempts == %{}
      assert %{busy: 0} = Governor.snapshot()
      refute File.exists?(Path.join(root, "sessions"))

      if count < 3 do
        retry = state(ctx).retry_attempts[id]
        assert retry.attempt == 0
        :sys.replace_state(ctx.orchestrator, &put_in(&1.startup_failures[id].due_at_ms, 0))
        send(ctx.orchestrator, {:retry_issue, id, retry.retry_token})
        send(ctx.orchestrator, {:retry_issue, id, retry.retry_token})
      end
    end

    refute Map.has_key?(state(ctx).retry_attempts, id)
    send(ctx.orchestrator, :run_poll_cycle)
    assert state(ctx).startup_failures[id].count == 3
    assert state(ctx).running == %{}
    File.write!(marker, "fixed")
    :sys.replace_state(ctx.orchestrator, &put_in(&1.startup_failures[id].due_at_ms, 0))
    send(ctx.orchestrator, :run_poll_cycle)
    send(ctx.orchestrator, :run_poll_cycle)
    await(fn -> get_in(state(ctx).autopilot.tasks, ["fixture", :last]) == :delivered end)
    refute Map.has_key?(state(ctx).startup_failures, id)
    assert state(ctx).autopilot.tasks["fixture"].attempts == 0
    assert File.read!(Path.join(root, "sessions")) == "start\n"
    assert %{busy: 0} = Governor.snapshot()
  end

  defp fake_ssh(root, command) do
    previous = System.get_env("PATH")

    if not File.exists?(Path.join(root, "ssh")) do
      System.put_env("PATH", root <> ":" <> previous)
      on_exit(fn -> System.put_env("PATH", previous) end)
    end

    File.write!(Path.join(root, "ssh"), "#!/bin/sh\n#{command}\n")
    File.chmod!(Path.join(root, "ssh"), 0o755)
  end

  defp os_running?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> not String.contains?(stat, ") Z ")
      {:error, :enoent} -> false
    end
  end

  defp retry_now(ctx, expected_attempt \\ 0) do
    await(fn -> state(ctx).throttle && state(ctx).throttle.slots > 0 end)
    retry = state(ctx).retry_attempts[ctx.issue.id]
    assert retry.attempt == expected_attempt
    send(ctx.orchestrator, {:retry_issue, ctx.issue.id, retry.retry_token})
    # Ensure duplicate timer messages cannot start another worker.
    send(ctx.orchestrator, {:retry_issue, ctx.issue.id, retry.retry_token})
    :sys.get_state(ctx.orchestrator)
  end

  defp start_worker(root, overrides, mode \\ :complete) do
    binary = Path.join(root, "codex")

    File.write!(binary, """
    #!/bin/sh
    echo start >> '#{root}/sessions'
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          if [ '#{mode}' != startup ]; then printf '%s\\n' '{"id":1,"result":{}}'; fi ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-deadline"}}}' ;;
        *'"method":"turn/start"'*)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-deadline"}}}'
          if [ '#{mode}' = complete ] || [ -f '#{root}/recovered' ]; then printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'; fi
          if [ '#{mode}' = protocol_overflow ] && [ ! -f '#{root}/recovered' ]; then printf '%s' '{"secret":"'; python3 -c "print('x'*18000000)"; fi
          if [ '#{mode}' = turn_failure ]; then printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"failed"}}}'; fi ;;
      esac
    done
    """)

    File.chmod!(binary, 0o755)
    workflow = Path.join([root, "projects", "deadline", "WORKFLOW.md"])
    File.mkdir_p!(Path.dirname(workflow))

    config =
      Keyword.merge(
        [
          tracker_kind: "memory",
          workspace_root: Path.join(root, "workspaces"),
          poll_interval_ms: 10,
          max_turns: 1,
          codex_command: binary,
          codex_stall_timeout_ms: 1_000,
          hook_timeout_ms: 1_500
        ],
        overrides
      )

    config =
      if autopilot = config[:autopilot] do
        for kind <- ["pull_request", "research"], do: File.write!(Path.join(root, "#{kind}.md"), "Fake #{kind}")
        prompts = Map.new(["pull_request", "research"], &{&1, Path.join(root, "#{&1}.md")})
        Keyword.put(config, :autopilot, Map.put(autopilot, "prompts", prompts))
      else
        config
      end

    write_workflow_file!(workflow, config)
    File.write!(Path.join(root, "crescendo.yml"), "paths: {state: state}\npool: {slots: 1}\nprojects: {deadline: {}}")
    {:ok, service} = Service.load(Path.join(root, "crescendo.yml"))
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    start_supervised!({Governor, service})
    start_supervised!({Projects, service})
    await(fn -> GenServer.whereis(Project.via("deadline", :orchestrator)) != nil end)
    orchestrator = GenServer.whereis(Project.via("deadline", :orchestrator))
    kind = overrides[:issue_kind] || :issue

    issue = %Issue{
      id: "deadline",
      identifier: "GH-32",
      title: "Deadline",
      state: overrides[:issue_state] || "In Progress",
      dispatchable: true,
      kind: kind,
      pull_request: if(kind == :pull_request, do: %{head_sha: "fixture-head", draft: false, trusted: true})
    }

    if config[:autopilot] do
      channels = Project.with_project("deadline", fn -> Config.settings!().autopilot.channels end)

      cooled =
        Map.new(channels, fn {channel, _} ->
          {channel, %{finished_at: DateTime.add(DateTime.utc_now(), 1, :day), attempts: 0, last: :delivered}}
        end)

      :sys.replace_state(orchestrator, &%{&1 | autopilot: %{&1.autopilot | tasks: cooled}})
    end

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    send(orchestrator, :run_poll_cycle)
    %{orchestrator: orchestrator, issue: issue, workflow: workflow, config: config, workspace: Path.join(root, "workspaces/GH-32")}
  end

  defp state(ctx), do: :sys.get_state(ctx.orchestrator)

  defp await_entry(ctx, phase) do
    await(fn -> get_in(state(ctx).running, [ctx.issue.id, :phase]) == phase end, 300)
    state(ctx).running[ctx.issue.id]
  end

  defp await(check, attempts \\ 250) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && await(check, attempts - 1)
    end
  end
end
