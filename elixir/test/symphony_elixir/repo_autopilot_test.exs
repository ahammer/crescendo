defmodule SymphonyElixir.RepoAutopilotTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Autopilot, Commands, Config.Schema, Project, PromptBuilder, RepoAutopilot}
  alias SymphonyElixir.GitHub.Client

  @folder ".crescendo/autopilot"

  test "an unobserved source revision stays unknown" do
    assert {:error, :source_revision_unknown} = RepoAutopilot.revision("unknown-source-project")
  end

  setup do
    root = Path.join(System.tmp_dir!(), "crescendo-repo-autopilot-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp entry(name, type, sha \\ "s"), do: %{"name" => name, "type" => type, "sha" => sha}
  defp blob(text), do: %{"encoding" => "base64", "content" => Base.encode64(text), "size" => byte_size(text)}

  # A contents API stand-in over `files` (path => response); each read is reported.
  defp fetch(files) do
    parent = self()

    fn path ->
      send(parent, {:read, path})
      Map.get(files, path, {:ok, :not_found})
    end
  end

  @task "---\nfocus: QA\nevery: 1d\n---\nHunt {{ issue.research.focus }}"

  defp repo(qa_sha \\ "q1", qa \\ @task) do
    %{
      @folder =>
        {:ok,
         [
           entry("autopilot.yml", "file", "a1"),
           entry("guidelines.md", "file", "g1"),
           entry("notes.txt", "file"),
           entry("tasks", "dir"),
           entry("other", "dir")
         ]},
      (@folder <> "/tasks") => {:ok, [entry("qa.md", "file", qa_sha), entry("skip.yml", "file")]},
      (@folder <> "/autopilot.yml") => {:ok, blob("defaults: {when: anytime}\n")},
      (@folder <> "/guidelines.md") => {:ok, blob("Run mix test.")},
      (@folder <> "/tasks/qa.md") => {:ok, blob(qa)}
    }
  end

  defp flush_reads(acc \\ []) do
    receive do
      {:read, path} -> flush_reads([path | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "sync" do
    test "mirrors the folder, fetching only changed files, and removes it when the repo drops it", %{root: root} do
      dir = Path.join(root, "mirror")

      assert :updated = RepoAutopilot.sync(dir, fetch(repo()))
      assert File.read!(Path.join(dir, "tasks/qa.md")) == @task
      assert File.read!(Path.join(dir, "guidelines.md")) == "Run mix test."
      refute File.exists?(Path.join(dir, "notes.txt"))
      refute File.exists?(Path.join(dir, "tasks/skip.yml"))
      flush_reads()

      # Unchanged blobs are neither fetched nor rewritten.
      assert :unchanged = RepoAutopilot.sync(dir, fetch(repo()))
      assert flush_reads() == [@folder, @folder <> "/tasks"]

      assert :updated = RepoAutopilot.sync(dir, fetch(repo("q2", "---\nfocus: QA v2\n---\nv2")))
      assert (@folder <> "/tasks/qa.md") in flush_reads()
      assert File.read!(Path.join(dir, "tasks/qa.md")) =~ "v2"

      # A corrupt manifest means everything is fetched again.
      File.write!(Path.join(dir, ".manifest"), "not a term")
      assert :updated = RepoAutopilot.sync(dir, fetch(repo("q2", "---\nfocus: QA v2\n---\nv2")))

      assert :absent = RepoAutopilot.sync(dir, fetch(%{}))
      refute File.exists?(dir)
    end

    test "a failed read leaves the last mirror in place", %{root: root} do
      dir = Path.join(root, "mirror")
      :updated = RepoAutopilot.sync(dir, fetch(repo()))

      failures = [
        {%{@folder => {:error, :timeout}}, {:error, :timeout}},
        {%{@folder => {:ok, %{"type" => "file"}}}, {:error, {:not_a_folder, @folder}}},
        {Map.put(repo("q9"), @folder <> "/tasks/qa.md", {:error, :boom}), {:error, :boom}},
        {Map.put(repo("q9"), @folder <> "/tasks/qa.md", {:ok, %{"encoding" => "base64", "content" => "%%%", "size" => 3}}), {:error, {:bad_content, "tasks/qa.md"}}},
        {Map.put(repo("q9"), @folder <> "/tasks/qa.md", {:ok, %{"size" => 999_999}}), {:error, {:file_too_large, "tasks/qa.md"}}},
        {Map.put(repo("q9"), @folder <> "/tasks/qa.md", {:ok, %{"type" => "dir"}}), {:error, {:bad_content, "tasks/qa.md"}}},
        {Map.put(repo(), @folder <> "/tasks", {:ok, for(n <- 1..61, do: entry("t#{n}.md", "file"))}), {:error, {:too_many_files, 63}}}
      ]

      for {files, expected} <- failures do
        assert RepoAutopilot.sync(dir, fetch(files)) == expected
        assert File.read!(Path.join(dir, "tasks/qa.md")) == @task
        refute File.exists?(dir <> ".staging")
      end

      # A folder without `tasks/` (or whose tasks listing vanished) mirrors what it has.
      top_only = %{@folder => {:ok, [entry("guidelines.md", "file", "g1")]}, (@folder <> "/guidelines.md") => {:ok, blob("G")}}
      assert :updated = RepoAutopilot.sync(dir, fetch(top_only))
      assert :unchanged = RepoAutopilot.sync(dir, fetch(Map.merge(top_only, %{@folder => {:ok, [entry("guidelines.md", "file", "g1"), entry("tasks", "dir")]}})))
    end

    test "the mirror process polls, and records each outcome", %{root: root} do
      dir = Path.join(root, "mirror")
      start_supervised!({RepoAutopilot, project: "alpha", dir: dir, fetch: fetch(repo()), interval_ms: 60_000})
      assert_eventually(fn -> RepoAutopilot.status("alpha").state == :synced end)
      assert File.exists?(Path.join(dir, "tasks/qa.md"))

      stop_supervised!(RepoAutopilot)
      down = fetch(%{@folder => {:error, :down}})
      start_supervised!({RepoAutopilot, project: "beta", dir: dir, fetch: down, interval_ms: 60_000})

      ExUnit.CaptureLog.capture_log(fn ->
        assert_eventually(fn -> RepoAutopilot.status("beta").state == :error end)
      end)

      assert RepoAutopilot.status("beta").error == ":down"

      # Without a GitHub tracker there is no folder to read.
      stop_supervised!(RepoAutopilot)
      {:ok, pid} = RepoAutopilot.start_link(project: nil, dir: dir)
      send(pid, :unrelated)
      assert_eventually(fn -> RepoAutopilot.status(nil).state == :absent end)
      GenServer.stop(pid)
      assert RepoAutopilot.status("never-started").state == :pending
      assert RepoAutopilot.mirror_dir("/state/projects/a") == "/state/projects/a/repo-autopilot"
    end
  end

  describe "loading" do
    defp write_overlay!(dir, tasks, extra \\ %{}) do
      File.mkdir_p!(Path.join(dir, "tasks"))
      for {name, text} <- tasks, do: File.write!(Path.join([dir, "tasks", name]), text)
      for {name, text} <- extra, do: File.write!(Path.join(dir, name), text)
      File.write!(Path.join(dir, ".manifest"), :erlang.term_to_binary(%{tasks: map_size(tasks), at: System.unique_integer()}))
      dir
    end

    defp write_project_workflow!(root, autopilot \\ "") do
      path = Path.join(root, "WORKFLOW.md")

      File.write!(path, """
      ---
      tracker: {kind: memory}
      autopilot:
        enabled: true
        channels: {local: "Local work"}
        prompts: {pull_request: pr.md, research: research.md}
      #{autopilot}
      ---
      Issue {{ issue.identifier }}
      """)

      File.write!(Path.join(root, "pr.md"), "Review")
      File.write!(Path.join(root, "research.md"), "Shared research")
      path
    end

    test "repository tasks replace the local channels and guidelines join every prompt", %{root: root} do
      path = write_project_workflow!(root)

      overlay =
        write_overlay!(Path.join(root, "overlay"), %{"qa.md" => @task, "docs.md" => "---\nfocus: Docs\n---\nDocs body"}, %{
          "autopilot.yml" => "defaults: {when: anytime, every: 6h}\nguidelines: rules.md\n",
          "rules.md" => "Always run {{ the tests }}."
        })

      assert {:ok, workflow} = Workflow.load(path, %{}, overlay)
      channels = workflow.config["autopilot"]["channels"]
      assert Map.keys(channels) == ["docs", "qa"]
      assert %{"focus" => "QA", "every" => "1d", "when" => "anytime", "source" => "repo"} = channels["qa"]
      assert %{"every" => "6h"} = channels["docs"]
      assert workflow.prompt_templates["research:qa"] == "Hunt {{ issue.research.focus }}"
      assert workflow.prompt_templates["guidelines"] == "Always run {{ the tests }}."
      assert Path.join(overlay, "autopilot.yml") in workflow.prompt_paths

      # Disabled tasks drop out; with none left, the local channels stay.
      assert {:ok, workflow} = Workflow.load(write_project_workflow!(root, "  disabled_tasks: [qa]"), %{}, overlay)
      assert Map.keys(workflow.config["autopilot"]["channels"]) == ["docs"]
      assert {:ok, workflow} = Workflow.load(write_project_workflow!(root, "  disabled_tasks: [qa, docs]"), %{}, overlay)
      assert Map.keys(workflow.config["autopilot"]["channels"]) == ["local"]

      # The folder can be ignored, and is ignored when missing.
      assert {:ok, workflow} = Workflow.load(write_project_workflow!(root, "  repo_tasks: false"), %{}, overlay)
      assert Map.keys(workflow.config["autopilot"]["channels"]) == ["local"]
      assert {:ok, workflow} = Workflow.load(path, %{}, Path.join(root, "missing"))
      assert Map.keys(workflow.config["autopilot"]["channels"]) == ["local"]
    end

    test "an invalid folder fails the load", %{root: root} do
      path = write_project_workflow!(root)
      bad_task = write_overlay!(Path.join(root, "bad-task"), %{"qa.md" => "---\nfocus: [unclosed\n---\nbody"})
      assert {:error, {:repo_autopilot, {:invalid_task, "qa.md", _reason}}} = Workflow.load(path, %{}, bad_task)

      bad_yml = write_overlay!(Path.join(root, "bad-yml"), %{"qa.md" => @task}, %{"autopilot.yml" => "- a list"})
      assert {:error, {:repo_autopilot, {:invalid_autopilot_yml, _reason}}} = Workflow.load(path, %{}, bad_yml)

      unreadable = write_overlay!(Path.join(root, "unreadable"), %{"qa.md" => @task})
      File.mkdir_p!(Path.join(unreadable, "autopilot.yml"))
      assert {:error, {:repo_autopilot, {:unreadable, _path, :eisdir}}} = Workflow.load(path, %{}, unreadable)

      empty_tasks = Path.join(root, "no-tasks")
      File.mkdir_p!(empty_tasks)
      assert {:ok, %{channels: %{}, guidelines: nil}} = Workflow.read_autopilot_folder(empty_tasks)
    end

    test "a project's store reloads when the mirror changes", %{root: root} do
      path = write_project_workflow!(root)
      overlay = Path.join(root, "overlay")
      start_supervised!({WorkflowStore, name: Project.via("gamma", :workflow_store), project: "gamma", path: path, overlay: overlay})
      channels = fn -> Project.with_project("gamma", fn -> Config.settings!().autopilot.channels |> Map.keys() end) end
      assert channels.() == ["local"]

      write_overlay!(overlay, %{"qa.md" => @task})
      assert :ok = Project.with_project("gamma", &WorkflowStore.force_reload/0)
      assert channels.() == ["qa"]

      File.rm_rf!(overlay)
      assert :ok = Project.with_project("gamma", &WorkflowStore.force_reload/0)
      assert channels.() == ["local"]
    end
  end

  describe "validation" do
    defp autopilot_config(channels, extra \\ %{}) do
      Map.merge(%{"tracker" => %{"kind" => "memory"}, "autopilot" => %{"enabled" => true, "channels" => channels, "prompts" => %{"pull_request" => "p", "research" => "r"}}}, extra)
    end

    test "task fields are checked" do
      valid = %{
        "focus" => "QA",
        "every" => "1d",
        "when" => "anytime",
        "effort" => "high",
        "source" => "repo",
        "expectations" => ["Run it"],
        "delivers" => %{"issues" => %{"min" => 5, "max" => 6}, "pull_requests" => %{"min" => 0, "max" => 2, "paths" => ["docs/**"]}}
      }

      assert {:ok, _settings} = Schema.parse(autopilot_config(%{"qa" => valid}))

      for bad <- [
            %{"every" => "sometimes"},
            %{"when" => "never"},
            %{"at" => "noon"},
            %{"effort" => 3},
            %{"source" => "elsewhere"},
            %{"expectations" => "run it"},
            %{"expectations" => [1]},
            %{"delivers" => "lots"},
            %{"delivers" => %{"commits" => %{}}},
            %{"delivers" => %{"issues" => "3"}},
            %{"delivers" => %{"issues" => %{"min" => 3, "max" => 2}}},
            %{"delivers" => %{"issues" => %{"extra" => 1}}},
            %{"delivers" => %{"pull_requests" => %{"paths" => [""]}}},
            %{"delivers" => %{"pull_requests" => %{"paths" => "docs"}}}
          ] do
        assert {:error, _reason} = Schema.parse(autopilot_config(%{"qa" => Map.merge(valid, bad)})), inspect(bad)
      end
    end

    test "a task effort must be a rung of the research model's ladder" do
      ladder = %{
        "label_prefix" => "symphony:model:",
        "labels" => %{"symphony:model:sol" => %{"model" => "gpt-6.1-sol", "effort" => "high"}},
        "ladder" => [%{"model" => "gpt-6.1-sol", "effort" => "high"}],
        "escalation" => [0],
        "default" => %{"model" => "gpt-6.1-sol", "effort" => "high"}
      }

      routed = %{"codex" => %{"routing" => ladder}}
      research = fn config -> put_in(config, ["autopilot", "research_route"], %{"model" => "gpt-6.1-sol", "effort" => "high"}) end
      check = fn config -> with {:ok, settings} <- Schema.parse(config), do: Config.validate_settings(settings) end

      assert :ok = check.(research.(autopilot_config(%{"qa" => %{"focus" => "QA", "effort" => "high"}}, routed)))

      assert {:error, {:invalid_workflow_config, "autopilot task effort max is not a gpt-6.1-sol rung of codex.routing.ladder"}} =
               check.(research.(autopilot_config(%{"qa" => %{"focus" => "QA", "effort" => "max"}}, routed)))

      assert {:error, {:invalid_workflow_config, "autopilot task efforts need autopilot.research_route"}} =
               check.(autopilot_config(%{"qa" => %{"focus" => "QA", "effort" => "high"}}, routed))
    end
  end

  describe "prompts" do
    test "guidelines, deliverables and a task's PR scope are appended" do
      dir = Path.dirname(Workflow.workflow_file_path())
      File.write!(Path.join(dir, "rules.md"), "Keep it green.")
      File.write!(Path.join(dir, "pr.md"), "Review {{ issue.identifier }}")
      File.write!(Path.join(dir, "research.md"), "Research")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        prompt: "Work on {{ issue.identifier }}",
        autopilot: %{
          enabled: true,
          guidelines: "rules.md",
          prompts: %{pull_request: "pr.md", research: "research.md"},
          channels: %{
            "docs" => %{
              "focus" => "Docs",
              "expectations" => ["Screenshot the UI"],
              "delivers" => %{"issues" => %{"min" => 0, "max" => 1}, "pull_requests" => %{"min" => 1, "max" => 2, "paths" => ["README.md"]}}
            },
            "qa" => %{"focus" => "QA", "delivers" => %{"pull_requests" => %{"min" => 0}}}
          }
        }
      )

      assert PromptBuilder.build_prompt(%Issue{identifier: "GH-1", labels: []}) == "Work on GH-1\n\n## Repository guidelines\n\nKeep it green."

      [docs, qa] = Autopilot.research_items(Config.settings!().autopilot)
      prompt = PromptBuilder.build_prompt(docs)
      assert prompt =~ "- Issues: at least 0 and at most 1, each labelled `symphony:channel:docs`."
      assert prompt =~ "- Pull requests: at least 1 and at most 2, each labelled `symphony:channel:docs`, changing only `README.md`."
      assert prompt =~ "- Expectation: Screenshot the UI"
      assert PromptBuilder.build_prompt(qa) =~ "- Pull requests: at least 0, each labelled `symphony:channel:qa`."

      pr = %Issue{identifier: "PR-4", kind: :pull_request, labels: ["symphony:channel:docs", "symphony:channel:qa", "bug"]}
      assert PromptBuilder.build_prompt(pr) =~ "## Task scope\n\nThis pull request comes from the `docs` task, which may only change `README.md`."
      refute PromptBuilder.build_prompt(%{pr | labels: ["symphony:channel:qa"]}) =~ "Task scope"
    end
  end

  describe "GitHub reads" do
    @github %{kind: "github", provider: %{"repo" => "acme/app", "token" => "t"}}

    test "contents come from the default branch, and deliveries count what a task opened since it started" do
      parent = self()

      request = fn method, path, params, _body, _settings ->
        send(parent, {:request, method, path, params})
        Process.get(:response)
      end

      opts = [tracker_settings: @github, request_fun: request]
      Process.put(:response, {:ok, %{status: 200, body: [%{"name" => "tasks"}]}})
      assert {:ok, [%{"name" => "tasks"}]} = Client.fetch_contents(".crescendo/autopilot/tasks", opts)
      assert_received {:request, "GET", "/repos/acme/app/contents/.crescendo/autopilot/tasks", %{}}
      Process.put(:response, {:ok, %{status: 404, body: %{}}})
      assert {:ok, :not_found} = Client.fetch_contents(".crescendo/autopilot", opts)

      since = ~U[2026-09-29 10:00:00Z]

      items = [
        %{"created_at" => "2026-09-29T10:05:00Z"},
        %{"created_at" => "2026-09-29T10:06:00Z", "pull_request" => %{}},
        %{"created_at" => "2026-09-29T09:00:00Z"},
        %{"created_at" => "garbage"},
        %{}
      ]

      Process.put(:response, {:ok, %{status: 200, body: items}})
      assert {:ok, %{issues: 1, pull_requests: 1}} = Client.fetch_task_deliveries("crescendo:channel:qa", since, opts)
      assert_received {:request, "GET", "/repos/acme/app/issues", %{"labels" => "crescendo:channel:qa", "state" => "all", "since" => "2026-09-29T10:00:00Z"}}

      Process.put(:response, {:ok, %{status: 200, body: %{"message" => "odd"}}})
      assert {:error, :github_unknown_payload} = Client.fetch_task_deliveries("x", since, opts)
      Process.put(:response, {:ok, %{status: 500, body: %{}}})
      assert {:error, {:github_api_status, 500}} = Client.fetch_task_deliveries("x", since, opts)
    end
  end

  describe "autopilot check" do
    test "validates a folder and prints its tasks", %{root: root} do
      dir = Path.join(root, "autopilot")
      File.mkdir_p!(Path.join(dir, "tasks"))
      File.write!(Path.join(dir, "guidelines.md"), "G")
      File.write!(Path.join([dir, "tasks", "qa.md"]), "---\nfocus: QA\nevery: 1d\ndelivers: {pull_requests: {min: 1, paths: [docs]}}\n---\nHunt")
      File.write!(Path.join([dir, "tasks", "plain.md"]), "Just a prompt with no front matter")
      File.write!(Path.join([dir, "tasks", "open.md"]), "---\nfocus: Front matter never closed")
      File.write!(Path.join([dir, "tasks", "twice.md"]), "---\nfocus: Twice a day\nevery: 12h\nat: \"06:00\"\n---\nHunt")

      output = ExUnit.CaptureIO.capture_io(fn -> assert :ok = Commands.run(["autopilot", "check", dir], nil) end)
      assert output =~ "qa: every 1d · idle · effort default · issues 1..3 · PRs 1..∞ in docs"
      assert output =~ "plain: every 30m"
      assert output =~ "twice: every 12h at 06:00 UTC"
      assert output =~ "guidelines: guidelines.md"

      # With the project workflow the folder loads as the service would load it.
      workflow = Path.join(root, "WORKFLOW.md")
      File.write!(workflow, "---\ntracker: {kind: memory}\nautopilot: {enabled: true, prompts: {pull_request: pr.md}}\n---\nIssue")
      File.write!(Path.join(root, "pr.md"), "Review")
      File.rm!(Path.join([dir, "tasks", "plain.md"]))
      File.rm!(Path.join([dir, "tasks", "open.md"]))
      assert ExUnit.CaptureIO.capture_io(fn -> assert :ok = Commands.run(["autopilot", "check", dir, "--workflow", workflow], nil) end) =~ "qa: every"

      File.rm!(Path.join(dir, "guidelines.md"))
      assert ExUnit.CaptureIO.capture_io(fn -> Commands.run(["autopilot", "check", dir], nil) end) =~ "guidelines: none"
    end

    test "reports what is wrong", %{root: root} do
      dir = Path.join(root, "autopilot")
      File.mkdir_p!(Path.join(dir, "tasks"))

      assert {:error, message} = Commands.run(["autopilot", "check", Path.join(root, "missing")], nil)
      assert message =~ "is not a directory"
      assert {:error, message} = Commands.run(["autopilot", "check", dir], nil)
      assert message =~ "has no tasks"

      File.write!(Path.join([dir, "tasks", "qa.md"]), "---\nfocus: QA\n---\n{% if %}")
      assert {:error, message} = Commands.run(["autopilot", "check", dir], nil)
      assert message =~ "task qa: prompt template does not parse"

      File.write!(Path.join([dir, "tasks", "qa.md"]), "---\nfocus: QA\nwhen: never\n---\nHunt")
      assert {:error, message} = Commands.run(["autopilot", "check", dir], nil)
      assert message =~ "invalid autopilot folder"

      File.write!(Path.join([dir, "tasks", "qa.md"]), "---\nfocus: [open\n---\nHunt")
      assert {:error, "invalid autopilot folder: " <> _} = Commands.run(["autopilot", "check", dir], nil)

      File.write!(Path.join([dir, "tasks", "qa.md"]), "---\nfocus: QA\n---\nHunt")
      workflow = Path.join(root, "WORKFLOW.md")
      File.write!(workflow, "---\ntracker: {kind: memory}\nautopilot: {enabled: true}\n---\nIssue")
      assert {:error, "invalid autopilot folder: " <> _} = Commands.run(["autopilot", "check", dir, "--workflow", workflow], nil)

      assert {:error, _usage} = Commands.run(["autopilot", "check", dir, "--nope"], nil)
      assert {:error, _usage} = Commands.run(["autopilot"], nil)
    end
  end

  defp assert_eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && assert_eventually(fun, attempts - 1)
    end
  end
end
