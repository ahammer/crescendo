defmodule SymphonyElixir.ReportDeliveryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{GitHub.Client, GitHub.ReportCompletion, Operations}

  defmodule DeliveryClient do
    def fetch_issues_by_states(_), do: {:ok, []}
    def fetch_issues_by_ids(_), do: {:ok, []}
    def fetch_open_pull_requests, do: {:ok, []}

    defp fixture_body(fixtures, path) do
      if String.contains?(path, "/comments/") do
        fixtures
        |> Map.values()
        |> Enum.filter(&is_list/1)
        |> List.flatten()
        |> Enum.map(& &1["fixture_anchor"])
        |> Enum.find(fn anchor -> anchor && String.ends_with?(path, "/#{anchor["id"]}") end)
      else
        value = Map.fetch!(fixtures, path)
        if is_list(value), do: authenticate_timeline(value), else: value
      end
    end

    defp authenticate_timeline(rows) do
      anchors = rows |> Enum.flat_map(&List.wrap(&1["fixture_anchor"])) |> Enum.uniq_by(& &1["id"])
      rows ++ Enum.map(anchors, &Map.put(&1, "event", "commented"))
    end

    def fetch_delivery_observation(id) do
      {root, fixtures} = Agent.get(__MODULE__, & &1)

      request = fn "GET", path, _params, nil, _settings ->
        {:ok, %{status: 200, body: fixture_body(fixtures, path)}}
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
    %{root: root, table: table} = context

    fixtures =
      Enum.reduce([1243, 1244, 1189], %{}, fn number, acc ->
        id = to_string(number)
        run_id = "worker-#{id}"
        owner = %{1243 => 1233, 1244 => 1234, 1189 => 1188}[number]

        handoff = %{
          "owner" => owner,
          "change" => "prerequisite",
          "evidence" => number,
          "scope" => "bounded report; original unmet criteria remain"
        }

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
        {:ok, updated, _} = DateTime.from_iso8601(issue["updated_at"])

        unknown = %Issue{
          id: id,
          identifier: "GH-#{id}",
          title: issue["title"],
          description: issue["body"],
          url: issue["html_url"],
          state: "closed",
          state_reason: "completed",
          updated_at: updated
        }

        # Existing unknown observations gain their scope fingerprint even when GitHub's timestamp is unchanged.
        legacy = %{issue: unknown, closed_at: issue["closed_at"], sources: [], evidence_source: "github"}
        Operations.observe_delivery(table, legacy, "crescendo")

        Map.merge(acc, %{
          "/repos/ahammer/metalrain/issues/#{id}" => issue,
          "/repos/ahammer/metalrain/issues/#{id}/timeline" => timeline
        })
      end)

    budget = %{
      item_attempts: %{"1233" => 2, "1234" => 1, "1188" => 2},
      handoff_owners: %{
        "original-budget-1243" => "1243",
        "original-budget-1244" => "1244",
        "original-budget-1189" => "1189"
      }
    }

    Operations.save_autopilot_state(table, budget)
    {orchestrator, opts} = start_inventory(context, fixtures)
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

      assert association.canonical_owner ==
               %{"1243" => "1233", "1244" => "1234", "1189" => "1188"}[association.issue_id]

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

  test "retained production timing shapes stay unknown through inventory replay and restart", context do
    %{root: root, table: table} = context

    shapes = [
      {1245, 1_791_538_687.429, "2026-10-09T09:35:57Z", 506.806},
      {1247, 1_791_535_566.545, "2026-10-09T08:43:55Z", 658.443},
      {1168, 1_791_544_289.623, "2026-10-09T11:09:18Z", 533.280}
    ]

    # Shift published times together to keep the same ordering inside native history retention.
    offset = System.os_time(:second) - 60 - 1_791_544_289

    fixtures =
      Enum.reduce(shapes, %{}, fn {number, observed_s, closed_at, elapsed}, acc ->
        observed_s = observed_s + offset
        {:ok, closure, _} = DateTime.from_iso8601(closed_at)
        closed_at = closure |> DateTime.add(offset) |> DateTime.to_iso8601()
        id = to_string(number)
        run_id = "scrubbed-worker-#{id}"

        Operations.start_run(table, run_id, %{
          issue_id: id,
          issue_identifier: "GH-#{id}",
          issue_url: "https://github.com/ahammer/metalrain/issues/#{id}",
          kind: :issue,
          item_attempt: 2,
          delivery_key: "original-budget-#{id}"
        })

        {issue, [closed, comment], attempt} = receipt(root, number, run_id)
        issue = %{issue | "closed_at" => closed_at, "updated_at" => closed_at}
        closed = %{closed | "created_at" => closed_at}

        change_json(attempt, "review-usage", %{
          "observed_at_epoch" => observed_s,
          "codex_version" => "codex-cli 0.160.0",
          "elapsed_seconds" => elapsed,
          "account_credits" => nil,
          "account_usd" => nil,
          "attribution" => "cli_terminal_event"
        })

        File.write!(
          Path.join(attempt, "review.timing.json"),
          Jason.encode!(%{
            "elapsed_s" => elapsed,
            "exit" => 0,
            "attempt" => "scrubbed-attempt",
            "command" => ["scrubbed-review"],
            "lease_records" => [],
            "lease_held_s" => 0,
            "lease_waited_s" => 0
          })
        )

        Operations.finish_run(table, run_id, "completed", %{})
        [{key, run}] = :dets.lookup(table, {:lineage_run, run_id})
        :dets.insert(table, {key, %{run | started_s: trunc(observed_s) - 900, finished_s: trunc(observed_s) + 60}})
        # #1168 also carries an older closed/reopened lifecycle before its final completed closure.
        earlier =
          if number == 1168 do
            Enum.map(
              [{"closed", "2026-10-05T01:43:20Z"}, {"reopened", "2026-10-05T09:24:58Z"}],
              fn {event, at} ->
                {:ok, at, _} = DateTime.from_iso8601(at)
                %{"event" => event, "created_at" => at |> DateTime.add(offset) |> DateTime.to_iso8601()}
              end
            )
          else
            []
          end

        timeline = earlier ++ [closed, comment]

        File.rm!(Path.join(attempt, "review-completion.json"))
        File.rm!(Path.join(attempt, "closure-ordering.json"))

        assert {:ok, %{report_verifications: [], report_rejection: "missing-completion"}} =
                 observation(root, issue, timeline)

        {:ok, closure, _} = DateTime.from_iso8601(closed_at)
        assert observed_s > DateTime.to_unix(closure)

        Map.merge(acc, %{
          "/repos/ahammer/metalrain/issues/#{id}" => issue,
          "/repos/ahammer/metalrain/issues/#{id}/timeline" => timeline
        })
      end)

    budget = %{item_attempts: %{"1245" => 2, "1247" => 2, "1168" => 2}}
    Operations.save_autopilot_state(table, budget)
    {orchestrator, opts} = start_inventory(context, fixtures)
    associations = await_reports(orchestrator)

    for association <- associations do
      assert association.disposition == "unknown_acceptance"
      assert association.report_verifications == []
      assert association.sources == []
      assert association.verified_cost == nil
      assert association.verified_latency == nil
      assert association.helper_usage_coverage == "unknown"
      assert [%{item_attempt: 2, delivery_key: key}] = association.attempts
      assert key == "original-budget-#{association.issue_id}"
    end

    stop_supervised!(SymphonyElixir.Orchestrator)
    start_supervised!({Orchestrator, opts})
    assert await_reports(orchestrator) == associations
    assert :sys.get_state(orchestrator).autopilot.item_attempts == budget.item_attempts
    assert Orchestrator.snapshot(orchestrator, 5_000).operations.external.reports == 0
  end

  test "canonical receipts reject unapproved, wrong-source, wrong-issue and incomplete evidence", %{root: root} do
    {issue, timeline, attempt} = receipt(root, 42, "worker")
    assert {:ok, %{report_verifications: [_]}} = observation(root, issue, timeline)

    for name <-
          ~w(closure-intent input review review-usage delivery-source adjudicated-failures hosted-checks review-input-digest) do
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
          {"adjudicated-failures", %{"failures" => [nil]}},
          {"review", %{"preexisting" => [nil]}},
          {"review-input-digest", %{"after" => "changed"}},
          {"review-input-digest", %{"new_own_issue_paths" => ["modified"]}},
          {"hosted-checks", %{"statuses" => %{"total_count" => 1, "state" => "failure"}}},
          {"hosted-checks", %{"checks" => [%{"status" => "in_progress"}]}},
          {"hosted-checks", %{"checks" => [nil]}},
          {"review-usage", %{"work_item" => "GH-43"}},
          {"review-usage", %{"role" => "planner"}},
          {"review-usage", %{"source_sha" => String.duplicate("d", 40)}},
          {"review-usage", %{"terminal_event" => "turn.failed"}},
          {"review-usage", %{"parent_run_id" => nil}}
        ] do
      file = Path.join(attempt, name <> ".json")
      original = File.read!(file)
      File.write!(file, Jason.encode!(Map.merge(Jason.decode!(original), changes)))
      assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline), inspect({name, changes})
      File.write!(file, original)
    end

    entry = %{
      "check" => "workspace-tests",
      "failure" => "tracked_failure",
      "issue" => 99,
      "base_evidence" => "issue-42/#{String.duplicate("a", 40)}/baseline.log"
    }

    adjudicated =
      entry
      |> Map.delete("issue")
      |> Map.merge(%{"tracking_issue" => 99, "classification" => "equivalent-main-failure"})

    change_json(attempt, "review", %{"preexisting" => [entry]})
    change_json(attempt, "adjudicated-failures", %{"failures" => [adjudicated]})
    timeline = reseal(attempt, timeline)
    assert {:ok, %{report_verifications: [_]}} = observation(root, issue, timeline)

    for invalid <- [%{adjudicated | "tracking_issue" => 98}, %{adjudicated | "classification" => "unverified"}, nil] do
      change_json(attempt, "adjudicated-failures", %{"failures" => [invalid]})
      assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline)
    end

    change_json(attempt, "review", %{"preexisting" => [entry, entry]})
    change_json(attempt, "adjudicated-failures", %{"failures" => [adjudicated, adjudicated]})
    assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline)
    change_json(attempt, "review", %{"preexisting" => []})
    change_json(attempt, "adjudicated-failures", %{"failures" => []})

    timeline = reseal(attempt, timeline)
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

  test "hosted check receipts must identify the exact reviewed source", %{root: root} do
    {issue, timeline, attempt} = receipt(root, 42, "worker")
    sha = String.duplicate("a", 40)
    statuses = %{"total_count" => 1, "state" => "success", "sha" => sha}
    check = %{"head_sha" => sha, "status" => "completed", "conclusion" => "success"}
    hosted = %{"statuses" => statuses, "checks" => [check]}
    change_json(attempt, "hosted-checks", hosted)
    timeline = reseal(attempt, timeline)
    assert {:ok, %{report_verifications: [_]}} = observation(root, issue, timeline)

    for invalid <- [
          %{hosted | "statuses" => %{statuses | "sha" => String.duplicate("d", 40)}},
          %{hosted | "checks" => [%{check | "head_sha" => String.duplicate("d", 40)}]},
          %{hosted | "statuses" => Map.delete(statuses, "sha")},
          %{hosted | "checks" => [Map.delete(check, "head_sha")]}
        ] do
      change_json(attempt, "hosted-checks", invalid)
      assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline)
    end
  end

  test "mutable annotations cannot replace unique canonical receipts and observed closure", %{root: root} do
    {issue, [closed, comment] = timeline, attempt} = receipt(root, 42, "worker")

    second = %{
      comment
      | "body" => String.replace(comment["body"], String.duplicate("b", 32), String.duplicate("d", 32))
    }

    for events <- [
          [closed],
          [Map.delete(closed, "id"), comment],
          [Map.put(closed, "id", "invalid"), comment],
          [comment],
          [closed, second],
          [closed, comment, second],
          [Map.put(closed, "created_at", "2020-01-01T00:00:00Z"), comment],
          [closed, %{comment | "body" => String.replace(comment["body"], "issue-42/", "issue-43/")}],
          [
            closed,
            %{comment | "body" => String.replace(comment["body"], "Reviewed current main", "Completed successfully on")}
          ],
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

      details = %{
        issue_id: id,
        issue_identifier: "GH-#{id}",
        issue_url: "https://github.com/ahammer/metalrain/issues/#{id}",
        kind: :issue,
        item_attempt: 1
      }

      Operations.start_run(table, run_id, details)
      {issue, timeline, attempt} = receipt(root, number, run_id)
      [{key, run}] = :dets.lookup(table, {:lineage_run, run_id})

      case invalid do
        :ambiguous ->
          other = "other-#{id}"
          Operations.start_run(table, other, details)
          [{other_key, other_run}] = :dets.lookup(table, {:lineage_run, other})
          :dets.insert(table, {other_key, %{other_run | started_s: run.started_s}})

        :wrong_run ->
          change_json(attempt, "review-usage", %{"parent_run_id" => "missing"})

        :wrong_issue ->
          :dets.insert(table, {key, %{run | issue_id: "other"}})

        :foreign_repo ->
          :dets.insert(table, {key, %{run | issue_url: "https://github.com/foreign/repo/issues/#{id}"}})

        :historical ->
          :dets.insert(table, {key, %{run | delivery_tracking: false}})

        :outside ->
          :dets.insert(table, {key, %{run | started_s: run.started_s + 30}})

        :no_attempt ->
          :dets.insert(table, {key, Map.delete(run, :item_attempt)})

        :no_receipts ->
          File.rm!(Path.join(attempt, "review.json"))
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

  test "report replay keeps accounting separate and parent acceptance unknown through restart", %{
    root: root,
    table: table,
    path: path
  } do
    details = %{
      issue_id: "42",
      issue_identifier: "GH-42",
      issue_url: "https://github.com/ahammer/metalrain/issues/42",
      kind: :issue,
      item_attempt: 2,
      handoff: %{
        "owner" => 40,
        "change" => "partial_delivery",
        "evidence" => 41,
        "scope" => "bounded report; all unmet parent criteria"
      }
    }

    Operations.start_run(table, "worker", details)

    Operations.start_run(table, "parent", %{
      details
      | issue_id: "40",
        issue_identifier: "GH-40",
        issue_url: "https://github.com/ahammer/metalrain/issues/40",
        handoff: nil
    })

    {issue, timeline, attempt} = receipt(root, 42, "worker")
    # Real reviewer timestamps have subsecond precision, while native run windows have seconds.
    {:ok, closed_at, _} = DateTime.from_iso8601(issue["closed_at"])
    reviewed_s = DateTime.to_unix(closed_at) + elem(closed_at.microsecond, 0) / 2_000_000
    change_json(attempt, "review-usage", %{"observed_at_epoch" => reviewed_s})
    Operations.usage(table, "worker", "gpt-6-sol", %{input_tokens: 100, output_tokens: 10, total_tokens: 110})
    Operations.finish_run(table, "worker", "completed", %{})
    usage = Jason.decode!(File.read!(Path.join(attempt, "review-usage.json")))
    auxiliary = Path.join(root, "auxiliary-usage")
    File.mkdir_p!(auxiliary)
    File.write!(Path.join(auxiliary, usage["run_id"] <> ".json"), Jason.encode!(usage))
    before = Operations.spend_today(table)
    {:ok, observed} = observation(root, issue, timeline)

    parent = %{
      observed
      | issue: %{observed.issue | id: "40", identifier: "GH-40", url: "https://github.com/ahammer/metalrain/issues/40"},
        report_verifications: []
    }

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

    assert Enum.find(snapshot.delivery_metrics.issue_associations, &(&1.issue_id == "40")).disposition ==
             "unknown_acceptance"

    # A younger worker cannot extend native proof, including interrupted prune writes.
    Operations.start_run(table, "later", %{details | item_attempt: 3})
    [native] = :dets.lookup(table, {:lineage_run, "worker"})
    :dets.delete(table, {:lineage_run, "worker"})

    assert Enum.find(Operations.snapshot(table).delivery_metrics.issue_associations, &(&1.issue_id == "42")).disposition ==
             "unknown_acceptance"

    :dets.insert(table, native)

    # Removing the mutable heading or receipt after retention cannot rewrite lineage.
    File.rm!(Path.join(attempt, "review.json"))
    edited = %{observed | report_verifications: []}
    Operations.observe_delivery(table, edited, "crescendo")
    retained = Enum.find(Operations.snapshot(table).delivery_metrics.issue_associations, &(&1.issue_id == "42"))
    assert retained.report_verifications == association.report_verifications
    assert retained.disposition == association.disposition

    reopened = %{
      edited
      | issue: %{edited.issue | state: "open", updated_at: DateTime.add(edited.issue.updated_at, 10)},
        closed_at: nil
    }

    Operations.observe_delivery(table, reopened, "crescendo")

    assert Enum.find(Operations.snapshot(table).delivery_metrics.issue_associations, &(&1.issue_id == "42")).disposition ==
             "open"

    reclosed_at = DateTime.add(edited.issue.updated_at, 20)
    reclosed = %{edited | issue: %{edited.issue | updated_at: reclosed_at}, closed_at: DateTime.to_iso8601(reclosed_at)}
    Operations.observe_delivery(table, reclosed, "crescendo")

    assert Enum.find(Operations.snapshot(table).delivery_metrics.issue_associations, &(&1.issue_id == "42")).disposition ==
             "unknown_acceptance"

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
    Operations.start_run(table, "worker", %{
      issue_id: "42",
      issue_identifier: "GH-42",
      issue_url: "https://github.com/ahammer/metalrain/issues/42",
      kind: :issue,
      item_attempt: 1
    })

    {issue, timeline, _} = receipt(root, 42, "worker")
    {:ok, observed} = observation(root, issue, timeline)
    at = DateTime.add(observed.issue.updated_at, 30)

    newer = %{
      observed
      | issue: %{observed.issue | updated_at: at},
        closed_at: DateTime.to_iso8601(at),
        report_verifications: []
    }

    Operations.observe_delivery(table, newer, "crescendo")
    Operations.observe_delivery(table, observed, "crescendo")
    [association] = Operations.snapshot(table).delivery_metrics.issue_associations
    assert association.disposition == "unknown_acceptance"
    assert [%{closed_at: original}] = association.report_verifications
    assert original == observed.closed_at
  end

  test "edited issue criteria do not gain old report acceptance", %{root: root, table: table} do
    Operations.start_run(table, "worker", %{
      issue_id: "42",
      issue_identifier: "GH-42",
      issue_url: "https://github.com/ahammer/metalrain/issues/42",
      kind: :issue,
      item_attempt: 1
    })

    {issue, timeline, _} = receipt(root, 42, "worker")
    {:ok, original} = observation(root, issue, timeline)
    Operations.observe_delivery(table, original, "crescendo")

    edited = %{
      issue
      | "body" => issue["body"] <> "; new unmet criterion",
        "updated_at" => DateTime.utc_now() |> DateTime.add(10) |> DateTime.to_iso8601()
    }

    assert {:ok, %{report_verifications: []} = changed} = observation(root, edited, timeline)
    Operations.observe_delivery(table, changed, "crescendo")
    [association] = Operations.snapshot(table).delivery_metrics.issue_associations
    assert association.disposition == "unknown_acceptance"
    assert length(association.report_verifications) == 1
    refute association.canonical_outcome_complete
    assert {:ok, %{report_verifications: []}} = observation(root, %{issue | "title" => "Broader outcome"}, timeline)
  end

  test "conflicting scopes at the same GitHub timestamp stay unknown across replay and restart", %{
    root: root,
    table: table,
    path: path
  } do
    Operations.start_run(table, "worker", %{
      issue_id: "42",
      issue_identifier: "GH-42",
      issue_url: "https://github.com/ahammer/metalrain/issues/42",
      kind: :issue,
      item_attempt: 1
    })

    {issue, timeline, _} = receipt(root, 42, "worker")
    {:ok, original} = observation(root, issue, timeline)
    Operations.observe_delivery(table, original, "crescendo")
    [accepted] = Operations.snapshot(table).delivery_metrics.issue_associations
    assert accepted.disposition == "repository_reported_verification"

    edited = %{issue | "body" => issue["body"] <> "; new unmet criterion"}
    assert {:ok, %{report_verifications: []} = changed} = observation(root, edited, timeline)
    Operations.observe_delivery(table, changed, "crescendo")
    [conflicted] = Operations.snapshot(table).delivery_metrics.issue_associations
    assert conflicted.disposition == "unknown_acceptance"
    assert conflicted.report_verifications == accepted.report_verifications

    Operations.close(table)
    {:ok, ^table} = Operations.open(path, table)

    for observed <- [original, changed, original] do
      Operations.observe_delivery(table, observed, "crescendo")
      [retained] = Operations.snapshot(table).delivery_metrics.issue_associations
      assert retained.disposition == "unknown_acceptance"
      refute retained.canonical_outcome_complete
    end

    updated = DateTime.add(original.issue.updated_at, 1) |> DateTime.to_iso8601()
    {:ok, restored} = observation(root, %{issue | "updated_at" => updated}, timeline)
    Operations.observe_delivery(table, restored, "crescendo")
    [unambiguous] = Operations.snapshot(table).delivery_metrics.issue_associations
    assert unambiguous.disposition == "repository_reported_verification"

    # A mixed issue/timeline read has no lifecycle ID, but its conflicting scope is still observed.
    [closed, comment] = timeline
    reopened = %{"id" => closed["id"] + 1, "event" => "reopened", "created_at" => updated}
    {:ok, mixed} = observation(root, %{edited | "updated_at" => updated}, [closed, reopened, comment])
    assert mixed.lifecycle_id == nil
    Operations.observe_delivery(table, mixed, "crescendo")
    [conflicted] = Operations.snapshot(table).delivery_metrics.issue_associations
    assert conflicted.disposition == "unknown_acceptance"
    assert conflicted.lifecycle_id == unambiguous.lifecycle_id
    Operations.close(table)
    {:ok, ^table} = Operations.open(path, table)
    Operations.observe_delivery(table, restored, "crescendo")
    [conflicted] = Operations.snapshot(table).delivery_metrics.issue_associations
    assert conflicted.disposition == "unknown_acceptance"
    assert conflicted.lifecycle_id == unambiguous.lifecycle_id
  end

  test "delayed or missing accounting observation cannot change completion or server ordering", %{
    root: root,
    table: table,
    path: path
  } do
    start_worker(table, 42, "worker")
    {issue, timeline, attempt} = receipt(root, 42, "worker")
    {:ok, original} = observation(root, issue, timeline)
    [report] = original.report_verifications
    {:ok, closed, _} = DateTime.from_iso8601(issue["closed_at"])
    # Producer/native clocks are deliberately ahead of GitHub; neither supplies server order.
    assert report.reviewed_s > DateTime.to_unix(closed)
    assert report.ordering_s < DateTime.to_unix(closed)

    for observed_at <- [System.os_time(:second) + 3_600, nil] do
      change_json(attempt, "review-usage", %{"observed_at_epoch" => observed_at, "usage" => nil})
      assert {:ok, observed} = observation(root, issue, timeline)
      assert observed.report_verifications == original.report_verifications
      Operations.observe_delivery(table, observed, "crescendo")
      [association] = Operations.snapshot(table).delivery_metrics.issue_associations
      assert association.disposition == "repository_reported_verification"
      assert association.delivery_kind == "report_only"
      assert association.sources == []
      assert_unknown_accounting(association)
      Operations.close(table)
      {:ok, ^table} = Operations.open(path, table)
    end
  end

  test "missing or corrupt completion and original artifact commitments supply no proof", %{root: root} do
    {issue, timeline, attempt} = receipt(root, 42, "worker")

    for name <- [
          "review-completion.json",
          "closure-ordering.json",
          "review.log",
          "review.timing.json",
          "delivery-plan.json",
          "delivery-failures.json"
        ] do
      file = Path.join(attempt, name)
      original = File.read!(file)
      File.rm!(file)
      assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline)
      File.write!(file, "{}")
      assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline)
      File.write!(file, original)
    end

    original = File.read!(Path.join(attempt, "review-completion.json"))

    for changes <- [
          %{"event_id" => String.duplicate("0", 64)},
          %{"schema_version" => 2},
          %{"kind" => "usage"},
          %{"extra" => 1.5},
          %{"artifacts" => nil},
          %{"artifacts" => %{}}
        ] do
      change_json(attempt, "review-completion", changes)

      assert {:ok, %{report_verifications: [], report_rejection: "completion-integrity"}} =
               observation(root, issue, timeline)

      File.write!(Path.join(attempt, "review-completion.json"), original)
    end

    change_json(attempt, "closure-ordering", %{"schema_version" => 2})
    assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline)
  end

  test "committed completion requires exact original reviewer, parent, attempt and native timing", %{root: root} do
    cases = [
      fn event -> Map.put(event, "repository", "foreign/repo") end,
      fn event -> Map.put(event, "issue", 99) end,
      fn event -> Map.put(event, "source_sha", String.duplicate("c", 40)) end,
      fn event -> Map.put(event, "base_sha", String.duplicate("c", 40)) end,
      fn event -> Map.put(event, "scope_digest", String.duplicate("0", 64)) end,
      fn event -> Map.put(event, "receipt", "copied-attempt") end,
      fn event -> Map.put(event, "delivery_attempt_id", "copied-attempt") end,
      fn event -> Map.put(event, "parent", nil) end,
      fn event -> put_in(event, ["parent", "attempt_id"], "another-attempt") end,
      fn event -> put_in(event, ["reviewer", "thread_id"], "another-thread") end,
      fn event -> put_in(event, ["reviewer", "model"], "") end,
      fn event -> Map.put(event, "usage_identity_digest", "changed") end,
      fn event -> Map.put(event, "artifacts", nil) end,
      fn event -> Map.put(event, "native_window", nil) end,
      fn event -> put_in(event, ["native_window", "ordering_authority"], true) end,
      fn event -> put_in(event, ["native_window", "completed_at_epoch_us"], -1) end,
      fn event ->
        put_in(event, ["native_window", "started_at_epoch_us"], event["native_window"]["accepted_at_epoch_us"] + 1)
      end,
      fn event -> put_in(event, ["native_window", "accepted_at_epoch_us"], 1) end,
      fn event ->
        put_in(event, ["native_window", "completed_at_epoch_us"], event["native_window"]["completed_at_epoch_us"] + 1)
      end
    ]

    for {mutate, number} <- Enum.with_index(cases, 100) do
      {issue, timeline, attempt} = receipt(root, number, "worker-#{number}")
      timeline = reseal(attempt, timeline, event: mutate)
      assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline), "case #{number}"
    end

    for changes <- [
          %{"identity_status" => "ambiguous"},
          %{"thread_id" => nil},
          %{"log_digest" => "changed"},
          %{"run_id" => "worker"}
        ] do
      {issue, timeline, attempt} = receipt(root, 42, "worker")
      change_json(attempt, "review-usage", changes)
      timeline = reseal(attempt, timeline, update_identity: false)
      assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline)
    end

    {issue, timeline, attempt} = receipt(root, 43, "worker")
    change_json(attempt, "review.timing", %{"started_at_epoch" => nil})
    timeline = reseal(attempt, timeline)

    assert {:ok, %{report_verifications: [], report_rejection: "missing-native-window"}} =
             observation(root, issue, timeline)
  end

  test "late, same-second, equal fractional and absent GitHub timing stay unknown through restart", %{
    root: root,
    table: table,
    path: path
  } do
    for {offset, number} <- Enum.with_index([0, 1, :fractional, :missing], 42) do
      id = "worker-#{number}"
      start_worker(table, number, id)
      {issue, timeline, attempt} = receipt(root, number, id)
      {:ok, closed, _} = DateTime.from_iso8601(issue["closed_at"])

      at =
        case offset do
          :fractional -> closed |> DateTime.add(500_000, :microsecond) |> DateTime.to_iso8601()
          :missing -> nil
          value -> closed |> DateTime.add(value) |> DateTime.to_iso8601()
        end

      issue = if offset == :fractional, do: %{issue | "closed_at" => at, "updated_at" => at}, else: issue
      [closure, comment] = timeline
      timeline = [%{closure | "created_at" => issue["closed_at"]}, comment]
      timeline = reseal(attempt, timeline, anchor_at: at)
      assert {:ok, %{report_verifications: []} = observed} = observation(root, issue, timeline)

      for _ <- 1..2 do
        Operations.observe_delivery(table, observed, "crescendo")

        association =
          Enum.find(Operations.snapshot(table).delivery_metrics.issue_associations, &(&1.issue_id == to_string(number)))

        assert association.disposition == "unknown_acceptance"
        assert association.report_verifications == []
        assert_unknown_accounting(association)
        Operations.close(table)
        {:ok, ^table} = Operations.open(path, table)
      end
    end
  end

  test "fresh authentication rejects changed, foreign, missing and duplicate anchors", %{root: root} do
    {issue, timeline, attempt} = receipt(root, 42, "worker")
    [_, comment] = timeline
    anchor = comment["fixture_anchor"]

    for changes <- [
          %{"body" => "changed"},
          %{"updated_at" => issue["closed_at"]},
          %{"issue_url" => "https://api.github.com/repos/foreign/repo/issues/42"},
          %{"id" => 0}
        ] do
      assert {:ok, %{report_verifications: [], report_rejection: "changed-anchor"}} =
               observation(root, issue, timeline, nil, anchors: [Map.merge(anchor, changes)])
    end

    assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline, nil, anchors: [])
    duplicate = Map.merge(anchor, %{"id" => anchor["id"] + 1, "event" => "commented"})
    assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline ++ [duplicate])
    change_json(attempt, "closure-ordering", %{"anchor" => %{anchor | "id" => -1}})
    assert {:ok, %{report_verifications: []}} = observation(root, issue, timeline)
  end

  test "reopen cannot rebind approval; an independently completed new lifecycle can retain it", %{
    root: root,
    table: table,
    path: path
  } do
    second = System.os_time(:second) - 60
    at = fn offset -> DateTime.from_unix!(second + offset) |> DateTime.to_iso8601() end
    start_worker(table, 42, "worker")
    set_run_window(table, "worker", second, second + 15)
    {issue, [closed, comment], attempt} = receipt(root, 42, "worker")
    issue = %{issue | "closed_at" => at.(10), "updated_at" => at.(10)}
    closed = %{closed | "created_at" => at.(10)}
    [_, comment] = reseal(attempt, [closed, comment], native_second: second + 5, anchor_at: at.(8))
    {:ok, original} = observation(root, issue, [closed, comment])
    Operations.observe_delivery(table, original, "crescendo")
    [accepted] = Operations.snapshot(table).delivery_metrics.issue_associations
    assert accepted.disposition == "repository_reported_verification"

    reopened = %{"id" => closed["id"] + 1, "event" => "reopened", "created_at" => at.(20)}
    reclosed = %{closed | "id" => closed["id"] + 2, "created_at" => at.(40)}
    issue = %{issue | "closed_at" => at.(40), "updated_at" => at.(40)}
    assert {:ok, %{report_verifications: []} = unsafe} = observation(root, issue, [closed, reopened, reclosed, comment])

    for observed <- [unsafe, original, unsafe] do
      Operations.observe_delivery(table, observed, "crescendo")
      [association] = Operations.snapshot(table).delivery_metrics.issue_associations
      assert association.disposition == "unknown_acceptance"
      assert association.report_verifications == accepted.report_verifications
      Operations.close(table)
      {:ok, ^table} = Operations.open(path, table)
    end

    start_worker(table, 42, "later", 2)
    set_run_window(table, "later", second + 25, second + 45)
    {_, [_, new_comment], new_attempt} = receipt(root, 42, "later", String.duplicate("c", 32))

    [_, new_comment] =
      reseal(new_attempt, [reclosed, new_comment],
        prefix: [closed, reopened],
        native_second: second + 30,
        anchor_at: at.(35)
      )

    # Both annotations may share an old mutable workpad; only the fresh immutable anchors supply time.
    workpad = %{new_comment | "body" => comment["body"] <> "\n\n" <> new_comment["body"]}
    anchors = [comment["fixture_anchor"], new_comment["fixture_anchor"]]

    assert {:ok, %{report_verifications: [%{run_id: "later"}]} = safe} =
             observation(root, issue, [closed, reopened, reclosed, workpad], nil, anchors: anchors)

    Operations.observe_delivery(table, safe, "crescendo")
    [association] = Operations.snapshot(table).delivery_metrics.issue_associations
    assert association.disposition == "repository_reported_verification"
    assert length(association.report_verifications) == 2
    assert association.sources == []

    # First publication after a reopen cannot rescue an approval whose input captured the old lifecycle.
    [_, moved] = reseal(attempt, [reclosed, comment], anchor_at: at.(35))

    assert {:ok, %{report_verifications: [], report_rejection: "changed-lifecycle"}} =
             observation(root, issue, [closed, reopened, reclosed, moved])
  end

  test "a prior reopen needs an earlier server second and an exact pre-review prefix", %{root: root} do
    {issue, [closed, comment], attempt} = receipt(root, 42, "worker")
    {:ok, closure, _} = DateTime.from_iso8601(issue["closed_at"])
    anchor_at = DateTime.add(closure, -2) |> DateTime.to_iso8601()
    reopened = %{"id" => closed["id"] - 1, "event" => "reopened", "created_at" => anchor_at}
    [_, comment] = reseal(attempt, [closed, comment], prefix: [reopened])

    assert {:ok, %{report_verifications: [], report_rejection: "ambiguous-lifecycle"}} =
             observation(root, issue, [reopened, closed, comment])

    precise = %{reopened | "created_at" => DateTime.add(closure, -2_500_000, :microsecond) |> DateTime.to_iso8601()}
    assert {:ok, %{report_verifications: []}} = observation(root, issue, [precise, closed, comment])
    earlier = %{reopened | "created_at" => DateTime.add(closure, -3) |> DateTime.to_iso8601()}
    [_, comment] = reseal(attempt, [closed, comment], prefix: [earlier])
    assert {:ok, %{report_verifications: [_]}} = observation(root, issue, [earlier, closed, comment])
    assert {:ok, %{report_verifications: []}} = observation(root, issue, [Map.delete(earlier, "id"), closed, comment])
    assert {:ok, %{report_verifications: []}} = observation(root, issue, [earlier, earlier, closed, comment])
    change_json(attempt, "closure-ordering", %{"lifecycle_before" => []})
    assert {:ok, %{report_verifications: []}} = observation(root, issue, [earlier, closed, comment])
  end

  test "native attribution requires the entire original window and a unique reviewer event", %{root: root, table: table} do
    start_worker(table, 42, "worker")
    {issue, timeline, _attempt} = receipt(root, 42, "worker")
    {:ok, observed} = observation(root, issue, timeline)
    [report] = observed.report_verifications

    for invalid <- [
          Map.put(report, :native_started_s, report.reviewed_s + 1),
          Map.put(report, :native_accepted_s, report.reviewed_s - 1),
          Map.put(report, :native_accepted_s, report.reviewed_s + 10_000),
          Map.put(report, :ordering_s, DateTime.to_unix(observed.issue.updated_at))
        ] do
      Operations.observe_delivery(table, %{observed | report_verifications: [invalid]}, "crescendo")
      [association] = Operations.snapshot(table).delivery_metrics.issue_associations
      assert association.report_verifications == []
    end

    Operations.observe_delivery(table, observed, "crescendo")
    start_worker(table, 43, "other")
    {other, other_timeline, attempt} = receipt(root, 43, "other")
    change_json(attempt, "review-usage", %{"run_id" => report.reviewer_run_id})
    change_json(attempt, "review.timing", %{"attempt" => report.reviewer_run_id})
    other_timeline = reseal(attempt, other_timeline)
    assert {:ok, %{report_verifications: [_]} = duplicate} = observation(root, other, other_timeline)
    Operations.observe_delivery(table, duplicate, "crescendo")
    association = Enum.find(Operations.snapshot(table).delivery_metrics.issue_associations, &(&1.issue_id == "43"))
    assert association.disposition == "unknown_acceptance"
    assert association.report_verifications == []
  end

  test "legacy retained observation proof cannot regain acceptance after restart", %{
    root: root,
    table: table,
    path: path
  } do
    start_worker(table, 42, "worker")
    {issue, timeline, _} = receipt(root, 42, "worker")
    {:ok, observed} = observation(root, issue, timeline)
    [report] = observed.report_verifications

    legacy =
      report
      |> Map.drop([:completion_id, :ordering_s, :reviewer_run_id])
      |> Map.merge(%{issue_id: "42", item_attempt: 1})

    :dets.insert(table, {{:lineage_evidence, "issue_report", {"42", "legacy"}}, legacy})
    Operations.observe_delivery(table, %{observed | report_verifications: []}, "crescendo")
    Operations.close(table)
    {:ok, ^table} = Operations.open(path, table)
    [association] = Operations.snapshot(table).delivery_metrics.issue_associations
    assert association.disposition == "unknown_acceptance"
    assert length(association.report_verifications) == 1
    assert_unknown_accounting(association)
  end

  test "the completion boundary rejects a fresh context without the promised closure", %{root: root} do
    {issue, [closed, comment], attempt} = receipt(root, 42, "worker")
    anchor = comment["fixture_anchor"]

    context = %{
      repo: "ahammer/metalrain",
      number: 42,
      sha: String.duplicate("a", 40),
      parts: ["issue-42", String.duplicate("a", 40), String.duplicate("b", 32)],
      scope: [issue["title"], issue["body"]],
      raw: issue,
      timeline: [closed, Map.put(anchor, "event", "commented")],
      usage: Jason.decode!(File.read!(Path.join(attempt, "review-usage.json"))),
      input_lifecycle: []
    }

    bytes = &File.read(Path.join(attempt, &1))
    authenticate = fn _ -> {:ok, anchor} end
    assert {:ok, _} = ReportCompletion.read(bytes, context, authenticate)

    for raw <- [Map.put(issue, "state", "open"), Map.put(issue, "state_reason", "not_planned"), Map.put(issue, "closed_at", nil)] do
      assert {:error, "changed-lifecycle"} = ReportCompletion.read(bytes, %{context | raw: raw}, authenticate)
    end

    reopened = %{closed | "event" => "reopened"}
    timeline = [reopened, Map.put(anchor, "event", "commented")]
    assert {:error, "changed-lifecycle"} = ReportCompletion.read(bytes, %{context | timeline: timeline}, authenticate)
  end

  test "a worker overlapping only completion still makes original attribution ambiguous", %{root: root, table: table} do
    second = System.os_time(:second)
    start_worker(table, 42, "worker")
    set_run_window(table, "worker", second - 10, second + 1)
    {issue, timeline, attempt} = receipt(root, 42, "worker")
    change_json(attempt, "review.timing", %{"started_at_epoch" => second - 5, "completed_at_epoch" => second})
    timeline = reseal(attempt, timeline)
    start_worker(table, 42, "overlap")
    set_run_window(table, "overlap", second - 1, second + 1)
    assert {:ok, %{report_verifications: [_]} = observed} = observation(root, issue, timeline)
    Operations.observe_delivery(table, observed, "crescendo")
    [association] = Operations.snapshot(table).delivery_metrics.issue_associations
    assert association.disposition == "unknown_acceptance"
    assert association.report_verifications == []
  end

  test "Unicode scope and sorted nested commitments match the supported JSON contract", %{root: root, table: table} do
    start_worker(table, 42, "worker")
    {issue, timeline, attempt} = receipt(root, 42, "worker")
    issue = %{issue | "title" => "Rain 雨", "body" => "Scope é / λ"}
    change_json(attempt, "input", %{"issue" => %{issue | "state" => "open"}})
    change_json(attempt, "closure-intent", %{"scope" => [issue["title"], issue["body"]]})
    timeline = reseal(attempt, timeline)
    assert {:ok, %{report_verifications: [_]} = observed} = observation(root, issue, timeline)
    Operations.observe_delivery(table, observed, "crescendo")

    assert [%{disposition: "repository_reported_verification"}] =
             Operations.snapshot(table).delivery_metrics.issue_associations
  end

  defp observation(root, issue, timeline, id \\ nil, opts \\ []) do
    request = fn "GET", path, _params, nil, _settings ->
      anchors =
        Keyword.get(
          opts,
          :anchors,
          timeline |> Enum.flat_map(&List.wrap(&1["fixture_anchor"])) |> Enum.uniq_by(& &1["id"])
        )

      body =
        cond do
          String.ends_with?(path, "timeline") -> timeline ++ Enum.map(anchors, &Map.put(&1, "event", "commented"))
          String.contains?(path, "/comments/") -> Enum.find(anchors, &String.ends_with?(path, "/#{&1["id"]}"))
          true -> issue
        end

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

  defp start_worker(table, number, id, attempt \\ 1) do
    Operations.start_run(table, id, %{
      issue_id: to_string(number),
      issue_identifier: "GH-#{number}",
      issue_url: "https://github.com/ahammer/metalrain/issues/#{number}",
      kind: :issue,
      item_attempt: attempt
    })
  end

  defp set_run_window(table, id, started, finished) do
    Operations.finish_run(table, id, "completed", %{})
    [{key, run}] = :dets.lookup(table, {:lineage_run, id})
    :dets.insert(table, {key, Map.merge(run, %{started_s: started, finished_s: finished})})
  end

  defp assert_unknown_accounting(association) do
    assert association.verified_cost == nil
    assert association.verified_latency == nil
    assert association.helper_usage_coverage == "unknown"
  end

  # These are scrubbed producer-shaped commitments, never historical review reconstruction.
  defp reseal(attempt, [closed, comment], opts \\ []) do
    read = fn name -> Jason.decode!(File.read!(Path.join(attempt, name <> ".json"))) end
    write = fn name, value -> File.write!(Path.join(attempt, name <> ".json"), Jason.encode!(value)) end
    input = read.("input")
    input = Map.put(input, "lifecycle_before", Keyword.get(opts, :prefix, input["lifecycle_before"]))
    write.("input", input)
    usage = read.("review-usage")

    for name <- ["delivery-plan.json", "delivery-failures.json", "review.log"] do
      file = Path.join(attempt, name)
      if not File.exists?(file), do: File.write!(file, "scrubbed fixture\n")
    end

    log_digest = File.read!(Path.join(attempt, "review.log")) |> hash()
    if Keyword.get(opts, :update_identity, true), do: write.("review-usage", Map.put(usage, "log_digest", log_digest))
    usage = read.("review-usage")
    second = Keyword.get(opts, :native_second, System.os_time(:second))
    timing_file = Path.join(attempt, "review.timing.json")

    if not File.exists?(timing_file) or Keyword.has_key?(opts, :native_second) do
      write.("review.timing", %{
        "attempt" => usage["run_id"],
        "started_at_epoch" => second + 0.1,
        "completed_at_epoch" => second + 0.2
      })
    end

    timing = read.("review.timing")
    parts = attempt |> Path.split() |> Enum.take(-3)

    artifacts =
      ~w(review.json input.json acceptance.md review-input-digest.json adjudicated-failures.json hosted-checks.json review.log review.timing.json delivery-plan.json delivery-source.json delivery-failures.json)

    fields =
      ~w(run_id parent_run_id work_item role model effort codex_version source_sha thread_id terminal_event identity_status log_digest)

    native_started =
      if is_number(timing["started_at_epoch"]),
        do: trunc(timing["started_at_epoch"] * 1_000_000),
        else: second * 1_000_000

    native_completed =
      if is_number(timing["completed_at_epoch"]),
        do: trunc(timing["completed_at_epoch"] * 1_000_000),
        else: second * 1_000_000

    event = %{
      "schema_version" => 1,
      "kind" => "successful-review-completion",
      "repository" => "ahammer/metalrain",
      "issue" => input["issue"]["number"],
      "source_sha" => input["head"],
      "base_sha" => read.("review")["base"],
      "scope_digest" => canonical_digest([input["issue"]["title"], input["issue"]["body"]]),
      "lifecycle_before" => input["lifecycle_before"],
      "receipt" => Enum.join(parts, "/"),
      "delivery_attempt_id" => List.last(parts),
      "usage_identity_digest" => canonical_digest(Map.new(fields, &{&1, usage[&1]})),
      "reviewer" => %{
        "run_id" => usage["run_id"],
        "thread_id" => usage["thread_id"],
        "model" => usage["model"],
        "effort" => usage["effort"]
      },
      "parent" => %{
        "run_id" => usage["parent_run_id"],
        "work_item" => usage["work_item"],
        "attempt_id" => usage["parent_run_id"]
      },
      "native_window" => %{
        "clock" => "producer-wall-clock",
        "ordering_authority" => false,
        "started_at_epoch_us" => native_started,
        "completed_at_epoch_us" => native_completed,
        "accepted_at_epoch_us" => native_completed + 100_000
      },
      "artifacts" => Map.new(artifacts, &{&1, File.read!(Path.join(attempt, &1)) |> hash()})
    }

    event = Keyword.get(opts, :event, &Function.identity/1).(event)
    event = Map.put(event, "event_id", canonical_digest(event))
    write.("review-completion", event)
    {:ok, closed_at, _} = DateTime.from_iso8601(closed["created_at"])
    default_at = DateTime.add(closed_at, -2) |> DateTime.to_iso8601()
    at = Keyword.get(opts, :anchor_at, get_in(comment, ["fixture_anchor", "created_at"]) || default_at)

    anchor = %{
      "id" => String.slice(hash(Enum.join(parts, "/")), 0, 7) |> String.to_integer(16),
      "body" => "<!-- symphony-review-completion-v1 -->\nCompletion commitment: sha256:#{event["event_id"]}",
      "created_at" => at,
      "updated_at" => at
    }

    write.("closure-ordering", %{
      "schema_version" => 1,
      "event_id" => event["event_id"],
      "anchor" => anchor,
      "lifecycle_before" => event["lifecycle_before"],
      "expected_state_reason" => "completed"
    })

    fresh =
      Map.put(anchor, "issue_url", "https://api.github.com/repos/ahammer/metalrain/issues/#{input["issue"]["number"]}")

    [closed, Map.put(comment, "fixture_anchor", fresh)]
  end

  defp canonical_digest(value), do: value |> canonical_json() |> Jason.encode!() |> hash()

  defp canonical_json(value) when is_map(value),
    do: Jason.OrderedObject.new(value |> Enum.sort() |> Enum.map(fn {key, item} -> {key, canonical_json(item)} end))

  defp canonical_json(value) when is_list(value), do: Enum.map(value, &canonical_json/1)
  defp canonical_json(value), do: value
  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp start_inventory(%{root: root, path: path, table: table}, fixtures) do
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
    {orchestrator, opts}
  end

  defp await_reports(orchestrator) do
    assert Enum.any?(1..80, fn _ ->
             associations = Orchestrator.snapshot(orchestrator, 5_000).operations.delivery_metrics.issue_associations
             ready = length(associations) == 3 and :sys.get_state(orchestrator).pulls_observed_at != nil
             if not ready, do: Process.sleep(25)
             ready
           end)

    Orchestrator.snapshot(orchestrator, 5_000).operations.delivery_metrics.issue_associations
  end

  defp receipt(root, number, run_id, receipt_id \\ String.duplicate("b", 32)) do
    sha = String.duplicate("a", 40)
    attempt = Path.join([root, "issue-#{number}", sha, receipt_id])
    File.mkdir_p!(attempt)
    at = DateTime.from_unix!(System.os_time(:second) - 150) |> DateTime.to_iso8601()

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

    input = %{"issue" => %{issue | "state" => "open"}, "head" => sha, "lifecycle_before" => []}
    intent = %{"issue" => number, "head" => sha, "scope" => [issue["title"], issue["body"]], "retirement" => false}

    review = %{
      "base" => sha,
      "head" => sha,
      "approved" => true,
      "summary" => "Exact bounded report accepted",
      "findings" => [],
      "missing_evidence" => [],
      "preexisting" => []
    }

    usage = %{
      "run_id" => hash("#{number}:#{receipt_id}") |> String.slice(0, 32),
      "parent_run_id" => run_id,
      "work_item" => "GH-#{number}",
      "source_sha" => sha,
      "role" => "reviewer",
      "terminal_event" => "turn.completed",
      "observed_at_epoch" => System.os_time(:second),
      "model" => "gpt-6.1-sol",
      "effort" => "max",
      "thread_id" => "review-thread-#{number}",
      "identity_status" => "unique",
      "codex_version" => "scrubbed-cli",
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
          {"hosted-checks", %{"statuses" => %{"total_count" => 0, "sha" => sha}, "checks" => []}},
          {"review-input-digest", %{"before" => "digest", "after" => "digest", "new_own_issue_paths" => []}}
        ] do
      File.write!(Path.join(attempt, name <> ".json"), Jason.encode!(value))
    end

    File.write!(Path.join(attempt, "acceptance.md"), "Exact source #{sha}; bounded report accepted; parent unmet.")

    annotation =
      "<!-- symphony-workpad -->\n\n## Symphony existing-implementation verification\n" <>
        "Reviewed current main `#{sha}`. Retained evidence: `issue-#{number}/#{sha}/#{receipt_id}`."

    timeline = [
      %{"id" => number * 10, "event" => "closed", "created_at" => at},
      %{"event" => "commented", "body" => annotation}
    ]

    {issue, reseal(attempt, timeline), attempt}
  end
end
