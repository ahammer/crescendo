defmodule SymphonyElixir.SmartassModeTest do
  use ExUnit.Case

  alias SymphonyElixir.{Service, SmartassMode}

  @now ~U[2026-10-10 20:00:00Z]
  @expiry "2026-10-11T00:00:00-07:00"

  setup do
    root = Path.join(System.tmp_dir!(), "crescendo-smartass-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Service.current()

    on_exit(fn ->
      :persistent_term.put({Service, :current}, previous)
      File.rm_rf(root)
    end)

    %{root: root, service: %Service{state_root: root}}
  end

  test "an expiring Fast default survives reload and switches to standard exactly at its deadline", %{service: service, root: root} do
    assert %{enabled: false, error: nil} = SmartassMode.status(service, @now)
    Service.put_current(service)
    assert SmartassMode.admit_model("gpt-6-luna") == :ok
    assert {:ok, %{enabled: true, expires_at: @expiry}} = SmartassMode.set(service, %{"enabled" => true, "expires_at" => @expiry}, @now)
    assert SmartassMode.status(%Service{state_root: root}, ~U[2026-10-11 06:59:59Z]).enabled
    assert %{enabled: false, expired: true} = SmartassMode.status(service, ~U[2026-10-11 07:00:00Z])
    assert {:ok, %{enabled: false, expired: false}} = SmartassMode.set(service, %{"enabled" => false}, @now)
    refute SmartassMode.status(service, @now).enabled
  end

  test "default permission expires after one hour and no service means no Astra", %{service: service} do
    :persistent_term.put({Service, :current}, nil)
    assert SmartassMode.admit_model("gpt-6-astra") == {:error, :smartass_required}
    assert {:ok, %{enabled: true, expires_at: "2026-10-10T21:00:00Z"}} = SmartassMode.set(service, %{"enabled" => true}, @now)
    Service.put_current(service)
    assert {:ok, _} = SmartassMode.set(service, %{"enabled" => true})
    assert SmartassMode.admit_model("gpt-6-astra") == :ok
    assert SmartassMode.admit_route(%{"model" => "gpt-6-astra", "tier" => 2}) == {:error, :smartass_required}
    assert SmartassMode.admit_route(%{"model" => "gpt-6-astra"}) == :ok
    assert SmartassMode.admit_route(nil) == :ok
    assert SmartassMode.admit_model(nil) == :ok
    assert SmartassMode.admit_effective(nil, nil) == :ok
    assert SmartassMode.admit_effective(nil, "gpt-6-luna") == :ok
    assert SmartassMode.admit_effective(nil, "gpt-6-astra") == {:error, :smartass_required}
    assert SmartassMode.admit_effective(%{"model" => "gpt-6-astra"}, "gpt-6-astra") == :ok
    assert {:ok, _} = SmartassMode.set(service, %{"enabled" => false}, @now)
    assert SmartassMode.admit_model("gpt-6-luna") == :ok
  end

  test "invalid writes preserve the previous operator policy", %{service: service, root: root} do
    assert {:ok, _} = SmartassMode.set(service, %{"enabled" => true}, @now)
    before = File.read!(Path.join(root, "smartass-mode.json"))

    for invalid <- [
          %{},
          %{"enabled" => true, "expires_at" => nil},
          %{"enabled" => "yes"},
          %{"enabled" => true, "extra" => 1},
          %{"enabled" => true, "expires_at" => 1},
          %{"enabled" => true, "expires_at" => "2026-10-10T20:00:00Z"},
          %{"enabled" => true, "expires_at" => "2026-10-10"}
        ] do
      assert {:error, _} = SmartassMode.set(service, invalid, @now)
      assert File.read!(Path.join(root, "smartass-mode.json")) == before
    end
  end

  test "invalid or unreadable persisted policies fail closed and failed writes leave no partial policy", %{service: service, root: root} do
    path = Path.join(root, "smartass-mode.json")

    for invalid <- ["{", "{}", Jason.encode!(%{enabled: true, expires_at: "bad", updated_at: "now"}), Jason.encode!(%{enabled: true, expires_at: 7, updated_at: "now"})] do
      File.write!(path, invalid)
      assert %{enabled: false, error: "smartass policy is invalid"} = SmartassMode.status(service, @now)
    end

    File.rm!(path)
    File.mkdir!(path)
    assert %{enabled: false, error: "smartass policy is unreadable"} = SmartassMode.status(service, @now)
    assert {:error, "could not write smartass policy"} = SmartassMode.set(service, %{"enabled" => true}, @now)
    File.rm_rf!(path)
    File.write!(path, "not a directory")
    assert {:error, "could not write smartass policy"} = SmartassMode.set(%Service{state_root: path}, %{"enabled" => true}, @now)
    assert File.read!(path) == "not a directory"
    assert File.ls!(root) == ["smartass-mode.json"]
  end
end
