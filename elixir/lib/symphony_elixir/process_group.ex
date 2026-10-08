defmodule SymphonyElixir.ProcessGroup do
  @moduledoc "Bounds subprocess output and kills a spawn port's OS group on completion or owner death."

  @spec run(port(), pos_integer(), keyword()) ::
          {:ok, {String.t(), non_neg_integer()}} | {:error, :timeout | {:output_limit, binary()}}
  def run(port, timeout_ms, opts \\ []) do
    os_pid = os_pid(port)
    owner = self()
    watcher = spawn(fn -> watch(owner, os_pid) end)

    try do
      collect(port, "", System.monotonic_time(:millisecond) + timeout_ms, Keyword.get(opts, :output_limit))
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

  defp collect(port, output, deadline, limit) do
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    if remaining_ms > 0 do
      receive do
        {^port, {:data, data}} ->
          combined = output <> data

          cond do
            is_integer(limit) and byte_size(combined) > limit ->
              {:error, {:output_limit, binary_part(combined, 0, limit)}}

            is_integer(limit) ->
              collect(port, combined, deadline, limit)

            true ->
              collect(port, String.slice(combined, -2_048, 2_048), deadline, limit)
          end

        {^port, {:exit_status, status}} ->
          {:ok, {output, status}}
      after
        remaining_ms -> {:error, :timeout}
      end
    else
      {:error, :timeout}
    end
  end
end
