defmodule SymphonyElixirWeb.LiveRefresh do
  @moduledoc """
  Keeps a LiveView's `payload` current. It reloads on observability updates, at
  most once per `dashboard_reload_ms` (Codex streams many notifications a
  second; the first update after a quiet spell loads at once), and ticks `now`
  every second so runtimes count up between updates.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias Phoenix.LiveView
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub}

  @tick_ms 1_000

  @doc "Loads the first payload with `load` and, once connected, subscribes and starts ticking."
  @spec start(LiveView.Socket.t(), (-> map())) :: LiveView.Socket.t()
  def start(socket, load) do
    socket = socket |> assign(load: load, reload_timer: nil) |> reload()

    if LiveView.connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      Process.send_after(self(), :runtime_tick, @tick_ms)
    end

    socket
  end

  @doc "Handles the tick, update and deferred-reload messages `start/2` sets up."
  @spec handle_info(term(), LiveView.Socket.t()) :: LiveView.Socket.t()
  def handle_info(:runtime_tick, socket) do
    Process.send_after(self(), :runtime_tick, @tick_ms)
    assign(socket, :now, DateTime.utc_now())
  end

  def handle_info(:observability_updated, %{assigns: %{reload_timer: nil}} = socket) do
    wait = socket.assigns.loaded_at + reload_ms() - System.monotonic_time(:millisecond)
    if wait <= 0, do: reload(socket), else: assign(socket, :reload_timer, Process.send_after(self(), :reload, wait))
  end

  def handle_info(:observability_updated, socket), do: socket
  def handle_info(:reload, socket), do: socket |> assign(:reload_timer, nil) |> reload()
  def handle_info(_message, socket), do: socket

  defp reload(socket) do
    assign(socket, payload: socket.assigns.load.(), now: DateTime.utc_now(), loaded_at: System.monotonic_time(:millisecond))
  end

  defp reload_ms, do: Endpoint.config(:dashboard_reload_ms) || 1_000
end
