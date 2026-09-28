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

  @luna_max %{"model" => "gpt-6-luna", "effort" => "max"}

  # The production shape: luna-max only for sized work, Sol by default, Astra after failures.
  @sized_routing %{
    "label_prefix" => "symphony:model:",
    "size_label_prefix" => "symphony:size:",
    "ladder" => [@luna_max, @sol_medium, @sol_xhigh, @astra_medium, @astra_max],
    "escalation" => [0, 1, 3],
    "default" => @sol_medium,
    "sizes" => %{"tiny" => @luna_max, "small" => @luna_max},
    "effort_floor" => %{"gpt-6-luna" => "max"},
    "labels" => %{"symphony:model:sol" => @sol_medium, "symphony:model:astra" => @astra_medium}
  }

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

  defp route_steps(routing, issue, attempts, opts \\ []) do
    for attempt <- attempts do
      {:ok, route} = ModelRouting.select_for_run(routing, %{}, issue, attempt, opts)
      {route["model"], route["effort"], route["tier"]}
    end
  end

  test "size labels start small work on luna-max and failures climb the ladder" do
    assert :ok = ModelRouting.validate(@sized_routing)
    small = %Issue{kind: :issue, labels: ["Symphony:Size:Small"]}

    assert route_steps(@sized_routing, small, 1..3) == [{"gpt-6-luna", "max", 0}, {"gpt-6-sol", "medium", 1}, {"gpt-6-astra", "medium", 3}]

    assert route_steps(@sized_routing, %Issue{kind: :issue, labels: []}, 1..3) == [
             {"gpt-6-sol", "medium", 1},
             {"gpt-6-sol", "xhigh", 2},
             {"gpt-6-astra", "max", 4}
           ]

    # A size keeps the "default" label that delivery tooling expects for unlabelled issues.
    assert {:ok, %{"label" => "default", "size" => "small", "start_tier" => 0}} = ModelRouting.select_for_run(@sized_routing, %{}, small, 1)

    # A model label wins over a size; unknown sizes fall back to the default; the strongest size wins.
    assert {:ok, %{"model" => "gpt-6-astra", "label" => "symphony:model:astra"}} =
             ModelRouting.select(@sized_routing, %Issue{labels: ["symphony:size:tiny", "symphony:model:astra"]})

    assert {:ok, %{"model" => "gpt-6-sol", "label" => "default"} = route} = ModelRouting.select(@sized_routing, %Issue{labels: ["symphony:size:huge"]})
    refute Map.has_key?(route, "size")

    sizes = %{"tiny" => @luna_max, "medium" => @sol_xhigh}
    routing = Map.put(@sized_routing, "sizes", sizes)
    assert {:ok, %{"size" => "medium", "model" => "gpt-6-sol"}} = ModelRouting.select(routing, %Issue{labels: ["symphony:size:tiny", "symphony:size:medium"]})

    # Without a ladder a size still picks the route.
    plain = @routing |> Map.put("size_label_prefix", "size:") |> Map.put("sizes", %{"small" => @luna_max})
    assert {:ok, %{"model" => "gpt-6-luna", "size" => "small"}} = ModelRouting.select(plain, %Issue{labels: ["size:small"]})
  end

  test "sizes and effort floors are validated, including fixed routes" do
    assert {:ok, _} = Schema.parse(%{"codex" => %{"routing" => @sized_routing}})
    luna_medium = %{"model" => "gpt-6-luna", "effort" => "medium"}

    for {change, message} <- [
          {&Map.delete(&1, "size_label_prefix"), "size_label_prefix"},
          {&Map.put(&1, "size_label_prefix", " "), "size_label_prefix"},
          {&put_in(&1, ["sizes", " "], @luna_max), "nonblank"},
          {&put_in(&1, ["sizes", "tiny"], %{"model" => "gpt-6-luna"}), "each route"},
          {&Map.put(&1, "sizes", ["tiny"]), "map size names"},
          {&put_in(&1, ["sizes", "tiny"], @astra_max |> Map.put("model", "gpt-9")), "ladder step"},
          {&Map.put(&1, "effort_floor", %{"gpt-6-luna" => "extreme"}), "supported efforts"},
          {&Map.put(&1, "effort_floor", "max"), "supported efforts"},
          {&Map.update!(&1, "ladder", fn ladder -> [luna_medium | ladder] end), "gpt-6-luna must run at max effort"}
        ] do
      assert {:error, error} = ModelRouting.validate(change.(@sized_routing))
      assert error =~ message
    end

    assert :ok = ModelRouting.validate(Map.put(@sized_routing, "sizes", %{}))
    assert :ok = ModelRouting.check_floor(nil, luna_medium)
    assert :ok = ModelRouting.check_floor(@sized_routing, nil)

    assert {:error, "autopilot gpt-6-luna must run at max effort or higher"} =
             Schema.parse(%{"codex" => %{"routing" => @sized_routing}, "autopilot" => %{"review_route" => luna_medium}})
             |> then(fn {:error, {:invalid_workflow_config, message}} -> {:error, message} end)

    assert {:ok, _} = Schema.parse(%{"codex" => %{"routing" => @sized_routing}, "autopilot" => %{"research_route" => @astra_max}})
  end

  test "quota back-off swaps an avoided model for the strongest allowed step, never below the item's start" do
    avoid = [avoid: %{"gpt-6-astra" => "weekly quota 25% left"}]
    unsized = %Issue{kind: :issue, labels: []}
    small = %Issue{kind: :issue, labels: ["symphony:size:small"]}

    assert route_steps(@sized_routing, unsized, 1..3, avoid) == [{"gpt-6-sol", "medium", 1}, {"gpt-6-sol", "xhigh", 2}, {"gpt-6-sol", "xhigh", 2}]
    assert route_steps(@sized_routing, small, 1..3, avoid) == [{"gpt-6-luna", "max", 0}, {"gpt-6-sol", "medium", 1}, {"gpt-6-sol", "xhigh", 2}]

    assert {:ok, %{"label" => "default", "start_tier" => 1, "backoff" => %{"from" => "gpt-6-astra max", "reason" => "weekly quota 25% left"}}} =
             ModelRouting.select_for_run(@sized_routing, %{}, unsized, 3, avoid)

    # Fixed research and review routes back off too, to the same floor as unsized work.
    fixed = %{research: @astra_max, pull_request: @astra_medium}

    assert {:ok, %{"model" => "gpt-6-sol", "effort" => "xhigh", "label" => "research"}} =
             ModelRouting.select_for_run(@sized_routing, fixed, %Issue{kind: :research}, 1, avoid)

    assert {:ok, %{"model" => "gpt-6-sol", "effort" => "xhigh", "label" => "review"}} =
             ModelRouting.select_for_run(@sized_routing, fixed, %Issue{kind: :pull_request}, 1, avoid)

    # With no allowed step (or no ladder to step down) the run waits instead of starting.
    sol_too = [avoid: %{"gpt-6-astra" => "weekly quota 25% left", "gpt-6-sol" => "sol quota 5% left"}]
    assert {:wait, "sol quota 5% left"} = ModelRouting.select_for_run(@sized_routing, %{}, unsized, 1, sol_too)
    assert {:ok, %{"model" => "gpt-6-luna"}} = ModelRouting.select_for_run(@sized_routing, %{}, small, 1, sol_too)

    off_ladder = %{research: %{"model" => "gpt-6-astra", "effort" => "high"}}
    assert {:wait, "weekly quota 25% left"} = ModelRouting.select_for_run(@sized_routing, off_ladder, %Issue{kind: :research}, 1, avoid)
    assert {:wait, "weekly quota 25% left"} = ModelRouting.select_for_run(@routing, %{}, %Issue{labels: ["symphony:model:astra"]}, 1, avoid)

    # Unavoided routes and unrouted runs are untouched.
    assert {:ok, %{"model" => "gpt-6-sol"} = route} = ModelRouting.select_for_run(@sized_routing, %{}, unsized, 1, avoid)
    refute Map.has_key?(route, "backoff")
    assert {:ok, nil} = ModelRouting.select_for_run(nil, %{}, unsized, 1, avoid)
  end

  test "a research channel's own route wins over the fixed research route" do
    research = %Issue{kind: :research, research: %{channel: "testing", route: @sol_xhigh}}

    assert {:ok, %{"model" => "gpt-6-sol", "effort" => "xhigh", "label" => "research"}} =
             ModelRouting.select_for_run(@sized_routing, %{research: @astra_max}, research, 1)
  end
end
