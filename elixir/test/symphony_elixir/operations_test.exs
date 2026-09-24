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
end
