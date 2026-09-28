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
end
