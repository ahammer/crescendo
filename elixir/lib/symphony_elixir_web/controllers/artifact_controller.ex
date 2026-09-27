defmodule SymphonyElixirWeb.ArtifactController do
  @moduledoc """
  Serves images from Symphony's artifact store for run transcripts.

  Only files that `SymphonyElixir.Artifacts` stored are reachable: both path
  segments must match the store's naming, so no request can name another file.
  """

  use Phoenix.Controller, formats: []

  alias Plug.Conn
  alias SymphonyElixir.Artifacts
  alias SymphonyElixirWeb.Endpoint

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"run_id" => run_id, "name" => name}) do
    case Artifacts.path(run_id, name, root()) do
      {:ok, path} ->
        conn
        |> put_resp_content_type(Artifacts.content_type(name), nil)
        |> put_resp_header("cache-control", "public, max-age=86400, immutable")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_file(200, path)

      :error ->
        send_resp(conn, 404, "Not Found")
    end
  end

  defp root, do: Endpoint.config(:artifacts_root) || Artifacts.root()
end
