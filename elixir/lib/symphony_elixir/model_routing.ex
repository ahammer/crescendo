defmodule SymphonyElixir.ModelRouting do
  @moduledoc """
  Explicit issue-label routing for Codex worker runs.

  An optional `ladder` orders routes from cheapest to strongest, and
  `escalation` lists how many ladder steps each item attempt climbs from the
  run's starting route, so retries of a failing item use stronger models.

  The starting route comes from a model label (`label_prefix`), else a size
  label (`size_label_prefix` + a key of `sizes`, e.g. `size:small`), else
  `default`. `effort_floor` names the lowest effort a model may run at, so a
  cheap model can be kept at full effort. Quota back-off (`avoid`) swaps an
  avoided model for the strongest allowed ladder step at or below the route,
  but never below the item's own start or the default start, so back-off
  never hands work to a model it would not otherwise get.
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
             :ok <- validate_sizes(routing),
             :ok <- validate_floor(routing),
             do: validate_ladder(routing)
    end
  end

  def validate(_), do: {:error, "routing requires label_prefix, default, and labels"}

  @doc "Validates a single `{model, effort}` route."
  @spec validate_route(term()) :: :ok | {:error, String.t()}
  def validate_route(route), do: validate_route_entry(route) || :ok

  @doc "Checks a route (such as a fixed research or review route) against the routing's `effort_floor`."
  @spec check_floor(map() | nil, map() | nil) :: :ok | {:error, String.t()}
  def check_floor(%{"effort_floor" => %{} = floors}, %{"model" => model, "effort" => effort}) do
    case Map.fetch(floors, model) do
      {:ok, floor} -> if effort_rank(effort) >= effort_rank(floor), do: :ok, else: {:error, "#{model} must run at #{floor} effort or higher"}
      :error -> :ok
    end
  end

  def check_floor(_routing, _route), do: :ok

  @doc """
  Selects the route for one run. Research and pull request review runs use
  their fixed route (`fixed_routes.research`, `fixed_routes.pull_request`; a
  research item's own `route` wins) when configured. Everything else starts
  from the issue's label route and, with a ladder, climbs
  `escalation[item_attempt - 1]` steps (the last offset repeats), capped at the
  strongest step. `avoid:` (model => reason) then applies quota back-off; a
  route with no allowed step waits instead of running.
  """
  @spec select_for_run(map() | nil, %{optional(atom()) => map() | nil}, Issue.t(), pos_integer(), keyword()) ::
          {:ok, map() | nil} | {:wait, String.t()} | {:error, String.t()}
  def select_for_run(routing, fixed_routes, %Issue{} = issue, item_attempt, opts \\ []) do
    with {:ok, route} <- base_route(routing, fixed_routes, issue, item_attempt) do
      back_off(routing, route, Keyword.get(opts, :avoid, %{}))
    end
  end

  defp base_route(routing, fixed_routes, %Issue{kind: kind} = issue, item_attempt) do
    case fixed_route(fixed_routes, issue) do
      %{} = route -> {:ok, Map.put(route, "label", Map.fetch!(@fixed_labels, kind))}
      nil -> with {:ok, route} <- select(routing, issue), do: {:ok, escalate(routing, route, item_attempt)}
    end
  end

  defp fixed_route(_fixed_routes, %Issue{kind: :research, research: %{route: %{} = route}}), do: route
  defp fixed_route(fixed_routes, %Issue{kind: kind}), do: Map.get(fixed_routes, kind)

  @spec select(map() | nil, Issue.t()) :: {:ok, map() | nil} | {:error, String.t()}
  def select(nil, %Issue{}), do: {:ok, nil}

  def select(routing, %Issue{} = issue) do
    labels = issue |> Issue.label_names() |> Enum.map(&String.downcase/1) |> Enum.uniq()

    with {:ok, nil} <- model_label_route(routing, labels) do
      {:ok, size_route(routing, labels) || Map.put(routing["default"], "label", "default")}
    end
  end

  defp model_label_route(routing, labels) do
    prefix = String.downcase(routing["label_prefix"])
    routes = Map.new(routing["labels"], fn {label, route} -> {String.downcase(label), route} end)

    case Enum.filter(labels, &String.starts_with?(&1, prefix)) do
      [] ->
        {:ok, nil}

      [label] ->
        case Map.fetch(routes, label) do
          {:ok, route} -> {:ok, Map.put(route, "label", label)}
          :error -> {:error, "unknown model route label #{label}"}
        end

      matches ->
        {:error, "conflicting model route labels: #{Enum.join(matches, ", ")}"}
    end
  end

  # A size only picks the starting route; the route label stays "default", which
  # is what tools checking the selected model label expect for an unlabelled issue.
  # With several size labels the strongest wins.
  defp size_route(%{"size_label_prefix" => prefix, "sizes" => %{} = sizes} = routing, labels) when map_size(sizes) > 0 do
    prefix = String.downcase(prefix)

    labels
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&String.replace_prefix(&1, prefix, ""))
    |> Enum.filter(&Map.has_key?(sizes, &1))
    |> Enum.map(&Map.merge(Map.fetch!(sizes, &1), %{"label" => "default", "size" => &1}))
    |> Enum.max_by(&(tier(routing["ladder"] || [], &1) || -1), fn -> nil end)
  end

  defp size_route(_routing, _labels), do: nil

  # The label stays the starting route's, so a changed label still means a
  # changed selection; `tier` and `start_tier` record the climb.
  defp escalate(%{"ladder" => ladder, "escalation" => offsets}, %{} = route, item_attempt) do
    start = tier(ladder, route)
    offset = Enum.at(offsets, min(max(item_attempt, 1), length(offsets)) - 1)
    step = min(start + offset, length(ladder) - 1)

    ladder
    |> Enum.at(step)
    |> Map.merge(Map.take(route, ["label", "size"]))
    |> Map.merge(%{"tier" => step, "start_tier" => start})
  end

  defp escalate(_routing, route, _item_attempt), do: route

  defp back_off(_routing, nil, _avoid), do: {:ok, nil}

  defp back_off(routing, route, avoid) do
    case Map.fetch(avoid, route["model"]) do
      :error -> {:ok, route}
      {:ok, reason} -> fall_back(routing, route, avoid, reason)
    end
  end

  # The floor is the item's own start or the default start, whichever is lower:
  # unsized work never falls to a cheaper model than its default.
  defp fall_back(%{"ladder" => [_ | _] = ladder} = routing, route, avoid, reason) do
    top = tier(ladder, route)
    floor = min(route["start_tier"] || top || 0, tier(ladder, routing["default"]) || 0)

    with top when is_integer(top) <- top,
         step when is_integer(step) <- Enum.find(top..floor//-1, &(not Map.has_key?(avoid, Enum.at(ladder, &1)["model"]))) do
      {:ok,
       ladder
       |> Enum.at(step)
       |> Map.merge(Map.take(route, ["label", "size", "start_tier"]))
       |> Map.merge(%{"tier" => step, "backoff" => %{"from" => "#{route["model"]} #{route["effort"]}", "reason" => reason}})}
    else
      _ -> {:wait, reason}
    end
  end

  defp fall_back(_routing, _route, _avoid, reason), do: {:wait, reason}

  defp validate_sizes(%{"sizes" => %{} = sizes} = routing) when map_size(sizes) > 0 do
    cond do
      not (is_binary(routing["size_label_prefix"]) and String.trim(routing["size_label_prefix"]) != "") ->
        {:error, "sizes require a size_label_prefix"}

      Enum.any?(Map.keys(sizes), &(not is_binary(&1) or String.trim(&1) == "")) ->
        {:error, "size names must be nonblank"}

      true ->
        Enum.find_value(Map.values(sizes), :ok, &validate_route_entry/1)
    end
  end

  defp validate_sizes(%{"sizes" => sizes}) when not is_map(sizes), do: {:error, "sizes must map size names to routes"}
  defp validate_sizes(_routing), do: :ok

  defp validate_floor(%{"effort_floor" => %{} = floors} = routing) do
    if Enum.all?(floors, &valid_floor?/1),
      do: Enum.find_value(configured_routes(routing), :ok, &floor_error(routing, &1)),
      else: {:error, "effort_floor must map models to supported efforts"}
  end

  defp validate_floor(%{"effort_floor" => _floors}), do: {:error, "effort_floor must map models to supported efforts"}
  defp validate_floor(_routing), do: :ok

  defp valid_floor?({model, effort}), do: is_binary(model) and effort in @efforts

  defp floor_error(routing, route) do
    case check_floor(routing, route) do
      :ok -> nil
      error -> error
    end
  end

  defp configured_routes(routing),
    do: [routing["default"] | Map.values(routing["labels"])] ++ Map.values(routing["sizes"] || %{}) ++ (routing["ladder"] || [])

  defp validate_ladder(%{"ladder" => [_ | _] = ladder, "escalation" => escalation} = routing) do
    starts = [routing["default"] | Map.values(routing["labels"])] ++ Map.values(routing["sizes"] || %{})

    cond do
      Enum.any?(ladder, &validate_route_entry/1) ->
        {:error, "each ladder step needs a nonblank model and supported effort"}

      Enum.uniq(ladder) != ladder ->
        {:error, "ladder steps must be distinct"}

      not valid_escalation?(escalation) ->
        {:error, "escalation must be a non-empty, non-decreasing list of non-negative integers"}

      Enum.any?(starts, &is_nil(tier(ladder, &1))) ->
        {:error, "the default and every label and size route must be a ladder step"}

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

  defp effort_rank(effort), do: Enum.find_index(@efforts, &(&1 == effort)) || -1

  defp validate_route_entry(%{"model" => model, "effort" => effort} = route)
       when is_binary(model) and is_binary(effort) do
    if map_size(route) == 2 and String.trim(model) != "" and effort in @efforts,
      do: false,
      else: {:error, "each route needs a nonblank model and supported effort"}
  end

  defp validate_route_entry(_), do: {:error, "each route needs a nonblank model and supported effort"}
end
