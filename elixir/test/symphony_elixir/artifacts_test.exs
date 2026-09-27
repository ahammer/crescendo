defmodule SymphonyElixir.ArtifactsTest do
  # Not async: one test changes the application's artifacts_root.
  use ExUnit.Case

  alias SymphonyElixir.Artifacts

  @run "0123456789abcdef01234567"
  @png <<0x89, "PNG", 13, 10, 26, 10, 0, 0>>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0>>

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-artifacts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "stores images from files, data URLs and base64 under opaque names", %{root: root} do
    source = Path.join(root, "source.png")
    File.write!(source, @png)

    assert {:ok, %{name: "1.png", src: "/artifacts/#{@run}/1.png"}} = Artifacts.store(@run, {:file, source}, root)
    assert {:ok, %{name: "2.png"}} = Artifacts.store(@run, {:data_url, "data:image/png;base64," <> Base.encode64(@png)}, root)
    assert {:ok, %{name: "3.jpg"}} = Artifacts.store(@run, {:base64, Base.encode64(@jpeg), "image/jpeg"}, root)
    assert {:ok, %{name: "4.gif"}} = Artifacts.store(@run, {:base64, Base.encode64("GIF89a" <> <<0, 0>>), nil}, root)
    assert {:ok, %{name: "5.webp"}} = Artifacts.store(@run, {:base64, Base.encode64("RIFF" <> <<0, 0, 0, 0>> <> "WEBPVP8 "), nil}, root)

    assert {:ok, path} = Artifacts.path(@run, "3.jpg", root)
    assert File.read!(path) == @jpeg
    assert Artifacts.content_type("3.jpg") == "image/jpeg"
    assert Artifacts.content_type("x.bin") == "application/octet-stream"
  end

  test "refuses anything that is not an image it can name, and never resolves outside the store", %{root: root} do
    source = Path.join(root, "source.png")
    File.write!(source, @png)
    File.write!(Path.join(root, "secret.txt"), "secret")

    assert :error = Artifacts.store(@run, {:data_url, "data:text/html;base64," <> Base.encode64("<html>")}, root)
    assert :error = Artifacts.store(@run, {:data_url, "data:image/png,not-base64"}, root)
    assert :error = Artifacts.store(@run, {:data_url, "data:image/png;base64"}, root)
    assert :error = Artifacts.store(@run, {:base64, String.duplicate("A", 14_000_000), nil}, root)
    assert :error = Artifacts.store(@run, {:base64, "%%%", nil}, root)
    assert :error = Artifacts.store(@run, {:file, root}, root)
    assert :error = Artifacts.store(@run, {:file, Path.join(root, "missing.png")}, root)
    assert :error = Artifacts.store(@run, :bogus, root)
    assert :error = Artifacts.store("../escape", {:file, source}, root)

    assert {:ok, _image} = Artifacts.store(@run, {:file, source}, root)
    assert :error = Artifacts.path(@run, "../secret.txt", root)
    assert :error = Artifacts.path("..", "secret.txt", root)
    assert :error = Artifacts.path(@run, "2.png", root)
    assert :error = Artifacts.path(@run, "1.svg", root)
    assert :error = Artifacts.path(nil, "1.png", root)
  end

  test "caps the images kept per run", %{root: root} do
    for _index <- 1..40, do: assert({:ok, _image} = Artifacts.store(@run, {:base64, Base.encode64(@png), nil}, root))
    assert :error = Artifacts.store(@run, {:base64, Base.encode64(@png), nil}, root)
  end

  test "sweep removes runs idle for a day unless they are still active", %{root: root} do
    [old, active, recent] = ["aaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbb", "cccccccccccccccccccccccc"]
    for run <- [old, active, recent], do: {:ok, _image} = Artifacts.store(run, {:base64, Base.encode64(@png), nil}, root)
    File.mkdir_p!(Path.join(root, "not-a-run"))

    now = System.os_time(:second)
    for run <- [old, active], do: File.touch!(Path.join(root, run), now - 2 * 86_400)

    assert :ok = Artifacts.sweep([active], root, now)
    refute File.exists?(Path.join(root, old))
    assert File.exists?(Path.join(root, active))
    assert File.exists?(Path.join(root, recent))
    assert File.exists?(Path.join(root, "not-a-run"))
    assert :ok = Artifacts.sweep([], Path.join(root, "missing"), now)
  end

  test "the default store sits next to the log file unless configured" do
    previous = Application.get_env(:symphony_elixir, :artifacts_root)
    on_exit(fn -> restore(:artifacts_root, previous) end)

    root = Path.join(System.tmp_dir!(), "symphony-artifacts-default-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    Application.put_env(:symphony_elixir, :artifacts_root, root)
    assert Artifacts.root() == root
    assert {:ok, %{name: "1.png"}} = Artifacts.store(@run, {:base64, Base.encode64(@png), nil})
    assert {:ok, _path} = Artifacts.path(@run, "1.png")

    Application.delete_env(:symphony_elixir, :artifacts_root)
    assert Path.basename(Artifacts.root()) == "artifacts"
  end

  defp restore(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
