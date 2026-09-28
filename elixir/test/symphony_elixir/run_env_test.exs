defmodule SymphonyElixir.RunEnvTest do
  use ExUnit.Case

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
    refute Enum.any?(vars, &match?({"CRESCENDO_LABEL_PREFIX", _}, &1))
  end

  test "with the dashboard serving, runs learn where the state lives" do
    {:ok, pid} = SymphonyElixir.HttpServer.start_link(host: "127.0.0.1", port: 0)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid) end)

    url = "http://127.0.0.1:#{SymphonyElixir.HttpServer.bound_port()}/api/v1/state"
    assert {"CRESCENDO_STATE_URL", url} in RunEnv.vars("GH-1")
    assert {"SYMPHONY_STATE_URL", url} in RunEnv.vars("GH-1")
  end
end
