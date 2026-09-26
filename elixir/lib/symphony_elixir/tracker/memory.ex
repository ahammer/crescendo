defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Tracker.Issue

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @doc "Test and local-development write: records the call and drops the label."
  @spec clear_label(Issue.t(), String.t()) :: :ok
  def clear_label(%Issue{id: id}, label) do
    record_write({:clear_label, id, label})

    update_issue(id, fn issue -> %{issue | labels: Enum.reject(issue.labels, &(&1 == label))} end)
  end

  @doc "Test and local-development write: records the call and closes the item."
  @spec retire(Issue.t(), String.t()) :: :ok
  def retire(%Issue{id: id}, reason) do
    record_write({:retire, id, reason})
    update_issue(id, fn issue -> %{issue | state: "closed"} end)
  end

  defp record_write(entry) do
    writes = Application.get_env(:symphony_elixir, :memory_tracker_writes, [])
    Application.put_env(:symphony_elixir, :memory_tracker_writes, writes ++ [entry])
  end

  defp update_issue(id, fun) do
    issues =
      Enum.map(configured_issues(), fn
        %Issue{id: ^id} = issue -> fun.(issue)
        other -> other
      end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(_tracker_settings), do: []

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
