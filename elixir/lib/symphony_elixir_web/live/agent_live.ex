defmodule SymphonyElixirWeb.AgentLive do
  @moduledoc """
  The full-screen agent inspector at `/agents/:id`: one running agent's run as
  an observed chat, with its plan, changed files, images and run details.
  Phones show one pane at a time behind tabs; wider screens put the chat beside
  a sidebar. If the run ends while it is open, its last live view stays up.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :bare}

  import SymphonyElixirWeb.DashboardComponents

  alias SymphonyElixirWeb.{Endpoint, LiveRefresh, Presenter, TranscriptComponents}

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    project = params["project"]

    # Every project loads so the other agents stay one tap away; the agent
    # itself is matched by project and identifier.
    socket =
      socket
      |> assign(id: id, project: project, pane: "chat", agent: nil, ended: false)
      |> LiveRefresh.start(fn -> load_payload(id) end)
      |> track_agent()

    {:ok, socket}
  end

  @impl true
  def handle_event("pane", %{"id" => pane}, socket), do: {:noreply, assign(socket, :pane, pane)}

  @impl true
  def handle_info(message, socket), do: {:noreply, message |> LiveRefresh.handle_info(socket) |> track_agent()}

  # The agent stays on screen after its run ends, marked as ended; a snapshot
  # that failed to load says nothing about the run, so it changes nothing.
  defp track_agent(%{assigns: %{payload: %{running: running}, id: id, project: project}} = socket) do
    case Enum.find(running, &(&1.issue_identifier == id and project in [nil, &1[:project]])) do
      nil -> assign(socket, :ended, not is_nil(socket.assigns.agent))
      agent -> assign(socket, agent: agent, ended: false)
    end
  end

  defp track_agent(socket), do: socket

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :others, others(assigns.payload, assigns))

    ~H"""
    <section class="inspector">
      <header class="insp-bar">
        <.link navigate="/" class="insp-back" aria-label="Back to all agents"><span aria-hidden="true">‹</span><span class="insp-back-text">Agents</span></.link>
        <div class="insp-ident">
          <span :if={@agent} class={"kind-chip kind-#{kind_name(@agent)}"}><%= kind_label(kind_name(@agent)) %></span>
          <span class="insp-id"><%= @id %></span>
          <span :if={@agent && !@ended} class="insp-runtime numeric"><%= format_runtime(runtime_seconds(@agent.started_at, @now)) %></span>
        </div>
        <nav :if={@others != []} class="insp-others" aria-label="Other running agents">
          <.link :for={other <- @others} navigate={agent_path(other)} class="other-pill">
            <span class={"tab-dot kind-dot-#{kind_name(other)}"} aria-hidden="true"></span><%= other.issue_identifier %>
          </.link>
        </nav>
        <.live_badge />
      </header>

      <%= cond do %>
        <% @agent -> %>
          <.run_view agent={@agent} ended={@ended} pane={@pane} now={@now} max_turns={get_in(@payload, [:runtime, :max_turns])} />
        <% @payload[:error] -> %>
          <section class="insp-message error-card">
            <h2 class="error-title">Snapshot unavailable</h2>
            <p class="error-copy"><strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %></p>
          </section>
        <% true -> %>
          <section class="insp-message">
            <h2><%= @id %> is not running</h2>
            <p class="muted">Crescendo keeps a run's transcript only while the run is active. Its work lives on in the tracker and its pull request.</p>
            <.link navigate="/" class="insp-home">See all agents</.link>
          </section>
      <% end %>
    </section>
    """
  end

  attr(:agent, :map, required: true)
  attr(:ended, :boolean, required: true)
  attr(:pane, :string, required: true)
  attr(:now, :any, required: true)
  attr(:max_turns, :any, default: nil)

  defp run_view(assigns) do
    agent = assigns.agent
    workspace = agent.workspace
    entries = Map.get(agent, :transcript, [])

    assigns =
      assign(assigns,
        workspace: workspace,
        entries: entries,
        run: get_in(agent, [:cost, :run]) || %{usd_micro: 0, unpriced_tokens: 0},
        item: get_in(agent, [:cost, :item]) || %{usd_micro: 0, runs: 0, since: nil},
        seconds: runtime_seconds(agent.started_at, assigns.now),
        events: Map.get(agent, :recent_events, []),
        panes: panes(workspace),
        chat_id: "chat-" <> String.replace(agent.issue_identifier, ~r/[^A-Za-z0-9_-]/, "-")
      )

    ~H"""
    <div class="insp-head">
      <h1 class="insp-title"><%= @agent[:title] || @agent.issue_identifier %></h1>
      <div class="insp-meta">
        <.progress progress={@workspace.progress} />
        <span class="mono"><%= route_model(@agent) %></span>
        <span><%= compact(@agent.tokens.total_tokens) %> tok</span>
        <span><%= format_money(@run.usd_micro) %></span>
      </div>
      <p :if={@ended} class="insp-ended" role="status">This run has ended. You're looking at its last live update.</p>
    </div>

    <nav class="pane-tabs" role="tablist" aria-label="Inspector panes">
      <button
        :for={{id, label, count} <- @panes}
        type="button"
        role="tab"
        aria-selected={to_string(@pane == id)}
        class={["pane-tab", @pane == id && "is-active"]}
        phx-click="pane"
        phx-value-id={id}
      ><%= label %><span :if={count} class="tab-count"><%= count %></span></button>
    </nav>

    <div class="insp-body">
      <section class={["pane pane-chat", @pane == "chat" && "is-active"]} aria-label="Transcript">
        <%= if @entries == [] do %>
          <div class="chat chat-fallback">
            <p class="agent-label">Codex update</p>
            <p class="agent-message"><%= @agent.last_message || @agent.last_event || "Waiting for the first Codex event…" %></p>
            <ol :if={length(@events) > 1} class="agent-events">
              <li :for={event <- tl(@events)}>
                <time class="muted numeric" datetime={event.at} title={event.at}><%= ago(event.at, @now) %></time>
                <span class="agent-event-text" title={event.text}><%= event.text %></span>
              </li>
            </ol>
          </div>
        <% else %>
          <TranscriptComponents.transcript id={@chat_id} entries={@entries} now={@now} />
        <% end %>
      </section>

      <aside class="insp-side">
        <section class={["pane side-block", @pane == "plan" && "is-active"]} aria-labelledby="plan-title">
          <h2 id="plan-title">Plan <span class="count"><%= progress_text(@workspace.progress) %></span></h2>
          <%= if @workspace.plan == [] do %>
            <p class="empty-state">The agent has not shared a plan yet.</p>
          <% else %>
            <TranscriptComponents.plan_checklist steps={@workspace.plan} explanation={@workspace.plan_explanation} />
          <% end %>
        </section>

        <section class={["pane side-block", @pane == "files" && "is-active"]} aria-labelledby="files-title">
          <h2 id="files-title">Files changed <span class="count"><%= length(@workspace.files) %></span></h2>
          <%= if @workspace.files == [] do %>
            <p class="empty-state">No changes in this turn yet.</p>
          <% else %>
            <TranscriptComponents.files_changed files={@workspace.files} />
          <% end %>
        </section>

        <section class={["pane side-block", @pane == "images" && "is-active"]} aria-labelledby="images-title">
          <h2 id="images-title">Images <span class="count"><%= @workspace.images %></span></h2>
          <TranscriptComponents.gallery entries={@entries} />
        </section>

        <section class={["pane side-block", @pane == "info" && "is-active"]} aria-labelledby="info-title">
          <h2 id="info-title">Run details</h2>
          <dl class="fact-list">
            <div>
              <dt>Item</dt>
              <dd class="fact-item">
                <.issue_identifier identifier={@agent.issue_identifier} url={@agent.issue_url} />
                <span class={state_badge_class(@agent.state)}><%= @agent.state %></span>
                <span :if={(@agent[:item_attempt] || 1) > 1 or @agent[:final_attempt]} class={if @agent[:final_attempt], do: "status-tag status-critical", else: "status-tag status-warning"}>
                  Attempt <%= @agent[:item_attempt] || 1 %><%= if @agent[:final_attempt], do: " · final" %>
                </span>
              </dd>
            </div>
            <div :if={@agent[:description]}><dt>About</dt><dd><%= @agent.description %></dd></div>
            <div :if={kind_detail(@agent)}><dt>Context</dt><dd><%= kind_detail(@agent) %></dd></div>
            <div :if={visible_labels(@agent) != []}>
              <dt>Labels</dt>
              <dd><ul class="label-list"><li :for={label <- visible_labels(@agent)} class="label-chip"><%= label %></li></ul></dd>
            </div>
            <div><dt>Model</dt><dd class="mono"><%= route_model(@agent) %></dd></div>
            <div><dt>Route</dt><dd><%= route_detail(@agent) %></dd></div>
            <div :if={@agent[:branch]}><dt>Branch</dt><dd class="mono"><%= @agent.branch %></dd></div>
            <div>
              <dt>This run</dt>
              <dd><%= format_money(@run.usd_micro) %><span :if={@run.unpriced_tokens > 0} class="muted"> partly unpriced</span> · <%= spend_rate(@run.usd_micro, @seconds) %></dd>
            </div>
            <div><dt>Item total</dt><dd><%= format_money(@item.usd_micro) %> · <%= item_runs(@item) %></dd></div>
            <div>
              <dt>Tokens</dt>
              <dd>in <%= compact(@agent.tokens.input_tokens) %> · cached <%= compact(@agent.tokens[:cached_input_tokens] || 0) %> · out <%= compact(@agent.tokens.output_tokens) %> · <%= token_rate(@agent, @now) %></dd>
            </div>
            <div :if={@max_turns}><dt>Turns</dt><dd><%= @agent.turn_count %><span class="muted">/<%= @max_turns %></span></dd></div>
            <div>
              <dt>Workspace</dt>
              <dd class="mono" title={@agent[:workspace_path]}><%= short_path(@agent[:workspace_path]) %><%= if @agent[:worker_host], do: " @ #{@agent.worker_host}" %></dd>
            </div>
            <div>
              <dt>Session</dt>
              <dd class="fact-actions">
                <.copy_button :if={@agent.session_id} value={@agent.session_id} />
                <a class="issue-link" href={if @agent[:project], do: "/api/v1/#{@agent.project}/#{@agent.issue_identifier}", else: "/api/v1/#{@agent.issue_identifier}"}>JSON</a>
              </dd>
            </div>
          </dl>
        </section>
      </aside>
    </div>
    """
  end

  defp panes(workspace) do
    [
      {"chat", "Chat", nil},
      {"plan", "Plan", if(workspace.progress.total > 0, do: "#{workspace.progress.done}/#{workspace.progress.total}")},
      {"files", "Files", if(workspace.files != [], do: length(workspace.files))},
      {"images", "Images", if(workspace.images > 0, do: workspace.images)},
      {"info", "Info", nil}
    ]
  end

  defp others(%{running: running}, %{id: id, project: project}),
    do: Enum.reject(running, &(&1.issue_identifier == id and project in [nil, &1[:project]]))

  defp others(_payload, _assigns), do: []

  defp load_payload(id), do: Presenter.payload(transcripts: id, orchestrator: orchestrator(), timeout: snapshot_timeout_ms())
  defp orchestrator, do: Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  defp snapshot_timeout_ms, do: Endpoint.config(:snapshot_timeout_ms) || 15_000
end
