defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:dashboard_css_url, SymphonyElixirWeb.StaticAssets.dashboard_css_url())
      |> assign(:favicon_url, SymphonyElixirWeb.StaticAssets.favicon_url())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Crescendo</title>
        <link rel="icon" type="image/png" sizes="128x128" href={@favicon_url} />
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            // Keeps an agent transcript pinned to its newest entry, like a chat,
            // unless the reader has scrolled up to look at something older.
            var hooks = {
              ChatScroll: {
                mounted: function () {
                  var el = this.el;
                  var hook = this;
                  hook.stick = true;
                  el.addEventListener("scroll", function () {
                    hook.stick = el.scrollHeight - el.scrollTop - el.clientHeight < 48;
                  }, {passive: true});
                  el.addEventListener("load", function () {
                    if (hook.stick) el.scrollTop = el.scrollHeight;
                  }, true);
                  el.scrollTop = el.scrollHeight;
                },
                updated: function () {
                  if (this.stick) this.el.scrollTop = this.el.scrollHeight;
                }
              }
            };

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: hooks
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href={@dashboard_css_url} />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @doc "A full-screen page without the dashboard's gutters (the agent inspector)."
  @spec bare(map()) :: Phoenix.LiveView.Rendered.t()
  def bare(assigns) do
    ~H"""
    <main class="app-bare">
      {@inner_content}
    </main>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
