defmodule SymphonyElixirWeb.Timeline do
  @moduledoc """
  The dashboard's work timeline: one rolling column where time runs upward.
  What comes next sits on top (the soonest nearest the middle), the running
  agents form the "now" band, and finished work trails below, newest first,
  like a ticker tape. Each row carries an icon for what kind of step it is
  (delivery, review, research, marketing, merge, close, failure, ...).
  """

  use Phoenix.Component

  import SymphonyElixirWeb.DashboardComponents

  alias SymphonyElixir.Operations

  @next_limit 6
  @done_limit 60
  # Finished work worth a row; dispatches show as running, and turn or
  # retry bookkeeping would drown the rest.
  @done_kinds ~w(completed failed stopped interrupted pr_merged pr_closed pr_opened issue_terminal retired blocked task_delivered task_short)
  @run_kinds ~w(completed failed stopped interrupted)

  attr(:payload, :map, required: true)
  attr(:now, :any, required: true)
  attr(:mixed, :boolean, default: false)
  attr(:active, :boolean, default: false)

  @doc "The timeline column."
  @spec timeline(map()) :: Phoenix.LiveView.Rendered.t()
  def timeline(assigns) do
    payload = assigns.payload
    {next, more} = next_items(payload, assigns.now)

    assigns =
      assign(assigns,
        next: Enum.reverse(next),
        more: more,
        waiting: payload.upcoming.waiting,
        running: payload.running,
        done: done_items(payload.usage, assigns.now)
      )

    ~H"""
    <aside class={["timeline", @active && "is-active"]} aria-labelledby="timeline-title">
      <header class="section-head timeline-head">
        <h2 id="timeline-title">Timeline</h2>
        <span class="count"><%= @payload.counts.ready %> next · <%= length(@running) %> now</span>
      </header>
      <p :if={@payload.upcoming.error} class="error-copy">Tracker data is stale: <%= @payload.upcoming.error %></p>
      <div class="tl-scroll">
        <ol class="tl" aria-label="Coming up, running and finished work">
          <li class="tl-group">Up next</li>
          <li :if={@more > 0} class="tl-more">+<%= @more %> more queued</li>
          <li :if={@next == []} class="tl-empty">Nothing queued.</li>
          <.row :for={item <- @next} item={item} phase="next" mixed={@mixed} />
          <li :if={@waiting != []} class="tl-waiting">
            <details>
              <summary><%= length(@waiting) %> waiting</summary>
              <ul>
                <li :for={issue <- @waiting}>
                  <.issue_identifier identifier={issue.issue_identifier} url={issue[:issue_url]} />
                  <.project_chip :if={@mixed} project={issue[:project]} />
                  <span class="tl-waiting-title"><%= issue.title %></span>
                  <span class="tl-waiting-state" title={waiting_title(issue)}><%= waiting_label(issue.reason) %></span>
                </li>
              </ul>
            </details>
          </li>

          <li class="tl-group tl-now">Now</li>
          <li :if={@running == []} class="tl-empty">No agent is running.</li>
          <li :for={entry <- @running} class="tl-row tl-phase-now">
            <.link navigate={agent_path(entry)} class="tl-link" aria-label={"Inspect #{entry.issue_identifier}"}>
              <.tl_node icon={category_icon(entry.issue_identifier)} tone="live" />
              <div class="tl-body">
                <p class="tl-line">
                  <span class="tl-label"><%= category_label(entry.issue_identifier) %></span>
                  <span class="issue-id"><%= entry.issue_identifier %></span>
                  <.project_chip :if={@mixed} project={entry[:project]} />
                  <span class="tl-when numeric"><%= format_runtime(runtime_seconds(entry.started_at, @now)) %></span>
                </p>
                <p class="tl-title"><%= entry[:title] || entry.issue_identifier %></p>
                <p class="tl-meta numeric">
                  <%= format_money((get_in(entry, [:cost, :run]) || %{usd_micro: 0}).usd_micro) %> · <%= route_effort(entry) %>
                </p>
              </div>
            </.link>
          </li>

          <li class="tl-group">Done</li>
          <li :if={@done == []} class="tl-empty">Nothing finished yet.</li>
          <.row :for={item <- @done} item={item} phase="done" mixed={@mixed} />
        </ol>
      </div>
    </aside>
    """
  end

  attr(:item, :map, required: true)
  attr(:phase, :string, required: true)
  attr(:mixed, :boolean, default: false)

  defp row(assigns) do
    ~H"""
    <li class={"tl-row tl-phase-#{@phase}"} title={@item[:tip]}>
      <.tl_node icon={@item.icon} tone={@item.tone} />
      <div class="tl-body">
        <p class="tl-line">
          <span class="tl-label"><%= @item.label %></span>
          <%= if @item.id do %>
            <.issue_identifier identifier={@item.id} url={@item.url} />
          <% end %>
          <.project_chip :if={@mixed} project={@item.project} />
          <span :if={@item.when != ""} class="tl-when numeric"><%= @item.when %></span>
        </p>
        <p :if={@item.title} class="tl-title"><%= @item.title %></p>
        <p :if={@item.meta != ""} class="tl-meta numeric"><%= @item.meta %></p>
      </div>
    </li>
    """
  end

  attr(:icon, :string, required: true)
  attr(:tone, :string, default: "neutral")

  defp tl_node(assigns) do
    ~H"""
    <span class={"tl-node tone-#{@tone}"}><.icon name={@icon} /></span>
    """
  end

  attr(:name, :string, required: true)
  attr(:class, :string, default: "tl-icon")

  @doc "A small line icon for a kind of work or event."
  @spec icon(map()) :: Phoenix.LiveView.Rendered.t()
  def icon(assigns) do
    assigns = assign(assigns, :paths, icon_paths(assigns.name))

    ~H"""
    <svg class={@class} viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path :for={d <- @paths} d={d} /></svg>
    """
  end

  @doc "The icon and label for a task category (see `Operations.task_category/1`)."
  @spec category_icon(String.t() | nil) :: String.t()
  def category_icon(identifier), do: Operations.task_category(identifier)

  @spec category_label(String.t() | nil) :: String.t()
  def category_label(identifier), do: identifier |> Operations.task_category() |> category_name()

  @spec category_name(String.t()) :: String.t()
  def category_name("review"), do: "Review"
  def category_name("research"), do: "Research"
  def category_name("marketing"), do: "Marketing"
  def category_name(_category), do: "Delivery"

  # Soonest first: retries by due time, then the ready queue in dispatch order.
  defp next_items(payload, now) do
    retries =
      payload.retrying
      |> Enum.sort_by(&to_string(&1[:due_at]))
      |> Enum.map(fn entry ->
        %{
          icon: "retry",
          tone: "warning",
          label: "Retry #{entry.attempt}",
          id: entry.issue_identifier,
          url: entry[:issue_url],
          project: entry[:project],
          title: nil,
          when: until(entry[:due_at], now),
          meta: "",
          tip: entry[:error]
        }
      end)

    ready =
      Enum.map(payload.upcoming.ready, fn issue ->
        %{
          icon: category_icon(issue.issue_identifier),
          tone: "info",
          label: category_label(issue.issue_identifier),
          id: issue.issue_identifier,
          url: issue[:issue_url],
          project: issue[:project],
          title: issue[:title],
          when: eta(issue[:eta_seconds]),
          meta: "",
          tip: "Estimated from recent run times of similar work"
        }
      end)

    all = retries ++ ready
    {Enum.take(all, @next_limit), max(length(all) - @next_limit, 0)}
  end

  defp done_items(usage, now) do
    usage.activity
    |> Enum.filter(&(&1.kind in @done_kinds))
    # A task run shows once, as what it delivered, rather than also as a run ending.
    |> Enum.reject(&(&1.kind in @run_kinds and String.starts_with?(to_string(&1[:issue_identifier]), "research-")))
    |> Enum.take(@done_limit)
    |> Enum.map(fn event ->
      {id, url} = event_subject(event)

      %{
        icon: event_icon(event),
        tone: event_tone(event.kind),
        label: event_label(event),
        id: id,
        url: url,
        project: event[:project],
        title: event_title(event),
        when: ago(event.at, now),
        meta: [duration(event[:seconds]), cost(event[:usd_micro])] |> Enum.reject(&is_nil/1) |> Enum.join(" · "),
        tip: event[:at]
      }
    end)
  end

  defp event_subject(%{pr_number: number} = event) when not is_nil(number), do: {"PR-#{number}", event[:pr_url]}
  defp event_subject(%{issue_identifier: id} = event) when is_binary(id), do: {id, event[:issue_url]}
  defp event_subject(_event), do: {nil, nil}

  # Pull request events carry the PR title as their summary; runs carry the item title.
  defp event_title(%{kind: "pr_" <> _} = event), do: event[:summary]
  defp event_title(%{kind: "task_" <> _} = event), do: event[:summary]
  defp event_title(event), do: event[:title]

  defp event_category(event), do: event[:category] || Operations.task_category(event[:issue_identifier])

  defp event_icon(%{kind: "pr_merged"}), do: "merge"
  defp event_icon(%{kind: "pr_closed"}), do: "closed"
  defp event_icon(%{kind: "pr_opened"}), do: "pull"
  defp event_icon(%{kind: "issue_terminal"}), do: "done"
  defp event_icon(%{kind: "failed"}), do: "failed"
  defp event_icon(%{kind: kind}) when kind in ["stopped", "interrupted"], do: "stopped"
  defp event_icon(%{kind: "retired"}), do: "retired"
  defp event_icon(%{kind: "blocked"}), do: "blocked"
  defp event_icon(event), do: event_category(event)

  defp event_label(%{kind: "pr_merged"}), do: "Merged"
  defp event_label(%{kind: "pr_closed"}), do: "Closed"
  defp event_label(%{kind: "pr_opened"}), do: "PR opened"
  defp event_label(%{kind: "issue_terminal"}), do: "Issue closed"
  defp event_label(%{kind: "retired"}), do: "Retired"
  defp event_label(%{kind: "blocked"}), do: "Blocked"
  defp event_label(%{kind: "completed"} = event), do: category_name(event_category(event)) <> " done"
  defp event_label(%{kind: "task_delivered"} = event), do: category_name(event_category(event)) <> " delivered"
  defp event_label(%{kind: "task_short"} = event), do: category_name(event_category(event)) <> " fell short"
  defp event_label(%{kind: "failed"} = event), do: category_name(event_category(event)) <> " failed"
  defp event_label(event), do: category_name(event_category(event)) <> " " <> event.kind

  defp event_tone(kind) when kind in ["completed", "pr_merged", "issue_terminal", "task_delivered"], do: "good"
  defp event_tone(kind) when kind in ["failed", "blocked", "retired"], do: "critical"
  defp event_tone(kind) when kind in ["stopped", "interrupted", "pr_closed", "task_short"], do: "warning"
  defp event_tone(_kind), do: "info"

  # Short state names keep the row readable; the full reason is the tooltip.
  defp waiting_label(reason) when reason in ["dependency blocked", "operator blocked"], do: "Blocked"
  defp waiting_label("retry scheduled"), do: "Retrying"
  defp waiting_label("draft"), do: "Draft"
  defp waiting_label("continuation pending"), do: "Continuing"
  defp waiting_label("awaiting maintainer label"), do: "Untrusted"
  defp waiting_label("excluded by " <> _label), do: "Excluded"
  defp waiting_label(_reason), do: "Waiting"

  defp waiting_title(%{reason: reason, blocked_by: [_ | _] = blocked_by}), do: "#{reason}: #{Enum.join(blocked_by, ", ")}"
  defp waiting_title(%{reason: reason}), do: reason

  defp route_effort(%{route: %{effort: effort}}) when is_binary(effort), do: effort
  defp route_effort(entry), do: route_model(entry)

  defp duration(seconds) when is_integer(seconds), do: format_runtime(seconds)
  defp duration(_seconds), do: nil

  defp cost(micro) when is_integer(micro) and micro > 0, do: format_money(micro)
  defp cost(_micro), do: nil

  defp eta(seconds) when is_integer(seconds) and seconds >= 3_600, do: "~#{div(seconds, 3_600)}h #{rem(div(seconds, 60), 60)}m"
  defp eta(seconds) when is_integer(seconds), do: "~#{max(div(seconds, 60), 1)}m"
  defp eta(_seconds), do: ""

  # 24px line icons, drawn as stroke paths.
  defp icon_paths("delivery"), do: ["M21 8l-9-5-9 5v8l9 5 9-5z", "M3 8l9 5 9-5", "M12 13v8"]
  defp icon_paths("review"), do: ["M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z", circle(12, 12, 3)]
  defp icon_paths("research"), do: ["M9 3h6", "M10 3v6L4.5 19a1.5 1.5 0 0 0 1.3 2h12.4a1.5 1.5 0 0 0 1.3-2L14 9V3", "M7 15h10"]
  defp icon_paths("marketing"), do: ["M3 10v4h3l6 4V6L6 10z", "M16 9a4 4 0 0 1 0 6", "M19 6a8 8 0 0 1 0 12"]
  defp icon_paths("merge"), do: [circle(6, 5, 2), circle(6, 19, 2), circle(18, 12, 2), "M6 7v10", "M6 7c0 4 4 5 10 5"]
  defp icon_paths("pull"), do: [circle(6, 5, 2), circle(6, 19, 2), circle(18, 19, 2), "M6 7v10", "M18 17V9a3 3 0 0 0-3-3h-4", "M13 4l-2 2 2 2"]
  defp icon_paths("closed"), do: [circle(12, 12, 9), "M9 9l6 6", "M15 9l-6 6"]
  defp icon_paths("done"), do: [circle(12, 12, 9), "M8 12l3 3 5-6"]
  defp icon_paths("failed"), do: ["M12 3l10 18H2z", "M12 10v4", "M12 17.5v.01"]
  defp icon_paths("stopped"), do: [circle(12, 12, 9), "M9 9h6v6H9z"]
  defp icon_paths("retired"), do: ["M3 4h18v4H3z", "M5 8v12h14V8", "M10 12h4"]
  defp icon_paths("blocked"), do: ["M5 11h14v10H5z", "M8 11V7a4 4 0 0 1 8 0v4"]
  defp icon_paths("retry"), do: ["M3 12a9 9 0 1 0 3-6.7", "M3 4v5h5"]

  defp circle(cx, cy, r), do: "M#{cx - r} #{cy}a#{r} #{r} 0 1 0 #{2 * r} 0a#{r} #{r} 0 1 0 #{-2 * r} 0"
end
