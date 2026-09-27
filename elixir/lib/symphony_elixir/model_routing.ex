defmodule SymphonyElixir.ModelRouting do
  @moduledoc """
  Explicit issue-label routing for Codex worker runs.

  An optional `ladder` orders routes from cheapest to strongest, and
  `escalation` lists how many ladder steps each item attempt climbs from the
  run's starting route, so retries of a failing item use stronger models.
  """

  alias SymphonyElixir.Tracker.Issue

  @efforts ~w(minimal low medium high xhigh max)
  @fixed_labels %{research: "research", pull_request: "review"}

  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(%{"label_prefix" => prefix, "default" => default, "labels" => labels} = routing)
      when is_binary(prefix) and is_map(labels) do
    cond do
      String.trim(prefix) == "" ->
        {:error, "label_prefix must not be blank"}

      map_size(labels) == 0 ->
        {:error, "labels must not be empty"}

      Enum.any?(Map.keys(labels), &(not is_binary(&1) or not String.starts_with?(String.downcase(&1), String.downcase(prefix)))) ->
        {:error, "every route label must start with label_prefix"}

      length(Enum.uniq_by(Map.keys(labels), &String.downcase/1)) != map_size(labels) ->
        {:error, "route labels must be unique ignoring case"}

      true ->
        with :ok <- Enum.find_value([default | Map.values(labels)], :ok, &validate_route_entry/1),
             do: validate_ladder(routing)
    end
  end

  def validate(_), do: {:error, "routing requires label_prefix, default, and labels"}

  @doc "Validates a single `{model, effort}` route."
  @spec validate_route(term()) :: :ok | {:error, String.t()}
  def validate_route(route), do: validate_route_entry(route) || :ok

  @doc """
  Selects the route for one run. Research and pull request review runs use
  their fixed route (`fixed_routes.research`, `fixed_routes.pull_request`) when
  configured. Everything else starts from the issue's label route and, with a
  ladder, climbs `escalation[item_attempt - 1]` steps (the last offset
  repeats), capped at the strongest step.
  """
  @spec select_for_run(map() | nil, %{optional(atom()) => map() | nil}, Issue.t(), pos_integer()) ::
          {:ok, map() | nil} | {:error, String.t()}
  def select_for_run(routing, fixed_routes, %Issue{kind: kind} = issue, item_attempt) do
    case Map.get(fixed_routes, kind) do
      %{} = route -> {:ok, Map.put(route, "label", Map.fetch!(@fixed_labels, kind))}
      nil -> with {:ok, route} <- select(routing, issue), do: {:ok, escalate(routing, route, item_attempt)}
    end
  end

  @spec select(map() | nil, Issue.t()) :: {:ok, map() | nil} | {:error, String.t()}
  def select(nil, %Issue{}), do: {:ok, nil}

  def select(routing, %Issue{} = issue) do
    prefix = String.downcase(routing["label_prefix"])

    matches =
      issue
      |> Issue.label_names()
      |> Enum.map(&String.downcase/1)
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.uniq()

    labels = Map.new(routing["labels"], fn {label, route} -> {String.downcase(label), route} end)

    case matches do
      [] ->
        {:ok, Map.put(routing["default"], "label", "default")}

      [label] ->
        case Map.fetch(labels, label) do
          {:ok, route} -> {:ok, Map.put(route, "label", label)}
          :error -> {:error, "unknown model route label #{label}"}
        end

      _ ->
        {:error, "conflicting model route labels: #{Enum.join(matches, ", ")}"}
    end
  end

  # The label stays the starting route's, so a changed label still means a
  # changed selection; `tier` and `start_tier` record the climb.
  defp escalate(%{"ladder" => ladder, "escalation" => offsets}, %{} = route, item_attempt) do
    start = tier(ladder, route)
    offset = Enum.at(offsets, min(max(item_attempt, 1), length(offsets)) - 1)
    step = min(start + offset, length(ladder) - 1)

    ladder
    |> Enum.at(step)
    |> Map.merge(%{"label" => route["label"], "tier" => step, "start_tier" => start})
  end

  defp escalate(_routing, route, _item_attempt), do: route

  defp validate_ladder(%{"ladder" => [_ | _] = ladder, "escalation" => escalation} = routing) do
    starts = [routing["default"] | Map.values(routing["labels"])]

    cond do
      Enum.any?(ladder, &validate_route_entry/1) ->
        {:error, "each ladder step needs a nonblank model and supported effort"}

      Enum.uniq(ladder) != ladder ->
        {:error, "ladder steps must be distinct"}

      not valid_escalation?(escalation) ->
        {:error, "escalation must be a non-empty, non-decreasing list of non-negative integers"}

      Enum.any?(starts, &is_nil(tier(ladder, &1))) ->
        {:error, "the default and every label route must be a ladder step"}

      true ->
        :ok
    end
  end

  defp validate_ladder(routing) do
    if Map.has_key?(routing, "ladder") or Map.has_key?(routing, "escalation"),
      do: {:error, "ladder must be a non-empty list of routes, configured together with escalation"},
      else: :ok
  end

  defp valid_escalation?([_ | _] = offsets),
    do: Enum.all?(offsets, &(is_integer(&1) and &1 >= 0)) and offsets == Enum.sort(offsets)

  defp valid_escalation?(_offsets), do: false

  defp tier(ladder, route),
    do: Enum.find_index(ladder, &(&1["model"] == route["model"] and &1["effort"] == route["effort"]))

  defp validate_route_entry(%{"model" => model, "effort" => effort} = route)
       when is_binary(model) and is_binary(effort) do
    if map_size(route) == 2 and String.trim(model) != "" and effort in @efforts,
      do: false,
      else: {:error, "each route needs a nonblank model and supported effort"}
  end

  defp validate_route_entry(_), do: {:error, "each route needs a nonblank model and supported effort"}
end
