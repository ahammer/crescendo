defmodule SymphonyElixir.ServiceWebTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{Governor, Operations, Project, Projects, Service, SourceRevision}

  defmodule PollTracker do
    def fetch_issues_by_states(_states), do: {:error, :offline_tracker}
    def fetch_issues_by_ids(_ids), do: {:error, :offline_tracker}
  end

  @endpoint SymphonyElixirWeb.Endpoint

  setup context do
    root = Path.join(System.tmp_dir!(), "symphony-service-web-#{System.unique_integer([:positive])}")

    route = %{model: "gpt-6.1-sol", effort: "high"}
    routing = if context[:quiet_startup], do: %{label_prefix: "symphony:model:", default: route, labels: %{"symphony:model:sol" => route}}
    interval = if context[:quiet_startup], do: 3_600_000, else: 30_000

    for id <- ["alpha", "beta"] do
      dir = Path.join([root, "projects", id])
      File.mkdir_p!(dir)
      write_workflow_file!(Path.join(dir, "WORKFLOW.md"), tracker_kind: "memory", tracker_excluded_labels: ["hold"], codex_routing: routing, poll_interval_ms: interval)
    end

    quiet = if context[:quiet_startup], do: "\nquiet_window: {start: '03:00', end: '04:00', time_zone: America/Vancouver, drain_minutes: 60}", else: ""
    File.write!(Path.join(root, "crescendo.yml"), "paths: {state: state}\npool: {slots: 2}\nprojects: {alpha: {weight: 2}, beta: {redact: true, research_exclusive: global}}" <> quiet)
    {:ok, service} = Service.load(Path.join(root, "crescendo.yml"))

    # A held issue shows in the queue without starting an agent.
    labels = if context[:quiet_startup], do: ["symphony:quiet"], else: ["hold"]
    issue = %Issue{id: "issue-held", identifier: "MT-7", title: "Held work", state: "In Progress", labels: labels, dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    if context[:quiet_startup] do
      Application.put_env(:symphony_elixir, :governor_now, fn -> ~U[2025-10-08 09:30:00Z] end)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :governor_now) end)
    end

    previous = Service.current()
    :ok = Service.put_current(service)

    on_exit(fn ->
      :persistent_term.put({Service, :current}, previous)
      File.rm_rf(root)
    end)

    start_supervised!({Governor, service})
    start_supervised!({Projects, service})

    wait_for(fn ->
      assert Projects.failures() == %{}
      Enum.all?(["alpha", "beta"], &GenServer.whereis(SymphonyElixir.Project.via(&1, :orchestrator)))
    end)

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), dashboard_reload_ms: 0, snapshot_timeout_ms: 100)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    wait_for(fn -> length(json_response(get(build_conn(), "/api/v1/state"), 200)["upcoming"]["waiting"]) == 2 end)
    {:ok, service: service, quiet_issue: issue}
  end

  test "control observation is live, scoped and independent of retained analytics" do
    alpha = GenServer.whereis(Project.via("alpha", :orchestrator))
    :erlang.trace_pattern({Operations, :snapshot, 2}, true, [])
    :erlang.trace(alpha, true, [:call])

    try do
      state = json_response(get(build_conn(), "/api/v1/state?view=control"), 200)
      assert state["view"] == "control"
      assert state["schema_version"] == 1
      assert state["snapshot_status"] == "complete"
      assert state["observed_at"]
      assert state["counts"]["waiting"] == 2
      refute Map.has_key?(state, "usage")
      refute_receive {:trace, ^alpha, :call, {Operations, :snapshot, _}}, 20

      filtered = json_response(get(build_conn(), "/api/v1/state?view=control&project=alpha"), 200)
      assert filtered["project"] == "alpha"
      assert filtered["counts"]["waiting"] == 1
      assert [%{"project" => "alpha"}] = filtered["upcoming"]["waiting"]
      assert [%{"snapshot_status" => "ok"}, %{"snapshot_status" => "not_selected"}] = filtered["projects"]

      missing = json_response(get(build_conn(), "/api/v1/state?view=control&project=missing"), 200)
      assert missing["snapshot_status"] == "partial"
      assert missing["counts"]["running"] == nil
    after
      :erlang.trace(alpha, false, [:call])
      :erlang.trace_pattern({Operations, :snapshot, 2}, false, [])
    end
  end

  test "control view retains run identity and helper capacity while respecting privacy" do
    for id <- ["alpha", "beta"] do
      pid = GenServer.whereis(Project.via(id, :orchestrator))

      :sys.replace_state(pid, fn state ->
        issue = hd(state.polled_issues)

        entry = %{
          identifier: issue.identifier,
          issue: issue,
          run_id: "#{id}-run",
          session_id: nil,
          codex_app_server_pid: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          started_at: DateTime.utc_now(),
          last_codex_timestamp: nil,
          last_codex_message: nil,
          last_codex_event: nil
        }

        %{state | running: %{issue.id => entry}, helpers: %{"helper" => %{run_id: "#{id}-helper", parent_run_id: "#{id}-run", parent_issue_id: issue.id, status: "running"}}}
      end)
    end

    state = json_response(get(build_conn(), "/api/v1/state?view=control"), 200)
    assert state["counts"]["running"] == 2
    assert state["counts"]["helpers"] == 2
    alpha = Enum.find(state["running"], &(&1["project"] == "alpha"))
    beta = Enum.find(state["running"], &(&1["project"] == "beta"))
    assert alpha["run_id"] == "alpha-run"
    assert alpha["issue_identifier"] == "MT-7"
    assert beta["redacted"]
    refute Map.has_key?(beta, "run_id")
    refute Map.has_key?(beta, "title")
    assert Enum.find(state["helpers"], &(&1["project"] == "alpha"))["parent_run_id"] == "alpha-run"
    refute Map.has_key?(Enum.find(state["helpers"], &(&1["project"] == "beta")), "parent_run_id")
  end

  test "a missing governor makes otherwise responsive project control state partial" do
    stop_supervised!(Governor)
    state = json_response(get(build_conn(), "/api/v1/state?view=control&project=alpha"), 200)
    assert state["snapshot_status"] == "partial"
    assert state["counts"]["running"] == nil
    assert [%{"project" => "governor", "status" => "unavailable"}] = state["snapshot_errors"]
    assert hd(state["projects"])["snapshot_status"] == "ok"
  end

  test "control deadline covers all actors and never turns a partial read into idle" do
    actors = [Governor, Project.via("alpha", :orchestrator), Project.via("beta", :orchestrator)]
    Enum.each(actors, &:sys.suspend/1)

    try do
      started = System.monotonic_time(:millisecond)
      state = json_response(get(build_conn(), "/api/v1/state?view=control"), 200)
      assert System.monotonic_time(:millisecond) - started < 300
      assert state["snapshot_status"] == "partial"
      assert length(state["snapshot_errors"]) == 3
      assert state["counts"]["running"] == nil
      assert state["observed_at"] == nil
      assert state["upcoming"]["available_slots"] == nil
    after
      Enum.each(actors, &:sys.resume/1)
    end
  end

  @tag quiet_startup: true
  test "quiet work survives a cold service start and project restart", %{service: service} do
    assert Governor.snapshot().quiet_window.phase == "idle"

    for id <- ["alpha", "beta"] do
      pid = GenServer.whereis(SymphonyElixir.Project.via(id, :orchestrator))
      state = :sys.get_state(pid)
      assert state.issues_observed_at
      assert state.throttle.avoid == %{}
      send(pid, :run_poll_cycle)
      assert :sys.get_state(pid).issues_observed_at
      assert GenServer.whereis(SymphonyElixir.Project.via(id, :orchestrator)) == pid
    end

    assert Governor.snapshot().quiet_window.phase == "preparing"
    stop_supervised!(Projects)
    start_supervised!({Projects, service})
    wait_for(fn -> length(json_response(get(build_conn(), "/api/v1/state"), 200)["upcoming"]["waiting"]) == 2 end)
    assert Governor.snapshot().quiet_window.phase == "idle"
    assert json_response(get(build_conn(), "/api/v1/state"), 200)["snapshot_status"] == "complete"
    assert healthy(SymphonyElixirWeb.Presenter.payload(timeout: 1_000)) == 0
  end

  test "persisted inventory and a fresh sibling cannot establish restarted project tracker readiness", %{service: service} do
    beta = GenServer.whereis(Project.via("beta", :orchestrator))
    before = :sys.get_state(beta)
    assert Orchestrator.snapshot(beta, 1_000).tracker_ready
    inventory = [%{number: 7, title: "Private persisted inventory", url: "https://github.test/pull/7", draft: true}]
    Operations.save_pull_inventory(before.operations, inventory, before.issues_observed_at)
    prepared = %{"issue-held" => %{issue_id: "issue-held", item_attempt: 1, run_id: "prepared", reason: "quiet acceptance"}}
    assert :ok = Operations.save_quiet_continuations(before.operations, prepared)
    :sys.replace_state(beta, &%{&1 | quiet_continuations: prepared})

    previous = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, PollTracker)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :linear_client_module, previous),
        else: Application.delete_env(:symphony_elixir, :linear_client_module)
    end)

    workflow = Enum.find(Service.projects(service), &(&1.id == "beta")).workflow
    write_workflow_file!(workflow, tracker_kind: "linear", poll_interval_ms: 3_600_000)
    Project.with_project("beta", &WorkflowStore.force_reload/0)
    send(beta, :run_poll_cycle)
    failed = Orchestrator.snapshot(beta, 1_000)
    refute failed.tracker_ready
    assert :sys.get_state(beta).quiet_continuations == prepared
    assert failed.upcoming.observed_at == before.issues_observed_at
    assert failed.upcoming.error == "tracker fetch failed"
    state = SymphonyElixirWeb.Presenter.payload(timeout: 1_000)
    assert [%{tracker_ready: true}, %{tracker_ready: false}] = state.projects
    assert healthy(state) == 1

    runtime = Project.via("beta", :agent_runtime)
    :ok = Supervisor.terminate_child(runtime, Project.via("beta", :orchestrator))
    assert {:ok, restarted} = Supervisor.restart_child(runtime, Project.via("beta", :orchestrator))
    refute restarted == beta
    unobserved = Orchestrator.snapshot(restarted, 1_000)
    assert unobserved.pull_requests.items == inventory
    assert unobserved.pull_requests.observed_at == before.issues_observed_at
    assert unobserved.upcoming.observed_at == nil
    assert :sys.get_state(restarted).quiet_continuations == prepared
    refute unobserved.tracker_ready
    assert healthy(SymphonyElixirWeb.Presenter.payload(timeout: 1_000)) == 1

    # An empty successful read in the new process is sufficient; inventory and queue size are independent.
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    write_workflow_file!(workflow, tracker_kind: "memory", poll_interval_ms: 3_600_000)
    Project.with_project("beta", &WorkflowStore.force_reload/0)
    send(restarted, :run_poll_cycle)
    recovered = Orchestrator.snapshot(restarted, 1_000)
    assert recovered.tracker_ready
    assert recovered.upcoming.observed_at
    assert recovered.upcoming.error == nil
    assert recovered.upcoming.ready == []
    assert :sys.get_state(restarted).quiet_continuations == %{}
    state = SymphonyElixirWeb.Presenter.payload(timeout: 1_000)
    assert Enum.all?(state.projects, & &1.tracker_ready)
    assert healthy(state) == 0
  end

  @tag quiet_startup: true
  test "quiet demand retains policy gates and counts eligible held or due retries", %{quiet_issue: issue} do
    pid = GenServer.whereis(SymphonyElixir.Project.via("alpha", :orchestrator))
    initial = :sys.get_state(pid)
    now = System.monotonic_time(:millisecond)
    held = %{due_at_ms: now + 60_000, delay_type: :held, attempt: 1, timer_ref: nil}
    policy = initial.throttle

    for {throttle, retries, expected} <- [
          {%{policy | paused: "quota low"}, %{}, "idle"},
          {%{policy | over_budget: "daily budget", allow: []}, %{}, "idle"},
          {%{policy | avoid: %{"gpt-6.1-sol" => "backed off"}}, %{}, "idle"},
          {policy, %{issue.id => held}, "preparing"},
          {policy, %{issue.id => %{held | delay_type: :backoff, due_at_ms: now - 1}}, "preparing"},
          {policy, %{issue.id => %{held | delay_type: :backoff}}, "idle"},
          {%{policy | paused: "quota low"}, %{issue.id => held}, "idle"},
          {%{policy | over_budget: "daily budget", allow: []}, %{issue.id => held}, "idle"},
          {%{policy | avoid: %{"gpt-6.1-sol" => "backed off"}}, %{issue.id => held}, "idle"}
        ] do
      Governor.checkin("alpha", 0, 0, 0)
      Governor.checkin("beta", 0, 0, 0)
      :sys.replace_state(pid, fn state -> %{state | throttle: throttle, retry_attempts: retries} end)
      send(pid, :run_poll_cycle)
      assert :sys.get_state(pid).retry_attempts == retries
      assert GenServer.whereis(SymphonyElixir.Project.via("alpha", :orchestrator)) == pid
      assert Governor.snapshot().quiet_window.phase == expected
    end
  end

  @tag quiet_startup: true
  test "deferred unlabeled demand keeps throttle, route and dependency gates", %{quiet_issue: issue} do
    issue = %{issue | labels: []}
    pid = GenServer.whereis(Project.via("alpha", :orchestrator))
    initial = :sys.get_state(pid)

    prepared = %{
      issue_id: issue.id,
      item_attempt: 1,
      run_id: "prepared",
      retry_attempt: 0,
      reason: "quiet digest required",
      source_sha: "source",
      pull_request: "https://github.test/pull/7",
      evidence: [],
      unmet_acceptance: ["p99 failed"],
      final_attempt: false
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    for {policy, item, expected} <- [
          {%{initial.throttle | paused: "quota low"}, issue, "idle"},
          {%{initial.throttle | over_budget: "daily budget", allow: []}, issue, "idle"},
          {%{initial.throttle | avoid: %{"gpt-6.1-sol" => "backed off"}}, issue, "idle"},
          {initial.throttle, %{issue | dispatchable: false, blocked_by: [%{identifier: "GH-9"}]}, "idle"},
          {%{initial.throttle | over_budget: "daily budget", allow: ["continuation"]}, issue, "preparing"}
        ] do
      Governor.checkin("alpha", 0, 0, 0)
      Governor.checkin("beta", 0, 0, 0)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [item])
      :sys.replace_state(pid, &%{&1 | throttle: policy, quiet_continuations: %{issue.id => prepared}})
      send(pid, :run_poll_cycle)
      assert :sys.get_state(pid).running == %{}
      assert Governor.snapshot().quiet_window.phase == expected
    end

    state = json_response(get(build_conn(), "/api/v1/state?project=alpha"), 200)
    assert [%{"reason" => "quiet digest required", "unmet_acceptance" => ["p99 failed"]}] = state["deferred"]
    assert Enum.any?(state["upcoming"]["waiting"], &(&1["reason"] =~ "quiet digest required"))
    assert get(build_conn(), "/api/v1/state").status == 200
    assert post(build_conn(), "/api/v1/state", %{}).status == 405
  end

  @tag quiet_startup: true
  test "closed and missing quiet deliveries are forgotten across restart without resetting their budget", %{quiet_issue: issue} do
    pid = GenServer.whereis(Project.via("alpha", :orchestrator))
    state = :sys.get_state(pid)
    autopilot = Map.put(state.autopilot, :item_attempts, %{issue.id => 2})
    prepared = %{issue_id: issue.id, item_attempt: 3, run_id: "prepared", reason: "quiet acceptance pending"}
    Operations.save_autopilot_state(state.operations, autopilot)

    for items <- [[%{issue | state: "Closed"}], []] do
      assert :ok = Operations.save_quiet_continuations(state.operations, %{issue.id => prepared})
      :sys.replace_state(pid, &%{&1 | autopilot: autopilot, quiet_continuations: %{issue.id => prepared}})
      Application.put_env(:symphony_elixir, :memory_tracker_issues, items)
      send(pid, :run_poll_cycle)
      assert :sys.get_state(pid).quiet_continuations == %{}
      assert Operations.quiet_continuations(state.operations) == %{}
      assert :sys.get_state(pid).autopilot.item_attempts[issue.id] == 2
      assert Orchestrator.snapshot(pid, 1_000).deferred == []
    end

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | labels: ["hold"]}])
    runtime = Project.via("alpha", :agent_runtime)
    :ok = Supervisor.terminate_child(runtime, Project.via("alpha", :orchestrator))
    assert {:ok, restarted} = Supervisor.restart_child(runtime, Project.via("alpha", :orchestrator))
    assert :sys.get_state(restarted).quiet_continuations == %{}
    assert :sys.get_state(restarted).autopilot.item_attempts[issue.id] == 2
    assert Orchestrator.snapshot(restarted, 1_000).deferred == []
  end

  @tag quiet_startup: true
  test "removing the quiet window on restart fails a retained final attempt exactly once", %{service: service, quiet_issue: issue} do
    project = Enum.find(Service.projects(service), &(&1.id == "alpha"))

    write_workflow_file!(project.workflow,
      tracker_kind: "memory",
      tracker_excluded_labels: ["hold"],
      poll_interval_ms: 3_600_000,
      autopilot: %{
        "enabled" => true,
        "max_item_attempts" => 3,
        "channels" => %{"fixture" => "Unused fixture research"},
        "prompts" => %{"pull_request" => service.path, "research" => service.path}
      }
    )

    pid = GenServer.whereis(Project.via("alpha", :orchestrator))
    state = :sys.get_state(pid)

    autopilot =
      state.autopilot
      |> Map.put(:item_attempts, %{issue.id => 2})
      |> Map.put(:tasks, %{"fixture" => %{finished_at: DateTime.add(DateTime.utc_now(), 1, :day), attempts: 0, last: :delivered}})

    prepared = %{issue_id: issue.id, identifier: issue.identifier, item_attempt: 3, final_attempt: true, run_id: "prepared", reason: "quiet acceptance pending"}
    Operations.save_autopilot_state(state.operations, autopilot)
    assert :ok = Operations.save_quiet_continuations(state.operations, %{issue.id => prepared})
    :sys.replace_state(pid, &%{&1 | autopilot: autopilot, quiet_continuations: %{issue.id => prepared}})
    Application.put_env(:symphony_elixir, :memory_tracker_writes, [])
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_writes) end)

    stop_supervised!(Projects)
    stop_supervised!(Governor)
    service = %{service | quiet_window: nil}
    Service.put_current(service)
    start_supervised!({Governor, service})
    start_supervised!({Projects, service})

    wait_for(fn ->
      assert Projects.failures() == %{}
      is_pid(GenServer.whereis(Project.via("alpha", :orchestrator)))
    end)

    restarted = GenServer.whereis(Project.via("alpha", :orchestrator))
    send(restarted, :run_poll_cycle)
    recovered = :sys.get_state(restarted)
    assert recovered.quiet_continuations == %{}
    assert recovered.autopilot.item_attempts[issue.id] == 3
    assert recovered.autopilot.retired_items[issue.id]
    assert Operations.quiet_continuations(recovered.operations) == %{}
    assert Operations.autopilot_state(recovered.operations).item_attempts[issue.id] == 3
    assert recovered.running == %{}
    assert Governor.snapshot().quiet_window.phase == "idle"

    send(restarted, :run_poll_cycle)
    assert :sys.get_state(restarted).autopilot.item_attempts[issue.id] == 3
    assert [{:retire, id, reason}] = Application.get_env(:symphony_elixir, :memory_tracker_writes)
    assert id == issue.id
    assert reason =~ "quiet acceptance window removed"
  end

  test "operator Fast defaults appear in the dashboard and API without UI controls", %{service: service} do
    {:ok, view, _html} = live(build_conn(), "/")
    assert has_element?(view, "#priority-mode", "Fast mode: Off")

    set = fn enabled ->
      message = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => %{"name" => "crescendo_priority_mode_set", "arguments" => %{"enabled" => enabled}}}
      assert {%{result: %{isError: false}}, true} = SymphonyElixir.MCP.handle(message, service, true)
      send(view.pid, :observability_updated)
    end

    set.(true)
    assert has_element?(view, "#priority-mode", "Fast mode: On")
    state = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert %{"enabled" => true, "service_tier" => "fast", "expires_at" => nil} = state["priority_mode"]
    refute has_element?(view, "#priority-mode button")
    refute has_element?(view, "#priority-mode input")

    set.(false)
    assert has_element?(view, "#priority-mode", "Fast mode: Off")
  end

  test "the state API merges every project and filters to one" do
    state = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state["project"] == nil
    assert [%{"id" => "alpha", "weight" => 2, "failure" => nil, "started" => true}, %{"id" => "beta"}] = state["projects"]
    assert state["runtime"]["tracker"] == "2 projects"
    assert state["header"]["max_agents"] == 2
    assert Enum.map(state["upcoming"]["waiting"], &{&1["project"], &1["title"]}) == [{"alpha", "Held work"}, {"beta", "Private work"}]
    assert %{"service_slots" => 2, "busy" => 0} = state["throttle"]

    alpha = json_response(get(build_conn(), "/api/v1/state?project=alpha"), 200)
    assert alpha["project"] == "alpha"
    assert alpha["runtime"]["tracker"] == "memory:project"
    assert json_response(get(build_conn(), "/api/v1/state?project=gamma"), 200)["runtime"]["tracker"] == "2 projects"
    assert Enum.map(alpha["upcoming"]["waiting"], & &1["project"]) == ["alpha"]

    assert json_response(get(build_conn(), "/api/v1/alpha/MT-404"), 404)["error"]["code"] == "issue_not_found"
    assert json_response(get(build_conn(), "/api/v1/MT-404"), 404)["error"]["code"] == "issue_not_found"
  end

  test "polling health requires tracker observations from every selected project" do
    beta = GenServer.whereis(SymphonyElixir.Project.via("beta", :orchestrator))
    now = DateTime.utc_now()

    for {observed_at, error, status, detail} <- [
          {nil, nil, "warning", "Tracker observation incomplete"},
          {DateTime.add(now, -600), nil, "warning", "Last read 10m ago"},
          {now, "tracker unavailable", "critical", "Read failed: beta: tracker unavailable"},
          {now, nil, "healthy", nil}
        ],
        checking? <- [false, true] do
      :sys.replace_state(beta, fn state ->
        %{state | issues_observed_at: observed_at, issues_error: error, poll_check_in_progress: checking?}
      end)

      for query <- ["", "?project=beta", "?project=beta&history=full"] do
        payload = json_response(get(build_conn(), "/api/v1/state" <> query), 200)
        polling = Enum.find(payload["health"]["coordinator"]["checks"], &(&1["name"] == "Polling loop"))
        tracker = Enum.find(payload["health"]["system"]["checks"], &(&1["name"] == "Tracker"))
        assert polling["status"] == status
        assert tracker["status"] == status
        expected = detail || if(checking?, do: "Polling now", else: "Every 30s")
        assert polling["detail"] == expected
        if detail, do: assert(tracker["detail"] == detail)
        if is_nil(observed_at), do: assert(is_nil(payload["upcoming"]["observed_at"]))
      end

      alpha = json_response(get(build_conn(), "/api/v1/state?project=alpha"), 200)
      assert alpha["health"]["coordinator"]["status"] == "operational"
      assert alpha["upcoming"]["observed_at"]
    end
  end

  test "tracker freshness uses each selected project's poll interval", %{service: service} do
    for {alpha_interval, alpha_age, beta_interval, beta_age, expected} <- [
          {3_600_000, 60, 30_000, 600, "warning"},
          {3_600_000, 3_600, 30_000, 600, "warning"},
          {30_000, 60, 3_600_000, 600, "healthy"},
          {3_600_000, 600, 30_000, 60, "healthy"},
          {3_600_000, 60, 1_500, 6, "healthy"},
          {3_600_000, 60, 500, 1, "healthy"},
          {3_600_000, 60, 500, 3, "warning"}
        ] do
      now = DateTime.utc_now()

      for {id, interval, age} <- [{"alpha", alpha_interval, alpha_age}, {"beta", beta_interval, beta_age}] do
        workflow = Enum.find(Service.projects(service), &(&1.id == id)).workflow
        write_workflow_file!(workflow, tracker_kind: "memory", poll_interval_ms: interval)
        Project.with_project(id, &WorkflowStore.force_reload/0)
        pid = GenServer.whereis(Project.via(id, :orchestrator))
        :sys.replace_state(pid, &%{&1 | poll_interval_ms: interval, issues_observed_at: DateTime.add(now, -age)})
      end

      for {query, status} <- [{"", expected}, {"?project=alpha", "healthy"}, {"?project=beta", expected}] do
        payload = json_response(get(build_conn(), "/api/v1/state" <> query), 200)
        tracker = Enum.find(payload["health"]["system"]["checks"], &(&1["name"] == "Tracker"))
        polling = Enum.find(payload["health"]["coordinator"]["checks"], &(&1["name"] == "Polling loop"))
        assert tracker["status"] == status
        assert polling["status"] == status
        if status == "warning" and beta_age == 600, do: assert(tracker["detail"] == "Last read 10m ago")
      end
    end
  end

  test "service revision is shared across real snapshots, private filters and dashboard errors" do
    revision = String.duplicate("c", 40)
    root = Path.join(System.tmp_dir!(), "service-release-#{System.unique_integer([:positive])}")
    release = Path.join([root, "releases", revision])
    source = Path.join(release, "source/elixir")
    File.mkdir_p!(source)
    File.write!(Path.join(release, ".built"), "")
    previous = SourceRevision.metadata()

    on_exit(fn ->
      :persistent_term.put({SourceRevision, :metadata}, previous)
      File.rm_rf!(root)
    end)

    SourceRevision.initialize(source)
    identity = %{"revision" => revision, "commit_url" => "https://github.com/ahammer/crescendo/commit/" <> revision}

    for query <- ["", "?history=full", "?project=alpha", "?project=beta&history=full"] do
      state = json_response(get(build_conn(), "/api/v1/state" <> query), 200)
      assert state["service"] == identity
      if query =~ "beta", do: assert(Enum.all?(state["upcoming"]["waiting"], &(&1["title"] == "Private work")))
      refute Jason.encode!(state) =~ root
    end

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ ~s(href="#{identity["commit_url"]}")
    assert html =~ ~s(title="#{revision}">ccccccc</a>)
    assert render_patch(view, "/?project=beta") =~ identity["commit_url"]

    beta = GenServer.whereis(SymphonyElixir.Project.via("beta", :orchestrator))
    :ok = :sys.suspend(beta)

    try do
      state = json_response(get(build_conn(), "/api/v1/state?project=beta"), 200)
      assert state["snapshot_status"] == "partial"
      assert state["service"] == identity
      {:ok, _view, html} = live(build_conn(), "/?project=beta")
      assert html =~ "Snapshot incomplete"
      assert html =~ identity["commit_url"]
    after
      :ok = :sys.resume(beta)
    end

    unavailable = SymphonyElixirWeb.Presenter.state_payload(:missing_revision_orchestrator, 1)
    assert unavailable.error.code == "snapshot_unavailable"
    assert unavailable.service == SourceRevision.metadata()
    html = render_component(&SymphonyElixirWeb.DashboardLive.render/1, payload: unavailable)
    assert html =~ "Snapshot unavailable"
    assert html =~ identity["commit_url"]

    SourceRevision.initialize(__DIR__)
    assert json_response(get(build_conn(), "/api/v1/state"), 200)["service"] == %{"revision" => nil, "commit_url" => nil}
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Revision unknown"
    refute html =~ "/commit/"
  end

  test "research reservations, running holds and deployment drains explain service admission" do
    Governor.checkin("alpha", 0, 1)
    Governor.checkin("beta", 0, 0)
    assert :ok = Governor.acquire("alpha", "held-slot", :issue)
    assert {:wait, "waiting for the service to go idle for research"} = Governor.acquire("beta", "research:qa", :research)

    for query <- ["", "?project=alpha", "?project=beta&history=full"] do
      state = json_response(get(build_conn(), "/api/v1/state" <> query), 200)
      assert state["throttle"]["research_hold"] == %{"project" => "beta", "phase" => "reserved"}
      assert dispatch_detail(state) =~ "Service reserved for beta research"
      refute Jason.encode!(state["throttle"]) =~ "research:qa"
    end

    for id <- ["alpha", "beta"] do
      pid = GenServer.whereis(SymphonyElixir.Project.via(id, :orchestrator))
      send(pid, :run_poll_cycle)
      :sys.get_state(pid)
    end

    recorded = json_response(get(build_conn(), "/api/v1/state?history=full"), 200)
    sample = List.last(recorded["usage"]["samples"])
    assert sample["admission"]["slots"] == 2
    assert sample["admission"]["busy"] == 1
    assert sample["admission"]["research_hold"] == %{"project" => "beta", "phase" => "reserved"}
    assert length(sample["project_samples"]) == 2
    refute Jason.encode!(sample) =~ "research:qa"
    filtered = json_response(get(build_conn(), "/api/v1/state?project=alpha&history=full"), 200)
    assert length(List.last(filtered["usage"]["samples"])["project_samples"]) == 1

    alpha = GenServer.whereis(SymphonyElixir.Project.via("alpha", :orchestrator))
    :ok = :sys.suspend(alpha)

    try do
      state = json_response(get(build_conn(), "/api/v1/state"), 200)
      assert state["snapshot_status"] == "partial"
      assert state["counts"]["running"] == nil
      assert List.last(state["usage"]["samples"])["sample_status"] == "partial"
      assert List.last(state["usage"]["samples"])["running"] == nil
      assert state["history"]["running"] == []
      assert dispatch_detail(state) =~ "counts unknown"
      assert dispatch_detail(state) =~ "Service reserved for beta research"
    after
      :ok = :sys.resume(alpha)
    end

    Governor.release("alpha", "held-slot")
    assert %{busy: 0} = Governor.snapshot()
    assert :ok = Governor.acquire("beta", "research:qa", :research)
    state = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert state["throttle"]["research_hold"] == %{"project" => "beta", "phase" => "running"}
    assert dispatch_detail(state) =~ "Service held by beta research"
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Service held by beta research"

    Governor.release("beta", "research:qa")
    assert %{busy: 0} = Governor.snapshot()
    state = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert state["throttle"]["research_hold"] == nil
    refute dispatch_detail(state) =~ "research"

    drain = Path.join(Service.current().state_root, "drain")
    File.write!(drain, "")
    state = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert state["throttle"]["draining"] == true
    assert state["throttle"]["drain_reason"] == "dispatch drain flag is present"
    assert dispatch_detail(state) =~ "New runs held: dispatch drain flag is present"
    assert {:wait, "dispatch drain flag is present"} = Governor.acquire("alpha", "next-slot", :issue)
    File.rm!(drain)
    throttle = json_response(get(build_conn(), "/api/v1/state"), 200)["throttle"]
    assert throttle["draining"] == false
    assert throttle["drain_reason"] == nil
  end

  @tag quiet_startup: true
  test "quiet drains retain their actual reason in API, dashboard and sampled history" do
    for id <- ["alpha", "beta"] do
      pid = GenServer.whereis(Project.via(id, :orchestrator))
      send(pid, :run_poll_cycle)
      assert :sys.get_state(pid).issues_observed_at
    end

    assert Governor.snapshot().quiet_window.phase == "preparing"

    for query <- ["?history=full", "?project=beta&history=full"] do
      state = json_response(get(build_conn(), "/api/v1/state" <> query), 200)
      assert state["throttle"]["drain_reason"] == "preparing for quiet acceptance"
      assert dispatch_detail(state) =~ "New runs held: preparing for quiet acceptance"
      assert List.last(state["usage"]["samples"])["admission"]["drain_reason"] == "preparing for quiet acceptance"
      refute dispatch_detail(state) =~ "Deployment"
    end

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "New runs held: preparing for quiet acceptance"
    Application.put_env(:symphony_elixir, :governor_now, fn -> ~U[2025-10-08 10:00:00Z] end)
    assert :ok = Governor.acquire("alpha", "quiet-observation", :issue, quiet: true)
    Application.put_env(:symphony_elixir, :governor_now, fn -> ~U[2025-10-08 11:00:00Z] end)
    state = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert state["throttle"]["drain_reason"] == "waiting for a quiet acceptance run to finish"
    assert dispatch_detail(state) =~ "waiting for a quiet acceptance run to finish"
    Governor.release("alpha", "quiet-observation")
    assert json_response(get(build_conn(), "/api/v1/state"), 200)["throttle"]["drain_reason"] == nil
  end

  test "managed owner evidence reaches read-only API, dashboard and retained admission history" do
    root = Service.current().state_root
    owner = start_drain_owner(root)
    observed = Governor.observe()
    table = :sys.get_state(Project.via("alpha", :orchestrator)).operations
    sample = %{running: 0, ready: 1, waiting: 0, attention: 0, open_prs: 0, spend_micro: 0, admission: observed}
    Operations.record_sample(table, sample)
    state = json_response(get(build_conn(), "/api/v1/state?history=full"), 200)
    assert state["throttle"]["drain_owner"]["owner_status"] == "live"
    assert dispatch_detail(state) =~ "managed deployment drain is present"
    assert List.last(state["usage"]["samples"])["admission"]["drain_owner"]["kind"] == "managed"
    payload = Jason.encode!(state)
    refute payload =~ "private-owner"
    refute payload =~ root
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "managed deployment drain is present"
    Port.command(owner, "exit\n")
    assert_receive {^owner, {:exit_status, 0}}, 5_000
    state = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert state["throttle"]["drain_owner"]["owner_status"] == "abandoned"
    assert File.exists?(Path.join(root, "deploy-drain.json"))
    refute Governor.draining?()
    assert json_response(get(build_conn(), "/api/v1/state"), 200)["throttle"]["drain_owner"] == nil
  end

  test "full history includes older work across projects with the usual privacy and filters" do
    for id <- ["alpha", "beta"] do
      table = :sys.get_state(SymphonyElixir.Project.via(id, :orchestrator)).operations

      for number <- 1..105 do
        SymphonyElixir.Operations.event(table, "dispatch", %{issue_identifier: "GH-#{number}", summary: "#{id} evidence"})
      end

      bucket = div(System.os_time(:second), 300) - 288
      :dets.insert(table, {{:sample, bucket}, %{running: 0, ready: 1, waiting: 0, attention: 0, open_prs: 0, spend_micro: 0}})
    end

    recent = json_response(get(build_conn(), "/api/v1/state"), 200)
    history = json_response(get(build_conn(), "/api/v1/state?history=full"), 200)
    assert length(recent["usage"]["activity"]) == 100
    assert length(history["usage"]["activity"]) == 210
    assert Enum.count(history["usage"]["activity"], &(&1["project"] == "alpha")) == 105
    assert Enum.count(history["usage"]["activity"], &(&1["project"] == "beta")) == 105
    refute Jason.encode!(history) =~ "beta evidence"
    assert Enum.any?(history["usage"]["activity"], &(&1["summary"] == "alpha evidence"))
    assert length(history["usage"]["samples"]) == length(recent["usage"]["samples"]) + 1
    assert history["usage"]["daily"] == recent["usage"]["daily"]

    alpha = json_response(get(build_conn(), "/api/v1/state?history=full&project=alpha"), 200)
    assert length(alpha["usage"]["activity"]) == 105
    assert Enum.all?(alpha["usage"]["activity"], &(&1["project"] == "alpha"))
    assert length(json_response(get(build_conn(), "/api/v1/state?history=invalid"), 200)["usage"]["activity"]) == 100
  end

  test "a suspended project is unknown while healthy data survives, and recovers" do
    beta = GenServer.whereis(SymphonyElixir.Project.via("beta", :orchestrator))
    :ok = :sys.suspend(beta)

    try do
      Governor.checkin("alpha", 0, 0)
      Governor.checkin("beta", 0, 1)
      assert :ok = Governor.acquire("beta", "held-slot", :issue)
      state = SymphonyElixirWeb.Presenter.payload(timeout: 100)
      assert state.snapshot_status == "partial"
      assert state.upcoming.observed_at == nil
      assert %{status: "warning"} = Enum.find(state.health.system.checks, &(&1.name == "Tracker"))
      assert %{status: "warning"} = Enum.find(state.health.coordinator.checks, &(&1.name == "Polling loop"))
      assert Enum.all?(Map.values(state.counts), &is_nil/1)
      assert [%{project: "alpha", title: "Held work"}] = state.upcoming.waiting
      assert [alpha, beta] = state.projects
      assert %{id: "alpha", snapshot_status: "ok", tracker_ready: true} = alpha
      assert %{id: "beta", snapshot_status: "timeout", tracker_ready: nil, running: nil, ready: nil} = beta
      assert healthy(state) == 1
      assert state.health.coordinator.status == "degraded"
      assert state.health.system.status in ["degraded", "down"]
      assert %{name: "Dispatch", status: "warning", detail: detail} = Enum.find(state.health.coordinator.checks, &(&1.name == "Dispatch"))
      assert detail =~ "1 of 2 service slots held"
      assert detail =~ "counts unknown"

      api = json_response(get(build_conn(), "/api/v1/state"), 200)
      assert api["snapshot_status"] == "partial"
      assert api["counts"]["running"] == nil
      assert api["snapshot_errors"] == [%{"project" => "beta", "status" => "timeout"}]

      alpha = SymphonyElixirWeb.Presenter.payload(timeout: 100, project: "alpha")
      assert alpha.snapshot_status == "complete"
      assert alpha.counts.waiting == 1
      assert Enum.at(alpha.projects, 1).snapshot_status == "not_selected"
      assert Enum.at(alpha.projects, 1).running == nil
      assert Enum.at(alpha.projects, 1).tracker_ready == nil
      assert healthy(alpha) == 1
      assert SymphonyElixirWeb.Presenter.payload(timeout: 100, project: "beta").snapshot_status == "partial"

      {:ok, view, html} = live(build_conn(), "/")
      assert html =~ "Snapshot incomplete"
      assert html =~ "beta: timeout"
      assert html =~ "—/2"
      assert has_element?(view, ".issue-card-select", "Held work")
      refute html =~ "Free slot"
      refute html =~ "No agent is running."

      history = view |> element(".section-tab[phx-value-id='history']", "History") |> render_click()
      assert history =~ "Queue unknown."
      assert history =~ "Running work unknown."
    after
      :ok = Governor.release("beta", "held-slot")
      :ok = :sys.resume(beta)
    end

    recovered = SymphonyElixirWeb.Presenter.payload(timeout: 1_000)
    assert recovered.snapshot_status == "complete"
    assert recovered.snapshot_errors == []
    assert recovered.health.coordinator.status == "operational"
    refute Enum.any?(recovered.health.coordinator.checks, &(&1.name == "Project snapshots"))
    assert recovered.counts.waiting == 2
    assert Enum.all?(recovered.projects, &(&1.snapshot_status == "ok"))
    assert healthy(recovered) == 0
    assert Enum.map(recovered.upcoming.waiting, & &1.title) == ["Held work", "Private work"]
  end

  test "an unavailable project is reported and partial data stays redacted" do
    runtime = SymphonyElixir.Project.via("alpha", :agent_runtime)
    :ok = Supervisor.terminate_child(runtime, SymphonyElixir.Project.via("alpha", :orchestrator))
    stop_supervised!(Governor)

    try do
      state = SymphonyElixirWeb.Presenter.payload(timeout: 100)
      assert state.snapshot_status == "partial"
      assert [alpha, beta] = state.projects
      assert %{id: "alpha", started: false, snapshot_status: "unavailable", tracker_ready: nil, running: nil, ready: nil} = alpha
      assert %{id: "beta", snapshot_status: "ok"} = beta
      assert [%{project: "beta", title: "Private work"}] = state.upcoming.waiting
      refute Jason.encode!(state.upcoming) =~ "Held work"
      dispatch = Enum.find(state.health.coordinator.checks, &(&1.name == "Dispatch"))
      assert dispatch.detail == "Running and queue counts unknown"
      assert Enum.all?(Map.values(state.counts), &is_nil/1)
    after
      assert {:ok, _pid} = Supervisor.restart_child(runtime, SymphonyElixir.Project.via("alpha", :orchestrator))
    end
  end

  test "issue board keeps project-scoped cards and filters waiting work without implying it is blocked" do
    put_board_blocked_issue()
    {:ok, view, html} = live(build_conn(), "/")

    assert html |> Floki.parse_document!() |> Floki.find(".issue-card") |> length() == 3
    assert has_element?(view, ".issue-lane[aria-label='Intake issues']", "Held work")
    assert has_element?(view, ".issue-card-select", "Private work")
    assert has_element?(view, ".issue-lane[aria-label='Active issues']", "No matching observed issues")
    assert has_element?(view, ".issue-lane[aria-label='Done issues']", "No matching observed issues")

    view |> element(".issue-card-select", "Review GPU recovery") |> render_click()
    assert has_element?(view, "#issue-detail.is-open .issue-story-title", "Review GPU recovery")
    assert has_element?(view, "#issue-detail", "Waiting for validation evidence")
    assert has_element?(view, "#issue-detail", "No explicit worker run IDs are available")

    view |> form("form[phx-change='search']", query: "gpu") |> render_change()
    assert has_element?(view, ".issue-card-select", "Review GPU recovery")
    refute has_element?(view, ".issue-card-select", "Held work")
    refute has_element?(view, ".issue-card-select", "Private work")
    view |> form("form[phx-change='search']", query: "") |> render_change()
    view |> element("button[phx-value-filter='blocked']") |> render_click()
    assert has_element?(view, ".issue-card-select", "Review GPU recovery")
    refute has_element?(view, ".issue-card-select", "Held work")
    view |> element("button[phx-value-filter='all']") |> render_click()
    assert has_element?(view, ".issue-card-select", "Held work")
  end

  test "issue pins and reset change only the personal view" do
    put_board_blocked_issue()
    alpha = Project.via("alpha", :orchestrator)
    fields = [:running, :retry_attempts, :blocked, :polled_issues, :claimed]
    coordinator = Map.take(:sys.get_state(alpha), fields)
    governor_fields = [:slots, :busy, :projects, :reservation, :research_hold, :draining, :helpers]
    governor = Map.take(Governor.snapshot(), governor_fields)
    {:ok, view, _html} = live(build_conn(), "/?project=alpha")

    view |> element("button[aria-label='Pin MT-7 in your view']") |> render_click()
    assert_push_event(view, "board-pins", %{keys: [_key]})
    view |> element("button[phx-value-filter='pinned']") |> render_click()
    assert has_element?(view, ".issue-card-select", "Held work")
    refute has_element?(view, ".issue-card-select", "Review GPU recovery")
    assert has_element?(view, "button[aria-label='Unpin MT-7 in your view'][aria-pressed='true']")

    view |> element("button[phx-click='reset-view']") |> render_click()
    assert_push_event(view, "board-pins", %{keys: []})
    assert has_element?(view, "button[phx-value-filter='all'][aria-pressed='true']")
    assert has_element?(view, "button[aria-label='Pin MT-7 in your view'][aria-pressed='false']")
    assert has_element?(view, ".issue-card-select", "Review GPU recovery")
    assert Map.take(:sys.get_state(alpha), fields) == coordinator
    assert Map.take(Governor.snapshot(), governor_fields) == governor
  end

  test "UTC day changes retain unfinished work and history while rejecting invalid or future days" do
    table = :sys.get_state(Project.via("alpha", :orchestrator)).operations
    yesterday = Date.add(Date.utc_today(), -1) |> Date.to_iso8601()
    at = yesterday <> "T12:00:00Z"

    sequence =
      case :dets.lookup(table, :sequence) do
        [{:sequence, value}] -> value + 1
        _ -> 1
      end

    event = %{kind: "pr_merged", issue_identifier: "PR-77", pr_number: 77, summary: "Previously merged work", at: at}
    :ok = :dets.insert(table, [{:sequence, sequence}, {{:event, sequence}, event}])
    {:ok, view, _html} = live(build_conn(), "/?project=alpha")
    refute has_element?(view, ".issue-card-select", "Previously merged work")

    view |> form("form[phx-change='day']", date: yesterday) |> render_change()
    assert has_element?(view, ".issue-lane[aria-label='Done issues']", "Previously merged work")
    assert has_element?(view, ".issue-lane[aria-label='Intake issues']", "Held work")
    assert has_element?(view, ".board-day-note", "historical queue state is unavailable")
    assert has_element?(view, "#board-day[value='#{yesterday}']")

    render_change(view, "day", %{"date" => "not-a-day"})
    assert has_element?(view, ".board-day-note", "Choose a valid UTC day")
    future = Date.add(Date.utc_today(), 1) |> Date.to_iso8601()
    render_change(view, "day", %{"date" => future})
    assert has_element?(view, ".board-day-note", "Future days are unavailable")
    assert has_element?(view, "#board-day[value='#{yesterday}']")

    view |> element("button[phx-click='today']") |> render_click()
    refute has_element?(view, ".issue-card-select", "Previously merged work")
    assert has_element?(view, ".issue-card-select", "Held work")
    assert :dets.lookup(table, {:event, sequence}) == [{{:event, sequence}, event}]
  end

  test "project changes close selected details and clear an area that belongs to the previous project" do
    put_board_blocked_issue()
    alpha = Project.via("alpha", :orchestrator)

    :sys.replace_state(alpha, fn state ->
      issues =
        Enum.map(state.polled_issues, fn issue ->
          if issue.identifier == "MT-7", do: %{issue | labels: ["hold", "area:runtime"]}, else: issue
        end)

      # Work labels are exposed on active runs; admission queue rows do not project them.
      issue = Enum.find(issues, &(&1.identifier == "MT-7"))

      entry = %{
        identifier: issue.identifier,
        issue: issue,
        run_id: "alpha-area-run",
        session_id: nil,
        codex_app_server_pid: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        started_at: DateTime.utc_now(),
        last_codex_timestamp: nil,
        last_codex_message: nil,
        last_codex_event: nil
      }

      %{state | polled_issues: issues, running: %{issue.id => entry}}
    end)

    {:ok, view, _html} = live(build_conn(), "/?project=alpha")
    view |> form("form[phx-change='area']", area: "runtime") |> render_change()
    refute has_element?(view, ".issue-card-select", "Review GPU recovery")
    view |> element(".issue-card-select", "Held work") |> render_click()
    assert has_element?(view, "#issue-detail.is-open .issue-story-title", "Held work")

    render_patch(view, "/?project=beta")
    assert has_element?(view, ".issue-card-select", "Private work")
    refute has_element?(view, ".issue-card-select", "Held work")
    refute has_element?(view, "#issue-detail.is-open")
    render_patch(view, "/?project=alpha")
    assert has_element?(view, "#board-area option[value='all'][selected]")
    assert has_element?(view, ".issue-card-select", "Held work")
    assert has_element?(view, ".issue-card-select", "Review GPU recovery")
    refute has_element?(view, "#issue-detail.is-open")
  end

  test "issue board preserves private-project redaction through partial snapshots and recovery" do
    beta = Project.via("beta", :orchestrator)

    :sys.replace_state(beta, fn state ->
      [issue] = state.polled_issues
      issue = %{issue | title: "Beta confidential rollout"}

      entry = %{
        identifier: issue.identifier,
        issue: issue,
        run_id: "beta-secret-run",
        session_id: nil,
        codex_app_server_pid: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        started_at: DateTime.utc_now(),
        last_codex_timestamp: nil,
        last_codex_message: "beta-secret-summary",
        last_codex_event: nil
      }

      %{state | polled_issues: [issue], running: %{issue.id => entry}}
    end)

    table = :sys.get_state(beta).operations
    :ok = Operations.record_image(table, %{src: "/artifacts/beta-secret/image.png", issue_identifier: "MT-7"})
    :ok = Operations.event(table, "dispatch", %{issue_identifier: "MT-7", run_id: "beta-secret-run"})
    {:ok, view, html} = live(build_conn(), "/")
    assert has_element?(view, ".issue-card-select", "Private work")
    refute html =~ "Beta confidential rollout"
    refute html =~ "beta-secret"

    alpha = GenServer.whereis(Project.via("alpha", :orchestrator))
    :ok = :sys.suspend(alpha)

    try do
      send(view.pid, :observability_updated)
      wait_for(fn -> has_element?(view, ".board-day-note", "Snapshot incomplete") end)
      assert has_element?(view, ".board-day-note", "Counts are unknown")
      assert has_element?(view, ".issue-card-select", "Private work")
      refute has_element?(view, ".issue-card-select", "Held work")
      refute render(view) =~ "Beta confidential rollout"
      refute render(view) =~ "beta-secret"
    after
      :ok = :sys.resume(alpha)
    end

    send(view.pid, :observability_updated)
    wait_for(fn -> not has_element?(view, ".board-day-note", "Snapshot incomplete") end)
    assert has_element?(view, ".issue-card-select", "Held work")
    refute render(view) =~ "beta-secret"
  end

  test "the dashboard filters by project in the URL and names projects in mixed lists" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "project-filter"
    assert has_element?(view, ".issue-card-id span", "alpha")
    assert has_element?(view, ".issue-card-id span", "beta")

    # Filters combine in the URL: each link keeps the other filter.
    html = render_patch(view, "/?project=alpha&show=review")
    assert html =~ ~s(href="/?project=alpha")
    assert html =~ ~s(href="/?show=review")
    assert html =~ ~s(href="/?project=beta&amp;show=review")

    html = render_patch(view, "/?project=beta")
    assert html =~ ~s(class="project-pill is-active")
    assert has_element?(view, ".issue-card-id span", "beta")
    refute has_element?(view, ".issue-card-id span", "alpha")
    assert render_patch(view, "/?project=beta") =~ ~s(class="project-pill is-active")

    {:ok, _view, html} = live(build_conn(), "/agents/alpha/MT-7")
    assert html =~ "MT-7"
  end

  test "changing to an unavailable project clears the previous view and retries" do
    {:ok, view, html} = live(build_conn(), "/?project=alpha")
    assert html =~ "Held work"
    beta = GenServer.whereis(Project.via("beta", :orchestrator))
    :ok = :sys.suspend(beta)

    try do
      html = render_patch(view, "/?project=beta")
      assert html =~ "Snapshot incomplete"
      assert html =~ "beta: timeout"
      refute html =~ "Showing the last snapshot"
      refute html =~ "Held work"
    after
      :ok = :sys.resume(beta)
    end

    wait_for(fn -> not (render(view) =~ "Snapshot incomplete") end, 150)
    assert render(view) =~ "Private work"
    refute render(view) =~ "Held work"
  end

  test "a project that fails to start is flagged in the filter" do
    :persistent_term.put({Projects, :failures}, %{"beta" => "missing workflow"})
    on_exit(fn -> :persistent_term.put({Projects, :failures}, %{}) end)

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "is-failed"
    assert html =~ "missing workflow"
  end

  defp put_board_blocked_issue do
    issue = %Issue{
      id: "board-blocked",
      identifier: "MT-8",
      title: "Review GPU recovery",
      state: "In Progress",
      labels: ["hold", "area:product"],
      dispatchable: true
    }

    :sys.replace_state(Project.via("alpha", :orchestrator), fn state ->
      blocked = %{identifier: issue.identifier, issue: issue, error: "Waiting for validation evidence"}
      %{state | polled_issues: state.polled_issues ++ [issue], blocked: Map.put(state.blocked, issue.id, blocked)}
    end)
  end

  defp wait_for(check, attempts \\ 100) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && wait_for(check, attempts - 1)
    end
  end

  defp dispatch_detail(state),
    do: state["health"]["coordinator"]["checks"] |> Enum.find(&(&1["name"] == "Dispatch")) |> Map.fetch!("detail")

  defp healthy(state) do
    validator = Path.expand("../../../ops/bin/deploy-state.py", __DIR__)
    wrapper = "import subprocess, sys; sys.exit(subprocess.run(sys.argv[2:], input=sys.argv[1].encode()).returncode)"
    {_output, status} = System.cmd("python3", ["-c", wrapper, Jason.encode!(state), "python3", validator, "healthy"], stderr_to_stdout: true)
    status
  end
end
