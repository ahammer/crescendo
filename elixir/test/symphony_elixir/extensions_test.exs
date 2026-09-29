defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issues_by_ids(issue_ids) do
      send(self(), {:fetch_issues_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Second prompt",
      poll_interval_ms: 45_000
    )

    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    good_settings = Config.settings!()
    assert good_settings.polling.interval_ms == 45_000

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    File.write!(
      Workflow.workflow_file_path(),
      "---\npolling:\n  interval_ms: nope\n---\nTyped-invalid prompt\n"
    )

    assert {:error, {:invalid_workflow_config, message}} = WorkflowStore.force_reload()
    assert message =~ "polling.interval_ms"
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()
    assert Config.settings!().polling.interval_ms == good_settings.polling.interval_ms
    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "token",
      tracker_project_slug: nil,
      prompt: "Semantic-invalid prompt"
    )

    assert {:error, :missing_linear_project_slug} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()
    assert Config.settings!().polling.interval_ms == good_settings.polling.interval_ms
    assert {:error, :missing_linear_project_slug} = Config.validate!()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert {:ok, settings} = WorkflowStore.settings()
    assert settings.polling.interval_ms == 30_000
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.settings()

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    assert :ok = GenServer.stop(manual_pid)

    Workflow.set_workflow_file_path(existing_path)

    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    assert :ok = WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_ids(["issue-1"])

    binding = SymphonyElixir.Tracker.bind_agent_tools()
    assert binding.adapter == Memory
    assert binding.tool_specs == []
    assert binding.secret_environment_names == []

    assert SymphonyElixir.Tracker.execute_bound_agent_tool(binding, "not_a_memory_tool", %{})[
             "success"
           ] == false

    assert {:error, {:unsupported_tracker_kind, "future-tracker"}} =
             SymphonyElixir.Tracker.adapter_for_kind("future-tracker")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
    assert SymphonyElixir.Tracker.bind_agent_tools().secret_environment_names == ["LINEAR_API_KEY"]
  end

  test "linear adapter delegates reads and advertises its native agent tool" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issues_by_ids(["issue-1"])
    assert_receive {:fetch_issues_by_ids_called, ["issue-1"]}

    assert [%{"name" => "linear_graphql"}] = Adapter.agent_tool_specs()
  end

  @empty_workspace %{
    "progress" => %{"done" => 0, "total" => 0},
    "plan" => [],
    "plan_explanation" => nil,
    "files" => [],
    "latest_image" => nil,
    "images" => 0,
    "entries" => 0,
    "now" => nil,
    "said" => nil
  }

  test "phoenix observability api preserves state and issue responses and serves no writes" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1, "blocked" => 1, "ready" => 0, "waiting" => 0, "open_prs" => 0},
             "running" => [
               %{
                 "project" => nil,
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "issue_url" => "https://example.org/issues/MT-HTTP",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "model" => nil,
                 "route" => nil,
                 "title" => nil,
                 "labels" => [],
                 "kind" => "issue",
                 "pull_request" => nil,
                 "research" => nil,
                 "attempt" => 0,
                 "item_attempt" => 1,
                 "final_attempt" => false,
                 "recent_events" => [],
                 "cost" => %{"run" => nil, "item" => nil},
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "cached_input_tokens" => 0, "output_tokens" => 8, "total_tokens" => 12},
                 "run_id" => nil,
                 "description" => nil,
                 "branch" => nil,
                 "workspace" => @empty_workspace
               }
             ],
             "retrying" => [
               %{
                 "project" => nil,
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "issue_url" => "https://example.org/issues/MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "blocked" => [
               %{
                 "project" => nil,
                 "issue_id" => "issue-blocked",
                 "issue_identifier" => "MT-BLOCKED",
                 "issue_url" => "https://example.org/issues/MT-BLOCKED",
                 "state" => "In Progress",
                 "error" => "codex turn requires operator input",
                 "worker_host" => "dm-dev2",
                 "workspace_path" => "/workspaces/MT-BLOCKED",
                 "session_id" => "thread-blocked",
                 "blocked_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("blocked_at"),
                 "last_event" => "turn_input_required",
                 "last_message" => "turn blocked: waiting for user input",
                 "last_event_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("last_event_at")
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}},
             "quota" => nil,
             "throttle" => nil,
             "usage" => %{
               "status" => "unavailable",
               "pricing_as_of" => "2026-09-24",
               "today" => %{"input_tokens" => 0, "cached_input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0, "usd_micro" => 0, "unpriced_tokens" => 0},
               "recorded" => %{"input_tokens" => 0, "cached_input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0, "usd_micro" => 0, "unpriced_tokens" => 0},
               "by_model" => [],
               "activity" => [],
               "daily" => state_payload["usage"]["daily"],
               "samples" => [],
               "median_run_seconds" => %{}
             },
             "usage_error" => nil,
             "upcoming" => %{"ready" => [], "waiting" => [], "observed_at" => nil, "error" => nil, "available_slots" => nil},
             "autopilot" => %{"enabled" => false},
             "polling" => nil,
             "runtime" => %{"tracker" => "linear:project", "max_turns" => 20},
             "pull_requests" => %{"items" => [], "observed_at" => nil, "error" => nil, "enabled" => false},
             "header" => %{
               "budget_usd_micro" => 50_000_000,
               "runs_today" => 0,
               "max_agents" => Config.settings!().agent.max_concurrent_agents,
               "queued" => 0,
               "longest" => %{"issue_identifier" => "MT-HTTP", "seconds" => 0, "model" => nil}
             },
             "history" => %{"running" => [], "ready" => [], "waiting" => [], "attention" => [], "open_prs" => [], "spend_micro" => []},
             "health" => state_payload["health"],
             "run_stats" => %{"total" => 0, "completed" => 0, "interrupted" => 0, "failed" => 0, "merged" => 0, "closed" => 0}
           }

    # Health reports only observed signals: a blocked and a retrying item
    # degrade the coordinator, and an unavailable usage store is critical.
    assert %{"status" => "degraded", "checks" => coordinator_checks} = state_payload["health"]["coordinator"]
    assert Enum.map(coordinator_checks, & &1["name"]) == ["Polling loop", "Dispatch", "Retries", "Research"]
    assert %{"status" => "warning", "detail" => "1 blocked · 1 retrying"} = Enum.find(coordinator_checks, &(&1["name"] == "Retries"))
    assert %{"status" => "down", "checks" => system_checks} = state_payload["health"]["system"]
    assert %{"status" => "critical"} = Enum.find(system_checks, &(&1["name"] == "Usage history"))
    refute Enum.any?(system_checks, &(&1["name"] in ["Tracker", "GitHub pull requests"]))

    assert length(state_payload["usage"]["daily"]) == 14
    assert List.last(state_payload["usage"]["daily"])["date"] == Date.utc_today() |> Date.to_iso8601()

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "model" => nil,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "blocked" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{},
             "transcript" => [],
             "workspace_summary" => @empty_workspace
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-BLOCKED")

    assert %{
             "status" => "blocked",
             "last_error" => "codex turn requires operator input",
             "blocked" => %{
               "session_id" => "thread-blocked",
               "state" => "In Progress",
               "error" => "codex turn requires operator input"
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    # The API is read-only: nothing reachable over HTTP changes state.
    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/metalrain/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ ~r|/dashboard\.css\?v=[0-9a-f]{12}|

    assert html =~
             ~r|<link rel="icon" type="image/png" sizes="128x128" href="/favicon\.png\?v=[0-9a-f]{12}">|

    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"
    assert dashboard_css =~ "text-decoration-thickness: 1px"

    favicon_conn = get(build_conn(), "/favicon.png")
    assert response(favicon_conn, 200) == File.read!("priv/static/favicon.png")
    assert Plug.Conn.get_resp_header(favicon_conn, "content-type") == ["image/png; charset=utf-8"]

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Crescendo"
    assert html =~ "MT-HTTP"
    assert html =~ ~s(href="/agents/MT-HTTP")
    assert html =~ "MT-RETRY"
    assert html =~ "MT-BLOCKED"
    assert html =~ ~s(href="https://example.org/issues/MT-RETRY")
    assert html =~ ~s(href="https://example.org/issues/MT-BLOCKED")
    assert html =~ ~s(aria-label="Open MT-RETRY in the issue tracker")
    assert html =~ "rendered"
    assert html =~ "turn blocked: waiting for user input"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Blocked"
    assert html =~ "Retry 2"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          issue_url: "javascript:alert('nope')",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)

    refute render(view) =~ "javascript:alert"
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "agent inspector shows the work item, route, costs, and recent activity" do
    orchestrator_name = Module.concat(__MODULE__, :AgentCardOrchestrator)
    now = DateTime.utc_now()

    agent = %{
      issue_id: "7",
      identifier: "PR-7",
      issue_url: "https://example.org/pull/7",
      state: "open",
      session_id: "thread-pr",
      turn_count: 3,
      codex_app_server_pid: nil,
      last_codex_message: "reviewing the diff",
      last_codex_timestamp: now,
      last_codex_event: :notification,
      codex_input_tokens: 40_000,
      codex_cached_input_tokens: 30_000,
      codex_output_tokens: 2_000,
      codex_total_tokens: 42_000,
      started_at: DateTime.add(now, -600, :second),
      workspace_path: "/home/me/workspaces/PR-7",
      model: "gpt-6-sol",
      route: %{model: "gpt-6-sol", effort: "medium", label: "default"},
      title: "Parallelize boundary exchange reduction",
      labels: ["performance", "symphony:ready"],
      kind: :pull_request,
      pull_request: %{author: "ahammer", author_association: "OWNER", head_ref: "symphony/issue-711", head_sha: "abcdef1234", ci_state: "success", can_push: true},
      research: nil,
      attempt: 0,
      item_attempt: 2,
      recent_events: [
        %{at: now, event: :notification, text: "reviewing the diff"},
        %{at: DateTime.add(now, -90, :second), event: :notification, text: "ran cargo xtask ci worker"}
      ],
      run_usage: %{usd_micro: 420_000, total_tokens: 42_000, unpriced_tokens: 0},
      item_usage: %{usd_micro: 3_250_000, total_tokens: 900_000, unpriced_tokens: 0, runs: 4, since: "2026-09-26"}
    }

    snapshot = %{static_snapshot() | running: [agent]}
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(href="/agents/PR-7")
    assert html =~ "Parallelize boundary exchange reduction"
    assert html =~ "Attempt 2"

    {:ok, _view, html} = live(build_conn(), "/agents/PR-7")

    for text <- [
          "Parallelize boundary exchange reduction",
          "by ahammer (owner)",
          "symphony/issue-711@abcdef1",
          "CI success",
          "Attempt 2",
          "performance",
          "$0.420",
          "$3.25",
          "4 runs since 2026-09-26",
          "medium effort",
          "via default",
          "cached 30.0K",
          "Codex update",
          "ran cargo xtask ci worker",
          "workspaces/PR-7",
          "Copy ID"
        ] do
      assert html =~ text
    end

    refute html =~ ~s(<li class="label-chip">symphony:ready</li>)
  end

  test "agent inspector JSON link follows its project when present" do
    orchestrator_name = Module.concat(__MODULE__, :ProjectInspectorOrchestrator)
    [base] = static_snapshot().running

    project_agent = Map.merge(base, %{identifier: "GH-1", project: "beta"})
    single_agent = Map.merge(base, %{identifier: "GH-2"})

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: %{static_snapshot() | running: [project_agent, single_agent]}
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, project_html} = live(build_conn(), "/agents/beta/GH-1")
    assert project_html =~ ~s(href="/api/v1/beta/GH-1")

    {:ok, _view, single_html} = live(build_conn(), "/agents/GH-2")
    assert single_html =~ ~s(href="/api/v1/GH-2")
  end

  test "dashboard HUD cards summarise each agent and open its inspector" do
    orchestrator_name = Module.concat(__MODULE__, :WorkspaceOrchestrator)
    at = DateTime.utc_now()
    note = fn method, params -> %{payload: %{"method" => method, "params" => params}, timestamp: at} end
    image = %{name: "1.png", src: "/artifacts/0123456789abcdef01234567/1.png"}

    transcript =
      [
        note.("item/completed", %{"item" => %{"id" => "m1", "type" => "agentMessage", "text" => "Reading the solver <script>x</script>"}}),
        note.("item/completed", %{"item" => %{"id" => "v1", "type" => "imageView", "path" => "/tmp/reference.png"}}),
        note.("turn/plan/updated", %{
          "plan" => [%{"step" => "Run the example", "status" => "completed"}, %{"step" => "Compare results", "status" => "inProgress"}, %{"step" => "Draft summary", "status" => "pending"}]
        }),
        note.("turn/diff/updated", %{"diff" => "diff --git a/src/a.rs b/src/a.rs\n+++ b/src/a.rs\n+new\n-old\n"}),
        note.("item/started", %{"item" => %{"id" => "c1", "type" => "commandExecution", "command" => "cargo test -p solver", "status" => "inProgress"}})
      ]
      |> Enum.reduce(SymphonyElixir.Transcript.new(), &SymphonyElixir.Transcript.apply(&2, &1, store_image: fn _source -> {:ok, image} end))

    review =
      SymphonyElixir.Transcript.apply(
        SymphonyElixir.Transcript.new(),
        note.("item/completed", %{"item" => %{"id" => "m2", "type" => "agentMessage", "text" => "Looks good to merge"}})
      )

    [base] = static_snapshot().running

    first =
      Map.merge(base, %{
        identifier: "GH-1",
        issue_id: "gh-1",
        title: "Solve the flow case",
        description: "## Problem\n\nRun the **example** end to end.<!-- symphony:marker --> See [the docs](https://example.org).",
        branch_name: "symphony/issue-1",
        transcript: transcript,
        run_id: "0123456789abcdef01234567"
      })

    second =
      Map.merge(base, %{
        identifier: "PR-2",
        issue_id: "pr-2",
        title: "Review buoyancy",
        kind: :pull_request,
        transcript: review
      })

    snapshot = %{static_snapshot() | running: [first, second]}
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")

    for text <- [
          ~s(href="/agents/GH-1"),
          ~s(href="/agents/PR-2"),
          "Solve the flow case",
          "1/3 steps",
          "Running cargo test -p solver",
          "“Reading the solver &lt;script&gt;x&lt;/script&gt;”",
          "Looks good to merge",
          ~s(class="card-thumb" src="/artifacts/0123456789abcdef01234567/1.png"),
          "+1",
          "−1",
          "project · Autopilot off"
        ] do
      assert html =~ text
    end

    # The HUD carries no transcript; the inspector loads one agent's.
    refute html =~ "Compare results"

    # Phones switch sections with tabs; the choice is only a class.
    view |> element(~s(button[phx-value-id="activity"])) |> render_click()
    assert has_element?(view, ~s(button.section-tab.is-active[phx-value-id="activity"]))
    assert has_element?(view, ~s(section.sec.is-active[aria-labelledby="activity-title"]))
    refute has_element?(view, ~s(section.sec.is-active[aria-labelledby="queue-title"]))

    {:ok, view, html} = live(build_conn(), "/agents/GH-1")

    for text <- ["Solve the flow case", "Problem Run the example end to end. See the docs.", "symphony/issue-1", "Compare results", "cargo test -p solver", "a.rs"] do
      assert html =~ text
    end

    assert html =~ ~s(<img src="/artifacts/0123456789abcdef01234567/1.png")
    assert html =~ "&lt;script&gt;x&lt;/script&gt;"
    assert html =~ ~s(href="/agents/PR-2")
    refute html =~ "Looks good to merge"

    view |> element(~s(button[phx-value-id="plan"])) |> render_click()
    assert has_element?(view, ~s(section.pane.is-active[aria-labelledby="plan-title"]))
    refute has_element?(view, "section.pane-chat.is-active")

    {:ok, _view, html} = live(build_conn(), "/agents/PR-2")
    assert html =~ "Looks good to merge"
    refute html =~ "cargo test -p solver"
  end

  test "agent inspector keeps an ended run on screen and explains missing ones" do
    orchestrator_name = Module.concat(__MODULE__, :EndedOrchestrator)
    snapshot = static_snapshot()
    {:ok, orchestrator_pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/agents/MT-HTTP")
    assert html =~ "rendered"
    refute html =~ "This run has ended"

    :sys.replace_state(orchestrator_pid, fn state -> Keyword.put(state, :snapshot, %{snapshot | running: []}) end)
    StatusDashboard.notify_update()

    assert_eventually(fn -> render(view) =~ "This run has ended" end)
    assert render(view) =~ "rendered"

    {:ok, _view, html} = live(build_conn(), "/agents/GH-404")
    assert html =~ "GH-404 is not running"
    assert html =~ ~s(href="/")
  end

  test "agent inspector reports an unavailable snapshot" do
    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :MissingInspectorOrchestrator), snapshot_timeout_ms: 5)

    {:ok, _view, html} = live(build_conn(), "/agents/MT-HTTP")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "live pages coalesce bursts of updates into one reload" do
    orchestrator_name = Module.concat(__MODULE__, :BurstOrchestrator)
    snapshot = static_snapshot()
    {:ok, orchestrator_pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50, dashboard_reload_ms: 150)

    {:ok, view, _html} = live(build_conn(), "/")
    [entry] = snapshot.running
    :sys.replace_state(orchestrator_pid, fn state -> Keyword.put(state, :snapshot, %{snapshot | running: [%{entry | last_codex_message: "second update"}]}) end)

    # Inside the reload window the first update waits and the second joins it.
    send(view.pid, :observability_updated)
    send(view.pid, :observability_updated)
    refute render(view) =~ "second update"
    assert_eventually(fn -> render(view) =~ "second update" end)

    send(view.pid, :runtime_tick)
    send(view.pid, :unrelated_message)
    assert render(view) =~ "second update"
  end

  test "dashboard header, queue estimates and health follow the snapshot and settings" do
    write_workflow_file!(Workflow.workflow_file_path(), observability_daily_budget_usd: 10, max_concurrent_agents: 2)
    orchestrator_name = Module.concat(__MODULE__, :QueueOrchestrator)
    usage = SymphonyElixir.Operations.snapshot(nil)
    today = usage.daily |> List.last() |> Map.merge(%{merged: 2, closed: 1, spend_by_model: %{"gpt-6-sol" => 1_500_000}})

    usage = %{
      usage
      | status: "ok",
        today: %{usage.today | usd_micro: 12_000_000},
        median_run_seconds: %{"issue" => 600, "pull_request" => 300},
        daily: List.replace_at(usage.daily, -1, today),
        by_model: [%{model: "gpt-6-sol", total_tokens: 1_000, usd_micro: 1_500_000, unpriced_tokens: 0, runs: 1}]
    }

    ready =
      for {identifier, title} <- [{"GH-10", "First ready"}, {"GH-11", "Second ready"}, {"PR-12", "Third ready"}] do
        %{issue_identifier: identifier, title: title, issue_url: nil, priority: 2, reason: nil, blocked_by: []}
      end

    upcoming = %{
      ready: ready,
      waiting: [%{issue_identifier: "GH-13", title: "Blocked one", issue_url: nil, priority: 2, reason: "dependency blocked", blocked_by: ["GH-10"]}],
      observed_at: DateTime.utc_now(),
      error: nil,
      available_slots: 1
    }

    quota =
      SymphonyElixir.Quota.normalize(
        %{"limitId" => "codex", "planType" => "pro", "primary" => %{"usedPercent" => 75, "windowDurationMins" => 10_080, "resetsAt" => 1_900_000_000}},
        DateTime.utc_now()
      )

    snapshot =
      static_snapshot()
      |> Map.put(:operations, usage)
      |> Map.put(:upcoming, upcoming)
      |> Map.put(:blocked, [])
      |> Map.put(:quota, quota)

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    # Two slots: the first two issues finish in one median run, the review in the second wave.
    assert html =~ ~r/First ready.*?~10m/s
    assert html =~ ~r/Second ready.*?~10m/s
    assert html =~ ~r/Third ready.*?~10m/s
    assert html =~ "Blocked"
    assert html =~ ~s(title="dependency blocked: GH-10")
    assert html =~ "1/2 running"
    assert html =~ ~r/PRs closed today.*?3.*?2 merged · 1 closed/s
    assert html =~ ~r/class="spend-table".*?gpt-6-sol.*?\$1\.50.*?\$1\.50/s
    assert html =~ ~r/Free slot.*?Next up.*?GH-10.*?First ready/s
    assert html =~ "over $10.00 budget"
    assert html =~ "Worker usage alert"
    assert html =~ "1/2"
    assert html =~ "Coordinator"
    assert html =~ "1 retrying automatically"
    assert html =~ "Systems"
    assert html =~ "Tokens today"
    assert html =~ "Weekly quota"
    assert html =~ "Weekly quota 25% left"

    payload = SymphonyElixirWeb.Presenter.state_payload(orchestrator_name, 50)
    assert [%{eta_seconds: 600}, %{eta_seconds: 600}, %{eta_seconds: 600}] = payload.upcoming.ready
    assert payload.header.budget_usd_micro == 10_000_000
    assert payload.header.max_agents == 2
  end

  test "artifact route serves stored run images and nothing else" do
    root = Path.join(System.tmp_dir!(), "symphony-artifact-route-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    run_id = "0123456789abcdef01234567"
    png = <<0x89, "PNG", 13, 10, 26, 10, 0, 0>>
    {:ok, %{src: src}} = SymphonyElixir.Artifacts.store(run_id, {:base64, Base.encode64(png), "image/png"}, root)
    File.write!(Path.join(root, "secret.txt"), "secret")

    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :ArtifactOrchestrator), snapshot_timeout_ms: 5, artifacts_root: root)

    conn = get(build_conn(), src)
    assert response(conn, 200) == png
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["image/png"]
    assert [cache_control] = Plug.Conn.get_resp_header(conn, "cache-control")
    assert cache_control =~ "immutable"

    for path <- ["/artifacts/#{run_id}/2.png", "/artifacts/#{run_id}/..%2Fsecret.txt", "/artifacts/../secret.txt", "/artifacts/#{run_id}/1.svg", "/artifacts/nope/1.png"] do
      assert get(build_conn(), path).status == 404
    end
  end

  test "dashboard warns at the daily worker estimate threshold" do
    orchestrator_name = Module.concat(__MODULE__, :SpendAlertOrchestrator)
    usage = SymphonyElixir.Operations.snapshot(nil)
    usage = %{usage | status: "ok", today: %{usage.today | usd_micro: 49_999_999}}
    snapshot = Map.put(static_snapshot(), :operations, usage)
    {:ok, orchestrator_pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    refute html =~ "Worker usage alert"

    updated_usage = %{usage | today: %{usage.today | usd_micro: 50_000_000}}

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, %{snapshot | operations: updated_usage})
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn -> render(view) =~ "Worker usage alert" end)
    assert render(view) =~ "Planning and independent review usage are not included"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1, "blocked" => 1, "ready" => 0, "waiting" => 0, "open_prs" => 0}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 405

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), dashboard_reload_ms: 0)
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          issue_url: "https://example.org/issues/MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          issue_url: "https://example.org/issues/MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      blocked: [
        %{
          issue_id: "issue-blocked",
          identifier: "MT-BLOCKED",
          issue_url: "https://example.org/issues/MT-BLOCKED",
          state: "In Progress",
          error: "codex turn requires operator input",
          worker_host: "dm-dev2",
          workspace_path: "/workspaces/MT-BLOCKED",
          session_id: "thread-blocked",
          blocked_at: DateTime.utc_now(),
          last_codex_event: :turn_input_required,
          last_codex_message: %{
            event: :turn_input_required,
            message: %{"method" => "turn/input_required"},
            timestamp: DateTime.utc_now()
          },
          last_codex_timestamp: DateTime.utc_now()
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
