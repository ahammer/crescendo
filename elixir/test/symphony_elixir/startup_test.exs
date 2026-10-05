defmodule SymphonyElixir.StartupTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Operations, Startup}

  test "startup budget is bounded independently of delivery attempts and recovers with config" do
    identity = %{identifier: "GH-43", run_id: "run", worker_host: nil}
    diagnostic = Startup.diagnostic(:before_run, {:workspace_hook_failed, "before_run", 1, ""})
    assert diagnostic.empty_output
    assert diagnostic.context == ""
    assert diagnostic.status == 1
    assert Startup.ready?(nil)
    first = Startup.failed(nil, identity, diagnostic, 7)
    refute Startup.ready?(first)
    assert first.delivery_attempt == 7
    second = Startup.failed(first, identity, diagnostic, 7)
    third = Startup.failed(second, identity, diagnostic, 7)
    probe = Startup.failed(third, identity, diagnostic, 7)
    assert [first.count, second.count, third.count, probe.count] == [1, 2, 3, 3]
    assert third.due_at_ms - first.due_at_ms >= 1_790_000
    assert Startup.ready?(%{third | due_at_ms: 0})
    write_workflow_file!(Workflow.workflow_file_path(), hook_before_run: "true")
    assert Startup.ready?(third)
    assert Startup.failed(third, identity, diagnostic, 7).count == 1
  end

  test "diagnostics retain phase and status, bound and sanitize output without inventing a cause" do
    assert %{status: "timeout", hook: "after_create", timeout_ms: 10, context: "No output captured"} =
             Startup.diagnostic(:workspace, {:workspace_hook_timeout, "after_create", 10})

    assert %{phase: :session_start, status: "timeout", context: "App-server startup response timed out"} =
             Startup.diagnostic(:session_start, :response_timeout)

    assert %{status: 75, context: "", empty_output: true} =
             Startup.diagnostic(:workspace, {:workspace_prepare_failed, "worker", 75, ""})

    assert %{status: 2} = Startup.diagnostic(:session_start, {:port_exit, 2})
    assert %{status: "error"} = Startup.diagnostic(:worker_start, :unavailable)
    text = <<255>> <> "\e[31msecret=abc Bearer hidden ghp_abcdef sk-example\n" <> String.duplicate("x", 3_000)
    safe = Startup.sanitize(text)
    assert String.valid?(safe)
    assert String.length(safe) == 2_048
    refute safe =~ "abc"
    refute safe =~ "hidden"
    refute safe =~ "ghp_"
    refute safe =~ "\e"
    json = Startup.sanitize(~s({"token":"credential-value","password":"hunter2"}))
    refute json =~ "credential-value"
    refute json =~ "hunter2"
    refute Startup.sanitize("https://user:credential@example.test/repo") =~ "credential"
  end

  test "startup records survive a store reopen and old stores default to empty" do
    root = Path.join(System.tmp_dir!(), "startup-store-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    assert Operations.startup_state(nil) == %{}
    assert Operations.save_startup_state(nil, %{}) == :ok
    path = Path.join(root, "operations.dets")
    assert {:ok, table} = Operations.open(path, :startup_test_store)
    assert Operations.startup_state(table) == %{}
    entry = Startup.failed(nil, %{}, Startup.diagnostic(:worker_spawn, :unavailable), 2)
    assert :ok = Operations.save_startup_state(table, %{"GH-43" => entry})

    details = %{
      run_id: "run",
      worker_pid: "worker",
      worker_host: "remote",
      issue_id: "GH-43",
      issue_identifier: "GH-43",
      startup_attempt: 3,
      startup: entry.diagnostic,
      summary: "Startup blocked"
    }

    assert :ok = Operations.event(table, "startup_blocked", details)
    assert :ok = Operations.close(table)
    assert {:ok, table} = Operations.open(path, :startup_test_store)
    assert Operations.startup_state(table) == %{"GH-43" => entry}
    assert [event] = Operations.snapshot(table).activity
    assert Map.take(event, Map.keys(details)) == details
    assert :ok = Operations.close(table)
  end
end
