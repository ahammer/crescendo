defmodule SymphonyElixirWeb.Gallery do
  @moduledoc """
  The dashboard's picture timeline: images agents captured (screenshots,
  renders, charts), newest first, grouped into one card per run burst with
  its work item. Cards of runs still in flight are marked live. Every image
  opens full size; private projects' images never reach the payload.
  """

  use Phoenix.Component

  import SymphonyElixirWeb.DashboardComponents

  alias SymphonyElixirWeb.Timeline

  @group_limit 30
  @thumbs 3

  attr(:payload, :map, required: true)
  attr(:now, :any, required: true)
  attr(:mixed, :boolean, default: false)
  attr(:active, :boolean, default: false)

  @doc "The picture timeline column."
  @spec gallery(map()) :: Phoenix.LiveView.Rendered.t()
  def gallery(assigns) do
    images = Map.get(assigns.payload.usage, :images, [])
    live = MapSet.new(assigns.payload.running, &{&1[:project], &1.issue_identifier})

    assigns = assign(assigns, groups: groups(images, live), count: length(images))

    ~H"""
    <aside class={["pictures", @active && "is-active"]} aria-labelledby="pictures-title">
      <header class="section-head">
        <h2 id="pictures-title">Pictures</h2>
        <span class="count"><%= @count %> in 3 days</span>
      </header>
      <p :if={@groups == []} class="empty-state">No pictures yet. Screenshots and renders agents look at land here.</p>
      <ol :if={@groups != []} class="pictures-list">
        <li :for={group <- @groups} class={["shot-card", group.live && "is-live"]}>
          <a class="shot-hero" href={group.hero.src} target="_blank" rel="noopener noreferrer" aria-label={"Open the newest picture from #{group.id}"}>
            <img src={group.hero.src} alt={"Latest picture from #{group.id}"} loading="lazy" decoding="async" />
            <span :if={group.live} class="shot-live">Live</span>
            <span :if={group.more > 0} class="shot-count">+<%= group.more %></span>
          </a>
          <div :if={group.thumbs != []} class="shot-thumbs">
            <a :for={image <- group.thumbs} href={image.src} target="_blank" rel="noopener noreferrer" aria-label={"Open a picture from #{group.id}"}>
              <img src={image.src} alt="" loading="lazy" decoding="async" />
            </a>
          </div>
          <div class="shot-meta">
            <p class="shot-line">
              <Timeline.icon name={Timeline.category_icon(group.id)} class="task-icon" />
              <.issue_identifier identifier={group.id} url={group.url} />
              <.project_chip :if={@mixed} project={group.project} />
              <span class="tl-when numeric"><%= ago(group.at, @now) %></span>
            </p>
            <p :if={group.title} class="shot-title"><%= group.title %></p>
          </div>
        </li>
      </ol>
    </aside>
    """
  end

  # Consecutive images of one work item form a card: the newest is the hero,
  # the next few are thumbnails, the rest a count.
  defp groups(images, live) do
    images
    |> Enum.chunk_by(&{&1[:project], &1[:issue_identifier]})
    |> Enum.take(@group_limit)
    |> Enum.map(fn [hero | rest] = group ->
      %{
        id: hero[:issue_identifier] || "run",
        url: hero[:issue_url],
        project: hero[:project],
        title: hero[:title],
        at: hero.at,
        hero: hero,
        thumbs: Enum.take(rest, @thumbs),
        more: max(length(group) - 1 - @thumbs, 0),
        live: MapSet.member?(live, {hero[:project], hero[:issue_identifier]})
      }
    end)
  end
end
