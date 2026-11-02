defmodule SymphonyElixirWeb.IssueBoard do
  @moduledoc """
  A read-only issue view of an already-redacted Presenter payload.

  UTC day selection hides older terminal cards without changing retained data.
  Missing run IDs, parent links and media/run lineage remain unavailable.
  """

  alias SymphonyElixirWeb.{DashboardComponents, Timeline}

  @lanes [{"intake", "Intake"}, {"active", "Active"}, {"done", "Done"}]
  @shows ["delivery", "review", "autopilot", "prs"]
  @issue_events ["issue_terminal", "retired", "pr_merged", "pr_closed"]
  @terminal_events @issue_events ++ ["task_delivered", "task_short"]
  @lifecycle_events @terminal_events ++ ["dispatch", "pr_opened", "pr_reopened"]
  @run_outcomes ["completed", "failed", "stopped", "interrupted", "deferred"]
  @run_fields ~w(run_id status item_attempt started_s finished_s started_at model kind issue_identifier project)a

  @doc "Builds current cards plus the selected UTC day's terminal and unresolved history."
  @spec build(map(), Date.t() | String.t()) :: map()
  def build(payload, date) do
    day = day(date) || Date.to_iso8601(Date.utc_today())
    associations = get_in(payload, [:usage, :delivery_metrics, :issue_associations]) || []
    rows = current_rows(payload)
    index = identity_index(associations ++ Enum.map(rows, &elem(&1, 1)))
    pulls = pull_index(associations, index)

    cards =
      associations
      |> Enum.map(&{:delivery, &1})
      |> Enum.concat(rows)
      |> Enum.reduce(%{}, fn {source, row}, cards -> add(cards, source, row, index, pulls) end)

    {cards, unassigned_events} = add_events(cards, get_in(payload, [:usage, :activity]) || [], index, pulls)
    {cards, unassigned_helpers} = add_helpers(cards, payload[:helpers] || [])
    {cards, unassigned_reports} = add_reports(cards, get_in(payload, [:usage, :external, :observations]) || [])
    cards = add_media(cards, get_in(payload, [:usage, :images]) || [], index, pulls)

    Map.merge(day_view(cards, day), %{
      partial: payload[:snapshot_status] == "partial" or not is_nil(payload[:error]),
      unassigned_events: unassigned_events,
      unassigned_helpers: unassigned_helpers,
      unassigned_reports: unassigned_reports
    })
  end

  @doc "Applies the existing Show groups to cards; it does not filter service-wide metrics."
  @spec filter(map(), String.t() | nil) :: map()
  def filter(board, show) when show in @shows do
    cards = Enum.filter(board.cards, &(show in &1.groups))
    undated = Enum.filter(board.undated_cards, &(show in &1.groups))
    history = Enum.filter(board.history_cards, &(show in &1.groups))
    %{board | cards: cards, lanes: lanes(cards), counts: counts(cards), undated_cards: undated, history_cards: history}
  end

  def filter(board, _show), do: board

  @doc "Selects an observed card by its opaque project-scoped key."
  @spec select(map(), String.t() | nil) :: map() | nil
  def select(board, key), do: Enum.find(board.cards ++ board.history_cards ++ board.undated_cards, &(&1.key == key))

  defp day_view(cards, day) do
    all = cards |> Map.values() |> Enum.map(&finish/1) |> Enum.sort_by(&{&1.project || "", &1.issue_identifier})
    visible = Enum.filter(all, &(&1.lane in ["intake", "active"] or &1.done_day == day))

    %{
      date: day,
      days: [day | Enum.flat_map(all, &observed_days/1)] |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort(:desc),
      cards: visible,
      history_cards: Enum.filter(all, &(&1.lane == "history" and observed_on?(&1, day))),
      lanes: lanes(visible),
      counts: counts(visible),
      undated_cards: Enum.filter(all, &(&1.lane == "done" and is_nil(&1.done_day)))
    }
  end

  defp current_rows(payload) do
    [
      {:ready, get_in(payload, [:upcoming, :ready])},
      {:waiting, get_in(payload, [:upcoming, :waiting])},
      {:blocked, payload[:blocked]},
      {:retrying, payload[:retrying]},
      {:running, payload[:running]},
      {:pull_request, get_in(payload, [:pull_requests, :items])}
    ]
    |> Enum.flat_map(fn {source, rows} -> Enum.map(rows || [], &{source, &1}) end)
  end

  defp identity_index(rows) do
    rows
    |> Enum.filter(&is_binary(&1[:issue_identifier]))
    |> Enum.group_by(&{&1[:project], &1.issue_identifier})
    |> Map.new(fn {alias_key, rows} ->
      ids = rows |> Enum.map(& &1[:issue_id]) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      keys = Enum.map(ids, &{elem(alias_key, 0), {:issue, &1}})
      {alias_key, if(keys == [], do: [{elem(alias_key, 0), {:identifier, elem(alias_key, 1)}}], else: keys)}
    end)
  end

  defp pull_index(associations, index) do
    associations
    |> Enum.flat_map(fn association ->
      for source <- association[:sources] || [],
          is_integer(source[:pr_number]),
          key = identity(association, index),
          not is_nil(key),
          do: {{association[:project], source.pr_number}, key}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {pull, owners} ->
      {pull,
       case Enum.uniq(owners) do
         [owner] -> owner
         _ambiguous -> nil
       end}
    end)
  end

  defp identity(%{issue_id: id} = row, _index) when not is_nil(id), do: {row[:project], {:issue, id}}

  defp identity(row, index) do
    case index[{row[:project], row[:issue_identifier]}] do
      [key] -> key
      nil -> identifier_key(row)
      _ambiguous -> nil
    end
  end

  defp identifier_key(%{issue_identifier: id} = row) when is_binary(id),
    do: {row[:project], {:identifier, id}}

  defp identifier_key(row) do
    case pr_number(row) do
      number when is_integer(number) -> {row[:project], {:identifier, "PR-#{number}"}}
      _ -> nil
    end
  end

  defp resolve(row, index, pulls), do: pulls[{row[:project], pr_number(row)}] || identity(row, index)
  defp pr_number(%{pr_number: number}) when is_integer(number), do: number
  defp pr_number(%{number: number}) when is_integer(number), do: number
  defp pr_number(%{issue_identifier: "PR-" <> number}), do: integer(number)
  defp pr_number(_row), do: nil

  defp integer(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp add(cards, source, row, index, pulls) do
    case resolve(row, index, pulls) do
      nil -> cards
      key -> Map.update(cards, key, add_row(new_card(key, row), source, row), &add_row(&1, source, row))
    end
  end

  defp new_card(key, row) do
    identifier = row[:issue_identifier] || pr_identifier(row)
    pull_url = if String.starts_with?(identifier, "PR-"), do: row[:pr_url] || row[:url]

    %{
      key: Base.url_encode64(:erlang.term_to_binary(key), padding: false),
      identity: key,
      project: row[:project],
      issue_id: row[:issue_id],
      issue_identifier: identifier,
      title: nil,
      issue_url: row[:issue_url] || pull_url,
      state: nil,
      labels: [],
      parent_issue: nil,
      delivery: nil,
      current_pull: nil,
      running: [],
      retrying: [],
      blocked: [],
      waiting: [],
      ready: [],
      helpers: [],
      external_reports: [],
      events: [],
      media: [],
      pull_requests: [],
      runs: %{},
      groups: []
    }
  end

  defp pr_identifier(row) do
    case pr_number(row) do
      number when is_integer(number) -> "PR-#{number}"
      _ -> "Unidentified item"
    end
  end

  defp add_row(card, :delivery, row) do
    card
    |> metadata(row)
    |> Map.put(:delivery, row)
    |> Map.put(:pull_requests, row[:sources] || [])
    |> add_runs(row[:attempts] || [])
  end

  defp add_row(card, :pull_request, row) do
    card
    |> Map.update!(:pull_requests, &[row | &1])
    |> Map.update!(:groups, &["prs" | &1])
    |> pull_metadata(row)
  end

  defp add_row(card, source, row) do
    card
    |> metadata(row)
    |> Map.update!(source, &[row | &1])
    |> Map.update!(:groups, &[Timeline.group(row[:issue_identifier]) | &1])
    |> add_runs(if(source == :running, do: [Map.put(row, :status, "running")], else: []))
  end

  defp metadata(card, row) do
    if is_nil(row[:issue_identifier]) or row[:issue_identifier] == card.issue_identifier,
      do: subject_metadata(card, row),
      else: card
  end

  defp subject_metadata(card, row) do
    card =
      Enum.reduce([:title, :issue_url, :state], card, fn field, card ->
        if is_nil(row[field]), do: card, else: Map.put(card, field, row[field])
      end)

    labels = Enum.filter(row[:labels] || [], &is_binary/1)
    %{card | issue_id: card.issue_id || row[:issue_id], labels: Enum.uniq(card.labels ++ labels)}
  end

  defp pull_metadata(%{issue_identifier: "PR-" <> _} = card, row) do
    card
    |> metadata(row)
    |> Map.put(:issue_url, row[:url] || row[:pr_url] || card.issue_url)
    |> Map.put(:current_pull, row)
  end

  defp pull_metadata(card, _row), do: card

  defp add_runs(card, rows) do
    runs =
      Enum.reduce(rows, card.runs, fn row, runs ->
        if is_binary(row[:run_id]), do: Map.update(runs, row.run_id, run(row), &merge_run(&1, run(row))), else: runs
      end)

    %{card | runs: runs}
  end

  defp run(row) do
    Map.take(row, @run_fields)
    |> then(fn run ->
      if is_nil(run[:status]) and row[:kind] in @run_outcomes,
        do: Map.put(run, :status, row.kind),
        else: run
    end)
  end

  defp merge_run(%{status: "running"} = known, observed), do: Map.merge(known, Map.delete(observed, :status))
  defp merge_run(known, observed), do: Map.merge(known, observed)

  defp add_events(cards, events, index, pulls) do
    Enum.reduce(events, {cards, []}, fn event, {cards, unassigned} ->
      case resolve(event, index, pulls) do
        nil ->
          {cards, [event | unassigned]}

        {_project, {:identifier, "helper-" <> _}} ->
          {cards, [event | unassigned]}

        key ->
          card = Map.get(cards, key, new_card(key, event))
          card = %{card | events: [event | card.events]} |> event_metadata(event) |> add_runs([event])
          {Map.put(cards, key, card), unassigned}
      end
    end)
  end

  defp event_metadata(card, event) do
    title = event[:title] || pull_title(card, event)
    card = if is_nil(card.title), do: %{card | title: title}, else: card
    groups = if event[:kind] in @issue_events or is_integer(event[:pr_number]), do: ["prs"], else: []
    %{card | groups: groups ++ [Timeline.group(event[:issue_identifier]) | card.groups]}
  end

  defp pull_title(%{issue_identifier: "PR-" <> _}, %{kind: "pr_" <> _} = event), do: event[:summary]
  defp pull_title(_card, _event), do: nil

  defp add_helpers(cards, helpers) do
    Enum.reduce(helpers, {cards, []}, fn helper, {cards, unassigned} ->
      key = {helper[:project], {:issue, helper[:parent_issue_id]}}

      case cards[key] do
        nil -> {cards, [helper | unassigned]}
        card -> {Map.put(cards, key, %{card | helpers: [helper | card.helpers]}), unassigned}
      end
    end)
  end

  defp add_reports(cards, reports) do
    Enum.reduce(reports, {cards, []}, fn report, {cards, unassigned} ->
      key = {report[:project], {:issue, report[:parent_issue_id]}}

      case cards[key] do
        nil ->
          {cards, [report | unassigned]}

        card ->
          {Map.put(cards, key, add_report(card, report)), unassigned}
      end
    end)
  end

  defp add_report(card, report) do
    groups = if report[:role] == "reviewer", do: ["review" | card.groups], else: card.groups
    %{card | external_reports: [report | card.external_reports], groups: groups}
  end

  defp add_media(cards, images, index, pulls) do
    Enum.reduce(images, cards, fn image, cards ->
      case resolve(image, index, pulls) do
        nil ->
          cards

        key ->
          card = Map.get(cards, key, new_card(key, image))
          card = %{card | title: card.title || image[:title], issue_url: card.issue_url || image[:issue_url]}
          Map.put(cards, key, %{card | media: [Map.put(image, :run_id, nil) | card.media]})
      end
    end)
  end

  defp finish(card) do
    events = Enum.sort_by(card.events, &to_string(&1[:at]), :desc)
    {lane, phase, closed_at} = placement(card, events)
    runs = card.runs |> Map.values() |> Enum.sort_by(&run_start/1)

    card
    |> Map.merge(%{
      lane: lane,
      phase: phase,
      done_day: day(closed_at),
      events: events,
      runs: runs,
      area: area(card.labels),
      pull_requests: Enum.uniq_by(card.pull_requests, &pr_number/1),
      run_count: if(runs == [], do: nil, else: length(runs)),
      run_count_scope: "observed unique run IDs; total coverage unavailable",
      summary: summary(card),
      acceptance: card.delivery && card.delivery[:acceptance_proof],
      disposition: card.delivery && card.delivery[:disposition],
      canonical_outcome_complete: card.delivery && card.delivery[:canonical_outcome_complete],
      review_verifications: (card.delivery && card.delivery[:report_verifications]) || [],
      merged: merged(card.pull_requests, events),
      groups: Enum.uniq(card.groups ++ issue_groups(card)),
      media: Enum.sort_by(card.media, &to_string(&1[:at]), :desc)
    })
    |> Map.delete(:identity)
  end

  defp placement(%{running: [_ | _]}, _events), do: {"active", "Agent running", nil}
  defp placement(%{retrying: [_ | _]}, _events), do: {"intake", "Retry scheduled", nil}
  defp placement(%{blocked: [_ | _]}, _events), do: {"intake", "Blocked", nil}
  defp placement(%{waiting: [entry | _]}, _events), do: {"intake", entry[:reason] || "Waiting", nil}
  defp placement(%{ready: [_ | _]}, _events), do: {"intake", "Ready", nil}

  defp placement(%{state: "closed", delivery: delivery}, _events) when is_map(delivery),
    do: {"done", "Issue closed", delivery[:closed_at]}

  defp placement(%{state: "open"}, _events), do: {"intake", "Current phase unavailable", nil}

  defp placement(%{delivery: delivery}, _events) when is_map(delivery),
    do: {"history", "Current issue status unavailable", nil}

  defp placement(%{current_pull: pull}, _events) when is_map(pull),
    do: {"intake", "Open pull request", nil}

  defp placement(_card, events) do
    case Enum.find(events, &(&1[:kind] in @lifecycle_events)) do
      %{kind: kind} = event when kind in @terminal_events -> {"done", terminal_label(kind), event[:at]}
      _ -> {"history", "Current issue status unavailable", nil}
    end
  end

  defp terminal_label("pr_merged"), do: "PR merged"
  defp terminal_label("pr_closed"), do: "PR closed; acceptance unavailable"
  defp terminal_label("retired"), do: "Retired"
  defp terminal_label("task_delivered"), do: "Task delivered"
  defp terminal_label("task_short"), do: "Task fell short"
  defp terminal_label(_kind), do: "Issue closed; acceptance unavailable"

  defp summary(%{running: [entry | _]}) do
    now = get_in(entry, [:workspace, :now])
    message = if is_map(now) and now[:kind] == "message", do: now[:text]
    message || get_in(entry, [:workspace, :said]) || entry[:last_message]
  end

  defp summary(%{blocked: [entry | _]}), do: entry[:error] || entry[:last_message]
  defp summary(%{retrying: [entry | _]}), do: entry[:error]
  defp summary(_card), do: nil

  defp merged(pulls, events) do
    cond do
      Enum.any?(pulls, &(&1[:status] == "merged" or &1[:merged] == true)) -> true
      Enum.any?(events, &(&1[:kind] == "pr_merged")) -> true
      Enum.any?(pulls, &(&1[:status] in ["open", "closed"] or is_boolean(&1[:merged]))) -> false
      true -> nil
    end
  end

  defp issue_groups(card) do
    groups = [Timeline.group(card.issue_identifier)]
    if card.pull_requests != [] or is_map(card.delivery), do: ["prs" | groups], else: groups
  end

  defp area(labels) do
    case Enum.filter(labels, &String.starts_with?(&1, "area:")) do
      ["area:" <> value] -> value
      _ -> nil
    end
  end

  defp run_start(%{started_s: seconds}) when is_number(seconds), do: seconds

  defp run_start(row) do
    case DashboardComponents.parse_time(row[:started_at]) do
      %DateTime{} = at -> DateTime.to_unix(at)
      _ -> 0
    end
  end

  defp observed_days(card) do
    observations = if card.delivery, do: card.delivery[:tracker_observations] || [], else: []
    closed = if card.delivery, do: day(card.delivery[:closed_at])

    [closed | Enum.map(observations, &day(&1[:closed_at]))] ++
      Enum.map(card.events ++ card.media, &day(&1[:at]))
  end

  defp observed_on?(card, selected_day) do
    case Enum.reject(observed_days(card), &is_nil/1) do
      [] -> true
      days -> selected_day in days
    end
  end

  defp lanes(cards) do
    Enum.map(@lanes, fn {id, title} -> %{id: id, title: title, cards: Enum.filter(cards, &(&1.lane == id))} end)
  end

  defp counts(cards) do
    %{
      intake: Enum.count(cards, &(&1.lane == "intake")),
      active: Enum.count(cards, &(&1.lane == "active")),
      done: Enum.count(cards, &(&1.lane == "done"))
    }
  end

  defp day(%Date{} = date), do: Date.to_iso8601(date)
  defp day(%DateTime{} = at), do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_date() |> day()

  defp day(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> day(date)
      _ -> value |> DashboardComponents.parse_time() |> day()
    end
  end

  defp day(_value), do: nil
end
