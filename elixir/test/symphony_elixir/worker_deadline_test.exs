defmodule SymphonyElixir.WorkerDeadlineTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Governor, Project, Projects, Service}

  setup do
    root = Path.join(System.tmp_dir!(), "worker-deadline-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "workspace hooks and cleanup outlive Codex inactivity, including a config reload", %{root: root} do
    ctx =
      start_worker(root,
        hook_after_create: "echo started > after_create; sleep 0.3; echo done >> after_create",
        hook_before_run: "echo started > before_run; sleep 0.3; echo done >> before_run",
        hook_after_run: "echo started > after_run; sleep 0.3; echo done >> after_run"
      )

    entry = await_entry(ctx, :workspace)
    assert %{busy: 1} = Governor.snapshot()
    await(fn -> File.exists?(Path.join(ctx.workspace, "after_create")) end)
    Process.sleep(150)
    assert state(ctx).running[ctx.issue.id].pid == entry.pid
    refute Map.has_key?(state(ctx).retry_attempts, ctx.issue.id)

    write_workflow_file!(ctx.workflow, Keyword.put(ctx.config, :codex_stall_timeout_ms, 80))
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

  test "an over-deadline hook releases its slot and retries once", %{root: root} do
    ctx = start_worker(root, hook_after_create: "exec sleep 0.3", hook_timeout_ms: 200)
    entry = await_entry(ctx, :workspace)
    ref = Process.monitor(entry.pid)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    await(fn -> Map.has_key?(state(ctx).retry_attempts, ctx.issue.id) end)
    retry = state(ctx).retry_attempts[ctx.issue.id]
    assert retry.attempt == 1
    assert retry.error =~ "workspace_hook_timeout"
    assert %{busy: 0} = Governor.snapshot()
    refute File.exists?(Path.join(root, "sessions"))
    refute File.exists?(ctx.workspace)

    config = Keyword.merge(ctx.config, hook_after_create: nil, hook_before_run: "exec sleep 0.3", hook_timeout_ms: 1_500)
    write_workflow_file!(ctx.workflow, config)
    assert :ok = Project.with_project("deadline", &WorkflowStore.force_reload/0)
    await(fn -> state(ctx).throttle.slots > 0 end)
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
    assert state(ctx).retry_attempts[ctx.issue.id].error =~ "response_timeout"
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
    await(fn -> state(ctx).throttle.slots > 0 end)
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
          if [ '#{mode}' = complete ]; then printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'; fi ;;
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
          codex_stall_timeout_ms: 100,
          hook_timeout_ms: 1_500
        ],
        overrides
      )

    write_workflow_file!(workflow, config)
    File.write!(Path.join(root, "crescendo.yml"), "paths: {state: state}\npool: {slots: 1}\nprojects: {deadline: {}}")
    {:ok, service} = Service.load(Path.join(root, "crescendo.yml"))
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    start_supervised!({Governor, service})
    start_supervised!({Projects, service})
    await(fn -> GenServer.whereis(Project.via("deadline", :orchestrator)) != nil end)
    orchestrator = GenServer.whereis(Project.via("deadline", :orchestrator))
    issue = %Issue{id: "deadline", identifier: "GH-32", title: "Deadline", state: "In Progress", dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    send(orchestrator, :run_poll_cycle)
    %{orchestrator: orchestrator, issue: issue, workflow: workflow, config: config, workspace: Path.join(root, "workspaces/GH-32")}
  end

  defp state(ctx), do: :sys.get_state(ctx.orchestrator)

  defp await_entry(ctx, phase) do
    await(fn -> get_in(state(ctx).running, [ctx.issue.id, :phase]) == phase end)
    state(ctx).running[ctx.issue.id]
  end

  defp await(check, attempts \\ 150) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && await(check, attempts - 1)
    end
  end
end
