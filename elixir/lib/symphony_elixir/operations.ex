defmodule SymphonyElixir.Operations do
  @moduledoc "Durable, bounded operational history for the web dashboard."

  require Logger
  alias SymphonyElixir.Codex.Usage

  @table :symphony_operations
  @event_limit 2_000
  @task_days 14
  # Images the dashboard's picture timeline lists: the newest few hundred,
  # no older than the artifact store keeps their files.
  @image_limit 400
  @image_days 3
  @price_date "2026-09-24"
  # Standard, short-context API prices in micro-USD per million tokens
  # (input, cached input, output); `pricing.models` overrides or adds models.
  @rates %{
    # Placeholder at Sol 6.0's prices until `pricing.models` sets the real ones.
    "gpt-6.1-sol" => {1_000_000, 100_000, 5_000_000},
    "gpt-6-astra" => {5_000_000, 500_000, 25_000_000},
    "gpt-6-sol" => {1_000_000, 100_000, 5_000_000},
    "gpt-6-luna" => {50_000, 5_000, 250_000},
    "gpt-5.6-sol" => {4_000_000, 400_000, 20_000_000},
    "gpt-5.6-terra" => {2_000_000, 200_000, 12_000_000},
    "gpt-5.6-luna" => {200_000, 20_000, 1_200_000},
    "gpt-5.5" => {5_000_000, 500_000, 30_000_000}
  }

  @type handle :: atom() | nil
  @type rates :: %{optional(String.t()) => {non_neg_integer(), non_neg_integer(), non_neg_integer()}}

  @doc "Price table: the built-in rates with `pricing.models` (USD per million tokens) applied on top."
  @spec rates(map() | nil) :: rates()
  def rates(%{models: %{} = models}) do
    Enum.reduce(models, @rates, fn {model, price}, acc ->
      Map.put(
        acc,
        model,
        {usd_micro(price["input"]), usd_micro(price["cached_input"]), usd_micro(price["output"])}
      )
    end)
  end

  def rates(_pricing), do: @rates

  @doc "When the price table was last checked: `pricing.as_of`, else the built-in date."
  @spec price_date(map() | nil) :: String.t()
  def price_date(%{as_of: as_of}) when is_binary(as_of), do: as_of
  def price_date(_pricing), do: @price_date

  defp usd_micro(usd), do: round(usd * 1_000_000)

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
      run =
        Map.merge(details, %{
          status: "running",
          accounting_status: "incomplete",
          cache_write_status: "unknown",
          started_s: System.os_time(:second),
          first_eligible_at: lookup(table, {:eligible, details[:issue_id]}, nil)
        })

      :ok = :dets.insert(table, [{{:run, id}, run}, {{:lineage_run, id}, run}])

      :ok =
        :dets.insert(
          table,
          {{:item_run, details[:issue_identifier]}, %{run_id: id, item_attempt: details[:item_attempt]}}
        )

      event(table, "dispatch", Map.put(details, :run_id, id))
    end)
  end

  @spec finish_run(handle(), String.t() | nil, String.t(), map()) :: :ok
  def finish_run(nil, _id, _kind, _details), do: :ok
  def finish_run(_table, nil, _kind, _details), do: :ok

  def finish_run(table, id, kind, details) do
    safe_write(fn ->
      if :dets.lookup(table, {:task, id}) == [],
        do: do_finish_run(table, id, kind, Map.put(details, :run_id, id))
    end)
  end

  # A finished run leaves a task record (model, category, time and cost) for
  # the per-task averages, and its finish event carries the same figures.
  defp do_finish_run(table, id, kind, details) do
    now = System.os_time(:second)
    run = lookup(table, {:run, id}, %{})
    checkpoint = checkpoint(table, run[:issue_id])

    if (not completed_boundary?(kind, details) and checkpoint) && checkpoint[:run_id] == id do
      :ok = :dets.insert(table, {{:thread_checkpoint, run.issue_id}, Map.put(checkpoint, :eligible, false)})
    end

    started =
      case :dets.lookup(table, {:run, id}) do
        [{_key, %{started_s: started}}] -> started
        _ -> nil
      end

    cost = run_usage(table, id)
    category = if kind == "startup_failed", do: "startup", else: task_category(details[:issue_identifier])
    seconds = if started, do: max(now - started, 0)
    model = details[:model] || "unknown"

    task = %{
      at_s: now,
      model: model,
      category: category,
      seconds: seconds,
      usd_micro: cost.usd_micro,
      outcome: kind
    }

    :ok = :dets.delete(table, {:run, id})
    :ok = :dets.insert(table, {{:task, id}, task})

    :ok =
      :dets.insert(
        table,
        {{:lineage_run, id}, Map.merge(lookup(table, {:lineage_run, id}, run), Map.merge(Map.take(details, [:reason, :startup, :worker_host]), %{status: kind, finished_s: now}))}
      )

    :dets.select_delete(table, [
      {{{:lineage_run, :_}, %{finished_s: :"$1"}}, [{:<, :"$1", now - 90 * 86_400}], [true]}
    ])

    :dets.select_delete(table, [
      {{{:task, :_}, %{at_s: :"$1"}}, [{:<, :"$1", now - @task_days * 86_400}], [true]}
    ])

    event(table, kind, Map.merge(details, %{category: category, seconds: seconds, usd_micro: cost.usd_micro}))
    sync(table)
  end

  defp completed_boundary?("completed", _details), do: true
  defp completed_boundary?("interrupted", %{reason: "deployment_drain"}), do: true
  defp completed_boundary?(_kind, _details), do: false

  @doc "The kind of task a work item identifier names: review, research, marketing or delivery."
  @spec task_category(String.t() | nil) :: String.t()
  def task_category("PR-" <> _), do: "review"
  def task_category("research-marketing"), do: "marketing"
  def task_category("research" <> _), do: "research"
  def task_category(_identifier), do: "delivery"

  @spec usage(handle(), String.t() | nil, String.t() | nil, map()) :: :ok
  def usage(table, run_id, model, delta), do: usage(table, run_id, model, delta, nil, @rates)

  @spec usage(handle(), String.t() | nil, String.t() | nil, map(), String.t() | nil) :: :ok
  def usage(table, run_id, model, delta, item), do: usage(table, run_id, model, delta, item, @rates)

  @doc """
  Records a token delta for one run, priced with `rates`. With a work-item
  identifier, the delta also accumulates into that item's running total
  across all of its runs.
  """
  @spec usage(handle(), String.t() | nil, String.t() | nil, map(), String.t() | nil, rates()) :: :ok
  def usage(nil, _run_id, _model, _delta, _item, _rates), do: :ok
  def usage(_table, nil, _model, _delta, _item, _rates), do: :ok

  def usage(table, run_id, model, delta, item, rates) do
    if Enum.any?(
         [:input_tokens, :cached_input_tokens, :output_tokens, :total_tokens],
         &(Map.get(delta, &1, 0) > 0)
       ) do
      safe_write(fn -> record_usage(table, run_id, model, delta, item, rates) end)
    else
      :ok
    end
  end

  defp record_usage(table, run_id, model, delta, item, rates) do
    price = do_usage(table, run_id, model, delta, rates)
    if is_binary(item), do: add_item_usage(table, item, run_id, delta, price)
  end

  @doc "Records first observed eligibility before worker-capacity admission."
  @spec observe_eligible(handle(), String.t()) :: :ok
  def observe_eligible(nil, _issue_id), do: :ok

  def observe_eligible(table, issue_id) do
    safe_write(fn ->
      :dets.insert_new(table, {{:eligible, issue_id}, DateTime.to_iso8601(DateTime.utc_now())})
    end)
  end

  @doc "Atomically persists a scoped thread watermark and every run allocation."
  @spec thread_usage(handle(), term(), String.t(), String.t() | nil, map(), String.t(), rates(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def thread_usage(table, thread, run_id, model, snapshot, item, rates, restored \\ false) do
    checked_write(table, fn ->
      key = {:thread_usage, thread}
      record = lookup(table, key, %{total: %{}, allocations: %{}, source: nil, owner: nil})
      ignored = record.source == :canonical and snapshot.source == :legacy
      {total, delta} = Usage.delta(record.total, if(ignored, do: record.total, else: snapshot.total))

      owner =
        if restored and record.owner,
          do: record.owner,
          else: {run_id, usage_date(snapshot), model || "unknown", item}

      allocations = allocate_usage(record.allocations, owner, delta, rates)
      last_turn = if ignored, do: record[:last_turn], else: complete_turn(snapshot)

      value =
        Map.merge(record, %{
          total: total,
          allocations: allocations,
          owner: owner,
          source: if(ignored, do: record.source, else: snapshot.source),
          last_turn: last_turn
        })

      :ok = :dets.insert(table, {key, value})
      :ok = :dets.sync(table)
      {:ok, if(restored, do: Map.new(delta, fn {field, _} -> {field, 0} end), else: delta)}
    end)
  end

  @doc "Retains credential-free accounting attribution in the existing bounded run history."
  @spec bind_accounting(handle(), String.t(), map()) :: :ok | {:error, term()}
  def bind_accounting(table, run_id, attribution) do
    checked_write(table, fn ->
      run = lookup(table, {:lineage_run, run_id}, %{})
      :ok = :dets.insert(table, {{:lineage_run, run_id}, Map.put(run, :accounting, attribution)})
      :ok = :dets.sync(table)
    end)
  end

  @doc "Reconciles only usage and terminal evidence; never performs active worker actions."
  def reconcile_usage(table, issue_id, run_id, update, active \\ false)

  @spec reconcile_usage(handle(), String.t(), String.t(), map(), boolean()) ::
          {:ok, map()} | :ignored | {:error, term()}
  def reconcile_usage(nil, _issue_id, _run_id, _update, _active), do: :ignored

  def reconcile_usage(table, issue_id, run_id, update, active) do
    checked_write(table, fn ->
      run = lookup(table, {:lineage_run, run_id}, %{})
      attribution = run[:accounting]

      if valid_accounting?(table, run, attribution, issue_id, run_id) do
        reconcile_observation(table, run_id, run, attribution, update, active)
      else
        :ignored
      end
    end)
  end

  defp valid_accounting?(table, run, attribution, issue_id, run_id) do
    is_map(attribution) and attribution.issue_id == issue_id and
      (run[:finished_s] || System.os_time(:second)) >= System.os_time(:second) - 90 * 86_400 and
      lookup(table, {:thread_context, attribution.thread_key}, %{})[:run_id] == run_id
  end

  defp reconcile_observation(table, run_id, run, attribution, update, active) do
    attribution =
      if active and update[:event] != :account_usage,
        do: %{attribution | model: update[:model] || attribution.model, date: Date.to_iso8601(Date.utc_today())},
        else: attribution

    if active and run[:accounting] != attribution,
      do: :dets.insert(table, {{:lineage_run, run_id}, Map.put(run, :accounting, attribution)})

    run = Map.put(run, :accounting, attribution)

    case Usage.snapshot(update) do
      %{thread_id: thread} = snapshot when thread == attribution.thread_id ->
        reconcile_snapshot(table, run_id, run, attribution, snapshot, active and update[:restored] == true)

      _ ->
        observe_boundary(table, run_id, run, attribution, update, active)
    end
  end

  defp reconcile_snapshot(table, run_id, run, attribution, snapshot, restored) do
    snapshot = Map.put(snapshot, :accounting_date, attribution.date)
    result = thread_usage(table, attribution.thread_key, run_id, attribution.model, snapshot, attribution.identifier, attribution.rates, restored)

    if match?({:ok, _}, result) do
      run = if snapshot[:cache_write_observed], do: Map.put(run, :cache_write_status, "observed"), else: run
      turn = complete_turn(snapshot)
      # Stale notifications cannot erase usage observed before turn/start.
      run = if turn, do: Map.update(run, :usage_turns, MapSet.new([turn]), &MapSet.put(&1, turn)), else: run
      save_accounting_observation(table, run_id, run)
    end

    result
  end

  defp observe_boundary(table, id, run, attribution, %{event: :session_started, thread_id: thread, turn_id: turn}, true)
       when thread == attribution.thread_id do
    run =
      run
      |> Map.put(:active_turn, turn)
      |> Map.delete(:terminal_turn)

    save_accounting_observation(table, id, run)
    :ignored
  end

  defp observe_boundary(table, id, run, attribution, %{payload: %{"method" => "turn/completed", "params" => %{"threadId" => thread, "turn" => %{"id" => turn, "status" => status}}}}, _active)
       when thread == attribution.thread_id and status in ["completed", "failed", "interrupted"] do
    if matching_turn?(run, turn),
      do: save_accounting_observation(table, id, Map.put(run, :terminal_turn, turn))

    :ignored
  end

  defp observe_boundary(table, _id, _run, attribution, %{event: :account_usage, thread_id: thread} = update, _active)
       when thread == attribution.thread_id do
    account_usage(table, attribution.thread_key, thread, update[:account_usage])
    :ignored
  end

  defp observe_boundary(_table, _id, _run, _attribution, _update, _active), do: :ignored

  defp matching_turn?(run, turn),
    do: is_binary(turn) and (is_nil(run[:active_turn]) or run[:active_turn] == turn)

  defp save_accounting_observation(table, run_id, run) do
    status = if MapSet.member?(run[:usage_turns] || MapSet.new(), run[:terminal_turn]), do: "terminal_observed", else: "incomplete"
    :ok = :dets.insert(table, {{:lineage_run, run_id}, Map.put(run, :accounting_status, status)})
    :ok = :dets.sync(table)
  end

  defp usage_date(snapshot), do: snapshot[:accounting_date] || Date.to_iso8601(Date.utc_today())

  defp complete_turn(%{source: :canonical, complete: true, turn_id: turn}) when is_binary(turn), do: turn
  defp complete_turn(_snapshot), do: nil

  # A later subset classification can correct an earlier allocation without
  # charging parent tokens again. Exact historical attribution may be unknown.
  defp allocate_usage(allocations, owner, delta, rates) do
    subsets = [
      cached_input_tokens: :input_tokens,
      cache_write_input_tokens: :input_tokens,
      reasoning_output_tokens: :output_tokens
    ]

    allocations =
      Map.put(
        allocations,
        owner,
        priced_usage(
          Map.get(allocations, owner, empty_usage()),
          Map.drop(delta, Keyword.keys(subsets)),
          rates,
          elem(owner, 2)
        )
      )

    owners = [owner | Enum.sort(Map.keys(allocations) -- [owner])]

    Enum.reduce(subsets, allocations, fn {field, parent}, allocations ->
      {allocations, 0} =
        Enum.reduce(owners, {allocations, Map.get(delta, field, 0)}, fn key, {allocations, remaining} ->
          usage = allocations[key]
          count = min(remaining, usage[parent] - Map.get(usage, field, 0))

          {Map.put(allocations, key, priced_usage(usage, %{field => count}, rates, elem(key, 2))), remaining - count}
        end)

      allocations
    end)
  end

  @doc "Stores credential-free provenance and preserves links to all owners of a resumed thread."
  @spec thread_context(handle(), term(), map()) :: :ok | {:error, term()}
  def thread_context(table, thread, context) do
    checked_write(table, fn ->
      previous = lookup(table, {:thread_context, thread}, %{})
      runs = MapSet.put(previous[:runs] || MapSet.new(), context[:run_id])
      :ok = :dets.insert(table, {{:thread_context, thread}, Map.put(context, :runs, runs)})
      :ok = :dets.sync(table)
    end)
  end

  @doc "Retains merge heads and research associations without asserting independent acceptance."
  @spec record_lineage(handle(), String.t(), term(), map()) :: :ok
  def record_lineage(nil, _kind, _id, _evidence), do: :ok

  def record_lineage(table, kind, id, evidence) do
    safe_write(fn ->
      value = Map.put(evidence, :observed_at, DateTime.to_iso8601(DateTime.utc_now()))
      :ok = :dets.insert(table, {{:lineage_evidence, kind, id}, value})
      :ok = :dets.sync(table)
    end)
  end

  @doc "Replaces a thread's native cumulative account estimate; null stays unknown."
  @spec account_usage(handle(), term(), String.t(), map() | nil) :: :ok | {:error, term()}
  def account_usage(table, thread, thread_id, usage) do
    checked_write(table, fn ->
      usage =
        if is_map(usage) && usage["threadId"] == thread_id && is_integer(usage["estimatedUsageCreditsMicros"]) &&
             usage["estimatedUsageCreditsMicros"] >= 0,
           do: usage

      :ok =
        :dets.insert(
          table,
          {{:account_usage, thread}, %{usage: usage, observed_at: DateTime.to_iso8601(DateTime.utc_now())}}
        )

      :ok = :dets.sync(table)
    end)
  end

  @spec checkpoint(handle(), String.t()) :: map() | nil
  def checkpoint(nil, _item), do: nil

  def checkpoint(table, item) do
    case lookup(table, {:thread_checkpoint, item}, nil) do
      %{eligible: true} = value ->
        usage = lookup(table, {:thread_usage, value[:thread_key]}, nil)

        if is_map(usage) and usage[:total] == value[:usage_watermark],
          do: value,
          else: Map.put(value, :eligible, false)

      value when is_map(value) ->
        value

      _ ->
        nil
    end
  end

  @doc "A checkpoint must be durable and have accounted usage before reuse is eligible."
  @spec save_checkpoint(handle(), String.t(), map()) :: :ok | {:error, term()}
  def save_checkpoint(table, item, checkpoint) do
    checked_write(table, fn ->
      usage = lookup(table, {:thread_usage, checkpoint[:thread_key]}, nil)

      eligible =
        checkpoint[:eligible] == true and is_map(usage) and
          is_binary(checkpoint[:turn_id]) and usage[:last_turn] == checkpoint[:turn_id]

      checkpoint =
        checkpoint |> Map.put(:usage_watermark, usage && usage.total) |> Map.put(:eligible, eligible)

      :ok = :dets.insert(table, {{:thread_checkpoint, item}, checkpoint})
      :ok = :dets.sync(table)
    end)
  end

  defp checked_write(nil, _operation), do: {:error, :operations_unavailable}

  defp checked_write(_table, operation) do
    operation.()
  rescue
    error -> {:error, {:operations_write_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:operations_write_failed, reason}}
  end

  defp lookup(table, key, default) do
    case :dets.lookup(table, key) do
      [{^key, value}] -> value
      _ -> default
    end
  rescue
    ArgumentError -> default
  catch
    :exit, _ -> default
  end

  # ponytail: derive aggregates from atomic thread records; add a rebuildable index if reads become costly.
  defp usage_rows(table) do
    :dets.foldl(
      fn
        {{:usage, run, date, model}, value}, acc -> [{{run, date, model, nil}, value} | acc]
        {{:thread_usage, _}, %{allocations: allocations}}, acc -> Map.to_list(allocations) ++ acc
        _, acc -> acc
      end,
      [],
      table
    )
  end

  @doc "Recorded usage for one run, summed across its dates and models."
  @spec run_usage(handle(), String.t() | nil) :: map()
  def run_usage(nil, _run_id), do: empty_cost()
  def run_usage(_table, nil), do: empty_cost()

  def run_usage(table, run_id) do
    table
    |> usage_rows()
    |> Enum.filter(fn {{run, _, _, _}, _} -> run == run_id end)
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
    previous =
      lookup(table, {:item_usage, item}, %{
        usd_micro: 0,
        total_tokens: 0,
        unpriced_tokens: 0,
        runs: MapSet.new(),
        since: nil
      })

    rows = Enum.filter(usage_rows(table), fn {{_, _, _, owner}, _} -> owner == item end)

    Enum.reduce(rows, Map.delete(previous, :usd_numerator), fn {{run, date, _, _}, value}, acc ->
      %{
        acc
        | usd_micro: acc.usd_micro + value.usd_micro,
          total_tokens: acc.total_tokens + value.total_tokens,
          unpriced_tokens: acc.unpriced_tokens + value.unpriced_tokens,
          runs: MapSet.put(acc.runs, run),
          since: if(acc.since, do: min(acc.since, date), else: date)
      }
    end)
    |> Map.update!(:runs, &MapSet.size/1)
  rescue
    ArgumentError -> empty_item_usage()
  catch
    :exit, _ -> empty_item_usage()
  end

  defp add_item_usage(table, item, run_id, delta, price) do
    key = {:item_usage, item}

    previous =
      case :dets.lookup(table, key) do
        [{^key, value}] ->
          value

        _ ->
          %{
            usd_micro: 0,
            usd_numerator: 0,
            total_tokens: 0,
            unpriced_tokens: 0,
            runs: MapSet.new(),
            since: Date.utc_today() |> Date.to_iso8601()
          }
      end

    total =
      max(
        Map.get(delta, :input_tokens, 0) + Map.get(delta, :output_tokens, 0),
        Map.get(delta, :total_tokens, 0)
      )

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

  defp do_usage(table, run_id, model, delta, rates) do
    date = Date.utc_today() |> Date.to_iso8601()
    key = {:usage, run_id, date, model || "unknown"}

    previous =
      case :dets.lookup(table, key) do
        [{^key, value}] -> value
        _ -> empty_usage()
      end

    value = priced_usage(previous, delta, rates, model)
    :ok = :dets.insert(table, {key, value})

    if value.price_rates,
      do: value.usd_numerator - Map.get(previous, :usd_numerator, previous.usd_micro * 1_000_000)
  end

  defp priced_usage(previous, delta, rates, model) do
    input = max(0, Map.get(delta, :input_tokens, 0))

    cached_total =
      min(
        previous.input_tokens + input,
        previous.cached_input_tokens + max(0, Map.get(delta, :cached_input_tokens, 0))
      )

    cached = cached_total - previous.cached_input_tokens
    output = max(0, Map.get(delta, :output_tokens, 0))
    total = max(input + output, Map.get(delta, :total_tokens, 0))

    price_rates =
      case Map.fetch(previous, :price_rates) do
        {:ok, recorded} -> recorded
        :error -> Map.get(rates, model)
      end

    price = price_numerator(%{model => price_rates}, model, input, cached, output)
    price_total = Map.get(previous, :usd_numerator, previous.usd_micro * 1_000_000) + (price || 0)

    value = %{
      input_tokens: previous.input_tokens + input,
      cached_input_tokens: cached_total,
      cache_write_input_tokens: Map.get(previous, :cache_write_input_tokens, 0) + max(0, Map.get(delta, :cache_write_input_tokens, 0)),
      output_tokens: previous.output_tokens + output,
      reasoning_output_tokens: Map.get(previous, :reasoning_output_tokens, 0) + max(0, Map.get(delta, :reasoning_output_tokens, 0)),
      total_tokens: previous.total_tokens + total,
      usd_micro: div(price_total, 1_000_000),
      usd_numerator: price_total,
      price_rates: price_rates,
      unpriced_tokens: previous.unpriced_tokens + if(is_nil(price), do: total, else: 0)
    }

    value
  end

  @spec event(handle(), String.t(), map()) :: :ok
  def event(nil, _kind, _details), do: :ok

  def event(table, kind, details) do
    safe_write(fn ->
      details = correlate_item(table, kind, details)
      transition = pull_transition(table, kind, details)
      if transition, do: record_event(table, transition, details)

      if kind == "pr_merged" do
        record_event(table, "item_disposition", Map.put(details, :disposition, "merged"))
      end
    end)
  end

  @doc "Records a terminal item's scoped disposition; ordinary closure is unknown acceptance."
  @spec disposition(handle(), map(), String.t()) :: :ok
  def disposition(table, issue, prefix \\ "crescendo") do
    disposition =
      cond do
        issue[:state_reason] == "not_planned" -> "retirement"
        "#{prefix}:delivery:verified-existing" in issue.labels -> "verified_existing"
        "#{prefix}:delivery:split" in issue.labels -> "split"
        true -> "unknown"
      end

    event(table, "item_disposition", %{
      issue_identifier: issue.identifier,
      issue_url: issue.url,
      disposition: disposition,
      summary: "Terminal item: #{disposition}"
    })
  end

  defp correlate_item(table, kind, details) do
    identifier = details[:issue_identifier] || if(details[:pr_number], do: "PR-#{details.pr_number}")
    details = if identifier, do: Map.put(details, :issue_identifier, identifier), else: details

    if kind in ["attempt_failed", "blocked", "item_disposition", "retired", "pr_merged"] do
      case :dets.lookup(table, {:item_run, identifier}) do
        [{_key, run}] -> Map.merge(run, details)
        _ -> details
      end
    else
      details
    end
  end

  defp pull_transition(table, kind, %{pr_number: number})
       when kind in ["pr_opened", "pr_closed", "pr_merged"] do
    previous = :dets.lookup(table, {:pull_transition, number})
    :ok = :dets.insert(table, {{:pull_transition, number}, kind})

    case {kind, previous} do
      {"pr_opened", [{{:pull_transition, ^number}, "pr_closed"}]} -> "pr_reopened"
      {^kind, [{{:pull_transition, ^number}, ^kind}]} -> nil
      _ -> kind
    end
  end

  defp pull_transition(_table, kind, _details), do: kind

  defp record_event(table, kind, details) do
    key = fact_key(kind, details)

    if is_nil(key) or :dets.lookup(table, key) == [] do
      do_event(table, kind, details, key)
      sync(table)
    end
  end

  defp fact_key("item_disposition", %{issue_identifier: item, disposition: disposition})
       when disposition in ["merged", "verified_existing", "split"], do: {:accepted_delivery, item}

  defp fact_key("item_disposition", %{issue_identifier: item, disposition: disposition}),
    do: {:disposition, item, disposition}

  defp fact_key(kind, %{issue_identifier: item, item_attempt: attempt} = details)
       when kind in ["attempt_failed", "blocked"] and is_integer(attempt),
       do: {:blocked_attempt, item, attempt, details[:run_id]}

  defp fact_key("blocked", %{issue_identifier: item, run_id: run_id}) when is_binary(run_id),
    do: {:blocked_run, item, run_id}

  defp fact_key(_kind, _details), do: nil

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

  @doc "Records an image a run stored, for the dashboard's picture timeline."
  @spec record_image(handle(), map()) :: :ok
  def record_image(nil, _image), do: :ok

  def record_image(table, image) do
    safe_write(fn ->
      sequence =
        case :dets.lookup(table, :image_sequence) do
          [{:image_sequence, value}] -> value + 1
          _ -> 1
        end

      entry =
        image
        |> Map.take([:src, :issue_identifier, :issue_url, :title])
        |> Map.put(:at, DateTime.utc_now() |> DateTime.to_iso8601())

      :ok = :dets.insert(table, [{:image_sequence, sequence}, {{:image, sequence}, entry}])
      :dets.delete(table, {:image, sequence - @image_limit})
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

  @doc "Durable startup admission failures, independent of delivery attempts."
  @spec startup_state(handle()) :: map()
  def startup_state(nil), do: %{}
  def startup_state(table), do: lookup(table, :startup, %{})

  @spec save_startup_state(handle(), map()) :: :ok
  def save_startup_state(nil, _state), do: :ok

  def save_startup_state(table, state) do
    safe_write(fn ->
      :ok = :dets.insert(table, {:startup, state})
      sync(table)
    end)
  end

  @empty_autopilot %{pr_handled: %{}, tasks: %{}, item_attempts: %{}, handoff_owners: %{}, retired_items: %{}}

  @doc """
  Autopilot memory that must survive restarts: the head commit and run count
  per pull request, each autopilot task's last finish, attempts and retry
  time, and each item's failed attempts. State saved before per-task
  schedules starts every task fresh.
  """
  @spec autopilot_state(handle()) :: SymphonyElixir.Autopilot.state()
  def autopilot_state(nil), do: @empty_autopilot

  def autopilot_state(table) do
    case :dets.lookup(table, :autopilot) do
      [{:autopilot, %{} = state}] -> Map.merge(@empty_autopilot, Map.take(state, Map.keys(@empty_autopilot)))
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

    usage_rows(table)
    |> Enum.filter(fn {{_, date, _, _}, _} -> date == today end)
    |> Enum.reduce(0, fn {_, value}, acc -> value.usd_micro + acc end)
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

  defp do_event(table, kind, details, key) do
    sequence =
      case :dets.lookup(table, :sequence) do
        [{:sequence, value}] -> value + 1
        _ -> 1
      end

    entry =
      details
      |> Map.take([
        :issue_identifier,
        :issue_url,
        :pr_number,
        :pr_url,
        :summary,
        :model,
        :title,
        :category,
        :seconds,
        :usd_micro,
        :run_id,
        :item_attempt,
        :startup,
        :startup_attempt,
        :issue_id,
        :worker_host,
        :worker_pid,
        :disposition
      ])

    entry = Map.merge(entry, %{kind: kind, at: DateTime.utc_now() |> DateTime.to_iso8601()})
    records = [{:sequence, sequence}, {{:event, sequence}, entry}]
    :ok = :dets.insert(table, if(key, do: [{key, true} | records], else: records))
    if sequence > @event_limit, do: :dets.delete(table, {:event, sequence - @event_limit})
    :ok
  end

  def snapshot(table, opts \\ [])

  @spec snapshot(handle(), keyword()) :: map()
  def snapshot(nil, _opts) do
    %{
      status: "unavailable",
      pricing_as_of: @price_date,
      cost_basis: "api_equivalent_estimate",
      account_usage: empty_account(),
      accounting: %{terminal_observed: 0, incomplete: 0, helper_usage_coverage: "unknown"},
      delivery_metrics: empty_delivery_metrics(),
      today: empty_usage(),
      recorded: empty_usage(),
      by_model: [],
      activity: [],
      daily: daily_series(%{}, []),
      samples: [],
      median_run_seconds: %{},
      by_task: [],
      images: []
    }
  end

  def snapshot(table, opts) do
    do_snapshot(table, opts)
  rescue
    error ->
      Logger.warning("Operations history read failed: #{Exception.message(error)}")
      snapshot(nil)
  catch
    :exit, reason ->
      Logger.warning("Operations history read failed: #{inspect(reason)}")
      snapshot(nil)
  end

  defp do_snapshot(table, opts) do
    today = Date.utc_today() |> Date.to_iso8601()

    {recorded, daily, by_model, model_runs, events, spend, samples} =
      :dets.foldl(
        fn
          {{:task, run}, task}, {all, day, models, runs, events, spend, samples} ->
            {all, day, models, runs, events, spend, [{:task, {run, task}} | samples]}

          {{:image, sequence}, image}, {all, day, models, runs, events, spend, samples} ->
            {all, day, models, runs, events, spend, [{:image, sequence, image} | samples]}

          {{:usage, run, date, model}, value}, {all, day, models, runs, events, spend, samples} ->
            fold_usage(
              {run, date, model, nil},
              value,
              {all, day, models, runs, events, spend, samples},
              today
            )

          {{:thread_usage, _}, %{allocations: allocations}}, acc ->
            Enum.reduce(allocations, acc, fn {key, value}, acc -> fold_usage(key, value, acc, today) end)

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

    costs = current_run_costs(table)

    ordered_events =
      events
      |> Enum.sort_by(fn {sequence, _} -> sequence end)
      |> Enum.map(fn {_sequence, event} ->
        event
        |> Map.put(:attribution, if(event[:run_id], do: "recorded", else: "unknown"))
        |> current_accounting(table, costs)
      end)

    # Task and image records ride in the samples accumulator, tagged (sample buckets are integers).
    {tasks, samples} = Enum.split_with(samples, &match?({:task, _}, &1))
    {images, samples} = Enum.split_with(samples, &match?({:image, _, _}, &1))

    %{
      status: "ok",
      pricing_as_of: @price_date,
      cost_basis: "api_equivalent_estimate",
      account_usage: account_snapshot(table),
      accounting: accounting_summary(table),
      delivery_metrics: delivery_snapshot(table),
      today: daily,
      recorded: recorded,
      by_model:
        by_model
        |> Enum.map(fn {model, usage} ->
          usage |> Map.put(:model, model) |> Map.put(:runs, model_runs |> Map.fetch!(model) |> MapSet.size())
        end)
        |> Enum.sort_by(& &1.model),
      activity: ordered_events |> Enum.reverse() |> Enum.take(if(opts[:history], do: @event_limit, else: 100)),
      daily: daily_series(spend, ordered_events),
      samples:
        recent_samples(
          samples,
          if(opts[:history], do: @sample_retention_buckets, else: @sample_window_buckets)
        ),
      median_run_seconds: median_run_seconds(ordered_events),
      by_task: by_task(tasks_with_current_cost(costs, tasks)),
      images: recent_images(images)
    }
  end

  defp current_accounting(%{run_id: id} = event, table, costs) do
    run = lookup(table, {:lineage_run, id}, %{})

    event
    |> Map.put(:accounting_status, run[:accounting_status] || "incomplete")
    |> Map.put(:cache_write_status, run[:cache_write_status] || "unknown")
    |> Map.put(:usd_micro, Map.get(costs, id, 0))
  end

  defp current_accounting(event, _table, _costs), do: event

  defp accounting_summary(table) do
    :dets.match_object(table, {{:lineage_run, :_}, :_})
    |> Enum.reduce(%{terminal_observed: 0, incomplete: 0, helper_usage_coverage: "unknown"}, fn {_, run}, acc ->
      field = if run[:accounting_status] == "terminal_observed", do: :terminal_observed, else: :incomplete
      Map.update!(acc, field, &(&1 + 1))
    end)
  end

  defp current_run_costs(table) do
    Enum.reduce(usage_rows(table), %{}, fn {{run, _, _, _}, value}, acc ->
      Map.update(acc, run, value.usd_micro, &(&1 + value.usd_micro))
    end)
  end

  defp tasks_with_current_cost(costs, tasks) do
    Enum.map(tasks, fn {:task, {run, task}} ->
      Map.put(task, :usd_micro, Map.get(costs, run, task.usd_micro))
    end)
  end

  defp fold_usage({run, date, model, _}, value, {all, day, models, runs, events, spend, samples}, today) do
    models = Map.update(models, model, add_usage(empty_usage(), value), &add_usage(&1, value))
    runs = Map.update(runs, model, MapSet.new([run]), &MapSet.put(&1, run))
    spend = Map.update(spend, {date, model}, value.usd_micro, &(&1 + value.usd_micro))
    day = if date == today, do: add_usage(day, value), else: day
    {add_usage(all, value), day, models, runs, events, spend, samples}
  end

  defp empty_account,
    do: %{
      coverage: "incomplete",
      threads_recorded: 0,
      threads_observed: 0,
      threads_covered: 0,
      estimated_credits_micros: nil,
      estimated_usd_micros: nil
    }

  defp account_snapshot(table) do
    records = :dets.match_object(table, {{:account_usage, :_}, :_})
    known = for {_, %{usage: usage}} <- records, is_map(usage), do: usage
    observed = for {{:account_usage, id}, _} <- records, do: id
    threads = for {{:thread_context, id}, _} <- :dets.match_object(table, {{:thread_context, :_}, :_}), do: id
    count = length(Enum.uniq(threads ++ observed))

    %{
      coverage: if(count > 0 and count == length(known), do: "complete", else: "incomplete"),
      threads_recorded: count,
      threads_observed: length(records),
      threads_covered: length(known),
      estimated_credits_micros: if(known == [], do: nil, else: Enum.sum(Enum.map(known, & &1["estimatedUsageCreditsMicros"]))),
      estimated_usd_micros: known_usd(known)
    }
  end

  defp known_usd([]), do: nil

  defp known_usd(known) do
    if Enum.all?(known, &(is_integer(&1["estimatedUsageUsdMicros"]) and &1["estimatedUsageUsdMicros"] >= 0)),
      do: Enum.sum(Enum.map(known, & &1["estimatedUsageUsdMicros"]))
  end

  defp empty_delivery_metrics,
    do: %{
      status: "incomplete_delivery_lineage",
      accepted_delivery_cost: nil,
      accepted_delivery_latency: nil,
      verified_deliveries: nil,
      runs_recorded: 0,
      review_heads_recorded: 0,
      thread_links: 0,
      helper_usage_coverage: "unknown"
    }

  defp delivery_snapshot(table) do
    runs = for {_, run} <- :dets.match_object(table, {{:lineage_run, :_}, :_}), do: run
    threads = for {_, thread} <- :dets.match_object(table, {{:thread_context, :_}, :_}), do: thread
    evidence = :dets.match_object(table, {{:lineage_evidence, :_, :_}, :_})

    merges =
      Enum.count(evidence, fn {key, value} ->
        elem(key, 1) == "pull_request" and value[:status] == "merged"
      end)

    research = Enum.count(evidence, fn {key, _} -> elem(key, 1) == "research" end)

    empty_delivery_metrics()
    |> Map.merge(%{
      runs_recorded: length(runs),
      review_heads_recorded: Enum.count(runs, &is_binary(&1[:review_head])),
      thread_links: Enum.sum(Enum.map(threads, &MapSet.size(&1.runs))),
      merge_observations: merges,
      research_associations: research
    })
  end

  # Newest first; ISO 8601 UTC times compare as strings.
  defp recent_images(images) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@image_days * 86_400, :second) |> DateTime.to_iso8601()

    images
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.map(&elem(&1, 2))
    |> Enum.filter(&(to_string(&1[:at]) > cutoff))
    |> Enum.take(120)
  end

  # Totals per model and task category over the retained two weeks of tasks;
  # `timed` counts the runs whose duration is known, for the average time.
  defp by_task(tasks) do
    tasks
    |> Enum.group_by(&{&1.model, &1.category})
    |> Enum.map(fn {{model, category}, group} ->
      timed = for %{seconds: seconds} when is_integer(seconds) <- group, do: seconds

      %{
        model: model,
        category: category,
        runs: length(group),
        usd_micro: group |> Enum.map(& &1.usd_micro) |> Enum.sum(),
        timed: length(timed),
        seconds: Enum.sum(timed)
      }
    end)
    |> Enum.sort_by(&{&1.model, &1.category})
  end

  # Five-minute samples, oldest first; the dashboard uses twelve hours, history uses the retained two days.
  defp recent_samples(samples, window_buckets) do
    newest = div(System.os_time(:second), @sample_seconds)

    samples
    |> Enum.filter(fn {bucket, _sample} -> bucket > newest - window_buckets end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {bucket, sample} ->
      Map.put(sample, :at, DateTime.from_unix!(bucket * @sample_seconds) |> DateTime.to_iso8601())
    end)
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

  defp pair_event("dispatch", identifier, at, {durations, open}, _cutoff),
    do: {durations, Map.put(open, identifier, at)}

  defp pair_event(kind, identifier, at, {durations, open}, cutoff)
       when kind in @finish_kinds and is_map_key(open, identifier) do
    seconds = DateTime.diff(at, Map.fetch!(open, identifier))
    recent? = DateTime.compare(at, cutoff) == :gt

    {if(recent?, do: add_duration(durations, identifier, seconds), else: durations), Map.delete(open, identifier)}
  end

  defp pair_event(_kind, _identifier, _at, acc, _cutoff), do: acc

  defp add_duration(durations, identifier, seconds),
    do: Map.update(durations, item_kind(identifier), [seconds], &[seconds | &1])

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
    "stopped" => :stopped,
    "attempt_failed" => :blocked_attempts,
    "blocked" => :blocked_attempts,
    "retired" => :retirements,
    "issue_terminal" => :unknown_dispositions,
    "pr_merged" => :merged,
    "pr_closed" => :closed
  }

  @dispositions %{
    "merged" => :accepted_deliveries,
    "verified_existing" => :accepted_deliveries,
    "split" => :accepted_deliveries,
    "retirement" => :retirements,
    "unknown" => :unknown_dispositions
  }

  # Counts cover the retained event ring; PR closures are transitions, not abandonment.
  defp daily_series(spend, events) do
    today = Date.utc_today()
    dates = for offset <- (@series_days - 1)..0//-1, do: today |> Date.add(-offset) |> Date.to_iso8601()

    outcomes =
      Enum.reduce(events, %{}, fn event, acc ->
        with kind when is_atom(kind) <- series_kind(event),
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
        stopped: Map.get(outcomes, {date, :stopped}, 0),
        blocked_attempts: Map.get(outcomes, {date, :blocked_attempts}, 0),
        accepted_deliveries: Map.get(outcomes, {date, :accepted_deliveries}, 0),
        retirements: Map.get(outcomes, {date, :retirements}, 0),
        unknown_dispositions: Map.get(outcomes, {date, :unknown_dispositions}, 0),
        merged: Map.get(outcomes, {date, :merged}, 0),
        closed: Map.get(outcomes, {date, :closed}, 0)
      }
    end)
  end

  defp series_kind(%{kind: "item_disposition", disposition: disposition}), do: @dispositions[disposition]
  defp series_kind(event), do: @outcome_kinds[event[:kind]]

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
      finish_run(
        table,
        id,
        "interrupted",
        Map.put(run, :summary, "Worker interrupted by a Crescendo restart")
      )
    end)
  end

  defp empty_usage,
    do: %{
      input_tokens: 0,
      cached_input_tokens: 0,
      cache_write_input_tokens: 0,
      output_tokens: 0,
      reasoning_output_tokens: 0,
      total_tokens: 0,
      usd_micro: 0,
      unpriced_tokens: 0
    }

  defp add_usage(left, right) do
    Map.new(left, fn {key, value} -> {key, value + Map.get(right, key, 0)} end)
  end

  defp price_numerator(rates, model, input, cached, output) do
    case Map.get(rates, model) do
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
