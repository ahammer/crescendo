defmodule SymphonyElixirWeb.Charts do
  @moduledoc """
  Small server-rendered charts for the dashboard: stacked columns, horizontal
  bars, and meters. Marks are colored through CSS classes (`series-N`,
  `status-*`) so light and dark themes live in the stylesheet. Every chart has
  a hover title per mark and a table view, so no value depends on color alone.
  """

  use Phoenix.Component

  @width 560
  @height 150
  @pad_left 44
  @pad_right 8
  @pad_top 8
  @pad_bottom 22
  @max_column 24
  @gap 2

  @doc """
  Stacked columns over a shared baseline.

  `series` is a list of `%{key, label, class}` in fixed legend order; each
  column is `%{label, tip, values: %{key => number}}`. `format` renders axis,
  tooltip, and table values.
  """
  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:series, :list, required: true)
  attr(:columns, :list, required: true)
  attr(:format, :any, required: true)
  attr(:integer, :boolean, default: false, doc: "counts: ticks land on whole numbers")

  @spec columns(map()) :: Phoenix.LiveView.Rendered.t()
  def columns(assigns) do
    assigns = assign(assigns, geometry(assigns.series, assigns.columns, assigns.integer))

    ~H"""
    <figure class="chart" aria-labelledby={"#{@id}-title"}>
      <figcaption id={"#{@id}-title"} class="sr-only"><%= @title %></figcaption>
      <ul :if={length(@series) > 1} class="chart-legend">
        <li :for={series <- @series}><span class={"legend-key #{series.class}"}></span><%= series.label %></li>
      </ul>
      <svg class="chart-svg" viewBox={"0 0 #{@width} #{@height}"} role="img" aria-label={@title}>
        <g class="chart-grid">
          <line :for={tick <- @ticks} x1={@pad_left} x2={@width - @pad_right} y1={tick.y} y2={tick.y} />
        </g>
        <g class="chart-axis">
          <text :for={tick <- @ticks} x={@pad_left - 6} y={tick.y + 3} text-anchor="end"><%= @format.(tick.value) %></text>
          <text :for={label <- @x_labels} x={label.x} y={@height - 6} text-anchor="middle"><%= label.text %></text>
        </g>
        <g :for={column <- @bars} class="chart-column">
          <title><%= column.tip %> · <%= column_summary(column, @series, @format) %></title>
          <rect class="chart-hit" x={column.band_x} y={@pad_top} width={column.band_w} height={@plot_h} />
          <path :for={segment <- column.segments} class={"chart-mark #{segment.class}"} d={segment.d} />
        </g>
        <line class="chart-baseline" x1={@pad_left} x2={@width - @pad_right} y1={@pad_top + @plot_h} y2={@pad_top + @plot_h} />
      </svg>
      <details class="chart-table">
        <summary>Table</summary>
        <table>
          <thead><tr><th scope="col">Day</th><th :for={series <- @series} scope="col"><%= series.label %></th></tr></thead>
          <tbody>
            <tr :for={column <- @columns}>
              <th scope="row"><%= column.tip %></th>
              <td :for={series <- @series}><%= @format.(Map.get(column.values, series.key, 0)) %></td>
            </tr>
          </tbody>
        </table>
      </details>
    </figure>
    """
  end

  @doc """
  Horizontal bars for a ranked breakdown. Rows are `%{label, value, display, class}`.
  """
  attr(:title, :string, required: true)
  attr(:rows, :list, required: true)

  @spec bars(map()) :: Phoenix.LiveView.Rendered.t()
  def bars(assigns) do
    max = assigns.rows |> Enum.map(& &1.value) |> Enum.max(fn -> 0 end)
    assigns = assign(assigns, :max, max)

    ~H"""
    <ul class="hbar-list" aria-label={@title}>
      <li :for={row <- @rows} class="hbar-row" title={"#{row.label}: #{row.display}"}>
        <span class="hbar-label"><span class={"legend-key #{row.class}"}></span><%= row.label %></span>
        <span class="hbar-track"><span class={"hbar-fill #{row.class}"} style={"width: #{percent(row.value, @max)}%"}></span></span>
        <span class="hbar-value"><%= row.display %></span>
      </li>
    </ul>
    """
  end

  @doc "A single horizontal meter whose fill carries severity."
  attr(:label, :string, required: true)
  attr(:percent, :any, required: true)
  attr(:detail, :string, default: nil)

  @spec meter(map()) :: Phoenix.LiveView.Rendered.t()
  def meter(assigns) do
    percent = assigns.percent |> max(0) |> min(100)
    assigns = assign(assigns, percent: percent, level: meter_level(percent))

    ~H"""
    <div class="meter" title={"#{@label}: #{@percent}% used"}>
      <div class="meter-head">
        <span><%= @label %></span>
        <span class="meter-value"><%= @percent %>% <span class="meter-status"><%= @level %></span></span>
      </div>
      <div class="meter-track" role="meter" aria-label={@label} aria-valuemin="0" aria-valuemax="100" aria-valuenow={@percent}>
        <span class={"meter-fill meter-#{@level}"} style={"width: #{@percent}%"}></span>
      </div>
      <p :if={@detail} class="meter-detail"><%= @detail %></p>
    </div>
    """
  end

  defp meter_level(percent) when percent >= 90, do: "critical"
  defp meter_level(percent) when percent >= 70, do: "warning"
  defp meter_level(_percent), do: "ok"

  defp column_summary(column, series, format) do
    Enum.map_join(series, ", ", fn s -> "#{s.label} #{format.(Map.get(column.values, s.key, 0))}" end)
  end

  defp percent(_value, max) when max <= 0, do: 0
  defp percent(value, max), do: Float.round(value * 100 / max, 1)

  # Lays out stacked columns: a nice axis maximum, three hairline ticks, and
  # each column capped at 24px with a 2px surface gap between segments.
  defp geometry(series, columns, integer) do
    plot_w = @width - @pad_left - @pad_right
    plot_h = @height - @pad_top - @pad_bottom
    count = max(length(columns), 1)
    band = plot_w / count
    column_w = min(@max_column, band * 0.6)
    totals = Enum.map(columns, fn column -> column.values |> Map.values() |> Enum.sum() end)
    top = nice_max(Enum.max(totals, fn -> 0 end), integer)
    scale = if top > 0, do: plot_h / top, else: 0

    bars =
      columns
      |> Enum.with_index()
      |> Enum.map(fn {column, index} ->
        x = @pad_left + band * index + (band - column_w) / 2
        %{tip: column.tip, values: column.values, band_x: @pad_left + band * index, band_w: band, segments: stack(series, column, x, column_w, plot_h, scale)}
      end)

    ticks = for step <- 0..3, do: %{value: top * step / 3, y: @pad_top + plot_h - plot_h * step / 3}

    x_labels =
      columns
      |> Enum.with_index()
      |> Enum.filter(fn {_column, index} -> index in [0, div(count - 1, 2), count - 1] end)
      |> Enum.uniq_by(fn {_column, index} -> index end)
      |> Enum.map(fn {column, index} -> %{text: column.label, x: @pad_left + band * index + band / 2} end)

    %{
      bars: bars,
      ticks: ticks,
      x_labels: x_labels,
      plot_h: plot_h,
      width: @width,
      height: @height,
      pad_left: @pad_left,
      pad_right: @pad_right,
      pad_top: @pad_top
    }
  end

  defp stack(series, column, x, width, plot_h, scale) do
    visible = Enum.filter(series, fn s -> Map.get(column.values, s.key, 0) > 0 end)
    last = length(visible) - 1

    {segments, _base} =
      visible
      |> Enum.with_index()
      |> Enum.map_reduce(@pad_top + plot_h, fn {s, index}, base ->
        height = Map.fetch!(column.values, s.key) * scale
        gap = if index < last, do: @gap, else: 0
        drawn = max(height - gap, 1)
        y = base - height + gap
        {%{class: s.class, d: segment_path(x, y, width, drawn, index == last)}, base - height}
      end)

    segments
  end

  # The data end (top of the stack) gets 4px rounded corners; the baseline stays square.
  defp segment_path(x, y, w, h, true) do
    r = Enum.min([4, h, w / 2])
    "M#{f(x)},#{f(y + h)} L#{f(x)},#{f(y + r)} Q#{f(x)},#{f(y)} #{f(x + r)},#{f(y)} L#{f(x + w - r)},#{f(y)} Q#{f(x + w)},#{f(y)} #{f(x + w)},#{f(y + r)} L#{f(x + w)},#{f(y + h)} Z"
  end

  defp segment_path(x, y, w, h, false), do: "M#{f(x)},#{f(y)} h#{f(w)} v#{f(h)} h#{f(-w)} Z"

  defp f(number), do: :erlang.float_to_binary(number / 1, decimals: 1)

  @doc "Rounds an axis maximum up to three clean steps (whole steps for counts)."
  @spec nice_max(number(), boolean()) :: number()
  def nice_max(value, integer) when value <= 0, do: if(integer, do: 3, else: 3.0)

  def nice_max(value, integer) do
    raw_step = value / 3
    magnitude = :math.pow(10, :math.floor(:math.log10(raw_step)))
    step = Enum.find([1, 2, 2.5, 5, 10], fn m -> m * magnitude >= raw_step end) * magnitude
    if integer, do: max(ceil(step), 1) * 3, else: step * 3
  end
end
