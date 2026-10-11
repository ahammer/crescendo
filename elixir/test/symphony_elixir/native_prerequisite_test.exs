defmodule SymphonyElixir.NativePrerequisiteTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Client, as: GitHub
  alias SymphonyElixir.{Operations, Tracker}

  # Scrubbed #72/#1258 identities; no private producer content or live tracker writes.
  @consumer "/repos/fixture/consumer/issues/72"
  @producer "/repos/fixture/producer/issues/1258"
  @edge @consumer <> "/dependencies/blocked_by"

  defmodule ReplayClient do
    alias SymphonyElixir.{Config, GitHub.Client}

    def fetch_issues_by_states(states),
      do: Client.fetch_issues_by_states_for_test(states, Config.settings!().tracker, &request/5)

    def fetch_issues_by_ids(ids),
      do: Client.fetch_issues_by_ids_for_test(ids, Config.settings!().tracker, &request/5)

    def clear_label(issue, label),
      do: Client.clear_label_for_test(issue, label, Config.settings!().tracker, &request/5)

    def retire(issue, reason),
      do: Client.retire_for_test(issue, reason, Config.settings!().tracker, &request/5)

    def request(method, path, _params, body, _settings) do
      Agent.get_and_update(__MODULE__, fn state -> respond(method, path, body, state) end)
    end

    defp respond("GET", "/repos/fixture/consumer/issues", _, state), do: {ok(Enum.filter(state.issues, &(&1["state"] == "open"))), state}
    defp respond("GET", "/repos/fixture/consumer/pulls", _, state), do: {ok([]), state}

    defp respond("GET", path, _, state) do
      cond do
        String.ends_with?(path, "/dependencies/blocked_by") ->
          result = if String.contains?(path, "/72/"), do: state.read, else: ok([])
          {result, state}

        path == "/repos/fixture/producer/issues/1258" ->
          {ok(state.producer), state}

        true ->
          number = path |> Path.basename() |> String.to_integer()
          {ok(Enum.find(state.issues, &(&1["number"] == number))), state}
      end
    end

    defp respond("POST", path, %{"issue_id" => id}, state) do
      assert_path = "/repos/fixture/consumer/issues/72/dependencies/blocked_by"
      true = path == assert_path and id == state.producer["id"]

      if state.attached do
        {{:ok, %{status: 422, body: %{"message" => "already exists"}}}, state}
      else
        # GitHub applied the write but the worker lost its response.
        {{:error, :timeout}, %{state | attached: true, read: ok([state.producer])}}
      end
    end

    defp respond("DELETE", path, _, state) do
      issues = Enum.map(state.issues, fn issue -> if String.contains?(path, "/#{issue["number"]}/"), do: Map.put(issue, "labels", [%{"name" => "crescendo:ready"}]), else: issue end)
      {ok(%{}), %{state | issues: issues}}
    end

    defp respond("POST", _path, %{"body" => _}, state), do: {ok(%{}), state}

    defp respond("PATCH", path, body, state) do
      issues = Enum.map(state.issues, fn issue -> if String.ends_with?(path, "/#{issue["number"]}"), do: Map.merge(issue, body), else: issue end)
      {ok(%{}), %{state | issues: issues}}
    end

    defp ok(body), do: {:ok, %{status: 200, body: body}}
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :github_client_module)
    repo = System.get_env("GITHUB_REPO")
    token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_REPO", "fixture/consumer")
    System.put_env("GITHUB_TOKEN", "offline-fixture")
    Application.put_env(:symphony_elixir, :github_client_module, ReplayClient)

    on_exit(fn ->
      restore_env("GITHUB_REPO", repo)
      restore_env("GITHUB_TOKEN", token)

      if previous do
        Application.put_env(:symphony_elixir, :github_client_module, previous)
      else
        Application.delete_env(:symphony_elixir, :github_client_module)
      end
    end)

    root = Path.dirname(Workflow.workflow_file_path())
    File.write!(Path.join(root, "research.md"), "Research")
    File.write!(Path.join(root, "review.md"), "Review")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      extra_config: %{"labels" => %{"prefix" => "crescendo"}},
      tracker_active_states: ["open"],
      tracker_terminal_states: ["closed"],
      tracker_required_labels: ["crescendo:ready"],
      workspace_root: Path.join(root, "workspaces"),
      poll_interval_ms: 3_600_000,
      max_concurrent_agents: 1,
      hook_before_run: "sleep 30",
      autopilot: %{
        "enabled" => true,
        "repo_tasks" => false,
        "max_open_issues" => 1,
        "max_item_attempts" => 3,
        "channels" => %{"fixture" => "Unused"},
        "prompts" => %{"research" => "research.md", "pull_request" => "review.md"}
      }
    )

    consumer = raw(72, "consumer")
    producer = raw(1258, "producer")
    initial = %{issues: [consumer], producer: producer, attached: false, read: ok([])}
    start_supervised!(%{id: ReplayClient, start: {Agent, :start_link, [fn -> initial end, [name: ReplayClient]]}})
    path = Path.join(root, "native.dets")
    {:ok, table} = Operations.open(path, :native_prerequisite_replay)
    # The historical consumer had reached its final logical attempt before attachment.
    finished = %{finished_at: DateTime.add(DateTime.utc_now(), 1, :day), attempts: 0, last: :delivered}
    :ok = Operations.save_autopilot_state(table, %{item_attempts: %{"72" => 2}, tasks: %{"fixture" => finished}})
    Operations.close(table)
    supervisor = start_supervised!(Task.Supervisor)
    opts = [name: :native_replay, task_supervisor: supervisor, operations_path: path, operations_table: table]
    %{opts: opts, producer: producer}
  end

  test "native attachment retains preparation and budget through reconciliation and restart", context do
    %{opts: opts, producer: producer} = context
    assert {:ok, [issue]} = Tracker.fetch_issues_by_ids(["72"])
    assert {:ok, workspace} = Workspace.create_for_issue(issue)
    File.write!(Path.join(workspace, "evidence.md"), "Retained preparation; producer acceptance still unmet")
    {_, 0} = System.cmd("git", ["init", "-q", workspace])
    {_, 0} = System.cmd("git", ["add", "evidence.md"], cd: workspace)
    {_, 0} = System.cmd("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.org", "commit", "-qm", "preparation"], cd: workspace)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)

    pid = start_supervised!({Orchestrator, opts})
    poll(pid)
    entry = :sys.get_state(pid).running["72"]
    assert entry.item_attempt == 3 and entry.final_attempt
    assert Process.alive?(entry.pid)

    assert Enum.any?(1..100, fn _ ->
             Process.sleep(10)
             :sys.get_state(pid).running["72"].workspace_path == workspace
           end)

    assert {:ok, %{body: ^producer}} = api("GET", @producer)
    assert {:ok, %{body: []}} = api("GET", @edge)
    parent = self()

    intake =
      Task.async(fn ->
        assert {:ok, %{body: []}} = api("GET", @edge)
        send(parent, :intake_saw_absence)

        receive do
          :attach -> :ok
        after
          5_000 -> flunk("worker did not attach the prerequisite")
        end

        assert {:ok, %{status: 422}} = api("POST", @edge, %{"issue_id" => producer["id"]})
        assert {:ok, %{body: [^producer]}} = api("GET", @edge)
      end)

    assert_receive :intake_saw_absence, 1_000
    assert {:error, :timeout} = api("POST", @edge, %{"issue_id" => producer["id"]})
    # Uncertain mutation recovery reads the exact edge before considering another write.
    assert {:ok, %{body: [^producer]}} = api("GET", @edge)
    # The intake's earlier absence read races the worker's successful write.
    send(intake.pid, :attach)
    assert {:ok, %{body: [^producer]}} = Task.await(intake)
    assert {:ok, [blocked]} = Tracker.fetch_issues_by_ids(["72"])
    refute blocked.dispatchable
    poll(pid)
    state = :sys.get_state(pid)
    assert state.running == %{}
    refute Process.alive?(entry.pid)
    refute MapSet.member?(state.claimed, "72")
    assert state.autopilot.item_attempts == %{"72" => 2}
    assert state.retry_attempts == %{}
    assert Enum.any?(Orchestrator.snapshot(pid, 5_000).operations.activity, &(&1.kind == "stopped" and &1.issue_identifier == "GH-72"))

    Agent.update(ReplayClient, &%{&1 | issues: &1.issues ++ [raw(73, "consumer")]})
    for _ <- 1..3, do: poll(pid)
    assert Map.keys(:sys.get_state(pid).running) == ["73"]
    assert :sys.get_state(pid).autopilot.item_attempts == %{"72" => 2}
    stop_supervised!(Orchestrator)
    Agent.update(ReplayClient, &%{&1 | issues: Enum.filter(&1.issues, fn issue -> issue["number"] == 72 end)})
    pid = start_supervised!({Orchestrator, opts})
    poll(pid)
    assert :sys.get_state(pid).running == %{}
    assert :sys.get_state(pid).autopilot.item_attempts == %{"72" => 2}
    assert {^sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
    assert File.read!(Path.join(workspace, "evidence.md")) =~ "acceptance still unmet"

    # A different repository's completed same-number issue does not satisfy the open native producer.
    unrelated = raw(1258, "unrelated") |> Map.merge(%{"id" => 999, "state" => "closed", "state_reason" => "completed"})
    Agent.update(ReplayClient, &%{&1 | read: ok([producer, unrelated])})
    assert {:ok, [same_number]} = Tracker.fetch_issues_by_ids(["72"])
    producer_id = to_string(producer["id"])
    assert [%{id: ^producer_id, state: "open"}, %{id: "999", state: "closed"}] = same_number.blocked_by
    refute same_number.dispatchable
    poll(pid)
    assert :sys.get_state(pid).running == %{}

    for read <- [ok([Map.merge(producer, %{"state" => "closed", "state_reason" => "not_planned"})]), {:error, :unavailable}, ok(%{}), ok([%{"number" => 1258}])] do
      Agent.update(ReplayClient, &%{&1 | read: read})
      poll(pid)
      assert :sys.get_state(pid).running == %{}
      assert :sys.get_state(pid).autopilot.item_attempts == %{"72" => 2}
    end

    completed = Map.merge(producer, %{"state" => "closed", "state_reason" => "completed", "closed_at" => "2026-10-11T01:20:29Z"})
    Agent.update(ReplayClient, &%{&1 | producer: completed, read: ok([completed])})
    poll(pid)
    resumed = :sys.get_state(pid).running["72"]
    assert resumed.pid != entry.pid
    assert resumed.issue.id == "72" and resumed.issue.delivery_key == entry.issue.delivery_key
    assert resumed.item_attempt == 3 and resumed.final_attempt
    assert {^sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
    assert :sys.get_state(pid).autopilot.item_attempts == %{"72" => 2}
    refute Enum.any?(Orchestrator.snapshot(pid, 5_000).operations.activity, &(&1.kind == "attempt_failed"))

    # Completion of the producer does not renew the consumer's final-attempt policy.
    Agent.update(ReplayClient, fn state ->
      %{state | issues: Enum.map(state.issues, &Map.put(&1, "labels", [%{"name" => "crescendo:ready"}, %{"name" => "crescendo:blocked"}]))}
    end)

    poll(pid)
    retired = :sys.get_state(pid)
    assert retired.running == %{}
    refute Process.alive?(resumed.pid)
    assert retired.autopilot.item_attempts == %{"72" => 3}
    assert retired.autopilot.retired_items["72"]
    assert {:ok, %{body: %{"state" => "closed", "state_reason" => "not_planned"}}} = api("GET", @consumer)
    poll(pid)
    assert :sys.get_state(pid).autopilot.item_attempts == %{"72" => 3}
  end

  defp raw(number, repo) do
    %{
      "id" => number * 10_000,
      "number" => number,
      "title" => "Scrubbed prerequisite replay",
      "state" => "open",
      "repository_url" => "https://api.github.com/repos/fixture/#{repo}",
      "html_url" => "https://github.com/fixture/#{repo}/issues/#{number}",
      "labels" => [%{"name" => "crescendo:ready"}],
      "body" => "Retain source and unmet acceptance on this owner"
    }
  end

  defp api(method, path, body \\ nil), do: GitHub.request(method, path, %{}, body, request_fun: &ReplayClient.request/5)
  defp ok(body), do: {:ok, %{status: 200, body: body}}

  defp poll(pid) do
    send(pid, :run_poll_cycle)
    :sys.get_state(pid)
  end
end
