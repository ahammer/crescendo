defmodule SymphonyElixir.OperationsTest do
  use ExUnit.Case

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Operations

  test "model usage and activity survive reopening the local ledger" do
    path = Path.join(System.tmp_dir!(), "symphony-operations-#{System.unique_integer([:positive])}.dets")
    on_exit(fn -> File.rm(path) end)

    {:ok, table} = Operations.open(path, :symphony_operations_test)
    :ok = Operations.start_run(table, "run-1", %{issue_identifier: "GH-1", summary: "Dispatched"})

    :ok =
      Operations.usage(table, "run-1", "gpt-6-sol", %{
        input_tokens: 1_000_000,
        cached_input_tokens: 500_000,
        output_tokens: 100_000,
        total_tokens: 1_100_000
      })

    :ok = Operations.sync(table)
    :ok = Operations.close(table)

    {:ok, table} = Operations.open(path, :symphony_operations_test)
    snapshot = Operations.snapshot(table)
    assert snapshot.recorded.usd_micro == 1_050_000
    # The throttle's budget check reads the same total without folding the whole ledger.
    assert Operations.spend_today(table) == snapshot.today.usd_micro
    assert Operations.spend_today(nil) == 0
    assert snapshot.today.cached_input_tokens == 500_000
    assert [%{model: "gpt-6-sol", total_tokens: 1_100_000}] = snapshot.by_model
    assert Enum.any?(snapshot.activity, &(&1.kind == "interrupted"))
    :ok = Operations.close(table)
    assert Operations.spend_today(table) == 0
  end

  test "item attempts and scoped dispositions survive replay independently of run endings" do
    path = Path.join(System.tmp_dir!(), "outcome-facts-#{System.unique_integer([:positive])}.dets")
    table = :outcome_facts_test

    on_exit(fn ->
      Operations.close(table)
      File.rm(path)
    end)

    {:ok, ^table} = Operations.open(path, table)

    details = %{issue_identifier: "GH-1", item_attempt: 1, model: "gpt-6-sol"}
    Operations.start_run(table, "blocked-run", details)
    Operations.finish_run(table, "blocked-run", "completed", details)
    Operations.event(table, "attempt_failed", details)
    Operations.event(table, "attempt_failed", details)
    Operations.event(table, "blocked", details)
    assert %{completed: 1, blocked_attempts: 1, accepted_deliveries: 0} = List.last(Operations.snapshot(table).daily)
    assert Enum.any?(Operations.snapshot(table).activity, &match?(%{kind: "attempt_failed", run_id: "blocked-run", item_attempt: 1}, &1))

    accepted = %{identifier: "GH-2", url: nil, labels: ["crescendo:delivery:verified-existing"]}
    Operations.start_run(table, "accepted-run", %{issue_identifier: "GH-2", item_attempt: 1})
    Operations.usage(table, "accepted-run", "gpt-6-sol", %{input_tokens: 1_000_000}, "GH-2")
    Operations.disposition(table, accepted)
    Operations.finish_run(table, "accepted-run", "stopped", %{issue_identifier: "GH-2"})
    Operations.finish_run(table, "accepted-run", "failed", %{issue_identifier: "GH-2"})
    assert %{usd_micro: 1_000_000, runs: 1} = Operations.item_usage(table, "GH-2")
    assert Enum.any?(Operations.snapshot(table).activity, &match?(%{kind: "stopped", seconds: seconds, usd_micro: 1_000_000} when is_integer(seconds), &1))

    Operations.disposition(table, %{identifier: "GH-3", url: nil, labels: ["crescendo:delivery:split"]})
    Operations.disposition(table, %{identifier: "GH-4", url: nil, labels: [], state_reason: "not_planned"})
    Operations.disposition(table, %{identifier: "GH-5", url: nil, labels: []})
    pull = %{pr_number: 6, pr_url: "https://github.com/acme/repo/pull/6"}
    Operations.event(table, "pr_closed", pull)
    Operations.event(table, "pr_opened", pull)
    Operations.event(table, "pr_merged", pull)
    Operations.event(table, "pr_merged", pull)
    before = Operations.snapshot(table)
    assert %{stopped: 1, failed: 0, blocked_attempts: 1, accepted_deliveries: 3, retirements: 1, unknown_dispositions: 1, closed: 1} = List.last(before.daily)
    assert Enum.any?(before.activity, &(&1.kind == "pr_reopened"))
    assert Enum.any?(before.activity, &match?(%{kind: "item_disposition", disposition: "merged", attribution: "unknown"}, &1))

    Operations.close(table)
    {:ok, ^table} = Operations.open(path, table)
    Operations.disposition(table, accepted)
    Operations.event(table, "attempt_failed", details)
    Operations.event(table, "pr_merged", pull)
    after_replay = Operations.snapshot(table)
    assert after_replay.daily == before.daily
    assert List.last(after_replay.daily).accepted_deliveries == 3
    assert List.last(after_replay.daily).blocked_attempts == 1
    assert after_replay.by_task == before.by_task
    assert after_replay.recorded == before.recorded
  end

  test "blocks without autopilot distinguish runs even without numbered attempts" do
    path = Path.join(System.tmp_dir!(), "blocked-runs-#{System.unique_integer([:positive])}.dets")
    table = :blocked_runs_test

    on_exit(fn ->
      Operations.close(table)
      File.rm(path)
    end)

    {:ok, ^table} = Operations.open(path, table)

    for run <- ["one", "two"] do
      Operations.start_run(table, run, %{issue_identifier: "GH-1", item_attempt: 1})
      details = %{issue_identifier: "GH-1", run_id: run, item_attempt: nil}
      Operations.event(table, "blocked", details)
      Operations.event(table, "blocked", details)
    end

    assert List.last(Operations.snapshot(table).daily).blocked_attempts == 2
  end

  test "old events keep unknown run attribution without inventing acceptance" do
    path = Path.join(System.tmp_dir!(), "legacy-facts-#{System.unique_integer([:positive])}.dets")
    table = :legacy_facts_test

    on_exit(fn ->
      Operations.close(table)
      File.rm(path)
    end)

    {:ok, ^table} = Operations.open(path, table)
    at = DateTime.utc_now() |> DateTime.to_iso8601()

    :dets.insert(table, [
      {{:event, 1}, %{kind: "completed", issue_identifier: "GH-1", at: at}},
      {{:event, 2}, %{kind: "attempt_failed", issue_identifier: "GH-1", at: at}},
      {{:event, 3}, %{kind: "issue_terminal", issue_identifier: "GH-2", at: at}}
    ])

    assert %{completed: 1, blocked_attempts: 1, accepted_deliveries: 0, unknown_dispositions: 1} = List.last(Operations.snapshot(table).daily)
    assert Enum.all?(Operations.snapshot(table).activity, &(&1.attribution == "unknown"))
    Operations.close(table)
    {:ok, ^table} = Operations.open(path, table)
    assert List.last(Operations.snapshot(table).daily).blocked_attempts == 1
  end

  test "prices come from the built-in table with configured models on top" do
    pricing = %{
      "as_of" => "2026-10-01",
      "models" => %{
        "gpt-6-sol" => %{"input" => 2, "cached_input" => 0.2, "output" => 10},
        "gpt-7" => %{"input" => 1.5, "cached_input" => 0.15, "output" => 6}
      }
    }

    {:ok, settings} = Schema.parse(%{"pricing" => pricing})
    rates = Operations.rates(settings.pricing)
    assert rates["gpt-6-sol"] == {2_000_000, 200_000, 10_000_000}
    assert rates["gpt-7"] == {1_500_000, 150_000, 6_000_000}
    assert rates["gpt-6-astra"] == Operations.rates(nil)["gpt-6-astra"]
    assert Operations.price_date(settings.pricing) == "2026-10-01"
    assert Operations.price_date(nil) == "2026-09-24"

    path = Path.join(System.tmp_dir!(), "symphony-operations-pricing-#{System.unique_integer([:positive])}.dets")
    on_exit(fn -> File.rm(path) end)
    {:ok, table} = Operations.open(path, :symphony_operations_pricing_test)
    :ok = Operations.usage(table, "run-1", "gpt-7", %{input_tokens: 1_000_000, output_tokens: 100_000, total_tokens: 1_100_000}, "GH-1", rates)
    assert %{usd_micro: 2_100_000, unpriced_tokens: 0} = Operations.run_usage(table, "run-1")
    :ok = Operations.close(table)

    for bad <- [%{"x" => %{"input" => 1}}, %{"x" => %{"input" => -1, "cached_input" => 0, "output" => 1}}, %{"x" => 3}] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"pricing" => %{"models" => bad}})
      assert message =~ "pricing.models"
    end
  end

  test "run and item usage sum a run's rows and accumulate an item across runs" do
    path = Path.join(System.tmp_dir!(), "symphony-operations-cost-#{System.unique_integer([:positive])}.dets")
    on_exit(fn -> File.rm(path) end)
    {:ok, table} = Operations.open(path, :symphony_operations_cost_test)

    delta = %{input_tokens: 1_000_000, output_tokens: 100_000, total_tokens: 1_100_000}
    :ok = Operations.usage(table, "run-1", "gpt-6-sol", delta, "GH-9")
    :ok = Operations.usage(table, "run-1", "gpt-6-luna", delta, "GH-9")
    :ok = Operations.usage(table, "run-2", "gpt-6-sol", delta, "GH-9")
    :ok = Operations.usage(table, "run-3", "mystery-model", delta, "GH-9")
    :ok = Operations.usage(table, "run-4", "gpt-6-sol", %{input_tokens: 0}, "GH-9")

    # gpt-6-sol $1.50 + gpt-6-luna $0.075 for the same run.
    assert %{usd_micro: 1_575_000, total_tokens: 2_200_000, unpriced_tokens: 0} = Operations.run_usage(table, "run-1")
    assert %{usd_micro: 0, total_tokens: 0} = Operations.run_usage(table, "missing")

    item = Operations.item_usage(table, "GH-9")
    assert %{usd_micro: 3_075_000, total_tokens: 4_400_000, unpriced_tokens: 1_100_000, runs: 3} = item
    assert item.since == Date.utc_today() |> Date.to_iso8601()
    assert %{runs: 0, since: nil} = Operations.item_usage(table, "GH-404")

    assert Operations.run_usage(nil, "run-1").usd_micro == 0
    assert Operations.run_usage(table, nil).usd_micro == 0
    assert Operations.item_usage(nil, "GH-9").runs == 0
    assert Operations.item_usage(table, nil).runs == 0

    :ok = Operations.close(table)
    assert Operations.run_usage(table, "run-1").usd_micro == 0
    assert Operations.item_usage(table, "GH-9").runs == 0
  end

  test "intraday samples and recent median run times feed the dashboard" do
    path = Path.join(System.tmp_dir!(), "symphony-operations-samples-#{System.unique_integer([:positive])}.dets")
    on_exit(fn -> File.rm(path) end)
    {:ok, table} = Operations.open(path, :symphony_operations_samples_test)

    sample = %{running: 2, ready: 5, waiting: 1, attention: 0, open_prs: 3, spend_micro: 1_000}
    :ok = Operations.record_sample(table, sample)
    :ok = Operations.record_sample(table, %{sample | running: 3, ready: 4, attention: 1, spend_micro: 2_000})

    # One row per five-minute bucket: the newest sample in a bucket wins.
    samples = Operations.snapshot(table).samples
    assert length(samples) in 1..2
    assert %{running: 3, spend_micro: 2_000, at: at} = List.last(samples)
    assert {:ok, _time, 0} = DateTime.from_iso8601(at)

    # Event times are written directly so the runs have known durations.
    now = DateTime.utc_now()

    events = [
      {"dispatch", "GH-1", -3_000},
      {"completed", "GH-1", -2_400},
      {"dispatch", "GH-2", -2_000},
      {"failed", "GH-2", -1_000},
      {"dispatch", "GH-3", -900},
      {"completed", "GH-3", -700},
      {"dispatch", "PR-4", -500},
      {"completed", "PR-4", -200},
      {"dispatch", "GH-5", -5 * 86_400},
      {"completed", "GH-5", -4 * 86_400},
      {"completed", "GH-6", -100}
    ]

    for {{kind, identifier, offset}, sequence} <- Enum.with_index(events, 1) do
      at = now |> DateTime.add(offset, :second) |> DateTime.to_iso8601()
      :ok = :dets.insert(table, [{:sequence, sequence}, {{:event, sequence}, %{kind: kind, issue_identifier: identifier, at: at}}])
    end

    # Issues ran 600s, 1000s and 200s; the five-day-old run is outside the window.
    assert Operations.snapshot(table).median_run_seconds == %{"issue" => 600, "pull_request" => 300}
    assert Operations.record_sample(nil, %{}) == :ok
    assert %{samples: [], median_run_seconds: %{}} = Operations.snapshot(nil)
    :ok = Operations.close(table)
  end

  test "full history exposes the bounded event ring and two days of samples" do
    path = Path.join(System.tmp_dir!(), "operations-history-#{System.unique_integer([:positive])}.dets")
    {:ok, table} = Operations.open(path, :operations_history_test)

    on_exit(fn ->
      Operations.close(table)
      File.rm(path)
    end)

    for number <- 1..2_001 do
      Operations.event(table, "dispatch", %{issue_identifier: "GH-#{number}", run_id: "run-#{number}"})
    end

    bucket = div(System.os_time(:second), 300)
    sample = %{running: 1, ready: 2, waiting: 0, attention: 0, open_prs: 0, spend_micro: 123}

    for offset <- [0, 144, 288, 575, 576] do
      :dets.insert(table, {{:sample, bucket - offset}, sample})
    end

    recent = Operations.snapshot(table)
    history = Operations.snapshot(table, history: true)
    assert length(recent.activity) == 100
    assert length(history.activity) == 2_000
    assert hd(history.activity).issue_identifier == "GH-2001"
    assert List.last(history.activity).issue_identifier == "GH-2"
    assert Enum.all?(history.activity, &(&1.attribution == "recorded"))
    assert length(recent.samples) == 1
    assert length(history.samples) == 4
    assert Enum.map(history.samples, & &1.at) == Enum.sort(Enum.map(history.samples, & &1.at))
    assert Enum.all?(history.samples, &is_nil(&1.admission))

    observation = %{
      source: "governor",
      scope: "service",
      observed_at: DateTime.to_iso8601(DateTime.utc_now()),
      slots: 3,
      busy: 1,
      draining: false,
      research_hold: %{project: "public", phase: "reserved"}
    }

    Operations.record_sample(table, Map.put(sample, :admission, observation))
    assert :dets.lookup(table, {:sample, bucket - 576}) == []
    Operations.close(table)
    {:ok, table} = Operations.open(path, :operations_history_test)
    restarted = Operations.snapshot(table, history: true)
    assert List.last(restarted.samples).admission == observation
    assert length(restarted.samples) == 4
    assert hd(restarted.samples).admission == nil
    assert history.daily == recent.daily
    assert %{activity: [], samples: []} = Operations.snapshot(nil, history: true)
  end

  test "a finished run records its task: model, category, time and cost" do
    path = Path.join(System.tmp_dir!(), "symphony-operations-tasks-#{System.unique_integer([:positive])}.dets")
    on_exit(fn -> File.rm(path) end)
    {:ok, table} = Operations.open(path, :symphony_operations_tasks_test)

    :ok = Operations.start_run(table, "run-1", %{issue_identifier: "GH-1", summary: "Dispatched"})
    :ok = Operations.usage(table, "run-1", "gpt-6.1-sol", %{input_tokens: 1_000_000, output_tokens: 0, total_tokens: 1_000_000})
    :ok = Operations.finish_run(table, "run-1", "completed", %{issue_identifier: "GH-1", title: "Fix it", model: "gpt-6.1-sol"})
    # A run without a start record (or a model) still counts, untimed.
    :ok = Operations.finish_run(table, "run-2", "failed", %{issue_identifier: "PR-2"})
    # Tasks older than two weeks are dropped when the next one lands.
    :ok = :dets.insert(table, {{:task, "old"}, %{at_s: 0, model: "gpt-6-sol", category: "delivery", seconds: 1, usd_micro: 1, outcome: "completed"}})
    :ok = Operations.finish_run(table, "run-3", "completed", %{issue_identifier: "research-marketing", model: "gpt-6.1-sol"})

    snapshot = Operations.snapshot(table)

    assert snapshot.by_task == [
             %{model: "gpt-6.1-sol", category: "delivery", runs: 1, usd_micro: 1_000_000, timed: 1, seconds: 0},
             %{model: "gpt-6.1-sol", category: "marketing", runs: 1, usd_micro: 0, timed: 0, seconds: 0},
             %{model: "unknown", category: "review", runs: 1, usd_micro: 0, timed: 0, seconds: 0}
           ]

    assert %{kind: "completed", title: "Fix it", category: "delivery", seconds: 0, usd_micro: 1_000_000} =
             Enum.find(snapshot.activity, &(&1[:issue_identifier] == "GH-1" and &1.kind == "completed"))

    assert Enum.map(["PR-9", "research-qa", "research-marketing", "GH-3", nil], &Operations.task_category/1) ==
             ["review", "research", "marketing", "delivery", "delivery"]

    assert Operations.snapshot(nil).by_task == []

    # Stored images feed the picture timeline, newest first, within three days.
    :ok = Operations.record_image(table, %{src: "/artifacts/a/1.png", issue_identifier: "GH-1", title: "Fix it", run_id: "dropped"})
    :ok = Operations.record_image(table, %{src: "/artifacts/a/2.png", issue_identifier: "GH-1"})
    :ok = :dets.insert(table, {{:image, 0}, %{src: "/artifacts/old/1.png", at: "2020-01-01T00:00:00Z"}})
    assert [%{src: "/artifacts/a/2.png"}, %{src: "/artifacts/a/1.png", title: "Fix it"} = first] = Operations.snapshot(table).images
    refute Map.has_key?(first, :run_id)
    assert Operations.record_image(nil, %{}) == :ok
    assert Operations.snapshot(nil).images == []
    :ok = Operations.close(table)
  end
end
