defmodule SymphonyElixir.ServiceWebTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{Governor, Projects, Service}

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-service-web-#{System.unique_integer([:positive])}")

    for id <- ["alpha", "beta"] do
      dir = Path.join([root, "projects", id])
      File.mkdir_p!(dir)
      write_workflow_file!(Path.join(dir, "WORKFLOW.md"), tracker_kind: "memory", tracker_excluded_labels: ["hold"])
    end

    File.write!(Path.join(root, "crescendo.yml"), "paths: {state: state}\npool: {slots: 2}\nprojects: {alpha: {weight: 2}, beta: {redact: true}}")
    {:ok, service} = Service.load(Path.join(root, "crescendo.yml"))

    # A held issue shows in the queue without starting an agent.
    issue = %Issue{id: "issue-held", identifier: "MT-7", title: "Held work", state: "In Progress", labels: ["hold"], dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    previous = Service.current()
    :ok = Service.put_current(service)

    on_exit(fn ->
      :persistent_term.put({Service, :current}, previous)
      File.rm_rf(root)
    end)

    start_supervised!({Governor, service})
    start_supervised!({Projects, service})
    wait_for(fn -> Enum.all?(["alpha", "beta"], &GenServer.whereis(SymphonyElixir.Project.via(&1, :orchestrator))) end)

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), dashboard_reload_ms: 0)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    wait_for(fn -> length(json_response(get(build_conn(), "/api/v1/state"), 200)["upcoming"]["waiting"]) == 2 end)
    :ok
  end

  test "the state API merges every project and filters to one" do
    state = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state["project"] == nil
    assert [%{"id" => "alpha", "weight" => 2, "failure" => nil}, %{"id" => "beta"}] = state["projects"]
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

  test "the dashboard filters by project in the URL and names projects in mixed lists" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "project-filter"
    assert html =~ ~s(<span class="project-chip">alpha</span>)

    html = render_patch(view, "/?project=beta")
    assert html =~ ~s(class="project-pill is-active")
    refute html =~ ~s(<span class="project-chip">)
    assert render_patch(view, "/?project=beta") =~ ~s(class="project-pill is-active")

    {:ok, _view, html} = live(build_conn(), "/agents/alpha/MT-7")
    assert html =~ "MT-7"
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
end
