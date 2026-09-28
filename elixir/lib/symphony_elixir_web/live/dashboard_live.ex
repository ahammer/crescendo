defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Crescendo. Stats and charts sit at the top;
  the work queue, pull requests and activity fill the space above a strip of
  fixed worker slots at the bottom, where each running agent's card opens the
  full-screen agent inspector. Phones show one section at a time and stack the
  cards.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  import SymphonyElixirWeb.DashboardComponents

  alias SymphonyElixirWeb.{Charts, Endpoint, LiveRefresh, Presenter, TranscriptComponents}

  @sections [{"queue", "Queue"}, {"prs", "PRs"}, {"activity", "Activity"}, {"stats", "Stats"}]

  @impl true
  def mount(params, _session, socket) do
    project = params["project"]
    {:ok, socket |> assign(section: "queue", project: project) |> LiveRefresh.start(fn -> load_payload(project) end)}
  end

  # The project filter lives in the URL (`?project=`), so views can be shared.
  @impl true
  def handle_params(params, _uri, socket) do
    case params["project"] do
      project when project == socket.assigns.project -> {:noreply, socket}
      project -> {:noreply, socket |> assign(:project, project) |> LiveRefresh.replace(fn -> load_payload(project) end)}
    end
  end

  @impl true
  def handle_event("section", %{"id" => section}, socket) do
    {:noreply, assign(socket, :section, section)}
  end

  @impl true
  def handle_info(message, socket), do: {:noreply, LiveRefresh.handle_info(message, socket)}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :sections, @sections)

    ~H"""
    <section class="dash">
      <header class="masthead">
        <div class="brand">
          <span class="brand-mark" aria-hidden="true"></span>
          <div class="brand-text">
            <h1 class="brand-title">Crescendo</h1>
            <p class="brand-sub"><%= brand_line(@payload) %></p>
          </div>
          <.live_badge />
        </div>
        <nav :if={length(@payload[:projects] || []) > 1} class="project-filter" aria-label="Projects">
          <.link patch="/" class={["project-pill", is_nil(@payload[:project]) && "is-active"]}>All</.link>
          <.link
            :for={project <- @payload.projects}
            patch={"/?project=#{project.id}"}
            class={["project-pill", @payload[:project] == project.id && "is-active", project.failure && "is-failed"]}
            title={project.failure || "#{project.running} running · #{project.ready} ready"}
          ><%= project.id %><span :if={project.running > 0} class="tab-count"><%= project.running %></span></.link>
        </nav>
        <div :if={!@payload[:error]} class="stats">
          <.stat
            label="Agents"
            value={"#{@payload.counts.running}/#{@payload.header.max_agents || "—"}"}
            detail={longest_detail(@payload.running, @now)}
            values={@payload.history.running}
            tone="green"
          />
          <.stat label="Queue" value={@payload.counts.ready} detail={"#{@payload.counts.waiting} waiting"} values={@payload.history.ready} tone="blue" />
          <.stat label="Open PRs" value={@payload.counts.open_prs} detail="on GitHub" values={@payload.history.open_prs} tone="cyan" />
          <.stat
            label="PRs closed today"
            value={today(@payload.usage, :merged) + today(@payload.usage, :closed)}
            detail={"#{today(@payload.usage, :merged)} merged · #{today(@payload.usage, :closed)} closed"}
            values={closed_per_day(@payload.usage)}
            tone="violet"
            title="Pull requests merged or closed today (UTC); the sparkline covers 14 days"
          />
          <.stat
            label="Spend today"
            value={if @payload.usage.status == "ok", do: format_usd(@payload.usage.today[:usd_micro]), else: "n/a"}
            detail={budget_detail(@payload)}
            values={@payload.history.spend_micro}
            tone="gold"
            warn={over_budget?(@payload)}
            title={budget_title(@payload)}
          />
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">Snapshot unavailable</h2>
          <p class="error-copy"><strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %></p>
        </section>
      <% else %>
        <nav class="section-tabs" role="tablist" aria-label="Sections">
          <button
            :for={{id, label} <- @sections}
            type="button"
            role="tab"
            aria-selected={to_string(@section == id)}
            class={["section-tab", @section == id && "is-active"]}
            phx-click="section"
            phx-value-id={id}
          ><%= label %><span :if={section_count(@payload, id)} class="tab-count"><%= section_count(@payload, id) %></span></button>
        </nav>

        <div class={["charts", @section == "stats" && "is-active"]}>
          <.health_panel payload={@payload} now={@now} />
          <.runs_panel stats={@payload.run_stats} usage={@payload.usage} />
          <.spend_panel usage={@payload.usage} usage_error={@payload.usage_error} />
          <.models_panel usage={@payload.usage} quota={@payload.quota} throttle={@payload[:throttle]} now={@now} />
        </div>

        <div class="lists">
          <.queue_section upcoming={@payload.upcoming} counts={@payload.counts} active={@section == "queue"} mixed={mixed?(@payload)} />
          <.pulls_section
            :if={@payload.pull_requests.enabled}
            pulls={@payload.pull_requests}
            count={@payload.counts.open_prs}
            now={@now}
            active={@section == "prs"}
            mixed={mixed?(@payload)}
          />
          <.activity_section usage={@payload.usage} now={@now} active={@section == "activity"} mixed={mixed?(@payload)} />
        </div>

        <section class="dock" aria-labelledby="dock-title">
          <header class="dock-head">
            <h2 id="dock-title">Agents</h2>
            <span class="count"><%= @payload.counts.running %>/<%= @payload.header.max_agents || "—" %> running</span>
            <.attention blocked={@payload.blocked} retrying={@payload.retrying} now={@now} />
          </header>
          <div class="dock-slots">
            <.agent_card :for={entry <- @payload.running} entry={entry} now={@now} mixed={mixed?(@payload)} />
            <.free_slot :for={next <- free_slots(@payload)} next={next} idle={idle_reason(@payload, @now)} />
          </div>
        </section>
      <% end %>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:detail, :string, default: nil)
  attr(:values, :list, default: [])
  attr(:tone, :string, default: "blue")
  attr(:warn, :boolean, default: false)
  attr(:title, :string, default: nil)

  defp stat(assigns) do
    ~H"""
    <article class={["stat", "stat-#{@tone}", @warn && "stat-warn"]} title={@title}>
      <p class="stat-label"><%= @label %></p>
      <div class="stat-row">
        <p class="stat-value"><%= @value %></p>
        <Charts.sparkline values={@values} title={"#{@label}, last 12 hours"} />
      </div>
      <p :if={@detail} class="stat-detail"><%= @detail %></p>
    </article>
    """
  end

  attr(:entry, :map, required: true)
  attr(:now, :any, required: true)
  attr(:mixed, :boolean, default: false)

  # A whole card is the way into the inspector, so it holds no other links.
  defp agent_card(assigns) do
    entry = assigns.entry
    workspace = entry.workspace
    kind = kind_name(entry)

    assigns =
      assign(assigns,
        kind: kind,
        workspace: workspace,
        run: get_in(entry, [:cost, :run]) || %{usd_micro: 0},
        added: workspace.files |> Enum.map(&(&1[:additions] || 0)) |> Enum.sum(),
        removed: workspace.files |> Enum.map(&(&1[:deletions] || 0)) |> Enum.sum(),
        quote: if(match?(%{kind: "message"}, workspace.now), do: nil, else: workspace.said)
      )

    ~H"""
    <.link navigate={agent_path(@entry)} class={"agent-card agent-#{@kind}"} aria-label={"Inspect #{@entry.issue_identifier}"}>
      <div class="card-top">
        <span class={"kind-chip kind-#{@kind}"}><%= kind_label(@kind) %></span>
        <.project_chip :if={@mixed} project={@entry[:project]} />
        <span class="card-id"><%= @entry.issue_identifier %></span>
        <span :if={(@entry[:item_attempt] || 1) > 1 or @entry[:final_attempt]} class={if @entry[:final_attempt], do: "status-tag status-critical", else: "status-tag status-warning"}>
          Attempt <%= @entry[:item_attempt] || 1 %><%= if @entry[:final_attempt], do: " · final" %>
        </span>
        <span class="card-runtime numeric"><%= format_runtime(runtime_seconds(@entry.started_at, @now)) %></span>
      </div>
      <div class="card-body">
        <div class="card-main">
          <h3 class="card-title"><%= @entry[:title] || @entry.issue_identifier %></h3>
          <.progress progress={@workspace.progress} />
          <p class="card-now"><TranscriptComponents.status_line entry={@workspace.now} fallback={@entry.last_message} /></p>
          <p :if={@quote} class="card-said">“<%= @quote %>”</p>
        </div>
        <img :if={@workspace.latest_image} class="card-thumb" src={@workspace.latest_image.src} alt="Latest image from this run" />
      </div>
      <div class="card-foot">
        <span class="mono"><%= route_model(@entry) %></span>
        <span><%= compact(@entry.tokens.total_tokens) %> tok</span>
        <span><%= format_money(@run.usd_micro) %></span>
        <span :if={@workspace.files != []}><span class="diff-add">+<%= @added %></span> <span class="diff-del">−<%= @removed %></span></span>
        <span :if={@workspace.images > 0}>▣ <%= @workspace.images %></span>
        <span class="card-open" aria-hidden="true">Inspect ›</span>
      </div>
    </.link>
    """
  end

  attr(:blocked, :list, required: true)
  attr(:retrying, :list, required: true)
  attr(:now, :any, required: true)

  # Waiting runs as chips beside the slots; the reason is the tooltip.
  defp attention(assigns) do
    ~H"""
    <ul :if={@blocked != [] or @retrying != []} class="attention" aria-label="Needs attention">
      <li :for={entry <- @blocked} class="attention-chip chip-critical" title={Enum.join(Enum.reject([entry.error, entry.last_message], &is_nil/1), " · ")}>
        Blocked <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
      </li>
      <li :for={entry <- @retrying} class="attention-chip chip-warning" title={entry.error}>
        Retry <%= entry.attempt %> <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} /> <span class="muted numeric"><%= until(entry.due_at, @now) %></span>
      </li>
    </ul>
    """
  end

  attr(:next, :map, default: nil)
  attr(:idle, :string, required: true)

  # An empty worker slot keeps the strip's size and says what comes next.
  defp free_slot(assigns) do
    ~H"""
    <div class="free-slot">
      <p class="free-title">Free slot</p>
      <%= if @next do %>
        <p class="free-next">Next up <.issue_identifier identifier={@next.issue_identifier} url={@next.issue_url} /></p>
        <p class="free-next-title"><%= @next.title %></p>
      <% else %>
        <p class="free-next"><%= @idle %></p>
      <% end %>
    </div>
    """
  end

  attr(:upcoming, :map, required: true)
  attr(:counts, :map, required: true)
  attr(:active, :boolean, default: false)
  attr(:mixed, :boolean, default: false)

  defp queue_section(assigns) do
    ~H"""
    <section class={["sec", @active && "is-active"]} aria-labelledby="queue-title">
      <header class="section-head">
        <h2 id="queue-title">Work queue</h2>
        <span class="count"><%= @counts.ready %> ready · <%= @counts.waiting %> waiting</span>
      </header>
      <p :if={@upcoming.error} class="error-copy">Tracker data is stale: <%= @upcoming.error %></p>
      <%= if @upcoming.ready == [] and @upcoming.waiting == [] do %>
        <p class="empty-state">No upcoming work in the last poll.</p>
      <% else %>
        <ul class="rows">
          <li :for={issue <- Enum.take(@upcoming.ready, 25)} class="row">
            <.issue_identifier identifier={issue.issue_identifier} url={issue.issue_url} />
            <span class="row-title" title={issue.title}><.project_chip :if={@mixed} project={issue[:project]} /><%= issue.title %></span>
            <span class="row-meta numeric" title="Estimated from recent run times of similar work"><%= eta(issue[:eta_seconds]) %></span>
            <span class="row-state"><span class="dot dot-good" aria-hidden="true"></span>Ready</span>
          </li>
          <li :for={issue <- Enum.take(@upcoming.waiting, 25)} class="row row-waiting">
            <.issue_identifier identifier={issue.issue_identifier} url={issue.issue_url} />
            <span class="row-title" title={issue.title}><.project_chip :if={@mixed} project={issue[:project]} /><%= issue.title %></span>
            <span class="row-meta">—</span>
            <span class="row-state" title={waiting_title(issue)}><span class="dot dot-warning" aria-hidden="true"></span><%= waiting_label(issue.reason) %></span>
          </li>
        </ul>
      <% end %>
    </section>
    """
  end

  attr(:pulls, :map, required: true)
  attr(:count, :integer, required: true)
  attr(:now, :any, required: true)
  attr(:active, :boolean, default: false)
  attr(:mixed, :boolean, default: false)

  defp pulls_section(assigns) do
    ~H"""
    <section class={["sec", @active && "is-active"]} aria-labelledby="prs-title">
      <header class="section-head">
        <h2 id="prs-title">Pull requests</h2>
        <span class="count"><%= @count %> open</span>
      </header>
      <p :if={@pulls.error} class="error-copy">GitHub data is stale: <%= @pulls.error %></p>
      <%= if @pulls.items == [] do %>
        <p class="empty-state">No open pull requests.</p>
      <% else %>
        <ul class="rows">
          <li :for={pull <- recent_pulls(@pulls.items)} class="row">
            <a class="issue-id issue-id-link" href={external_url(pull.url)} target="_blank" rel="noopener noreferrer">#<%= pull.number %></a>
            <span class="row-title" title={pull.title}><.project_chip :if={@mixed} project={pull[:project]} /><%= pull.title %></span>
            <span class="row-meta numeric" title={pull[:updated_at]}><%= compact_ago(pull[:updated_at], @now) %></span>
            <span class="row-state"><span class={["ring", !pull.draft && "ring-open"]} aria-hidden="true"></span><%= if pull.draft, do: "Draft", else: "Open" %></span>
          </li>
        </ul>
      <% end %>
    </section>
    """
  end

  attr(:usage, :map, required: true)
  attr(:now, :any, required: true)
  attr(:active, :boolean, default: false)
  attr(:mixed, :boolean, default: false)

  defp activity_section(assigns) do
    ~H"""
    <section class={["sec", @active && "is-active"]} aria-labelledby="activity-title">
      <header class="section-head">
        <h2 id="activity-title">Recent activity</h2>
      </header>
      <%= if @usage.activity == [] do %>
        <p class="empty-state">No recorded activity yet.</p>
      <% else %>
        <ul class="rows">
          <li :for={event <- activity(@usage)} class="row row-event">
            <time class="row-meta numeric" datetime={event.at} title={event.at}><%= compact_ago(event.at, @now) %></time>
            <span class="row-title" title={Map.get(event, :summary)}>
              <span class={"dot dot-#{event_tone(event.kind)}"} aria-hidden="true"></span><.project_chip :if={@mixed} project={event[:project]} /><%= event_text(event) %>
            </span>
            <%= cond do %>
              <% Map.get(event, :issue_identifier) -> %>
                <.issue_identifier identifier={event.issue_identifier} url={Map.get(event, :issue_url)} />
              <% Map.get(event, :pr_number) -> %>
                <a class="issue-id issue-id-link" href={external_url(Map.get(event, :pr_url))} target="_blank" rel="noopener noreferrer">PR-<%= event.pr_number %></a>
              <% true -> %>
                <span class="muted">—</span>
            <% end %>
          </li>
        </ul>
      <% end %>
    </section>
    """
  end

  attr(:payload, :map, required: true)
  attr(:now, :any, required: true)

  defp health_panel(assigns) do
    health = assigns.payload.health
    checks = health.coordinator.checks ++ health.system.checks
    assigns = assign(assigns, health: health, checks: checks, problems: Enum.reject(checks, &(&1.status in ["healthy", "idle"])))

    ~H"""
    <section class="panel" aria-labelledby="system-title">
      <header class="section-head"><h2 id="system-title">System</h2></header>
      <div class="health-lines">
        <p class="health-line">
          <span class={"dot dot-#{status_tone(@health.coordinator.status)}"} aria-hidden="true"></span>Coordinator
          <strong><%= status_label(@health.coordinator.status) %></strong>
        </p>
        <p class="health-line">
          <span class={"dot dot-#{status_tone(@health.system.status)}"} aria-hidden="true"></span>Systems
          <strong><%= if @health.system.status == "operational", do: "All healthy", else: status_label(@health.system.status) %></strong>
        </p>
      </div>
      <ul :if={@problems != []} class="health-problems">
        <li :for={check <- @problems}><span class={"dot dot-#{status_tone(check.status)}"} aria-hidden="true"></span><strong><%= check.name %></strong> <%= check.detail %></li>
      </ul>
      <details class="checks">
        <summary>All checks (<%= length(@checks) %>)</summary>
        <ul class="health-list">
          <li :for={check <- @checks} class="health-row">
            <span class={"dot dot-#{status_tone(check.status)}"} aria-hidden="true"></span>
            <span class="health-name"><%= check.name %></span>
            <span class="health-detail"><%= check.detail %></span>
          </li>
        </ul>
      </details>
      <div :if={@payload.autopilot.enabled} class="sys-block">
        <h3>Autopilot</h3>
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
      </div>
    </section>
    """
  end

  attr(:stats, :map, required: true)
  attr(:usage, :map, required: true)

  defp runs_panel(assigns) do
    ~H"""
    <section class="panel" aria-labelledby="runs-title">
      <header class="section-head"><h2 id="runs-title">Runs <span class="count">14 days</span></h2></header>
      <dl class="run-stats">
        <div><dt>Runs</dt><dd class="numeric"><%= format_int(@stats.total) %></dd></div>
        <div><dt>Completed</dt><dd class="numeric"><%= share(@stats.completed, @stats.total) %></dd></div>
        <div><dt>Interrupted</dt><dd class="numeric"><%= share(@stats.interrupted, @stats.total) %></dd></div>
        <div><dt>Failed</dt><dd class="numeric"><%= share(@stats.failed, @stats.total) %></dd></div>
        <div><dt>Merged</dt><dd class="numeric"><%= format_int(@stats.merged) %></dd></div>
        <div><dt>Tokens today</dt><dd class="numeric"><%= compact(@usage.today[:total_tokens]) %></dd></div>
      </dl>
      <Charts.columns id="runs-chart" title="Worker runs per day by outcome, last 14 days" series={run_series()} columns={run_columns(@usage)} format={&format_count/1} integer={true} width={340} />
    </section>
    """
  end

  attr(:usage, :map, required: true)
  attr(:usage_error, :any, default: nil)

  defp spend_panel(assigns) do
    assigns = assign(assigns, :rows, spend_rows(assigns.usage))

    ~H"""
    <section class="panel" aria-labelledby="spend-title">
      <header class="section-head"><h2 id="spend-title" title="API-equivalent USD by model">Spend <span class="count">14 days</span></h2></header>
      <p :if={@usage.status != "ok"} class="error-copy">History unavailable<%= if @usage_error do %>: <%= @usage_error %><% end %>.</p>
      <Charts.columns id="spend-chart" title="Estimated worker spend per day by model, last 14 days" series={spend_series(@usage)} columns={spend_columns(@usage)} format={&format_usd_axis/1} width={340} />
      <table :if={@rows != []} class="spend-table">
        <thead><tr><th scope="col">Model</th><th scope="col">Today</th><th scope="col">14 days</th></tr></thead>
        <tbody>
          <tr :for={row <- @rows}>
            <th scope="row"><span class={"legend-key #{row.class}"}></span><%= row.model %></th>
            <td class="numeric"><%= format_usd(row.today) %></td>
            <td class="numeric"><%= format_usd(row.total) %></td>
          </tr>
        </tbody>
      </table>
      <table :if={length(@usage[:by_project] || []) > 1} class="spend-table">
        <thead><tr><th scope="col">Project</th><th scope="col">Today</th><th scope="col">14 days</th></tr></thead>
        <tbody>
          <tr :for={row <- Enum.sort_by(@usage.by_project, & &1.today_usd_micro, :desc)}>
            <th scope="row"><%= row.project %></th>
            <td class="numeric"><%= format_usd(row.today_usd_micro) %></td>
            <td class="numeric"><%= format_usd(row.days_usd_micro) %></td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  attr(:usage, :map, required: true)
  attr(:quota, :any, default: nil)
  attr(:throttle, :any, default: nil)
  attr(:now, :any, required: true)

  defp models_panel(assigns) do
    ~H"""
    <section class="panel" aria-labelledby="models-title">
      <header class="section-head"><h2 id="models-title" title={"Tokens by model; prices as of #{@usage.pricing_as_of}"}>Models</h2></header>
      <%= if @usage.by_model == [] do %>
        <p class="empty-state">No recorded model usage yet.</p>
      <% else %>
        <Charts.bars title="Tokens by model" rows={model_rows(@usage)} />
      <% end %>
      <Charts.meter :for={meter <- quota_meters(@quota, @now)} label={meter.label} percent={meter.percent} detail={meter.detail} />
      <p :for={item <- (@throttle && @throttle.avoid) || []} class="panel-copy">
        <strong><%= item.model %></strong> backed off: <%= item.reason %>
      </p>
      <p :if={@throttle && @throttle.paused} class="panel-copy"><strong>New runs paused:</strong> <%= @throttle.paused %></p>
    </section>
    """
  end

  defp load_payload(project), do: Presenter.payload(project: project, orchestrator: orchestrator(), timeout: snapshot_timeout_ms())

  # Lists that mix projects name each item's project; one project needs neither filter nor names.
  defp mixed?(payload), do: length(payload[:projects] || []) > 1 and is_nil(payload[:project])
  defp orchestrator, do: Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  defp snapshot_timeout_ms, do: Endpoint.config(:snapshot_timeout_ms) || 15_000

  defp brand_line(%{error: _error}), do: "AI Agent Operations Dashboard"

  defp brand_line(payload) do
    repo = with tracker when is_binary(tracker) <- payload.runtime.tracker, do: tracker |> String.split(":", parts: 2) |> List.last()
    autopilot = if payload.autopilot.enabled, do: "Autopilot on", else: "Autopilot off"
    [repo, autopilot] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
  end

  defp longest_detail([], _now), do: "idle"

  defp longest_detail(running, now) do
    longest = running |> Enum.map(&runtime_seconds(&1.started_at, now)) |> Enum.max()
    "longest #{format_runtime(longest)}"
  end

  defp over_budget?(%{usage: %{status: "ok", today: today}, header: %{budget_usd_micro: budget}}), do: (today[:usd_micro] || 0) >= budget
  defp over_budget?(_payload), do: false

  defp budget_detail(payload) do
    budget = format_usd(payload.header.budget_usd_micro)

    cond do
      get_in(payload, [:throttle, :over_budget]) -> "over #{budget} · closing only"
      over_budget?(payload) -> "over #{budget} budget"
      true -> "of #{budget} budget"
    end
  end

  defp budget_title(payload) do
    if get_in(payload, [:throttle, :over_budget]) do
      "Over the enforced daily budget: until midnight UTC only #{Enum.map_join(payload.throttle.allow, ", ", &allow_phrase/1)} start."
    else
      budget_alert_title(payload)
    end
  end

  defp allow_phrase("pull_request"), do: "pull request reviews"
  defp allow_phrase("final_attempt"), do: "final attempts"
  defp allow_phrase("continuation"), do: "continuations of work in flight"
  defp allow_phrase("issue"), do: "new issues"
  defp allow_phrase(class), do: class

  defp budget_alert_title(payload) do
    if over_budget?(payload),
      do: "Worker usage alert: estimated worker usage today (UTC) passed the daily budget. Planning and independent review usage are not included.",
      else: "Estimated worker usage today (UTC). Planning and independent review usage are not included."
  end

  defp section_count(payload, "queue"), do: payload.counts.ready
  defp section_count(payload, "prs"), do: payload.counts.open_prs
  defp section_count(payload, "stats"), do: if(healthy?(payload.health), do: nil, else: "!")
  defp section_count(_payload, _section), do: nil

  # The strip always shows the worker slots (up to four empty ones) so its size
  # holds steady as agents start and finish; free slots preview the queue.
  defp free_slots(payload) do
    slots = max(min(payload.header.max_agents || 1, 4), length(payload.running))
    free = slots - length(payload.running)
    ready = payload.upcoming.ready
    if free > 0, do: Enum.map(0..(free - 1)//1, &Enum.at(ready, &1)), else: []
  end

  defp healthy?(health), do: health.coordinator.status == "operational" and health.system.status == "operational"

  defp idle_reason(%{autopilot: %{enabled: true} = autopilot}, now), do: research_summary(autopilot, now)
  defp idle_reason(_payload, _now), do: "Waiting for ready work."

  defp eta(seconds) when is_integer(seconds) and seconds >= 3_600, do: "~#{div(seconds, 3_600)}h #{rem(div(seconds, 60), 60)}m"
  defp eta(seconds) when is_integer(seconds), do: "~#{max(div(seconds, 60), 1)}m"
  defp eta(_seconds), do: "—"

  # Short state names keep the title readable; the full reason is the tooltip.
  defp waiting_label(reason) when reason in ["dependency blocked", "operator blocked"], do: "Blocked"
  defp waiting_label("retry scheduled"), do: "Retrying"
  defp waiting_label("draft"), do: "Draft"
  defp waiting_label("continuation pending"), do: "Continuing"
  defp waiting_label("awaiting maintainer label"), do: "Untrusted"
  defp waiting_label("excluded by " <> _label), do: "Excluded"
  defp waiting_label(_reason), do: "Waiting"

  defp waiting_title(%{reason: reason, blocked_by: [_ | _] = blocked_by}), do: "#{reason}: #{Enum.join(blocked_by, ", ")}"
  defp waiting_title(%{reason: reason}), do: reason

  defp recent_pulls(items), do: items |> Enum.sort_by(&to_string(&1[:updated_at]), :desc) |> Enum.take(100)

  defp activity(usage), do: usage.activity |> Enum.reject(&(&1.kind == "turn_completed")) |> Enum.take(40)

  defp compact_ago(value, now) do
    case parse_time(value) do
      nil -> "—"
      at -> compact_seconds(max(DateTime.diff(now, at, :second), 0))
    end
  end

  defp compact_seconds(seconds) when seconds < 60, do: "now"
  defp compact_seconds(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m ago"
  defp compact_seconds(seconds) when seconds < 86_400, do: "#{div(seconds, 3_600)}h ago"
  defp compact_seconds(seconds), do: "#{div(seconds, 86_400)}d ago"

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

  defp event_tone(kind) when kind in ["completed", "pr_merged", "pr_ready_for_review"], do: "good"
  defp event_tone(kind) when kind in ["failed", "blocked", "attempt_failed", "retired"], do: "critical"
  defp event_tone(kind) when kind in ["retry_scheduled", "interrupted", "stopped", "pr_closed", "model_rerouted"], do: "warning"
  defp event_tone(kind) when kind in ["dispatch", "pr_opened"], do: "info"
  defp event_tone(_kind), do: "neutral"

  defp status_tone(status) when status in ["healthy", "operational"], do: "good"
  defp status_tone(status) when status in ["warning", "degraded"], do: "warning"
  defp status_tone(status) when status in ["critical", "down"], do: "critical"
  defp status_tone(_status), do: "neutral"

  defp status_label("operational"), do: "Operational"
  defp status_label("degraded"), do: "Degraded"
  defp status_label(_status), do: "Down"

  defp share(_part, total) when total in [0, nil], do: "—"
  defp share(part, total), do: "#{format_int(part)} · #{round(part * 100 / total)}%"

  defp channel_status(payload, channel) do
    running? = Enum.any?(payload.running, &(&1.issue_identifier == "research-#{channel}"))
    pending = Map.get(payload.autopilot, :research_pending, [])

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
    Enum.map(Map.get(usage, :daily, []), fn day -> %{label: short_date(day.date), tip: day.date, values: day.spend_by_model} end)
  end

  # Estimated spend per model, today and over the chart's 14 days, largest first.
  defp spend_rows(usage) do
    days = Map.get(usage, :daily, [])
    today = List.last(days, %{spend_by_model: %{}}).spend_by_model

    usage
    |> spend_series()
    |> Enum.map(fn series ->
      total = days |> Enum.map(&Map.get(&1.spend_by_model, series.key, 0)) |> Enum.sum()
      %{model: series.label, class: series.class, today: Map.get(today, series.key, 0), total: total}
    end)
    |> Enum.filter(&(&1.total > 0))
    |> Enum.sort_by(& &1.total, :desc)
  end

  defp today(usage, key), do: usage |> Map.get(:daily, []) |> List.last(%{}) |> Map.get(key, 0)

  defp closed_per_day(usage), do: usage |> Map.get(:daily, []) |> Enum.map(&(Map.get(&1, :merged, 0) + Map.get(&1, :closed, 0)))

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

  # One meter per Codex quota window (the weekly one first), marked when stale.
  defp quota_meters(%{windows: windows}, now) do
    for window <- windows, is_number(window.used_percent) do
      %{
        label: "#{String.capitalize(window.name)} quota",
        percent: round(window.used_percent),
        detail: [reset_text(window.resets_at, now), stale_text(window.state)] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
      }
    end
  end

  defp quota_meters(_quota, _now), do: []

  defp reset_text(nil, _now), do: nil
  defp reset_text(resets_at, now), do: "resets #{until(resets_at, now)}"

  defp stale_text(:stale), do: "last seen over 2h ago"
  defp stale_text(:reset), do: "window has reset"
  defp stale_text(_state), do: nil

  defp short_date(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> Calendar.strftime(parsed, "%b %-d")
      _ -> date
    end
  end

  # Axis values are micro-USD: whole dollars from $10 up, cents below.
  defp format_usd_axis(value) when value >= 10_000_000, do: "$#{round(value / 1_000_000)}"
  defp format_usd_axis(value), do: value |> round() |> format_usd()

  defp format_count(value), do: value |> round() |> Integer.to_string()
end
