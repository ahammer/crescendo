defmodule SymphonyElixir.OperationsTest do
  use ExUnit.Case

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
    assert snapshot.today.cached_input_tokens == 500_000
    assert [%{model: "gpt-6-sol", total_tokens: 1_100_000}] = snapshot.by_model
    assert Enum.any?(snapshot.activity, &(&1.kind == "interrupted"))
    :ok = Operations.close(table)
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
end
