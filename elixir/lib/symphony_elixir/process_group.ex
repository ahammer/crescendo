defmodule SymphonyElixir.ProcessGroup do
  @moduledoc "Bounds subprocess output and kills a spawn port's OS group on completion or owner death."

  @spec run(port(), pos_integer()) :: {:ok, {String.t(), non_neg_integer()}} | {:error, :timeout}
  def run(port, timeout_ms) do
    os_pid = os_pid(port)
    owner = self()
    watcher = spawn(fn -> watch(owner, os_pid) end)

    try do
      collect(port, "", System.monotonic_time(:millisecond) + timeout_ms)
    after
      send(watcher, :finish)
      receive do: ({:group_cleaned, ^watcher} -> :ok)
      close(port)
    end
  end

  @doc "Protects session initialization even if its owner is killed before it can close the port."
  @spec protect(port()) :: :ok
  def protect(port) do
    owner = self()
    os_pid = os_pid(port)

    spawn(fn ->
      Process.monitor(owner)
      :erlang.monitor(:port, port)

      receive do
        {:DOWN, _ref, _type, _object, _reason} -> kill(os_pid)
      end
    end)

    :ok
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  @spec stop(port()) :: :ok
  def stop(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        kill(os_pid)
        close(port)

      nil ->
        :ok
    end

    :ok
  end

  defp close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp watch(owner, os_pid) do
    ref = Process.monitor(owner)

    receive do
      :finish ->
        kill(os_pid)
        Process.demonitor(ref, [:flush])
        send(owner, {:group_cleaned, self()})

      {:DOWN, ^ref, :process, ^owner, _reason} ->
        kill(os_pid)
    end
  end

  defp kill(nil), do: :ok

  defp kill(os_pid) do
    System.cmd("kill", ["-KILL", "--", "-#{os_pid}"], stderr_to_stdout: true)
    :ok
  end

  defp collect(port, output, deadline) do
    receive do
      {^port, {:data, data}} -> collect(port, String.slice(output <> data, -2_048, 2_048), deadline)
      {^port, {:exit_status, status}} -> {:ok, {output, status}}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> {:error, :timeout}
    end
  end
end
