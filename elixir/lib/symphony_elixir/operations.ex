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
  def usage(nil, _run_id, _model, _delta), do: :ok
  def usage(_table, nil, _model, _delta), do: :ok

  def usage(table, run_id, model, delta) do
    if Enum.any?([:input_tokens, :cached_input_tokens, :output_tokens, :total_tokens], &(Map.get(delta, &1, 0) > 0)) do
      safe_write(fn -> do_usage(table, run_id, model, delta) end)
    else
      :ok
    end
  end

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

    :dets.insert(table, {key, value})
  end

  @spec event(handle(), String.t(), map()) :: :ok
  def event(nil, _kind, _details), do: :ok

  def event(table, kind, details) do
    safe_write(fn -> do_event(table, kind, details) end)
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

  @empty_autopilot %{pr_handled: %{}, research_finished_at: nil, research_pending: []}

  @doc """
  Autopilot memory that must survive restarts: the head commit and run count
  per pull request, the channels left in the current research round, and when
  the last round finished.
  """
  @spec autopilot_state(handle()) :: %{
          pr_handled: map(),
          research_finished_at: DateTime.t() | nil,
          research_pending: [String.t()]
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
  def snapshot(nil), do: %{status: "unavailable", pricing_as_of: @price_date, today: empty_usage(), recorded: empty_usage(), by_model: [], activity: []}

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

    {recorded, daily, by_model, model_runs, events} =
      :dets.foldl(
        fn
          {{:usage, run, date, model}, value}, {all, day, models, runs, events} ->
            models = Map.update(models, model, Map.take(value, Map.keys(empty_usage())), &add_usage(&1, value))
            runs = Map.update(runs, model, MapSet.new([run]), &MapSet.put(&1, run))
            {add_usage(all, value), if(date == today, do: add_usage(day, value), else: day), models, runs, events}

          {{:event, sequence}, entry}, {all, day, models, runs, events} ->
            {all, day, models, runs, [{sequence, entry} | events]}

          _, acc ->
            acc
        end,
        {empty_usage(), empty_usage(), %{}, %{}, []},
        table
      )

    %{
      status: "ok",
      pricing_as_of: @price_date,
      today: daily,
      recorded: recorded,
      by_model: by_model |> Enum.map(fn {model, usage} -> usage |> Map.put(:model, model) |> Map.put(:runs, model_runs |> Map.fetch!(model) |> MapSet.size()) end) |> Enum.sort_by(& &1.model),
      activity: events |> Enum.sort_by(fn {sequence, _} -> -sequence end) |> Enum.take(100) |> Enum.map(&elem(&1, 1))
    }
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
