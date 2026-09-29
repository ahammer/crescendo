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
    assert settings.labels.prefix == "crescendo"
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
    assert {:ok, settings} = Schema.parse(workflow.config)
    assert workflow.config["hooks"]["after_create"] =~ "git checkout master"
    assert workflow.config["labels"] == %{"prefix" => "board"}
    assert settings.labels.prefix == "board"
    assert workflow.config["codex"]["command"] == "codex --config shell_environment_policy.inherit=all app-server"

    assert {:error, "project ids are" <> _} = Commands.run(["project", "add", service, "Bad", "a/b"], &no_gh/1)
    assert {:error, "the repository must be owner/name"} = Commands.run(["project", "add", service, "ok", "nope"], &no_gh/1)
    assert {:error, "Usage:" <> _} = Commands.run(["project", "add", service, "only-id"], &no_gh/1)
    assert {:error, "Usage:" <> _} = Commands.run(["project", "add"], &no_gh/1)
  end

  test "project add rejects invalid label prefixes before writing files", %{root: root, service: service} do
    assert {:error, message} =
             Commands.run(["project", "add", service, "demo", "ahammer/crescendo", "--prefix", "bad: label"], &no_gh/1)

    assert message =~ "invalid --prefix value"
    assert message =~ "lowercase letters, digits, or dashes"
    refute File.exists?(Path.join([root, "projects", "demo"]))
  end

  test "labels sync creates the labels a project's workflow uses that its repository lacks", %{service: service} do
    capture_io(fn -> Commands.run(["project", "add", service, "shimmer", "ahammer/Shimmer"], &no_gh/1) end)
    File.write!(service, "projects: {shimmer: {}, other: {enabled: false}}")
    parent = self()

    gh = fn
      ["label", "list" | _] ->
        {"crescendo:ready\nCRESCENDO:HOLD\n", 0}

      ["label", "create", name | rest] ->
        send(parent, {:created, name, rest})
        {"", 0}
    end

    output = capture_io(fn -> assert :ok = Commands.run(["labels", "sync", service], gh) end)

    created = collect_created()
    refute "crescendo:ready" in created
    refute "crescendo:hold" in created

    for label <- ["crescendo:in-review", "crescendo:blocked", "crescendo:channel:qa", "crescendo:size:small", "crescendo:model:sol"],
        do: assert(label in created)

    assert output =~ "shimmer: created crescendo:blocked"
    assert Enum.count(created, &(&1 == "crescendo:blocked")) == 1

    assert {:error, "no project nothing-matches"} = Commands.run(["labels", "sync", service, "nothing-matches"], &no_gh/1)

    listing_failure = fn
      ["label", "list" | _] -> {"HTTP 403: denied", 1}
      args -> flunk("unexpected gh call: #{inspect(args)}")
    end

    assert {:error, "shimmer: could not list labels: HTTP 403: denied"} =
             Commands.run(["labels", "sync", service, "shimmer"], listing_failure)

    create_failure = fn
      ["label", "list" | _] -> {"", 0}
      ["label", "create", "crescendo:blocked" | _] -> {"HTTP 403: denied", 1}
      args -> flunk("unexpected gh call: #{inspect(args)}")
    end

    assert {:error, "shimmer: could not create crescendo:blocked: HTTP 403: denied"} =
             Commands.run(["labels", "sync", service, "shimmer"], create_failure)
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

  test "labels migrate moves open issues and pull requests to the project's prefix", %{service: service} do
    capture_io(fn -> Commands.run(["project", "add", service, "metalrain", "ahammer/metalrain"], &no_gh/1) end)
    File.write!(service, "projects: {metalrain: {}}")
    parent = self()
    listing = "repos/ahammer/metalrain/issues?state=open&per_page=100&labels="

    gh = fn
      ["api", "--paginate", ^listing <> "symphony%3Aready" | _] -> {"12\n", 0}
      ["api", "--paginate" | _] -> {"", 0}
      ["api", "-X", method, path | _] -> send(parent, {:gh, method, path}) && {"", 0}
    end

    output = capture_io(fn -> assert :ok = Commands.run(["labels", "migrate", service, "metalrain", "--from", "symphony"], gh) end)

    assert_received {:gh, "POST", "repos/ahammer/metalrain/issues/12/labels"}
    assert_received {:gh, "DELETE", "repos/ahammer/metalrain/issues/12/labels/symphony:ready"}
    assert output =~ "metalrain: #12 symphony:ready -> crescendo:ready"

    listing_failure = fn
      ["api", "--paginate", ^listing <> "symphony%3Aready" | _] -> {"HTTP 502", 1}
      ["api", "--paginate" | _] -> {"", 0}
      args -> flunk("unexpected gh call: #{inspect(args)}")
    end

    assert {:error, "metalrain: symphony:ready: could not list items: HTTP 502"} =
             Commands.run(["labels", "migrate", service, "metalrain", "--from", "symphony"], listing_failure)

    add_failure = fn
      ["api", "--paginate", ^listing <> "symphony%3Aready" | _] -> {"12\n", 0}
      ["api", "--paginate" | _] -> {"", 0}
      ["api", "-X", "POST", "repos/ahammer/metalrain/issues/12/labels" | _] -> {"HTTP 403", 1}
      args -> flunk("unexpected gh call: #{inspect(args)}")
    end

    assert {:error, "metalrain: #12 could not add crescendo:ready while moving symphony:ready: HTTP 403"} =
             Commands.run(["labels", "migrate", service, "metalrain", "--from", "symphony"], add_failure)

    remove_failure = fn
      ["api", "--paginate", ^listing <> "symphony%3Aready" | _] -> {"12\n", 0}
      ["api", "--paginate" | _] -> {"", 0}
      ["api", "-X", "POST", "repos/ahammer/metalrain/issues/12/labels" | _] -> {"", 0}
      ["api", "-X", "DELETE", "repos/ahammer/metalrain/issues/12/labels/symphony:ready"] -> {"HTTP 403", 1}
      args -> flunk("unexpected gh call: #{inspect(args)}")
    end

    assert {:error, "metalrain: #12 could not remove symphony:ready after adding crescendo:ready: HTTP 403"} =
             Commands.run(["labels", "migrate", service, "metalrain", "--from", "symphony"], remove_failure)

    assert {:error, "no project nubu"} = Commands.run(["labels", "migrate", service, "nubu", "--from", "symphony"], &no_gh/1)
    assert {:error, "cannot read " <> _} = Commands.run(["labels", "migrate", service <> ".missing", "x", "--from", "s"], &no_gh/1)
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

  test "drain off reports when the drain flag cannot be removed", %{root: root, service: service} do
    File.write!(service, "paths: {state: state}\nprojects: {a: {}}")
    drain = Path.join([root, "state", "drain"])
    File.mkdir_p!(drain)

    output =
      capture_io(fn ->
        assert {:error, "could not remove drain flag " <> details} = Commands.run(["drain", "off", service], &no_gh/1)
        assert [^drain, reason] = String.split(details, ": ", parts: 2)
        assert reason != ""
      end)

    refute output =~ "Drain off"
    assert File.dir?(drain)
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
