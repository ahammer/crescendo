defmodule SymphonyElixir.DashboardComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias SymphonyElixirWeb.DashboardComponents, as: C

  @now ~U[2026-09-27 12:00:00Z]

  test "work items are named by kind, with pull request and research context" do
    assert C.kind_name(%{kind: :pull_request}) == "pr"
    assert C.kind_name(%{kind: "research"}) == "research"
    assert C.kind_name(%{issue_identifier: "PR-7"}) == "pr"
    assert C.kind_name(%{issue_identifier: "research-performance"}) == "research"
    assert C.kind_name(%{issue_identifier: "GH-1"}) == "issue"
    assert Enum.map(["pr", "research", "issue"], &C.kind_label/1) == ["Review", "Research", "Issue"]

    assert C.kind_detail(%{kind: :research, research: %{channel: "performance", focus: "GPU"}}) == "Channel performance · GPU"

    pull = %{author: "a", head_ref: "b", head_sha: "c1234567890", ci_state: "pending", can_push: false}
    assert C.kind_detail(%{kind: :pull_request, pull_request: pull}) == "by a · b@c123456 · CI pending · comment-only (cannot push)"

    assert C.kind_detail(%{kind: :issue}) == nil
    assert C.visible_labels(%{labels: ["symphony", "symphony:ready", "solver"]}) == ["solver"]
    assert C.route_detail(%{}) == "route pending"
    assert C.route_model(%{model: nil}) == "pending"
  end

  test "money, tokens and counts read compactly" do
    assert C.format_money(1_234_567) == "$1.23"
    assert C.format_money(420_000) == "$0.420"
    assert C.format_money(nil) == "n/a"
    assert C.format_usd(nil) == "n/a"
    assert Enum.map([2_500_000_000, 3_400_000, 45_600, 1_234, nil], &C.compact/1) == ["2.5B", "3.4M", "45.6K", "1,234", "n/a"]
    assert C.spend_rate(100_000, 30) == "rate pending"
    assert C.spend_rate(1_000_000, 3_600) == "$1.00/h"
    assert C.item_runs(%{runs: 1, since: "2026-09-26"}) == "1 run since 2026-09-26"
    assert C.item_runs(%{runs: 0}) == "first run"
    assert C.short_path(nil) == "workspace pending"
    assert C.percent(3, nil) == 0
    assert C.percent(9, 8) == 100
    assert C.progress_text(%{done: 0, total: 0}) == "no plan yet"
  end

  test "times read as runtimes and relative ages" do
    assert C.runtime_seconds("2026-09-27T11:00:00Z", @now) == 3_600
    assert C.runtime_seconds("not a time", @now) == 0
    assert C.runtime_seconds(nil, @now) == 0
    assert C.format_runtime(3_725) == "1h 2m"
    assert C.format_runtime(125) == "2m 5s"
    assert C.format_runtime(-5) == "0m 0s"

    assert C.ago(DateTime.add(@now, -30, :second), @now) == "30s ago"
    assert C.ago(DateTime.add(@now, -7_500, :second), @now) == "2h 5m ago"
    assert C.ago(DateTime.add(@now, -200_000, :second), @now) == "2d ago"
    assert C.ago("garbage", @now) == "—"
    assert C.until(DateTime.add(@now, 90, :second), @now) == "in 1m"
    assert C.until(DateTime.add(@now, -90, :second), @now) == "is due"
    assert C.until(nil, @now) == "soon"
    assert C.parse_time(42) == nil

    assert C.state_badge_class("Todo") == "state-badge state-badge-warning"
    assert C.state_badge_class("Failed") == "state-badge state-badge-danger"
    assert C.state_badge_class("Closed") == "state-badge"
  end

  test "identifiers link only to web URLs, and shared pieces render" do
    assert C.external_url(" https://example.org/1 ") == "https://example.org/1"
    assert C.external_url("javascript:alert(1)") == nil
    assert C.external_url(nil) == nil

    refute render_component(&C.issue_identifier/1, identifier: "GH-1", url: "javascript:alert(1)") =~ "href"
    assert render_component(&C.issue_identifier/1, identifier: "GH-1", url: "https://example.org/1") =~ ~s(href="https://example.org/1")
    assert render_component(&C.progress/1, progress: %{done: 1, total: 4}) =~ "width: 25%"
    assert render_component(&C.live_badge/1, %{}) =~ "Offline"
    assert render_component(&C.copy_button/1, value: "thread-1") =~ ~s(data-copy="thread-1")
  end
end
