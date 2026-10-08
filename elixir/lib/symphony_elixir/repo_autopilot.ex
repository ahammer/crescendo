defmodule SymphonyElixir.RepoAutopilot do
  @moduledoc """
  Mirrors a project repository's `.crescendo/autopilot/` folder (from its
  default branch) into a local directory the project's workflow store loads
  alongside `WORKFLOW.md`: `autopilot.yml`, `guidelines.md` and `tasks/*.md`.

  The mirror is rewritten only when a file's blob changed, and replaced as a
  whole (a fresh directory renamed into place), so the store reloads once
  per change and never sees half a folder. A repository without the folder
  removes the mirror, and the project falls back to its local channels. A
  failed read keeps the last good mirror. Directory listings are conditional
  requests, so an unchanged folder costs no rate limit.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Project}
  alias SymphonyElixir.GitHub.Client

  @folder ".crescendo/autopilot"
  @manifest ".manifest"
  @max_files 60
  @max_bytes 256 * 1024
  @name ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\.(md|yml|yaml)\z/

  @type fetch :: (String.t() -> {:ok, term()} | {:error, term()})
  @type status :: %{
          state: :synced | :absent | :error | :pending,
          error: String.t() | nil,
          checked_at: DateTime.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @doc "The mirror directory of a project's repository folder."
  @spec mirror_dir(Path.t()) :: Path.t()
  def mirror_dir(state_dir), do: Path.join(state_dir, "repo-autopilot")

  @doc "A project's last sync outcome."
  @spec status(Project.id() | nil) :: status()
  def status(project), do: :persistent_term.get({__MODULE__, project}, %{state: :pending, error: nil, checked_at: nil})

  @doc "Last successfully observed repository commit; errors remain unknown."
  @spec revision(Project.id() | nil) :: {:ok, String.t()} | {:error, term()}
  def revision(project), do: :persistent_term.get({__MODULE__, :revision, project}, {:error, :source_revision_unknown})

  @impl true
  def init(opts) do
    project = Keyword.get(opts, :project)
    :ok = Project.put(project)
    send(self(), :poll)
    {:ok, %{project: project, dir: Keyword.fetch!(opts, :dir), interval_ms: Keyword.get(opts, :interval_ms, 300_000), fetch: Keyword.get(opts, :fetch)}}
  end

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, state.interval_ms)

    outcome =
      cond do
        state.fetch -> sync(state.dir, state.fetch)
        github?() -> sync(state.dir, &Client.fetch_contents/1)
        true -> :absent
      end

    :persistent_term.put({__MODULE__, state.project}, status_for(outcome))
    if is_nil(state.fetch) and github?(), do: :persistent_term.put({__MODULE__, :revision, state.project}, Client.source_revision())
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp github? do
    match?({:ok, %{tracker: %{kind: "github"}}}, Config.settings())
  end

  defp status_for({:error, reason}) do
    Logger.warning("Repository autopilot sync failed: #{inspect(reason)}; keeping the last mirror")
    %{state: :error, error: inspect(reason), checked_at: DateTime.utc_now()}
  end

  defp status_for(outcome), do: %{state: if(outcome == :absent, do: :absent, else: :synced), error: nil, checked_at: DateTime.utc_now()}

  @doc """
  Brings `dir` in line with the repository folder read through `fetch`
  (a contents API reader). Returns `:unchanged`, `:updated`, `:absent`
  (no folder: the mirror is removed) or an error, which leaves the mirror
  as it was.
  """
  @spec sync(Path.t(), fetch()) :: :unchanged | :updated | :absent | {:error, term()}
  def sync(dir, fetch) do
    case listing(fetch, @folder) do
      {:ok, :not_found} ->
        File.rm_rf!(dir)
        :absent

      {:ok, top} ->
        with {:ok, tasks} <- task_listing(fetch, top),
             {:ok, files} <- wanted(top, tasks) do
          apply_files(dir, files, fetch)
        end

      error ->
        error
    end
  end

  defp listing(fetch, path) do
    case fetch.(path) do
      {:ok, :not_found} -> {:ok, :not_found}
      {:ok, entries} when is_list(entries) -> {:ok, entries}
      {:ok, _other} -> {:error, {:not_a_folder, path}}
      error -> error
    end
  end

  defp task_listing(fetch, top) do
    if Enum.any?(top, &match?(%{"type" => "dir", "name" => "tasks"}, &1)) do
      case listing(fetch, @folder <> "/tasks") do
        {:ok, :not_found} -> {:ok, []}
        other -> other
      end
    else
      {:ok, []}
    end
  end

  # The mirror holds only the files the store reads: top-level YAML and
  # Markdown, and Markdown tasks; anything else in the folder is ignored.
  defp wanted(top, tasks) do
    files =
      for(%{"type" => "file", "name" => name, "sha" => sha} <- top, Regex.match?(@name, name), do: {name, sha}) ++
        for(%{"type" => "file", "name" => name, "sha" => sha} <- tasks, Regex.match?(@name, name), String.ends_with?(name, ".md"), do: {"tasks/" <> name, sha})

    if length(files) > @max_files, do: {:error, {:too_many_files, length(files)}}, else: {:ok, Map.new(files)}
  end

  defp apply_files(dir, files, fetch) do
    if read_manifest(dir) == files do
      :unchanged
    else
      staging = dir <> ".staging"
      File.rm_rf!(staging)

      with :ok <- stage(files, dir, staging, fetch),
           :ok <- write(Path.join(staging, @manifest), :erlang.term_to_binary(files)) do
        File.rm_rf!(dir)
        :ok = File.rename(staging, dir)
        :updated
      else
        error ->
          File.rm_rf!(staging)
          error
      end
    end
  end

  defp stage(files, dir, staging, fetch) do
    Enum.reduce_while(files, :ok, fn {relative, sha}, :ok ->
      case file_bytes(dir, relative, sha, fetch) do
        {:ok, bytes} -> {:cont, write(Path.join(staging, relative), bytes)}
        error -> {:halt, error}
      end
    end)
  end

  # An unchanged blob is copied from the current mirror instead of fetched again.
  defp file_bytes(dir, relative, sha, fetch) do
    with true <- Map.get(read_manifest(dir), relative) == sha,
         {:ok, bytes} <- File.read(Path.join(dir, relative)) do
      {:ok, bytes}
    else
      _ -> download(fetch, relative)
    end
  end

  defp download(fetch, relative) do
    case fetch.(@folder <> "/" <> relative) do
      {:ok, %{"encoding" => "base64", "content" => content, "size" => size}} when size <= @max_bytes ->
        case Base.decode64(content, ignore: :whitespace) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, {:bad_content, relative}}
        end

      {:ok, %{"size" => size}} when is_integer(size) and size > @max_bytes ->
        {:error, {:file_too_large, relative}}

      {:ok, _other} ->
        {:error, {:bad_content, relative}}

      error ->
        error
    end
  end

  defp write(path, bytes) do
    with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, bytes)
  end

  defp read_manifest(dir) do
    case File.read(Path.join(dir, @manifest)) do
      {:ok, binary} -> :erlang.binary_to_term(binary, [:safe])
      {:error, _reason} -> %{}
    end
  rescue
    ArgumentError -> %{}
  end
end
