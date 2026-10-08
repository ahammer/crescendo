defmodule SymphonyElixirWeb.Redaction do
  @moduledoc """
  Keeps a private project's work off the public dashboard and API.

  For a project marked `redact: true` in the service file, items show only
  what they are and how they are doing: identifiers, links back to the
  tracker, kind, state, model, attempts, tokens and cost. Titles,
  descriptions, labels, messages, transcripts, plans, changed files,
  images (including the picture timeline's), branches, errors and run ids
  are dropped.
  """

  @hidden "Private work"
  @empty_workspace %{
    progress: %{done: 0, total: 0},
    plan: [],
    plan_explanation: nil,
    files: [],
    latest_image: nil,
    images: 0,
    entries: 0,
    now: nil,
    said: nil
  }

  @doc "Scrubs every item of the `redacted` projects from a dashboard/state payload."
  @spec payload(map(), MapSet.t(String.t())) :: map()
  def payload(payload, redacted) do
    if Enum.empty?(redacted) or Map.has_key?(payload, :error) do
      payload
    else
      scrub = fn items, fun -> scrub(items, redacted, fun) end

      payload
      |> Map.update(:running, [], &scrub.(&1, fn entry -> running(entry) end))
      |> Map.update(:helpers, [], &scrub.(&1, fn entry -> Map.take(entry, [:project, :status, :model, :effort, :usage]) end))
      |> Map.update(:retrying, [], &scrub.(&1, fn entry -> entry |> Map.merge(%{error: nil, workspace_path: nil}) |> Map.drop([:startup]) end))
      |> Map.update(:blocked, [], &scrub.(&1, fn entry -> blocked(entry) end))
      |> update_in([:upcoming, :ready], &scrub.(&1, fn item -> %{item | title: @hidden} end))
      |> update_in([:upcoming, :waiting], &scrub.(&1, fn item -> %{item | title: @hidden} end))
      |> update_in([:pull_requests, :items], &scrub.(&1, fn pull -> pull(pull) end))
      |> update_in([:usage, :activity], &scrub.(&1, fn event -> Map.drop(event, [:summary, :title, :startup, :run_id, :parent_run_id, :source_sha, :worker_pid]) end))
      |> update_in([:usage], &redact_external(&1, redacted))
      |> update_in([:usage, :images], &drop_projects(&1, redacted))
      |> update_in([:usage], &redact_deliveries(&1, redacted))
    end
  end

  defp redact_external(usage, redacted) do
    Map.update(usage, :external, %{}, fn external ->
      Map.update(external, :observations, [], fn observations ->
        scrub(observations, redacted, &Map.drop(&1, [:run_id, :parent_run_id, :parent_issue_id, :source_sha]))
      end)
    end)
  end

  defp redact_deliveries(usage, redacted) do
    Map.update(usage, :delivery_metrics, %{}, fn metrics ->
      Map.update(metrics, :issue_associations, [], &drop_projects(&1, redacted))
    end)
  end

  # A private project's pictures would show its work, so they are dropped outright.
  defp drop_projects(items, redacted), do: Enum.reject(items || [], &(&1[:project] in redacted))

  defp scrub(items, redacted, fun), do: Enum.map(items || [], &scrub_item(&1, redacted, fun))

  defp scrub_item(item, redacted, fun), do: if(item[:project] in redacted, do: fun.(item), else: item)

  @doc "A redacted project's single-item payload: only its status."
  @spec item(map()) :: map()
  def item(payload), do: Map.take(payload, [:project, :issue_identifier, :issue_id, :status]) |> Map.put(:redacted, true)

  defp running(entry) do
    entry
    |> Map.merge(%{
      title: @hidden,
      labels: [],
      description: nil,
      branch: nil,
      workspace_path: nil,
      session_id: nil,
      run_id: nil,
      codex_provenance: %{},
      last_message: nil,
      recent_events: [],
      pull_request: nil,
      research: entry[:research] && Map.take(entry.research, [:channel]),
      workspace: @empty_workspace
    })
    |> Map.replace(:transcript, [])
  end

  defp blocked(entry) do
    entry
    |> Map.merge(%{error: nil, workspace_path: nil, session_id: nil, last_message: nil})
    |> Map.drop([:startup, :run_id, :worker_pid])
  end

  defp pull(pull) do
    pull
    |> Map.put(:title, @hidden)
    |> Map.drop([:head_ref, :author, :body])
  end
end
