defmodule SymphonyElixir.TerminalUsageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.Usage
  alias SymphonyElixir.Operations

  setup do
    path = Path.join(System.tmp_dir!(), "terminal-usage-#{System.unique_integer([:positive])}.dets")
    table = :terminal_usage_test
    {:ok, ^table} = Operations.open(path, table)

    on_exit(fn ->
      Operations.close(table)
      File.rm(path)
    end)

    %{table: table, path: path}
  end

  test "offline ended-worker fixture reproduces and reconciles the reported aggregate gap", %{table: table} do
    fixture = Jason.decode!(File.read!("test/fixtures/terminal-usage-gap.json"))

    for run <- fixture["runs"] do
      bind(table, run["run_id"], run["thread_id"])
      {:ok, _} = Operations.reconcile_usage(table, "issue", run["run_id"], usage(run["thread_id"], run["ledger"]))
      Operations.finish_run(table, run["run_id"], run["outcome"], %{issue_identifier: "GH-1"})
    end

    before = Operations.snapshot(table)
    assert before.recorded.input_tokens == 6_000
    assert before.accounting.incomplete == 6

    for run <- fixture["runs"] do
      update = %{payload: run["native_event"]}
      for _ <- 1..2, do: assert({:ok, _} = Operations.reconcile_usage(table, "issue", run["run_id"], update))
      terminal = terminal(run["thread_id"], run["native_event"]["params"]["turnId"], "interrupted")
      assert :ignored = Operations.reconcile_usage(table, "issue", run["run_id"], terminal)
    end

    after_usage = Operations.snapshot(table)
    assert after_usage.recorded.input_tokens - before.recorded.input_tokens == 512_557
    assert after_usage.recorded.output_tokens - before.recorded.output_tokens == 1_927
    assert after_usage.recorded.total_tokens == 520_604
    assert after_usage.accounting.terminal_observed == 6
    assert Operations.item_usage(table, "GH-1").total_tokens == after_usage.recorded.total_tokens
    assert [%{total_tokens: 520_604}] = after_usage.by_model
    assert Enum.sum(Enum.flat_map(after_usage.daily, &Map.values(&1.spend_by_model))) == after_usage.recorded.usd_micro
    for entry <- after_usage.activity, entry[:run_id], do: assert(entry.cache_write_status == "unknown")
    assert [%{usd_micro: cost}] = after_usage.by_task
    assert cost == after_usage.recorded.usd_micro
  end

  test "terminal evidence survives event ordering, failures and restart", ctx do
    for {id, status, order} <- [{"one", "completed", :before}, {"two", "failed", :after}, {"three", "interrupted", :before}] do
      bind(ctx.table, id, id)
      assert :ignored = Operations.reconcile_usage(ctx.table, "issue", id, %{event: :session_started, thread_id: id, turn_id: "turn"}, true)
      if order == :before, do: Operations.reconcile_usage(ctx.table, "issue", id, terminal(id, "turn", status))
      assert {:ok, _} = Operations.reconcile_usage(ctx.table, "issue", id, usage(id, %{"inputTokens" => 200, "outputTokens" => 50, "cachedInputTokens" => 180, "reasoningOutputTokens" => 40}))
      Operations.finish_run(ctx.table, id, status, %{issue_identifier: "GH-1", model: "gpt-6-sol"})
      if order == :after, do: Operations.reconcile_usage(ctx.table, "issue", id, terminal(id, "turn", status))
      # A context compaction estimate and stale/duplicate totals never charge again.
      assert :ignored = Operations.reconcile_usage(ctx.table, "issue", id, %{payload: %{"method" => "thread/compacted", "params" => %{"threadId" => id, "usage" => %{"inputTokens" => 999}}}})
      {:ok, delta} = Operations.reconcile_usage(ctx.table, "issue", id, usage(id, %{"inputTokens" => 100, "outputTokens" => 20}, "older"))
      assert delta.total_tokens == 0
      {:ok, delta} = Operations.reconcile_usage(ctx.table, "issue", id, usage(id, %{"inputTokens" => 200, "outputTokens" => 50}))
      assert delta.total_tokens == 0
      assert :ignored = Operations.reconcile_usage(ctx.table, "issue", id, terminal(id, "older", "completed"))
    end

    before = Operations.snapshot(ctx.table)
    assert before.accounting.terminal_observed == 3
    assert before.recorded.total_tokens == 750
    assert before.recorded.cached_input_tokens == 540
    assert before.recorded.reasoning_output_tokens == 120
    Operations.close(ctx.table)
    {:ok, _} = Operations.open(ctx.path, ctx.table)
    assert Operations.snapshot(ctx.table) == before
    {:ok, delta} = Operations.reconcile_usage(ctx.table, "issue", "one", usage("one", %{"inputTokens" => 220, "outputTokens" => 55}))
    assert delta.total_tokens == 25
    assert Operations.run_usage(ctx.table, "one").total_tokens == 275
    assert Enum.find(Operations.snapshot(ctx.table).activity, &(&1.kind == "completed")).usd_micro == Operations.run_usage(ctx.table, "one").usd_micro
  end

  test "unknown force-termination stays explicit and stale or resumed identities cannot allocate usage", ctx do
    bind(ctx.table, "old", "thread")
    Operations.close(ctx.table)
    {:ok, _} = Operations.open(ctx.path, ctx.table)
    assert Operations.snapshot(ctx.table).accounting.incomplete == 1
    update = usage("thread", %{"inputTokens" => 20, "outputTokens" => 2})
    assert :ignored = Operations.reconcile_usage(ctx.table, "other", "old", update)
    assert :ignored = Operations.reconcile_usage(ctx.table, "issue", "missing", update)
    assert :ignored = Operations.reconcile_usage(ctx.table, "issue", "old", usage("foreign", %{}))
    assert :ignored = Operations.reconcile_usage(ctx.table, "issue", "old", %{event: :account_usage, thread_id: "thread", account_usage: nil})
    assert {:ok, _} = Operations.reconcile_usage(ctx.table, "issue", "old", update)
    bind(ctx.table, "resumed", "thread")
    assert :ignored = Operations.reconcile_usage(ctx.table, "issue", "old", update)
    [{key, run}] = :dets.lookup(ctx.table, {:lineage_run, "resumed"})
    :dets.insert(ctx.table, {key, Map.put(run, :finished_s, System.os_time(:second) - 91 * 86_400)})
    assert :ignored = Operations.reconcile_usage(ctx.table, "issue", "resumed", update)
    Operations.finish_run(ctx.table, "prune", "failed", %{})
    assert :dets.lookup(ctx.table, key) == []
    assert Operations.run_usage(ctx.table, "old").total_tokens == 22
    assert :ignored = Operations.reconcile_usage(nil, "issue", "old", update)
    assert :ignored = Operations.reconcile_usage(:closed_terminal_ledger, "issue", "old", update)
    assert {:error, _} = Operations.bind_accounting(nil, "run", %{})
  end

  test "active turn and cache-write coverage remain separate from terminal watermark", %{table: table} do
    bind(table, "run", "thread")
    Operations.reconcile_usage(table, "issue", "run", %{event: :session_started, thread_id: "thread", turn_id: "turn"}, true)
    {:ok, _} = Operations.reconcile_usage(table, "issue", "run", usage("thread", %{"inputTokens" => 20, "outputTokens" => 2, "cacheWriteInputTokens" => 0}))
    Operations.reconcile_usage(table, "issue", "run", terminal("thread", "turn", "completed"))
    assert Operations.snapshot(table).accounting.terminal_observed == 1
    Operations.reconcile_usage(table, "issue", "run", %{event: :session_started, thread_id: "thread", turn_id: "next"}, true)
    assert Operations.snapshot(table).accounting.incomplete == 1
    assert Enum.all?(Operations.snapshot(table).activity, &(&1.cache_write_status == "observed"))
    assert :ignored = Operations.reconcile_usage(table, "issue", "run", terminal("thread", "turn", "completed"))
    assert Operations.snapshot(table).accounting.incomplete == 1
  end

  test "OTP DOWN and redispatch preserve late accounting without changing the replacement worker", %{table: table, path: path} do
    Operations.close(table)
    {:ok, pid} = Orchestrator.start_link(name: __MODULE__.Orchestrator, operations_path: path, operations_table: table)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    issue = %Issue{id: "issue", identifier: "GH-1", title: "fixture", state: "In Progress"}

    entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: "GH-1",
      issue: issue,
      session_id: nil,
      started_at: DateTime.utc_now(),
      run_id: "old"
    }

    Operations.start_run(table, "old", %{issue_id: issue.id, issue_identifier: issue.identifier})
    :sys.replace_state(pid, &%{&1 | running: %{issue.id => entry}})
    send(pid, {:codex_worker_update, issue.id, "old", %{event: :thread_initialized, timestamp: DateTime.utc_now(), thread_id: "thread", thread_key: {"storage", "thread"}, model: "gpt-6-sol"}})
    send(pid, {:codex_worker_update, issue.id, "old", timed(terminal("thread", "turn", "completed"))})
    send(pid, {:DOWN, entry.ref, :process, self(), :normal})
    assert :sys.get_state(pid).running == %{}
    assert Operations.snapshot(table).accounting.incomplete == 1
    replacement = %{entry | run_id: "new", ref: make_ref()}
    :sys.replace_state(pid, &%{&1 | running: %{issue.id => replacement}})
    before = :sys.get_state(pid)
    payload = usage("thread", %{"inputTokens" => 120, "outputTokens" => 30}) |> timed() |> Map.merge(%{model: "wrong-model", rate_limits: %{danger: true}})
    for _ <- 1..2, do: send(pid, {:codex_worker_update, issue.id, "old", payload})
    send(pid, {:codex_worker_update, issue.id, "old", %{event: :thread_initialized, timestamp: DateTime.utc_now(), thread_id: "forged", thread_key: {"storage", "forged"}}})
    send(pid, {:worker_model_route, issue.id, "old", %{"model" => "wrong-model"}})
    send(pid, {:worker_runtime_info, issue.id, "old", %{workspace_path: "wrong-path"}})
    assert :sys.get_state(pid) == before
    assert Operations.run_usage(table, "old").total_tokens == 150
    assert Operations.run_usage(table, "new").total_tokens == 0
    assert Operations.snapshot(table).accounting.terminal_observed == 1
    assert [%{model: "gpt-6-sol", total_tokens: 150}] = Operations.snapshot(table).by_model
  end

  test "late allocations retain original date model and rates after stale account metadata", %{table: table} do
    bind(table, "run", "thread")
    {:ok, _} = Operations.reconcile_usage(table, "issue", "run", usage("thread", %{"inputTokens" => 100, "outputTokens" => 20}) |> Map.put(:model, "gpt-6-astra"), true)
    account = %{event: :account_usage, thread_id: "thread", model: "gpt-6-sol", account_usage: nil}
    assert :ignored = Operations.reconcile_usage(table, "issue", "run", account, true)
    [{key, run}] = :dets.lookup(table, {:lineage_run, "run"})
    date = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()
    :dets.insert(table, {key, put_in(run.accounting.date, date)})
    update = usage("thread", %{"inputTokens" => 150, "outputTokens" => 30}) |> Map.put(:model, "wrong-model")
    {:ok, delta} = Operations.reconcile_usage(table, "issue", "run", update)
    assert delta.total_tokens == 60
    assert [%{model: "gpt-6-astra", total_tokens: 180}] = Operations.snapshot(table).by_model
    yesterday = Enum.find(Operations.snapshot(table).daily, &(&1.date == date))
    assert yesterday.spend_by_model == %{"gpt-6-astra" => 500}
    assert Operations.snapshot(table).today.total_tokens == 120
    assert Operations.run_usage(table, "run").usd_micro == 1_500
  end

  test "pinned deployed schema supplies cumulative events but no thread-read usage snapshot" do
    schema = Jason.decode!(File.read!("test/fixtures/codex-0.160.0-output-schema.json"))
    assert schema["ThreadTokenUsageUpdatedNotification"]["required"] == ["threadId", "tokenUsage", "turnId"]
    assert schema["ThreadTokenUsage"]["required"] == ["last", "total"]
    refute Map.has_key?(schema["Thread"]["properties"], "tokenUsage")
    assert schema["ThreadReadResponse"]["required"] == ["thread"]
    assert Usage.snapshot(usage("thread", %{"inputTokens" => 1, "outputTokens" => 1})).cache_write_observed == false
  end

  defp bind(table, id, thread) do
    key = {"storage", thread}
    Operations.start_run(table, id, %{issue_id: "issue", issue_identifier: "GH-1"})
    Operations.thread_context(table, key, %{run_id: id})

    Operations.bind_accounting(table, id, %{
      issue_id: "issue",
      thread_id: thread,
      thread_key: key,
      identifier: "GH-1",
      model: "gpt-6-sol",
      date: Date.to_iso8601(Date.utc_today()),
      rates: Operations.rates(nil)
    })
  end

  defp timed(update), do: Map.merge(update, %{event: :notification, timestamp: DateTime.utc_now()})

  defp usage(thread, total, turn \\ "turn"), do: %{payload: %{"method" => "thread/tokenUsage/updated", "params" => %{"threadId" => thread, "turnId" => turn, "tokenUsage" => %{"total" => total}}}}

  defp terminal(thread, turn, status), do: %{payload: %{"method" => "turn/completed", "params" => %{"threadId" => thread, "turn" => %{"id" => turn, "status" => status, "items" => []}}}}
end
