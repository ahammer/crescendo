defmodule SymphonyElixirWeb.ServiceSnapshotTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.ServiceSnapshot

  @earlier ~U[2026-09-27 10:00:00Z]
  @later ~U[2026-09-27 11:00:00Z]

  defp operations(overrides) do
    Map.merge(
      %{
        status: "ok",
        pricing_as_of: "2026-09-24",
        today: %{usd_micro: 1_000_000, total_tokens: 10},
        recorded: %{usd_micro: 5_000_000, total_tokens: 50},
        by_model: [%{model: "gpt-6-sol", usd_micro: 1_000_000, total_tokens: 10, runs: 1}],
        activity: [%{kind: "dispatch", at: "2026-09-27T10:00:00Z", issue_identifier: "GH-1"}],
        daily: [day("2026-09-27", %{"gpt-6-sol" => 1_000_000}, completed: 1, merged: 1)],
        samples: [%{at: "2026-09-27T10:00:00Z", running: 1, ready: 2, spend_micro: 1_000_000}],
        median_run_seconds: %{"issue" => 600},
        by_task: [
          %{model: "gpt-6.1-sol", category: "delivery", runs: 2, usd_micro: 400, timed: 2, seconds: 1_200}
        ],
        images: [%{src: "/artifacts/a/1.png", issue_identifier: "GH-1", at: "2026-09-27T10:00:00Z"}]
      },
      overrides
    )
  end

  test "billing coverage merges known native credits without converting missing estimates to zero" do
    first =
      snapshot(%{
        operations:
          operations(%{
            account_usage: %{
              coverage: "complete",
              threads_recorded: 1,
              threads_observed: 1,
              threads_covered: 1,
              estimated_credits_micros: 100,
              estimated_usd_micros: nil
            },
            delivery_metrics: %{runs_recorded: 1, accepted_delivery_cost: nil}
          })
      })

    second =
      snapshot(%{
        operations:
          operations(%{
            account_usage: %{
              coverage: "incomplete",
              threads_recorded: 1,
              threads_observed: 1,
              threads_covered: 0,
              estimated_credits_micros: nil,
              estimated_usd_micros: nil
            }
          })
      })

    usage = ServiceSnapshot.merge([{"one", first}, {"two", second}], nil).operations

    assert %{
             coverage: "incomplete",
             threads_recorded: 2,
             threads_covered: 1,
             estimated_credits_micros: 100,
             estimated_usd_micros: nil
           } = usage.account_usage

    assert usage.cost_basis == "api_equivalent_estimate"
    assert usage.delivery_metrics.accepted_delivery_cost == nil
    assert ServiceSnapshot.merge([{"one", first}], nil).operations.account_usage.coverage == "complete"
    assert ServiceSnapshot.merge([], nil).operations.account_usage.estimated_credits_micros == nil
  end

  defp day(date, spend, counts) do
    Map.merge(
      %{date: date, spend_by_model: spend, completed: 0, failed: 0, interrupted: 0, merged: 0, closed: 0},
      Map.new(counts)
    )
  end

  defp snapshot(overrides) do
    Map.merge(
      %{
        running: [%{identifier: "GH-1"}],
        retrying: [],
        blocked: [],
        codex_totals: %{input_tokens: 1, output_tokens: 2, total_tokens: 3, seconds_running: 4},
        operations: operations(%{}),
        operations_error: nil,
        upcoming: %{
          ready: [%{issue_identifier: "GH-2"}, %{issue_identifier: "GH-3"}],
          waiting: [%{issue_identifier: "GH-4"}],
          observed_at: @later,
          error: nil,
          available_slots: 1
        },
        autopilot: %{
          enabled: true,
          channels: ["qa"],
          research_pending: ["qa"],
          research_running: 0,
          open_issues: 3,
          max_open_issues: 10,
          next_research_at: @later
        },
        pull_requests: %{items: [%{number: 7}], observed_at: @later, error: nil, enabled: true},
        quota: nil,
        throttle: nil,
        polling: %{checking?: false, next_poll_in_ms: 20_000, poll_interval_ms: 30_000}
      },
      overrides
    )
  end

  test "projects merge into one snapshot with every item tagged by project" do
    metalrain = snapshot(%{})

    nubu =
      snapshot(%{
        running: [%{identifier: "GH-9"}],
        blocked: [%{identifier: "GH-8"}],
        operations:
          operations(%{
            today: %{usd_micro: 2_000_000, total_tokens: 20},
            by_model: [
              %{model: "gpt-6-sol", usd_micro: 2_000_000, total_tokens: 20, runs: 2},
              %{model: "gpt-6-luna", usd_micro: 1, total_tokens: 1, runs: 1}
            ],
            activity: [%{kind: "pr_merged", at: "2026-09-27T11:00:00Z", pr_number: 3}],
            daily: [day("2026-09-26", %{"gpt-6-luna" => 5}, failed: 1, closed: 1)],
            median_run_seconds: %{"issue" => 1_000, "pull_request" => 300}
          }),
        operations_error: "disk full",
        upcoming: %{
          ready: [%{issue_identifier: "GH-5"}],
          waiting: [],
          observed_at: @earlier,
          error: "rate limited",
          available_slots: 2
        },
        pull_requests: %{items: [], observed_at: @earlier, error: "GitHub HTTP 502", enabled: true},
        polling: %{checking?: true, next_poll_in_ms: 5_000, poll_interval_ms: 30_000},
        autopilot: %{
          enabled: false,
          channels: ["docs"],
          research_pending: [],
          research_running: 1,
          open_issues: 1,
          max_open_issues: 5,
          next_research_at: @earlier
        }
      })

    governor = %{
      slots: 3,
      busy: 2,
      quota: %{observed_at: @later},
      throttle: %{avoid: %{}, paused: nil, over_budget: nil}
    }

    merged = ServiceSnapshot.merge([{"metalrain", metalrain}, {"nubu3d", nubu}], governor)

    assert merged.running == [
             %{identifier: "GH-1", project: "metalrain"},
             %{identifier: "GH-9", project: "nubu3d"}
           ]

    assert merged.blocked == [%{identifier: "GH-8", project: "nubu3d"}]
    assert merged.codex_totals == %{input_tokens: 2, output_tokens: 4, total_tokens: 6, seconds_running: 8}
    assert merged.operations_error == "nubu3d: disk full"

    # Ready work interleaves across projects; the stalest read shows.
    assert Enum.map(merged.upcoming.ready, &{&1.project, &1.issue_identifier}) == [
             {"metalrain", "GH-2"},
             {"nubu3d", "GH-5"},
             {"metalrain", "GH-3"}
           ]

    assert merged.upcoming.waiting == [%{issue_identifier: "GH-4", project: "metalrain"}]
    assert merged.upcoming.observed_at == @earlier
    assert merged.upcoming.error == "nubu3d: rate limited"
    assert merged.upcoming.available_slots == 1

    assert %{enabled: true, research_pending: ["metalrain/qa"], research_running: 1} = merged.autopilot
    assert %{open_issues: 4, max_open_issues: 15} = merged.autopilot
    assert merged.autopilot.channels == ["metalrain/qa", "nubu3d/docs"]

    assert merged.autopilot.next_research_at == @earlier

    assert %{items: [%{number: 7, project: "metalrain"}], observed_at: @earlier, enabled: true} =
             merged.pull_requests

    assert merged.pull_requests.error == "nubu3d: GitHub HTTP 502"
    assert merged.polling == %{checking?: true, next_poll_in_ms: 5_000, poll_interval_ms: 30_000}
    assert merged.quota == %{observed_at: @later}
    assert merged.throttle == %{avoid: %{}, paused: nil, over_budget: nil, service_slots: 3, busy: 2}

    ops = merged.operations

    assert %{status: "ok", pricing_as_of: "2026-09-24", today: %{usd_micro: 3_000_000, total_tokens: 30}} =
             ops

    assert ops.by_model == [
             %{model: "gpt-6-luna", usd_micro: 1, total_tokens: 1, runs: 1},
             %{model: "gpt-6-sol", usd_micro: 3_000_000, total_tokens: 30, runs: 3}
           ]

    assert [%{kind: "pr_merged", project: "nubu3d"}, %{kind: "dispatch", project: "metalrain"}] = ops.activity

    assert [
             %{date: "2026-09-26", failed: 1, closed: 1},
             %{date: "2026-09-27", completed: 1, merged: 1} = today
           ] = ops.daily

    assert today.spend_by_model == %{"gpt-6-sol" => 1_000_000}
    assert ops.samples == [%{at: "2026-09-27T10:00:00Z", running: 2, ready: 4, spend_micro: 2_000_000}]
    assert ops.median_run_seconds == %{"issue" => 800, "pull_request" => 300}
    assert [%{project: "metalrain"}, %{project: "nubu3d"}] = Enum.sort_by(ops.images, & &1.project)

    assert ops.by_task == [
             %{model: "gpt-6.1-sol", category: "delivery", runs: 4, usd_micro: 800, timed: 4, seconds: 2_400}
           ]

    assert ops.by_project == [
             %{project: "metalrain", today_usd_micro: 1_000_000, days_usd_micro: 1_000_000},
             %{project: "nubu3d", today_usd_micro: 2_000_000, days_usd_micro: 5}
           ]
  end

  test "without a Governor, slots add up and the newest project quota shows" do
    older = %{observed_at: @earlier}
    newer = %{observed_at: @later}
    unavailable = snapshot(%{quota: newer, operations: operations(%{status: "unavailable"})})
    merged = ServiceSnapshot.merge([{"a", snapshot(%{quota: older})}, {"b", unavailable}], nil)

    assert merged.upcoming.available_slots == 2
    assert merged.quota == newer
    assert merged.throttle == nil
    assert merged.operations.status == "unavailable"
  end

  test "failed snapshots are retained as errors while only observed data merges" do
    merged = ServiceSnapshot.merge([{"a", snapshot(%{})}, {"b", :timeout}, {"c", :unavailable}], nil)
    assert merged.snapshot_status == "partial"

    assert merged.snapshot_errors == [
             %{project: "b", status: "timeout"},
             %{project: "c", status: "unavailable"}
           ]

    assert merged.running == [%{identifier: "GH-1", project: "a"}]
    assert merged.upcoming.ready != []

    empty = ServiceSnapshot.merge([{"b", :timeout}], nil)
    assert empty.snapshot_status == "partial"
    assert empty.running == []
  end

  test "no projects merge into an empty snapshot" do
    merged = ServiceSnapshot.merge([], nil)

    assert %{running: [], retrying: [], blocked: [], codex_totals: %{}, operations_error: nil, quota: nil} =
             merged

    assert %{ready: [], waiting: [], observed_at: nil, error: nil, available_slots: 0} = merged.upcoming

    assert %{status: "unavailable", today: %{}, by_model: [], activity: [], daily: [], by_project: []} =
             merged.operations

    assert %{enabled: false, channels: [], next_research_at: nil} = merged.autopilot
    assert %{checking?: false, next_poll_in_ms: nil} = merged.polling
  end
end
