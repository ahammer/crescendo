defmodule SymphonyElixir.QuotaProbe do
  @moduledoc """
  Reads the Codex account quota straight from a short-lived app server
  (`account/rateLimits/read`), without starting a thread or spending quota.

  Runs report the quota as they go, but a service that is paused on a nearly
  spent window starts no runs, so without a probe it would never see the
  window reset early (a reset credit, a plan change) and stay paused until the
  reset time it last saw.
  """

  alias SymphonyElixir.Quota

  @default_command "codex app-server"

  @doc "The current quota, or nil when the app server cannot be read in time."
  @spec read(String.t() | nil, non_neg_integer()) :: Quota.t() | nil
  def read(command \\ nil, timeout_ms \\ 20_000) do
    command = command || Application.get_env(:symphony_elixir, :quota_probe_command, @default_command)

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        {:line, 1_048_576},
        args: ["-c", "exec " <> command]
      ])

    Enum.each(
      [
        %{id: 1, method: "initialize", params: %{clientInfo: %{name: "crescendo-quota", version: "1"}}},
        %{method: "initialized"},
        %{id: 2, method: "account/rateLimits/read"}
      ],
      &Port.command(port, [Jason.encode!(&1), "\n"])
    )

    result = await(port, System.monotonic_time(:millisecond) + timeout_ms)
    close(port)
    result
  end

  defp await(port, deadline) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, %{"id" => 2, "result" => %{"rateLimits" => limits}}} -> Quota.normalize(limits, DateTime.utc_now())
          {:ok, %{"id" => 2}} -> nil
          _other -> await(port, deadline)
        end

      {^port, {:exit_status, _status}} ->
        nil
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> nil
    end
  end

  defp close(port) do
    with {:os_pid, os_pid} <- Port.info(port, :os_pid) do
      Port.close(port)
      System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  end
end
