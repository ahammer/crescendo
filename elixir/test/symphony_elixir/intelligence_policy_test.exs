defmodule SymphonyElixir.IntelligencePolicyTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{IntelligencePolicy, ModelRouting, Operations, Service}
  alias SymphonyElixir.Tracker.Issue

  setup do
    root = Path.join(System.tmp_dir!(), "gain-test-#{System.unique_integer([:positive])}")
    previous = Service.current()
    service = %Service{state_root: root, intelligence_policy: %{"enabled" => true}}
    Service.put_current(service)

    on_exit(fn ->
      :persistent_term.put({Service, :current}, previous)
      File.rm_rf!(root)
    end)

    %{service: service, root: root}
  end

  defp profile(complexity, risk \\ "normal"), do: %{"complexity" => complexity, "risk" => risk, "reason" => "Observed task contracts", "evidence_refs" => ["source:12"]}
  defp route(profile, role, key, gain, opts \\ []), do: ModelRouting.gain_route(profile, role, key, %{gain: gain, revision: "test", error: nil}, opts)

  test "absolute model endpoints include every role, complexity, risk and promotion" do
    for role <- ~w(delivery helper classifier reviewer scorecard planner), complexity <- ~w(routine standard complex exceptional), risk <- ~w(low normal high) do
      p = profile(complexity, risk)
      evidence = %{"kind" => "insufficient_model", "reason" => "Independent finding", "evidence_refs" => ["review:1"], "model_steps" => 3}
      assert {:ok, %{"model" => "gpt-6-luna"}} = route(p, role, "id", 0, smartass: true, feedback: evidence)
      assert {:ok, %{"model" => "gpt-6-astra"}} = route(p, role, "id", 2, smartass: true)
      assert {:ok, %{"model" => "gpt-6.1-sol", "requested_model" => "gpt-6-astra", "cap_reason" => "smartass_off"}} = route(p, role, "id", 2)
    end
  end

  test "one is Terra for ordinary work, low reasoning stays bounded" do
    assert {:ok, %{"model" => "gpt-6.1-terra", "effort" => "medium"}} = route(profile("standard"), "delivery", 1, 1)
    assert {:ok, %{"model" => "gpt-6.1-terra", "effort" => "low"}} = route(profile("standard", "low"), "classifier", 1, 1)
    assert {:ok, %{"model" => "gpt-6-luna", "effort" => "low"}} = route(profile("routine", "low"), "helper", 1, 1)
    assert {:ok, %{"model" => "gpt-6.1-terra", "effort" => "medium"}} = route(profile("routine", "high"), "delivery", 1, 1)
    assert {:ok, %{"model" => "gpt-6-luna", "effort" => "medium"}} = route(profile("exceptional", "high"), "reviewer", 1, 0)

    for g <- [0, 0.75, 1, 1.5, 2], c <- ~w(routine standard) do
      {:ok, r} = route(profile(c), "delivery", c, g, smartass: true)
      assert r["effort"] in ~w(low medium)
    end
  end

  test "fractional gain is reproducible, gradual, and monotone for each task" do
    models = ~w(gpt-6-luna gpt-6.1-terra gpt-6.1-sol gpt-6-astra)

    selected =
      for id <- 1..2000 do
        assert {:ok, same} = route(profile("standard"), "delivery", id, 0.75)
        assert {:ok, ^same} = route(profile("standard"), "delivery", id, 0.75)

        ranks =
          for g <- [0, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2] do
            {:ok, r} = route(profile("standard"), "delivery", id, g, smartass: true)
            Enum.find_index(models, &(&1 == r["model"]))
          end

        assert ranks == Enum.sort(ranks)
        same["model"]
      end

    fraction = Enum.count(selected, &(&1 == "gpt-6-luna")) / length(selected)
    assert fraction > 0.21 and fraction < 0.29
  end

  test "infrastructure feedback does not promote and capability feedback does" do
    base = profile("standard")
    {:ok, original} = route(base, "delivery", 1, 1)

    for kind <- ~w(lease_wait provider_error stale_fixture build_failure unknown) do
      assert {:ok, ^original} = route(base, "delivery", 1, 1, feedback: %{"kind" => kind, "reason" => "failure", "evidence_refs" => ["log"]})
    end

    assert {:ok, %{"model" => "gpt-6.1-sol", "effort" => "medium"}} =
             route(base, "delivery", 1, 1, feedback: %{"kind" => "insufficient_model", "reason" => "Repeated logic failure", "evidence_refs" => ["review:2"]})

    assert {:error, _} = route(base, "delivery", 1, -1)
    assert {:error, _} = route(base, "delivery", 1, 3)
    assert {:error, _} = route(%{}, "delivery", 1, 1)
  end

  test "gain persistence is atomic, validates input and keeps permissions separate", %{service: service, root: root} do
    assert IntelligencePolicy.status().gain == 1
    assert {:ok, state} = IntelligencePolicy.set(service, %{"gain" => 0.75})
    assert state.gain == 0.75 and state.revision != "default"

    for args <- [%{}, %{"gain" => true}, %{"gain" => "1"}, %{"gain" => -1}, %{"gain" => 2.1}, %{"gain" => 1, "enabled" => true}] do
      assert {:error, _} = IntelligencePolicy.set(service, args)
    end

    refute File.exists?(Path.join(root, "smartass-mode.json"))
    File.write!(Path.join(root, "intelligence-policy.json"), "broken")
    assert IntelligencePolicy.status().error != nil
    assert {:error, _} = IntelligencePolicy.resolve(profile("standard"), "delivery", 1)
    assert {:ok, _} = IntelligencePolicy.set(service, %{"gain" => 1})
    assert :ok = IntelligencePolicy.admit_native(nil)
  end

  test "classification is cached across gain changes, with failures deferred", %{root: root} do
    issue = %SymphonyElixir.Tracker.Issue{id: "cached", identifier: "GH-1", title: "One task", description: "Keep acceptance"}
    assert {:ok, first} = Operations.routing_profile(issue, fn -> {:ok, profile("standard")} end)
    IntelligencePolicy.set(Service.current(), %{"gain" => 0})
    assert {:ok, ^first} = Operations.routing_profile(issue, fn -> flunk("classification repeated") end)
    bad = %{issue | id: "failure"}
    assert {:error, :provider_error} = Operations.routing_profile(bad, fn -> {:error, :provider_error} end)
    assert {:error, :classification_deferred} = Operations.routing_profile(bad, fn -> flunk("failure repurchased") end)
    assert File.dir?(Path.join(root, "routing-profiles"))
  end

  test "dispatch uses profiles and holds the selected model rather than changing price tiers" do
    issue = %Issue{id: "dispatch", identifier: "GH-5", title: "Task", labels: ["symphony:complexity:standard", "symphony:risk:normal"]}

    for {kind, role} <- [{:issue, "delivery"}, {:research, "scorecard"}, {:pull_request, "reviewer"}] do
      candidate = %{issue | kind: kind}
      assert {:ok, selected} = ModelRouting.select_for_run(nil, %{}, candidate, 99)
      assert %{"role" => ^role, "model" => "gpt-6.1-terra"} = selected
      refute selected["needs_classification"]
      assert Jason.decode!(Jason.encode!(selected))["identity"] == selected["identity"]
      assert {:wait, "quota"} = ModelRouting.select_for_run(nil, %{}, %{issue | kind: kind}, 1, avoid: %{"gpt-6.1-terra" => "quota"})
    end

    for kind <- [:issue, :pull_request] do
      candidate = %{issue | kind: kind, labels: []}
      assert {:ok, selected} = ModelRouting.select_for_run(nil, %{}, candidate, 1)
      assert %{"role" => "classifier", "needs_classification" => true} = selected
    end

    assert IntelligencePolicy.profile(%{issue | labels: ["crescendo:complexity:complex", "crescendo:risk:high"]}) == nil
    assert {:error, _} = IntelligencePolicy.resolve(%{}, "helper", "id")
    assert IntelligencePolicy.role_profile("helper")["complexity"] == "routine"
    assert IntelligencePolicy.role_profile("classifier")["risk"] == "low"
    assert {:ok, _} = ModelRouting.gain_route(profile("standard"), "delivery", "default", %{gain: 1, revision: "default"})
  end

  test "scorecard reuses grounded task complexity and reclassifies a changed contract" do
    prompt = Path.join(Path.dirname(Workflow.workflow_file_path()), "research.md")
    File.write!(prompt, "Assess all eleven dimensions and publish a dependency-safe batch")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      autopilot: %{
        enabled: true,
        channels: %{"scorecard" => "Assess production owners"},
        prompts: %{research: "research.md", pull_request: "research.md"}
      }
    )

    issue = Enum.find(SymphonyElixir.Autopilot.research_items(Config.settings!().autopilot), &(&1.research.channel == "scorecard"))
    assert issue.description == nil
    assert IntelligencePolicy.task_contract(issue) =~ "Assess all eleven dimensions"

    assert {:ok, %{"needs_classification" => true}} = ModelRouting.select_for_run(nil, %{}, issue, 1)
    assert {:ok, classified} = Operations.routing_profile(issue, fn -> {:ok, profile("complex", "high")} end)
    assert {:ok, selected} = ModelRouting.select_for_run(nil, %{}, issue, 1)
    assert selected["role"] == "scorecard"
    assert selected["model"] == "gpt-6.1-sol"
    assert selected["effort"] == "high"
    assert selected["profile"] == classified
    refute selected["needs_classification"]
    assert {:ok, ^classified} = Operations.routing_profile(issue, fn -> flunk("scorecard classification repeated") end)
    File.write!(prompt, "A different assessment contract")
    assert :ok = WorkflowStore.force_reload()
    assert IntelligencePolicy.task_contract(issue) =~ "A different assessment contract"
    assert {:ok, %{"needs_classification" => true}} = ModelRouting.select_for_run(nil, %{}, issue, 1)
    File.write!(prompt, "{{ missing_task_variable }}")
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, %{"needs_classification" => true}} = ModelRouting.select_for_run(nil, %{}, issue, 1)
  end

  test "unreadable state and unsupported native capabilities fail closed", %{root: root} do
    File.mkdir_p!(Path.join(root, "intelligence-policy.json"))
    assert IntelligencePolicy.status().error =~ "unreadable"
    File.rm_rf!(Path.join(root, "intelligence-policy.json"))
    previous = System.get_env("CODEX_HOME")
    System.put_env("CODEX_HOME", root)
    on_exit(fn -> restore_env("CODEX_HOME", previous) end)
    route = %{"policy" => %{}, "model" => "gpt-6-luna", "effort" => "low"}
    assert {:error, :unsupported_intelligence_route} = IntelligencePolicy.admit_native(route)
    File.write!(Path.join(root, "models_cache.json"), "broken")
    assert {:error, :unsupported_intelligence_route} = IntelligencePolicy.admit_native(route)
    File.write!(Path.join(root, "models_cache.json"), Jason.encode!(%{"models" => [%{"slug" => "gpt-6-luna", "supported_reasoning_levels" => [%{"effort" => "low"}]}]}))
    assert :ok = IntelligencePolicy.admit_native(route)
    assert {:error, :unsupported_intelligence_route} = IntelligencePolicy.admit_native(%{route | "effort" => "max"})
    assert {:error, :unsupported_intelligence_route} = IntelligencePolicy.admit_native(%{route | "model" => "gpt-6-astra"})
  end

  test "quota admission preserves holds during a governor shutdown" do
    pid = spawn(fn -> receive do: ({:"$gen_call", _, :snapshot} -> :ok) end)
    Process.register(pid, SymphonyElixir.Governor)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert {:error, :quota_unknown} = IntelligencePolicy.admit_native(%{"policy" => %{}, "model" => "gpt-6-luna", "effort" => "low"})
  end
end
