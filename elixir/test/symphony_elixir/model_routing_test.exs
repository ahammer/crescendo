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

  test "research runs use the research route and other runs route by label" do
    routing = %{
      "label_prefix" => "symphony:model:",
      "default" => %{"model" => "luna", "effort" => "medium"},
      "labels" => %{"symphony:model:sol" => %{"model" => "sol", "effort" => "high"}}
    }

    research_route = %{"model" => "astra", "effort" => "xhigh"}
    research = %Issue{kind: :research, labels: ["symphony:model:sol"]}
    issue = %Issue{kind: :issue, labels: ["symphony:model:sol"]}

    assert {:ok, %{"model" => "astra", "effort" => "xhigh", "label" => "research"}} = ModelRouting.select_for_run(routing, research_route, research)
    assert {:ok, %{"model" => "sol", "label" => "symphony:model:sol"}} = ModelRouting.select_for_run(routing, research_route, issue)

    assert {:ok, %{"model" => "luna", "label" => "default"}} =
             ModelRouting.select_for_run(routing, nil, %{research | labels: ["symphony:research"]})

    assert :ok = ModelRouting.validate_route(research_route)
    assert :ok = ModelRouting.validate_route(%{"model" => "gpt-6-luna", "effort" => "max"})
    assert {:error, _} = ModelRouting.validate_route(%{"model" => "astra", "effort" => "extreme"})
  end
end
