defmodule SymphonyElixir.HelperAccountingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Codex.Usage, Operations}

  setup do
    root = Path.join(System.tmp_dir!(), "crescendo-helper-accounting-#{System.unique_integer([:positive])}")
    table = :helper_accounting_test
    {:ok, ^table} = Operations.open(Path.join(root, "operations.dets"), table)

    on_exit(fn ->
      Operations.close(table)
      File.rm_rf(root)
    end)

    %{table: table, root: root}
  end

  test "synthetic leaf helpers are never refreshed as tracker work" do
    refute Issue.tracker_backed?(%Issue{kind: :helper})
  end

  test "helper tokens and terminal tails have their own run and never complete the parent", %{table: table} do
    at = DateTime.utc_now()

    details = %{
      # The child identity and parent linkage must stay distinct.
      run_id: "child",
      issue_id: "child",
      issue_identifier: "helper-child",
      parent_run_id: "parent",
      parent_issue_id: "lead",
      source_sha: "source",
      model: "gpt-6-luna",
      effort: "max"
    }

    parent = %{run_id: "parent", turn_count: 2, last_codex_timestamp: DateTime.add(at, -60, :second)}
    totals = %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    state = %Orchestrator.State{operations: table, running: %{"lead" => parent}, codex_totals: totals}
    started = %{event: :helper_started, timestamp: at}
    {:noreply, state} = Orchestrator.handle_info({:helper_update, details, started}, state)
    init = %{event: :thread_initialized, timestamp: at, thread_id: "child-thread", thread_key: {:helper, "child-thread"}, model: "gpt-6-luna"}
    {:noreply, state} = Orchestrator.handle_info({:helper_update, details, init}, state)

    update = %{
      event: :notification,
      timestamp: at,
      payload: %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{"threadId" => "child-thread", "turnId" => "turn", "tokenUsage" => %{"total" => %{"inputTokens" => 100, "cachedInputTokens" => 20, "outputTokens" => 10}}}
      }
    }

    {:noreply, state} = Orchestrator.handle_info({:helper_update, details, update}, state)
    finished = %{event: :helper_finished, timestamp: at, status: "completed", reason: %{summary: "done"}}
    {:noreply, state} = Orchestrator.handle_info({:helper_update, details, finished}, state)
    assert state.running["lead"].turn_count == 2
    assert state.running["lead"].last_codex_timestamp == at
    assert state.codex_totals.total_tokens == 110
    assert state.helpers["child"].finished
    assert [{_, %{reason: %{summary: "done"}}}] = :dets.lookup(table, {:lineage_run, "child"})
    assert Operations.run_usage(table, "child").total_tokens == 110
    assert Operations.run_usage(table, "parent").total_tokens == 0
    snapshot = Operations.snapshot(table)
    assert snapshot.helpers.recorded == 1
    assert Enum.any?(snapshot.by_task, &(&1.category == "helper" and &1.model == "gpt-6-luna"))
    assert List.last(snapshot.daily).completed == 0
    # The existing usage reconciler accepts a larger retained terminal tail without replaying parent tokens.
    update = put_in(update.payload["params"]["tokenUsage"]["total"]["outputTokens"], 20)
    assert {:ok, %{total_tokens: 10}} = Operations.reconcile_usage(table, "child", "child", update)
    assert Operations.run_usage(table, "child").total_tokens == 120
  end

  test "expired unverified reports are rejected once and cannot consume every import batch", %{root: root, table: table} do
    directory = Path.join(root, "auxiliary-usage")
    File.mkdir_p!(directory)
    Operations.start_run(table, "parent", %{issue_id: "lead", model: "gpt-6.1-sol"})

    for index <- 1..65 do
      id = Integer.to_string(index, 16) |> String.downcase() |> String.pad_leading(32, "0")

      report = %{
        "run_id" => id,
        "parent_run_id" => "parent",
        "role" => "reviewer",
        "model" => "gpt-6.1-sol",
        "effort" => "max",
        "source_sha" => String.duplicate("b", 40),
        "observed_at_epoch" => System.os_time(:second) - 91 * 86_400
      }

      File.write!(Path.join(directory, id <> ".json"), Jason.encode!(report))
    end

    Operations.import_auxiliary(table, root)
    Operations.import_auxiliary(table, root)
    assert length(:dets.match_object(table, {{:auxiliary_seen, :_}, :_})) == 65
    assert Operations.snapshot(table).external.reports == 0
    Operations.import_auxiliary(table, root)
    assert length(:dets.match_object(table, {{:auxiliary_seen, :_}, :_})) == 65
  end

  test "CLI reviewer imports are parent scoped, idempotent and preserve unknown account debits", %{root: root, table: table} do
    assert Operations.import_auxiliary(nil, root) == Usage.normalize(%{})
    assert Operations.import_auxiliary(table, nil) == Usage.normalize(%{})
    assert Operations.import_auxiliary(table, root) == Usage.normalize(%{})
    directory = Path.join(root, "auxiliary-usage")
    File.mkdir_p!(directory)
    Operations.start_run(table, "parent", %{issue_id: "lead", issue_identifier: "GH-1", kind: :issue, model: "gpt-6.1-sol"})

    report = %{
      "run_id" => String.duplicate("a", 32),
      "parent_run_id" => "parent",
      "role" => "reviewer",
      "model" => "gpt-6.1-sol",
      "effort" => "max",
      "source_sha" => String.duplicate("b", 40),
      "thread_id" => "review-thread",
      "usage" => %{"input_tokens" => 100, "cached_input_tokens" => 20, "output_tokens" => 30},
      "terminal_event" => "turn.completed",
      "accounting_status" => "terminal_observed",
      "observed_at_epoch" => DateTime.to_unix(DateTime.add(DateTime.utc_now(), -86_400, :second)),
      "elapsed_seconds" => 42.5
    }

    File.write!(Path.join(directory, report["run_id"] <> ".json"), Jason.encode!(report))
    File.write!(Path.join(directory, String.duplicate("c", 32) <> ".json"), Jason.encode!(%{report | "run_id" => String.duplicate("c", 32), "parent_run_id" => "another-project"}))
    File.write!(Path.join(directory, String.duplicate("d", 32) <> ".json"), "invalid json")
    assert %{total_tokens: 0} = Operations.import_auxiliary(table, root)
    assert Operations.import_auxiliary(table, root).total_tokens == 0
    snapshot = Operations.snapshot(table)
    assert snapshot.account_usage.estimated_credits_micros == nil
    assert List.last(snapshot.daily).completed == 0
    assert snapshot.external.reported_usage.total_tokens == 130
    assert snapshot.external.attribution == "unverified_cli_report"
    assert snapshot.external.reports == 1
    [observation] = snapshot.external.observations
    assert observation.parent_run_id == "parent"
    assert observation.source_sha == report["source_sha"]
    assert observation.accounting_date == Date.to_iso8601(Date.add(Date.utc_today(), -1))
    assert observation.elapsed_seconds == 42.5
    assert Operations.spend_today(table) == 0
    assert Operations.run_usage(table, report["run_id"]).total_tokens == 0
    assert :dets.lookup(table, {:lineage_run, report["run_id"]}) == []
    # Replay after the cursor is lost retains the first immutable observation.
    :dets.delete(table, {:auxiliary_seen, report["run_id"] <> ".json"})
    File.write!(Path.join(directory, report["run_id"] <> ".json"), Jason.encode!(put_in(report["usage"]["output_tokens"], 999)))
    Operations.import_auxiliary(table, root)
    assert Operations.snapshot(table).external.reported_usage.total_tokens == 130
  end
end
