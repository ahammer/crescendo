defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Charts, Endpoint, ObservabilityPubSub, Presenter, TranscriptComponents}
  @runtime_tick_ms 1_000
  @empty_workspace %{progress: %{done: 0, total: 0}, plan: [], plan_explanation: nil, files: [], latest_image: nil}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(selected: nil, reload_timer: nil)
      |> reload()

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, assign(socket, :selected, id)}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  # Codex streams many notifications a second; each viewer reloads at most once
  # per `dashboard_reload_ms`, and the first update after a quiet spell at once.
  def handle_info(:observability_updated, %{assigns: %{reload_timer: nil}} = socket) do
    wait = socket.assigns.loaded_at + reload_ms() - System.monotonic_time(:millisecond)

    if wait <= 0,
      do: {:noreply, reload(socket)},
      else: {:noreply, assign(socket, :reload_timer, Process.send_after(self(), :reload, wait))}
  end

  def handle_info(:observability_updated, socket), do: {:noreply, socket}

  def handle_info(:reload, socket), do: {:noreply, socket |> assign(:reload_timer, nil) |> reload()}

  defp reload(socket) do
    assign(socket, payload: load_payload(), now: DateTime.utc_now(), loaded_at: System.monotonic_time(:millisecond))
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :agent, selected_agent(assigns.payload, assigns.selected))

    ~H"""
    <section class="dashboard-shell">
      <header class="masthead">
        <div class="brand">
          <span class="brand-mark" aria-hidden="true"></span>
          <div>
            <h1 class="brand-title">Symphony</h1>
            <p class="brand-sub">AI Agent Operations Dashboard</p>
          </div>
        </div>
        <div class="stat-strip">
          <%= unless @payload[:error] do %>
            <.head_stat label="Repo" value={@payload.runtime.tracker || "—"} detail={if @payload.autopilot.enabled, do: "Autopilot on", else: "Autopilot off"} mono={true} />
            <.head_stat label="Updated" value={short_date_time(@payload.generated_at)} detail={"#{short_time(@payload.generated_at)} UTC"} />
          <% end %>
          <div class="head-stat head-live">
            <span class="status-badge status-badge-live"><span class="status-badge-dot"></span>Live</span>
            <span class="status-badge status-badge-offline"><span class="status-badge-dot"></span>Offline</span>
            <span :if={!@payload[:error]} class="head-detail"><%= agents_running(@payload.counts.running) %></span>
          </div>
          <%= unless @payload[:error] do %>
            <.head_stat
              label="Daily spend"
              value={if @payload.usage.status == "ok", do: format_usd(@payload.usage.today[:usd_micro]), else: "n/a"}
              detail={"#{format_usd(@payload.header.budget_usd_micro)} daily budget"}
              warn={over_budget?(@payload)}
            />
            <.head_stat label="Tokens today" value={compact(@payload.usage.today[:total_tokens])} detail={"#{@payload.header.runs_today} runs today"} />
            <.head_stat label="Runtime (longest)" value={longest_runtime(@payload.running, @now)} detail={longest_detail(@payload.running, @now)} />
            <.head_stat label="Active agents" value={"#{@payload.counts.running} / #{@payload.header.max_agents || "—"}"} detail={"#{@payload.counts.ready} queued"} />
          <% end %>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">Snapshot unavailable</h2>
          <p class="error-copy"><strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %></p>
        </section>
      <% else %>
        <section :if={over_budget?(@payload)} class="alert-banner" role="alert">
          <strong>Worker usage alert</strong>
          Estimated Symphony worker usage today (UTC) reached <%= format_usd(@payload.usage.today[:usd_micro]) %>, above the
          <%= format_usd(@payload.header.budget_usd_micro) %> daily budget. Planning and independent review usage are not included.
        </section>

        <div class="ops-grid">
          <div class="col col-left">
            <.queue_panel upcoming={@payload.upcoming} counts={@payload.counts} />
            <.pulls_panel :if={@payload.pull_requests.enabled} pulls={@payload.pull_requests} count={@payload.counts.open_prs} now={@now} />
            <.activity_panel usage={@payload.usage} now={@now} />
          </div>

          <div class="col col-center">
            <section class="kpis" aria-label="Summary">
              <.kpi label="Running" value={@payload.counts.running} detail="agents active" values={@payload.history.running} tone="green" />
              <.kpi label="Ready next" value={@payload.counts.ready} detail="queued for dispatch" values={@payload.history.ready} tone="blue" />
              <.kpi label="Waiting" value={@payload.counts.waiting} detail="held by labels, deps, CI" values={@payload.history.waiting} tone="violet" />
              <.kpi
                label="Needs attention"
                value={@payload.counts.blocked + @payload.counts.retrying}
                detail="blocked or retrying"
                title={"#{@payload.counts.blocked} blocked · #{@payload.counts.retrying} retrying"}
                values={@payload.history.attention}
                tone="red"
                warn={@payload.counts.blocked + @payload.counts.retrying > 0}
              />
              <.kpi label="Open PRs" value={@payload.counts.open_prs} detail="on GitHub" values={@payload.history.open_prs} tone="cyan" />
              <.kpi
                label="Spend today"
                value={if @payload.usage.status == "ok", do: format_usd(@payload.usage.today[:usd_micro]), else: "n/a"}
                detail={"#{format_usd(@payload.usage.recorded[:usd_micro])} recorded"}
                values={@payload.history.spend_micro}
                tone="gold"
                warn={over_budget?(@payload)}
              />
            </section>

            <section class="panel workspace" aria-labelledby="workspace-title">
              <header class="workspace-head">
                <span class="workspace-icon" aria-hidden="true"></span>
                <div>
                  <h2 id="workspace-title">Active Agent Workspace</h2>
                  <p class="panel-note">Live read-only view of Codex agents solving issues, writing code, and reviewing pull requests.</p>
                </div>
              </header>
              <%= if @payload.running == [] do %>
                <p class="empty-state">No active sessions. <%= idle_reason(@payload) %></p>
              <% else %>
                <nav class="agent-tabs" role="tablist" aria-label="Running agents">
                  <button
                    :for={entry <- @payload.running}
                    type="button"
                    role="tab"
                    aria-selected={to_string(entry.issue_identifier == @agent.issue_identifier)}
                    class={["agent-tab", entry.issue_identifier == @agent.issue_identifier && "is-selected"]}
                    phx-click="select_agent"
                    phx-value-id={entry.issue_identifier}
                  >
                    <span class={"tab-dot kind-dot-#{kind_name(entry)}"} aria-hidden="true"></span>
                    <span class="tab-id"><%= entry.issue_identifier %></span>
                    <span class="tab-state"><%= kind_label(kind_name(entry)) %></span>
                    <span class="tab-time numeric"><%= format_runtime_seconds(runtime_seconds_from_started_at(entry.started_at, @now)) %></span>
                  </button>
                </nav>
                <.agent_panel entry={@agent} now={@now} max_turns={@payload.runtime.max_turns} />
              <% end %>
            </section>

            <section class="charts-row">
              <article class="panel panel-chart">
                <header class="panel-head">
                  <h2 title="API-equivalent USD by model">Estimated spend <span class="count">14 days</span></h2>
                </header>
                <Charts.columns id="spend-chart" title="Estimated worker spend per day by model, last 14 days" series={spend_series(@payload.usage)} columns={spend_columns(@payload.usage)} format={&format_usd_axis/1} width={340} />
              </article>
              <article class="panel panel-chart">
                <header class="panel-head">
                  <h2>Worker runs <span class="count">14 days</span></h2>
                  <span class="panel-note"><%= merged_total(@payload.usage) %> merged</span>
                </header>
                <Charts.columns id="runs-chart" title="Worker runs per day by outcome, last 14 days" series={run_series()} columns={run_columns(@payload.usage)} format={&format_count/1} integer={true} width={340} />
              </article>
              <article class="panel panel-models">
                <header class="panel-head">
                  <h2 title={"Tokens by model; prices as of #{@payload.usage.pricing_as_of}"}>Model usage <span class="count">tokens</span></h2>
                </header>
                <p :if={@payload.usage.status != "ok"} class="error-copy">History unavailable<%= if @payload.usage_error do %>: <%= @payload.usage_error %><% end %>.</p>
                <%= if @payload.usage.by_model == [] do %>
                  <p class="empty-state">No recorded model usage yet.</p>
                <% else %>
                  <Charts.bars title="Tokens by model" rows={model_rows(@payload.usage)} />
                <% end %>
                <Charts.meter :for={meter <- rate_limit_meters(@payload.rate_limits)} label={meter.label} percent={meter.percent} detail={meter.detail} />
              </article>
            </section>
          </div>

          <div class="col col-right">
            <.health_panel title="Agent coordinator" group={@payload.health.coordinator} summary={coordinator_summary(@payload.health.coordinator.status)} />
            <.health_panel title="System health" group={@payload.health.system} summary={system_summary(@payload.health.system.status)} />
            <.run_stats_panel stats={@payload.run_stats} />
            <.autopilot_panel payload={@payload} now={@now} />
            <.attention_panel blocked={@payload.blocked} retrying={@payload.retrying} />
            <blockquote class="tagline">
              <p>Turning software ideas into working code, independently.</p>
              <footer>— Symphony</footer>
            </blockquote>
          </div>
        </div>
      <% end %>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:detail, :string, default: nil)
  attr(:mono, :boolean, default: false)
  attr(:warn, :boolean, default: false)

  defp head_stat(assigns) do
    ~H"""
    <div class={["head-stat", @warn && "head-warn"]}>
      <span class="head-label"><%= @label %></span>
      <span class={["head-value", @mono && "mono"]} title={to_string(@value)}><%= @value %></span>
      <span :if={@detail} class="head-detail"><%= @detail %></span>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:detail, :string, default: nil)
  attr(:values, :list, default: [])
  attr(:tone, :string, default: "blue")
  attr(:warn, :boolean, default: false)
  attr(:title, :string, default: nil)

  defp kpi(assigns) do
    ~H"""
    <article class={["kpi", "kpi-#{@tone}", @warn && "kpi-warn"]} title={@title}>
      <p class="kpi-label"><%= @label %></p>
      <div class="kpi-row">
        <p class="kpi-value"><%= @value %></p>
        <Charts.sparkline values={@values} title={"#{@label}, last 12 hours"} />
      </div>
      <p :if={@detail} class="kpi-detail"><%= @detail %></p>
    </article>
    """
  end

  attr(:upcoming, :map, required: true)
  attr(:counts, :map, required: true)

  defp queue_panel(assigns) do
    ~H"""
    <article class="panel panel-queue">
      <header class="panel-head">
        <h2>Work queue <span class="count"><%= @counts.ready %> ready · <%= @counts.waiting %> waiting</span></h2>
        <span class="panel-note mono" title="Last tracker read (UTC)"><%= short_time(@upcoming.observed_at) %></span>
      </header>
      <p :if={@upcoming.error} class="error-copy">Tracker data is stale: <%= @upcoming.error %></p>
      <%= if @upcoming.ready == [] and @upcoming.waiting == [] do %>
        <p class="empty-state">No upcoming work in the last poll.</p>
      <% else %>
        <div class="table-wrap">
          <table class="data-table">
            <thead>
              <tr><th>ID</th><th>Title</th><th title="Estimated from the median run time of similar work over the last 3 days">ETA</th><th>State</th></tr>
            </thead>
            <tbody>
              <tr :for={issue <- Enum.take(@upcoming.ready, 25)}>
                <td><.issue_identifier identifier={issue.issue_identifier} url={issue.issue_url} /></td>
                <td class="cell-title" title={issue.title}><%= issue.title %></td>
                <td class="numeric muted"><%= eta(issue[:eta_seconds]) %></td>
                <td class="cell-state"><span class="dot dot-good" aria-hidden="true"></span>Ready</td>
              </tr>
              <tr :for={issue <- Enum.take(@upcoming.waiting, 25)}>
                <td><.issue_identifier identifier={issue.issue_identifier} url={issue.issue_url} /></td>
                <td class="cell-title" title={issue.title}><%= issue.title %></td>
                <td class="numeric muted">—</td>
                <td class="cell-state" title={waiting_title(issue)}><span class="dot dot-warning" aria-hidden="true"></span><span class="state-text"><%= waiting_label(issue.reason) %></span></td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </article>
    """
  end

  attr(:pulls, :map, required: true)
  attr(:count, :integer, required: true)
  attr(:now, :any, required: true)

  defp pulls_panel(assigns) do
    ~H"""
    <article class="panel panel-prs">
      <header class="panel-head">
        <h2>Pull requests <span class="count"><%= @count %></span></h2>
        <span class="panel-note mono" title="Last GitHub sync (UTC)"><%= short_time(@pulls.observed_at) %></span>
      </header>
      <p :if={@pulls.error} class="error-copy">GitHub data is stale: <%= @pulls.error %></p>
      <%= if @pulls.items == [] do %>
        <p class="empty-state">No open pull requests.</p>
      <% else %>
        <div class="table-wrap">
          <table class="data-table">
            <thead><tr><th>#</th><th>Title</th><th>Updated</th><th>State</th></tr></thead>
            <tbody>
              <tr :for={pull <- recent_pulls(@pulls.items)}>
                <td><a class="issue-id issue-id-link" href={external_issue_url(pull.url)} target="_blank" rel="noopener noreferrer">#<%= pull.number %></a></td>
                <td class="cell-title" title={pull.title}><%= pull.title %></td>
                <td class="numeric muted" title={pull[:updated_at]}><%= compact_ago(pull[:updated_at], @now) %></td>
                <td class="cell-state"><span class={["ring", !pull.draft && "ring-open"]} aria-hidden="true"></span><%= if pull.draft, do: "Draft", else: "Open" %></td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </article>
    """
  end

  attr(:usage, :map, required: true)
  attr(:now, :any, required: true)

  defp activity_panel(assigns) do
    ~H"""
    <article class="panel panel-activity">
      <header class="panel-head">
        <h2>Recent activity</h2>
        <span class="panel-note">Newest first</span>
      </header>
      <%= if @usage.activity == [] do %>
        <p class="empty-state">No recorded activity yet.</p>
      <% else %>
        <div class="table-wrap">
          <table class="data-table">
            <thead><tr><th>Time</th><th>Event</th><th>Agent</th></tr></thead>
            <tbody>
              <tr :for={event <- activity(@usage)}>
                <td class="numeric muted"><time datetime={event.at} title={event.at}><%= compact_ago(event.at, @now) %></time></td>
                <td class="cell-title" title={Map.get(event, :summary)}>
                  <span class={"dot dot-#{event_tone(event.kind)}"} aria-hidden="true"></span><%= event_text(event) %>
                </td>
                <td>
                  <%= cond do %>
                    <% Map.get(event, :issue_identifier) -> %>
                      <.issue_identifier identifier={event.issue_identifier} url={Map.get(event, :issue_url)} />
                    <% Map.get(event, :pr_number) -> %>
                      <a class="issue-id issue-id-link" href={external_issue_url(Map.get(event, :pr_url))} target="_blank" rel="noopener noreferrer">PR-<%= event.pr_number %></a>
                    <% true -> %>
                      <span class="muted">—</span>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </article>
    """
  end

  attr(:title, :string, required: true)
  attr(:group, :map, required: true)
  attr(:summary, :map, required: true)

  defp health_panel(assigns) do
    ~H"""
    <article class="panel panel-health">
      <header class="panel-head"><h2><%= @title %></h2></header>
      <div class={"health-summary health-#{@group.status}"}>
        <span class={"dot dot-lg dot-#{status_tone(@group.status)}"} aria-hidden="true"></span>
        <div>
          <p class="health-title"><%= @summary.title %></p>
          <p class="health-copy"><%= @summary.copy %></p>
        </div>
      </div>
      <ul class="health-list">
        <li :for={check <- @group.checks} class="health-row" title={check.detail}>
          <span class={"dot dot-#{status_tone(check.status)}"} aria-hidden="true"></span>
          <span class="health-name"><%= check.name %></span>
          <span class={"health-state tone-#{status_tone(check.status)}"}><%= check_label(check.status) %></span>
          <span class="health-detail"><%= check.detail %></span>
        </li>
      </ul>
    </article>
    """
  end

  attr(:stats, :map, required: true)

  defp run_stats_panel(assigns) do
    ~H"""
    <article class="panel panel-stats">
      <header class="panel-head"><h2>Run statistics <span class="count">14 days</span></h2></header>
      <dl class="stat-table">
        <div><dt>Total runs</dt><dd class="numeric"><%= format_int(@stats.total) %></dd><dd></dd></div>
        <div><dt>Completed</dt><dd class="numeric"><%= format_int(@stats.completed) %></dd><dd class="muted numeric"><%= share(@stats.completed, @stats.total) %></dd></div>
        <div><dt>Interrupted</dt><dd class="numeric"><%= format_int(@stats.interrupted) %></dd><dd class="muted numeric"><%= share(@stats.interrupted, @stats.total) %></dd></div>
        <div><dt>Failed</dt><dd class="numeric"><%= format_int(@stats.failed) %></dd><dd class="muted numeric"><%= share(@stats.failed, @stats.total) %></dd></div>
        <div><dt>PRs merged</dt><dd class="numeric"><%= format_int(@stats.merged) %></dd><dd></dd></div>
      </dl>
    </article>
    """
  end

  attr(:payload, :map, required: true)
  attr(:now, :any, required: true)

  defp autopilot_panel(assigns) do
    ~H"""
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
            <span :if={channel_status_label(channel_status(@payload, channel))} class="step-state"><%= channel_status_label(channel_status(@payload, channel)) %></span>
          </li>
        </ol>
        <p class="panel-copy"><%= research_summary(@payload.autopilot, @now) %></p>
        <Charts.meter
          :if={Map.get(@payload.autopilot, :max_open_issues)}
          label={"Open issue backlog #{@payload.autopilot.open_issues}/#{@payload.autopilot.max_open_issues}"}
          percent={round(@payload.autopilot.open_issues * 100 / max(@payload.autopilot.max_open_issues, 1))}
          detail="Research pauses at the cap."
        />
      <% else %>
        <p class="empty-state">Autopilot is disabled in WORKFLOW.md.</p>
      <% end %>
    </article>
    """
  end

  attr(:blocked, :list, required: true)
  attr(:retrying, :list, required: true)

  defp attention_panel(assigns) do
    ~H"""
    <article class="panel panel-attention">
      <header class="panel-head"><h2>Needs attention <span class="count"><%= length(@blocked) + length(@retrying) %></span></h2></header>
      <%= if @blocked == [] and @retrying == [] do %>
        <p class="empty-state">Nothing blocked or retrying.</p>
      <% else %>
        <ul class="attention-list">
          <li :for={entry <- @blocked} class="attention-item">
            <span class="status-tag status-critical">Blocked</span>
            <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
            <span class="attention-text" title={"#{entry.error} · #{entry.last_message}"}><%= entry.error || "n/a" %><span :if={entry.last_message} class="muted"> · <%= entry.last_message %></span></span>
            <.copy_button :if={entry.session_id} value={entry.session_id} />
          </li>
          <li :for={entry <- @retrying} class="attention-item">
            <span class="status-tag status-warning">Retry <%= entry.attempt %></span>
            <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
            <span class="attention-text" title={entry.error}><%= entry.error || "n/a" %></span>
            <span class="mono muted"><%= short_time(entry.due_at) %></span>
          </li>
        </ul>
      <% end %>
    </article>
    """
  end

  attr(:entry, :map, required: true)
  attr(:now, :any, required: true)
  attr(:max_turns, :any, default: nil)

  defp agent_panel(assigns) do
    entry = assigns.entry
    run = get_in(entry, [:cost, :run]) || %{usd_micro: 0, unpriced_tokens: 0}
    item = get_in(entry, [:cost, :item]) || %{usd_micro: 0, runs: 0, since: nil}
    seconds = runtime_seconds_from_started_at(entry.started_at, assigns.now)
    kind = kind_name(entry)
    workspace = entry[:workspace] || @empty_workspace

    assigns =
      assign(assigns,
        kind: kind,
        run: run,
        item: item,
        seconds: seconds,
        labels: visible_labels(entry),
        events: Map.get(entry, :recent_events, []),
        detail: kind_detail(kind, entry),
        workspace: workspace,
        entries: entry |> Map.get(:transcript, []) |> Enum.take(-80),
        chat_id: "chat-" <> dom_id(entry.issue_identifier)
      )

    ~H"""
    <article class={"agent-panel agent-#{@kind}"}>
      <header class="agent-head">
        <div class="agent-main">
          <div class="agent-title-row">
            <span class={"kind-chip kind-#{@kind}"}><%= kind_label(@kind) %></span>
            <.issue_identifier identifier={@entry.issue_identifier} url={@entry.issue_url} />
            <span class={state_badge_class(@entry.state)}><%= @entry.state %></span>
            <span :if={(@entry[:item_attempt] || 1) > 1 or @entry[:final_attempt]} class={if @entry[:final_attempt], do: "status-tag status-critical", else: "status-tag status-warning"}>
              Attempt <%= @entry[:item_attempt] || 1 %><%= if @entry[:final_attempt], do: " · final" %>
            </span>
          </div>
          <h3 class="agent-title" title={@entry[:title]}><%= @entry[:title] || @entry.issue_identifier %></h3>
          <p :if={@entry[:description]} class="agent-desc"><%= @entry.description %></p>
          <p :if={@detail} class="agent-detail"><%= @detail %></p>
          <ul :if={@labels != []} class="label-list">
            <li :for={label <- @labels} class="label-chip"><%= label %></li>
          </ul>
        </div>
        <div class="agent-side">
          <dl class="chip-row">
            <div class="chip-stat"><dt>Model</dt><dd class="mono"><%= route_model(@entry) %></dd></div>
            <div class="chip-stat"><dt>Runtime</dt><dd class="numeric"><%= format_runtime_seconds(@seconds) %></dd></div>
            <div class="chip-stat"><dt>Tokens</dt><dd class="numeric"><%= compact(@entry.tokens.total_tokens) %></dd></div>
            <div class="chip-stat"><dt>Cost</dt><dd class="numeric"><%= format_money(@run.usd_micro) %><span :if={@run.unpriced_tokens > 0} class="muted"> partly unpriced</span></dd></div>
          </dl>
          <dl class="fact-list">
            <div :if={@entry[:branch]}><dt>Branch</dt><dd class="mono" title={@entry.branch}><%= @entry.branch %></dd></div>
            <div><dt>Route</dt><dd><%= route_detail(@entry) %></dd></div>
            <div><dt>Item total</dt><dd><%= format_money(@item.usd_micro) %> · <%= item_runs(@item) %></dd></div>
            <div><dt>Tokens</dt><dd>in <%= compact(@entry.tokens.input_tokens) %> · cached <%= compact(@entry.tokens[:cached_input_tokens] || 0) %> · out <%= compact(@entry.tokens.output_tokens) %></dd></div>
            <div><dt>Rate</dt><dd><%= spend_rate(@run.usd_micro, @seconds) %> · <%= token_rate(@entry, @now) %></dd></div>
            <div :if={@max_turns}><dt>Turns</dt><dd><%= @entry.turn_count %><span class="muted">/<%= @max_turns %></span></dd></div>
            <div class="fact-progress">
              <dt>Progress</dt>
              <dd>
                <span class="progress-track" role="progressbar" aria-valuemin="0" aria-valuemax={@workspace.progress.total} aria-valuenow={@workspace.progress.done}>
                  <span class="progress-fill" style={"width: #{share_percent(@workspace.progress.done, @workspace.progress.total)}%"}></span>
                </span>
                <span class="numeric"><%= progress_text(@workspace.progress) %></span>
              </dd>
            </div>
          </dl>
        </div>
      </header>

      <div class="agent-body">
        <aside class="agent-rail">
          <section class="rail-block">
            <h4>Plan <span class="count"><%= progress_text(@workspace.progress) %></span></h4>
            <%= if @workspace.plan == [] do %>
              <p class="empty-state">The agent has not shared a plan yet.</p>
            <% else %>
              <TranscriptComponents.plan_checklist steps={@workspace.plan} explanation={@workspace.plan_explanation} />
            <% end %>
          </section>
          <section :if={@workspace.files != []} class="rail-block">
            <h4>Files changed <span class="count"><%= length(@workspace.files) %></span></h4>
            <TranscriptComponents.files_changed files={@workspace.files} />
          </section>
          <section :if={@workspace.latest_image} class="rail-block">
            <h4>Latest image</h4>
            <a class="shot shot-rail" href={@workspace.latest_image.src} target="_blank" rel="noopener" title="Open full size">
              <img src={@workspace.latest_image.src} alt="Latest image from this run" />
            </a>
          </section>
        </aside>

        <div class="agent-chat">
          <%= if @entries == [] do %>
            <section class="chat chat-fallback" aria-label="Recent Codex activity">
              <p class="agent-label">Codex update</p>
              <%= if @entry.last_message || @entry.last_event do %>
                <p class="agent-message" title={@entry.last_message || to_string(@entry.last_event)}><%= @entry.last_message || to_string(@entry.last_event) %></p>
              <% else %>
                <p class="agent-message muted">Waiting for the first Codex event…</p>
              <% end %>
              <ol :if={length(@events) > 1} class="agent-events">
                <li :for={event <- tl(@events)}>
                  <time class="muted numeric" datetime={event.at} title={event.at}><%= ago(event.at, @now) %></time>
                  <span class="agent-event-text" title={event.text}><%= event.text %></span>
                </li>
              </ol>
            </section>
          <% else %>
            <TranscriptComponents.transcript id={@chat_id} entries={@entries} now={@now} />
          <% end %>
        </div>
      </div>

      <footer class="agent-foot">
        <span class="agent-label">Codex update</span>
        <span class="agent-latest" title={@entry.last_message}><%= @entry.last_message || @entry.last_event || "waiting" %></span>
        <span :if={@entry.last_event_at} class="muted" title={@entry.last_event_at}><%= ago(@entry.last_event_at, @now) %></span>
        <span class="agent-spacer"></span>
        <span class="mono muted workspace-path" title={@entry[:workspace_path]}><%= short_path(@entry[:workspace_path]) %><%= if @entry[:worker_host], do: " @ #{@entry.worker_host}" %></span>
        <.copy_button :if={@entry.session_id} value={@entry.session_id} />
        <a class="issue-link" href={"/api/v1/#{@entry.issue_identifier}"}>JSON</a>
      </footer>
    </article>
    """
  end

  # The selected tab survives updates while its agent runs; otherwise the first agent shows.
  defp selected_agent(%{running: [first | _] = running}, selected) do
    Enum.find(running, first, &(&1.issue_identifier == selected))
  end

  defp selected_agent(_payload, _selected), do: nil

  defp dom_id(identifier), do: identifier |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "-")

  defp over_budget?(%{usage: %{status: "ok", today: today}, header: %{budget_usd_micro: budget}}), do: (today[:usd_micro] || 0) >= budget
  defp over_budget?(_payload), do: false

  defp agents_running(1), do: "1 agent running"
  defp agents_running(count), do: "#{count} agents running"

  defp longest(running, now), do: Enum.max_by(running, &runtime_seconds_from_started_at(&1.started_at, now), fn -> nil end)

  defp longest_runtime(running, now) do
    case longest(running, now) do
      nil -> "—"
      entry -> format_runtime_seconds(runtime_seconds_from_started_at(entry.started_at, now))
    end
  end

  defp longest_detail(running, now) do
    case longest(running, now) do
      nil -> "no agent running"
      entry -> "#{entry.issue_identifier} (#{route_model(entry)})"
    end
  end

  defp eta(seconds) when is_integer(seconds) and seconds >= 3_600, do: "~#{div(seconds, 3_600)}h #{rem(div(seconds, 60), 60)}m"
  defp eta(seconds) when is_integer(seconds), do: "~#{max(div(seconds, 60), 1)}m"
  defp eta(_seconds), do: "—"

  # Short state names keep the title column readable; the full reason is the tooltip.
  defp waiting_label(reason) when reason in ["dependency blocked", "operator blocked"], do: "Blocked"
  defp waiting_label("retry scheduled"), do: "Retrying"
  defp waiting_label("draft"), do: "Draft"
  defp waiting_label("continuation pending"), do: "Continuing"
  defp waiting_label("awaiting maintainer label"), do: "Untrusted"
  defp waiting_label("excluded by " <> _label), do: "Excluded"
  defp waiting_label(_reason), do: "Waiting"

  defp waiting_title(%{reason: reason, blocked_by: [_ | _] = blocked_by}), do: "#{reason}: #{Enum.join(blocked_by, ", ")}"
  defp waiting_title(%{reason: reason}), do: reason

  defp recent_pulls(items) do
    items
    |> Enum.sort_by(&to_string(&1[:updated_at]), :desc)
    |> Enum.take(100)
  end

  defp event_text(event) do
    subject =
      cond do
        Map.get(event, :pr_number) -> "PR ##{event.pr_number}"
        Map.get(event, :issue_identifier) -> event.issue_identifier
        true -> nil
      end

    [subject, event_phrase(event.kind)] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp event_phrase("dispatch"), do: "dispatched"
  defp event_phrase("attempt_failed"), do: "attempt failed"
  defp event_phrase("retry_scheduled"), do: "re-queued"
  defp event_phrase("issue_terminal"), do: "closed"
  defp event_phrase("model_rerouted"), do: "rerouted"
  defp event_phrase("pr_opened"), do: "opened"
  defp event_phrase("pr_merged"), do: "merged"
  defp event_phrase("pr_closed"), do: "closed"
  defp event_phrase("pr_drafted"), do: "moved to draft"
  defp event_phrase("pr_ready_for_review"), do: "ready for review"
  defp event_phrase("pr_left_open_list"), do: "left the open list"
  defp event_phrase(kind), do: String.replace(to_string(kind), "_", " ")

  defp status_tone(status) when status in ["healthy", "operational"], do: "good"
  defp status_tone(status) when status in ["warning", "degraded"], do: "warning"
  defp status_tone(status) when status in ["critical", "down"], do: "critical"
  defp status_tone(_status), do: "neutral"

  defp check_label("healthy"), do: "Healthy"
  defp check_label("warning"), do: "Warning"
  defp check_label("critical"), do: "Failing"
  defp check_label(_status), do: "Idle"

  defp coordinator_summary("operational"), do: %{title: "Operational", copy: "Sequencing work, resolving dependencies, and handing tasks to free agents."}
  defp coordinator_summary("degraded"), do: %{title: "Degraded", copy: "Work is flowing, but some items are blocked or retrying."}
  defp coordinator_summary(_status), do: %{title: "Down", copy: "The coordinator cannot make progress; see the checks below."}

  defp system_summary("operational"), do: %{title: "All systems healthy", copy: "Tracker, GitHub, models, history and disk look normal."}
  defp system_summary("degraded"), do: %{title: "Degraded", copy: "A dependency needs a look; see the checks below."}
  defp system_summary(_status), do: %{title: "Outage", copy: "A dependency is failing; see the checks below."}

  defp share(_part, total) when total in [0, nil], do: ""
  defp share(part, total), do: "#{round(part * 100 / total)}%"

  defp share_percent(_part, total) when total in [0, nil], do: 0
  defp share_percent(part, total), do: min(round(part * 100 / total), 100)

  defp progress_text(%{total: 0}), do: "no plan yet"
  defp progress_text(%{done: done, total: total}), do: "#{done}/#{total} steps"

  defp kind_name(%{kind: kind}) when kind in [:pull_request, "pull_request"], do: "pr"
  defp kind_name(%{kind: kind}) when kind in [:research, "research"], do: "research"
  defp kind_name(%{issue_identifier: identifier}), do: work_kind(identifier)

  defp kind_detail("pr", %{pull_request: %{} = pr}) do
    sha = pr |> Map.get(:head_sha, "") |> to_string() |> String.slice(0, 7)

    [
      pr[:author] && "by #{pr.author}#{if pr[:author_association], do: " (#{String.downcase(pr.author_association)})"}",
      pr[:head_ref] && "#{pr.head_ref}@#{sha}",
      pr[:ci_state] && "CI #{pr.ci_state}",
      pr[:can_push] == false && "comment-only (cannot push)"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp kind_detail("research", %{research: %{} = research}),
    do: "Channel #{research[:channel]} · #{research[:focus]}"

  defp kind_detail(_kind, _entry), do: nil

  # Scheduling labels are shown elsewhere (route, channel); the rest describe the work.
  defp visible_labels(entry) do
    entry
    |> Map.get(:labels, [])
    |> Enum.reject(&(String.starts_with?(&1, "symphony:") or &1 == "symphony"))
    |> Enum.take(8)
  end

  defp route_model(%{route: %{model: model}}) when is_binary(model), do: model
  defp route_model(entry), do: entry[:model] || "pending"

  defp route_detail(%{route: %{} = route}) do
    [route[:effort] && "#{route.effort} effort", route[:tier] && "tier #{route.tier}", route[:label] && "via #{route.label}"]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp route_detail(_entry), do: "route pending"

  defp format_money(micro) when is_integer(micro) and micro >= 1_000_000, do: format_usd(micro)
  defp format_money(micro) when is_integer(micro), do: "$" <> :erlang.float_to_binary(micro / 1_000_000, decimals: 3)
  defp format_money(_micro), do: "n/a"

  defp spend_rate(micro, seconds) when is_integer(micro) and micro > 0 and seconds >= 60,
    do: "#{format_money(round(micro * 3_600 / seconds))}/h"

  defp spend_rate(_micro, _seconds), do: "rate pending"

  defp item_runs(%{runs: runs, since: since}) when is_integer(runs) and runs > 0,
    do: "#{runs} run#{if runs == 1, do: "", else: "s"} since #{since}"

  defp item_runs(_item), do: "first run"

  defp short_path(nil), do: "workspace pending"

  defp short_path(path) do
    path |> Path.split() |> Enum.take(-2) |> Path.join()
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
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms(), transcripts: true)
  end

  defp reload_ms do
    Endpoint.config(:dashboard_reload_ms) || 1_000
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

  defp activity(usage) do
    usage.activity
    |> Enum.reject(&(&1.kind == "turn_completed"))
    |> Enum.take(60)
  end

  defp token_rate(entry, now) do
    minutes = runtime_seconds_from_started_at(entry.started_at, now) / 60

    case entry.tokens.total_tokens do
      total when is_integer(total) and total > 0 and minutes >= 1 -> "#{compact(round(total / minutes))}/min"
      _ -> "rate pending"
    end
  end

  defp ago(value, now) do
    case parse_time(value) do
      nil -> "—"
      at -> relative(DateTime.diff(now, at, :second), "ago")
    end
  end

  defp compact_ago(value, now) do
    case parse_time(value) do
      nil ->
        "—"

      at ->
        seconds = max(DateTime.diff(now, at, :second), 0)

        cond do
          seconds < 60 -> "now"
          seconds < 3_600 -> "#{div(seconds, 60)}m ago"
          seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
          true -> "#{div(seconds, 86_400)}d ago"
        end
    end
  end

  defp until(value, now) do
    case parse_time(value) do
      nil -> "soon"
      at -> if DateTime.compare(at, now) == :gt, do: "in " <> relative(DateTime.diff(at, now, :second), ""), else: "is due"
    end
  end

  defp relative(seconds, suffix) do
    text =
      cond do
        seconds < 60 -> "#{max(seconds, 0)}s"
        seconds < 3_600 -> "#{div(seconds, 60)}m"
        seconds < 86_400 -> "#{div(seconds, 3_600)}h #{rem(div(seconds, 60), 60)}m"
        true -> "#{div(seconds, 86_400)}d"
      end

    String.trim("#{text} #{suffix}")
  end

  defp parse_time(%DateTime{} = at), do: at

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp parse_time(_value), do: nil

  defp work_kind("PR-" <> _), do: "pr"
  defp work_kind("research-" <> _), do: "research"
  defp work_kind(_identifier), do: "issue"

  defp kind_label("pr"), do: "Review"
  defp kind_label("research"), do: "Research"
  defp kind_label(_kind), do: "Issue"

  defp idle_reason(%{autopilot: %{enabled: true} = autopilot}), do: research_summary(autopilot, DateTime.utc_now())
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
  defp channel_status_label(_status), do: nil

  defp research_summary(autopilot, now) do
    cond do
      Map.get(autopilot, :research_running, 0) > 0 -> "A planner has the machine to itself; other work waits for it."
      Map.get(autopilot, :research_pending, []) != [] -> "Round in progress; resumes when the queue is idle."
      next = Map.get(autopilot, :next_research_at) -> "Next research round #{until(next, now)}, once the queue is empty."
      true -> "Research starts when the queue is empty."
    end
  end

  defp event_tone(kind) when kind in ["completed", "pr_merged", "pr_ready_for_review"], do: "good"
  defp event_tone(kind) when kind in ["failed", "blocked", "attempt_failed", "retired"], do: "critical"
  defp event_tone(kind) when kind in ["retry_scheduled", "interrupted", "stopped", "pr_closed", "model_rerouted"], do: "warning"
  defp event_tone(kind) when kind in ["dispatch", "pr_opened"], do: "info"
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

      %{
        label: row.model,
        value: row.total_tokens,
        display: "#{compact(row.total_tokens)} · #{row.runs} runs",
        title: "#{compact(row.total_tokens)} tokens · #{price} · #{row.runs} runs",
        class: classes[row.model]
      }
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

  defp short_date_time(value) do
    case parse_time(value) do
      nil -> "—"
      at -> Calendar.strftime(at, "%b %-d, %Y")
    end
  end

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
