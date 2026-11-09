defmodule SymphonyElixir.RunEnvTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Project, RunEnv}

  test "a run's commands know their project, work item, route and the state URL" do
    assert RunEnv.vars(nil) == [{"CRESCENDO_LABEL_PREFIX", "symphony"}]
    assert {"SYMPHONY_WORK_ITEM", "GH-1"} in RunEnv.vars("GH-1")
    assert {"CRESCENDO_WORK_ITEM", "GH-1"} in RunEnv.vars("GH-1")

    vars = Project.with_project("metalrain", fn -> RunEnv.vars("GH-12", "default") end)
    assert {"CRESCENDO_PROJECT", "metalrain"} in vars
    assert {"CRESCENDO_WORK_ITEM", "metalrain/GH-12"} in vars
    assert {"SYMPHONY_WORK_ITEM", "GH-12"} in vars
    assert {"SYMPHONY_SELECTED_MODEL_LABEL", "default"} in vars

    # The label prefix comes from the workflow, when one can be read.
    assert {"CRESCENDO_LABEL_PREFIX", "symphony"} in RunEnv.vars("GH-1")
    assert {"CRESCENDO_RUN_ID", "unique-run"} in RunEnv.vars("GH-1", nil, "unique-run")
    refute Enum.any?(vars, &match?({"CRESCENDO_LABEL_PREFIX", _}, &1))
  end

  test "evidence roots prefer project config, expand paths, and retain the legacy alias" do
    keys = ~w(CRESCENDO_EVIDENCE_ROOT METALRAIN_SYMPHONY_EVIDENCE_ROOT CRESCENDO_TEST_EVIDENCE)
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)
    Enum.each(keys, &System.delete_env/1)
    assert Config.evidence_root() == nil
    System.put_env("METALRAIN_SYMPHONY_EVIDENCE_ROOT", "/tmp/legacy-evidence")
    assert Config.evidence_root() == "/tmp/legacy-evidence"
    System.put_env("CRESCENDO_EVIDENCE_ROOT", "/tmp/generic-evidence")
    assert Config.evidence_root() == "/tmp/generic-evidence"
    System.put_env("CRESCENDO_TEST_EVIDENCE", "relative-evidence")
    write_workflow_file!(Workflow.workflow_file_path(), extra_config: %{"evidence" => %{"root" => "$CRESCENDO_TEST_EVIDENCE"}})
    expected = Path.join(Path.dirname(Workflow.workflow_file_path()), "relative-evidence")
    assert Config.evidence_root() == expected
    assert {"CRESCENDO_EVIDENCE_ROOT", expected} in RunEnv.vars("GH-1")
    assert {"METALRAIN_SYMPHONY_EVIDENCE_ROOT", expected} in RunEnv.vars("GH-1")
    System.delete_env("CRESCENDO_TEST_EVIDENCE")
    assert Config.evidence_root() == nil
    {captured, 0} = System.cmd("python3", ["-c", "import json,os; print(json.dumps([os.getenv('CRESCENDO_EVIDENCE_ROOT'), os.getenv('METALRAIN_SYMPHONY_EVIDENCE_ROOT')]))"], env: RunEnv.vars("GH-1"))
    assert Enum.all?(Jason.decode!(captured), &(&1 in [nil, ""]))
    write_workflow_file!(Workflow.workflow_file_path(), extra_config: %{"evidence" => %{"root" => "~/evidence"}})
    assert Config.evidence_root() == Path.expand("~/evidence")
    System.delete_env("METALRAIN_SYMPHONY_EVIDENCE_ROOT")
    refute Enum.any?(RunEnv.vars("GH-1"), fn {key, _} -> key == "METALRAIN_SYMPHONY_EVIDENCE_ROOT" end)
  end

  test "with the dashboard serving, runs learn where the state lives" do
    {:ok, pid} = SymphonyElixir.HttpServer.start_link(host: "127.0.0.1", port: 0)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid) end)

    url = "http://127.0.0.1:#{SymphonyElixir.HttpServer.bound_port()}/api/v1/state"
    assert {"CRESCENDO_CONTROL_STATE_URL", url <> "?view=control"} in RunEnv.vars("GH-1")
    assert {"CRESCENDO_STATE_URL", url} in RunEnv.vars("GH-1")
    assert {"SYMPHONY_STATE_URL", url} in RunEnv.vars("GH-1")
  end
end
