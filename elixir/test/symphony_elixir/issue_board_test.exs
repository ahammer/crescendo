defmodule SymphonyElixirWeb.IssueBoardTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.IssueBoard

  @day ~D[2026-11-02]
  @today "2026-11-02T00:02:00Z"
  @yesterday "2026-11-01T23:59:00Z"

  test "empty and partial snapshots retain unavailable state without invented cards" do
    board = IssueBoard.build(%{snapshot_status: "partial"}, @day)
    assert board.partial
    assert board.cards == []
    assert board.counts == %{intake: 0, active: 0, done: 0}
    assert Enum.map(board.lanes, & &1.id) == ["intake", "active", "done"]
    assert board.days == ["2026-11-02"]
    assert IssueBoard.select(board, nil) == nil
    assert IssueBoard.filter(board, "unknown") == board
    assert IssueBoard.build(%{error: %{code: "timeout"}}, @day).partial
    assert IssueBoard.build(%{}, "invalid").date == Date.to_iso8601(Date.utc_today())
  end

  test "current issue entries, repeated runs, retries and media form one project-scoped card" do
    item = issue("1", "GH-1", title: "Current issue title", labels: ["area:runtime", "priority:p1"])
    delivery = association(item, attempts: [%{run_id: "one", status: "completed", started_s: 1}])
    active = Map.merge(item, %{run_id: "one", last_message: "A current update", started_at: @today})

    payload = %{
      upcoming: %{ready: [item], waiting: [Map.put(item, :reason, "dependency blocked")]},
      blocked: [Map.put(item, :error, "Previous failure")],
      retrying: [Map.merge(item, %{due_at: @today, error: "No available slot"})],
      running: [active],
      usage: %{
        delivery_metrics: %{issue_associations: [delivery]},
        activity: [Map.merge(item, %{kind: "completed", at: @today, run_id: "one"})],
        images: [Map.merge(item, %{title: "Older image title", src: "/artifacts/a/1.png", at: @yesterday})]
      }
    }

    [card] = IssueBoard.build(payload, @day).cards
    assert card.lane == "active"
    assert card.title == "Current issue title"
    assert card.area == "runtime"
    assert card.labels == ["area:runtime", "priority:p1"]
    assert card.summary == "A current update"
    assert card.run_count == 1
    assert hd(card.runs).run_id == "one"
    assert card.run_count_scope =~ "coverage unavailable"
    assert length(card.retrying) == 1
    assert length(card.blocked) == 1
    assert [%{run_id: nil, src: "/artifacts/a/1.png"}] = card.media
    assert card.acceptance == "incomplete"
    assert card.parent_issue == nil
    assert IssueBoard.select(IssueBoard.build(payload, @day), card.key) == card
  end

  test "missing IDs remain unavailable and command success does not become validation or delivery" do
    active = issue("1", "GH-1", workspace: %{now: %{kind: "command", status: "completed"}, said: "Waiting for review"})
    [card] = IssueBoard.build(%{running: [active]}, @day).cards
    assert card.phase == "Agent running"
    assert card.summary == "Waiting for review"
    assert card.run_count == nil
    assert card.runs == []
    assert card.acceptance == nil
    assert card.merged == nil

    message = put_in(active, [:workspace, :now], %{kind: "message", text: "Validation is still running"})
    assert hd(IssueBoard.build(%{running: [message]}, @day).cards).summary == "Validation is still running"
  end

  test "worker completion and stop events alone never enter Done" do
    events = [
      Map.put(event("GH-1", "completed", @today), :run_id, "finished-worker"),
      event("GH-2", "stopped", @today),
      event("GH-3", "interrupted", @today),
      %{kind: "completed", at: @today},
      event("helper-unrelated", "failed", @today)
    ]

    board = IssueBoard.build(%{usage: %{activity: events}}, @day)
    assert board.counts == %{intake: 0, active: 0, done: 0}
    assert Enum.all?(board.history_cards, &(&1.phase == "Current issue status unavailable"))
    finished = Enum.find(board.history_cards, &(&1.issue_identifier == "GH-1"))
    assert hd(finished.runs).status == "completed"
    assert finished.acceptance == nil
    assert length(board.unassigned_events) == 2
  end

  test "the selected UTC day archives completed issues and carries all unfinished work" do
    first = association(issue("1", "GH-1"), state: "closed", closed_at: @yesterday)
    second = association(issue("2", "GH-2"), state: "closed", closed_at: @today)
    waiting = issue("3", "GH-3", reason: "continuation pending")
    payload = %{upcoming: %{waiting: [waiting]}, usage: %{delivery_metrics: %{issue_associations: [first, second]}}}

    today = IssueBoard.build(payload, @day)
    yesterday = IssueBoard.build(payload, "2026-11-01")
    assert Enum.map(today.cards, & &1.issue_identifier) == ["GH-2", "GH-3"]
    assert Enum.map(yesterday.cards, & &1.issue_identifier) == ["GH-1", "GH-3"]
    assert today.days == ["2026-11-02", "2026-11-01"]
    assert today.counts == %{intake: 1, active: 0, done: 1}
    assert hd(today.lanes).cards |> hd() |> Map.fetch!(:phase) == "continuation pending"
    assert hd(payload.usage.delivery_metrics.issue_associations).closed_at == @yesterday
  end

  test "closed issues without a closure timestamp remain separately available" do
    row = association(issue("1", "GH-1"), state: "closed", closed_at: nil)
    board = IssueBoard.build(%{usage: %{delivery_metrics: %{issue_associations: [row]}}}, @day)
    assert board.cards == []
    assert [%{done_day: nil, issue_identifier: "GH-1"}] = board.undated_cards
    assert IssueBoard.select(board, hd(board.undated_cards).key) == hd(board.undated_cards)
    assert IssueBoard.filter(board, "prs").undated_cards == board.undated_cards
  end

  test "current open or running observations dominate older terminal and merged evidence" do
    row =
      association(issue("1", "GH-1"),
        sources: [%{pr_number: 2, status: "merged"}],
        tracker_observations: [%{closed_at: @yesterday}, %{closed_at: nil}]
      )

    events = [Map.merge(event("GH-1", "issue_terminal", @yesterday), %{issue_id: "1"})]
    payload = %{usage: %{delivery_metrics: %{issue_associations: [row]}, activity: events}}
    [card] = IssueBoard.build(payload, @day).cards
    assert card.lane == "intake"
    assert card.phase == "Current phase unavailable"
    assert card.merged
    assert card.acceptance == "incomplete"
    assert IssueBoard.build(payload, @day).days == ["2026-11-02", "2026-11-01"]

    [running] = IssueBoard.build(Map.put(payload, :running, [issue("1", "GH-1")]), @day).cards
    assert running.lane == "active"
  end

  test "PRs join issues only through explicit source associations in the same project" do
    row = association(issue("1", "GH-1"), sources: [%{pr_number: 7, status: "open"}])
    other = association(issue("1", "GH-1", project: "other"), sources: [%{pr_number: 8, status: "open"}])

    review = %{
      project: "one",
      issue_id: "pr-7",
      issue_identifier: "PR-7",
      title: "Review title",
      run_id: "review",
      kind: :pull_request
    }

    payload = %{
      running: [review],
      pull_requests: %{
        items: [
          %{project: "one", number: 7, title: "Actual pull"},
          %{project: "other", number: 7, title: "Other pull"}
        ]
      },
      usage: %{delivery_metrics: %{issue_associations: [row, other]}}
    }

    board = IssueBoard.build(payload, @day)
    issue = Enum.find(board.cards, &(&1.project == "one" and &1.issue_identifier == "GH-1"))
    assert issue.lane == "active"
    assert issue.issue_id == "1"
    refute issue.title == "Review title"
    assert issue.run_count == 1
    assert "review" in issue.groups
    assert "prs" in issue.groups
    assert length(issue.pull_requests) == 1
    assert Enum.any?(board.cards, &(&1.project == "other" and &1.issue_identifier == "PR-7"))
    assert Enum.any?(board.cards, &(&1.project == "other" and &1.issue_identifier == "GH-1"))
    assert hd(IssueBoard.filter(board, "review").cards).key == issue.key
  end

  test "unassociated PR observations retain their identity and reopen over an older merge" do
    events = [
      %{kind: "pr_merged", project: "one", pr_number: 41, summary: "A real PR title", at: @yesterday},
      %{kind: "completed", project: "one", issue_identifier: "PR-41", at: @today}
    ]

    board = IssueBoard.build(%{usage: %{activity: events}}, "2026-11-01")
    [card] = board.cards
    assert card.issue_identifier == "PR-41"
    assert card.title == "A real PR title"
    assert card.phase == "PR merged"
    assert card.merged

    reopened = %{kind: "pr_reopened", project: "one", pr_number: 41, at: @today}
    payload = %{usage: %{activity: [reopened | events]}}
    assert hd(IssueBoard.build(payload, @day).history_cards).lane == "history"

    open_pull = %{project: "one", number: 41, url: "https://example.test/pull/41", title: "Current PR"}
    current = IssueBoard.build(Map.put(payload, :pull_requests, %{items: [open_pull]}), @day)
    assert hd(current.cards).phase == "Open pull request"
    assert hd(current.cards).title == "Current PR"
    assert hd(current.cards).issue_url == open_pull.url
  end

  test "ambiguous identifiers never cross explicit issue IDs or project boundaries" do
    first = association(issue("1", "GH-1"))
    second = association(issue("2", "GH-1"))

    payload = %{
      running: [issue("1", "GH-1"), issue("1", "GH-1", project: "other")],
      usage: %{
        delivery_metrics: %{issue_associations: [first, second]},
        activity: [event("GH-1", "completed", @today)],
        images: [%{project: "one", issue_identifier: "GH-1", src: "/artifacts/ambiguous.png"}]
      }
    }

    board = IssueBoard.build(payload, @day)
    assert length(board.cards) == 3
    assert length(board.unassigned_events) == 1
    assert Enum.all?(board.cards, &(&1.media == []))
    assert length(Enum.uniq(Enum.map(board.cards, & &1.key))) == 3
  end

  test "helpers use explicit parent issue IDs while unrelated helpers stay unassigned" do
    owner = issue("1", "GH-1")
    good = %{project: "one", run_id: "helper", parent_issue_id: "1", status: "running"}
    wrong = %{good | project: "other"}
    payload = %{running: [owner], helpers: [good, wrong, %{run_id: "unowned"}]}
    board = IssueBoard.build(payload, @day)
    assert hd(board.cards).helpers == [good]
    assert length(board.unassigned_helpers) == 2
    assert hd(board.cards).run_count == nil
  end

  test "history and media can seed unidentified current work without inventing run ownership" do
    image = %{
      project: "one",
      issue_identifier: "GH-10",
      title: "Image-owned title",
      src: "/artifacts/a.png",
      at: @today
    }

    payload = %{
      usage: %{
        images: [image],
        activity: [event("GH-9", "retired", @today), event("GH-8", "issue_terminal", @today)]
      }
    }

    board = IssueBoard.build(payload, @day)
    assert board.counts == %{intake: 0, active: 0, done: 2}
    card = Enum.find(board.history_cards, &(&1.issue_identifier == "GH-10"))
    assert card.title == "Image-owned title"
    assert hd(card.media).run_id == nil
    assert card.run_count == nil
    assert length(IssueBoard.filter(board, "prs").cards) == 2
  end

  test "explicit task results end the task without asserting issue acceptance" do
    payload = %{
      usage: %{
        activity: [
          event("research-scorecard", "task_delivered", @today),
          event("research-grooming", "task_short", @today),
          event("research-no-output", "task_no_output", @today),
          event("research-unverified", "task_unverified", @today)
        ]
      }
    }

    board = IssueBoard.build(payload, @day)
    assert board.counts.done == 4
    assert Enum.sort(Enum.map(board.cards, & &1.phase)) == Enum.sort(["Task fell short", "Task delivered", "No new issues or PRs observed", "Publication unverified"])
    assert Enum.all?(board.cards, &is_nil(&1.acceptance))
    assert length(IssueBoard.filter(board, "autopilot").cards) == 4
    assert IssueBoard.filter(board, "prs").cards == []

    current = %{project: "one", issue_identifier: "research-scorecard", last_message: "Starting another round"}

    assert Enum.find(
             IssueBoard.build(Map.put(payload, :running, [current]), @day).cards,
             &(&1.issue_identifier == "research-scorecard")
           ).lane == "active"
  end

  test "unknown history is day scoped, selectable and absent from the current queue" do
    payload = %{
      usage: %{
        activity: [
          event("GH-1", "completed", @yesterday),
          event("GH-2", "stopped", @today)
        ]
      }
    }

    today = IssueBoard.build(payload, @day)
    yesterday = IssueBoard.build(payload, "2026-11-01")
    assert today.cards == []
    assert Enum.map(today.history_cards, & &1.issue_identifier) == ["GH-2"]
    assert Enum.map(yesterday.history_cards, & &1.issue_identifier) == ["GH-1"]
    assert today.days == ["2026-11-02", "2026-11-01"]
    assert IssueBoard.select(today, hd(today.history_cards).key) == hd(today.history_cards)
    assert IssueBoard.filter(today, "review").history_cards == []
  end

  test "external reviews remain unverified reports separate from recorded worker totals" do
    owner = issue("1", "GH-1")

    report = %{
      project: "one",
      run_id: "review",
      parent_run_id: "worker",
      parent_issue_id: "1",
      role: "reviewer",
      identity: "claimed",
      attribution: "unverified_cli_report",
      terminal_event: "completed"
    }

    planner = %{report | run_id: "plan", role: "planner"}
    unmatched = %{report | project: "other"}
    redacted = Map.drop(report, [:run_id, :parent_issue_id, :parent_run_id])
    delivery = association(owner, report_verifications: [%{reviewer_run_id: "verified-review"}])

    payload = %{
      running: [owner],
      usage: %{
        delivery_metrics: %{issue_associations: [delivery]},
        external: %{observations: [report, planner, unmatched, redacted]}
      }
    }

    board = IssueBoard.build(payload, @day)
    [card] = board.cards
    assert length(card.external_reports) == 2
    assert Enum.all?(card.external_reports, &(&1.attribution == "unverified_cli_report"))
    assert card.run_count == nil
    assert card.acceptance == "incomplete"
    assert card.review_verifications == [%{reviewer_run_id: "verified-review"}]
    assert length(board.unassigned_reports) == 2
    assert IssueBoard.filter(board, "review").cards == [card]
  end

  test "ready, waiting, blocked and retrying are distinct current observations" do
    ready = %{project: "one", issue_identifier: "GH-ready", title: "Ready without a native ID"}
    blocked = issue("blocked", "GH-blocked", last_message: "A retained blocking explanation")
    retry = issue("retry", "GH-retry", error: "No available slot")
    waiting = issue("waiting", "GH-waiting")
    nameless = %{project: "one", issue_id: "opaque", title: "Identifier not reported"}
    invalid = %{project: "one", title: "Cannot safely identify this record"}
    malformed_pull = %{project: "one", issue_identifier: "PR-invalid", labels: [%{name: "not a native string"}]}

    payload = %{
      upcoming: %{ready: [ready, nameless, invalid, malformed_pull], waiting: [waiting]},
      blocked: [blocked],
      retrying: [retry]
    }

    cards = IssueBoard.build(payload, @day).cards
    assert length(cards) == 6
    find = fn id -> Enum.find(cards, &(&1.issue_identifier == id)) end
    assert find.("GH-ready").phase == "Ready"
    assert find.("GH-waiting").phase == "Waiting"
    assert find.("GH-blocked").phase == "Blocked"
    assert find.("GH-blocked").summary == "A retained blocking explanation"
    assert find.("GH-retry").phase == "Retry scheduled"
    assert find.("GH-retry").summary == "No available slot"
    assert find.("PR-invalid").labels == []
  end

  test "ambiguous PR ownership cannot pick an arbitrary issue" do
    first = association(issue("1", "GH-1"), sources: [%{pr_number: 7}])
    second = association(issue("2", "GH-2"), sources: [%{pr_number: 7}])
    review = %{project: "one", issue_identifier: "PR-7", pr_number: nil}

    payload = %{
      running: [review],
      usage: %{delivery_metrics: %{issue_associations: [first, second]}}
    }

    board = IssueBoard.build(payload, @day)
    assert length(board.cards) == 3
    assert Enum.find(board.cards, &(&1.issue_identifier == "PR-7")).lane == "active"

    assert Enum.all?(
             Enum.filter(board.cards, &(&1.issue_identifier in ["GH-1", "GH-2"])),
             &(&1.lane == "intake" and is_nil(&1.merged))
           )
  end

  test "run order uses recorded timestamps and ambiguous area labels stay unavailable" do
    item = issue("1", "GH-1", labels: ["area:runtime", "area:product"])

    delivery =
      association(item,
        attempts: [
          %{run_id: "late", status: "completed", started_s: 10},
          %{run_id: "early", status: "failed", started_s: 2},
          %{run_id: "unknown", status: "stopped"}
        ]
      )

    active = Map.merge(item, %{run_id: "now", started_at: @today})
    payload = %{running: [active], usage: %{delivery_metrics: %{issue_associations: [delivery]}}}
    [card] = IssueBoard.build(payload, @day).cards
    assert Enum.map(card.runs, & &1.run_id) == ["unknown", "early", "late", "now"]
    assert card.area == nil
  end

  test "closed PRs, UTC-normalized timestamps and undated history retain their evidence limits" do
    {:ok, offset, _} = DateTime.from_iso8601("2026-11-02T01:00:00+03:00")
    closed = association(issue("1", "GH-1"), state: "closed", closed_at: offset)
    unknown = association(issue("2", "GH-2"), state: nil)

    payload = %{
      usage: %{
        delivery_metrics: %{issue_associations: [closed, unknown]},
        activity: [%{project: "one", kind: "pr_closed", pr_number: 12, at: @today}]
      }
    }

    today = IssueBoard.build(payload, @day)
    assert hd(today.cards).phase == "PR closed; acceptance unavailable"
    assert hd(today.cards).acceptance == nil
    assert Enum.map(today.history_cards, & &1.issue_identifier) == ["GH-2"]
    assert hd(IssueBoard.build(payload, "2026-11-01").cards).issue_identifier == "GH-1"
    assert IssueBoard.filter(today, "prs").history_cards == today.history_cards
  end

  defp issue(id, identifier, overrides \\ []) do
    Map.merge(%{project: "one", issue_id: id, issue_identifier: identifier}, Map.new(overrides))
  end

  defp association(issue, overrides \\ []) do
    issue
    |> Map.merge(%{state: "open", acceptance_proof: "incomplete", attempts: [], sources: []})
    |> Map.merge(Map.new(overrides))
  end

  defp event(identifier, kind, at), do: %{project: "one", issue_identifier: identifier, kind: kind, at: at}
end
