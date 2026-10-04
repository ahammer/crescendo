defmodule SymphonyElixir.SourceRevisionTest do
  use ExUnit.Case

  alias SymphonyElixir.SourceRevision

  @revision String.duplicate("a", 40)
  @unknown %{revision: nil, commit_url: nil}

  setup do
    root = Path.join(System.tmp_dir!(), "source-revision-#{System.unique_integer([:positive])}")
    release = Path.join([root, "releases", @revision])
    source = Path.join(release, "source/elixir")
    File.mkdir_p!(source)
    File.write!(Path.join(release, ".built"), "")
    previous = SourceRevision.metadata()
    burrito = System.get_env("__BURRITO")
    System.delete_env("__BURRITO")

    on_exit(fn ->
      :persistent_term.put({SourceRevision, :metadata}, previous)
      SymphonyElixir.TestSupport.restore_env("__BURRITO", burrito)
      File.rm_rf!(root)
    end)

    %{root: root, release: release, source: source}
  end

  test "captures a pinned release once, ignoring environment and later file changes", %{source: source, release: release} do
    previous = System.get_env("CRESCENDO_RELEASE")
    System.put_env("CRESCENDO_RELEASE", "/private/credentials/releases/" <> String.duplicate("b", 40))
    on_exit(fn -> SymphonyElixir.TestSupport.restore_env("CRESCENDO_RELEASE", previous) end)

    assert :ok = SourceRevision.initialize(source)
    assert SourceRevision.metadata() == %{revision: @revision, commit_url: "https://github.com/ahammer/crescendo/commit/" <> @revision}
    File.write!(Path.join(release, ".built"), String.duplicate("b", 40) <> "\n")
    assert SourceRevision.metadata().revision == @revision

    assert :ok = SourceRevision.initialize(source)
    assert SourceRevision.metadata() == @unknown
  end

  test "missing, unreadable and malformed build markers stay unknown", %{source: source, release: release} do
    stamp = Path.join(release, ".built")

    for content <- [@revision, "\n", "/host/secret\n"] do
      File.write!(stamp, content)
      SourceRevision.initialize(source)
      assert SourceRevision.metadata() == @unknown
    end

    File.rm!(stamp)
    SourceRevision.initialize(source)
    assert SourceRevision.metadata() == @unknown
    File.mkdir!(stamp)
    SourceRevision.initialize(source)
    assert SourceRevision.metadata() == @unknown
  end

  test "development, non-source, missing and malformed release directories stay unknown", %{root: root, source: source} do
    for path <- [
          __DIR__,
          "releases/#{@revision}/source/elixir",
          root,
          Path.join(root, "missing"),
          Path.join([root, "releases", "main", "source/elixir"]),
          Path.join([root, "releases", @revision, "bin"]),
          Path.join([root, "releases", String.upcase(@revision), "source/elixir"])
        ] do
      SourceRevision.initialize(path)
      assert SourceRevision.metadata() == @unknown
    end

    File.rm_rf!(source)
    SourceRevision.initialize(source)
    assert SourceRevision.metadata() == @unknown

    # Default initialization cannot use an inherited release environment to label a checkout.
    assert :ok = SourceRevision.initialize()
  end

  test "a checkout or Burrito package cannot claim an installed source identity", %{source: source} do
    git = Path.join(source, "../.git")
    File.write!(git, "gitdir: /private/repository")
    SourceRevision.initialize(source)
    assert SourceRevision.metadata() == @unknown
    File.rm!(git)
    File.mkdir!(git)
    SourceRevision.initialize(source)
    assert SourceRevision.metadata() == @unknown
    File.rm_rf!(git)

    System.put_env("__BURRITO", "1")
    SourceRevision.initialize(source)
    assert SourceRevision.metadata() == @unknown
  end

  test "an uninitialized owner is explicitly unknown" do
    :persistent_term.erase({SourceRevision, :metadata})
    assert SourceRevision.metadata() == @unknown
  end
end
