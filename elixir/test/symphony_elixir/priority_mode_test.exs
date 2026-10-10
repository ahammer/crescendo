defmodule SymphonyElixir.PriorityModeTest do
  use ExUnit.Case

  alias SymphonyElixir.{PriorityMode, Service}

  @now ~U[2026-10-10 20:00:00Z]
  @expiry "2026-10-11T00:00:00-07:00"

  setup do
    root = Path.join(System.tmp_dir!(), "crescendo-priority-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Service.current()

    on_exit(fn ->
      :persistent_term.put({Service, :current}, previous)
      File.rm_rf(root)
    end)

    %{root: root, service: %Service{state_root: root}}
  end

  test "an expiring Fast default survives reload and switches to standard exactly at its deadline", %{service: service, root: root} do
    assert %{enabled: false, service_tier: "default", error: nil} = PriorityMode.status(service, @now)
    Service.put_current(service)
    assert PriorityMode.current_tier() == "default"
    assert {:ok, %{enabled: true, service_tier: "fast", expires_at: @expiry}} = PriorityMode.set(service, %{"enabled" => true, "expires_at" => @expiry}, @now)
    assert PriorityMode.status(%Service{state_root: root}, ~U[2026-10-11 06:59:59Z]).service_tier == "fast"
    assert %{enabled: false, expired: true, service_tier: "default"} = PriorityMode.status(service, ~U[2026-10-11 07:00:00Z])
    assert {:ok, %{enabled: false, expired: false}} = PriorityMode.set(service, %{"enabled" => false}, @now)
    assert PriorityMode.status(service, @now).service_tier == "default"
  end

  test "a persistent default can be enabled and disabled without altering single-workflow defaults", %{service: service} do
    :persistent_term.put({Service, :current}, nil)
    assert PriorityMode.current_tier() == nil
    assert {:ok, %{enabled: true, expires_at: nil}} = PriorityMode.set(service, %{"enabled" => true}, @now)
    Service.put_current(service)
    assert PriorityMode.current_tier() == "fast"
    assert {:ok, _} = PriorityMode.set(service, %{"enabled" => false}, @now)
    assert PriorityMode.current_tier() == "default"
  end

  test "invalid writes preserve the previous operator policy", %{service: service, root: root} do
    assert {:ok, _} = PriorityMode.set(service, %{"enabled" => true}, @now)
    before = File.read!(Path.join(root, "priority-mode.json"))

    for invalid <- [
          %{},
          %{"enabled" => "yes"},
          %{"enabled" => true, "extra" => 1},
          %{"enabled" => true, "expires_at" => 1},
          %{"enabled" => true, "expires_at" => "2026-10-10T20:00:00Z"},
          %{"enabled" => true, "expires_at" => "2026-10-10"}
        ] do
      assert {:error, _} = PriorityMode.set(service, invalid, @now)
      assert File.read!(Path.join(root, "priority-mode.json")) == before
    end
  end

  test "invalid or unreadable persisted policies fail closed and failed writes leave no partial policy", %{service: service, root: root} do
    path = Path.join(root, "priority-mode.json")

    for invalid <- ["{", "{}", Jason.encode!(%{enabled: true, expires_at: "bad", updated_at: "now"}), Jason.encode!(%{enabled: true, expires_at: 7, updated_at: "now"})] do
      File.write!(path, invalid)
      assert %{enabled: false, error: "priority policy is invalid"} = PriorityMode.status(service, @now)
    end

    File.rm!(path)
    File.mkdir!(path)
    assert %{enabled: false, error: "priority policy is unreadable"} = PriorityMode.status(service, @now)
    assert {:error, "could not write priority policy"} = PriorityMode.set(service, %{"enabled" => true}, @now)
    File.rm_rf!(path)
    File.write!(path, "not a directory")
    assert {:error, "could not write priority policy"} = PriorityMode.set(%Service{state_root: path}, %{"enabled" => true}, @now)
    assert File.read!(path) == "not a directory"
    assert File.ls!(root) == ["priority-mode.json"]
  end
end
