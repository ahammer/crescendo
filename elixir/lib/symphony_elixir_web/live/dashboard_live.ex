defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Blocked</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail">Issues paused for operator input or approval.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Recorded tokens</p>
            <p class="metric-value numeric"><%= format_int(if(@payload.usage.status == "ok", do: @payload.usage.recorded.total_tokens, else: @payload.codex_totals.total_tokens)) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(if(@payload.usage.status == "ok", do: @payload.usage.recorded.input_tokens, else: @payload.codex_totals.input_tokens)) %> / Out <%= format_int(if(@payload.usage.status == "ok", do: @payload.usage.recorded.output_tokens, else: @payload.codex_totals.output_tokens)) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Ready next</p>
            <p class="metric-value numeric"><%= @payload.counts.ready %></p>
            <p class="metric-detail"><%= @payload.upcoming.available_slots || 0 %> worker slots available.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Estimated API USD</p>
            <p class="metric-value numeric"><%= if @payload.usage.status == "ok", do: format_usd(@payload.usage.recorded[:usd_micro]), else: "n/a" %></p>
            <p class="metric-detail">Today (UTC) <%= format_usd(@payload.usage.today[:usd_micro]) %> · since recording began.<%= if @payload.usage.recorded[:unpriced_tokens] > 0 do %> Partial: <%= format_int(@payload.usage.recorded.unpriced_tokens) %> tokens unpriced.<% end %></p>
          </article>
        </section>

        <section :if={@payload.usage.status == "ok" and (@payload.usage.today[:usd_micro] || 0) >= 50_000_000} class="error-card" role="alert">
          <h2 class="error-title">Worker usage alert</h2>
          <p class="error-copy">Estimated Symphony worker usage today (UTC) reached <%= format_usd(@payload.usage.today[:usd_micro]) %>, above the $50 alert threshold. Planning and independent review usage are not included.</p>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Upcoming issues</h2>
              <p class="section-copy">Open tracker issues in dispatch order. Only ready issues are queued · <%= @payload.upcoming.observed_at || "not polled yet" %></p>
            </div>
          </div>
          <%= if @payload.upcoming.error do %><p class="error-copy">Tracker data is stale: <%= @payload.upcoming.error %></p><% end %>
          <p class="section-copy"><%= @payload.counts.ready %> ready · <%= @payload.counts.waiting %> waiting · showing up to 25 of each</p>
          <%= if @payload.upcoming.ready == [] and @payload.upcoming.waiting == [] do %>
            <p class="empty-state">No upcoming issues in the last poll.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table">
                <thead><tr><th>Issue</th><th>Title</th><th>Priority</th><th>State</th></tr></thead>
                <tbody>
                  <tr :for={issue <- Enum.take(@payload.upcoming.ready, 25)}>
                    <td><.issue_identifier identifier={issue.issue_identifier} url={issue.issue_url} /></td>
                    <td><%= issue.title %></td><td><%= issue.priority || "—" %></td><td>Ready</td>
                  </tr>
                  <tr :for={issue <- Enum.take(@payload.upcoming.waiting, 25)}>
                    <td><.issue_identifier identifier={issue.issue_identifier} url={issue.issue_url} /></td>
                    <td><%= issue.title %></td><td><%= issue.priority || "—" %></td>
                    <td><%= issue.reason %><%= if issue.blocked_by != [] do %> · <%= Enum.join(issue.blocked_by, ", ") %><% end %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section :if={@payload.pull_requests.enabled} class="section-card">
          <div class="section-header"><div>
            <h2 class="section-title">Open pull requests (<%= @payload.counts.open_prs %>)</h2>
            <p class="section-copy">Read-only GitHub inventory, oldest update first · <%= @payload.pull_requests.observed_at || "not polled yet" %></p>
          </div></div>
          <%= if @payload.pull_requests.error do %><p class="error-copy">GitHub data is stale: <%= @payload.pull_requests.error %></p><% end %>
          <%= if @payload.pull_requests.items == [] do %>
            <p class="empty-state">No open pull requests in the last poll.</p>
          <% else %>
            <p :if={@payload.counts.open_prs > 100} class="section-copy">Showing the 100 oldest updates.</p>
            <div class="table-wrap"><table class="data-table">
              <thead><tr><th>PR</th><th>Title</th><th>Stage</th><th>Last update</th></tr></thead>
              <tbody>
                <tr :for={pull <- Enum.take(@payload.pull_requests.items, 100)}>
                  <td><a class="issue-id issue-id-link" href={external_issue_url(pull.url)} target="_blank" rel="noopener noreferrer">#<%= pull.number %></a></td>
                  <td><%= pull.title %></td><td><%= if pull.draft, do: "Draft", else: "Open for review" %></td><td class="mono"><%= pull.updated_at %></td>
                </tr>
              </tbody>
            </table></div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header"><div>
            <h2 class="section-title">Model usage</h2>
            <p class="section-copy">API equivalent estimate at standard short-context prices dated <%= @payload.usage.pricing_as_of %>. ChatGPT charges may differ.</p>
          </div></div>
          <%= if @payload.usage.status != "ok" do %><p class="error-copy">History unavailable<%= if @payload.usage_error do %>: <%= @payload.usage_error %><% end %>.</p><% end %>
          <%= if @payload.usage.by_model == [] do %>
            <p class="empty-state">No recorded model usage yet.</p>
          <% else %>
            <div class="table-wrap"><table class="data-table">
              <thead><tr><th>Model</th><th>Runs</th><th>Input</th><th>Cached input</th><th>Output</th><th>Tokens</th><th>Estimated USD</th></tr></thead>
              <tbody>
                <tr :for={usage <- @payload.usage.by_model}>
                  <td><%= usage.model %></td><td class="numeric"><%= usage.runs %></td><td class="numeric"><%= format_int(usage.input_tokens) %></td>
                  <td class="numeric"><%= format_int(usage.cached_input_tokens) %></td><td class="numeric"><%= format_int(usage.output_tokens) %></td>
                  <td class="numeric"><%= format_int(usage.total_tokens) %></td>
                  <td class="numeric"><%= if usage.unpriced_tokens > 0, do: "unpriced", else: format_usd(usage.usd_micro) %></td>
                </tr>
              </tbody>
            </table></div>
          <% end %>
          <p :if={@payload.usage.recorded[:unpriced_tokens] > 0} class="section-copy"><%= format_int(@payload.usage.recorded.unpriced_tokens) %> tokens have no known model price.</p>
        </section>

        <section class="section-card">
          <div class="section-header"><div><h2 class="section-title">Activity timeline</h2><p class="section-copy">Recent worker and observed PR changes.</p></div></div>
          <%= if @payload.usage.activity == [] do %>
            <p class="empty-state">No recorded activity yet.</p>
          <% else %>
            <ol class="activity-list">
              <li :for={event <- @payload.usage.activity}>
                <time class="mono"><%= event.at %></time>
                <strong><%= event.kind |> String.replace("_", " ") %></strong>
                <%= if Map.get(event, :issue_identifier) do %><.issue_identifier identifier={event.issue_identifier} url={Map.get(event, :issue_url)} /><% end %>
                <%= if Map.get(event, :pr_number) do %><a href={external_issue_url(Map.get(event, :pr_url))} target="_blank" rel="noopener noreferrer">PR #<%= event.pr_number %></a><% end %>
                <span><%= Map.get(event, :summary) %></span>
              </li>
            </ol>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                      <span class="muted"><%= entry.model || "model unknown" %></span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Blocked sessions</h2>
              <p class="section-copy">Issues paused because Codex requested operator input or approval.</p>
            </div>
          </div>

          <%= if @payload.blocked == [] do %>
            <p class="empty-state">No blocked sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Blocked at</th>
                    <th>Last update</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.blocked}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state || "Blocked")}>
                        <%= entry.state || "Blocked" %>
                      </span>
                    </td>
                    <td>
                      <%= if entry.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label="Copy ID"
                          data-copy={entry.session_id}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          Copy ID
                        </button>
                      <% else %>
                        <span class="muted">n/a</span>
                      <% end %>
                    </td>
                    <td class="mono"><%= entry.blocked_at || "n/a" %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp format_usd(value) when is_integer(value) do
    value |> Kernel./(1_000_000) |> then(&:io_lib.format("$~.2f", [&1])) |> to_string()
  end

  defp format_usd(_), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
