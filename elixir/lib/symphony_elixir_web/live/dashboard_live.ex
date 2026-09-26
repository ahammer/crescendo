defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Charts, Endpoint, ObservabilityPubSub, Presenter}
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
      <header class="topbar">
        <div class="brand">
          <span class="brand-mark" aria-hidden="true"></span>
          <div>
            <h1 class="brand-title">Symphony</h1>
            <p class="brand-sub">Operations Dashboard</p>
          </div>
        </div>
        <div class="topbar-meta">
          <span :if={!@payload[:error] and @payload.autopilot.enabled} class="chip chip-accent">Autopilot on</span>
          <span :if={@payload[:generated_at]} class="mono muted" title="Snapshot time (UTC)">Updated <%= short_time(@payload.generated_at) %> UTC</span>
          <span class="status-badge status-badge-live"><span class="status-badge-dot"></span>Live</span>
          <span class="status-badge status-badge-offline"><span class="status-badge-dot"></span>Offline</span>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">Snapshot unavailable</h2>
          <p class="error-copy"><strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %></p>
        </section>
      <% else %>
        <section :if={@payload.usage.status == "ok" and (@payload.usage.today[:usd_micro] || 0) >= 50_000_000} class="alert-banner" role="alert">
          <strong>Worker usage alert</strong>
          Estimated Symphony worker usage today (UTC) reached <%= format_usd(@payload.usage.today[:usd_micro]) %>, above the $50 alert threshold. Planning and independent review usage are not included.
        </section>

        <section class="tiles" aria-label="Summary">
          <.tile label="Running" value={@payload.counts.running} detail={"#{@payload.upcoming.available_slots || 0} slots free"} accent={@payload.counts.running > 0} />
          <.tile label="Ready next" value={@payload.counts.ready} detail="queued for dispatch" />
          <.tile label="Waiting" value={@payload.counts.waiting} detail="held by labels, deps, CI" />
          <.tile label="Open PRs" value={@payload.counts.open_prs} detail="on GitHub" />
          <.tile label="Retrying" value={@payload.counts.retrying} detail="backing off" warn={@payload.counts.retrying > 0} />
          <.tile label="Blocked" value={@payload.counts.blocked} detail="need an operator" warn={@payload.counts.blocked > 0} />
          <.tile label="Spend today" value={if @payload.usage.status == "ok", do: format_usd(@payload.usage.today[:usd_micro]), else: "n/a"} detail={"#{format_usd(@payload.usage.recorded[:usd_micro])} recorded"} />
          <.tile label="Tokens today" value={compact(@payload.usage.today[:total_tokens])} detail={"#{compact(@payload.usage.recorded[:total_tokens])} recorded"} />
          <.tile label="Runtime" value={format_runtime_seconds(total_runtime_seconds(@payload, @now))} detail="Codex, this process" />
        </section>

        <section class="board">
          <article class="panel panel-agents">
            <header class="panel-head">
              <h2>Active agents <span class="count"><%= length(@payload.running) %></span></h2>
              <span class="panel-note">Live Codex sessions</span>
            </header>
            <%= if @payload.running == [] do %>
              <p class="empty-state">No active sessions. <%= idle_reason(@payload) %></p>
            <% else %>
              <div class="agent-list">
                <article :for={entry <- @payload.running} class="agent-card">
                  <header class="agent-head">
                    <span class={"kind-chip kind-#{work_kind(entry.issue_identifier)}"}><%= kind_label(work_kind(entry.issue_identifier)) %></span>
                    <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                    <span class={state_badge_class(entry.state)}><%= entry.state %></span>
                    <span class="agent-model mono"><%= entry.model || "model unknown" %></span>
                    <span class="agent-spacer"></span>
                    <span class="mono numeric" title="Runtime / turns"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></span>
                  </header>
                  <div class="agent-body">
                    <p class="agent-label">Codex update</p>
                    <p class="agent-message" title={entry.last_message || to_string(entry.last_event || "n/a")}><%= entry.last_message || to_string(entry.last_event || "n/a") %></p>
                    <p class="agent-meta muted">
                      <%= entry.last_event || "n/a" %><%= if entry.last_event_at do %> · <span class="mono"><%= short_time(entry.last_event_at) %></span><% end %>
                    </p>
                  </div>
                  <footer class="agent-foot">
                    <span class="numeric">Tokens <strong><%= format_int(entry.tokens.total_tokens) %></strong> <span class="muted">in <%= compact(entry.tokens.input_tokens) %> / out <%= compact(entry.tokens.output_tokens) %></span></span>
                    <span class="agent-spacer"></span>
                    <%= if entry.session_id do %>
                      <.copy_button value={entry.session_id} />
                    <% end %>
                    <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON</a>
                  </footer>
                </article>
              </div>
            <% end %>
          </article>

          <article class="panel panel-autopilot">
            <header class="panel-head">
              <h2>Autopilot</h2>
              <span class="panel-note"><%= if @payload.autopilot.enabled, do: "PRs → issues → research", else: "off" %></span>
            </header>
            <%= if @payload.autopilot.enabled do %>
              <ol class="stepper" aria-label="Research round">
                <li :for={channel <- Map.get(@payload.autopilot, :channels, [])} class={"step step-#{channel_status(@payload, channel)}"}>
                  <span class="step-dot" aria-hidden="true"></span>
                  <span class="step-name"><%= channel %></span>
                  <span class="step-state"><%= channel_status_label(channel_status(@payload, channel)) %></span>
                </li>
              </ol>
              <p class="panel-copy"><%= research_summary(@payload.autopilot) %></p>
            <% else %>
              <p class="empty-state">Autopilot is disabled in WORKFLOW.md.</p>
            <% end %>

            <header class="panel-subhead"><h3>Needs attention <span class="count"><%= length(@payload.blocked) + length(@payload.retrying) %></span></h3></header>
            <%= if @payload.blocked == [] and @payload.retrying == [] do %>
              <p class="empty-state">Nothing blocked or retrying.</p>
            <% else %>
              <ul class="attention-list">
                <li :for={entry <- @payload.blocked} class="attention-item">
                  <span class="status-tag status-critical">Blocked</span>
                  <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                  <span class="attention-text" title={"#{entry.error} · #{entry.last_message}"}><%= entry.error || "n/a" %><span :if={entry.last_message} class="muted"> · <%= entry.last_message %></span></span>
                  <.copy_button :if={entry.session_id} value={entry.session_id} />
                </li>
                <li :for={entry <- @payload.retrying} class="attention-item">
                  <span class="status-tag status-warning">Retry <%= entry.attempt %></span>
                  <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                  <span class="attention-text" title={entry.error}><%= entry.error || "n/a" %></span>
                  <span class="mono muted"><%= short_time(entry.due_at) %></span>
                </li>
              </ul>
            <% end %>
          </article>

          <article class="panel panel-queue">
            <header class="panel-head">
              <h2>Work queue <span class="count"><%= @payload.counts.ready %> ready · <%= @payload.counts.waiting %> waiting</span></h2>
              <span class="panel-note mono"><%= short_time(@payload.upcoming.observed_at) %></span>
            </header>
            <p :if={@payload.upcoming.error} class="error-copy">Tracker data is stale: <%= @payload.upcoming.error %></p>
            <%= if @payload.upcoming.ready == [] and @payload.upcoming.waiting == [] do %>
              <p class="empty-state">No upcoming work in the last poll.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table">
                  <thead><tr><th>Item</th><th>Title</th><th>State</th></tr></thead>
                  <tbody>
                    <tr :for={issue <- Enum.take(@payload.upcoming.ready, 25)}>
                      <td><.issue_identifier identifier={issue.issue_identifier} url={issue.issue_url} /></td>
                      <td class="cell-title" title={issue.title}><%= issue.title %></td>
                      <td><span class="status-tag status-good">Ready</span></td>
                    </tr>
                    <tr :for={issue <- Enum.take(@payload.upcoming.waiting, 25)}>
                      <td><.issue_identifier identifier={issue.issue_identifier} url={issue.issue_url} /></td>
                      <td class="cell-title" title={issue.title}><%= issue.title %></td>
                      <td class="muted"><%= issue.reason %><%= if issue.blocked_by != [] do %> · <%= Enum.join(issue.blocked_by, ", ") %><% end %></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </article>

          <article :if={@payload.pull_requests.enabled} class="panel panel-prs">
            <header class="panel-head">
              <h2>Pull requests <span class="count"><%= @payload.counts.open_prs %></span></h2>
              <span class="panel-note mono"><%= short_time(@payload.pull_requests.observed_at) %></span>
            </header>
            <p :if={@payload.pull_requests.error} class="error-copy">GitHub data is stale: <%= @payload.pull_requests.error %></p>
            <%= if @payload.pull_requests.items == [] do %>
              <p class="empty-state">No open pull requests.</p>
            <% else %>
              <ul class="pr-list">
                <li :for={pull <- Enum.take(@payload.pull_requests.items, 100)} class="pr-item">
                  <a class="issue-id issue-id-link" href={external_issue_url(pull.url)} target="_blank" rel="noopener noreferrer">#<%= pull.number %></a>
                  <span class="cell-title" title={pull.title}><%= pull.title %></span>
                  <span class={if pull.draft, do: "status-tag", else: "status-tag status-good"}><%= if pull.draft, do: "Draft", else: "Ready" %></span>
                </li>
              </ul>
            <% end %>
          </article>

          <article class="panel panel-activity">
            <header class="panel-head">
              <h2>Activity</h2>
              <span class="panel-note">Workers and PRs, newest first</span>
            </header>
            <%= if @payload.usage.activity == [] do %>
              <p class="empty-state">No recorded activity yet.</p>
            <% else %>
              <ol class="activity-list">
                <li :for={event <- Enum.take(@payload.usage.activity, 60)} class="activity-item">
                  <time class="mono muted" datetime={event.at} title={event.at}><%= short_time(event.at) %></time>
                  <span class={"activity-kind activity-#{event_tone(event.kind)}"}><%= event.kind |> String.replace("_", " ") %></span>
                  <span class="activity-subject">
                    <%= if Map.get(event, :issue_identifier) do %><.issue_identifier identifier={event.issue_identifier} url={Map.get(event, :issue_url)} /><% end %>
                    <%= if Map.get(event, :pr_number) do %><a class="issue-id issue-id-link" href={external_issue_url(Map.get(event, :pr_url))} target="_blank" rel="noopener noreferrer">PR #<%= event.pr_number %></a><% end %>
                  </span>
                  <span class="activity-summary" title={Map.get(event, :summary)}><%= Map.get(event, :summary) %></span>
                </li>
              </ol>
            <% end %>
          </article>

          <article class="panel panel-chart">
            <header class="panel-head">
              <h2>Estimated spend</h2>
              <span class="panel-note">14 days · API-equivalent USD by model</span>
            </header>
            <Charts.columns id="spend-chart" title="Estimated worker spend per day by model, last 14 days" series={spend_series(@payload.usage)} columns={spend_columns(@payload.usage)} format={&format_usd_axis/1} />
          </article>

          <article class="panel panel-chart">
            <header class="panel-head">
              <h2>Worker runs</h2>
              <span class="panel-note">14 days · <%= merged_total(@payload.usage) %> PRs merged</span>
            </header>
            <Charts.columns id="runs-chart" title="Worker runs per day by outcome, last 14 days" series={run_series()} columns={run_columns(@payload.usage)} format={&format_count/1} integer={true} />
          </article>

          <article class="panel panel-models">
            <header class="panel-head">
              <h2>Models</h2>
              <span class="panel-note">Priced <%= @payload.usage.pricing_as_of %></span>
            </header>
            <p :if={@payload.usage.status != "ok"} class="error-copy">History unavailable<%= if @payload.usage_error do %>: <%= @payload.usage_error %><% end %>.</p>
            <%= if @payload.usage.by_model == [] do %>
              <p class="empty-state">No recorded model usage yet.</p>
            <% else %>
              <Charts.bars title="Tokens by model" rows={model_rows(@payload.usage)} />
            <% end %>
            <header class="panel-subhead"><h3>Rate limits</h3></header>
            <%= case rate_limit_meters(@payload.rate_limits) do %>
              <% [] -> %>
                <p class="empty-state">No rate-limit snapshot yet.</p>
              <% meters -> %>
                <Charts.meter :for={meter <- meters} label={meter.label} percent={meter.percent} detail={meter.detail} />
            <% end %>
          </article>
        </section>
      <% end %>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:detail, :string, default: nil)
  attr(:accent, :boolean, default: false)
  attr(:warn, :boolean, default: false)

  defp tile(assigns) do
    ~H"""
    <article class={["tile", @accent && "tile-accent", @warn && "tile-warn"]}>
      <p class="tile-label"><%= @label %></p>
      <p class="tile-value"><%= @value %></p>
      <p :if={@detail} class="tile-detail"><%= @detail %></p>
    </article>
    """
  end

  attr(:value, :string, required: true)

  defp copy_button(assigns) do
    ~H"""
    <button
      type="button"
      class="subtle-button"
      data-label="Copy ID"
      data-copy={@value}
      onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
    >Copy ID</button>
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

  defp work_kind("PR-" <> _), do: "pr"
  defp work_kind("research-" <> _), do: "research"
  defp work_kind(_identifier), do: "issue"

  defp kind_label("pr"), do: "Review"
  defp kind_label("research"), do: "Research"
  defp kind_label(_kind), do: "Issue"

  defp idle_reason(%{autopilot: %{enabled: true} = autopilot}), do: research_summary(autopilot)
  defp idle_reason(_payload), do: "Waiting for ready work."

  defp channel_status(payload, channel) do
    autopilot = payload.autopilot
    running? = Enum.any?(payload.running, &(&1.issue_identifier == "research-#{channel}"))
    pending = Map.get(autopilot, :research_pending, [])

    cond do
      running? -> "running"
      channel in pending -> "pending"
      pending != [] -> "done"
      true -> "idle"
    end
  end

  defp channel_status_label("running"), do: "running"
  defp channel_status_label("pending"), do: "queued"
  defp channel_status_label("done"), do: "done"
  defp channel_status_label(_status), do: "—"

  defp research_summary(autopilot) do
    cond do
      Map.get(autopilot, :research_running, 0) > 0 -> "A planner has the machine to itself; other work waits for it."
      Map.get(autopilot, :research_pending, []) != [] -> "Round in progress; resumes when the queue is idle."
      next = Map.get(autopilot, :next_research_at) -> "Next research round no earlier than #{short_time(next)} UTC."
      true -> "Research starts when the queue is empty."
    end
  end

  defp event_tone(kind) when kind in ["completed", "pr_merged"], do: "good"
  defp event_tone(kind) when kind in ["failed", "blocked"], do: "critical"
  defp event_tone(kind) when kind in ["retry_scheduled", "interrupted", "pr_closed"], do: "warning"
  defp event_tone(_kind), do: "neutral"

  # Series colors follow the model, not its rank: slots come from the stable,
  # name-sorted list of every model with recorded usage.
  defp spend_series(usage) do
    usage.by_model
    |> Enum.map(& &1.model)
    |> Enum.sort()
    |> Enum.with_index()
    |> Enum.map(fn {model, index} -> %{key: model, label: model, class: "series-#{rem(index, 8) + 1}"} end)
  end

  defp spend_columns(usage) do
    Enum.map(Map.get(usage, :daily, []), fn day ->
      %{label: short_date(day.date), tip: day.date, values: day.spend_by_model}
    end)
  end

  defp run_series do
    [
      %{key: :completed, label: "Completed", class: "status-good"},
      %{key: :interrupted, label: "Interrupted", class: "status-warning"},
      %{key: :failed, label: "Failed", class: "status-critical"}
    ]
  end

  defp run_columns(usage) do
    Enum.map(Map.get(usage, :daily, []), fn day ->
      %{label: short_date(day.date), tip: day.date, values: Map.take(day, [:completed, :interrupted, :failed])}
    end)
  end

  defp merged_total(usage), do: usage |> Map.get(:daily, []) |> Enum.map(& &1.merged) |> Enum.sum()

  defp model_rows(usage) do
    classes = usage |> spend_series() |> Map.new(&{&1.key, &1.class})

    usage.by_model
    |> Enum.sort_by(& &1.total_tokens, :desc)
    |> Enum.map(fn row ->
      price = if row.unpriced_tokens > 0, do: "unpriced", else: format_usd(row.usd_micro)
      %{label: row.model, value: row.total_tokens, display: "#{compact(row.total_tokens)} · #{price} · #{row.runs} runs", class: classes[row.model]}
    end)
  end

  defp rate_limit_meters(limits) when is_map(limits) do
    for {name, window} <- [{"Primary", fetch(limits, "primary")}, {"Secondary", fetch(limits, "secondary")}],
        is_map(window),
        percent = fetch(window, "used_percent"),
        is_number(percent) do
      %{label: "#{name} window#{window_label(fetch(window, "window_minutes"))}", percent: round(percent), detail: reset_label(fetch(window, "resets_at"))}
    end
  end

  defp rate_limit_meters(_limits), do: []

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp window_label(minutes) when is_integer(minutes) and minutes >= 1_440, do: " (#{div(minutes, 1_440)}d)"
  defp window_label(minutes) when is_integer(minutes), do: " (#{div(minutes, 60)}h)"
  defp window_label(_minutes), do: ""

  defp reset_label(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, at} -> "Resets #{Calendar.strftime(at, "%b %-d %H:%M")} UTC"
      _ -> nil
    end
  end

  defp reset_label(_seconds), do: nil

  defp short_time(nil), do: "—"

  defp short_time(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M:%S")

  defp short_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> short_time(at)
      _ -> value
    end
  end

  defp short_time(value), do: to_string(value)

  defp short_date(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> Calendar.strftime(parsed, "%b %-d")
      _ -> date
    end
  end

  defp compact(value) when is_integer(value) and value >= 1_000_000_000, do: "#{Float.round(value / 1_000_000_000, 1)}B"
  defp compact(value) when is_integer(value) and value >= 1_000_000, do: "#{Float.round(value / 1_000_000, 1)}M"
  defp compact(value) when is_integer(value) and value >= 10_000, do: "#{Float.round(value / 1_000, 1)}K"
  defp compact(value) when is_integer(value), do: format_int(value)
  defp compact(_value), do: "n/a"

  # Axis values are micro-USD: whole dollars from $10 up, cents below.
  defp format_usd_axis(value) when value >= 10_000_000, do: "$#{round(value / 1_000_000)}"
  defp format_usd_axis(value), do: value |> round() |> format_usd()

  defp format_count(value), do: value |> round() |> Integer.to_string()

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
end
