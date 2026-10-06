defmodule SymphonyElixir.HandoffTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Autopilot, Handoff, Operations}
  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Tracker.Issue

  @settings %{
    kind: "github",
    provider: %{"repo" => "octo/repo", "token" => "offline"},
    active_states: ["open"],
    terminal_states: ["closed"],
    required_labels: ["crescendo:ready"],
    excluded_labels: ["crescendo:hold"]
  }
  @empty %{pr_handled: %{}, tasks: %{}, item_attempts: %{}}

  test "contract rejects absent, malformed, duplicated and unsupported replacement records" do
    assert Handoff.instructions() =~ "Do not create or promote a ready replacement"
    assert Handoff.record(%Issue{}) == nil
    assert Handoff.record(%Issue{kind: :pull_request, description: "## replacement of #1"}) == nil
    assert Handoff.record(%Issue{description: "ordinary replacement details"}) == nil
    assert Handoff.record(%Issue{description: "## Full required replacement of unaccepted #1184"}) == :invalid

    invalid_records = Enum.map([%{"scope" => " "}, %{"change" => "unchanged"}, %{"owner" => 0}, %{"evidence" => "456"}], &marker/1)
    bodies = ["<!-- crescendo:handoff nope -->", "<!-- crescendo:handoff truncated", marker() <> marker() | invalid_records]

    for body <- bodies do
      assert Handoff.record(%Issue{description: body}) == :invalid
    end
  end

  test "no-source replacement chain admits only the root and keeps its bounded budget" do
    # Offline excerpts from the GH-49 retrospective: every production outcome remains unaccepted.
    fixture = fixture()
    [root, second, third] = Enum.map(fixture["gas_owner"], &raw(&1["number"], &1["body"]))
    assert {:ok, [owner, a, b]} = poll([root, second, third])
    assert owner.dispatchable
    refute a.dispatchable
    refute b.dispatchable
    {state, 1} = Autopilot.record_failed_attempt(@empty, owner.id)
    {state, 2} = Autopilot.record_failed_attempt(state, owner.id)
    {state, 3} = Autopilot.record_failed_attempt(state, owner.id)
    state = Autopilot.prune_pull_requests(state, [a, b])
    assert Autopilot.exhausted?(state, owner.id, %{max_item_attempts: 3})
    assert state.item_attempts == %{"1184" => 3}
    assert Enum.filter([a, b], &Issue.routable?(&1, ["crescendo:ready"])) == []
  end

  test "legacy replacements cannot claim their own issue number as a canonical root" do
    replacement = raw(123, "## Replacement of #122\n" <> marker())
    assert {:ok, [direct]} = poll([replacement])
    owner = Map.merge(replacement, %{"state" => "closed", "created_at" => "2026-10-01T00:00:00Z"})
    proof = %{"merged_at" => "2026-10-02T00:00:00Z", "body" => "Closes #123"}
    responses = %{"/repos/octo/repo/issues/123" => owner, "/repos/octo/repo/pulls/456" => proof}
    assert {:ok, [successor]} = poll([raw(124, marker())], responses)
    assert [direct.dispatchable, successor.dispatchable] == [false, false]

    authorized = marker(%{"owner" => 122})
    root = raw(122, authorized) |> Map.merge(%{"state" => "closed", "created_at" => "2026-10-01T00:00:00Z"})
    proof = %{proof | "body" => "Closes #122"}
    responses = %{"/repos/octo/repo/issues/122" => root, "/repos/octo/repo/pulls/456" => proof}
    assert {:ok, [verified]} = poll([raw(123, "## Replacement of #122\n" <> authorized)], responses)
    assert verified.dispatchable
    assert verified.delivery_key == "handoff:122:partial_delivery:456"
  end

  test "fresh accepted partial delivery gets one budget and proof replay cannot restart it" do
    owner = raw(123, marker()) |> Map.merge(%{"state" => "closed", "created_at" => "2026-10-01T00:00:00Z"})
    proof = %{"merged_at" => "2026-10-02T00:00:00Z", "body" => "Closes #123"}
    responses = %{"/repos/octo/repo/issues/123" => owner, "/repos/octo/repo/pulls/456" => proof}
    assert {:ok, [a, b]} = poll([raw(124, marker()), raw(125, marker())], responses)
    assert a.dispatchable and b.dispatchable
    assert a.delivery_key == b.delivery_key
    {state, [a, b]} = Autopilot.admit_handoffs(@empty, [a, b])
    assert a.dispatchable
    refute b.dispatchable
    key = Autopilot.delivery_key(a)
    {state, 1} = Autopilot.record_failed_attempt(state, key)
    {state, 2} = Autopilot.record_failed_attempt(state, key)
    assert Autopilot.final_run?(state, a, %{max_item_attempts: 3})
    {state, 3} = Autopilot.record_failed_attempt(state, key)
    state = Autopilot.prune_pull_requests(state, [])
    assert Autopilot.exhausted?(state, Autopilot.delivery_key(b), %{max_item_attempts: 3})
    {_, [b]} = Autopilot.admit_handoffs(state, [%{b | dispatchable: true}])
    refute b.dispatchable
    {_, [stripped]} = Autopilot.admit_handoffs(state, [%{a | delivery_key: nil}])
    refute stripped.dispatchable

    for modified <- [%{a | delivery_key: "handoff:123:partial_delivery:999"}, %{a | id: "126", delivery_key: "handoff:124:partial_delivery:999"}] do
      {_, [rebound]} = Autopilot.admit_handoffs(state, [modified])
      refute rebound.dispatchable
    end

    assert Autopilot.delivery_key(%Issue{id: "unrelated"}) == "unrelated"
    {_, [pr, blocked]} = Autopilot.admit_handoffs(state, [%Issue{kind: :pull_request}, %{a | dispatchable: false}])
    assert pr.kind == :pull_request
    refute blocked.dispatchable
  end

  test "partial evidence must be merged, owned, authorized and newer than the outcome" do
    owner = raw(123, marker()) |> Map.merge(%{"state" => "closed", "created_at" => "2026-10-01T00:00:00Z"})

    for proof <- [
          %{},
          %{"merged_at" => nil, "body" => "Closes #123"},
          %{"merged_at" => "2026-10-02T00:00:00Z", "body" => "Depends on #123"},
          %{"merged_at" => "2026-09-01T00:00:00Z", "body" => "Closes #123"}
        ] do
      assert {:ok, [issue]} = poll([raw(124, marker())], %{"/repos/octo/repo/issues/123" => owner, "/repos/octo/repo/pulls/456" => proof})
      refute issue.dispatchable
    end

    for owner <- [%{owner | "state" => "open"}, %{owner | "body" => "unaccepted"}] do
      assert {:ok, [issue]} = poll([raw(124, marker())], %{"/repos/octo/repo/issues/123" => owner})
      refute issue.dispatchable
    end
  end

  test "quiet-window prerequisite only progresses when newly completed, with its native edge intact" do
    assert fixture()["quiet_window"]["canonical_owner"] == 1168
    text = marker(%{"owner" => 1168, "change" => "prerequisite", "evidence" => 1169})
    owner = raw(1168, text) |> Map.merge(%{"state" => "closed", "closed_at" => "2026-10-03T00:00:00Z"})
    path = "/repos/octo/repo/issues/1168/dependencies/blocked_by"

    for {state, reason, closed_at, expected} <- [
          {"open", nil, nil, false},
          {"closed", "not_planned", "2026-10-04T00:00:00Z", false},
          {"closed", "completed", "2026-10-02T00:00:00Z", false},
          {"closed", "completed", "2026-10-04T00:00:00Z", true}
        ] do
      proof = raw(1169, "Owner-confirmed quiet-window evidence") |> Map.merge(%{"state" => state, "state_reason" => reason, "closed_at" => closed_at})
      responses = %{"/repos/octo/repo/issues/1168" => owner, path => [proof], "/repos/octo/repo/issues/1169" => proof}
      assert {:ok, [successor]} = poll([raw(1170, text)], responses)
      assert successor.dispatchable == expected
    end

    assert {:ok, [successor]} = poll([raw(1170, text)], %{"/repos/octo/repo/issues/1168" => owner})
    refute successor.dispatchable
  end

  test "successors cannot omit unchanged native prerequisites or bypass a held canonical owner" do
    root = raw(123, marker()) |> Map.merge(%{"state" => "closed", "created_at" => "2026-10-01T00:00:00Z"})
    proof = %{"merged_at" => "2026-10-02T00:00:00Z", "body" => "Closes #123"}
    blocker = raw(900, "Required capability still unavailable")
    responses = %{"/repos/octo/repo/issues/123" => root, "/repos/octo/repo/pulls/456" => proof, "/repos/octo/repo/issues/123/dependencies/blocked_by" => [blocker]}
    assert {:ok, [missing]} = poll([raw(124, marker())], responses)
    refute missing.dispatchable
    responses = Map.put(responses, "/repos/octo/repo/issues/124/dependencies/blocked_by", [blocker])
    assert {:ok, [waiting]} = poll([raw(124, marker())], responses)
    refute waiting.dispatchable
    assert [%{id: "10900"}] = waiting.blocked_by
    completed = Map.merge(blocker, %{"state" => "closed", "state_reason" => "completed"})

    responses =
      responses
      |> Map.put("/repos/octo/repo/issues/123/dependencies/blocked_by", [completed])
      |> Map.put("/repos/octo/repo/issues/124/dependencies/blocked_by", [completed])

    assert {:ok, [ready]} = poll([raw(124, marker())], responses)
    assert ready.dispatchable
    responses = Map.put(responses, "/repos/octo/repo/issues/123", Map.put(root, "labels", ["crescendo:hold"]))
    assert {:ok, [held]} = poll([raw(124, marker())], responses)
    refute held.dispatchable
  end

  test "a prerequisite in another repository with the same issue number is no proof" do
    text = marker(%{"change" => "prerequisite"})
    root = raw(123, text) |> Map.merge(%{"state" => "closed", "closed_at" => "2026-10-03T00:00:00Z"})
    foreign = raw(456, "Foreign prerequisite") |> Map.merge(%{"id" => 99_999, "state" => "closed", "state_reason" => "completed"})
    local = raw(456, "Unrelated local issue") |> Map.merge(%{"state" => "closed", "state_reason" => "completed", "closed_at" => "2026-10-04T00:00:00Z"})
    responses = %{"/repos/octo/repo/issues/123" => root, "/repos/octo/repo/issues/123/dependencies/blocked_by" => [foreign], "/repos/octo/repo/issues/456" => local}
    assert {:ok, [issue]} = poll([raw(124, text)], responses)
    refute issue.dispatchable
  end

  test "retired quiet-window owner remains unsatisfied for all retained successors" do
    quiet = fixture()["quiet_window"]

    owner =
      raw(quiet["canonical_owner"], quiet["required_external_outcome"])
      |> Map.merge(%{"state" => "closed", "state_reason" => "not_planned"})

    successors = Enum.map(quiet["dependent_successors"], &raw(&1, "Wrapped acceptance requires the same quiet window"))

    responses =
      Map.new(successors, fn issue ->
        {"/repos/octo/repo/issues/#{issue["number"]}/dependencies/blocked_by", [owner]}
      end)

    assert {:ok, issues} = poll(successors, responses)
    assert Enum.all?(issues, &(not &1.dispatchable))
    assert Enum.all?(issues, &match?([%{state_reason: "not_planned"}], &1.blocked_by))
    {state, 1} = Autopilot.record_failed_attempt(@empty, "1168")
    {state, 2} = Autopilot.record_failed_attempt(state, "1168")
    {state, 3} = Autopilot.record_failed_attempt(state, "1168")
    state = Autopilot.prune_pull_requests(state, issues)
    assert Autopilot.exhausted?(state, "1168", %{max_item_attempts: 3})
    assert Enum.filter(issues, &Issue.routable?(&1, ["crescendo:ready"])) == []
  end

  test "authorization and budget ownership survive operations restart" do
    path = Path.join(System.tmp_dir!(), "handoff-#{System.unique_integer([:positive])}.dets")
    name = :handoff_regression
    {:ok, table} = Operations.open(path, name)
    {state, [_]} = Autopilot.admit_handoffs(@empty, [%Issue{id: "124", delivery_key: "handoff:123:partial_delivery:456", dispatchable: true}])
    {state, 3} = Autopilot.record_failed_attempt(%{state | item_attempts: %{"handoff:123:partial_delivery:456" => 2}}, "handoff:123:partial_delivery:456")
    :ok = Operations.save_autopilot_state(table, state)
    :ok = Operations.close(table)
    {:ok, table} = Operations.open(path, name)
    restored = Operations.autopilot_state(table)
    assert restored.item_attempts == state.item_attempts
    assert restored.handoff_owners == state.handoff_owners
    :ok = Operations.close(table)
    File.rm!(path)
  end

  test "unrelated issues, canonical owner records and native dependency owners remain untouched" do
    owner = raw(123, marker())
    unrelated = raw(200, "Replace a component; see #123 for context")
    blocked = raw(201, "Unrelated blocked outcome")
    dependency = raw(202, "Required capability")
    responses = %{"/repos/octo/repo/issues/201/dependencies/blocked_by" => [dependency]}
    assert {:ok, [canonical, ordinary, waiting, capability]} = poll([owner, unrelated, blocked, dependency], responses)
    assert canonical.dispatchable and ordinary.dispatchable and capability.dispatchable
    refute waiting.dispatchable
    assert [%{id: "10202", state: "open"}] = waiting.blocked_by
    fetch = request(%{"/repos/octo/repo/issues/124" => raw(124, marker())})
    assert {:ok, [refreshed]} = Client.fetch_issues_by_ids_for_test(["124"], @settings, fetch)
    refute refreshed.dispatchable
  end

  defp fixture do
    Path.expand("../fixtures/unchanged-handoffs.json", __DIR__) |> File.read!() |> Jason.decode!()
  end

  defp marker(overrides \\ %{}) do
    record = Map.merge(%{"owner" => 123, "change" => "partial_delivery", "evidence" => 456, "scope" => "Accepted fixture validity; all production repair remains required"}, overrides)
    "<!-- crescendo:handoff " <> Jason.encode!(record) <> " -->"
  end

  defp raw(number, body), do: %{"id" => number + 10_000, "number" => number, "title" => "Outcome #{number}", "state" => "open", "body" => body, "labels" => ["crescendo:ready"]}

  defp poll(issues, responses \\ %{}), do: Client.fetch_issues_by_states_for_test(["open"], @settings, request(Map.put(responses, "/repos/octo/repo/issues", issues)))

  defp request(responses) do
    fn "GET", path, _params, nil, _settings ->
      {:ok, %{status: 200, body: Map.get(responses, path, [])}}
    end
  end
end
