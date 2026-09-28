defmodule SymphonyElixir.Operations do
  @moduledoc "Durable, bounded operational history for the web dashboard."

  require Logger

  @table :symphony_operations
  @event_limit 2_000
  @price_date "2026-09-24"
  # Standard, short-context API prices in micro-USD per million tokens.
  @rates %{
    "gpt-6-astra" => {5_000_000, 500_000, 25_000_000},
    "gpt-6-sol" => {1_000_000, 100_000, 5_000_000},
    "gpt-6-luna" => {50_000, 5_000, 250_000},
    "gpt-5.6-sol" => {4_000_000, 400_000, 20_000_000},
    "gpt-5.6-terra" => {2_000_000, 200_000, 12_000_000},
    "gpt-5.6-luna" => {200_000, 20_000, 1_200_000},
    "gpt-5.5" => {5_000_000, 500_000, 30_000_000}
  }

  @type handle :: atom() | nil

  @spec open(Path.t(), atom()) :: {:ok, handle()} | {:error, term()}
  def open(path, table \\ @table) when is_binary(path) and is_atom(table) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, ^table} <- :dets.open_file(table, file: String.to_charlist(path), type: :set) do
      interrupt_active_runs(table)
      {:ok, table}
    end
  end

  @spec close(handle()) :: :ok
  def close(nil), do: :ok
  def close(table), do: safe_write(fn -> :dets.close(table) end)

  @spec sync(handle()) :: :ok
  def sync(nil), do: :ok
  def sync(table), do: safe_write(fn -> :dets.sync(table) end)

  @spec start_run(handle(), String.t(), map()) :: :ok
  def start_run(nil, _id, _details), do: :ok

  def start_run(table, id, details) do
    safe_write(fn ->
      :ok = :dets.insert(table, {{:run, id}, Map.put(details, :status, "running")})
      event(table, "dispatch", details)
    end)
  end

  @spec finish_run(handle(), String.t() | nil, String.t(), map()) :: :ok
  def finish_run(nil, _id, _kind, _details), do: :ok
  def finish_run(_table, nil, _kind, _details), do: :ok

  def finish_run(table, id, kind, details) do
    safe_write(fn -> do_finish_run(table, id, kind, details) end)
  end

  defp do_finish_run(table, id, kind, details) do
    :ok = :dets.delete(table, {:run, id})
    event(table, kind, details)
    sync(table)
  end

  @spec usage(handle(), String.t() | nil, String.t() | nil, map()) :: :ok
  def usage(table, run_id, model, delta), do: usage(table, run_id, model, delta, nil)

  @doc """
  Records a token delta for one run. With a work-item identifier, the delta
  also accumulates into that item's running total across all of its runs.
  """
  @spec usage(handle(), String.t() | nil, String.t() | nil, map(), String.t() | nil) :: :ok
  def usage(nil, _run_id, _model, _delta, _item), do: :ok
  def usage(_table, nil, _model, _delta, _item), do: :ok

  def usage(table, run_id, model, delta, item) do
    if Enum.any?([:input_tokens, :cached_input_tokens, :output_tokens, :total_tokens], &(Map.get(delta, &1, 0) > 0)) do
      safe_write(fn -> record_usage(table, run_id, model, delta, item) end)
    else
      :ok
    end
  end

  defp record_usage(table, run_id, model, delta, item) do
    price = do_usage(table, run_id, model, delta)
    if is_binary(item), do: add_item_usage(table, item, run_id, delta, price)
  end

  @doc "Recorded usage for one run, summed across its dates and models."
  @spec run_usage(handle(), String.t() | nil) :: map()
  def run_usage(nil, _run_id), do: empty_cost()
  def run_usage(_table, nil), do: empty_cost()

  def run_usage(table, run_id) do
    table
    |> :dets.match_object({{:usage, run_id, :_, :_}, :_})
    |> Enum.reduce(empty_cost(), fn {_key, value}, acc ->
      %{
        usd_micro: acc.usd_micro + value.usd_micro,
        total_tokens: acc.total_tokens + value.total_tokens,
        unpriced_tokens: acc.unpriced_tokens + value.unpriced_tokens
      }
    end)
  rescue
    ArgumentError -> empty_cost()
  catch
    :exit, _ -> empty_cost()
  end

  @doc """
  Recorded usage for one work item across every run that passed its
  identifier, with the run count and when recording began.
  """
  @spec item_usage(handle(), String.t() | nil) :: map()
  def item_usage(nil, _item), do: empty_item_usage()
  def item_usage(_table, nil), do: empty_item_usage()

  def item_usage(table, item) do
    case :dets.lookup(table, {:item_usage, item}) do
      [{_key, value}] -> value |> Map.delete(:usd_numerator) |> Map.put(:runs, MapSet.size(value.runs))
      _ -> empty_item_usage()
    end
  rescue
    ArgumentError -> empty_item_usage()
  catch
    :exit, _ -> empty_item_usage()
  end

  defp add_item_usage(table, item, run_id, delta, price) do
    key = {:item_usage, item}

    previous =
      case :dets.lookup(table, key) do
        [{^key, value}] -> value
        _ -> %{usd_micro: 0, usd_numerator: 0, total_tokens: 0, unpriced_tokens: 0, runs: MapSet.new(), since: Date.utc_today() |> Date.to_iso8601()}
      end

    total = max(Map.get(delta, :input_tokens, 0) + Map.get(delta, :output_tokens, 0), Map.get(delta, :total_tokens, 0))
    numerator = previous.usd_numerator + (price || 0)

    :dets.insert(
      table,
      {key,
       %{
         previous
         | usd_micro: div(numerator, 1_000_000),
           usd_numerator: numerator,
           total_tokens: previous.total_tokens + total,
           unpriced_tokens: previous.unpriced_tokens + if(is_nil(price), do: total, else: 0),
           runs: MapSet.put(previous.runs, run_id)
       }}
    )
  end

  defp empty_cost, do: %{usd_micro: 0, total_tokens: 0, unpriced_tokens: 0}
  defp empty_item_usage, do: %{usd_micro: 0, total_tokens: 0, unpriced_tokens: 0, runs: 0, since: nil}

  defp do_usage(table, run_id, model, delta) do
    date = Date.utc_today() |> Date.to_iso8601()
    key = {:usage, run_id, date, model || "unknown"}

    previous =
      case :dets.lookup(table, key) do
        [{^key, value}] -> value
        _ -> empty_usage()
      end

    input = max(0, Map.get(delta, :input_tokens, 0))
    cached = min(input, max(0, Map.get(delta, :cached_input_tokens, 0)))
    output = max(0, Map.get(delta, :output_tokens, 0))
    total = max(input + output, Map.get(delta, :total_tokens, 0))
    price = price_numerator(model, input, cached, output)
    price_total = Map.get(previous, :usd_numerator, previous.usd_micro * 1_000_000) + (price || 0)

    value = %{
      input_tokens: previous.input_tokens + input,
      cached_input_tokens: previous.cached_input_tokens + cached,
      output_tokens: previous.output_tokens + output,
      total_tokens: previous.total_tokens + total,
      usd_micro: div(price_total, 1_000_000),
      usd_numerator: price_total,
      unpriced_tokens: previous.unpriced_tokens + if(is_nil(price), do: total, else: 0)
    }

    :ok = :dets.insert(table, {key, value})
    price
  end

  @spec event(handle(), String.t(), map()) :: :ok
  def event(nil, _kind, _details), do: :ok

  def event(table, kind, details) do
    safe_write(fn -> do_event(table, kind, details) end)
  end

  @sample_seconds 300
  @sample_retention_buckets div(48 * 3600, 300)
  @sample_window_buckets div(12 * 3600, 300)

  @doc """
  Records the dashboard's headline counts for the current five-minute bucket;
  the latest poll in a bucket wins, and buckets older than two days are dropped.
  """
  @spec record_sample(handle(), map()) :: :ok
  def record_sample(nil, _sample), do: :ok

  def record_sample(table, sample) do
    bucket = div(System.os_time(:second), @sample_seconds)

    safe_write(fn ->
      :ok = :dets.insert(table, {{:sample, bucket}, sample})
      :dets.delete(table, {:sample, bucket - @sample_retention_buckets})
    end)
  end

  @spec pull_inventory(handle()) :: {[map()], DateTime.t() | nil}
  def pull_inventory(nil), do: {[], nil}

  def pull_inventory(table) do
    case :dets.lookup(table, :pull_inventory) do
      [{:pull_inventory, pulls, observed_at}] -> {pulls, observed_at}
      _ -> {[], nil}
    end
  catch
    :exit, _ -> {[], nil}
  end

  @spec save_pull_inventory(handle(), [map()], DateTime.t()) :: :ok
  def save_pull_inventory(nil, _pulls, _observed_at), do: :ok

  def save_pull_inventory(table, pulls, observed_at) do
    safe_write(fn -> :dets.insert(table, {:pull_inventory, pulls, observed_at}) end)
  end

  @empty_autopilot %{pr_handled: %{}, research_finished_at: nil, research_pending: [], item_attempts: %{}}

  @doc """
  Autopilot memory that must survive restarts: the head commit and run count
  per pull request, the channels left in the current research round, and when
  the last round finished.
  """
  @spec autopilot_state(handle()) :: %{
          pr_handled: map(),
          research_finished_at: DateTime.t() | nil,
          research_pending: [String.t()],
          item_attempts: map()
        }
  def autopilot_state(nil), do: @empty_autopilot

  def autopilot_state(table) do
    case :dets.lookup(table, :autopilot) do
      [{:autopilot, %{} = state}] -> Map.merge(@empty_autopilot, state)
      _ -> @empty_autopilot
    end
  rescue
    ArgumentError -> @empty_autopilot
  catch
    :exit, _ -> @empty_autopilot
  end

  @spec save_autopilot_state(handle(), map()) :: :ok
  def save_autopilot_state(nil, _state), do: :ok

  def save_autopilot_state(table, state) do
    safe_write(fn -> :dets.insert(table, {:autopilot, state}) end)
  end

  @doc "Estimated spend recorded today (UTC), in micro-USD."
  @spec spend_today(handle()) :: non_neg_integer()
  def spend_today(nil), do: 0

  def spend_today(table) do
    today = Date.utc_today() |> Date.to_iso8601()

    case :dets.select(table, [{{{:usage, :_, today, :_}, :"$1"}, [], [:"$1"]}]) do
      values when is_list(values) -> Enum.reduce(values, 0, &(&1.usd_micro + &2))
      {:error, _reason} -> 0
    end
  rescue
    ArgumentError -> 0
  catch
    :exit, _ -> 0
  end

  @doc "The last Codex quota snapshot, kept so throttling knows the quota after a restart."
  @spec quota(handle()) :: map() | nil
  def quota(nil), do: nil

  def quota(table) do
    case :dets.lookup(table, :quota) do
      [{:quota, %{} = snapshot}] -> snapshot
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  catch
    :exit, _ -> nil
  end

  @spec save_quota(handle(), map()) :: :ok
  def save_quota(nil, _snapshot), do: :ok
  def save_quota(table, snapshot), do: safe_write(fn -> :dets.insert(table, {:quota, snapshot}) end)

  defp do_event(table, kind, details) do
    sequence =
      case :dets.lookup(table, :sequence) do
        [{:sequence, value}] -> value + 1
        _ -> 1
      end

    entry = details |> Map.take([:issue_identifier, :issue_url, :pr_number, :pr_url, :summary, :model])
    entry = Map.merge(entry, %{kind: kind, at: DateTime.utc_now() |> DateTime.to_iso8601()})
    :ok = :dets.insert(table, [{:sequence, sequence}, {{:event, sequence}, entry}])
    if sequence > @event_limit, do: :dets.delete(table, {:event, sequence - @event_limit})
    :ok
  end

  @spec snapshot(handle()) :: map()
  def snapshot(nil) do
    %{
      status: "unavailable",
      pricing_as_of: @price_date,
      today: empty_usage(),
      recorded: empty_usage(),
      by_model: [],
      activity: [],
      daily: daily_series(%{}, []),
      samples: [],
      median_run_seconds: %{}
    }
  end

  def snapshot(table) do
    do_snapshot(table)
  rescue
    error ->
      Logger.warning("Operations history read failed: #{Exception.message(error)}")
      snapshot(nil)
  catch
    :exit, reason ->
      Logger.warning("Operations history read failed: #{inspect(reason)}")
      snapshot(nil)
  end

  defp do_snapshot(table) do
    today = Date.utc_today() |> Date.to_iso8601()

    {recorded, daily, by_model, model_runs, events, spend, samples} =
      :dets.foldl(
        fn
          {{:usage, run, date, model}, value}, {all, day, models, runs, events, spend, samples} ->
            models = Map.update(models, model, Map.take(value, Map.keys(empty_usage())), &add_usage(&1, value))
            runs = Map.update(runs, model, MapSet.new([run]), &MapSet.put(&1, run))
            spend = Map.update(spend, {date, model}, value.usd_micro, &(&1 + value.usd_micro))
            day = if date == today, do: add_usage(day, value), else: day
            {add_usage(all, value), day, models, runs, events, spend, samples}

          {{:event, sequence}, entry}, {all, day, models, runs, events, spend, samples} ->
            {all, day, models, runs, [{sequence, entry} | events], spend, samples}

          {{:sample, bucket}, sample}, {all, day, models, runs, events, spend, samples} ->
            {all, day, models, runs, events, spend, [{bucket, sample} | samples]}

          _, acc ->
            acc
        end,
        {empty_usage(), empty_usage(), %{}, %{}, [], %{}, []},
        table
      )

    ordered_events = events |> Enum.sort_by(fn {sequence, _} -> sequence end) |> Enum.map(&elem(&1, 1))

    %{
      status: "ok",
      pricing_as_of: @price_date,
      today: daily,
      recorded: recorded,
      by_model: by_model |> Enum.map(fn {model, usage} -> usage |> Map.put(:model, model) |> Map.put(:runs, model_runs |> Map.fetch!(model) |> MapSet.size()) end) |> Enum.sort_by(& &1.model),
      activity: ordered_events |> Enum.reverse() |> Enum.take(100),
      daily: daily_series(spend, ordered_events),
      samples: recent_samples(samples),
      median_run_seconds: median_run_seconds(ordered_events)
    }
  end

  # The last twelve hours of five-minute samples, oldest first.
  defp recent_samples(samples) do
    newest = div(System.os_time(:second), @sample_seconds)

    samples
    |> Enum.filter(fn {bucket, _sample} -> bucket > newest - @sample_window_buckets end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {bucket, sample} -> Map.put(sample, :at, DateTime.from_unix!(bucket * @sample_seconds) |> DateTime.to_iso8601()) end)
  end

  @finish_kinds ["completed", "failed", "stopped", "interrupted"]

  # Median wall time of runs finished in the last three days, per kind of work
  # item, paired from each item's dispatch event to its next finish event.
  defp median_run_seconds(events) do
    cutoff = DateTime.utc_now() |> DateTime.add(-3 * 86_400, :second)
    {durations, _open} = Enum.reduce(events, {%{}, %{}}, &pair_run(&1, &2, cutoff))
    Map.new(durations, fn {kind, seconds} -> {kind, median(seconds)} end)
  end

  defp pair_run(event, acc, cutoff) do
    with identifier when is_binary(identifier) <- event[:issue_identifier],
         {:ok, at, _offset} <- DateTime.from_iso8601(to_string(event[:at])) do
      pair_event(event[:kind], identifier, at, acc, cutoff)
    else
      _ -> acc
    end
  end

  defp pair_event("dispatch", identifier, at, {durations, open}, _cutoff), do: {durations, Map.put(open, identifier, at)}

  defp pair_event(kind, identifier, at, {durations, open}, cutoff)
       when kind in @finish_kinds and is_map_key(open, identifier) do
    seconds = DateTime.diff(at, Map.fetch!(open, identifier))
    recent? = DateTime.compare(at, cutoff) == :gt
    {if(recent?, do: add_duration(durations, identifier, seconds), else: durations), Map.delete(open, identifier)}
  end

  defp pair_event(_kind, _identifier, _at, acc, _cutoff), do: acc

  defp add_duration(durations, identifier, seconds), do: Map.update(durations, item_kind(identifier), [seconds], &[seconds | &1])

  defp item_kind("PR-" <> _), do: "pull_request"
  defp item_kind("research" <> _), do: "research"
  defp item_kind(_identifier), do: "issue"

  defp median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted), 2))
  end

  @series_days 14
  @outcome_kinds %{
    "completed" => :completed,
    "failed" => :failed,
    "interrupted" => :interrupted,
    "pr_merged" => :merged,
    "pr_closed" => :closed
  }

  # The last two weeks (UTC), oldest first: estimated spend per model plus run
  # outcomes and merged or closed pull requests counted from the retained event ring.
  defp daily_series(spend, events) do
    today = Date.utc_today()
    dates = for offset <- (@series_days - 1)..0//-1, do: today |> Date.add(-offset) |> Date.to_iso8601()

    outcomes =
      Enum.reduce(events, %{}, fn event, acc ->
        with kind when is_atom(kind) <- Map.get(@outcome_kinds, event[:kind]),
             at when is_binary(at) <- event[:at] do
          Map.update(acc, {String.slice(at, 0, 10), kind}, 1, &(&1 + 1))
        else
          _ -> acc
        end
      end)

    Enum.map(dates, fn date ->
      %{
        date: date,
        spend_by_model: for({{^date, model}, usd_micro} <- spend, usd_micro > 0, into: %{}, do: {model, usd_micro}),
        completed: Map.get(outcomes, {date, :completed}, 0),
        failed: Map.get(outcomes, {date, :failed}, 0),
        interrupted: Map.get(outcomes, {date, :interrupted}, 0),
        merged: Map.get(outcomes, {date, :merged}, 0),
        closed: Map.get(outcomes, {date, :closed}, 0)
      }
    end)
  end

  defp interrupt_active_runs(table) do
    active =
      :dets.foldl(
        fn
          {{:run, id}, %{status: "running"} = run}, acc -> [{id, run} | acc]
          _, acc -> acc
        end,
        [],
        table
      )

    Enum.each(active, fn {id, run} ->
      finish_run(table, id, "interrupted", Map.put(run, :summary, "Worker interrupted by Symphony restart"))
    end)
  end

  defp empty_usage, do: %{input_tokens: 0, cached_input_tokens: 0, output_tokens: 0, total_tokens: 0, usd_micro: 0, unpriced_tokens: 0}

  defp add_usage(left, right) do
    Map.new(left, fn {key, value} -> {key, value + Map.get(right, key, 0)} end)
  end

  defp price_numerator(model, input, cached, output) do
    case Map.get(@rates, model) do
      {input_rate, cached_rate, output_rate} ->
        (input - cached) * input_rate + cached * cached_rate + output * output_rate

      nil ->
        nil
    end
  end

  defp safe_write(operation) do
    try do
      operation.()
    rescue
      error -> Logger.warning("Operations history write failed: #{Exception.message(error)}")
    catch
      :exit, reason -> Logger.warning("Operations history write failed: #{inspect(reason)}")
    end

    :ok
  end
end
