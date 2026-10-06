defmodule SymphonyElixirWeb.ServiceSnapshot do
  @moduledoc """
  One snapshot for a service: each project's orchestrator snapshot merged,
  with every item tagged by its `project`, so the dashboard and the state API
  read a service the way they read a single project. What projects share
  (slots, the budget, the Codex quota) comes from the Governor's snapshot.
  """

  @doc "Merges `{project, snapshot}` pairs; `governor` is the Governor's snapshot, if any."
  @spec merge([{String.t(), map() | :timeout | :unavailable}], map() | nil, keyword()) :: map()
  def merge(results, governor, opts \\ []) do
    {snapshots, failed} = Enum.split_with(results, fn {_id, result} -> is_map(result) end)

    %{
      snapshot_status: if(failed == [], do: "complete", else: "partial"),
      snapshot_errors: Enum.map(failed, fn {id, status} -> %{project: id, status: to_string(status)} end),
      running: tagged(snapshots, :running),
      retrying: tagged(snapshots, :retrying),
      blocked: tagged(snapshots, :blocked),
      codex_totals: snapshots |> Enum.map(fn {_id, snapshot} -> snapshot[:codex_totals] || %{} end) |> sum(),
      operations: operations(snapshots, opts),
      operations_error: joined(snapshots, fn snapshot -> snapshot[:operations_error] end),
      upcoming: upcoming(snapshots, governor),
      autopilot: autopilot(snapshots),
      pull_requests: pull_requests(snapshots),
      rate_limits: nil,
      quota: (governor && governor.quota) || newest_quota(snapshots),
      throttle: throttle(governor),
      polling: polling(snapshots)
    }
  end

  defp tagged(snapshots, key) do
    for {id, snapshot} <- snapshots, entry <- Map.get(snapshot, key) || [], do: Map.put(entry, :project, id)
  end

  # Ready work interleaves across projects (the order it would run in with
  # equal weights); everything else keeps each project's own order.
  defp upcoming(snapshots, governor) do
    upcomings = for {id, snapshot} <- snapshots, upcoming = snapshot[:upcoming], do: {id, upcoming}
    ready = Enum.map(upcomings, fn {id, upcoming} -> Enum.map(upcoming.ready, &Map.put(&1, :project, id)) end)

    %{
      ready: interleave(ready),
      waiting: for({id, upcoming} <- upcomings, item <- upcoming.waiting, do: Map.put(item, :project, id)),
      observed_at: oldest(Enum.map(upcomings, fn {_id, upcoming} -> upcoming.observed_at end)),
      error: joined(snapshots, fn snapshot -> get_in(snapshot, [:upcoming, :error]) end),
      available_slots: available_slots(governor, upcomings)
    }
  end

  defp available_slots(%{slots: slots, busy: busy}, _upcomings), do: max(slots - busy, 0)

  defp available_slots(_governor, upcomings),
    do: upcomings |> Enum.map(fn {_id, upcoming} -> upcoming.available_slots || 0 end) |> Enum.sum()

  defp interleave(lists) do
    case Enum.reject(lists, &(&1 == [])) do
      [] -> []
      lists -> Enum.map(lists, &hd/1) ++ interleave(Enum.map(lists, &tl/1))
    end
  end

  # Research is per project: channels and pending channels are named
  # `project/channel`, backlogs add up, and the soonest next round shows.
  defp autopilot(snapshots) do
    autopilots = for {id, snapshot} <- snapshots, autopilot = snapshot[:autopilot], do: {id, autopilot}

    named = fn key ->
      for {id, autopilot} <- autopilots, channel <- Map.get(autopilot, key) || [], do: "#{id}/#{channel}"
    end

    total = fn key ->
      autopilots |> Enum.map(fn {_id, autopilot} -> Map.get(autopilot, key) || 0 end) |> Enum.sum()
    end

    %{
      enabled: Enum.any?(autopilots, fn {_id, autopilot} -> autopilot[:enabled] == true end),
      channels: named.(:channels),
      research_pending: named.(:research_pending),
      research_running: total.(:research_running),
      open_issues: total.(:open_issues),
      max_open_issues: total.(:max_open_issues),
      research_finished_at: nil,
      next_research_at: autopilots |> Enum.map(fn {_id, autopilot} -> autopilot[:next_research_at] end) |> oldest(),
      tasks:
        for(
          {id, autopilot} <- autopilots,
          task <- Map.get(autopilot, :tasks) || [],
          do: Map.put(task, :project, id)
        ),
      repos: for({id, autopilot} <- autopilots, repo = autopilot[:repo], into: %{}, do: {id, repo})
    }
  end

  defp pull_requests(snapshots) do
    pulls = for {id, snapshot} <- snapshots, pulls = snapshot[:pull_requests], do: {id, pulls}

    %{
      items: for({id, pulls} <- pulls, item <- pulls.items || [], do: Map.put(item, :project, id)),
      observed_at: pulls |> Enum.map(fn {_id, pulls} -> pulls.observed_at end) |> oldest(),
      error: joined(snapshots, fn snapshot -> get_in(snapshot, [:pull_requests, :error]) end),
      enabled: Enum.any?(pulls, fn {_id, pulls} -> pulls.enabled == true end)
    }
  end

  defp polling(snapshots) do
    polls = for {_id, snapshot} <- snapshots, polling = snapshot[:polling], do: polling

    %{
      checking?: Enum.any?(polls, &(&1[:checking?] == true)),
      next_poll_in_ms: polls |> Enum.map(& &1[:next_poll_in_ms]) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end),
      poll_interval_ms: polls |> Enum.map(& &1[:poll_interval_ms]) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end)
    }
  end

  # The Governor's policy plus the service's slot use.
  defp throttle(%{throttle: throttle, slots: slots, busy: busy} = governor),
    do: throttle |> Map.merge(%{service_slots: slots, busy: busy}) |> Map.merge(Map.take(governor, [:research_hold, :draining]))

  defp throttle(_governor), do: nil

  defp newest_quota(snapshots) do
    snapshots
    |> Enum.map(fn {_id, snapshot} -> snapshot[:quota] end)
    |> Enum.filter(&match?(%{observed_at: %DateTime{}}, &1))
    |> Enum.max_by(& &1.observed_at, DateTime, fn -> nil end)
  end

  defp operations(snapshots, opts) do
    ops = for {id, snapshot} <- snapshots, operations = snapshot[:operations], do: {id, operations}
    all = Enum.map(ops, &elem(&1, 1))

    %{
      status: if(all != [] and Enum.all?(all, &(&1.status == "ok")), do: "ok", else: "unavailable"),
      pricing_as_of: all |> Enum.map(& &1[:pricing_as_of]) |> Enum.find(& &1),
      cost_basis: "api_equivalent_estimate",
      account_usage: account_usage(all),
      accounting: accounting(all),
      delivery_metrics: delivery_metrics(all),
      today: all |> Enum.map(&(&1[:today] || %{})) |> sum(),
      recorded: all |> Enum.map(&(&1[:recorded] || %{})) |> sum(),
      by_model: by_model(all),
      activity: activity(ops, opts),
      daily: daily(all),
      samples: samples(all),
      median_run_seconds: medians(all),
      by_task: by_task(all),
      images: images(ops),
      by_project: Enum.map(ops, fn {id, operations} -> project_spend(id, operations) end)
    }
  end

  defp accounting(all) do
    counts = all |> Enum.map(&Map.take(&1[:accounting] || %{}, [:terminal_observed, :incomplete])) |> sum()
    Map.merge(%{terminal_observed: 0, incomplete: 0, helper_usage_coverage: "unknown"}, counts)
  end

  defp account_usage(all) do
    records = Enum.map(all, &Map.get(&1, :account_usage, %{}))
    counts = sum(Enum.map(records, &Map.take(&1, [:threads_recorded, :threads_observed, :threads_covered])))

    Map.merge(%{threads_recorded: 0, threads_observed: 0, threads_covered: 0}, counts)
    |> Map.put(
      :coverage,
      if(records != [] and Enum.all?(records, &(&1[:coverage] == "complete")),
        do: "complete",
        else: "incomplete"
      )
    )
    |> Map.put(:estimated_credits_micros, known_sum(records, :estimated_credits_micros))
    |> Map.put(:estimated_usd_micros, known_sum(records, :estimated_usd_micros))
  end

  defp known_sum(records, field) do
    known =
      Enum.flat_map(records, fn record -> if is_integer(record[field]), do: [record[field]], else: [] end)

    if known != [], do: Enum.sum(known)
  end

  defp delivery_metrics(all) do
    counts =
      all
      |> Enum.map(
        &Map.take(Map.get(&1, :delivery_metrics, %{}), [
          :runs_recorded,
          :review_heads_recorded,
          :thread_links,
          :merge_observations,
          :research_associations
        ])
      )
      |> sum()

    Map.merge(
      %{
        status: "incomplete_delivery_lineage",
        accepted_delivery_cost: nil,
        accepted_delivery_latency: nil,
        verified_deliveries: nil,
        helper_usage_coverage: "unknown"
      },
      counts
    )
  end

  defp by_model(all) do
    all
    |> Enum.flat_map(&(&1[:by_model] || []))
    |> Enum.group_by(& &1.model)
    |> Enum.map(fn {_model, rows} -> sum(rows) end)
    |> Enum.sort_by(& &1.model)
  end

  defp by_task(all) do
    all
    |> Enum.flat_map(&(&1[:by_task] || []))
    |> Enum.group_by(&{&1.model, &1.category})
    |> Enum.map(fn {_key, rows} -> sum(rows) end)
    |> Enum.sort_by(&{&1.model, &1.category})
  end

  defp images(ops) do
    ops
    |> Enum.flat_map(fn {id, operations} ->
      Enum.map(operations[:images] || [], &Map.put(&1, :project, id))
    end)
    |> Enum.sort_by(&to_string(&1[:at]), :desc)
    |> Enum.take(120)
  end

  defp activity(ops, opts) do
    events =
      ops
      |> Enum.flat_map(fn {id, operations} ->
        Enum.map(operations[:activity] || [], &Map.put(&1, :project, id))
      end)
      |> Enum.sort_by(&to_string(&1[:at]), :desc)

    if opts[:history], do: events, else: Enum.take(events, 100)
  end

  defp daily(all) do
    all
    |> Enum.flat_map(&(&1[:daily] || []))
    |> Enum.group_by(& &1.date)
    |> Enum.map(fn {_date, days} ->
      %{sum(days) | spend_by_model: days |> Enum.map(& &1.spend_by_model) |> sum()}
    end)
    |> Enum.sort_by(& &1.date)
  end

  defp samples(all) do
    all
    |> Enum.flat_map(&(&1[:samples] || []))
    |> Enum.group_by(& &1[:at])
    |> Enum.map(fn {_at, samples} -> sum(samples) end)
    |> Enum.sort_by(&to_string(&1[:at]))
  end

  defp medians(all) do
    all
    |> Enum.flat_map(&Map.to_list(&1[:median_run_seconds] || %{}))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {kind, values} -> {kind, div(Enum.sum(values), length(values))} end)
  end

  defp project_spend(id, operations) do
    %{
      project: id,
      today_usd_micro: get_in(operations, [:today, :usd_micro]) || 0,
      days_usd_micro: (operations[:daily] || []) |> Enum.flat_map(&Map.values(&1.spend_by_model)) |> Enum.sum()
    }
  end

  # Adds maps key by key: numbers add, anything else keeps the first value.
  defp sum(maps) do
    Enum.reduce(maps, %{}, fn map, acc ->
      Map.merge(acc, map, fn
        _key, left, right when is_number(left) and is_number(right) -> left + right
        _key, left, _right -> left
      end)
    end)
  end

  defp oldest(values) do
    values
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.min_by(& &1, DateTime, fn -> nil end)
  end

  defp joined(snapshots, get) do
    case for({id, snapshot} <- snapshots, error = get.(snapshot), is_binary(error), do: "#{id}: #{error}") do
      [] -> nil
      errors -> Enum.join(errors, "; ")
    end
  end
end
