defmodule SymphonyElixir.AutopilotTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Autopilot, Operations, PromptBuilder}

  @settings %{
    enabled: true,
    min_issues_per_channel: 1,
    channels: %{"testing" => "Tests", "cleanup" => "Cleanup"},
    max_issues_per_channel: 2,
    max_open_issues: 3,
    research_cooldown_ms: 60_000,
    max_pr_runs: 2
  }

  @empty %{pr_handled: %{}, research_finished_at: nil, research_pending: []}

  defmodule CiClient do
    def fetch_commit_ci_state(sha) do
      send(Application.get_env(:symphony_elixir, :autopilot_test_pid), {:ci_lookup, sha})
      Application.get_env(:symphony_elixir, :autopilot_test_ci, {:ok, "success"})
    end
  end

  setup do
    previous_client = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, CiClient)
    Application.put_env(:symphony_elixir, :autopilot_test_pid, self())

    on_exit(fn ->
      if previous_client,
        do: Application.put_env(:symphony_elixir, :github_client_module, previous_client),
        else: Application.delete_env(:symphony_elixir, :github_client_module)

      Application.delete_env(:symphony_elixir, :autopilot_test_pid)
      Application.delete_env(:symphony_elixir, :autopilot_test_ci)
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
    end)

    :ok
  end

  describe "pull request policy" do
    test "a pull request waits once its head is handled or its run cap is reached" do
      pr = pull_request("7", "sha-1")

      assert Autopilot.pull_request_ready?(pr, @empty, @settings)
      assert Autopilot.pull_request_ready?(%Issue{kind: :issue}, @empty, @settings)
      assert Autopilot.pull_request_waiting_reason(%Issue{kind: :issue}, @empty, @settings) == nil

      state = Autopilot.record_pull_dispatch(@empty, pr)
      assert state.pr_handled == %{"7" => %{runs: 1}}
      assert Autopilot.pull_request_ready?(pr, state, @settings)

      assert Autopilot.dispatched_head(pr) == "sha-1"
      assert Autopilot.dispatched_head(%Issue{kind: :issue}) == nil
      state = Autopilot.record_pull_handled(state, pr, "sha-1")
      assert Autopilot.pull_request_waiting_reason(pr, state, @settings) == "reviewed at current head"
      assert Autopilot.pull_request_ready?(pull_request("7", "sha-2"), state, @settings)

      state = Autopilot.record_pull_dispatch(state, pr)
      assert Autopilot.pull_request_waiting_reason(pull_request("7", "sha-2"), state, @settings) == "review run cap reached"

      assert Autopilot.pull_request_waiting_reason(%Issue{kind: :pull_request, id: "8"}, @empty, @settings) ==
               "pull request details unavailable"

      assert Autopilot.record_pull_dispatch(@empty, %Issue{kind: :issue}) == @empty
      assert Autopilot.record_pull_handled(@empty, %Issue{kind: :pull_request, id: "8"}, nil) == @empty

      assert Autopilot.prune_pull_requests(state, [%Issue{kind: :issue, id: "7"}]).pr_handled == %{}
      assert Autopilot.prune_pull_requests(state, [pr]).pr_handled == state.pr_handled
    end
  end

  describe "research policy" do
    test "research runs as sequential rounds over every channel, then cools down" do
      now = ~U[2026-09-25 12:00:00Z]

      assert {@empty, nil} = Autopilot.next_research(@empty, %{@settings | enabled: false}, 0, now)
      assert {@empty, nil} = Autopilot.next_research(@empty, @settings, 3, now)

      # A fresh round covers every channel in name order, one at a time.
      assert {state, %Issue{id: "research:cleanup"}} = Autopilot.next_research(@empty, @settings, 0, now)
      assert state.research_pending == ["cleanup", "testing"]
      assert {^state, %Issue{id: "research:cleanup"}} = Autopilot.next_research(state, @settings, 0, now)

      state = Autopilot.record_research_finished(state, "cleanup", now)
      assert state.research_pending == ["testing"]
      assert state.research_finished_at == nil

      # An unfinished round continues without waiting for the cooldown, but still respects the backlog.
      assert {_, %Issue{id: "research:testing"}} = Autopilot.next_research(state, @settings, 2, now)
      assert {_, nil} = Autopilot.next_research(state, @settings, 3, now)

      state = Autopilot.record_research_finished(state, "testing", now)
      assert state == %{@empty | research_finished_at: now}
      assert {_, nil} = Autopilot.next_research(state, @settings, 0, DateTime.add(now, 59, :second))
      assert {_, %Issue{id: "research:cleanup"}} = Autopilot.next_research(state, @settings, 0, DateTime.add(now, 60, :second))

      # Channels removed from config drop out of a pending round.
      stale = %{@empty | research_pending: ["removed", "testing"]}
      assert {%{research_pending: ["testing"]}, %Issue{id: "research:testing"}} = Autopilot.next_research(stale, @settings, 0, now)
    end

    test "research items are synthetic, per channel, and never tracker backed" do
      assert [cleanup, testing] = Autopilot.research_items(@settings)

      assert %Issue{
               id: "research:cleanup",
               identifier: "research-cleanup",
               kind: :research,
               state: "research",
               labels: ["symphony:research", "symphony:channel:cleanup"],
               research: %{channel: "cleanup", focus: "Cleanup", min_issues: 1, max_issues: 2}
             } = cleanup

      assert testing.id == "research:testing"
      refute Issue.tracker_backed?(cleanup)
      assert Issue.tracker_backed?(pull_request("7", "sha"))
    end
  end

  describe "workflow and prompts" do
    test "autopilot config validates, loads prompt files, and renders per-kind prompts" do
      prompts_dir = Path.join(Path.dirname(Workflow.workflow_file_path()), "prompts")
      File.mkdir_p!(prompts_dir)
      File.write!(Path.join(prompts_dir, "pr.md"), "Review {{ issue.identifier }} at {{ issue.pull_request.head_sha }} ({{ issue.kind }})")
      File.write!(Path.join(prompts_dir, "research.md"), "Research {{ issue.research.channel }}: {{ issue.research.focus }} (max {{ issue.research.max_issues }})")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        autopilot: %{
          enabled: true,
          trusted_associations: [" owner "],
          trusted_authors: [" AdamH "],
          prompts: %{pull_request: "prompts/pr.md", research: "prompts/research.md"}
        }
      )

      assert :ok = Config.validate!()
      autopilot = Config.settings!().autopilot
      assert autopilot.trusted_associations == ["OWNER"]
      assert autopilot.trusted_authors == ["adamh"]
      assert Map.keys(autopilot.channels) == ["cleanup", "optimization", "testing"]

      assert PromptBuilder.build_prompt(pull_request("7", "sha-1")) == "Review PR-7 at sha-1 (pull_request)"

      [research | _] = Autopilot.research_items(autopilot)
      assert PromptBuilder.build_prompt(research) =~ "Research cleanup: Dead code"
      assert PromptBuilder.build_prompt(research) =~ "(max 3)"

      File.write!(Path.join(prompts_dir, "pr.md"), "Updated {{ issue.identifier }}")
      assert :ok = WorkflowStore.force_reload()
      assert PromptBuilder.build_prompt(pull_request("7", "sha-1")) == "Updated PR-7"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        autopilot: %{prompts: %{pull_request: "prompts/missing.md"}}
      )

      assert {:error, {:missing_prompt_file, missing_path, :enoent}} = Workflow.load()
      assert String.ends_with?(missing_path, "prompts/missing.md")
    end

    test "autopilot config rejects bad channels, prompts, trackers, and missing prompts" do
      invalid = [
        {%{channels: %{}}, "autopilot.channels"},
        {%{channels: %{"Bad Name" => "x"}}, "autopilot.channels"},
        {%{prompts: %{other: "x.md"}}, "autopilot.prompts"},
        {%{max_pr_runs: 0}, "autopilot.max_pr_runs"},
        {%{min_issues_per_channel: 4, max_issues_per_channel: 3}, "autopilot.min_issues_per_channel"},
        {%{research_route: %{model: "astra", effort: "extreme"}}, "autopilot.research_route"}
      ]

      for {autopilot, field} <- invalid do
        write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", autopilot: autopilot)
        assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
        assert message =~ field
      end

      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", autopilot: %{enabled: true})
      assert {:error, {:invalid_workflow_config, "autopilot requires prompts.pull_request and prompts.research"}} = Config.validate!()

      write_workflow_file!(Workflow.workflow_file_path(), autopilot: %{enabled: true})
      assert {:error, {:invalid_workflow_config, "autopilot requires tracker.kind github"}} = Config.validate!()

      write_workflow_file!(Workflow.workflow_file_path(), prompt: "Issue {{ issue.identifier }}")

      assert_raise RuntimeError, ~r/missing_prompt_template: research/, fn ->
        PromptBuilder.build_prompt(%Issue{kind: :research, identifier: "research-x"})
      end
    end
  end

  describe "shipped workflow" do
    test "WORKFLOW.autopilot.md validates and renders every prompt kind strictly" do
      previous = {System.get_env("GITHUB_REPO"), System.get_env("GITHUB_TOKEN")}
      System.put_env("GITHUB_REPO", "octo/repo")
      System.put_env("GITHUB_TOKEN", "test-token")

      try do
        Workflow.set_workflow_file_path(Path.expand("../../WORKFLOW.autopilot.md", __DIR__))
        assert :ok = Config.validate!()
        settings = Config.settings!()
        assert settings.autopilot.enabled
        assert settings.tracker.excluded_labels == ["symphony:in-review", "symphony:hold", "symphony:needs-attention"]

        issue = %Issue{id: "5", identifier: "GH-5", title: "Fix it", state: "open", url: "https://github.test/5", labels: ["symphony"]}
        assert PromptBuilder.build_prompt(issue, attempt: 2) =~ "symphony/gh-5"

        pull = %{
          number: 7,
          head_sha: "abc",
          head_ref: "feature",
          head_repo: "octo/repo",
          base_ref: "main",
          draft: false,
          can_push: true,
          author: "octocat",
          author_association: "OWNER",
          trusted: true,
          ci_state: "success"
        }

        pr = %Issue{id: "7", kind: :pull_request, identifier: "PR-7", title: "Change", state: "open", url: "https://github.test/7", pull_request: pull}
        assert PromptBuilder.build_prompt(pr) =~ "git fetch origin pull/7/head"

        [research | _] = Autopilot.research_items(settings.autopilot)
        assert PromptBuilder.build_prompt(research) =~ "File **at least 3 and at most 5** issues"
        assert settings.autopilot.research_route == %{"model" => "gpt-6-astra", "effort" => "high"}
      after
        {repo, token} = previous
        restore_env("GITHUB_REPO", repo)
        restore_env("GITHUB_TOKEN", token)
      end
    end
  end

  describe "persistence" do
    test "autopilot state survives reopening the operations table" do
      path = Path.join(System.tmp_dir!(), "autopilot-ops-#{System.unique_integer([:positive])}.dets")
      table = :"autopilot_ops_#{System.unique_integer([:positive])}"

      try do
        assert Operations.autopilot_state(nil) == @empty
        assert :ok = Operations.save_autopilot_state(nil, @empty)

        {:ok, ^table} = Operations.open(path, table)
        assert Operations.autopilot_state(table) == @empty

        saved = %{pr_handled: %{"7" => %{runs: 1, head_sha: "sha"}}, research_finished_at: ~U[2026-09-25 00:00:00Z], research_pending: ["testing"]}
        :ok = Operations.save_autopilot_state(table, saved)
        :ok = Operations.close(table)

        {:ok, ^table} = Operations.open(path, table)
        assert Operations.autopilot_state(table) == saved
        :ok = Operations.close(table)

        assert Operations.autopilot_state(table) == @empty
      after
        File.rm(path)
      end
    end
  end

  describe "orchestrator" do
    test "a ready pull request takes the only slot ahead of an issue" do
      write_autopilot_workflow!(max_concurrent_agents: 1)
      issue = %Issue{id: "1", identifier: "GH-1", title: "Issue", state: "open", dispatchable: true, labels: [], priority: 1}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, pull_request("2", "sha-2")])

      {pid, name} = start_orchestrator!()
      send(pid, :run_poll_cycle)
      state = :sys.get_state(pid)

      assert_received {:ci_lookup, "sha-2"}
      assert Map.keys(state.running) == ["2"]
      assert state.running["2"].issue.pull_request.ci_state == "success"
      assert state.autopilot.pr_handled["2"] == %{runs: 1}
      assert Orchestrator.snapshot(name, 5_000).running |> Enum.map(& &1.identifier) == ["PR-2"]
    end

    test "a pull request with pending or unknown CI is skipped" do
      write_autopilot_workflow!(max_concurrent_agents: 1)
      issue = %Issue{id: "1", identifier: "GH-1", title: "Issue", state: "open", dispatchable: true, labels: []}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, pull_request("2", "sha-2")])
      Application.put_env(:symphony_elixir, :autopilot_test_ci, {:ok, "pending"})

      {pid, _name} = start_orchestrator!()
      send(pid, :run_poll_cycle)
      state = :sys.get_state(pid)

      assert_received {:ci_lookup, "sha-2"}
      assert Map.keys(state.running) == ["1"]
      refute Map.has_key?(state.autopilot.pr_handled, "2")

      Application.put_env(:symphony_elixir, :autopilot_test_ci, {:error, :boom})
      :sys.replace_state(pid, fn state -> %{state | running: %{}, claimed: MapSet.new()} end)

      log =
        capture_log(fn ->
          send(pid, :run_poll_cycle)
          refute Map.has_key?(:sys.get_state(pid).running, "2")
        end)

      assert log =~ "CI lookup failed"
    end

    test "a finished review records its head and waits for a new push" do
      write_autopilot_workflow!()
      pr = pull_request("2", "sha-2")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [pr])

      {pid, name} = start_orchestrator!()
      ref = make_ref()

      # The reviewer pushed a fix mid-run and reconciliation refreshed the head;
      # the run is still recorded at the head it was dispatched at.
      entry = Map.merge(running_entry(pull_request("2", "sha-fix"), ref), %{dispatched_head: "sha-2"})

      # Research is cooling down, so idle polls leave the machine free for the pull request.
      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{"2" => entry},
            claimed: MapSet.new(["2"]),
            autopilot: %{state.autopilot | research_finished_at: DateTime.utc_now()}
        }
      end)

      send(pid, {:DOWN, ref, :process, self(), :normal})
      state = :sys.get_state(pid)

      assert state.autopilot.pr_handled["2"] == %{head_sha: "sha-2"}
      refute Map.has_key?(state.retry_attempts, "2")
      refute MapSet.member?(state.claimed, "2")

      send(pid, :run_poll_cycle)
      refute Map.has_key?(:sys.get_state(pid).running, "2")
      assert [%{issue_identifier: "PR-2", reason: "reviewed at current head"}] = Orchestrator.snapshot(name, 5_000).upcoming.waiting

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [pull_request("2", "sha-3")])
      send(pid, :run_poll_cycle)
      assert Map.has_key?(:sys.get_state(pid).running, "2")
    end

    test "research runs one channel at a time and has the machine to itself" do
      write_autopilot_workflow!()
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      {pid, name} = start_orchestrator!()
      send(pid, :run_poll_cycle)
      state = :sys.get_state(pid)

      assert Map.keys(state.running) == ["research:cleanup"]
      assert state.autopilot.research_pending == ["cleanup", "testing"]

      # Reconciliation must not treat research runs as missing tracker issues, and
      # work that becomes ready waits for the running planner.
      issue = %Issue{id: "1", identifier: "GH-1", title: "Filed", state: "open", dispatchable: true, labels: []}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      send(pid, :run_poll_cycle)
      assert Map.keys(:sys.get_state(pid).running) == ["research:cleanup"]
      assert Orchestrator.snapshot(name, 5_000).autopilot.research_pending == ["cleanup", "testing"]

      finish_running_research(pid, "research:cleanup")
      state = :sys.get_state(pid)
      refute MapSet.member?(state.claimed, "research:cleanup")
      refute Map.has_key?(state.retry_attempts, "research:cleanup")
      assert state.autopilot.research_pending == ["testing"]
      assert state.autopilot.research_finished_at == nil

      # Ready work outranks the rest of the round.
      send(pid, :run_poll_cycle)
      assert Map.keys(:sys.get_state(pid).running) == ["1"]

      # Once idle again, the round resumes with the next channel, then cools down.
      :sys.replace_state(pid, fn state -> %{state | running: %{}, claimed: MapSet.new()} end)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      send(pid, :run_poll_cycle)
      assert Map.keys(:sys.get_state(pid).running) == ["research:testing"]

      finish_running_research(pid, "research:testing")
      state = :sys.get_state(pid)
      assert state.autopilot.research_pending == []
      assert %DateTime{} = state.autopilot.research_finished_at

      send(pid, :run_poll_cycle)
      assert :sys.get_state(pid).running == %{}
    end

    test "draft pull requests wait with an explicit reason, and stopped runs close their record" do
      write_autopilot_workflow!()
      draft_details = %{head_sha: "sha-3", draft: true, trusted: true}
      untrusted_details = %{head_sha: "sha-4", draft: false, trusted: false}
      draft = %{pull_request("3", "sha-3") | dispatchable: false, pull_request: draft_details}
      untrusted = %{pull_request("4", "sha-4") | dispatchable: false, pull_request: untrusted_details}
      pr = pull_request("2", "sha-2")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [draft, untrusted, pr])

      ops_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "ops.dets")
      suffix = System.unique_integer([:positive])
      supervisor = Module.concat(__MODULE__, "StopTasks#{suffix}")
      name = Module.concat(__MODULE__, "StopOrchestrator#{suffix}")
      start_supervised!({Task.Supervisor, name: supervisor})

      table = :"autopilot_stop_ops_#{suffix}"
      opts = [name: name, task_supervisor: supervisor, operations_path: ops_path, operations_table: table]
      pid = start_supervised!({Orchestrator, opts})

      send(pid, :run_poll_cycle)
      assert Map.has_key?(:sys.get_state(pid).running, "2")

      reasons = Orchestrator.snapshot(name, 5_000).upcoming.waiting |> Map.new(&{&1.issue_identifier, &1.reason})
      assert reasons["PR-3"] == "draft"
      assert reasons["PR-4"] == "awaiting maintainer label"

      # The review is running when its pull request closes: reconciliation stops it and records why.
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{pr | state: "closed"}])
      send(pid, :run_poll_cycle)

      activity = Orchestrator.snapshot(name, 5_000).operations.activity
      assert Enum.any?(activity, &(&1.kind == "stopped" and &1.issue_identifier == "PR-2"))
    end

    test "agents keep a short, readable history of Codex events and their route" do
      write_autopilot_workflow!()
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      {pid, _name} = start_orchestrator!()
      ref = make_ref()
      issue = %Issue{id: "9", identifier: "GH-9", title: "Nine", state: "open", url: nil, labels: []}

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"9" => running_entry(issue, ref)}, claimed: MapSet.new(["9"]), autopilot: %{state.autopilot | research_finished_at: DateTime.utc_now()}}
      end)

      send(pid, {:worker_model_route, "9", %{"model" => "gpt-6-sol", "effort" => "high", "label" => "default"}})

      update = fn method, item_id ->
        payload = %{"method" => method, "params" => %{"item" => %{"id" => item_id, "type" => "commandExecution"}, "delta" => "streaming"}}
        send(pid, {:codex_worker_update, "9", %{event: :notification, timestamp: DateTime.utc_now(), payload: payload}})
      end

      update.("item/agentMessage/delta", "delta-item")
      update.("thread/tokenUsage/updated", "usage-item")
      for n <- 1..8, do: update.("item/completed", "item-#{n}")
      update.("item/completed", "item-8")

      entry = :sys.get_state(pid).running["9"]
      assert entry.route == %{model: "gpt-6-sol", effort: "high", label: "default"}
      assert length(entry.recent_events) == 6
      texts = Enum.map(entry.recent_events, & &1.text)
      assert texts == Enum.uniq(texts)
      refute Enum.any?(texts, &(&1 =~ "streaming" or &1 =~ "delta-item" or &1 =~ "usage-item"))
      assert hd(texts) =~ "item-8"
    end

    test "research waits while the backlog is full" do
      write_autopilot_workflow!(autopilot: %{max_open_issues: 1})
      held = %Issue{id: "1", identifier: "GH-1", title: "Held", state: "open", dispatchable: true, labels: ["symphony:hold"]}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [held])

      {pid, name} = start_orchestrator!()
      send(pid, :run_poll_cycle)
      assert :sys.get_state(pid).running == %{}
      assert [%{reason: "excluded by symphony:hold"}] = Orchestrator.snapshot(name, 5_000).upcoming.waiting
    end
  end

  defp pull_request(id, head_sha) do
    %Issue{
      id: id,
      kind: :pull_request,
      identifier: "PR-#{id}",
      title: "Pull #{id}",
      state: "open",
      dispatchable: true,
      labels: [],
      pull_request: %{number: String.to_integer(id), head_sha: head_sha, can_push: true, trusted: true}
    }
  end

  defp finish_running_research(pid, id) do
    %{ref: ref, pid: worker} = :sys.get_state(pid).running[id]
    Process.exit(worker, :kill)
    send(pid, {:DOWN, ref, :process, worker, :boom})
  end

  defp running_entry(issue, ref) do
    %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      started_at: DateTime.utc_now()
    }
  end

  defp write_autopilot_workflow!(overrides \\ []) do
    prompts_dir = Path.join(Path.dirname(Workflow.workflow_file_path()), "prompts")
    File.mkdir_p!(prompts_dir)
    File.write!(Path.join(prompts_dir, "pr.md"), "Review {{ issue.identifier }}")
    File.write!(Path.join(prompts_dir, "research.md"), "Research {{ issue.research.channel }}")

    autopilot =
      Map.merge(
        %{
          enabled: true,
          channels: %{"cleanup" => "Cleanup", "testing" => "Tests"},
          prompts: %{pull_request: "prompts/pr.md", research: "prompts/research.md"}
        },
        Keyword.get(overrides, :autopilot, %{})
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["open"],
      tracker_terminal_states: ["closed"],
      tracker_excluded_labels: ["symphony:hold"],
      poll_interval_ms: 3_600_000,
      workspace_root: Path.join(Path.dirname(Workflow.workflow_file_path()), "workspaces"),
      # Workers park in the hook so no Codex session starts; the tests observe dispatch state.
      hook_before_run: "sleep 30",
      max_concurrent_agents: Keyword.get(overrides, :max_concurrent_agents, 10),
      autopilot: autopilot
    )
  end

  defp start_orchestrator! do
    suffix = System.unique_integer([:positive])
    supervisor = Module.concat(__MODULE__, "Tasks#{suffix}")
    name = Module.concat(__MODULE__, "Orchestrator#{suffix}")
    start_supervised!({Task.Supervisor, name: supervisor})
    pid = start_supervised!({Orchestrator, name: name, task_supervisor: supervisor})
    # Let the startup tick settle so the test drives poll cycles itself.
    :sys.get_state(pid)
    {pid, name}
  end
end
