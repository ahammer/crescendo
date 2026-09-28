defmodule SymphonyElixir.CommandsTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias SymphonyElixir.{Commands, Config.Schema, Workflow}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-commands-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, service: Path.join(root, "crescendo.yml")}
  end

  defp no_gh(_args), do: flunk("gh must not run")

  test "project add writes a project from the templates that loads as a valid workflow", %{root: root, service: service} do
    output =
      capture_io(fn ->
        assert :ok = Commands.run(["project", "add", service, "babelfit", "ahammer/BabelFit", "--tools", "java@21, gradle@8"], &no_gh/1)
      end)

    assert output =~ "babelfit: {weight: 1}"
    dir = Path.join([root, "projects", "babelfit"])
    assert {:ok, workflow} = Workflow.load(Path.join(dir, "WORKFLOW.md"))
    assert {:ok, settings} = Schema.parse(workflow.config)

    assert settings.tracker.provider["repo"] == "ahammer/BabelFit"
    assert settings.tracker.required_labels == ["crescendo:ready"]
    assert settings.autopilot.blocked_label == "crescendo:blocked"
    assert settings.autopilot.trusted_authors == ["ahammer"]
    assert settings.codex.command == "mise exec java@21 gradle@8 -- codex --config shell_environment_policy.inherit=all app-server"
    assert settings.codex.routing["label_prefix"] == "crescendo:model:"
    assert Map.keys(settings.autopilot.channels) == ["cleanup", "docs", "qa", "testing"]
    assert workflow.prompt =~ "`ahammer/BabelFit`"
    assert workflow.prompt_templates["research"] =~ "`crescendo:channel:{{ issue.research.channel }}`"
    assert workflow.prompt_templates["pull_request"] =~ "`crescendo:hold`"

    assert {:error, "#{dir} already exists; nothing was written"} ==
             Commands.run(["project", "add", service, "babelfit", "ahammer/BabelFit"], &no_gh/1)
  end

  test "project add takes a branch and prefix and rejects bad input", %{root: root, service: service} do
    capture_io(fn ->
      assert :ok = Commands.run(["project", "add", service, "dartboard", "ahammer/dart_board", "--branch", "master", "--prefix", "board"], &no_gh/1)
    end)

    {:ok, workflow} = Workflow.load(Path.join([root, "projects", "dartboard", "WORKFLOW.md"]))
    assert workflow.config["hooks"]["after_create"] =~ "git checkout master"
    assert workflow.config["labels"] == %{"prefix" => "board"}
    assert workflow.config["codex"]["command"] == "codex --config shell_environment_policy.inherit=all app-server"

    assert {:error, "project ids are" <> _} = Commands.run(["project", "add", service, "Bad", "a/b"], &no_gh/1)
    assert {:error, "the repository must be owner/name"} = Commands.run(["project", "add", service, "ok", "nope"], &no_gh/1)
    assert {:error, "Usage:" <> _} = Commands.run(["project", "add", service, "only-id"], &no_gh/1)
    assert {:error, "Usage:" <> _} = Commands.run(["project", "add"], &no_gh/1)
  end

  test "labels sync creates the labels a project's workflow uses that its repository lacks", %{service: service} do
    capture_io(fn -> Commands.run(["project", "add", service, "shimmer", "ahammer/Shimmer"], &no_gh/1) end)
    capture_io(fn -> Commands.run(["project", "add", service, "norepo", "ahammer/NoRepo"], &no_gh/1) end)
    File.write!(service, "projects: {shimmer: {}, other: {enabled: false}}")
    parent = self()

    gh = fn
      ["label", "list" | _] ->
        {"crescendo:ready\nCRESCENDO:HOLD\n", 0}

      ["label", "create", name | rest] ->
        send(parent, {:created, name, rest})
        if name == "crescendo:model:astra", do: {"HTTP 422: already taken\n", 1}, else: {"", 0}
    end

    output = capture_io(fn -> assert :ok = Commands.run(["labels", "sync", service], gh) end)

    created = collect_created()
    refute "crescendo:ready" in created
    refute "crescendo:hold" in created

    for label <- ["crescendo:in-review", "crescendo:blocked", "crescendo:channel:qa", "crescendo:size:small", "crescendo:model:sol"],
        do: assert(label in created)

    assert output =~ "shimmer: created crescendo:blocked"
    assert Enum.count(created, &(&1 == "crescendo:blocked")) == 1
    assert output =~ "shimmer: could not create crescendo:model:astra: HTTP 422: already taken"

    # A listing failure still creates everything; only the named projects sync.
    failing = fn
      ["label", "list" | _] -> {"boom", 1}
      ["label", "create", name | _] -> send(parent, {:created, name, []}) && {"", 0}
    end

    capture_io(fn -> assert :ok = Commands.run(["labels", "sync", service, "shimmer"], failing) end)
    assert "crescendo:ready" in collect_created()
    capture_io(fn -> assert :ok = Commands.run(["labels", "sync", service, "nothing-matches"], &no_gh/1) end)
  end

  test "labels sync reports projects it cannot read", %{root: root, service: service} do
    dir = Path.join([root, "projects", "local"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "WORKFLOW.md"), "---\ntracker: {kind: memory}\n---\nWork.\n")
    File.write!(service, "projects: {local: {}}")
    assert {:error, "local: tracker.provider.repo is not set"} = Commands.run(["labels", "sync", service], &no_gh/1)

    File.write!(service, "projects: {missing: {}}")
    assert {:error, "missing: {:missing_workflow_file" <> _} = Commands.run(["labels", "sync", service], &no_gh/1)

    assert {:error, "cannot read " <> _} = Commands.run(["labels", "sync", Path.join(root, "absent.yml")], &no_gh/1)
  end

  test "drain on holds new dispatch until drain off", %{root: root, service: service} do
    File.write!(service, "paths: {state: state}\nprojects: {a: {}}")
    drain = Path.join([root, "state", "drain"])

    assert capture_io(fn -> assert :ok = Commands.run(["drain", "on", service], &no_gh/1) end) =~ "Draining"
    assert File.exists?(drain)
    assert capture_io(fn -> assert :ok = Commands.run(["drain", "off", service], &no_gh/1) end) =~ "Drain off"
    refute File.exists?(drain)
    assert {:error, "cannot read " <> _} = Commands.run(["drain", "on", Path.join(root, "absent.yml")], &no_gh/1)
  end

  test "anything else starts the service; half a command explains the usage" do
    assert Commands.run(["crescendo.yml", "--port", "1"], &no_gh/1) == :not_a_command
    assert Commands.run([], &no_gh/1) == :not_a_command

    for args <- [["project"], ["labels"], ["labels", "check"], ["drain", "maybe", "x.yml"]] do
      assert {:error, "Usage:" <> _} = Commands.run(args, &no_gh/1)
    end

    assert Commands.usage() =~ "crescendo drain on|off"
  end

  defp collect_created(acc \\ []) do
    receive do
      {:created, name, _rest} -> collect_created([name | acc])
    after
      0 -> acc
    end
  end
end
