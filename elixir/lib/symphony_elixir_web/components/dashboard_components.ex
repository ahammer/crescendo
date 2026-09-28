defmodule SymphonyElixirWeb.DashboardComponents do
  @moduledoc """
  Pieces shared by the dashboard (the agent HUD) and the agent inspector:
  identifiers, live status, progress, and the formatting both pages use for
  work items, routes, money, tokens and time.
  """

  use Phoenix.Component

  @doc "Live while the page's socket is connected, Offline otherwise (pure CSS)."
  @spec live_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def live_badge(assigns) do
    ~H"""
    <span class="live-state">
      <span class="status-badge status-badge-live"><span class="status-badge-dot"></span>Live</span>
      <span class="status-badge status-badge-offline"><span class="status-badge-dot"></span>Offline</span>
    </span>
    """
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  @doc "A work item identifier, linked to the tracker when it has a web URL."
  @spec issue_identifier(map()) :: Phoenix.LiveView.Rendered.t()
  def issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a class="issue-id issue-id-link" href={@href} target="_blank" rel="noopener noreferrer" aria-label={"Open #{@identifier} in the issue tracker"}><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  attr(:value, :string, required: true)

  @doc "Copies a value (a Codex session id) to the clipboard."
  @spec copy_button(map()) :: Phoenix.LiveView.Rendered.t()
  def copy_button(assigns) do
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

  attr(:progress, :map, required: true)

  @doc "Plan progress as a bar and a step count."
  @spec progress(map()) :: Phoenix.LiveView.Rendered.t()
  def progress(assigns) do
    ~H"""
    <span class="progress">
      <span class="progress-track" role="progressbar" aria-valuemin="0" aria-valuemax={@progress.total} aria-valuenow={@progress.done}>
        <span class="progress-fill" style={"width: #{percent(@progress.done, @progress.total)}%"}></span>
      </span>
      <span class="progress-text numeric"><%= progress_text(@progress) %></span>
    </span>
    """
  end

  @doc "Only http(s) URLs become links."
  @spec external_url(term()) :: String.t() | nil
  def external_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) and host != "" -> url
      _ -> nil
    end
  end

  def external_url(_url), do: nil

  @doc "The kind of work a running entry does: `issue`, `pr` or `research`."
  @spec kind_name(map()) :: String.t()
  def kind_name(%{kind: kind}) when kind in [:pull_request, "pull_request"], do: "pr"
  def kind_name(%{kind: kind}) when kind in [:research, "research"], do: "research"
  def kind_name(%{issue_identifier: "PR-" <> _}), do: "pr"
  def kind_name(%{issue_identifier: "research-" <> _}), do: "research"
  def kind_name(_entry), do: "issue"

  @spec kind_label(String.t()) :: String.t()
  def kind_label("pr"), do: "Review"
  def kind_label("research"), do: "Research"
  def kind_label(_kind), do: "Issue"

  @doc "Pull request and research context for a running entry."
  @spec kind_detail(map()) :: String.t() | nil
  def kind_detail(entry), do: kind_detail(kind_name(entry), entry)

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

  defp kind_detail("research", %{research: %{} = research}), do: "Channel #{research[:channel]} · #{research[:focus]}"
  defp kind_detail(_kind, _entry), do: nil

  @doc "Labels that describe the work; scheduling labels are shown elsewhere."
  @spec visible_labels(map()) :: [String.t()]
  def visible_labels(entry) do
    entry
    |> Map.get(:labels, [])
    |> Enum.reject(&(String.starts_with?(&1, "symphony:") or &1 == "symphony"))
    |> Enum.take(8)
  end

  @spec route_model(map()) :: String.t()
  def route_model(%{route: %{model: model}}) when is_binary(model), do: model
  def route_model(entry), do: entry[:model] || "pending"

  @spec route_detail(map()) :: String.t()
  def route_detail(%{route: %{} = route}) do
    [
      route[:effort] && "#{route.effort} effort",
      route[:tier] && "tier #{route.tier}",
      route[:size] && "size #{route.size}",
      route[:label] && "via #{route.label}",
      backoff_text(route[:backoff])
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  def route_detail(_entry), do: "route pending"

  defp backoff_text(%{"from" => from, "reason" => reason}), do: "backed off from #{from} (#{reason})"
  defp backoff_text(_backoff), do: nil

  @doc "Micro-USD: cents from a dollar up, tenths of a cent below."
  @spec format_money(term()) :: String.t()
  def format_money(micro) when is_integer(micro) and micro >= 1_000_000, do: format_usd(micro)
  def format_money(micro) when is_integer(micro), do: "$" <> :erlang.float_to_binary(micro / 1_000_000, decimals: 3)
  def format_money(_micro), do: "n/a"

  @spec format_usd(term()) :: String.t()
  def format_usd(value) when is_integer(value), do: value |> Kernel./(1_000_000) |> then(&:io_lib.format("$~.2f", [&1])) |> to_string()
  def format_usd(_value), do: "n/a"

  @spec compact(term()) :: String.t()
  def compact(value) when is_integer(value) and value >= 1_000_000_000, do: "#{Float.round(value / 1_000_000_000, 1)}B"
  def compact(value) when is_integer(value) and value >= 1_000_000, do: "#{Float.round(value / 1_000_000, 1)}M"
  def compact(value) when is_integer(value) and value >= 10_000, do: "#{Float.round(value / 1_000, 1)}K"
  def compact(value) when is_integer(value), do: format_int(value)
  def compact(_value), do: "n/a"

  @spec format_int(integer()) :: String.t()
  def format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  @doc "Seconds since a run started, from a DateTime or ISO 8601 string."
  @spec runtime_seconds(term(), DateTime.t()) :: integer()
  def runtime_seconds(%DateTime{} = started_at, %DateTime{} = now), do: DateTime.diff(now, started_at, :second)

  def runtime_seconds(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds(parsed, now)
      _ -> 0
    end
  end

  def runtime_seconds(_started_at, _now), do: 0

  @spec format_runtime(number()) :: String.t()
  def format_runtime(seconds) when is_number(seconds) do
    whole = max(trunc(seconds), 0)

    if whole >= 3_600,
      do: "#{div(whole, 3_600)}h #{rem(div(whole, 60), 60)}m",
      else: "#{div(whole, 60)}m #{rem(whole, 60)}s"
  end

  @doc "How long ago a DateTime or ISO 8601 string was, coarsely."
  @spec ago(term(), DateTime.t()) :: String.t()
  def ago(value, now) do
    case parse_time(value) do
      nil -> "—"
      at -> relative(max(DateTime.diff(now, at, :second), 0)) <> " ago"
    end
  end

  @doc "When a future time falls due."
  @spec until(term(), DateTime.t()) :: String.t()
  def until(value, now) do
    case parse_time(value) do
      nil -> "soon"
      at -> if DateTime.compare(at, now) == :gt, do: "in " <> relative(DateTime.diff(at, now, :second)), else: "is due"
    end
  end

  defp relative(seconds) when seconds < 60, do: "#{seconds}s"
  defp relative(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m"
  defp relative(seconds) when seconds < 86_400, do: "#{div(seconds, 3_600)}h #{rem(div(seconds, 60), 60)}m"
  defp relative(seconds), do: "#{div(seconds, 86_400)}d"

  @spec parse_time(term()) :: DateTime.t() | nil
  def parse_time(%DateTime{} = at), do: at

  def parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  def parse_time(_value), do: nil

  @doc "Estimated spend per hour for a run, once it has run a minute."
  @spec spend_rate(term(), integer()) :: String.t()
  def spend_rate(micro, seconds) when is_integer(micro) and micro > 0 and seconds >= 60, do: "#{format_money(round(micro * 3_600 / seconds))}/h"
  def spend_rate(_micro, _seconds), do: "rate pending"

  @doc "Tokens per minute for a running entry."
  @spec token_rate(map(), DateTime.t()) :: String.t()
  def token_rate(entry, now) do
    minutes = runtime_seconds(entry.started_at, now) / 60

    case entry.tokens.total_tokens do
      total when is_integer(total) and total > 0 and minutes >= 1 -> "#{compact(round(total / minutes))}/min"
      _ -> "rate pending"
    end
  end

  @spec item_runs(map()) :: String.t()
  def item_runs(%{runs: runs, since: since}) when is_integer(runs) and runs > 0, do: "#{runs} run#{if runs == 1, do: "", else: "s"} since #{since}"
  def item_runs(_item), do: "first run"

  @spec short_path(String.t() | nil) :: String.t()
  def short_path(nil), do: "workspace pending"
  def short_path(path), do: path |> Path.split() |> Enum.take(-2) |> Path.join()

  @spec state_badge_class(term()) :: String.t()
  def state_badge_class(state) do
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "state-badge state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "state-badge state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "state-badge state-badge-warning"
      true -> "state-badge"
    end
  end

  @spec progress_text(map()) :: String.t()
  def progress_text(%{total: 0}), do: "no plan yet"
  def progress_text(%{done: done, total: total}), do: "#{done}/#{total} steps"

  @spec percent(number(), number() | nil) :: non_neg_integer()
  def percent(_part, total) when total in [0, nil], do: 0
  def percent(part, total), do: min(round(part * 100 / total), 100)
end
