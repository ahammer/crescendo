defmodule SymphonyElixir.ServiceWebTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{Governor, Operations, Project, Projects, Service, SourceRevision}

  defmodule PollTracker do
    def fetch_issues_by_states(_states), do: {:error, :offline_tracker}
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
    assert dispatch_detail(state) =~ "Deployment drain holds new runs"
    assert {:wait, "draining for a deploy"} = Governor.acquire("alpha", "next-slot", :issue)
    File.rm!(drain)
    assert json_response(get(build_conn(), "/api/v1/state"), 200)["throttle"]["draining"] == false
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

      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ "Snapshot incomplete"
      assert html =~ "beta: timeout"
      assert html =~ "—/2"
      assert html =~ "Queue unknown."
      assert html =~ "Running work unknown."
      refute html =~ "Free slot"
      refute html =~ "No agent is running."
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

  test "the dashboard filters by project in the URL and names projects in mixed lists" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "project-filter"
    assert html =~ ~s(<span class="project-chip">alpha</span>)

    # Filters combine in the URL: each link keeps the other filter.
    html = render_patch(view, "/?project=alpha&show=review")
    assert html =~ ~s(href="/?project=alpha")
    assert html =~ ~s(href="/?show=review")
    assert html =~ ~s(href="/?project=beta&amp;show=review")

    html = render_patch(view, "/?project=beta")
    assert html =~ ~s(class="project-pill is-active")
    refute html =~ ~s(<span class="project-chip">)
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
