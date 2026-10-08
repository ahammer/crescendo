defmodule SymphonyElixir.Tracker.Issue do
  @moduledoc """
  Normalized work item representation used by the orchestrator.

  `id` is the stable dispatch identity for the configured tracker scope. It may
  differ from a provider's underlying issue ID when the scheduled item is a
  board or project entry. `native_ref` carries non-secret provider identifiers
  needed by provider-native agent tools. `identifier` remains the human-readable
  value used to derive the workspace key and must be unique within that scope.

  `kind` distinguishes tracker issues from GitHub pull requests (`:pull_request`,
  with details in `pull_request`) and synthetic autopilot research items
  (`:research`, with details in `research`). Research items never exist in the
  tracker; see `tracker_backed?/1`.
  """

  defstruct [
    :id,
    :native_ref,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :state_reason,
    :branch_name,
    :url,
    :assignee_id,
    :pull_request,
    :research,
    :delivery_key,
    kind: :issue,
    blocked_by: [],
    labels: [],
    dispatchable: false,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          native_ref: map() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          state_reason: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          kind: kind(),
          pull_request: map() | nil,
          research: map() | nil,
          delivery_key: String.t() | nil,
          labels: [String.t()],
          blocked_by: [map()],
          dispatchable: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type kind :: :issue | :pull_request | :research | :helper

  @doc "Whether the item can be refreshed through the tracker adapter."
  @spec tracker_backed?(t()) :: boolean()
  def tracker_backed?(%__MODULE__{kind: :research}), do: false
  def tracker_backed?(%__MODULE__{kind: :helper}), do: false
  def tracker_backed?(%__MODULE__{}), do: true

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end

  @spec routable?(t(), [String.t()]) :: boolean()
  def routable?(issue, required_labels), do: routable?(issue, required_labels, [])

  @spec routable?(t(), [String.t()], [String.t()]) :: boolean()
  # For pull requests the adapter folds required labels into `dispatchable` as an
  # alternative to author trust, so only excluded labels apply here.
  def routable?(%__MODULE__{dispatchable: true, kind: :pull_request} = issue, _required_labels, excluded_labels) do
    is_nil(excluded_label(issue, excluded_labels))
  end

  def routable?(%__MODULE__{dispatchable: true, labels: labels} = issue, required_labels, excluded_labels)
      when is_list(labels) and is_list(required_labels) do
    has_required_labels?(issue, required_labels) and is_nil(excluded_label(issue, excluded_labels))
  end

  def routable?(%__MODULE__{}, _required_labels, _excluded_labels), do: false

  @doc "Whether the issue carries every required label, ignoring case and surrounding whitespace."
  @spec has_required_labels?(t(), [String.t()]) :: boolean()
  def has_required_labels?(%__MODULE__{labels: labels}, required_labels) do
    issue_labels = MapSet.new(labels, &normalize_label/1)
    Enum.all?(required_labels, &MapSet.member?(issue_labels, normalize_label(&1)))
  end

  @doc "Returns the first configured excluded label present on the issue, if any."
  @spec excluded_label(t(), [String.t()]) :: String.t() | nil
  def excluded_label(%__MODULE__{labels: labels}, excluded_labels) do
    issue_labels = MapSet.new(labels, &normalize_label/1)
    Enum.find(excluded_labels, &MapSet.member?(issue_labels, normalize_label(&1)))
  end

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end
end
