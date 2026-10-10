defmodule SymphonyElixir.DeployDrainTest do
  use ExUnit.Case

  alias SymphonyElixir.DeployDrain

  setup do
    root = Path.join(System.tmp_dir!(), "deploy-owner-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "absent, malformed and unavailable managed observations fail safely", %{root: root} do
    assert DeployDrain.observe(root) == nil
    File.write!(Path.join(root, "deploy-drain.json"), "invalid")
    assert DeployDrain.observe(root)["owner_status"] == "unknown"
    path = System.fetch_env!("PATH")
    on_exit(fn -> System.put_env("PATH", path) end)
    System.put_env("PATH", root)
    assert DeployDrain.observe(root)["owner_status"] == "unknown"
    executable = Path.join(root, "python3")
    File.write!(executable, "#!/bin/sh\nprintf 'invalid'\n")
    File.chmod!(executable, 0o755)
    assert DeployDrain.observe(root)["owner_status"] == "unknown"
    File.write!(executable, "#!/bin/sh\nprintf 'null'\n")
    assert DeployDrain.observe(root) == nil
    File.write!(executable, "#!/bin/sh\nprintf '{\"kind\":\"managed\",\"phase\":\"waiting\",\"token\":\"private\"}'\n")
    assert DeployDrain.observe(root) == %{"kind" => "managed", "phase" => "waiting"}
  end

  test "manual holds have explicit provenance and legacy holds stay unknown", %{root: root} do
    assert DeployDrain.manual(root)["kind"] == "legacy_unknown"
    flag = Path.join(root, "drain")
    File.write!(flag, "legacy-owner-do-not-publish")
    assert DeployDrain.manual(root) == %{"kind" => "legacy_unknown", "phase" => "held"}

    for invalid <- [42, "private-host-path"] do
      File.write!(flag, Jason.encode!(%{kind: "manual", started_at: invalid}))
      assert DeployDrain.manual(root)["kind"] == "legacy_unknown"
    end

    File.write!(flag, Jason.encode!(%{kind: "manual", started_at: "2026-10-10T22:00:00Z", token: "private"}))
    assert DeployDrain.manual(root) == %{"kind" => "manual", "phase" => "held", "started_at" => "2026-10-10T22:00:00Z"}
  end
end
