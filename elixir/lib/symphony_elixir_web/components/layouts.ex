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
              BoardView: {
                mounted: function () {
                  var hook = this;
                  var storageKey = "crescendo.issue-board.pins.v1";
                  try {
                    var keys = JSON.parse(localStorage.getItem(storageKey) || "[]");
                    if (Array.isArray(keys)) hook.pushEvent("restore-pins", {keys: keys});
                  } catch (_) { /* Storage is optional; view state still works. */ }
                  hook.handleEvent("board-pins", function (data) {
                    try { localStorage.setItem(storageKey, JSON.stringify(data.keys)); } catch (_) {}
                  });
                  hook.el.addEventListener("click", function (event) {
                    var button = event.target.closest('[phx-click="select-issue"]');
                    if (button) hook.lastSelectedKey = button.getAttribute("phx-value-key");
                  });
                  hook.handleEvent("board-selection", function () {
                    requestAnimationFrame(function () {
                      hook.syncDrawer();
                      if (window.matchMedia("(max-width: 720px)").matches) {
                        hook.el.querySelector(".issue-detail.is-open")?.focus();
                      }
                    });
                  });
                  hook.handleEvent("board-close", function () {
                    requestAnimationFrame(function () {
                      hook.syncDrawer();
                      if (hook.lastSelectedKey) {
                        hook.el.querySelector('[phx-click="select-issue"][phx-value-key="' +
                          CSS.escape(hook.lastSelectedKey) + '"]')?.focus();
                      }
                    });
                  });
                  hook.el.addEventListener("keydown", function (event) {
                    var drawer = hook.el.querySelector(".issue-detail.is-open");
                    if (event.key === "Escape" && drawer) {
                      event.preventDefault();
                      hook.pushEvent("close-issue", {});
                    }
                    if (event.key === "Tab" && drawer && window.matchMedia("(max-width: 720px)").matches) {
                      var controls = Array.from(drawer.querySelectorAll(
                        'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), summary, [tabindex="0"]'
                      )).filter(function (element) { return element.getClientRects().length > 0; });
                      var first = controls[0];
                      var last = controls[controls.length - 1];
                      if (!first) { event.preventDefault(); drawer.focus(); }
                      else if (event.shiftKey && (document.activeElement === first || document.activeElement === drawer)) {
                        event.preventDefault(); last.focus();
                      } else if (!event.shiftKey && (document.activeElement === last || document.activeElement === drawer)) {
                        event.preventDefault(); first.focus();
                      }
                    }
                  });
                  hook.onResize = function () { hook.syncDrawer(); };
                  window.addEventListener("resize", hook.onResize);
                  hook.syncDrawer();
                },
                updated: function () { this.syncDrawer(); },
                destroyed: function () { window.removeEventListener("resize", this.onResize); },
                syncDrawer: function () {
                  var drawer = this.el.querySelector(".issue-detail");
                  var modal = drawer?.classList.contains("is-open") && window.matchMedia("(max-width: 720px)").matches;
                  if (drawer) {
                    if (modal) { drawer.setAttribute("role", "dialog"); drawer.setAttribute("aria-modal", "true"); }
                    else { drawer.removeAttribute("role"); drawer.removeAttribute("aria-modal"); }
                  }
                  this.el.querySelectorAll(
                    ".workspace-top, .workspace-heading, .workspace-footer, .issue-board-main, .board-stats"
                  ).forEach(function (element) { element.inert = Boolean(modal); });
                }
              },
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
