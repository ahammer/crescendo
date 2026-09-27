defmodule SymphonyElixir.DashboardChartsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias SymphonyElixir.Operations
  alias SymphonyElixirWeb.Charts

  @series [
    %{key: :completed, label: "Completed", class: "status-good"},
    %{key: :failed, label: "Failed", class: "status-critical"}
  ]

  test "columns draw at a narrower width for small panels" do
    html =
      render_component(&Charts.columns/1,
        id: "narrow",
        title: "Runs per day",
        series: @series,
        columns: [%{label: "Sep 1", tip: "2026-09-01", values: %{completed: 1}}],
        format: &Integer.to_string(round(&1)),
        integer: true,
        width: 340
      )

    assert html =~ ~s(viewBox="0 0 340 150")
  end

  test "stacked columns draw a legend, rounded data ends, hover titles, and a table view" do
    columns = [
      %{label: "Sep 1", tip: "2026-09-01", values: %{completed: 3, failed: 1}},
      %{label: "Sep 2", tip: "2026-09-02", values: %{completed: 0, failed: 0}},
      %{label: "Sep 3", tip: "2026-09-03", values: %{completed: 5}}
    ]

    html =
      render_component(&Charts.columns/1,
        id: "runs",
        title: "Runs per day",
        series: @series,
        columns: columns,
        format: &Integer.to_string(round(&1)),
        integer: true
      )

    assert html =~ ~s(class="chart-legend")
    assert html =~ "Completed"
    assert html =~ "<title>2026-09-01 · Completed 3, Failed 1</title>"
    # Two segments on day one (one rounded data end), one on day three, none on the empty day.
    assert length(Regex.scan(~r/class="chart-mark /, html)) == 3
    assert html =~ " Q"
    assert html =~ "<th scope=\"row\">2026-09-02</th>"
    # Axis labels at the first, middle, and last column.
    assert html =~ ">Sep 1<" and html =~ ">Sep 2<" and html =~ ">Sep 3<"
  end

  test "a single series has no legend and an empty chart still has an axis" do
    html =
      render_component(&Charts.columns/1,
        id: "spend",
        title: "Spend",
        series: [%{key: "m", label: "m", class: "series-1"}],
        columns: [],
        format: &to_string/1
      )

    refute html =~ "chart-legend"
    assert html =~ "chart-baseline"
  end

  test "axis maxima land on clean steps" do
    assert Charts.nice_max(0, true) == 3
    assert Charts.nice_max(0, false) == 3.0
    assert Charts.nice_max(1, true) == 3
    assert Charts.nice_max(7, true) == 9
    assert Charts.nice_max(40, false) == 60.0
    assert_in_delta Charts.nice_max(2_600_000, false), 3_000_000, 0.001
  end

  test "bars scale to the largest row and meters carry severity" do
    html =
      render_component(&Charts.bars/1,
        title: "Tokens",
        rows: [%{label: "astra", value: 200, display: "200", class: "series-1"}, %{label: "luna", value: 50, display: "50", class: "series-2"}]
      )

    assert html =~ "width: 100.0%"
    assert html =~ "width: 25.0%"
    assert render_component(&Charts.bars/1, title: "None", rows: [%{label: "x", value: 0, display: "0", class: "series-1"}]) =~ "width: 0%"

    assert render_component(&Charts.meter/1, label: "Primary", percent: 95, detail: "Resets soon") =~ "meter-critical"
    assert render_component(&Charts.meter/1, label: "Primary", percent: 75) =~ "meter-warning"
    ok = render_component(&Charts.meter/1, label: "Primary", percent: 140)
    assert ok =~ "meter-critical" and ok =~ ~s(aria-valuenow="100")
    assert render_component(&Charts.meter/1, label: "Primary", percent: 10) =~ "meter-ok"
  end

  test "operations snapshots carry fourteen days of spend and run outcomes" do
    path = Path.join(System.tmp_dir!(), "dashboard-ops-#{System.unique_integer([:positive])}.dets")
    table = :"dashboard_ops_#{System.unique_integer([:positive])}"

    try do
      {:ok, ^table} = Operations.open(path, table)
      :ok = Operations.usage(table, "run-1", "gpt-5.5", %{input_tokens: 1_000_000, output_tokens: 10_000, total_tokens: 1_010_000})
      :ok = Operations.event(table, "completed", %{issue_identifier: "GH-1"})
      :ok = Operations.event(table, "failed", %{issue_identifier: "GH-2"})
      :ok = Operations.event(table, "pr_merged", %{pr_number: 3})
      :ok = Operations.event(table, "dispatch", %{issue_identifier: "GH-4"})

      daily = Operations.snapshot(table).daily
      today = List.last(daily)

      assert length(daily) == 14
      assert today.date == Date.utc_today() |> Date.to_iso8601()
      assert today.spend_by_model == %{"gpt-5.5" => 5_300_000}
      assert %{completed: 1, failed: 1, interrupted: 0, merged: 1} = today
      assert hd(daily).spend_by_model == %{}
      assert length(Operations.snapshot(nil).daily) == 14
    after
      Operations.close(table)
      File.rm(path)
    end
  end
end
