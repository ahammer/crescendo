defmodule SymphonyElixir.AutopilotTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Autopilot, Config.Schema, Operations, PromptBuilder}

  @settings %{
    enabled: true,
    min_issues_per_channel: 1,
    channels: %{"testing" => "Tests", "cleanup" => "Cleanup"},
    max_issues_per_channel: 2,
    max_open_issues: 3,
    research_cooldown_ms: 60_000,
    max_pr_runs: 2,
    pr_recheck_ms: 60_000,
    max_item_attempts: 3
  }

  @empty %{pr_handled: %{}, tasks: %{}, item_attempts: %{}}

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
      state = Autopilot.record_pull_handled(state, pr, "sha-1", 1_000)
      assert state.pr_handled["7"] == %{runs: 1, head_sha: "sha-1", handled_at_ms: 1_000}
      assert Autopilot.pull_request_waiting_reason(pr, state, @settings, 60_999) == "reviewed at current head"
      assert Autopilot.pull_request_ready?(pull_request("7", "sha-2"), state, @settings, 1_000)
      # An unmerged pass at an unchanged head is rechecked once the cooldown passes.
      assert Autopilot.pull_request_ready?(pr, state, @settings, 61_000)

      # The next dispatch is the last review run before the cap retires the pull request.
      assert Autopilot.final_run?(state, pr, @settings)
      refute Autopilot.final_run?(@empty, pr, @settings)

      state = Autopilot.record_pull_dispatch(state, pr)
      assert Autopilot.pull_request_waiting_reason(pull_request("7", "sha-2"), state, @settings) == "review run cap reached"

      assert Autopilot.pull_request_waiting_reason(%Issue{kind: :pull_request, id: "8"}, @empty, @settings) ==
               "pull request details unavailable"

      assert Autopilot.record_pull_dispatch(@empty, %Issue{kind: :issue}) == @empty
      assert Autopilot.record_pull_handled(@empty, %Issue{kind: :pull_request, id: "8"}, nil) == @empty

      assert Autopilot.prune_pull_requests(state, [%Issue{kind: :issue, id: "7"}]).pr_handled == %{}
      assert Autopilot.prune_pull_requests(state, [pr]).pr_handled == state.pr_handled
    end

    test "records persisted before recheck timestamps are due immediately" do
      pr = pull_request("7", "sha-1")
      legacy = %{@empty | pr_handled: %{"7" => %{runs: 1, head_sha: "sha-1"}}}

      assert Autopilot.pull_request_ready?(pr, legacy, @settings)
    end
  end

  describe "attempt policy" do
    test "failed attempts accumulate to a final attempt, then exhaust" do
      refute Autopilot.final_attempt?(@empty, "5", @settings)
      {state, 1} = Autopilot.record_failed_attempt(@empty, "5")
      refute Autopilot.final_attempt?(state, "5", @settings)
      {state, 2} = Autopilot.record_failed_attempt(state, "5")
      assert Autopilot.final_attempt?(state, "5", @settings)
      refute Autopilot.exhausted?(state, "5", @settings)
      {state, 3} = Autopilot.record_failed_attempt(state, "5")
      assert Autopilot.exhausted?(state, "5", @settings)
      assert Autopilot.failed_attempts(state, "6") == 0
      assert Autopilot.final_run?(state, %Issue{kind: :issue, id: "5"}, @settings)
      refute Autopilot.final_run?(state, %Issue{kind: :research, id: "5"}, @settings)

      assert Autopilot.prune_pull_requests(state, [%Issue{id: "5"}]).item_attempts == %{"5" => 3}
      assert Autopilot.prune_pull_requests(state, []).item_attempts == %{}
      # State persisted before attempts were tracked still loads.
      assert Autopilot.failed_attempts(Map.delete(@empty, :item_attempts), "5") == 0
    end
  end

  describe "tracker writes" do
    test "trackers without write support report it instead of failing silently" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
      issue = %Issue{id: "x", identifier: "MT-1"}
      assert {:error, {:unsupported_tracker_operation, :retire}} = Tracker.retire(issue, "why")
      assert {:error, {:unsupported_tracker_operation, :clear_label}} = Tracker.clear_label(issue, "symphony:blocked")
    end

    test "final and item attempt numbers render into prompts" do
      write_workflow_file!(Workflow.workflow_file_path(), prompt: "{{ item_attempt }}{% if final_attempt %} final{% endif %}")
      assert PromptBuilder.build_prompt(%Issue{identifier: "GH-1"}) == "1"
      assert PromptBuilder.build_prompt(%Issue{identifier: "GH-1"}, item_attempt: 3, final_attempt: true) == "3 final"
    end
  end

  describe "research policy" do
    test "each task runs on its own schedule, the most overdue first" do
      now = ~U[2026-09-25 12:00:00Z]

      settings = %{
        @settings
        | channels: %{"testing" => "Tests", "cleanup" => "Cleanup", "docs" => %{"focus" => "Docs", "every" => "1d", "when" => "anytime", "delivers" => %{"issues" => %{"min" => 0}}}}
      }

      assert {@empty, nil} = Autopilot.next_research(@empty, %{settings | enabled: false}, 0, now)

      # Never-run tasks are due at once, in name order; a full backlog holds only tasks that must file issues.
      assert {@empty, %Issue{id: "research:cleanup"}} = Autopilot.next_research(@empty, settings, 0, now)
      assert {_, %Issue{id: "research:docs"}} = Autopilot.next_research(@empty, settings, 3, now)

      # A busy project starts only `anytime` tasks, and never one already running.
      assert {_, %Issue{id: "research:docs"}} = Autopilot.next_research(@empty, settings, 0, now, idle: false)
      assert {_, nil} = Autopilot.next_research(@empty, settings, 0, now, idle: false, running: ["docs"])

      # A delivered run waits its interval (the default cooldown, or the task's `every`).
      state = Autopilot.record_research_finished(@empty, "cleanup", :delivered, now, settings)
      state = Autopilot.record_research_finished(state, "docs", :unverified, now, settings)
      assert %{finished_at: ^now, attempts: 0, last: :delivered} = state.tasks["cleanup"]
      assert {_, %Issue{id: "research:testing"}} = Autopilot.next_research(state, settings, 0, now)
      state = Autopilot.record_research_finished(state, "testing", :delivered, DateTime.add(now, 10, :second), settings)
      assert {_, nil} = Autopilot.next_research(state, settings, 0, DateTime.add(now, 59, :second))
      assert {_, %Issue{id: "research:cleanup"}} = Autopilot.next_research(state, settings, 0, DateTime.add(now, 60, :second))
      # The most overdue goes first.
      assert {_, %Issue{id: "research:cleanup"}} = Autopilot.next_research(state, settings, 0, DateTime.add(now, 3_600, :second))
      assert {_, nil} = Autopilot.next_research(state, settings, 0, DateTime.add(now, 3_600, :second), idle: false)
      assert {_, %Issue{id: "research:docs"}} = Autopilot.next_research(state, settings, 0, DateTime.add(now, 86_400, :second), idle: false)
      assert Autopilot.last_finished_at(state) == DateTime.add(now, 10, :second)
      assert Autopilot.last_finished_at(@empty) == nil

      # A short or failed run retries 30 minutes later; the last allowed attempt ends it until next due.
      state = Autopilot.record_research_finished(state, "cleanup", :short, now, settings)
      assert %{attempts: 1, last: :short, retry_at: retry_at} = state.tasks["cleanup"]
      assert DateTime.compare(retry_at, DateTime.add(now, 1_800, :second)) == :eq
      others = [running: ["testing", "docs"]]
      assert {_, nil} = Autopilot.next_research(state, settings, 0, DateTime.add(now, 1_799, :second), others)
      assert {_, %Issue{id: "research:cleanup"}} = Autopilot.next_research(state, settings, 0, DateTime.add(now, 1_800, :second), others)
      state = Autopilot.record_research_finished(state, "cleanup", :failed, now, settings)
      assert %{attempts: 2, last: :failed} = state.tasks["cleanup"]
      state = Autopilot.record_research_finished(state, "cleanup", :short, now, settings)
      assert %{attempts: 0, last: :gave_up, finished_at: ^now, retry_at: nil} = state.tasks["cleanup"]

      assert [cleanup, docs, _testing] = Autopilot.task_statuses(state, settings, now)
      assert %{name: "cleanup", source: "local", when: "idle", every_ms: 60_000, last: :gave_up} = cleanup
      assert %{name: "docs", when: "anytime", every_ms: 86_400_000} = docs
    end

    test "schedules parse from short durations" do
      assert Enum.map(["30m", "6h", " 1d ", "2w", 90_000], &Autopilot.duration_ms/1) == [1_800_000, 21_600_000, 86_400_000, 1_209_600_000, 90_000]
      assert Enum.map(["0h", "1y", "", nil, -5], &Autopilot.duration_ms/1) == [nil, nil, nil, nil, nil]
    end

    test "a task's deliveries, expectations and effort shape its research item" do
      settings =
        @settings
        |> Map.put(:research_route, %{"model" => "gpt-6.1-sol", "effort" => "max"})
        |> Map.put(:channels, %{
          "marketing" => %{
            "focus" => "Docs",
            "effort" => "high",
            "source" => "repo",
            "expectations" => ["Run the quick start"],
            "delivers" => %{"issues" => %{"min" => 0, "max" => 2}, "pull_requests" => %{"min" => 1, "paths" => ["README.md"]}}
          },
          "qa" => %{"focus" => "QA", "effort" => "high"}
        })

      assert [%Issue{research: marketing}, %Issue{research: qa}] = Autopilot.research_items(settings)
      assert %{min_issues: 0, max_issues: 2, pull_requests: %{min: 1, max: nil, paths: ["README.md"]}} = marketing
      assert %{expectations: ["Run the quick start"], source: "repo"} = marketing
      assert marketing.route == %{"model" => "gpt-6.1-sol", "effort" => "high"}
      assert qa.route == %{"model" => "gpt-6.1-sol", "effort" => "high"}
      assert Autopilot.research_items(%{settings | research_route: nil}) |> hd() |> Map.get(:research) |> Map.get(:route) == nil
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
          blocked_label: " Symphony:Blocked ",
          prompts: %{pull_request: "prompts/pr.md", research: "prompts/research.md"}
        }
      )

      assert :ok = Config.validate!()
      autopilot = Config.settings!().autopilot
      assert autopilot.trusted_associations == ["OWNER"]
      assert autopilot.trusted_authors == ["adamh"]
      assert autopilot.blocked_label == "symphony:blocked"
      assert "symphony:blocked" in Config.settings!().tracker.excluded_labels
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

    test "research channels can carry their own prompt, counts and route, and labels follow the prefix" do
      prompts_dir = Path.join(Path.dirname(Workflow.workflow_file_path()), "prompts")
      File.mkdir_p!(prompts_dir)
      File.write!(Path.join(prompts_dir, "pr.md"), "Review {{ issue.identifier }}")
      File.write!(Path.join(prompts_dir, "qa.md"), "QA {{ issue.research.focus }} ({{ issue.research.min_issues }}-{{ issue.research.max_issues }})")
      File.write!(Path.join(prompts_dir, "shared.md"), "Shared {{ issue.research.channel }}")
      sol = %{model: "gpt-6-sol", effort: "medium"}
      qa_route = %{model: "gpt-6-sol", effort: "xhigh"}

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        codex_routing: %{default: sol, labels: %{"crescendo:model:sol" => sol}},
        extra_config: %{"labels" => %{"prefix" => " Crescendo "}},
        autopilot: %{
          enabled: true,
          channels: %{
            "qa" => %{focus: "Journeys", prompt: "prompts/qa.md", min_issues: 2, max_issues: 4, route: qa_route},
            "docs" => "Docs drift",
            "marketing" => %{focus: "Sell it", min_issues: 0}
          },
          prompts: %{pull_request: "prompts/pr.md", research: "prompts/shared.md"}
        }
      )

      assert :ok = Config.validate!()
      settings = Config.settings!()
      assert settings.labels.prefix == "crescendo"
      assert settings.autopilot.blocked_label == "crescendo:blocked"
      assert "crescendo:blocked" in settings.tracker.excluded_labels
      assert %{"label_prefix" => "crescendo:model:", "size_label_prefix" => "crescendo:size:"} = settings.codex.routing

      [docs, marketing, qa] = Autopilot.research_items(settings.autopilot)
      # A channel may have no quota at all.
      assert %{min_issues: 0, max_issues: 3} = marketing.research
      assert qa.labels == ["crescendo:research", "crescendo:channel:qa"]
      assert %{channel: "qa", focus: "Journeys", min_issues: 2, max_issues: 4, route: %{"model" => "gpt-6-sol", "effort" => "xhigh"}} = qa.research
      assert docs.research.route == nil
      assert "QA Journeys (2-4)\n\n## Deliverables\n\n- Issues: at least 2 and at most 4, each labelled `crescendo:channel:qa`." <> _ = PromptBuilder.build_prompt(qa)
      assert "Shared docs\n\n## Deliverables" <> _ = PromptBuilder.build_prompt(docs)

      # A channel's prompt file hot-reloads like the others.
      File.write!(Path.join(prompts_dir, "qa.md"), "QA v2")
      assert :ok = WorkflowStore.force_reload()
      assert "QA v2\n\n## Deliverables" <> _ = PromptBuilder.build_prompt(qa)

      # Without a shared research prompt every channel must bring its own.
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        autopilot: %{enabled: true, channels: %{"qa" => %{focus: "Journeys", prompt: "prompts/qa.md"}}, prompts: %{pull_request: "prompts/pr.md"}}
      )

      assert :ok = Config.validate!()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        autopilot: %{enabled: true, channels: %{"qa" => %{focus: "Journeys", prompt: "prompts/qa.md"}, "docs" => "Docs"}, prompts: %{pull_request: "prompts/pr.md"}}
      )

      assert {:error, {:invalid_workflow_config, "autopilot requires prompts.pull_request and prompts.research"}} = Config.validate!()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        autopilot: %{channels: %{"qa" => %{focus: "Journeys", prompt: "prompts/missing-qa.md"}}}
      )

      assert {:error, {:missing_prompt_file, missing_path, :enoent}} = Workflow.load()
      assert String.ends_with?(missing_path, "prompts/missing-qa.md")

      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"labels" => %{"prefix" => "bad prefix"}})
      assert message =~ "labels.prefix"
    end

    test "autopilot config rejects bad channels, prompts, trackers, and missing prompts" do
      luna_medium = %{model: "gpt-6-luna", effort: "medium"}

      invalid = [
        {%{channels: %{}}, "autopilot.channels"},
        {%{channels: %{"Bad Name" => "x"}}, "autopilot.channels"},
        {%{channels: %{"qa" => %{max_issues: 2}}}, "autopilot.channels"},
        {%{channels: %{"qa" => %{focus: "x", extra: 1}}}, "autopilot.channels"},
        {%{channels: %{"qa" => %{focus: "x", prompt: " "}}}, "autopilot.channels"},
        {%{channels: %{"qa" => %{focus: "x", min_issues: -1}}}, "autopilot.channels"},
        {%{channels: %{"qa" => %{focus: "x", max_issues: 0}}}, "autopilot.channels"},
        {%{channels: %{"qa" => %{focus: "x", route: %{model: "m"}}}}, "autopilot.channels"},
        {%{channels: %{"qa" => 7}}, "autopilot.channels"},
        {%{channels: %{"qa" => %{focus: "x", min_issues: 5}}}, "qa min_issues must not exceed max_issues"},
        {%{channels: %{"qa" => %{focus: "x", route: luna_medium}}}, "gpt-6-luna must run at max effort"},
        {%{prompts: %{other: "x.md"}}, "autopilot.prompts"},
        {%{max_pr_runs: 0}, "autopilot.max_pr_runs"},
        {%{max_item_attempts: 0}, "autopilot.max_item_attempts"},
        {%{min_issues_per_channel: 4, max_issues_per_channel: 3}, "autopilot.min_issues_per_channel"},
        {%{research_route: %{model: "astra", effort: "extreme"}}, "autopilot.research_route"}
      ]

      floors = %{
        default: %{model: "gpt-6-sol", effort: "medium"},
        labels: %{"symphony:model:sol" => %{model: "gpt-6-sol", effort: "medium"}},
        effort_floor: %{"gpt-6-luna" => "max"}
      }

      for {autopilot, field} <- invalid do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          autopilot: autopilot,
          codex_routing: floors
        )

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
        assert settings.tracker.excluded_labels == ["symphony:in-review", "symphony:hold", "symphony:blocked"]

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
        assert settings.autopilot.research_route == %{"model" => "gpt-6.1-sol", "effort" => "max"}
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

        saved = %{
          pr_handled: %{"7" => %{runs: 1, head_sha: "sha"}},
          tasks: %{"testing" => %{finished_at: ~U[2026-09-25 00:00:00Z], attempts: 0, retry_at: nil, last: :delivered}},
          item_attempts: %{"9" => 2}
        }

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
      refute state.running["2"].final_attempt
      assert Orchestrator.snapshot(name, 5_000).running |> Enum.map(& &1.identifier) == ["PR-2"]
    end

    test "a pull request reviewed at its current head is rechecked after the cooldown, as its final run" do
      write_autopilot_workflow!(autopilot: %{max_pr_runs: 2, pr_recheck_ms: 0})
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [pull_request("2", "sha-2")])
      {pid, _name} = start_orchestrator!()

      :sys.replace_state(pid, fn state ->
        handled = %{"2" => %{runs: 1, head_sha: "sha-2", handled_at_ms: System.system_time(:millisecond)}}
        %{state | autopilot: %{state.autopilot | pr_handled: handled, tasks: cooled_tasks()}}
      end)

      send(pid, :run_poll_cycle)
      state = :sys.get_state(pid)

      assert state.running["2"].final_attempt
      assert state.autopilot.pr_handled["2"].runs == 2
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
            autopilot: %{state.autopilot | tasks: cooled_tasks()}
        }
      end)

      send(pid, {:DOWN, ref, :process, self(), :normal})
      state = :sys.get_state(pid)

      assert %{head_sha: "sha-2", handled_at_ms: handled_at_ms} = state.autopilot.pr_handled["2"]
      assert is_integer(handled_at_ms)
      refute Map.has_key?(state.retry_attempts, "2")
      refute MapSet.member?(state.claimed, "2")

      send(pid, :run_poll_cycle)
      refute Map.has_key?(:sys.get_state(pid).running, "2")
      assert [%{issue_identifier: "PR-2", reason: "reviewed at current head"}] = Orchestrator.snapshot(name, 5_000).upcoming.waiting

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [pull_request("2", "sha-3")])
      send(pid, :run_poll_cycle)
      assert Map.has_key?(:sys.get_state(pid).running, "2")
    end

    test "research runs one task at a time, checks its deliveries, and has the machine to itself" do
      write_autopilot_workflow!()
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      parent = self()

      Application.put_env(:symphony_elixir, :task_deliveries_fun, fn label, since ->
        send(parent, {:deliveries, label, since})
        Application.get_env(:symphony_elixir, :task_deliveries_result, {:ok, %{issues: 1, pull_requests: 0}})
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :task_deliveries_fun)
        Application.delete_env(:symphony_elixir, :task_deliveries_result)
      end)

      {pid, name} = start_orchestrator!()
      send(pid, :run_poll_cycle)
      assert Map.keys(:sys.get_state(pid).running) == ["research:cleanup"]
      autopilot = Orchestrator.snapshot(name, 5_000).autopilot
      assert %{research_pending: ["cleanup", "testing"], tasks: [%{name: "cleanup"}, %{name: "testing"}]} = autopilot

      # Reconciliation must not treat research runs as missing tracker issues, and
      # work that becomes ready waits for the running planner.
      issue = %Issue{id: "1", identifier: "GH-1", title: "Filed", state: "open", dispatchable: true, labels: []}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      send(pid, :run_poll_cycle)
      assert Map.keys(:sys.get_state(pid).running) == ["research:cleanup"]

      # Delivered: counted with the task's label since the run started.
      finish_running_research(pid, "research:cleanup")
      state = :sys.get_state(pid)
      assert_received {:deliveries, "symphony:channel:cleanup", %DateTime{}}
      refute MapSet.member?(state.claimed, "research:cleanup")
      assert %{last: :delivered, attempts: 0} = state.autopilot.tasks["cleanup"]

      # Ready work outranks the next task.
      send(pid, :run_poll_cycle)
      assert Map.keys(:sys.get_state(pid).running) == ["1"]

      # Once idle again the next task runs; falling short schedules a retry.
      :sys.replace_state(pid, fn state -> %{state | running: %{}, claimed: MapSet.new()} end)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      send(pid, :run_poll_cycle)
      assert Map.keys(:sys.get_state(pid).running) == ["research:testing"]
      Application.put_env(:symphony_elixir, :task_deliveries_result, {:ok, %{issues: 0, pull_requests: 0}})
      finish_running_research(pid, "research:testing")
      assert %{last: :short, attempts: 1, retry_at: %DateTime{}} = :sys.get_state(pid).autopilot.tasks["testing"]

      send(pid, :run_poll_cycle)
      assert :sys.get_state(pid).running == %{}

      # Deliveries that cannot be read leave the run unverified, not failed.
      :sys.replace_state(pid, fn state -> %{state | autopilot: %{state.autopilot | tasks: Map.delete(state.autopilot.tasks, "cleanup")}} end)
      send(pid, :run_poll_cycle)
      Application.put_env(:symphony_elixir, :task_deliveries_result, {:error, :boom})
      finish_running_research(pid, "research:cleanup")
      assert %{last: :unverified} = :sys.get_state(pid).autopilot.tasks["cleanup"]
    end

    test "an anytime task starts while other work runs, and a failed run is retried" do
      write_autopilot_workflow!(autopilot: %{channels: %{"deps" => %{"focus" => "Dependencies", "when" => "anytime", "every" => "7d"}}})
      issue = %Issue{id: "1", identifier: "GH-1", title: "Work", state: "open", dispatchable: true, labels: []}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      {pid, _name} = start_orchestrator!()
      send(pid, :run_poll_cycle)
      assert Map.keys(:sys.get_state(pid).running) |> Enum.sort() == ["1", "research:deps"]

      %{ref: ref} = :sys.get_state(pid).running["research:deps"]
      send(pid, {:DOWN, ref, :process, self(), :boom})
      assert %{last: :failed, attempts: 1} = :sys.get_state(pid).autopilot.tasks["deps"]
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
        %{state | running: %{"9" => running_entry(issue, ref)}, claimed: MapSet.new(["9"]), autopilot: %{state.autopilot | tasks: cooled_tasks()}}
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
      assert entry.route == %{model: "gpt-6-sol", effort: "high", label: "default", tier: nil, size: nil, backoff: nil}
      assert length(entry.recent_events) == 6
      texts = Enum.map(entry.recent_events, & &1.text)
      assert texts == Enum.uniq(texts)
      refute Enum.any?(texts, &(&1 =~ "streaming" or &1 =~ "delta-item" or &1 =~ "usage-item"))
      assert hd(texts) =~ "item-8"
    end

    test "blocked attempts are retried behind fresh work, flagged final, then retired" do
      write_autopilot_workflow!(max_concurrent_agents: 1)
      Application.delete_env(:symphony_elixir, :memory_tracker_writes)
      blocked = %Issue{id: "1", identifier: "GH-1", title: "Blocked", state: "open", dispatchable: true, labels: ["symphony:blocked"], priority: 1}
      fresh = %Issue{id: "2", identifier: "GH-2", title: "Fresh", state: "open", dispatchable: true, labels: [], priority: 2}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [blocked, fresh])

      {pid, name} = start_orchestrator!()
      cool_down_research(pid)
      send(pid, :run_poll_cycle)
      state = :sys.get_state(pid)

      # The marker became one failed attempt and was cleared; the fresh issue goes first.
      assert state.autopilot.item_attempts == %{"1" => 1}
      assert {:clear_label, "1", "symphony:blocked"} in Application.get_env(:symphony_elixir, :memory_tracker_writes)
      assert Map.keys(state.running) == ["2"]

      # Attempt 2 fails the same way; the third run is flagged final.
      :sys.replace_state(pid, fn state -> %{state | running: %{}, claimed: MapSet.new()} end)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{blocked | labels: ["symphony:blocked"]}])
      send(pid, :run_poll_cycle)
      state = :sys.get_state(pid)
      assert state.autopilot.item_attempts == %{"1" => 2}
      assert %{item_attempt: 3, final_attempt: true} = state.running["1"]
      assert [%{item_attempt: 3, final_attempt: true}] = Orchestrator.snapshot(name, 5_000).running |> Enum.map(&Map.take(&1, [:item_attempt, :final_attempt]))

      # The final attempt also ends blocked: the issue is retired, never parked.
      :sys.replace_state(pid, fn state -> %{state | running: %{}, claimed: MapSet.new()} end)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{blocked | labels: ["symphony:blocked"]}])
      send(pid, :run_poll_cycle)
      state = :sys.get_state(pid)
      assert state.running == %{}
      assert Enum.any?(Application.get_env(:symphony_elixir, :memory_tracker_writes), &match?({:retire, "1", _}, &1))
    end

    test "exhausted crash retries count as a failed attempt instead of blocking" do
      write_autopilot_workflow!(max_attempts: 1)
      issue = %Issue{id: "3", identifier: "GH-3", title: "Crashy", state: "open", dispatchable: true, labels: []}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      {pid, _name} = start_orchestrator!()
      ref = make_ref()

      :sys.replace_state(pid, fn state ->
        entry = Map.put(running_entry(issue, ref), :retry_attempt, 1)
        %{state | running: %{"3" => entry}, claimed: MapSet.new(["3"]), autopilot: %{state.autopilot | tasks: cooled_tasks()}}
      end)

      send(pid, {:DOWN, ref, :process, self(), :boom})
      state = :sys.get_state(pid)
      assert state.blocked == %{}
      assert state.autopilot.item_attempts == %{"3" => 1}
      refute MapSet.member?(state.claimed, "3")
    end

    test "a pull request at its review cap is retired" do
      write_autopilot_workflow!(autopilot: %{max_pr_runs: 1})
      Application.delete_env(:symphony_elixir, :memory_tracker_writes)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [pull_request("8", "sha-9")])
      {pid, _name} = start_orchestrator!()

      :sys.replace_state(pid, fn state ->
        handled = %{"8" => %{runs: 1, head_sha: "sha-8"}}
        %{state | autopilot: %{state.autopilot | pr_handled: handled, tasks: cooled_tasks()}}
      end)

      send(pid, :run_poll_cycle)
      assert :sys.get_state(pid).running == %{}
      assert Enum.any?(Application.get_env(:symphony_elixir, :memory_tracker_writes), &match?({:retire, "8", _}, &1))
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

  defp cool_down_research(pid) do
    :sys.replace_state(pid, fn state ->
      %{state | autopilot: Map.put(state.autopilot, :tasks, cooled_tasks())}
    end)
  end

  defp finish_running_research(pid, id) do
    %{ref: ref, pid: worker} = :sys.get_state(pid).running[id]
    Process.exit(worker, :kill)
    send(pid, {:DOWN, ref, :process, worker, :normal})
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

  # Both test channels just finished, so no research starts in the tests that
  # watch other work.
  defp cooled_tasks do
    now = DateTime.utc_now()
    Map.new(["cleanup", "testing"], &{&1, %{finished_at: now, attempts: 0, retry_at: nil, last: :delivered}})
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
      max_attempts: Keyword.get(overrides, :max_attempts),
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
