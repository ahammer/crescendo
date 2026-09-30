defmodule SymphonyElixir.DeployStateTest do
  use ExUnit.Case, async: true

  @validator Path.expand("../../../ops/bin/deploy-state.py", __DIR__)

  test "deployment validators fail closed on incomplete state without service access" do
    state = %{
      snapshot_status: "complete",
      project: nil,
      projects: [%{id: "alpha", started: true, failure: nil, snapshot_status: "ok", running: 0, ready: 0}],
      counts: %{running: 0},
      running: [],
      throttle: %{busy: 0}
    }

    assert {"0\n", 0} = validate(state, "running")
    assert {"", 0} = validate(state, "healthy")
    assert {"2\n", 0} = validate(%{state | throttle: %{busy: 2}}, "running")
    assert {"1\n", 0} = validate(%{state | running: [%{}], counts: %{running: 1}}, "running")

    unknown_project = %{hd(state.projects) | snapshot_status: "timeout", running: nil, ready: nil}

    invalid = [
      %{state | snapshot_status: "partial"},
      %{state | projects: [unknown_project]},
      %{state | projects: [%{unknown_project | snapshot_status: "unavailable"}]},
      %{state | projects: [%{unknown_project | snapshot_status: "not_selected"}]},
      %{state | projects: [%{hd(state.projects) | started: false}]},
      %{state | projects: [%{hd(state.projects) | failure: "failed"}]},
      %{state | project: "alpha"},
      %{state | projects: []},
      %{state | counts: %{running: nil}},
      %{state | counts: %{running: true}},
      %{state | running: nil},
      %{state | counts: %{running: 1}},
      %{state | throttle: %{busy: nil}},
      Map.put(state, :error, %{}),
      Map.delete(state, :snapshot_status),
      %{},
      nil
    ]

    for observation <- invalid, mode <- ["running", "healthy"] do
      assert {_message, 1} = validate(observation, mode)
    end

    assert {_message, 1} = validate(state, "unknown")
  end

  defp validate(state, mode) do
    wrapper = "import subprocess, sys; sys.exit(subprocess.run(sys.argv[2:], input=sys.argv[1].encode()).returncode)"
    System.cmd("python3", ["-c", wrapper, Jason.encode!(state), "python3", @validator, mode], stderr_to_stdout: true)
  end
end
