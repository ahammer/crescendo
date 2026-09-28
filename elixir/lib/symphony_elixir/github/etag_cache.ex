defmodule SymphonyElixir.GitHub.ETagCache do
  @moduledoc """
  Conditional GETs for the GitHub API. A response's ETag is remembered with
  its body; the next identical request sends `If-None-Match`, and a `304 Not
  Modified` answer reuses the remembered body. GitHub does not count 304s
  against the rate limit, so polling unchanged issues, dependencies and pull
  requests across many projects costs almost nothing.

  The table belongs to this process, which runs for the service's lifetime;
  without it (a command run, a test) requests simply go unconditional.
  """

  use GenServer

  @table :symphony_github_etags
  @max_entries 20_000

  @type key :: {String.t(), [{term(), term()}], non_neg_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    {:ok, nil}
  end

  @doc "The cache key of a GET: its URL, its query and (hashed, never stored) the token that sees it."
  @spec key(String.t(), map() | keyword() | nil, String.t()) :: key()
  def key(url, params, token), do: {url, params |> Kernel.||([]) |> Enum.sort(), :erlang.phash2(token)}

  @doc "Headers that make the request conditional, when an earlier answer is remembered."
  @spec headers(key()) :: [{String.t(), String.t()}]
  def headers(key) do
    case lookup(key) do
      {etag, _body} -> [{"If-None-Match", etag}]
      nil -> []
    end
  end

  @doc """
  Settles a response: a 304 becomes the remembered answer, a success with an
  ETag is remembered, anything else passes through.
  """
  @spec resolve(key(), %{status: integer(), headers: map(), body: term()}) :: %{status: integer(), body: term()}
  def resolve(key, %{status: 304} = response) do
    case lookup(key) do
      {_etag, body} -> %{status: 200, body: body}
      nil -> Map.take(response, [:status, :body])
    end
  end

  def resolve(key, %{status: status, headers: headers, body: body}) when status in 200..299 do
    case headers["etag"] do
      [etag | _] when is_binary(etag) -> remember(key, etag, body)
      _ -> :ok
    end

    %{status: status, body: body}
  end

  def resolve(_key, response), do: Map.take(response, [:status, :body])

  defp lookup(key) do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      table ->
        case :ets.lookup(table, key) do
          [{^key, etag, body}] -> {etag, body}
          [] -> nil
        end
    end
  end

  # A bounded table: past the limit it starts over, which only costs one
  # unconditional request per resource.
  defp remember(key, etag, body) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      table ->
        if :ets.info(table, :size) >= @max_entries, do: :ets.delete_all_objects(table)
        :ets.insert(table, {key, etag, body})
        :ok
    end
  end
end
