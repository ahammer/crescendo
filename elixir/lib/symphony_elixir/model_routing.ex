defmodule SymphonyElixir.ModelRouting do
  @moduledoc "Explicit issue-label routing for Codex worker runs."

  alias SymphonyElixir.Tracker.Issue

  @efforts ~w(minimal low medium high xhigh)

  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(%{"label_prefix" => prefix, "default" => default, "labels" => labels})
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
        Enum.find_value([default | Map.values(labels)], :ok, &validate_route_entry/1)
    end
  end

  def validate(_), do: {:error, "routing requires label_prefix, default, and labels"}

  @doc "Validates a single `{model, effort}` route."
  @spec validate_route(term()) :: :ok | {:error, String.t()}
  def validate_route(route), do: validate_route_entry(route) || :ok

  @doc """
  Selects the route for one run. Autopilot research runs use `research_route`
  when configured, since planning deserves a stronger model than the default
  issue route; everything else routes by issue labels.
  """
  @spec select_for_run(map() | nil, map() | nil, Issue.t()) :: {:ok, map() | nil} | {:error, String.t()}
  def select_for_run(_routing, %{} = research_route, %Issue{kind: :research}),
    do: {:ok, Map.put(research_route, "label", "research")}

  def select_for_run(routing, _research_route, %Issue{} = issue), do: select(routing, issue)

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

  defp validate_route_entry(%{"model" => model, "effort" => effort} = route)
       when is_binary(model) and is_binary(effort) do
    if map_size(route) == 2 and String.trim(model) != "" and effort in @efforts,
      do: false,
      else: {:error, "each route needs a nonblank model and supported effort"}
  end

  defp validate_route_entry(_), do: {:error, "each route needs a nonblank model and supported effort"}
end
