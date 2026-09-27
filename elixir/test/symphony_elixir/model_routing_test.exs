defmodule SymphonyElixir.ModelRoutingTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Config.Schema, ModelRouting}
  alias SymphonyElixir.Tracker.Issue

  @routing %{
    "label_prefix" => "symphony:model:",
    "default" => %{"model" => "gpt-6-sol", "effort" => "medium"},
    "labels" => %{
      "symphony:model:luna" => %{"model" => "gpt-6-luna", "effort" => "medium"},
      "symphony:model:astra" => %{"model" => "gpt-6-astra", "effort" => "high"}
    }
  }

  @sol_medium %{"model" => "gpt-6-sol", "effort" => "medium"}
  @sol_xhigh %{"model" => "gpt-6-sol", "effort" => "xhigh"}
  @astra_medium %{"model" => "gpt-6-astra", "effort" => "medium"}
  @astra_max %{"model" => "gpt-6-astra", "effort" => "max"}

  @ladder_routing %{
    "label_prefix" => "symphony:model:",
    "ladder" => [@sol_medium, @sol_xhigh, @astra_medium, @astra_max],
    "escalation" => [0, 1, 3],
    "default" => @sol_medium,
    "labels" => %{"symphony:model:sol" => @sol_medium, "symphony:model:astra" => @astra_medium}
  }

  test "explicit routes, default, and fail-closed labels" do
    assert :ok = ModelRouting.validate(@routing)

    assert {:ok, %{"model" => "gpt-6-sol", "label" => "default"}} =
             ModelRouting.select(@routing, %Issue{labels: ["priority:p0"]})

    assert {:ok, %{"model" => "gpt-6-luna", "label" => "symphony:model:luna"}} =
             ModelRouting.select(@routing, %Issue{labels: ["Symphony:Model:Luna"]})

    assert {:error, "unknown model route label symphony:model:other"} =
             ModelRouting.select(@routing, %Issue{labels: ["symphony:model:other"]})

    assert {:error, "conflicting model route labels: " <> _} =
             ModelRouting.select(@routing, %Issue{labels: ["symphony:model:luna", "symphony:model:astra"]})

    assert {:ok, nil} = ModelRouting.select(nil, %Issue{labels: ["symphony:model:other"]})
  end

  test "invalid configured route is rejected" do
    assert {:error, _} = ModelRouting.validate(Map.put(@routing, "label_prefix", " "))
    assert {:error, _} = ModelRouting.validate(put_in(@routing, ["default", "effort"], "extreme"))
    assert {:error, _} = ModelRouting.validate(Map.put(@routing, "default", %{}))
    assert {:error, _} = ModelRouting.validate(put_in(@routing, ["labels", "other"], %{"model" => "x", "effort" => "high"}))
    assert {:error, _} = ModelRouting.validate(%{})
    assert {:error, _} = Schema.parse(%{"codex" => %{"routing" => %{}}})
    assert {:ok, _} = Schema.parse(%{"codex" => %{"routing" => @routing}})
  end

  test "research and review runs use their fixed routes; other runs route by label" do
    routing = %{
      "label_prefix" => "symphony:model:",
      "default" => %{"model" => "luna", "effort" => "medium"},
      "labels" => %{"symphony:model:sol" => %{"model" => "sol", "effort" => "high"}}
    }

    research_route = %{"model" => "astra", "effort" => "xhigh"}
    review_route = %{"model" => "astra", "effort" => "medium"}
    fixed = %{research: research_route, pull_request: review_route}
    research = %Issue{kind: :research, labels: ["symphony:model:sol"]}
    pull = %Issue{kind: :pull_request, labels: ["symphony:model:sol"]}
    issue = %Issue{kind: :issue, labels: ["symphony:model:sol"]}

    assert {:ok, %{"model" => "astra", "effort" => "xhigh", "label" => "research"}} = ModelRouting.select_for_run(routing, fixed, research, 1)
    assert {:ok, %{"model" => "astra", "effort" => "medium", "label" => "review"}} = ModelRouting.select_for_run(routing, fixed, pull, 3)
    assert {:ok, %{"model" => "sol", "label" => "symphony:model:sol"}} = ModelRouting.select_for_run(routing, fixed, issue, 1)

    assert {:ok, %{"model" => "luna", "label" => "default"}} =
             ModelRouting.select_for_run(routing, %{research: nil}, %{research | labels: ["symphony:research"]}, 1)

    assert :ok = ModelRouting.validate_route(research_route)
    assert :ok = ModelRouting.validate_route(%{"model" => "gpt-6-luna", "effort" => "max"})
    assert {:error, _} = ModelRouting.validate_route(%{"model" => "astra", "effort" => "extreme"})
    assert {:ok, _} = Schema.parse(%{"autopilot" => %{"review_route" => review_route}})
    assert {:error, _} = Schema.parse(%{"autopilot" => %{"review_route" => %{"model" => "astra"}}})
  end

  test "failed attempts climb the ladder from the starting route and cap at the strongest step" do
    assert :ok = ModelRouting.validate(@ladder_routing)
    issue = %Issue{kind: :issue, labels: []}
    critical = %Issue{kind: :issue, labels: ["symphony:model:astra"]}

    routes = for attempt <- 1..5, do: elem(ModelRouting.select_for_run(@ladder_routing, %{}, issue, attempt), 1)

    assert Enum.map(routes, &{&1["model"], &1["effort"], &1["tier"]}) == [
             {"gpt-6-sol", "medium", 0},
             {"gpt-6-sol", "xhigh", 1},
             {"gpt-6-astra", "max", 3},
             {"gpt-6-astra", "max", 3},
             {"gpt-6-astra", "max", 3}
           ]

    # The label stays the starting route's so delivery can detect a changed selection.
    assert Enum.all?(routes, &(&1["label"] == "default" and &1["start_tier"] == 0))

    assert {:ok, %{"model" => "gpt-6-astra", "effort" => "medium", "tier" => 2, "label" => "symphony:model:astra"}} =
             ModelRouting.select_for_run(@ladder_routing, %{}, critical, 1)

    assert {:ok, %{"model" => "gpt-6-astra", "effort" => "max", "tier" => 3, "start_tier" => 2}} =
             ModelRouting.select_for_run(@ladder_routing, %{}, critical, 2)

    # Without a ladder, attempts never change the route.
    assert {:ok, route} = ModelRouting.select_for_run(@routing, %{}, issue, 3)
    assert route == %{"model" => "gpt-6-sol", "effort" => "medium", "label" => "default"}
  end

  test "ladder configuration is validated" do
    assert {:ok, _} = Schema.parse(%{"codex" => %{"routing" => @ladder_routing}})

    for {change, message} <- [
          {&Map.delete(&1, "escalation"), "configured together"},
          {&Map.put(&1, "ladder", []), "configured together"},
          {&Map.put(&1, "ladder", [@sol_medium, %{"model" => "x"}]), "each ladder step"},
          {&Map.put(&1, "ladder", [@sol_medium, @sol_medium, @astra_medium]), "distinct"},
          {&Map.put(&1, "escalation", []), "non-decreasing"},
          {&Map.put(&1, "escalation", [0, 2, 1]), "non-decreasing"},
          {&Map.put(&1, "escalation", [-1, 0]), "non-decreasing"},
          {&Map.put(&1, "escalation", 1), "non-decreasing"},
          {&Map.put(&1, "default", %{"model" => "gpt-6-luna", "effort" => "max"}), "ladder step"},
          {&put_in(&1, ["labels", "symphony:model:astra"], %{"model" => "gpt-6-astra", "effort" => "high"}), "ladder step"}
        ] do
      assert {:error, error} = ModelRouting.validate(change.(@ladder_routing))
      assert error =~ message
    end
  end
end
