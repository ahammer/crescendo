defmodule SymphonyElixir.SourceRevision do
  @moduledoc """
  Startup identity of an installed source release. Never takes a revision from
  environment variables or a checkout's HEAD; only a gated source archive in
  its revision directory is accepted. Only public commit metadata is kept.
  """

  @source_dir Path.expand("../..", __DIR__)
  @unknown %{revision: nil, commit_url: nil}

  @doc "Captures the source release identity once, before serving snapshots."
  @spec initialize(String.t()) :: :ok
  def initialize(source_dir \\ @source_dir) do
    identity = if System.get_env("__BURRITO") == "1", do: @unknown, else: read_identity(source_dir)
    :persistent_term.put({__MODULE__, :metadata}, identity)
  end

  @doc "Public identity shared by all projects, including unavailable snapshots."
  @spec metadata() :: map()
  def metadata, do: :persistent_term.get({__MODULE__, :metadata}, @unknown)

  defp read_identity(source_dir) do
    with [_, revision] <- Regex.run(~r"\A/.*/releases/([0-9a-f]{40})/source/elixir\z", source_dir),
         true <- File.dir?(source_dir),
         false <- File.exists?(Path.join(source_dir, "../.git")),
         {:ok, ""} <- File.read(Path.join(source_dir, "../../.built")) do
      %{revision: revision, commit_url: "https://github.com/ahammer/crescendo/commit/" <> revision}
    else
      _ -> @unknown
    end
  end
end
