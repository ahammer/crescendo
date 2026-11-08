defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Read-only issue workspace over the existing redacted observability payload.
  UTC day selection filters retained terminal outcomes; unfinished work carries
  forward. Personal view preferences never change coordinator state.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  import SymphonyElixirWeb.DashboardComponents

  alias SymphonyElixirWeb.{Charts, Endpoint, Gallery, IssueBoard, LiveRefresh, Presenter, Timeline}
  alias SymphonyElixirWeb.TranscriptComponents

  @sections [{"board", "Board"}, {"stats", "Stats"}, {"pictures", "Pictures"}, {"history", "History"}]
  @shows [{nil, "All"}, {"delivery", "Delivery"}, {"review", "Reviews"}, {"autopilot", "Autopilot"}, {"prs", "PRs & issues"}]

  @impl true
  def mount(params, _session, socket) do
    project = params["project"]

    socket =
      assign(socket,
        section: "board",
        project: project,
        show: show(params),
        selected: nil,
        detail_open: false,
        board_filter: "all",
        query: "",
        area: "all",
        date: nil,
        day_error: nil,
        pins: MapSet.new()
      )

    {:ok, LiveRefresh.start(socket, fn -> load_payload(project) end)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    changed_show = socket.assigns.show != show(params)
    socket = assign(socket, :show, show(params))
    socket = if changed_show, do: assign(socket, area: "all", selected: nil, detail_open: false), else: socket

    case params["project"] do
      project when project == socket.assigns.project ->
        {:noreply, socket}

      project ->
        socket = assign(socket, project: project, area: "all", selected: nil, detail_open: false)
        {:noreply, LiveRefresh.replace(socket, fn -> load_payload(project) end)}
    end
  end

  defp show(%{"show" => show}) when show in ["delivery", "review", "autopilot", "prs"], do: show
  defp show(_params), do: nil

  defp filter_path(project, show) do
    query = URI.encode_query(Enum.reject([project: project, show: show], fn {_key, value} -> is_nil(value) end))
    if query == "", do: "/", else: "/?" <> query
  end

  @impl true
  def handle_event("section", %{"id" => section}, socket) when section in ["board", "stats", "pictures", "history"] do
    {:noreply, assign(socket, section: section, detail_open: false)}
  end

  def handle_event("select-issue", %{"key" => key}, socket) do
    board = IssueBoard.build(socket.assigns.payload, board_day(socket.assigns))

    if IssueBoard.select(board, key),
      do: {:noreply, socket |> assign(selected: key, detail_open: true) |> push_event("board-selection", %{})},
      else: {:noreply, socket}
  end

  def handle_event("close-issue", _params, socket) do
    {:noreply, socket |> assign(:detail_open, false) |> push_event("board-close", %{})}
  end

  def handle_event("board-filter", %{"filter" => filter}, socket) when filter in ["all", "blocked", "pinned"] do
    {:noreply, assign(socket, board_filter: filter, selected: nil, detail_open: false)}
  end

  def handle_event("search", %{"query" => query}, socket) when is_binary(query) do
    {:noreply, assign(socket, query: String.slice(query, 0, 200), selected: nil, detail_open: false)}
  end

  def handle_event("area", %{"area" => area}, socket) when is_binary(area) and byte_size(area) <= 80 do
    {:noreply, assign(socket, area: area, selected: nil, detail_open: false)}
  end

  def handle_event("pin-issue", %{"key" => key}, socket) do
    board = IssueBoard.build(socket.assigns.payload, board_day(socket.assigns))
    pins = socket.assigns.pins

    if IssueBoard.select(board, key) do
      pins = if MapSet.member?(pins, key), do: MapSet.delete(pins, key), else: MapSet.put(pins, key)
      {:noreply, socket |> assign(:pins, pins) |> push_event("board-pins", %{keys: Enum.take(pins, 250)})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("restore-pins", %{"keys" => keys}, socket) when is_list(keys) do
    pins = keys |> Enum.filter(&(is_binary(&1) and byte_size(&1) <= 400)) |> Enum.take(250) |> MapSet.new()
    {:noreply, assign(socket, :pins, pins)}
  end

  def handle_event("day", %{"date" => date}, socket), do: change_day(socket, date)

  def handle_event("day-step", %{"offset" => offset}, socket) when offset in ["-1", "1"] do
    {:ok, date} = Date.from_iso8601(board_day(socket.assigns))
    change_day(socket, date |> Date.add(String.to_integer(offset)) |> Date.to_iso8601())
  end

  def handle_event("today", _params, socket) do
    {:noreply, assign(socket, date: nil, day_error: nil, area: "all", selected: nil, detail_open: false)}
  end

  def handle_event("reset-view", _params, socket) do
    socket =
      socket
      |> assign(section: "board", date: nil, day_error: nil, selected: nil, detail_open: false, board_filter: "all", query: "", area: "all", pins: MapSet.new())
      |> push_event("board-pins", %{keys: []})
      |> push_patch(to: filter_path(socket.assigns.project, nil))

    {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp change_day(socket, value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        if Date.compare(date, DateTime.to_date(socket.assigns.now)) != :gt do
          {:noreply, assign(socket, date: value, day_error: nil, area: "all", selected: nil, detail_open: false)}
        else
          {:noreply, assign(socket, :day_error, "Future days are unavailable.")}
        end

      _ ->
        {:noreply, assign(socket, :day_error, "Choose a valid UTC day.")}
    end
  end

  defp change_day(socket, _value), do: {:noreply, assign(socket, :day_error, "Choose a valid UTC day.")}

  @impl true
  def handle_info(message, socket), do: {:noreply, LiveRefresh.handle_info(message, socket)}

  defp board_day(assigns), do: assigns.date || assigns.now |> DateTime.to_date() |> Date.to_iso8601()

  @impl true
  def render(assigns) do
    assigns = view_defaults(assigns)
    day = board_day(assigns)
    observed = assigns.payload |> IssueBoard.build(day) |> IssueBoard.filter(assigns.show)
    areas = (observed.cards ++ observed.history_cards ++ observed.undated_cards) |> Enum.map(& &1.area) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
    assigns = assign(assigns, :area, if(assigns.area in areas, do: assigns.area, else: "all"))
    board = personal_filter(observed, assigns)
    selected = if assigns.selected, do: IssueBoard.select(board, assigns.selected), else: List.first(board.cards)

    assigns =
      assign(assigns,
        sections: @sections,
        shows: @shows,
        refresh_error: assigns[:refresh_error],
        board: board,
        selected_card: selected,
        day: day,
        areas: areas,
        today: assigns.now |> DateTime.to_date() |> Date.to_iso8601(),
        daily: Enum.find(get_in(assigns.payload, [:usage, :daily]) || [], &(&1.date == day))
      )

    ~H"""
    <section id="issue-workspace" phx-hook="BoardView" class={["issue-workspace", "workspace-section-#{@section}", @payload[:error] && "dash-error"]}>
      <aside :if={@payload[:intelligence_policy]} id="intelligence-policy" class="mediahint">
        Intelligence gain <strong><%= @payload.intelligence_policy.gain %></strong> · <%= if @payload.intelligence_policy.enabled, do: "task-based routing", else: "legacy routing" %>
        <span :if={@payload.intelligence_policy[:error]}><%= @payload.intelligence_policy.error %></span>
        <span>Operator control: crescendo_intelligence_gain_set — gain from 0 to 2. Smartass permission remains separate.</span>
      </aside>
      <header class="workspace-top">
        <div class="workspace-brand"><span class="brand-mark workspace-mark" aria-hidden="true">≋</span><strong>Crescendo</strong><span class="workspace-slash">/</span><span>Issue workspace</span></div>
        <span id="service-revision" class="workspace-subtitle"><%= if @payload.service.revision do %>Revision <a href={@payload.service.commit_url} title={@payload.service.revision}><%= String.slice(@payload.service.revision, 0, 7) %></a><% else %>Revision unknown<% end %></span>
        <.live_badge />
        <button type="button" class="quiet" phx-click="reset-view">Reset view</button>
      </header>
      <section class="workspace-heading">
        <div><p class="workspace-eyebrow">YOUR WORK, NOT YOUR WORKERS</p><h1>A clear path to done<span>.</span></h1><p class="workspace-subtitle"><%= brand_line(@payload) %></p></div>
        <div class="workspace-controls">
          <nav class="section-tabs workspace-section-tabs" role="tablist" aria-label="Sections"><button :for={{id, label} <- @sections} type="button" role="tab" aria-selected={to_string(@section == id)} class={["section-tab", @section == id && "is-active"]} phx-click="section" phx-value-id={id}><%= label %><span :if={section_count(@payload, id)} class="tab-count"><%= section_count(@payload, id) %></span></button></nav>
          <nav :if={!@payload[:error] && length(@payload[:projects] || []) > 1} class="project-filter" aria-label="Project">
            <.link patch={filter_path(nil, @show)} class={["project-pill", is_nil(@payload[:project]) && "is-active"]}>All projects</.link>
            <.link :for={project <- @payload.projects} patch={filter_path(project.id, @show)} class={["project-pill", @payload[:project] == project.id && "is-active", (project.failure || project.snapshot_status in ["timeout", "unavailable"]) && "is-failed"]} title={project.failure || "Snapshot: #{project.snapshot_status} · #{project.running || "—"} running · #{project.ready || "—"} ready"}><%= project.id %><span :if={is_integer(project.running) and project.running > 0} class="tab-count"><%= project.running %></span></.link>
          </nav>
          <form :if={@areas != [] && @section != "pictures"} phx-change="area"><label class="sr-only" for="board-area">Area</label><select id="board-area" name="area"><option value="all" selected={@area == "all"}>All areas</option><option :for={area <- @areas} value={area} selected={@area == area}><%= area %></option></select></form>
          <div class="board-date-control">
            <button type="button" phx-click="day-step" phx-value-offset="-1" aria-label="Previous UTC day">‹</button>
            <form phx-change="day"><label class="sr-only" for="board-day">UTC day</label><input id="board-day" type="date" name="date" value={@day} max={@today} /></form>
            <button type="button" phx-click="day-step" phx-value-offset="1" disabled={@day >= @today} aria-label="Next UTC day">›</button>
            <button type="button" phx-click="today" class="board-today">Today</button>
          </div>
          <nav :if={@section != "pictures"} class="project-filter" aria-label="Work category">
            <.link :for={{value, label} <- @shows} patch={filter_path(@payload[:project], value)} class={["project-pill", @show == value && "is-active"]}><%= label %></.link>
          </nav>
        </div>
      </section>

      <div :if={@refresh_error || @payload[:error]} class="workspace-alert error-card" role="status">
        <h2 class="error-title">Snapshot unavailable</h2><p><%= (@refresh_error || @payload.error).message %>. Retrying automatically.</p>
        <code><%= (@refresh_error || @payload.error).code %></code>
        <p :if={!@payload[:error]}>Showing the last snapshot from <%= @payload.generated_at %>.</p>
      </div>
      <div :if={!@payload[:error]} class="workspace-layout">
        <aside class="board-stats" aria-label="Service statistics and charts">
          <p class="workspace-eyebrow">CURRENT SCOPE · <%= @payload[:project] || "All projects" %></p>
          <div class="stats">
            <.stat label="Agents" value={"#{@payload.counts.running || "—"}/#{@payload.header.max_agents || "—"}"} detail={if @board.partial, do: "Snapshot incomplete", else: longest_detail(@payload.running, @now)} values={@payload.history.running} tone="green" />
            <.stat label="Queue" value={@payload.counts.ready || "-"} detail={"#{@payload.counts.waiting || "-"} waiting"} values={@payload.history.ready} tone="blue" />
            <.stat label="Open PRs" value={@payload.counts.open_prs || "-"} links={pull_links(@payload)} values={@payload.history.open_prs} tone="cyan" />
            <.stat label="PR transitions today" value={today(@payload.usage, :merged) + today(@payload.usage, :closed)} detail={"#{today(@payload.usage, :merged)} merged · #{today(@payload.usage, :closed)} closed · UTC"} values={closed_per_day(@payload.usage)} span="14 days" tone="violet" title="Observed PR transitions, including transient closures; separate from accepted issue deliveries" />
            <.stat label="Turn completion rate" value={share_percent(@payload.run_stats.completed, @payload.run_stats.total)} detail={"#{format_int(@payload.run_stats.completed)} of #{format_int(@payload.run_stats.total)} finished runs · not accepted deliveries"} values={success_per_day(@payload.usage)} span="14 days" tone="cyan" />
            <.stat label="API estimate today" value={if @payload.usage.status == "ok", do: format_usd(@payload.usage.today[:usd_micro]), else: "n/a"} detail={budget_detail(@payload)} values={@payload.history.spend_micro} tone="gold" warn={over_budget?(@payload)} title={budget_title(@payload)} />
          </div>
          <div class="charts is-active">
            <.runs_panel stats={@payload.run_stats} usage={@payload.usage} />
            <.spend_panel usage={@payload.usage} usage_error={@payload.usage_error} stats={@payload.run_stats} />
            <.cost_panel usage={@payload.usage} />
            <.autopilot_panel :if={@payload.autopilot.enabled} payload={@payload} now={@now} />
            <.health_panel payload={@payload} quota={@payload.quota} throttle={@payload[:throttle]} now={@now} />
          </div>
          <details class="worker-details"><summary>Worker slots and automatic retries</summary><.attention blocked={@payload.blocked} retrying={@payload.retrying} now={@now} /><.agent_card :for={entry <- @payload.running} entry={entry} now={@now} mixed={mixed?(@payload)} /><.free_slot :for={next <- free_slots(@payload)} next={next} idle={idle_reason(@payload, @now)} /></details>

          <p :if={@payload[:smartass_mode]} id="smartass-mode" class="workspace-subtitle">Astra permission: <%= if @payload.smartass_mode.enabled, do: "On", else: "Off" %><span :if={@payload.smartass_mode.expires_at}> until <%= @payload.smartass_mode.expires_at %></span></p>
          <p :if={@payload[:priority_mode]} id="priority-mode" class="workspace-subtitle">Fast mode: <%= if @payload.priority_mode.enabled, do: "On", else: "Off" %><span :if={@payload.priority_mode.expires_at}> until <%= @payload.priority_mode.expires_at %></span><span :if={@payload.priority_mode.error}> · Policy unavailable; standard speed</span></p>
        </aside>

        <main class="issue-board-main">

          <div :if={@section != "pictures"} class="board-toolbar">
            <div class="board-view-filters" role="group" aria-label="Filter issues"><button :for={{value, label} <- [{"all", "All issues"}, {"blocked", "Blocked / retrying"}, {"pinned", "Pinned"}]} type="button" phx-click="board-filter" phx-value-filter={value} aria-pressed={to_string(@board_filter == value)} class={@board_filter == value && "is-active"}><%= label %></button></div>
            <form phx-change="search" class="board-search"><label class="sr-only" for="issue-query">Find an issue</label><input id="issue-query" type="search" name="query" value={@query} phx-debounce="150" placeholder="Find an issue…" /></form>
          </div>
          <p :if={@day_error} class="board-day-note" role="status"><%= @day_error %></p>
          <div :if={@board.partial} class="board-day-note" role="status"><strong>Snapshot incomplete.</strong> Counts are unknown. Showing only observed project data.<p :for={error <- @payload[:snapshot_errors] || []}><%= error.project %>: <%= error.status %></p></div>
          <p class="board-day-note"><strong><%= @day %> · UTC</strong> · Completed outcomes are filtered by day. Current unfinished work carries forward; historical queue state is unavailable. History is retained, never cleared.<span :if={@board.undated_cards != []}> <%= length(@board.undated_cards) %> terminal items have no recorded day; see History.</span></p>
          <div :if={@section in ["board", "stats"]} class="board-lanes" aria-label="Issue board">
            <section :for={lane <- @board.lanes} class="issue-lane" aria-label={"#{lane.title} issues"}>
              <header class="lane-heading"><h2><%= lane.title %></h2><span class="count"><%= length(lane.cards) %></span><small><%= lane_hint(lane.id) %></small></header>
              <div class="issue-cards"><p :if={lane.cards == []} class="board-empty">No matching observed issues.<br />Try another filter or UTC day.</p><.issue_card :for={card <- lane.cards} card={card} selected={@selected_card != nil and @selected_card.key == card.key} pinned={MapSet.member?(@pins, card.key)} /></div>
            </section>
          </div>
          <p :if={@section == "pictures"} class="board-day-note">Pictures show the newest retained media in this project scope. Day and issue filters apply to Board and History stories.</p>
          <Gallery.gallery :if={@section == "pictures"} payload={@payload} now={@now} mixed={mixed?(@payload)} active={true} />
          <div :if={@section == "history"} class="board-history"><p class="board-day-note">Retained events: at most 2,000 per selected project. Media: newest 120 within three days. Daily charts: 14 days. Older or missing observations are unavailable.</p><details :if={@board.undated_cards != []}><summary>Terminal items with no recorded day</summary><div class="board-history-cards"><.issue_card :for={card <- @board.undated_cards} card={card} selected={@selected_card != nil and @selected_card.key == card.key} pinned={MapSet.member?(@pins, card.key)} /></div></details><h2>Retained issue stories</h2><p class="mediahint">Issue filters apply to these stories. The source timeline below keeps its project and work-category scope. These observations do not establish a current queue state or accepted delivery.</p><div class="board-history-cards"><.issue_card :for={card <- @board.history_cards} card={card} selected={@selected_card != nil and @selected_card.key == card.key} pinned={MapSet.member?(@pins, card.key)} /></div><Timeline.timeline payload={@payload} now={@now} mixed={mixed?(@payload)} active={true} show={@show} /></div>
          <p class="board-view-note"><span>Select an issue to follow its story</span><span>Pins affect this view only · never scheduling</span></p>
        </main>

        <aside id="issue-detail" class={["issue-detail", @detail_open && @selected_card && "is-open"]} aria-label="Selected issue details" tabindex="-1">
          <%= if @selected_card do %>
            <.issue_story card={@selected_card} now={@now} />
          <% else %>
            <div class="issue-detail-top"><h2>Issue story</h2><button type="button" phx-click="close-issue" class="issue-detail-close">Close</button></div><p class="board-empty">Select an observed issue to see its runs, outcomes and media.</p>
          <% end %>
        </aside>
      </div>
      <footer class="workspace-footer"><div><span class="board-live-dot" aria-hidden="true"></span><strong><%= @day %> UTC</strong><span><%= if @board.partial, do: "Daily totals unavailable: snapshot incomplete", else: daily_rollup(@daily) %></span></div><button type="button" phx-click="section" phx-value-id="history">History &amp; sources</button><span>Updated <%= @payload.generated_at %> · view only</span></footer>
    </section>
    """
  end

  defp view_defaults(assigns) do
    defaults = [
      now: DateTime.utc_now(),
      section: "board",
      show: nil,
      project: nil,
      selected: nil,
      detail_open: false,
      board_filter: "all",
      query: "",
      area: "all",
      date: nil,
      day_error: nil,
      pins: MapSet.new()
    ]

    Enum.reduce(defaults, assigns, fn {key, value}, assigns -> assign_new(assigns, key, fn -> value end) end)
  end

  defp personal_filter(board, assigns) do
    query = String.downcase(assigns.query)

    keep = fn card ->
      text = Enum.join([card.issue_identifier, card.project, card.title, card.phase, card.summary, card.area], " ") |> String.downcase()
      matches = (query == "" or String.contains?(text, query)) and (assigns.area == "all" or assigns.area == card.area)

      matches and
        case assigns.board_filter do
          "pinned" -> MapSet.member?(assigns.pins, card.key)
          "blocked" -> blocked_card?(card)
          _ -> true
        end
    end

    cards = Enum.filter(board.cards, keep)

    %{
      board
      | cards: cards,
        history_cards: Enum.filter(board.history_cards, keep),
        undated_cards: Enum.filter(board.undated_cards, keep),
        lanes: Enum.map(board.lanes, fn lane -> %{lane | cards: Enum.filter(cards, &(&1.lane == lane.id))} end)
    }
  end

  defp lane_hint("intake"), do: "Waiting / scoped"
  defp lane_hint("active"), do: "Observed phase"
  defp lane_hint("done"), do: "Terminal outcomes"

  defp blocked_card?(card) do
    reasons = ["startup admission blocked", "dependency blocked", "operator blocked", "retry scheduled"]

    card.blocked != [] or card.retrying != [] or card.state in ["blocked", "Blocked"] or
      Enum.any?(card.waiting, &(&1[:reason] in reasons))
  end

  defp daily_rollup(nil), do: "Daily observation unavailable"
  defp daily_rollup(day), do: "#{day[:completed] || 0} turns completed · #{day[:failed] || 0} failed · #{day[:stopped] || 0} stopped · not acceptance"

  attr(:card, :map, required: true)
  attr(:selected, :boolean, default: false)
  attr(:pinned, :boolean, default: false)

  defp issue_card(assigns) do
    ~H"""
    <article class={["issue-card", @selected && "is-selected"]}>
      <div class="issue-card-top"><span class="issue-card-id"><%= @card.issue_identifier %><span :if={@card.project}> · <%= @card.project %></span></span><button type="button" class={["issue-pin", @pinned && "is-pinned"]} phx-click="pin-issue" phx-value-key={@card.key} aria-pressed={to_string(@pinned)} aria-label={"#{if @pinned, do: "Unpin", else: "Pin"} #{@card.issue_identifier} in your view"} title="View only; no scheduling change">◇</button></div>
      <button type="button" class="issue-card-select" phx-click="select-issue" phx-value-key={@card.key} aria-pressed={to_string(@selected)} aria-label={"Open #{@card.issue_identifier}: #{@card.title}"}>
        <h3 class="issue-card-title"><%= @card.title || @card.issue_identifier %></h3>
        <p :if={@card.summary} class="issue-card-summary"><%= @card.summary %></p>
        <span class={["issue-phase", "phase-#{@card.lane}"]}><%= @card.phase || "Phase unavailable" %></span>
        <div :if={@card.media != []} class="issue-card-media"><img :for={image <- Enum.take(@card.media, 2)} src={image.src} alt={"Image associated with #{@card.issue_identifier}"} loading="lazy" /></div>
      </button>
      <div class="issue-card-meta"><span><%= if is_integer(@card.run_count), do: "#{@card.run_count} recorded runs", else: "Run count unavailable" %></span><span><%= @card.state || "State unavailable" %><span :if={@card.merged}> · PR merge observed</span></span></div>
    </article>
    """
  end

  attr(:card, :map, required: true)
  attr(:now, :any, required: true)

  defp issue_story(assigns) do
    ~H"""
    <div class="issue-detail-top"><span class="workspace-eyebrow">ISSUE STORY</span><button type="button" phx-click="close-issue" class="issue-detail-close" aria-label="Close issue details">Close ×</button><.issue_identifier identifier={@card.issue_identifier} url={@card.issue_url} /></div>
    <span class={["issue-phase", "phase-#{@card.lane}"]}><%= @card.phase || "Phase unavailable" %></span>
    <h2 class="issue-story-title"><%= @card.title || @card.issue_identifier %></h2>
    <p class="issue-story-summary"><%= @card.summary || "No user-facing phase summary is available." %></p>
    <div class="issue-outcome"><strong><%= if @card.merged, do: "PR merge observed", else: "Delivery outcome" %></strong><p>Issue state: <%= @card.state || "unavailable" %>. Acceptance proof: <%= @card.acceptance || "unavailable" %>. Disposition: <%= @card.disposition || "unavailable" %>. Reported full completion: <%= known_boolean(@card.canonical_outcome_complete) %>.</p><p>Worker completion, validation, issue closure and merge are separate observations.</p></div>
    <details open><summary>Agent runs &amp; reviews</summary><p :if={@card.runs == []} class="mediahint">No explicit worker run IDs are available.</p><ul class="issue-run-list"><li :for={run <- @card.runs}><strong><%= run[:run_id] %></strong><span><%= run[:status] || "Outcome unavailable" %></span><time>Started <%= run_time(run, :started) %> · finished <%= run_time(run, :finished) %></time></li></ul><p :if={@card.helpers != []} class="mediahint"><%= length(@card.helpers) %> explicitly associated helpers</p><.link :for={entry <- @card.running} navigate={agent_path(entry)} class="issue-inspector-link">Open live <%= @card.issue_identifier %> inspector →</.link><p class="mediahint">Recorded runs are observed IDs, not a promised total. Validation status is unavailable in this projection; inspect the linked source records for evidence.</p></details>
    <details :if={@card.external_reports != [] || @card.review_verifications != []} open><summary>Independent reports &amp; verification</summary><p class="mediahint">External reports are unverified CLI reports. They do not add verified worker runs, acceptance or billing totals.</p><ul><li :for={report <- @card.external_reports}><strong><%= report[:role] || "Role unavailable" %></strong> · <%= report[:run_id] || "Report ID unavailable" %><br /><time><%= report[:observed_at] || "Time unavailable" %></time><br />Parent run: <%= report[:parent_run_id] || "unavailable" %></li><li :for={review <- @card.review_verifications}><strong>Verification recorded</strong> · <%= review[:verification_id] || "ID unavailable" %><br /><time><%= epoch_time(review[:reviewed_s]) %></time></li></ul></details>
    <details open><summary>Issue grouping</summary><p class="mediahint">Project: <%= @card.project || "unavailable" %><br />Parent issue: <%= @card.parent_issue || "unavailable" %>. Prerequisites and handoff owners are not inferred parents.</p><ul><li :for={pull <- @card.pull_requests}><a :if={pull[:pr_url] || pull[:url]} href={pull[:pr_url] || pull[:url]} target="_blank" rel="noopener noreferrer">PR <%= pull[:pr_number] || pull[:number] || "unavailable" %> ↗</a><span :if={!pull[:pr_url] && !pull[:url]}>PR relationship recorded; link unavailable</span></li></ul></details>
    <h3>Detailed timeline</h3><p :if={@card.events == []} class="mediahint">No retained events for this issue.</p><ol class="issue-detail-events"><li :for={event <- @card.events} class="issue-detail-event"><time><%= event[:at] || "Time unavailable" %></time><strong><%= event_label(event) %><span :if={event[:pr_number]}> · PR-<%= event.pr_number %></span></strong><p :if={event_summary(event)}><%= event_summary(event) %></p></li></ol>
    <p class="mediahint">Original event timestamps are retained. Recorded observations may lag the underlying event; no cross-clock duration is inferred.</p>
    <details open><summary>Evidence &amp; media · <%= length(@card.media) %></summary><div class="issue-detail-media"><a :for={image <- @card.media} href={image.src} target="_blank" rel="noopener noreferrer" aria-label={"Open original image associated with #{@card.issue_identifier}"}><img src={image.src} alt={"Original issue-associated image for #{@card.issue_identifier}"} loading="lazy" /></a></div><p class="mediahint"><%= if @card.media == [], do: "No retained media available.", else: "Original issue-associated images. Worker-run attribution unavailable; these images alone do not establish acceptance or a before/after comparison." %></p></details>
    """
  end

  defp event_label(event), do: Timeline.describe_event(event).label

  defp event_summary(event) do
    Timeline.describe_event(event).title ||
      Enum.find_value([:reason, :error], fn key -> if is_binary(event[key]), do: String.slice(event[key], 0, 240) end)
  end

  defp run_time(run, :started), do: run[:started_at] || epoch_time(run[:started_s])
  defp run_time(run, :finished), do: run[:finished_at] || epoch_time(run[:finished_s])

  defp epoch_time(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, at} -> DateTime.to_iso8601(at)
      _ -> "unavailable"
    end
  end

  defp epoch_time(_seconds), do: "unavailable"
  defp known_boolean(true), do: "confirmed"
  defp known_boolean(false), do: "not established"
  defp known_boolean(_value), do: "unavailable"

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:detail, :string, default: nil)
  attr(:values, :list, default: [])
  attr(:tone, :string, default: "blue")
  attr(:warn, :boolean, default: false)
  attr(:title, :string, default: nil)
  attr(:links, :list, default: [])
  attr(:span, :string, default: "last 12 hours")

  defp stat(assigns) do
    ~H"""
    <article class={["stat", "stat-#{@tone}", @warn && "stat-warn"]} title={@title}>
      <p class="stat-label"><%= @label %></p>
      <div class="stat-row">
        <p class="stat-value"><%= @value %></p>
        <Charts.sparkline :if={@values != []} values={@values} title={"#{@label}, #{@span}"} />
      </div>
      <p :if={@detail && @links == []} class="stat-detail"><%= @detail %></p>
      <p :if={@links != []} class="stat-detail stat-links">
        <a :for={link <- @links} href={link.url} target="_blank" rel="noopener noreferrer" title={"Open pull requests of #{link.label} on GitHub"}><%= link.label %> <strong><%= link.count %></strong></a>
      </p>
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
        <span :if={get_in(@entry, [:codex_provenance, :service_tier]) in ["fast", "priority"]} class="speed-badge is-fast" title="Fast tier reported by Codex at thread startup">Fast</span>
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

  attr(:payload, :map, required: true)
  attr(:quota, :any, default: nil)
  attr(:throttle, :any, default: nil)
  attr(:now, :any, required: true)

  # Service health and the limits that can hold work back: the Codex quota and the throttle.
  defp health_panel(assigns) do
    health = assigns.payload.health
    checks = health.coordinator.checks ++ health.system.checks
    assigns = assign(assigns, health: health, checks: checks, problems: Enum.reject(checks, &(&1.status in ["healthy", "idle"])))

    ~H"""
    <section class="panel" aria-labelledby="system-title">
      <header class="section-head"><h2 id="system-title">Health &amp; quota</h2></header>
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
      <Charts.meter :for={meter <- quota_meters(@quota, @now)} label={meter.label} percent={meter.percent} detail={meter.detail} />
      <p :if={@payload[:pacing]} class="panel-copy">Usage pace: <strong><%= String.replace(@payload.pacing.signal, "_", " ") %></strong> ·
        <%= @payload.pacing.target_percent %>% account target, <%= @payload.pacing.interactive_allowance_percent %>% interactive allowance.</p>
      <p :for={item <- (@throttle && @throttle.avoid) || []} class="panel-copy">
        <strong><%= item.model %></strong> backed off: <%= item.reason %>
      </p>
      <p :if={@throttle && @throttle.paused} class="panel-copy"><strong>New runs paused:</strong> <%= @throttle.paused %></p>
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
    </section>
    """
  end

  attr(:payload, :map, required: true)
  attr(:now, :any, required: true)

  defp autopilot_panel(assigns) do
    ~H"""
    <section class="panel" aria-labelledby="autopilot-title">
      <header class="section-head"><h2 id="autopilot-title">Autopilot</h2></header>
      <ul class="research-rows" aria-label="Autopilot tasks by project">
        <li :for={{project, source, tasks} <- task_groups(@payload)} class="research-row">
          <span :if={project} class="research-project"><%= project %></span>
          <span class={"task-source source-#{source}"} title={source_title(source)}><%= source %></span>
          <span
            :for={task <- tasks}
            class={"research-channel step-#{task_state(task, @payload, @now)}"}
            title={task_title(task, @now)}
          ><span class="step-dot" aria-hidden="true"></span><%= task.name %> <span class="task-when"><%= task_when(task, @payload, @now) %></span></span>
        </li>
      </ul>
      <p class="panel-copy"><%= research_summary(@payload.autopilot, @now) %></p>
      <Charts.meter
        :if={Map.get(@payload.autopilot, :max_open_issues)}
        label={"Open issue backlog #{@payload.autopilot.open_issues}/#{@payload.autopilot.max_open_issues}"}
        percent={round(@payload.autopilot.open_issues * 100 / max(@payload.autopilot.max_open_issues, 1))}
        detail="Research pauses at the cap."
      />
    </section>
    """
  end

  attr(:stats, :map, required: true)
  attr(:usage, :map, required: true)

  defp runs_panel(assigns) do
    ~H"""
    <section class="panel panel-wide" aria-labelledby="runs-title">
      <header class="section-head"><h2 id="runs-title">Runs <span class="count">14 days</span></h2></header>
      <dl class="run-stats">
        <div><dt>Runs</dt><dd class="numeric"><%= format_int(@stats.total) %></dd></div>
        <div><dt>Completed turns</dt><dd class="numeric"><%= share(@stats.completed, @stats.total) %></dd></div>
        <div><dt>Interrupted</dt><dd class="numeric"><%= share(@stats.interrupted, @stats.total) %></dd></div>
        <div><dt>Failed</dt><dd class="numeric"><%= share(@stats.failed, @stats.total) %></dd></div>
        <div><dt>Stopped runs</dt><dd class="numeric"><%= format_int(@stats.stopped) %></dd></div>
        <div><dt>Blocked item attempts</dt><dd class="numeric"><%= format_int(@stats.blocked_attempts) %></dd></div>
        <div><dt>Scoped deliveries</dt><dd class="numeric"><%= format_int(@stats.accepted_deliveries) %></dd></div>
        <div><dt>Retirements</dt><dd class="numeric"><%= format_int(@stats.retirements) %></dd></div>
        <div><dt>Unknown acceptance</dt><dd class="numeric"><%= format_int(@stats.unknown_dispositions) %></dd></div>
        <div><dt>Merged PRs</dt><dd class="numeric"><%= format_int(@stats.merged) %></dd></div>
        <div><dt>Tokens</dt><dd class="numeric"><%= compact(@usage.today[:total_tokens]) %></dd></div>
      </dl>
      <Charts.columns id="runs-chart" title="Worker runs per day by outcome, last 14 days" series={run_series()} columns={run_columns(@usage)} format={&format_count/1} integer={true} />
    </section>
    """
  end

  attr(:usage, :map, required: true)
  attr(:usage_error, :any, default: nil)
  attr(:stats, :map, required: true)

  defp spend_panel(assigns) do
    days = Map.get(assigns.usage, :daily, [])
    total = days |> Enum.flat_map(&Map.values(&1.spend_by_model)) |> Enum.sum()
    active = Enum.count(days, &(map_size(&1.spend_by_model) > 0))
    assigns = assign(assigns, total: total, today: get_in(assigns.usage, [:today, :usd_micro]), active: active)

    ~H"""
    <section class="panel panel-wide" aria-labelledby="spend-title">
      <header class="section-head">
        <h2 id="spend-title" title="API-equivalent USD by model">Spend <span class="count">14 days</span></h2>
      </header>
      <dl class="run-stats">
        <div><dt>Today</dt><dd class="numeric"><%= format_usd(@today) %></dd></div>
        <div><dt>14 days</dt><dd class="numeric"><%= format_usd(@total) %></dd></div>
        <div title="Average over days with spend"><dt>Per day</dt><dd class="numeric"><%= per(@total, @active) %></dd></div>
        <div title="Spend per finished run"><dt>Per run</dt><dd class="numeric"><%= per(@total, @stats.total) %></dd></div>
        <div title="API-equivalent spend divided by observed merges; accepted-delivery cost is not verified"><dt>Per observed merge</dt><dd class="numeric"><%= per(@total, @stats.merged) %></dd></div>
      </dl>
      <p class="muted">Terminal usage observed: <%= get_in(@usage, [:accounting, :terminal_observed]) || 0 %> runs ·
        incomplete: <%= get_in(@usage, [:accounting, :incomplete]) || 0 %> runs (90-day history).
        Managed helpers: <%= get_in(@usage, [:helpers, :terminal_observed]) || 0 %> with terminal usage ·
        <%= get_in(@usage, [:helpers, :incomplete]) || 0 %> incomplete. External helper/reviewer coverage is unknown.</p>
      <p :if={@usage[:external]} class="muted">CLI reviewer/planner reports: <%= @usage.external[:terminal_reported] || 0 %> terminal tails ·
        <%= @usage.external[:incomplete] || 0 %> incomplete · unverified, outside budget · account debits unknown.</p>
      <p :if={@usage[:planning]} class="muted">Planning skipped before startup: <%= @usage.planning[:unchanged_skips] || 0 %> ·
        observed ready promotions: <%= @usage.planning[:ready_promotions] || 0 %> · startup failures: <%= @usage.planning[:startup_failures] || 0 %>.</p>
      <p :if={@usage.status != "ok"} class="error-copy">History unavailable<%= if @usage_error do %>: <%= @usage_error %><% end %>.</p>
      <Charts.columns id="spend-chart" title="Estimated worker spend per day by model, last 14 days" series={spend_series(@usage)} columns={spend_columns(@usage)} format={&format_usd_axis/1} />
    </section>
    """
  end

  attr(:usage, :map, required: true)

  # Where the money goes: by model (with tokens), by project and by kind of task.
  defp cost_panel(assigns) do
    tokens = Map.new(assigns.usage.by_model, &{&1.model, &1.total_tokens})
    projects = Enum.sort_by(assigns.usage[:by_project] || [], & &1.days_usd_micro, :desc)
    assigns = assign(assigns, models: spend_rows(assigns.usage), tokens: tokens, projects: projects, tasks: task_rows(assigns.usage))

    ~H"""
    <section class="panel panel-wide panel-cost" aria-labelledby="cost-title">
      <header class="section-head">
        <h2 id="cost-title" title={"API-equivalent USD; prices as of #{@usage.pricing_as_of}"}>Cost breakdown</h2>
        <span class="count">today · 14 days</span>
      </header>
      <p :if={@models == [] and @tasks == []} class="empty-state">No recorded spend yet.</p>
      <div class="cost-grid">
        <table :if={@models != []} class="spend-table">
          <thead><tr><th scope="col">Model</th><th scope="col">Today</th><th scope="col">14 days</th><th scope="col">Tokens</th></tr></thead>
          <tbody>
            <tr :for={row <- @models}>
              <th scope="row"><span class="cell-name"><span class={"legend-key #{row.class}"}></span><%= row.model %></span></th>
              <td class="numeric"><%= format_usd(row.today) %></td>
              <td class="numeric"><%= format_usd(row.total) %></td>
              <td class="numeric"><%= compact(Map.get(@tokens, row.model)) %></td>
            </tr>
          </tbody>
        </table>
        <table :if={length(@projects) > 1} class="spend-table">
          <thead><tr><th scope="col">Project</th><th scope="col">Today</th><th scope="col">14 days</th></tr></thead>
          <tbody>
            <tr :for={row <- @projects}>
              <th scope="row"><span class="cell-name"><%= row.project %></span></th>
              <td class="numeric"><%= format_usd(row.today_usd_micro) %></td>
              <td class="numeric"><%= format_usd(row.days_usd_micro) %></td>
            </tr>
          </tbody>
        </table>
        <table :if={@tasks != []} class="spend-table task-table">
          <thead><tr><th scope="col">Task</th><th scope="col">Runs</th><th scope="col" title="Average cost per task">Avg $</th><th scope="col" title="Average time per task">Avg time</th></tr></thead>
          <tbody>
            <tr :for={row <- @tasks}>
              <th scope="row"><span class="cell-name"><Timeline.icon name={row.category} class="task-icon" /><%= row.label %></span></th>
              <td class="numeric"><%= format_int(row.runs) %></td>
              <td class="numeric"><%= format_money(div(row.usd_micro, max(row.runs, 1))) %></td>
              <td class="numeric"><%= if row.timed > 0, do: format_runtime(div(row.seconds, row.timed)), else: "—" %></td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  defp load_payload(project), do: Presenter.payload(project: project, orchestrator: orchestrator(), timeout: snapshot_timeout_ms(), history: true)

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
      do: "API-equivalent worker usage today (UTC) passed the daily budget. Account billing and accepted-delivery cost are unverified.",
      else: "API-equivalent worker usage today (UTC). Account billing and accepted-delivery cost are unverified."
  end

  defp section_count(%{error: _error}, _section), do: nil
  defp section_count(payload, "timeline"), do: payload.counts.ready
  defp section_count(payload, "pictures"), do: if(Map.get(payload.usage, :images, []) == [], do: nil, else: length(payload.usage.images))
  defp section_count(payload, "stats"), do: if(healthy?(payload.health), do: nil, else: "!")
  defp section_count(_payload, _section), do: nil

  # The strip always shows the worker slots (up to four empty ones) so its size
  # holds steady as agents start and finish; free slots preview the queue.
  defp free_slots(%{snapshot_status: "partial"}), do: []

  defp free_slots(payload) do
    slots = max(min(payload.header.max_agents || 1, 4), length(payload.running))
    free = slots - length(payload.running)
    ready = payload.upcoming.ready
    if free > 0, do: Enum.map(0..(free - 1)//1, &Enum.at(ready, &1)), else: []
  end

  # Open pull requests per project, each linking to the repository's pull
  # request list on GitHub (derived from any of its pull request URLs).
  defp pull_links(%{pull_requests: %{enabled: true, items: items}} = payload) when items != [] do
    items
    |> Enum.group_by(&(&1[:project] || brand_repo(payload)))
    |> Enum.map(fn {project, pulls} -> %{label: project, count: length(pulls), url: pulls_url(pulls)} end)
    |> Enum.reject(&is_nil(&1.url))
    |> Enum.sort_by(&{-&1.count, &1.label})
  end

  defp pull_links(_payload), do: []

  defp pulls_url(pulls) do
    Enum.find_value(pulls, fn pull ->
      with url when is_binary(url) <- external_url(pull[:url]),
           [repo, _number] <- String.split(url, ~r{/pull/}, parts: 2),
           do: repo <> "/pulls"
    end)
  end

  defp brand_repo(payload), do: payload |> brand_line() |> String.split(" · ") |> List.first()

  # Average cost and time per task category (per model too once several models ran).
  defp task_rows(usage) do
    rows = Map.get(usage, :by_task, [])
    models = rows |> Enum.map(& &1.model) |> Enum.uniq()

    rows
    |> Enum.group_by(&if(length(models) > 1, do: {&1.category, &1.model}, else: {&1.category, nil}))
    |> Enum.map(fn {{category, model}, group} ->
      label = Timeline.category_name(category) <> if(model, do: " · #{model}", else: "")
      totals = for key <- [:runs, :usd_micro, :timed, :seconds], into: %{}, do: {key, group |> Enum.map(& &1[key]) |> Enum.sum()}
      Map.merge(totals, %{category: category, label: label})
    end)
    |> Enum.sort_by(&{-&1.runs, &1.label})
  end

  defp per(_micro, count) when count in [0, nil], do: "—"
  defp per(micro, count), do: format_money(div(micro, count))

  defp healthy?(health), do: health.coordinator.status == "operational" and health.system.status == "operational"

  defp idle_reason(%{autopilot: %{enabled: true} = autopilot}, now), do: research_summary(autopilot, now)
  defp idle_reason(_payload, _now), do: "Waiting for ready work."

  defp status_tone(status) when status in ["healthy", "operational"], do: "good"
  defp status_tone(status) when status in ["warning", "degraded"], do: "warning"
  defp status_tone(status) when status in ["critical", "down"], do: "critical"
  defp status_tone(_status), do: "neutral"

  defp status_label("operational"), do: "Operational"
  defp status_label("degraded"), do: "Degraded"
  defp status_label(_status), do: "Down"

  defp share(_part, total) when total in [0, nil], do: "—"
  defp share(part, total), do: "#{format_int(part)} · #{round(part * 100 / total)}%"

  # Tasks grouped per project (one group without a service), each group
  # marked by where its tasks come from: the repository folder or local config.
  defp task_groups(payload) do
    autopilot = payload.autopilot
    repos = Map.get(autopilot, :repos) || %{}

    autopilot
    |> Map.get(:tasks, [])
    |> Enum.group_by(& &1[:project])
    |> Enum.sort_by(fn {project, _tasks} -> to_string(project) end)
    |> Enum.map(fn {project, tasks} -> {project, task_source(tasks, Map.get(repos, project) || autopilot[:repo]), Enum.sort_by(tasks, & &1.name)} end)
  end

  defp task_source(tasks, repo) do
    cond do
      match?(%{state: :error}, repo) -> "repo-error"
      Enum.any?(tasks, &(&1.source == "repo")) -> "repo"
      true -> "local"
    end
  end

  defp source_title("repo"), do: "Tasks from the repository's .crescendo/autopilot/ folder"
  defp source_title("repo-error"), do: "Reading the repository's .crescendo/autopilot/ folder failed; the last copy is in use"
  defp source_title(_source), do: "Tasks from the local project config"

  defp task_running?(task, payload) do
    Enum.any?(payload.running, &(&1.issue_identifier == "research-" <> task.name and &1[:project] == task[:project]))
  end

  defp task_state(task, payload, now) do
    cond do
      task_running?(task, payload) -> "running"
      task.attempts > 0 -> "retry"
      DateTime.compare(task_due(task), now) != :gt -> "pending"
      true -> "idle"
    end
  end

  defp task_when(task, payload, now) do
    cond do
      task_running?(task, payload) -> "running"
      task.attempts > 0 -> "retry #{task.attempts + 1} #{until(task_due(task), now)}"
      DateTime.compare(task_due(task), now) != :gt -> if(task.when == "idle", do: "due · when idle", else: "due")
      true -> until(task_due(task), now)
    end
  end

  defp task_title(task, now) do
    last = if task.last, do: " · last #{task.last}#{if task.finished_at, do: " #{ago(task.finished_at, now)}"}", else: ""
    at = if task[:at], do: " at #{task.at} UTC", else: ""
    "#{task.name}: every #{format_every(task.every_ms)}#{at} · #{task.when} · #{task.source}#{last}"
  end

  defp task_due(%{due_at: %DateTime{} = due_at}), do: due_at
  defp task_due(%{due_at: due_at}), do: parse_time(due_at) || ~U[1970-01-01 00:00:00Z]

  defp format_every(ms) when rem(ms, 86_400_000) == 0, do: "#{div(ms, 86_400_000)}d"
  defp format_every(ms) when rem(ms, 3_600_000) == 0, do: "#{div(ms, 3_600_000)}h"
  defp format_every(ms), do: "#{div(ms, 60_000)}m"

  defp research_summary(autopilot, now) do
    cond do
      Map.get(autopilot, :research_running, 0) > 0 -> "Research is planning new work."
      Map.get(autopilot, :research_pending, []) != [] -> "Tasks are due; idle tasks start when the queue is empty."
      next = Map.get(autopilot, :next_research_at) -> "Next task #{until(next, now)}."
      true -> "Tasks start when they are due."
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

  defp success_per_day(usage) do
    Enum.map(Map.get(usage, :daily, []), fn day ->
      finished = Map.get(day, :completed, 0) + Map.get(day, :failed, 0) + Map.get(day, :interrupted, 0) + Map.get(day, :stopped, 0)
      if finished > 0, do: round(Map.get(day, :completed, 0) * 100 / finished), else: 0
    end)
  end

  defp share_percent(_part, total) when total in [0, nil], do: "—"
  defp share_percent(part, total), do: "#{round(part * 100 / total)}%"

  defp closed_per_day(usage), do: usage |> Map.get(:daily, []) |> Enum.map(&(Map.get(&1, :merged, 0) + Map.get(&1, :closed, 0)))

  defp run_series do
    [
      %{key: :completed, label: "Completed turns", class: "status-good"},
      %{key: :interrupted, label: "Interrupted", class: "status-warning"},
      %{key: :failed, label: "Failed", class: "status-critical"},
      %{key: :stopped, label: "Stopped", class: "status-warning"}
    ]
  end

  defp run_columns(usage) do
    Enum.map(Map.get(usage, :daily, []), fn day ->
      %{label: short_date(day.date), tip: day.date, values: Map.take(day, [:completed, :interrupted, :failed, :stopped])}
    end)
  end

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
