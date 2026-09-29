defmodule SymphonyElixir.QuotaProbeTest do
  use ExUnit.Case

  alias SymphonyElixir.{Governor, QuotaProbe, Service}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-quota-probe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  # A fake app server: it answers the rate-limit read (request id 2) with `reply`.
  defp fake_server(root, reply) do
    path = Path.join(root, "app-server")
    File.write!(path, "#!/bin/sh\nwhile read -r line; do case \"$line\" in *'\"id\":2'*) echo '#{reply}';; *) echo '{\"noise\":true}';; esac; done\n")
    File.chmod!(path, 0o755)
    path
  end

  @limits ~s({"id":2,"result":{"rateLimits":{"planType":"pro","primary":{"usedPercent":4,"windowDurationMins":10080,"resetsAt":1791046716}}}})

  test "reads the quota from the app server", %{root: root} do
    assert %{plan: "pro", windows: %{"weekly" => %{used_percent: 4.0}}} = QuotaProbe.read(fake_server(root, @limits))
  end

  test "an error reply, an exit or silence reads as no quota", %{root: root} do
    assert QuotaProbe.read(fake_server(root, ~s({"id":2,"error":{"message":"no"}}))) == nil
    assert QuotaProbe.read("sh -c 'read -r line; exit 3'") == nil
    assert QuotaProbe.read("sleep 5", 50) == nil
    # The default command comes from the application environment (`cat` in tests).
    assert QuotaProbe.read() == nil
  end

  test "the Governor probes a stale quota and takes the reading", %{root: root} do
    previous = Application.get_env(:symphony_elixir, :quota_probe_command)
    Application.put_env(:symphony_elixir, :quota_probe_command, fake_server(root, @limits))
    on_exit(fn -> Application.put_env(:symphony_elixir, :quota_probe_command, previous) end)

    {:ok, service} = Service.parse(%{"paths" => %{"state" => "state"}, "projects" => %{"a" => %{}}}, Path.join(root, "crescendo.yml"))
    start_supervised!({Governor, service})

    assert Enum.find_value(1..100, fn _ ->
             Process.sleep(20)
             match?(%{quota: %{windows: %{"weekly" => %{used_percent: 4.0}}}}, Governor.snapshot())
           end)

    # A fresh reading is not probed again.
    send(Process.whereis(Governor), :probe_quota)
    assert %{quota: %{}} = Governor.snapshot()
  end
end
