defmodule SymphonyElixir.ReportDeliveryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{GitHub.Client, Operations}

  defmodule DeliveryClient do
    def fetch_issues_by_states(_), do: {:ok, []}
    def fetch_issues_by_ids(_), do: {:ok, []}
    def fetch_open_pull_requests, do: {:ok, []}

    def fetch_delivery_observation(id) do
      {root, fixtures} = Agent.get(__MODULE__, & &1)

      request = fn "GET", path, _params, nil, _settings ->
        {:ok, %{status: 200, body: Map.fetch!(fixtures, path)}}
      end

      Client.fetch_delivery_observation(id,
        tracker_settings: %{provider: %{"repo" => "ahammer/metalrain", "token" => "test-token"}},
        request_fun: request,
        evidence_root: root
      )
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "report-delivery-#{System.unique_integer([:positive])}")
    path = Path.join(root, "operations.dets")
    table = :report_delivery_test
    {:ok, ^table} = Operations.open(path, table)

    on_exit(fn ->
      Operations.close(table)
      File.rm_rf(root)
      Application.delete_env(:symphony_elixir, :github_client_module)
    end)

    %{root: root, path: path, table: table}
  end

  test "three canonical report closures retain unique workers through OTP inventory and restart", context do
    %{root: root, path: path, table: table} = context

    fixtures =
      Enum.reduce([1243, 1244, 1189], %{}, fn number, acc ->
        id = to_string(number)
        run_id = "worker-#{id}"
        owner = %{1243 => 1233, 1244 => 1234, 1189 => 1188}[number]
        handoff = %{"owner" => owner, "change" => "prerequisite", "evidence" => number, "scope" => "bounded report; original unmet criteria remain"}

        Operations.start_run(table, run_id, %{
          issue_id: id,
          issue_identifier: "GH-#{id}",
          issue_url: "https://github.com/ahammer/metalrain/issues/#{id}",
          kind: :issue,
          item_attempt: 2,
          delivery_key: "original-budget-#{id}",
          handoff: handoff
        })

        {issue, timeline, _attempt} = receipt(root, number, run_id)
        Operations.finish_run(table, run_id, "completed", %{})
        Map.merge(acc, %{"/repos/ahammer/metalrain/issues/#{id}" => issue, "/repos/ahammer/metalrain/issues/#{id}/timeline" => timeline})
      end)

    budget = %{item_attempts: %{"1233" => 2, "1234" => 1, "1188" => 2}, handoff_owners: %{"original-budget-1243" => "1243", "original-budget-1244" => "1244", "original-budget-1189" => "1189"}}
    Operations.save_autopilot_state(table, budget)
    Operations.close(table)
    agent_start = {Agent, :start_link, [fn -> {root, fixtures} end, [name: DeliveryClient]]}
    start_supervised!(%{id: DeliveryClient, start: agent_start})
    Application.put_env(:symphony_elixir, :github_client_module, DeliveryClient)

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: github
      provider:
        repo: ahammer/metalrain
        token: test-token
      active_states: [open]
      terminal_states: [closed]
    ---
    Work on {{ issue.identifier }}.
    """)

    WorkflowStore.force_reload()
    supervisor = Module.concat(__MODULE__, TaskSupervisor)
    orchestrator = Module.concat(__MODULE__, Orchestrator)
    start_supervised!({Task.Supervisor, name: supervisor})
    opts = [name: orchestrator, task_supervisor: supervisor, operations_path: path, operations_table: table]
    start_supervised!({Orchestrator, opts})
    associations = await_reports(orchestrator)

    assert length(associations) == 3

    for association <- associations do
      assert association.disposition == "repository_reported_verification"
      assert association.acceptance_proof == "repository_reported"
      assert association.delivery_kind == "report_only"
      assert association.sources == []
      assert [%{run_id: run_id, item_attempt: 2, delivery_key: key}] = association.attempts
      assert [%{run_id: ^run_id, item_attempt: 2, source_sha: sha}] = association.report_verifications
      assert sha == String.duplicate("a", 40)
      assert key == "original-budget-#{association.issue_id}"
      assert association.canonical_owner == %{"1243" => "1233", "1244" => "1234", "1189" => "1188"}[association.issue_id]
      assert association.handoff["scope"] == "bounded report; original unmet criteria remain"
      refute association.canonical_outcome_complete
      assert association.verified_cost == nil
      assert association.verified_latency == nil
      assert association.helper_usage_coverage == "unknown"
    end

    stop_supervised!(SymphonyElixir.Orchestrator)
    start_supervised!({Orchestrator, opts})
    assert await_reports(orchestrator) == associations
    assert Orchestrator.snapshot(orchestrator, 5_000).operations.delivery_metrics.verified_deliveries == nil
    assert Orchestrator.snapshot(orchestrator, 5_000).operations.external.reports == 0
    assert :sys.get_state(orchestrator).autopilot.item_attempts == budget.item_attempts
    assert :sys.get_state(orchestrator).autopilot.handoff_owners == budget.handoff_owners
  end

  test "canonical receipts reject unapproved, wrong-source, wrong-issue and incomplete evidence", %{root: root} do
    {issue, timeline, attempt} = receipt(root, 42, "worker")
    assert {:ok, %{report_verifications: [_]}} = observation(root, issue, timeline)

    for name <- ~w(closure-intent input review review-usage delivery-source adjudicated-failures hosted-checks review-input-digest) do
      file = Path.join(attempt, name <> ".json")
      original = File.read!(file)

      for invalid <- ["null", "[]", "{", "{}"] do
        File.write!(file, invalid)
        assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline), name
      end

      File.rm!(file)
      assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline), name
      File.write!(file, original)
    end

    for {name, changes} <- [
          {"review", %{"approved" => false}},
          {"review", %{"head" => String.duplicate("d", 40)}},
          {"review", %{"base" => String.duplicate("d", 40)}},
          {"review", %{"findings" => ["repair required"]}},
          {"review", %{"missing_evidence" => ["runtime"]}},
          {"review", %{"summary" => " "}},
          {"closure-intent", %{"issue" => 43}},
          {"closure-intent", %{"scope" => ["different", "scope"]}},
          {"closure-intent", %{"retirement" => true}},
          {"input", %{"head" => String.duplicate("d", 40)}},
          {"input", %{"issue" => %{issue | "html_url" => "https://github.com/foreign/repo/issues/42"}}},
          {"input", %{"issue" => %{issue | "number" => 43}}},
          {"delivery-source", %{"clean_after" => false}},
          {"adjudicated-failures", %{"head" => String.duplicate("d", 40)}},
          {"review-input-digest", %{"after" => "changed"}},
          {"review-input-digest", %{"new_own_issue_paths" => ["modified"]}},
          {"hosted-checks", %{"statuses" => %{"total_count" => 1, "state" => "failure"}}},
          {"hosted-checks", %{"checks" => [%{"status" => "in_progress"}]}},
          {"hosted-checks", %{"checks" => [nil]}},
          {"review-usage", %{"work_item" => "GH-43"}},
          {"review-usage", %{"role" => "planner"}},
          {"review-usage", %{"source_sha" => String.duplicate("d", 40)}},
          {"review-usage", %{"terminal_event" => "turn.failed"}},
          {"review-usage", %{"parent_run_id" => nil}},
          {"review-usage", %{"observed_at_epoch" => nil}}
        ] do
      file = Path.join(attempt, name <> ".json")
      original = File.read!(file)
      File.write!(file, Jason.encode!(Map.merge(Jason.decode!(original), changes)))
      assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline), inspect({name, changes})
      File.write!(file, original)
    end

    file = Path.join(attempt, "acceptance.md")
    original = File.read!(file)

    for invalid <- ["unrelated source", <<255>>, String.duplicate("x", 131_073)] do
      File.write!(file, invalid)
      assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline)
    end

    File.rm!(file)
    File.ln_s!(Path.join(attempt, "review.json"), file)
    assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline)
    File.rm!(file)
    File.write!(file, original)
  end

  test "mutable annotations cannot replace unique canonical receipts and observed closure", %{root: root} do
    {issue, [closed, comment] = timeline, attempt} = receipt(root, 42, "worker")
    second = %{comment | "body" => String.replace(comment["body"], String.duplicate("b", 32), String.duplicate("d", 32))}

    for events <- [
          [closed],
          [comment],
          [closed, second],
          [closed, comment, second],
          [Map.put(closed, "created_at", "2020-01-01T00:00:00Z"), comment],
          [closed, %{comment | "body" => String.replace(comment["body"], "issue-42/", "issue-43/")}],
          [closed, %{comment | "body" => String.replace(comment["body"], "Reviewed current main", "Completed successfully on")}],
          [closed, %{comment | "body" => String.replace(comment["body"], "issue-42/", "issue-42/../")}]
        ] do
      assert {:ok, %{report_verifications: []}} = observation(root, issue, events)
    end

    assert {:ok, %{report_verifications: [_]}} = observation(root, issue, timeline ++ [comment])
    reopened = %{"event" => "reopened", "created_at" => DateTime.utc_now() |> DateTime.add(10) |> DateTime.to_iso8601()}
    assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline ++ [reopened])
    assert {:ok, %{report_verifications: []}} = observation(nil, issue, timeline)
    assert {:ok, %{report_verifications: []}} = observation(root, %{issue | "state" => "open"}, timeline)
    assert {:ok, %{report_verifications: []}} = observation(root, %{issue | "state_reason" => "not_planned"}, timeline)
    foreign = %{issue | "html_url" => "https://github.com/foreign/repo/issues/42"}
    assert {:ok, %{report_verifications: []}} = observation(root, foreign, timeline)
    assert {:error, :github_wrong_issue} = observation(root, %{issue | "number" => 43}, timeline, "42")

    # A prior rejected receipt is retained for repairs but cannot override the exact approved reference.
    rejected = Path.join(Path.dirname(attempt), String.duplicate("e", 32))
    File.mkdir_p!(rejected)
    File.write!(Path.join(rejected, "review.json"), Jason.encode!(%{"approved" => false}))
    assert {:ok, %{report_verifications: [_]}} = observation(root, issue, timeline)
    # Symlinked directories never import receipts from another location.
    File.rename!(attempt, attempt <> "-original")
    File.ln_s!(attempt <> "-original", attempt)
    assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline)
  end

  test "report ownership rejects ambiguous or foreign workers and successful turns alone", %{root: root, table: table} do
    cases = [:ambiguous, :wrong_run, :wrong_issue, :foreign_repo, :historical, :outside, :no_attempt, :no_receipts]

    for {invalid, number} <- Enum.with_index(cases, 1) do
      id = to_string(number)
      run_id = "worker-#{id}"
      details = %{issue_id: id, issue_identifier: "GH-#{id}", issue_url: "https://github.com/ahammer/metalrain/issues/#{id}", kind: :issue, item_attempt: 1}
      Operations.start_run(table, run_id, details)
      {issue, timeline, attempt} = receipt(root, number, run_id)
      [{key, run}] = :dets.lookup(table, {:lineage_run, run_id})

      case invalid do
        :ambiguous -> Operations.start_run(table, "other-#{id}", details)
        :wrong_run -> change_json(attempt, "review-usage", %{"parent_run_id" => "missing"})
        :wrong_issue -> :dets.insert(table, {key, %{run | issue_id: "other"}})
        :foreign_repo -> :dets.insert(table, {key, %{run | issue_url: "https://github.com/foreign/repo/issues/#{id}"}})
        :historical -> :dets.insert(table, {key, %{run | delivery_tracking: false}})
        :outside -> :dets.insert(table, {key, %{run | started_s: run.started_s + 30}})
        :no_attempt -> :dets.insert(table, {key, Map.delete(run, :item_attempt)})
        :no_receipts -> File.rm!(Path.join(attempt, "review.json"))
      end

      {:ok, observed} = observation(root, issue, timeline)
      Operations.observe_delivery(table, observed, "crescendo")
      associations = Operations.snapshot(table).delivery_metrics.issue_associations

      case Enum.find(associations, &(&1.issue_id == id)) do
        nil ->
          assert invalid in [:wrong_issue, :historical]

        association ->
          assert association.disposition == "unknown_acceptance"
          assert association.report_verifications == []
      end
    end
  end

  test "report replay keeps accounting separate and parent acceptance unknown through restart", %{root: root, table: table, path: path} do
    details = %{
      issue_id: "42",
      issue_identifier: "GH-42",
      issue_url: "https://github.com/ahammer/metalrain/issues/42",
      kind: :issue,
      item_attempt: 2,
      handoff: %{"owner" => 40, "change" => "partial_delivery", "evidence" => 41, "scope" => "bounded report; all unmet parent criteria"}
    }

    Operations.start_run(table, "worker", details)
    Operations.start_run(table, "parent", %{details | issue_id: "40", issue_identifier: "GH-40", issue_url: "https://github.com/ahammer/metalrain/issues/40", handoff: nil})
    {issue, timeline, attempt} = receipt(root, 42, "worker")
    # Real reviewer timestamps have subsecond precision, while native run windows have seconds.
    change_json(attempt, "review-usage", %{"observed_at_epoch" => System.os_time(:second) + 0.5})
    Operations.usage(table, "worker", "gpt-6-sol", %{input_tokens: 100, output_tokens: 10, total_tokens: 110})
    Operations.finish_run(table, "worker", "completed", %{})
    usage = Jason.decode!(File.read!(Path.join(attempt, "review-usage.json")))
    auxiliary = Path.join(root, "auxiliary-usage")
    File.mkdir_p!(auxiliary)
    File.write!(Path.join(auxiliary, usage["run_id"] <> ".json"), Jason.encode!(usage))
    before = Operations.spend_today(table)
    {:ok, observed} = observation(root, issue, timeline)
    parent = %{observed | issue: %{observed.issue | id: "40", identifier: "GH-40", url: "https://github.com/ahammer/metalrain/issues/40"}, report_verifications: []}
    Operations.observe_delivery(table, parent, "crescendo")

    for _ <- 1..2 do
      Operations.import_auxiliary(table, root)
      Operations.observe_delivery(table, observed, "crescendo")
      Operations.close(table)
      {:ok, ^table} = Operations.open(path, table)
    end

    snapshot = Operations.snapshot(table)
    assert snapshot.external.reports == 1
    assert snapshot.external.reported_usage.total_tokens == 11
    assert snapshot.recorded.total_tokens == 110
    assert Operations.spend_today(table) == before
    association = Enum.find(snapshot.delivery_metrics.issue_associations, &(&1.issue_id == "42"))
    assert association.disposition == "accepted_reduced_scope"
    assert [%{run_id: "worker", item_attempt: 2}] = association.report_verifications
    assert association.sources == []
    refute association.canonical_outcome_complete
    assert Enum.find(snapshot.delivery_metrics.issue_associations, &(&1.issue_id == "40")).disposition == "unknown_acceptance"

    # Removing the mutable heading or receipt after retention cannot rewrite lineage.
    File.rm!(Path.join(attempt, "review.json"))
    edited = %{observed | report_verifications: []}
    Operations.observe_delivery(table, edited, "crescendo")
    assert Enum.find(Operations.snapshot(table).delivery_metrics.issue_associations, &(&1.issue_id == "42")) == association
    reopened = %{edited | issue: %{edited.issue | state: "open", updated_at: DateTime.add(edited.issue.updated_at, 10)}, closed_at: nil}
    Operations.observe_delivery(table, reopened, "crescendo")
    assert Enum.find(Operations.snapshot(table).delivery_metrics.issue_associations, &(&1.issue_id == "42")).disposition == "open"
    reclosed_at = DateTime.add(edited.issue.updated_at, 20)
    reclosed = %{edited | issue: %{edited.issue | updated_at: reclosed_at}, closed_at: DateTime.to_iso8601(reclosed_at)}
    Operations.observe_delivery(table, reclosed, "crescendo")
    assert Enum.find(Operations.snapshot(table).delivery_metrics.issue_associations, &(&1.issue_id == "42")).disposition == "unknown_acceptance"
    # Expiration of retained attempts also expires report receipts.
    for run_id <- ["worker", "parent"] do
      [{key, run}] = :dets.lookup(table, {:lineage_run, run_id})
      :dets.insert(table, {key, Map.put(run, :finished_s, 0)})
    end

    Operations.start_run(table, "prune", %{kind: :research})
    Operations.finish_run(table, "prune", "completed", %{})
    assert :dets.match_object(table, {{:lineage_evidence, "issue_report", :_}, :_}) == []
  end

  test "a delayed old closure cannot bind report proof to a newer closure", %{root: root, table: table} do
    Operations.start_run(table, "worker", %{issue_id: "42", issue_identifier: "GH-42", issue_url: "https://github.com/ahammer/metalrain/issues/42", kind: :issue, item_attempt: 1})
    {issue, timeline, _} = receipt(root, 42, "worker")
    {:ok, observed} = observation(root, issue, timeline)
    at = DateTime.add(observed.issue.updated_at, 30)
    newer = %{observed | issue: %{observed.issue | updated_at: at}, closed_at: DateTime.to_iso8601(at), report_verifications: []}
    Operations.observe_delivery(table, newer, "crescendo")
    Operations.observe_delivery(table, observed, "crescendo")
    [association] = Operations.snapshot(table).delivery_metrics.issue_associations
    assert association.disposition == "unknown_acceptance"
    assert [%{closed_at: original}] = association.report_verifications
    assert original == observed.closed_at
  end

  defp observation(root, issue, timeline, id \\ nil) do
    request = fn "GET", path, _params, nil, _settings ->
      body = if String.ends_with?(path, "timeline"), do: timeline, else: issue
      {:ok, %{status: 200, body: body}}
    end

    Client.fetch_delivery_observation(id || to_string(issue["number"]),
      tracker_settings: %{provider: %{"repo" => "ahammer/metalrain", "token" => "test-token"}},
      request_fun: request,
      evidence_root: root
    )
  end

  defp change_json(attempt, name, changes) do
    path = Path.join(attempt, name <> ".json")
    File.write!(path, Jason.encode!(Map.merge(Jason.decode!(File.read!(path)), changes)))
  end

  defp await_reports(orchestrator) do
    assert Enum.any?(1..80, fn _ ->
             associations = Orchestrator.snapshot(orchestrator, 5_000).operations.delivery_metrics.issue_associations
             if length(associations) != 3, do: Process.sleep(25)
             length(associations) == 3
           end)

    Orchestrator.snapshot(orchestrator, 5_000).operations.delivery_metrics.issue_associations
  end

  defp receipt(root, number, run_id) do
    sha = String.duplicate("a", 40)
    receipt_id = String.duplicate("b", 32)
    attempt = Path.join([root, "issue-#{number}", sha, receipt_id])
    File.mkdir_p!(attempt)
    at = DateTime.to_iso8601(DateTime.utc_now())

    issue = %{
      "number" => number,
      "html_url" => "https://github.com/ahammer/metalrain/issues/#{number}",
      "title" => "Bounded report",
      "body" => "Unmet parent criteria remain",
      "state" => "closed",
      "state_reason" => "completed",
      "closed_at" => at,
      "updated_at" => at,
      "labels" => []
    }

    input = %{"issue" => %{issue | "state" => "open"}, "head" => sha}
    intent = %{"issue" => number, "head" => sha, "scope" => [issue["title"], issue["body"]], "retirement" => false}
    review = %{"base" => sha, "head" => sha, "approved" => true, "summary" => "Exact bounded report accepted", "findings" => [], "missing_evidence" => [], "preexisting" => []}

    usage = %{
      "run_id" => Integer.to_string(number, 16) |> String.downcase() |> String.pad_leading(32, "0"),
      "parent_run_id" => run_id,
      "work_item" => "GH-#{number}",
      "source_sha" => sha,
      "role" => "reviewer",
      "terminal_event" => "turn.completed",
      "observed_at_epoch" => System.os_time(:second),
      "model" => "gpt-6.1-sol",
      "effort" => "max",
      "thread_id" => "review-thread-#{number}",
      "accounting_status" => "terminal_observed",
      "usage" => %{"input_tokens" => 10, "cached_input_tokens" => 2, "output_tokens" => 1}
    }

    for {name, value} <- [
          {"input", input},
          {"closure-intent", intent},
          {"review", review},
          {"review-usage", usage},
          {"delivery-source", %{"base" => sha, "head" => sha, "clean_after" => true}},
          {"adjudicated-failures", %{"base" => sha, "head" => sha, "failures" => []}},
          {"hosted-checks", %{"statuses" => %{"total_count" => 0}, "checks" => []}},
          {"review-input-digest", %{"before" => "digest", "after" => "digest", "new_own_issue_paths" => []}}
        ] do
      File.write!(Path.join(attempt, name <> ".json"), Jason.encode!(value))
    end

    File.write!(Path.join(attempt, "acceptance.md"), "Exact source #{sha}; bounded report accepted; parent unmet.")

    annotation =
      "<!-- symphony-workpad -->\n\n## Symphony existing-implementation verification\n" <>
        "Reviewed current main `#{sha}`. Retained evidence: `issue-#{number}/#{sha}/#{receipt_id}`."

    {issue, [%{"event" => "closed", "created_at" => at}, %{"event" => "commented", "body" => annotation}], attempt}
  end
end
