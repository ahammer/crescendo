defmodule SymphonyElixir.TokenCacheLifecycleTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.Usage
  alias SymphonyElixir.{Governor, Operations, Project, Service}

  test "startup notifications survive RPC waits and terminal success requires the matching native turn" do
    fixture = native_fixture()
    parent = self()
    handler = fn message -> send(parent, {:native, message}) end
    {:ok, session} = AppServer.start_session(fixture.workspace, on_message: handler)
    on_exit(fn -> AppServer.stop_session(session) end)

    assert session.metadata.codex_version == "0.160.0"
    assert session.metadata.model == "resolved-model"
    assert_receive {:native, %{event: :notification, payload: %{"method" => "thread/started"}}}
    assert {:ok, turn} = AppServer.run_turn(session, "task", fixture.issue, on_message: handler)
    assert turn.turn_id == "turn-1"
    assert_receive {:native, %{payload: %{"method" => "thread/tokenUsage/updated"}} = update}
    assert Usage.snapshot(update).total.total_tokens == 120

    assert_receive {:native, %{event: :turn_completed, payload: %{"params" => %{"turn" => %{"id" => "turn-1"}}}}}

    assert :ok = AppServer.read_account_usage(session, on_message: handler)
    assert_receive {:native, %{event: :account_usage, account_usage: nil}}
    requests = requests(fixture)

    assert Enum.all?(
             Enum.filter(requests, &(&1["method"] == "turn/start")),
             &(not Map.has_key?(&1["params"], "title"))
           )

    for status <- ["failed", "interrupted", nil] do
      change_fixture(fixture, %{"terminal_status" => status})
      assert {:error, {:turn_not_completed, ^status}} = AppServer.run_turn(session, "continue", fixture.issue)
    end
  end

  test "malformed model reroutes preserve native metadata for later usage and completion" do
    fixture = native_fixture()
    parent = self()
    handler = fn message -> send(parent, {:native, message}) end
    {:ok, session} = AppServer.start_session(fixture.workspace)
    on_exit(fn -> AppServer.stop_session(session) end)

    for {rerouted, expected} <- [
          {42, "resolved-model"},
          {%{}, "resolved-model"},
          {[], "resolved-model"},
          {true, "resolved-model"},
          {nil, "resolved-model"},
          {"gpt-6-sol", "gpt-6-sol"},
          {false, "gpt-6-sol"}
        ] do
      change_fixture(fixture, %{"rerouted_model" => rerouted})
      assert {:ok, _turn} = AppServer.run_turn(session, "task", fixture.issue, on_message: handler)
      assert_received {:native, %{payload: %{"method" => "model/rerouted", "params" => %{"toModel" => ^rerouted}}}}
      assert_received {:native, %{payload: %{"method" => "thread/tokenUsage/updated"}} = update}
      assert update.model == expected
      assert_received {:native, %{event: :turn_completed, model: ^expected}}
    end
  end

  test "native resume requires a known completed boundary and reconciles restored usage before new work" do
    fixture = native_fixture()
    codex = %{Config.settings!().codex | resume_threads: true}
    opts = [kind: :issue, codex_settings: codex, contract_hash: "contract"]
    {:ok, session} = AppServer.start_session(fixture.workspace, opts)
    assert session.resumed == false
    assert {:ok, turn} = AppServer.run_turn(session, "task", fixture.issue)
    checkpoint = AppServer.checkpoint(session, turn, item_attempt: 1)
    assert checkpoint.eligible

    checkpoint =
      Map.put(
        checkpoint,
        :usage_watermark,
        Usage.normalize(%{input_tokens: 100, output_tokens: 20, cached_input_tokens: 80})
      )

    AppServer.stop_session(session)
    parent = self()
    handler = fn message -> send(parent, {:resume, message}) end

    {:ok, resumed} =
      AppServer.start_session(
        fixture.workspace,
        Keyword.merge(opts, checkpoint: checkpoint, on_message: handler)
      )

    assert resumed.resumed
    assert resumed.thread_id == session.thread_id
    assert_receive {:resume, %{restored: true, payload: %{"method" => "thread/tokenUsage/updated"}}}
    assert {:ok, turn} = AppServer.run_turn(resumed, "continue", fixture.issue)

    checkpoint =
      AppServer.checkpoint(resumed, turn, item_attempt: 1)
      |> Map.put(:usage_watermark, checkpoint.usage_watermark)

    AppServer.stop_session(resumed)

    for changes <- [%{"restore_usage" => false}, %{"last_status" => "failed"}, %{"version" => "0.999.0"}] do
      change_fixture(fixture, changes)
      {:ok, fresh} = AppServer.start_session(fixture.workspace, Keyword.put(opts, :checkpoint, checkpoint))
      assert fresh.resumed == false
      assert fresh.thread_id != checkpoint.thread_id
      AppServer.stop_session(fresh)

      change_fixture(fixture, %{"restore_usage" => true, "last_status" => "completed", "version" => "0.160.0"})
    end
  end

  test "instruction, checkout, contract, tool and role changes fall back to fresh threads" do
    fixture = native_fixture()
    codex = %{Config.settings!().codex | resume_threads: true}
    opts = [kind: :issue, codex_settings: codex, contract_hash: "contract"]
    {:ok, session} = AppServer.start_session(fixture.workspace, opts)
    assert {:ok, turn} = AppServer.run_turn(session, "task", fixture.issue)

    checkpoint =
      AppServer.checkpoint(session, turn, [])
      |> Map.put(:usage_watermark, Usage.normalize(%{input_tokens: 100, output_tokens: 20}))

    AppServer.stop_session(session)

    for overrides <- [
          [kind: :research],
          [kind: :pull_request],
          [contract_hash: "changed"],
          [codex_settings: %{codex | resume_threads: false}]
        ] do
      {:ok, fresh} =
        AppServer.start_session(fixture.workspace, Keyword.merge(opts, [checkpoint: checkpoint] ++ overrides))

      refute fresh.resumed
      AppServer.stop_session(fresh)
    end

    File.write!(Path.join(fixture.workspace, "AGENTS.md"), "changed instructions")
    {:ok, changed} = AppServer.start_session(fixture.workspace, Keyword.put(opts, :checkpoint, checkpoint))
    refute changed.resumed
    AppServer.stop_session(changed)
    File.write!(Path.join(fixture.workspace, "AGENTS.md"), "initial instructions")
    change_fixture(fixture, %{"tools" => [%{"name" => "different"}]})
    {:ok, changed} = AppServer.start_session(fixture.workspace, Keyword.put(opts, :checkpoint, checkpoint))
    refute changed.resumed
    AppServer.stop_session(changed)
  end

  test "configured developer instructions are preserved and controls default off" do
    fixture = native_fixture()
    assert Config.settings!().codex.resume_threads == false
    assert Config.settings!().codex.developer_instructions == nil
    codex = %{Config.settings!().codex | developer_instructions: "Approved service rules"}
    {:ok, session} = AppServer.start_session(fixture.workspace, codex_settings: codex)
    AppServer.stop_session(session)
    request = Enum.find(requests(fixture), &(&1["method"] == "thread/start"))
    assert request["params"]["developerInstructions"] == "Existing developer rules\n\nApproved service rules"
    refute Map.has_key?(request["params"], "baseInstructions")
    change_fixture(fixture, %{"config_error" => true})

    assert {:error, {:developer_instructions_unverified, _}} =
             AppServer.start_session(fixture.workspace, codex_settings: codex)
  end

  test "a workflow reload does not enable reuse inside a worker with captured settings" do
    fixture = native_fixture()
    captured = Config.settings!().codex
    workflow = Workflow.workflow_file_path()
    contents = File.read!(workflow) |> String.replace("codex:\n", "codex:\n  resume_threads: true\n")
    File.write!(workflow, contents)
    WorkflowStore.force_reload()
    assert Config.settings!().codex.resume_threads
    {:ok, session} = AppServer.start_session(fixture.workspace, kind: :issue, codex_settings: captured)
    refute session.resumed
    assert session.reuse_context == nil
    refute Enum.any?(requests(fixture), &(&1["method"] in ["thread/resume", "config/read"]))
    AppServer.stop_session(session)
    assert :ok = AppServer.read_account_usage(session)
  end

  test "RPC waits are bounded even while notifications continue and oversized startup buffers fail closed" do
    fixture = native_fixture()
    change_fixture(fixture, %{"initialize_noise" => 40})

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(fixture.root, "workspaces"),
      codex_command: "python3 #{Path.join(fixture.root, "server.py")}",
      codex_read_timeout_ms: 120
    )

    started = System.monotonic_time(:millisecond)
    assert {:error, :response_timeout} = AppServer.start_session(fixture.workspace)
    assert System.monotonic_time(:millisecond) - started < 600
    change_fixture(fixture, %{"initialize_noise" => 0, "initialize_burst" => 1100})

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(fixture.root, "workspaces"),
      codex_command: "python3 #{Path.join(fixture.root, "server.py")}",
      codex_read_timeout_ms: 5000
    )

    assert {:error, :protocol_buffer_overflow} = AppServer.start_session(fixture.workspace)
  end

  test "one atomic thread record survives replay and charges each resumed run only for its new work" do
    {table, path} = ledger()
    key = {"storage", "thread"}
    rates = Operations.rates(nil)
    first = %{source: :canonical, total: Usage.normalize(%{input_tokens: 100, output_tokens: 20})}

    assert {:ok, %{total_tokens: 120}} =
             Operations.thread_usage(table, key, "one", "gpt-6-sol", first, "GH-1", rates)

    assert {:ok, %{total_tokens: 0}} =
             Operations.thread_usage(table, key, "two", "gpt-6-sol", first, "GH-1", rates, true)

    assert Operations.run_usage(table, "two").total_tokens == 0

    late = %{
      first
      | total:
          Usage.normalize(%{
            input_tokens: 100,
            output_tokens: 20,
            cached_input_tokens: 80,
            reasoning_output_tokens: 10
          })
    }

    assert {:ok, %{total_tokens: 0, cached_input_tokens: 80}} =
             Operations.thread_usage(table, key, "two", "gpt-6-sol", late, "GH-1", rates)

    assert Operations.run_usage(table, "one").usd_micro == 128

    next = %{
      first
      | total:
          Usage.normalize(%{
            input_tokens: 150,
            output_tokens: 30,
            cached_input_tokens: 120,
            cache_write_tokens: 5,
            reasoning_output_tokens: 15
          })
    }

    assert {:ok, %{total_tokens: 60}} =
             Operations.thread_usage(table, key, "two", "gpt-6-sol", next, "GH-1", rates)

    legacy = %{source: :legacy, total: Usage.normalize(%{input_tokens: 9999, output_tokens: 9999})}

    assert {:ok, %{total_tokens: 0}} =
             Operations.thread_usage(table, key, "two", "gpt-6-sol", legacy, "GH-1", rates)

    assert Operations.run_usage(table, "one").total_tokens == 120
    assert Operations.run_usage(table, "two").total_tokens == 60
    assert Operations.item_usage(table, "GH-1").runs == 2
    before = Operations.snapshot(table).recorded
    assert before.total_tokens == 180
    assert before.cached_input_tokens == 120
    assert before.reasoning_output_tokens == 15
    Operations.close(table)
    {:ok, ^table} = Operations.open(path, table)

    assert {:ok, %{total_tokens: 0}} =
             Operations.thread_usage(table, key, "two", "gpt-6-sol", next, "GH-1", rates)

    assert Operations.snapshot(table).recorded == before
    assert {:error, :operations_unavailable} = Operations.save_checkpoint(nil, "GH-1", %{eligible: true})
    Operations.close(table)
    assert {:error, _} = Operations.save_checkpoint(table, "GH-1", %{eligible: true})
  end

  test "checkpoint eligibility is durable, depends on accounted usage, and is revoked on an interrupted owner" do
    {table, path} = ledger()
    key = {"storage", "thread"}
    checkpoint = %{eligible: true, run_id: "one", thread_key: key, turn_id: "turn-one"}
    Operations.start_run(table, "one", %{issue_id: "item", issue_identifier: "GH-1"})
    :ok = Operations.save_checkpoint(table, "item", checkpoint)
    refute Operations.checkpoint(table, "item").eligible

    snapshot = %{
      source: :canonical,
      complete: true,
      turn_id: "turn-one",
      total: Usage.normalize(%{input_tokens: 100, output_tokens: 20})
    }

    Operations.thread_usage(table, key, "one", nil, snapshot, "GH-1", Operations.rates(nil))
    :ok = Operations.save_checkpoint(table, "item", checkpoint)
    assert Operations.checkpoint(table, "item").eligible
    Operations.finish_run(table, "one", "interrupted", %{issue_identifier: "GH-1", reason: "deployment_drain"})
    assert Operations.checkpoint(table, "item").eligible
    Operations.close(table)
    {:ok, ^table} = Operations.open(path, table)
    assert Operations.checkpoint(table, "item").eligible
    Operations.start_run(table, "two", %{issue_id: "item", issue_identifier: "GH-1"})
    :ok = Operations.save_checkpoint(table, "item", Map.put(checkpoint, :run_id, "two"))
    Operations.close(table)
    {:ok, ^table} = Operations.open(path, table)
    refute Operations.checkpoint(table, "item").eligible
    :ok = :dets.insert(table, {{:thread_checkpoint, "corrupt"}, "bad"})
    assert Operations.checkpoint(table, "corrupt") == nil
    assert Operations.run_usage(table, "one").total_tokens == 120
  end

  test "late cache classification uses recorded prices and updates finished-run summaries" do
    {table, _path} = ledger()
    key = {"storage", "thread"}
    first = %{source: :canonical, total: Usage.normalize(%{input_tokens: 100, output_tokens: 20})}
    Operations.start_run(table, "one", %{issue_identifier: "GH-1"})
    Operations.thread_usage(table, key, "one", "gpt-6-sol", first, "GH-1", Operations.rates(nil))
    Operations.finish_run(table, "one", "completed", %{issue_identifier: "GH-1", model: "gpt-6-sol"})
    assert hd(Operations.snapshot(table).by_task).usd_micro == 200
    changed_rates = %{"gpt-6-sol" => {99_000_000, 0, 99_000_000}}
    late = %{first | total: Usage.normalize(%{input_tokens: 100, output_tokens: 20, cached_input_tokens: 80})}
    Operations.thread_usage(table, key, "two", "gpt-6-sol", late, "GH-1", changed_rates)
    assert Operations.run_usage(table, "one").usd_micro == 128
    assert hd(Operations.snapshot(table).by_task).usd_micro == 128
  end

  test "native account snapshots replace cumulative values and null is unknown" do
    {table, _path} = ledger()
    key = {"storage", "thread"}
    Operations.thread_context(table, key, %{run_id: "one"})
    assert :ok = Operations.account_usage(table, key, "thread", nil)

    assert %{threads_observed: 1, threads_covered: 0, estimated_credits_micros: nil} =
             Operations.snapshot(table).account_usage

    usage = %{"threadId" => "thread", "estimatedUsageCreditsMicros" => 100, "estimatedUsageUsdMicros" => nil}
    Operations.account_usage(table, key, "thread", usage)
    Operations.account_usage(table, key, "thread", Map.put(usage, "estimatedUsageCreditsMicros", 150))

    assert %{
             coverage: "complete",
             threads_covered: 1,
             estimated_credits_micros: 150,
             estimated_usd_micros: nil
           } = Operations.snapshot(table).account_usage

    Operations.account_usage(table, key, "thread", Map.put(usage, "threadId", "other"))
    assert Operations.snapshot(table).account_usage.estimated_credits_micros == nil
    assert Operations.snapshot(table).delivery_metrics.accepted_delivery_cost == nil
  end

  test "the OTP orchestrator fences old runs and threads and acknowledges only its active worker's checkpoints" do
    fixture = native_fixture()
    path = Path.join(fixture.root, "orchestrator.dets")

    {:ok, pid} =
      Orchestrator.start_link(
        name: __MODULE__.Fenced,
        operations_path: path,
        operations_table: :token_cache_orchestrator_test
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: fixture.issue.identifier,
      issue: fixture.issue,
      session_id: nil,
      started_at: DateTime.utc_now(),
      run_id: "new",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil
    }

    :sys.replace_state(pid, &%{&1 | running: %{fixture.issue.id => entry}})
    update = fn fields -> Map.merge(%{event: :notification, timestamp: DateTime.utc_now()}, fields) end

    send(
      pid,
      {:codex_worker_update, fixture.issue.id, "old", update.(%{event: :thread_initialized, thread_id: "old", thread_key: {"storage", "old"}})}
    )

    send(pid, {:worker_model_route, fixture.issue.id, "old", %{"model" => "old-model"}})
    send(pid, {:worker_runtime_info, fixture.issue.id, "old", %{workspace_path: "wrong"}})
    send(pid, {:codex_worker_update, fixture.issue.id, update.(%{model: "unfenced"})})
    assert :sys.get_state(pid).running[fixture.issue.id] == entry

    key = {"storage", "current"}

    send(
      pid,
      {:codex_worker_update, fixture.issue.id, "new", update.(%{event: :thread_initialized, thread_id: "current", thread_key: key, model: "gpt-6-sol"})}
    )

    usage = fn thread ->
      update.(%{
        payload: %{
          "method" => "thread/tokenUsage/updated",
          "params" => %{
            "threadId" => thread,
            "turnId" => "turn",
            "tokenUsage" => %{"total" => %{"inputTokens" => 100, "outputTokens" => 20}}
          }
        }
      })
    end

    send(pid, {:codex_worker_update, fixture.issue.id, "new", usage.("foreign")})
    assert :sys.get_state(pid).codex_totals.total_tokens == 0
    send(pid, {:codex_worker_update, fixture.issue.id, "new", usage.("current")})
    send(pid, {:codex_worker_update, fixture.issue.id, "new", usage.("current")})
    assert :sys.get_state(pid).codex_totals.total_tokens == 120
    checkpoint = %{eligible: true, thread_id: "current", thread_key: key, run_id: "new", turn_id: "turn"}

    assert {:error, :stale_checkpoint} =
             GenServer.call(pid, {:thread_checkpoint, fixture.issue.id, "old", checkpoint})

    assert :ok = GenServer.call(pid, {:thread_checkpoint, fixture.issue.id, "new", checkpoint})
    assert Operations.checkpoint(:token_cache_orchestrator_test, fixture.issue.id).eligible

    forged =
      Task.async(fn -> GenServer.call(pid, {:thread_checkpoint, fixture.issue.id, "new", checkpoint}) end)

    assert Task.await(forged) == {:error, :stale_checkpoint}
    :sys.replace_state(pid, fn state -> put_in(state.running[fixture.issue.id].issue.kind, :pull_request) end)

    assert {:error, :stale_checkpoint} =
             GenServer.call(pid, {:thread_checkpoint, fixture.issue.id, "new", checkpoint})
  end

  test "replaced cumulative records retain legacy spend and observed lineage without inventing acceptance" do
    {table, _path} = ledger()
    Operations.observe_eligible(table, "issue")
    Operations.observe_eligible(table, "issue")
    Operations.start_run(table, "old", %{issue_id: "issue", issue_identifier: "GH-1"})
    Operations.usage(table, "old", "gpt-6-sol", %{input_tokens: 100, output_tokens: 20}, "GH-1")
    Operations.start_run(table, "new", %{issue_id: "issue", issue_identifier: "GH-1", review_head: "sha"})
    snapshot = %{source: :canonical, total: Usage.normalize(%{input_tokens: 50, output_tokens: 10})}

    Operations.thread_usage(
      table,
      {"storage", "new"},
      "new",
      "gpt-6-sol",
      snapshot,
      "GH-1",
      Operations.rates(nil)
    )

    merge = %{status: "merged", head_sha: "sha", merged_at: "2026-10-02T00:00:00Z"}
    Operations.record_lineage(table, "pull_request", {1, "sha"}, merge)
    Operations.record_lineage(table, "pull_request", {1, "sha"}, merge)

    Operations.record_lineage(table, "research", "research-run", %{
      outputs: [%{number: 1}],
      association: "channel_window"
    })

    assert Operations.snapshot(table).recorded.total_tokens == 180
    assert Operations.item_usage(table, "GH-1").runs == 2

    assert %{
             merge_observations: 1,
             research_associations: 1,
             review_heads_recorded: 1,
             accepted_delivery_cost: nil,
             accepted_delivery_latency: nil
           } = Operations.snapshot(table).delivery_metrics

    assert [{_, %{first_eligible_at: at}}] = :dets.lookup(table, {:lineage_run, "new"})
    assert is_binary(at)
  end

  test "first eligibility is observed while all worker capacity is occupied" do
    fixture = native_fixture()
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", max_concurrent_agents: 1)
    busy = %{fixture.issue | state: "In Progress", dispatchable: true}
    ready = %{busy | id: "2", identifier: "GH-2", title: "Waiting"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [busy, ready])

    {:ok, pid} =
      Orchestrator.start_link(
        name: __MODULE__.Eligibility,
        operations_path: Path.join(fixture.root, "eligibility.dets"),
        operations_table: :token_cache_eligibility_test
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    busy_pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(busy_pid, :shutdown) end)

    entry = %{
      pid: busy_pid,
      ref: make_ref(),
      identifier: busy.identifier,
      issue: busy,
      session_id: nil,
      started_at: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_timestamp: DateTime.utc_now(),
      last_codex_event: nil
    }

    :sys.replace_state(pid, &%{&1 | running: %{busy.id => entry}, claimed: MapSet.new([busy.id])})
    send(pid, :run_poll_cycle)
    state = :sys.get_state(pid)
    assert Map.keys(state.running) == [busy.id]
    assert [{_, at}] = :dets.lookup(:token_cache_eligibility_test, {:eligible, ready.id})
    assert is_binary(at)
    assert :dets.lookup(:token_cache_eligibility_test, {:eligible, busy.id}) == []
  end

  test "standalone turns ignore a service drain, and failed native turns keep failing" do
    fixture = native_fixture()
    {:ok, service} = Service.parse(%{"paths" => %{"state" => "service-state"}, "projects" => %{"other" => %{}}}, Path.join(fixture.root, "service.yml"))
    start_supervised!({Governor, service})
    drain = Path.join(Service.state_root(service), "drain")
    File.mkdir_p!(Path.dirname(drain))
    File.write!(drain, "test")
    issue = %{fixture.issue | state: "In Progress", dispatchable: true}
    fetcher = fn _ -> {:ok, [issue]} end
    assert :ok = AgentRunner.run(issue, nil, max_turns: 2, issue_state_fetcher: fetcher)
    assert Enum.count(requests(fixture), &(&1["method"] == "turn/start")) == 2
    start_supervised!({WorkflowStore, name: Project.via("other", :workflow_store), project: "other", path: Workflow.workflow_file_path()})
    change_fixture(fixture, %{"terminal_status" => "failed"})

    Project.with_project("other", fn ->
      assert_raise RuntimeError, ~r/turn_not_completed/, fn ->
        AgentRunner.run(issue, nil, max_turns: 2, issue_state_fetcher: fetcher)
      end

      codex = %{Config.settings!().codex | resume_threads: true}

      assert_raise RuntimeError, ~r/checkpoint_owner_unavailable/, fn ->
        AgentRunner.run(issue, nil, codex_settings: codex, issue_state_fetcher: fetcher)
      end
    end)

    assert Enum.count(requests(fixture), &(&1["method"] == "turn/start")) == 3
  end

  test "a real service worker yields at a completed turn and resumes the same logical attempt" do
    fixture = native_fixture()
    issue = %{fixture.issue | state: "In Progress", dispatchable: true, description: "Keep the workpad"}
    change_fixture(fixture, %{"wait_turn" => true})

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(fixture.root, "workspaces"),
      codex_command: "python3 #{Path.join(fixture.root, "server.py")}",
      hook_after_run: "echo cleanup >> #{Path.join(fixture.root, "cleanup")}",
      max_turns: 3
    )

    start_supervised!({WorkflowStore, name: Project.via("drain-test", :workflow_store), project: "drain-test", path: Workflow.workflow_file_path()})
    {:ok, service} = Service.parse(%{"paths" => %{"state" => "service-state"}, "projects" => %{"drain-test" => %{}}}, Path.join(fixture.root, "service.yml"))
    start_supervised!({Governor, service})
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    task_supervisor = start_supervised!(Task.Supervisor)

    pid =
      start_supervised!(
        {Orchestrator,
         task_supervisor: task_supervisor,
         name: Project.via("drain-test", :orchestrator),
         project: "drain-test",
         operations_path: Path.join(fixture.root, "drain.dets"),
         operations_table: :drain_worker_test}
      )

    eventually(fn -> File.exists?(Path.join(fixture.root, "turn-started")) end)
    entry = :sys.get_state(pid).running[issue.id]
    assert entry.item_attempt == 1
    :sys.replace_state(pid, fn state -> put_in(state.running[issue.id].retry_attempt, 2) end)
    File.write!(Path.join(fixture.workspace, "WORKPAD.md"), "progress")
    assert Governor.snapshot().busy == 1
    busy = deployment_observation(pid)
    drain = Path.join(Service.state_root(service), "drain")
    File.mkdir_p!(Path.dirname(drain))
    File.write!(drain, "test")
    assert Governor.draining?()
    assert map_size(:sys.get_state(pid).running) == 1
    File.write!(Path.join(fixture.root, "finish-turn"), "")

    eventually(fn -> map_size(:sys.get_state(pid).running) == 0 end)
    state = :sys.get_state(pid)
    assert Governor.snapshot().busy == 0
    assert state.retry_attempts[issue.id].attempt == 2
    assert state.retry_attempts[issue.id].error == nil
    refute MapSet.member?(state.completed, issue.id)
    assert state.autopilot.item_attempts == %{}
    assert File.read!(Path.join(fixture.root, "cleanup")) == "cleanup\n"
    assert Enum.count(requests(fixture), &(&1["method"] == "turn/start")) == 1
    assert [{_, %{status: "interrupted", reason: "deployment_drain", item_attempt: 1}}] = :dets.lookup(:drain_worker_test, {:lineage_run, entry.run_id})
    daily = List.last(Operations.snapshot(:drain_worker_test).daily)
    assert daily.interrupted == 1
    assert daily.failed == 0
    assert daily.completed == 0
    assert daily.accepted_deliveries == 0

    idle = deployment_observation(pid)
    check_deployment_boundary(fixture, busy, idle)
    # A duplicate/stale DOWN cannot release or finish the worker twice.
    send(pid, {:DOWN, entry.ref, :process, entry.pid, {:shutdown, :deployment_drain}})
    assert :sys.get_state(pid).retry_attempts[issue.id].attempt == 2
    assert Governor.snapshot().busy == 0

    File.rm!(drain)
    assert Governor.draining?() == false
    File.rm!(Path.join(fixture.root, "turn-started"))
    File.rm!(Path.join(fixture.root, "finish-turn"))
    retry = :sys.get_state(pid).retry_attempts[issue.id]
    send(pid, {:retry_issue, issue.id, retry.retry_token})
    eventually(fn -> File.exists?(Path.join(fixture.root, "turn-started")) end)
    resumed = :sys.get_state(pid).running[issue.id]
    assert resumed.item_attempt == entry.item_attempt
    assert resumed.retry_attempt == 2
    assert resumed.issue.description == issue.description
    send(pid, {:DOWN, entry.ref, :process, entry.pid, {:shutdown, :deployment_drain}})
    assert :sys.get_state(pid).running[issue.id].run_id == resumed.run_id
    assert Governor.snapshot().busy == 1
    change_fixture(fixture, %{"wait_turn" => false})
    File.write!(Path.join(fixture.root, "finish-turn"), "")
    eventually(fn -> Enum.count(requests(fixture), &(&1["method"] == "turn/start")) == 4 end)
    assert Enum.all?(Operations.snapshot(:drain_worker_test).activity, &(&1[:kind] != "attempt_failed"))
    assert File.exists?(Path.join(fixture.workspace, "AGENTS.md"))
    assert File.read!(Path.join(fixture.workspace, "WORKPAD.md")) == "progress"
  end

  defp deployment_observation(pid) do
    running = map_size(:sys.get_state(pid).running)

    %{
      snapshot_status: "complete",
      project: nil,
      projects: [%{started: true, failure: nil, snapshot_status: "ok", running: running, ready: 1}],
      running: List.duplicate(%{}, running),
      counts: %{running: running},
      throttle: %{busy: Governor.snapshot().busy, service_slots: 1}
    }
  end

  defp check_deployment_boundary(fixture, busy, idle) do
    samples = Path.join(fixture.root, "deployment-samples.json")
    File.write!(samples, Jason.encode!([busy, busy, idle]))
    script = Path.expand("../ops/bin/deploy-state.py")

    code = """
    import importlib.util, json
    from pathlib import Path
    spec = importlib.util.spec_from_file_location('policy', #{inspect(script)})
    policy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(policy)
    samples = iter(json.loads(Path(#{inspect(samples)}).read_text()))
    root = Path(#{inspect(Path.join(fixture.root, "deployment"))})
    assert policy.drain(root, 'candidate', lambda: next(samples), 300, 1800, 'test', sleep=lambda _: None) == 0
    history = policy.events(root)
    assert [event['running'] for event in history if event['outcome'] == 'drain_sample'] == [1, 0]
    policy.finish(root, 'candidate', 'test', 'deployed')
    assert not (root / 'drain').exists()
    """

    assert {_, 0} = System.cmd("python3", ["-B", "-c", code])
  end

  defp eventually(fun, attempts \\ 200)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(fun, 0), do: assert(fun.())

  defp ledger do
    path = Path.join(System.tmp_dir!(), "token-ledger-#{System.unique_integer([:positive])}.dets")
    table = :token_cache_ledger_test
    {:ok, ^table} = Operations.open(path, table)

    on_exit(fn ->
      Operations.close(table)
      File.rm(path)
    end)

    {table, path}
  end

  defp native_fixture do
    root = Path.join(System.tmp_dir!(), "native-fixture-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspaces/GH-1")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(root, "home"))
    File.write!(Path.join(workspace, "AGENTS.md"), "initial instructions")
    {_, 0} = System.cmd("git", ["init", "-q"], cd: workspace)
    {_, 0} = System.cmd("git", ["add", "AGENTS.md"], cd: workspace)

    {_, 0} =
      System.cmd(
        "git",
        ["-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm", "fixture"],
        cd: workspace
      )

    script = Path.join(root, "server.py")

    File.write!(script, """
    import json, sys, time
    from pathlib import Path
    root = Path(#{inspect(root)})
    workspace = #{inspect(workspace)}
    state_file = root / 'state.json'
    config_file = root / 'fixture.json'
    def emit(message):
        print(json.dumps(message), flush=True)
    def usage(thread, state):
        total = state.get('usage', {}).get(thread, {'inputTokens':100, 'cachedInputTokens':80, 'outputTokens':20, 'totalTokens':400000})
        return {'method':'thread/tokenUsage/updated','params':{'threadId':thread,'turnId':state.get('last_turn','turn-1'),'tokenUsage':{'total':total}}}
    thread = None
    for line in sys.stdin:
        request = json.loads(line)
        with (root/'requests.jsonl').open('a') as out:
            out.write(json.dumps(request)+'\\n')
        method = request.get('method')
        if method == 'initialized': continue
        cfg = json.loads(config_file.read_text()) if config_file.exists() else {}
        state = json.loads(state_file.read_text()) if state_file.exists() else {}
        params = request.get('params', {})
        result = {}
        if method == 'initialize':
            for _ in range(cfg.get('initialize_noise',0)):
                emit({'method':'notice','params':{}})
                time.sleep(0.02)
            for _ in range(cfg.get('initialize_burst',0)):
                emit({'method':'notice','params':{}})
            result = {'userAgent':'codex_cli_rs/'+cfg.get('version','0.160.0'), 'codexHome':str(root/'home')}
        elif method == 'config/read':
            if cfg.get('config_error'):
                emit({'id':request['id'],'error':{'code':-1,'message':'unavailable'}})
                continue
            result = {'config':{'developer_instructions':'Existing developer rules'},'origins':{}}
        elif method == 'skills/list':
            result = {'data':[{'cwd':workspace,'skills':[],'errors':[]}]}
        elif method == 'mcpServerStatus/list':
            result = {'data':cfg.get('tools',[]),'nextCursor':None}
        elif method in ('thread/start','thread/resume'):
            if method == 'thread/start':
                state['threads'] = state.get('threads',0)+1
                thread = 'thread-'+str(state['threads'])
                emit({'method':'thread/started','params':{'thread':{'id':thread}}})
            else:
                thread = params['threadId']
                if cfg.get('restore_usage',True): emit(usage(thread, state))
            result = {'thread':{'id':thread,'status':{'type':'idle'}},'model':'resolved-model','modelProvider':'fixture','reasoningEffort':'high','serviceTier':None,'instructionSources':[workspace+'/AGENTS.md'],'cwd':workspace,'approvalPolicy':params['approvalPolicy'],'sandbox':params['sandbox']}
        elif method == 'thread/turns/list':
            result = {'data':[{'id':state.get('last_turn','turn-1'),'status':cfg.get('last_status','completed')}]}
        elif method == 'thread/read':
            result = {'thread':{'id':params['threadId'],'status':{'type':'idle'}}}
        elif method == 'turn/start':
            if 'title' in params: raise RuntimeError('unsupported title')
            if cfg.get('wait_turn'):
                (root/'turn-started').write_text('started')
                while not (root/'finish-turn').exists(): time.sleep(0.01)
            state['turns'] = state.get('turns',0)+1
            turn = 'turn-'+str(state['turns'])
            state['last_turn'] = turn
            result = {'turn':{'id':turn}}
            if 'rerouted_model' in cfg:
                emit({'method':'model/rerouted','params':{'toModel':cfg['rerouted_model']}})
            emit(usage(thread, state))
            emit({'method':'turn/completed','params':{'threadId':'foreign','turn':{'id':'foreign','status':'completed'}}})
            emit({'method':'turn/completed','params':{'threadId':thread,'turn':{'id':turn,'status':cfg.get('terminal_status','completed')}}})
        elif method == 'account/usage/read':
            result = {'threadUsage':None}
        else:
            raise RuntimeError('unsupported method '+method)
        state_file.write_text(json.dumps(state))
        emit({'id':request['id'],'result':result})
    """)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(root, "workspaces"),
      codex_command: "python3 #{script}"
    )

    on_exit(fn -> File.rm_rf(root) end)

    %{
      root: root,
      workspace: workspace,
      issue: %Issue{id: "1", identifier: "GH-1", title: "Fixture", kind: :issue}
    }
  end

  defp change_fixture(fixture, changes) do
    path = Path.join(fixture.root, "fixture.json")

    previous =
      case File.read(path) do
        {:ok, content} -> Jason.decode!(content)
        _ -> %{}
      end

    File.write!(path, Jason.encode!(Map.merge(previous, changes)))
  end

  defp requests(fixture),
    do:
      Path.join(fixture.root, "requests.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
end
