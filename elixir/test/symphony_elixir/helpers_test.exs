defmodule SymphonyElixir.HelpersTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Helpers, Service}

  setup do
    root = Path.join(System.tmp_dir!(), "crescendo-helpers-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspaces/lead")
    File.mkdir_p!(workspace)
    git!(workspace, ["init", "-q"])
    File.write!(Path.join(workspace, "source.txt"), "accepted original\n")
    File.write!(Path.join(workspace, "empty.txt"), "")
    File.write!(Path.join(workspace, "large.txt"), String.duplicate("x", 140_000))
    File.ln_s!("/etc/passwd", Path.join(workspace, "link"))
    git!(workspace, ["add", "."])
    git!(workspace, ["-c", "user.name=Helper Test", "-c", "user.email=helper@example.test", "commit", "-qm", "source"])
    prior_home = System.get_env("CODEX_HOME")
    home = Path.join(root, "codex-home")
    File.mkdir_p!(home)

    File.write!(
      Path.join(home, "models_cache.json"),
      Jason.encode!(%{"models" => [%{"slug" => "gpt-6-luna", "multi_agent_version" => "v2", "apply_patch_tool_type" => "freeform"}, %{"slug" => "gpt-6.1-sol", "apply_patch_tool_type" => "freeform"}]})
    )

    System.put_env("CODEX_HOME", home)
    previous = Service.current()
    evidence_root = System.get_env("METALRAIN_SYMPHONY_EVIDENCE_ROOT")

    on_exit(fn ->
      :persistent_term.put({Service, :current}, previous)
      restore_env("METALRAIN_SYMPHONY_EVIDENCE_ROOT", evidence_root)
      restore_env("CODEX_HOME", prior_home)
      File.rm_rf(root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(root, "workspaces"))
    context = %{workspace: workspace, run_id: "lead-run", issue_id: "lead", project: "test", recipient: self()}
    context = Map.put(context, :codex_settings, Config.settings!().codex)
    %{root: root, context: context}
  end

  test "lead catalogs suppress forced delegation while keeping native editing", %{root: root} do
    Service.put_current(%Service{state_root: root})
    assert {:ok, codex, config} = Helpers.lead_session(Config.settings!().codex)
    catalog = catalog_from_command(codex.command)
    assert Enum.all?(catalog["models"], &(&1["multi_agent_version"] == "disabled"))
    assert Enum.all?(catalog["models"], &(&1["apply_patch_tool_type"] == "freeform"))
    assert config["agents.max_threads"] == 1
    assert byte_size(Helpers.error_text(String.duplicate("é", 30_000))) <= 16_384
    File.write!(Path.join(System.get_env("CODEX_HOME"), "models_cache.json"), "invalid")
    assert {:error, :helper_model_catalog_unknown} = Helpers.lead_session(Config.settings!().codex)
  end

  test "source reads use the captured commit and reject traversal, pathspecs, links and oversized files", %{context: context} do
    assert {:ok, prepared} = Helpers.prepare(context, %{"question" => "Inspect ownership"})
    File.write!(Path.join(context.workspace, "source.txt"), "uncommitted change")
    assert %{"text" => "accepted original\n", "source_sha" => sha} = read(prepared, "read", "source.txt")
    assert sha == prepared.source_sha
    assert %{"text" => ""} = read(prepared, "read", "empty.txt")
    assert %{"text" => paths} = read(prepared, "list", "")
    assert paths =~ "source.txt"
    assert %{"text" => matches} = read(prepared, "search", "", "original")
    assert matches =~ "source.txt:1:accepted original"
    assert %{"text" => ""} = read(prepared, "search", "", "not present")
    assert %{"truncated" => true, "text" => preview} = read(prepared, "search", "large.txt", "x")
    assert byte_size(preview) <= 16_384

    for path <- ["../source.txt", "/etc/passwd", ".git/config", "*.txt", "[a].txt", "source?txt", ":(glob)*", "-source.txt", "link", "large.txt", "missing", 3, "x\n"] do
      assert Helpers.read_tool("read_source", %{"operation" => "read", "path" => path}, prepared)["success"] == false
    end

    assert Helpers.read_tool("read_source", %{"operation" => "execute", "path" => "source.txt"}, prepared)["success"] == false
    assert Helpers.read_tool("read_source", %{"operation" => "search", "query" => ""}, prepared)["success"] == false
    assert Helpers.read_tool("shell", %{}, prepared)["success"] == false
    assert {:error, :invalid_helper_request} = Helpers.prepare(context, %{"question" => "", "unexpected" => true})
    assert {:error, :invalid_helper_request} = Helpers.prepare(Map.put(context, :worker_host, "remote"), %{"question" => "Inspect"})
    assert {:error, :invalid_helper_request} = Helpers.prepare(%{context | workspace: "/missing-helper-workspace"}, %{"question" => "Inspect"})
    assert {:error, :source_unavailable} = Helpers.prepare(Map.delete(context, :workspace), %{"question" => "Inspect"})
  end

  test "evidence is bounded, frozen at admission, and cannot follow symlink roots or components", %{root: root, context: context} do
    evidence = Path.join(root, "evidence")
    File.mkdir_p!(Path.join(evidence, "nested"))
    File.write!(Path.join(evidence, "nested/report.json"), "original evidence")
    File.write!(Path.join(evidence, "empty"), "")
    File.write!(Path.join(evidence, "binary"), <<0, 255>>)
    File.write!(Path.join(evidence, "large"), String.duplicate("x", 140_000))
    File.write!(Path.join(evidence, "summary"), String.duplicate("ü", 20_000))
    File.ln_s!("/etc/passwd", Path.join(evidence, "escape"))
    File.ln_s!("/etc", Path.join(evidence, "outside"))
    System.put_env("METALRAIN_SYMPHONY_EVIDENCE_ROOT", evidence)
    assert {:ok, prepared} = Helpers.prepare(context, %{"question" => "Inspect", "evidence_keys" => ["nested/report.json", "empty", "summary"]})
    File.rm!(Path.join(evidence, "nested/report.json"))
    assert %{"text" => "original evidence", "evidence_id" => "1"} = result(Helpers.read_tool("read_evidence", %{"evidence_id" => "1"}, prepared))
    assert %{"text" => ""} = result(Helpers.read_tool("read_evidence", %{"evidence_id" => "2"}, prepared))
    assert %{"text" => text, "truncated" => true} = result(Helpers.read_tool("read_evidence", %{"evidence_id" => "3"}, prepared))
    assert byte_size(text) <= 16_384 and String.valid?(text)
    assert Helpers.read_tool("read_evidence", %{"evidence_id" => "missing"}, prepared)["success"] == false

    for keys <- [["escape"], ["binary"], ["outside/passwd"], ["large"], ["missing"], ["../source.txt"], [3], List.duplicate("empty", 13), "empty"] do
      assert {:error, :invalid_helper_request} = Helpers.prepare(context, %{"question" => "Inspect", "evidence_keys" => keys})
    end

    root_link = Path.join(root, "root-link")
    File.ln_s!(evidence, root_link)
    System.put_env("METALRAIN_SYMPHONY_EVIDENCE_ROOT", root_link)
    assert {:error, :invalid_helper_request} = Helpers.prepare(context, %{"question" => "Inspect", "evidence_keys" => ["empty"]})
    System.delete_env("METALRAIN_SYMPHONY_EVIDENCE_ROOT")
    assert {:error, :invalid_helper_request} = Helpers.prepare(context, %{"question" => "Inspect", "evidence_keys" => ["empty"]})
  end

  test "helper session exposes only curated reads, rejects native approval, and retains a bounded report", %{root: root, context: context} do
    start_supervised!({WorkflowStore, name: SymphonyElixir.Project.via("test", :workflow_store), project: "test", path: Workflow.workflow_file_path()})
    {:ok, service} = Service.parse(%{"paths" => %{"state" => root}, "projects" => %{"test" => %{}}}, Path.join(root, "service.yml"))
    Service.put_current(service)
    refute Helpers.enabled?()
    assert Helpers.tool_names() == ~w(helper_start helper_status helper_cancel)
    assert length(Helpers.tool_specs()) == 3
    assert Helpers.execute("helper_status", %{}, context)["success"] == false
    assert Helpers.execute("helper_start", [], context)["success"] == false
    assert :ok = Helpers.cancel_owned()

    details = %{run_id: "child", issue_identifier: "helper-child"}
    observed = Path.join(root, "observed.jsonl")
    peer = Path.expand("../fixtures/helper_app_server.py", __DIR__)
    codex = %{context.codex_settings | command: "python3 '#{peer}' '#{observed}' helper app-server"}
    {:ok, prepared} = Helpers.prepare(%{context | codex_settings: codex}, %{"question" => "Inspect"})
    assert {:ok, %{summary: summary}} = Helpers.run(prepared, details, %Service.Helpers{})
    assert String.starts_with?(summary, "Pinned source observations") and byte_size(summary) <= 16_384
    messages = File.stream!(observed) |> Enum.map(&Jason.decode!/1)
    thread = Enum.find(messages, &(&1["method"] == "thread/start"))["params"]
    assert Enum.map(thread["dynamicTools"], & &1["name"]) == ~w(read_source read_evidence)
    assert thread["sandbox"] == "read-only"
    assert thread["config"]["features.multi_agent"] == false
    assert thread["config"]["model_catalog_json"] == "/proc/self/fd/198"
    # The real bootstrap seals the catalog before exec; the fixture verifies it cannot write it.
    leaf = Enum.find(messages, &(&1["catalog"] != nil))["catalog"]
    assert [%{"slug" => "gpt-6-luna", "multi_agent_version" => "disabled", "apply_patch_tool_type" => nil}] = leaf["models"]
    assert thread["config"]["agents.max_threads"] == 1
    assert thread["config"]["features.shell_tool"] == false
    assert thread["config"]["features.view_image"] == false

    assert thread["config"]["mcp_servers"] == %{
             "inherited-server" => %{"enabled" => false},
             "dotted.server" => %{"enabled" => false},
             "quoted\"server" => %{"enabled" => false}
           }

    refute File.exists?(Path.join(context.workspace, "escaped"))

    codex = %{codex | command: "python3 '#{peer}' '#{observed}' approval app-server"}
    assert {:error, {:approval_required, _}} = Helpers.run(put_in(prepared.context.codex_settings, codex), details, %Service.Helpers{})
    assert {:error, :helper_tool_configuration_unknown} = Helpers.run(put_in(prepared.context.codex_settings.command, "invalid"), details, %Service.Helpers{})
    assert {:ok, _} = Helpers.run(put_in(prepared.context.recipient, nil), details, %Service.Helpers{})
    File.write!(Path.join(System.get_env("CODEX_HOME"), "models_cache.json"), "invalid")
    assert {:error, :helper_tool_configuration_unknown} = Helpers.run(prepared, details, %Service.Helpers{})
  end

  test "Git reads cannot keep a helper alive beyond their command deadline", %{root: root, context: context} do
    executable = Path.join(root, "git")
    File.write!(executable, "#!/bin/sh\nexec sleep 30\n")
    File.chmod!(executable, 0o755)
    previous = System.get_env("PATH")
    System.put_env("PATH", root <> ":" <> previous)
    on_exit(fn -> System.put_env("PATH", previous) end)
    assert {:error, :invalid_helper_request} = Helpers.prepare(context, %{"question" => "Inspect"})
  end

  defp catalog_from_command(command) do
    ["python3", "-c", _script, encoded | _] = OptionParser.split(command)
    encoded |> Base.decode64!() |> :zlib.gunzip() |> Jason.decode!()
  end

  defp read(prepared, operation, path, query \\ nil), do: result(Helpers.read_tool("read_source", %{"operation" => operation, "path" => path, "query" => query}, prepared))
  defp result(%{"success" => true, "output" => output}), do: Jason.decode!(output)
  defp git!(workspace, args), do: assert(match?({_, 0}, System.cmd("git", args, cd: workspace, stderr_to_stdout: true)))
end
