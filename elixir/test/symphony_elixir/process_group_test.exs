defmodule SymphonyElixir.ProcessGroupTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProcessGroup

  test "bounded source reads retain a prefix and stop an infinite producer" do
    assert {:ok, {"abc", 0}} = ProcessGroup.run(port("printf abc"), 1_000, output_limit: 100)
    assert {:error, {:output_limit, output}} = ProcessGroup.run(port("exec yes prefix"), 1_000, output_limit: 1_000)
    assert byte_size(output) == 1_000
    assert String.starts_with?(output, "prefix")
  end

  test "continuous subprocess output cannot extend the absolute deadline" do
    worker = Task.async(fn -> ProcessGroup.run(port("exec yes"), 50) end)
    result = Task.yield(worker, 1_000) || Task.shutdown(worker, :brutal_kill)
    assert result == {:ok, {:error, :timeout}}
  end

  test "output and deadline are bounded, descendants die on timeout and owner cancellation" do
    assert {:ok, {"hello", 7}} = ProcessGroup.run(port("printf hello; exit 7"), 1_000)
    assert {:ok, {output, 0}} = ProcessGroup.run(port("head -c 4000 /dev/zero | tr '\\0' x; printf marker"), 1_000)
    assert String.length(output) == 2_048
    assert String.ends_with?(output, "marker")
    assert {:error, :timeout} = ProcessGroup.run(port("exec sleep 60"), 10)

    parent = self()

    owner =
      spawn(fn ->
        child_port = port("exec sleep 60")
        :ok = ProcessGroup.protect(child_port)
        send(parent, {:port, child_port})
        ProcessGroup.run(child_port, 60_000)
      end)

    assert_receive {:port, child_port}
    Process.sleep(10)
    {:os_pid, child} = Port.info(child_port, :os_pid)
    Process.exit(owner, :kill)
    await_dead(child)

    child_port = port("exec sleep 60")
    {:os_pid, child} = Port.info(child_port, :os_pid)
    assert :ok = ProcessGroup.stop(child_port)
    assert :ok = ProcessGroup.stop(child_port)
    await_dead(child)
    closed_port = port("read line")
    Port.close(closed_port)
    assert :ok = ProcessGroup.protect(closed_port)
    send(self(), {closed_port, {:exit_status, 0}})
    assert {:ok, {"", 0}} = ProcessGroup.run(closed_port, 100)
  end

  defp port(command) do
    Port.open({:spawn_executable, ~c"/bin/sh"}, [:binary, :exit_status, :stderr_to_stdout, args: [~c"-c", String.to_charlist(command)]])
  end

  defp await_dead(pid, attempts \\ 100) do
    cond do
      not File.exists?("/proc/#{pid}") -> :ok
      attempts == 0 -> flunk("process #{pid} survived cancellation")
      true -> Process.sleep(10) && await_dead(pid, attempts - 1)
    end
  end
end
