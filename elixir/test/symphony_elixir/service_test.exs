defmodule SymphonyElixir.ServiceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Project, Projects, Service}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-service-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp write_project!(root, id, overrides) do
    dir = Path.join([root, "projects", id])
    File.mkdir_p!(dir)
    write_workflow_file!(Path.join(dir, "WORKFLOW.md"), [tracker_kind: "memory"] ++ overrides)
  end

  test "a service file names projects that share slots, budget and defaults", %{root: root} do
    path = Path.join(root, "crescendo.yml")

    File.write!(path, """
    server: {host: 0.0.0.0, port: 4280}
    paths: {state: state}
    pool: {slots: 4}
    throttle: {daily_budget_usd: 200}
    pricing: {models: {gpt-7: {input: 1, cached_input: 0.1, output: 4}}}
    defaults: {agent: {max_turns: 7}}
    projects:
      metalrain: {weight: 3, research_exclusive: global}
      nubu3d: {workflow: elsewhere/WORKFLOW.md, cap: 1}
      shimmer: {enabled: false}
      dartboard:
    """)

    assert {:ok, service} = Service.load(path)
    assert %{host: "0.0.0.0", port: 4280, slots: 4, state_root: state_root} = service
    assert state_root == Path.join(root, "state")
    assert Service.state_root(service) == state_root
    assert service.throttle.daily_budget_usd == 200.0

    assert [dartboard, metalrain, nubu3d] = Service.projects(service)
    assert %{id: "dartboard", weight: 1, cap: nil, research_exclusive: "project"} = dartboard
    assert dartboard.workflow == Path.join([root, "projects", "dartboard", "WORKFLOW.md"])
    assert %{weight: 3, research_exclusive: "global"} = metalrain
    assert %{cap: 1, workflow: workflow} = nubu3d
    assert workflow == Path.join([root, "elsewhere", "WORKFLOW.md"])

    # Service pricing reaches every project through its defaults.
    assert metalrain.defaults == %{"agent" => %{"max_turns" => 7}, "pricing" => %{"models" => %{"gpt-7" => %{"input" => 1, "cached_input" => 0.1, "output" => 4}}}}
    assert Service.state_root(%Service{}) == Path.expand("~/.local/state/crescendo")

    previous = Service.current()
    on_exit(fn -> :persistent_term.put({Service, :current}, previous) end)
    assert :ok = Service.put_current(service)
    assert Service.current() == service
  end

  test "service files are validated", %{root: root} do
    for {yaml, message} <- [
          {"projects: {}", "projects must name at least one project"},
          {"projects: {Bad_Id: {}}", "projects ids must be"},
          {"projects: {a: {weight: 0}}", "projects ids must be"},
          {"projects: {a: {research_exclusive: sometimes}}", "projects ids must be"},
          {"projects: {a: {colour: red}}", "projects ids must be"},
          {"projects: {a: 3}", "projects ids must be"},
          {"pool: {slots: 0}\nprojects: {a: {}}", "slots must be greater than 0"},
          {"throttle: {daily_budget_usd: -1}\nprojects: {a: {}}", "throttle.daily_budget_usd"},
          {"- a list", "must be a map"},
          {"projects: {a: [}", "cannot parse"}
        ] do
      path = Path.join(root, "crescendo.yml")
      File.write!(path, yaml)
      assert {:error, error} = Service.load(path)
      assert error =~ message
    end

    assert {:error, "cannot read " <> _} = Service.load(Path.join(root, "missing.yml"))
  end

  test "projects run side by side, each reading its own configuration", %{root: root} do
    write_project!(root, "alpha", max_concurrent_agents: 2)
    write_project!(root, "beta", max_concurrent_agents: 5, max_turns: 3)
    File.write!(Path.join(root, "crescendo.yml"), "defaults: {agent: {max_turns: 7}}\nprojects: {alpha: {}, beta: {}, broken: {}}")
    {:ok, service} = Service.load(Path.join(root, "crescendo.yml"))
    service = %{service | state_root: Path.join(root, "state")}

    start_supervised!({Projects, service})
    assert_eventually(fn -> Map.has_key?(Projects.failures(), "broken") end)

    settings = fn id -> Project.with_project(id, fn -> Config.settings!().agent end) end
    assert %{max_concurrent_agents: 2, max_turns: 20} = settings.("alpha")
    assert %{max_concurrent_agents: 5, max_turns: 3} = settings.("beta")

    # Tasks inherit the project of the process that started them.
    assert Project.with_project("alpha", fn -> Task.async(fn -> Config.settings!().agent.max_concurrent_agents end) |> Task.await() end) == 2

    assert %{running: []} = Orchestrator.snapshot(Project.via("beta", :orchestrator), 5_000)
    assert File.exists?(Path.join([root, "state", "projects", "alpha", "operations.dets"]))

    alias SymphonyElixir.WorkflowStore

    for call <- [&WorkflowStore.settings/0, &WorkflowStore.current/0, &WorkflowStore.force_reload/0] do
      assert Project.with_project("broken", call) == {:error, {:project_not_running, "broken"}}
    end

    assert Project.current() == nil
  end

  test "service defaults fill in what a project leaves out", %{root: root} do
    dir = Path.join([root, "projects", "gamma"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "WORKFLOW.md"), "---\ntracker: {kind: memory}\nagent: {max_turns: 4}\n---\nWork on {{ issue.identifier }}.\n")
    File.write!(Path.join(root, "crescendo.yml"), "defaults: {agent: {max_turns: 9, max_concurrent_agents: 6}}\nprojects: {gamma: {}}")
    {:ok, service} = Service.load(Path.join(root, "crescendo.yml"))
    start_supervised!({Projects, %{service | state_root: Path.join(root, "state")}})

    assert_eventually(fn -> GenServer.whereis(Project.via("gamma", :orchestrator)) != nil end)
    assert %{max_turns: 4, max_concurrent_agents: 6} = Project.with_project("gamma", fn -> Config.settings!().agent end)
  end

  test "a task inherits its starter's project, and only live, real callers count" do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

    task =
      Task.async(fn ->
        Process.put(:"$callers", [:not_a_pid, dead | Process.get(:"$callers")])
        Project.current()
      end)

    assert Task.await(task) == nil
    assert Project.with_project("delta", fn -> Task.async(fn -> Project.current() end) |> Task.await() end) == "delta"
    assert Project.with_project("delta", fn -> Project.name(:orchestrator, :legacy) end) == Project.via("delta", :orchestrator)
    assert Project.name(:orchestrator, :legacy) == :legacy
    assert Project.registry() == SymphonyElixir.ProjectRegistry
  end

  defp assert_eventually(check, attempts \\ 50) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && assert_eventually(check, attempts - 1)
    end
  end
end
