defmodule SymphonyElixir.Artifacts do
  @moduledoc """
  Images agents saw during a run, copied into a Symphony-owned store so the
  dashboard can show them in the run's transcript.

  Each run gets `<root>/<run_id>/` holding `<n>.<ext>` files. Only files in this
  store are ever served, only real PNG, JPEG, GIF or WebP data is kept, and a
  run's images are deleted three days after the run was last active.
  """

  @max_bytes 10 * 1024 * 1024
  @max_per_run 40
  @retention_seconds 3 * 24 * 60 * 60
  @run_id ~r/\A[0-9a-f]{24}\z/
  @name ~r/\A\d{1,3}\.(png|jpg|gif|webp)\z/
  @content_types %{"png" => "image/png", "jpg" => "image/jpeg", "gif" => "image/gif", "webp" => "image/webp"}

  @type source :: {:file, Path.t()} | {:data_url, String.t()} | {:base64, String.t(), String.t() | nil}

  @spec root() :: Path.t()
  def root do
    case Application.get_env(:symphony_elixir, :artifacts_root) do
      root when is_binary(root) ->
        root

      _ ->
        log_file = Application.get_env(:symphony_elixir, :log_file, SymphonyElixir.LogFile.default_log_file())
        Path.join(Path.dirname(log_file), "artifacts")
    end
  end

  @doc "Stores one image for a run and returns how the dashboard references it."
  @spec store(String.t(), source(), Path.t()) :: {:ok, %{name: String.t(), src: String.t()}} | :error
  def store(run_id, source, root \\ root()) when is_binary(run_id) do
    with true <- Regex.match?(@run_id, run_id),
         {:ok, bytes} <- read_source(source),
         {:ok, extension} <- image_extension(bytes),
         directory = Path.join(root, run_id),
         :ok <- File.mkdir_p(directory),
         {:ok, index} <- next_index(directory),
         name = "#{index}.#{extension}",
         :ok <- File.write(Path.join(directory, name), bytes) do
      {:ok, %{name: name, src: "/artifacts/#{run_id}/#{name}"}}
    else
      _ -> :error
    end
  end

  @doc "Resolves a stored image, refusing anything that is not one."
  @spec path(String.t(), String.t(), Path.t()) :: {:ok, Path.t()} | :error
  def path(run_id, name, root \\ root()) do
    with true <- is_binary(run_id) and Regex.match?(@run_id, run_id),
         true <- is_binary(name) and Regex.match?(@name, name),
         path = Path.join([root, run_id, name]),
         true <- File.regular?(path) do
      {:ok, path}
    else
      _ -> :error
    end
  end

  @spec content_type(String.t()) :: String.t()
  def content_type(name), do: Map.get(@content_types, name |> Path.extname() |> String.trim_leading("."), "application/octet-stream")

  @doc "Deletes stored images of runs that are not active and have been idle for three days."
  @spec sweep([String.t()], Path.t(), integer()) :: :ok
  def sweep(active_run_ids, root \\ root(), now \\ System.os_time(:second)) do
    active = MapSet.new(active_run_ids)

    case File.ls(root) do
      {:ok, runs} ->
        for run_id <- runs,
            Regex.match?(@run_id, run_id),
            not MapSet.member?(active, run_id),
            directory = Path.join(root, run_id),
            {:ok, %File.Stat{mtime: mtime}} <- [File.stat(directory, time: :posix)],
            now - mtime > @retention_seconds do
          File.rm_rf(directory)
        end

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp read_source({:file, path}) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_bytes -> File.read(path)
      _ -> :error
    end
  end

  defp read_source({:data_url, "data:" <> rest}) do
    case String.split(rest, ",", parts: 2) do
      [meta, data] -> if String.ends_with?(meta, ";base64"), do: decode(data), else: :error
      _ -> :error
    end
  end

  defp read_source({:base64, data, _mime}) when is_binary(data), do: decode(data)
  defp read_source(_source), do: :error

  defp decode(data) when byte_size(data) <= div(@max_bytes * 4, 3) + 4 do
    case Base.decode64(data, ignore: :whitespace) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> :error
    end
  end

  defp decode(_data), do: :error

  defp image_extension(<<0x89, "PNG", _::binary>>), do: {:ok, "png"}
  defp image_extension(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "jpg"}
  defp image_extension(<<"GIF8", _::binary>>), do: {:ok, "gif"}
  defp image_extension(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, "webp"}
  defp image_extension(_bytes), do: :error

  defp next_index(directory) do
    count = directory |> File.ls!() |> length()
    if count < @max_per_run, do: {:ok, count + 1}, else: :error
  end
end
