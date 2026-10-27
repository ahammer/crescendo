defmodule SymphonyElixirWeb.ControlState do
  @moduledoc """
  Bounded live observations for reconcilers, leases and deployment. No retained
  history, transcripts or repository I/O participates in this projection.
  Partial observations never establish that work has stopped or slots are free.
  """

  alias SymphonyElixir.{Governor, Orchestrator, Project, Projects, Service, SourceRevision}

  @deadline_ms 2_000

  @spec payload(keyword()) :: map()
  def payload(opts) do
    service = Service.current()
    projects = if service, do: Service.projects(service), else: []
    project = opts[:project]
    selected = Enum.filter(projects, &(project in [nil, &1.id]))

    targets =
      if service do
        [{:governor, Governor} | Enum.map(selected, &{&1.id, Project.via(&1.id, :orchestrator)})]
      else
        [{nil, Keyword.fetch!(opts, :orchestrator)}]
      end

    timeout = min(Keyword.fetch!(opts, :timeout), @deadline_ms)
    results = observe(targets, timeout)
    snapshots = for {id, result} <- results, id != :governor, do: {id, result}
    governor = results[:governor]
    errors = snapshot_errors(results, project, selected)
    build(snapshots, governor, projects, project, errors)
  end

  defp snapshot_errors(results, project, selected) do
    errors = for {id, result} <- results, not is_map(result), do: %{project: id, status: result}
    if project && selected == [], do: [%{project: project, status: :unknown_project} | errors], else: errors
  end

  defp build(snapshots, governor, projects, project, errors) do
    complete = errors == []
    running = entries(snapshots, :running, [:issue_id, :identifier, :run_id, :kind, :started_at], projects)
    helpers = entries(snapshots, :helpers, [:run_id, :parent_run_id, :parent_issue_id, :status], projects)
    retrying = entries(snapshots, :retrying, [:issue_id, :identifier, :attempt, :due_in_ms], projects)
    ready = upcoming(snapshots, :ready, projects)
    waiting = upcoming(snapshots, :waiting, projects)
    observations = for {_id, snapshot} <- snapshots, is_map(snapshot), do: snapshot.observed_at

    counts = %{
      running: length(running),
      helpers: length(helpers),
      retrying: length(retrying),
      ready: length(ready),
      waiting: length(waiting)
    }

    %{
      view: "control",
      schema_version: 1,
      generated_at: DateTime.utc_now(),
      observed_at: if(complete, do: Enum.min(observations, DateTime, fn -> nil end)),
      service: SourceRevision.metadata(),
      project: project,
      snapshot_status: if(complete, do: "complete", else: "partial"),
      snapshot_errors: errors,
      counts: if(complete, do: counts, else: Map.new(counts, fn {key, _} -> {key, nil} end)),
      running: running,
      helpers: helpers,
      retrying: retrying,
      upcoming: %{
        ready: ready,
        waiting: waiting,
        observed_at: oldest(snapshots, [:upcoming, :observed_at], complete),
        available_slots: if(complete, do: available_slots(governor, snapshots))
      },
      pull_requests: %{
        observed_at: oldest(snapshots, [:pull_requests, :observed_at], complete),
        enabled: pulls_enabled?(snapshots)
      },
      throttle: if(is_map(governor), do: Map.take(governor, [:slots, :busy, :helpers, :draining, :drain_reason, :drain_owner])),
      projects: project_status(projects, snapshots)
    }
  end

  defp pulls_enabled?(snapshots),
    do: Enum.any?(snapshots, fn {_id, value} -> is_map(value) and get_in(value, [:pull_requests, :enabled]) == true end)

  # Every actor shares one deadline. A missing actor or timed-out task is a
  # partial observation, including the Governor even on a project-filtered read.
  defp observe(targets, timeout) do
    targets
    |> Task.async_stream(
      fn
        {:governor, _} -> safe(fn -> Governor.snapshot(timeout) end)
        {id, server} -> Project.with_project(id, fn -> Orchestrator.snapshot(server, timeout, view: :control) end)
      end,
      timeout: timeout,
      on_timeout: :kill_task,
      max_concurrency: max(length(targets), 1)
    )
    |> Enum.zip(targets)
    |> Map.new(fn
      {{:ok, result}, {id, _}} -> {id, result}
      {{:exit, _}, {id, _}} -> {id, :timeout}
    end)
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, _ -> :unavailable
  end

  defp entries(snapshots, key, fields, projects) do
    private = for project <- projects, project.redact, do: project.id

    for {id, snapshot} <- snapshots, is_map(snapshot), entry <- snapshot[key] || [] do
      entry = entry |> Map.take(fields) |> Map.put(:project, id)
      entry = if Map.has_key?(entry, :identifier), do: entry |> Map.put(:issue_identifier, entry.identifier) |> Map.delete(:identifier), else: entry
      if id in private, do: entry |> Map.drop([:run_id, :parent_run_id]) |> Map.put(:redacted, true), else: entry
    end
  end

  defp upcoming(snapshots, key, projects) do
    private = for project <- projects, project.redact, do: project.id

    for {id, snapshot} <- snapshots,
        is_map(snapshot),
        item <- get_in(snapshot, [:upcoming, key]) || [],
        do: item |> Map.take([:issue_identifier, :blocked_by]) |> Map.put(:project, id) |> Map.put(:reason, if(id in private, do: "Private admission policy", else: item[:reason]))
  end

  defp oldest(snapshots, path, complete) do
    dates = for {_id, snapshot} <- snapshots, is_map(snapshot), do: get_in(snapshot, path)
    if complete and Enum.all?(dates, &match?(%DateTime{}, &1)), do: Enum.min(dates, DateTime, fn -> nil end)
  end

  defp available_slots(%{slots: slots, busy: busy}, _snapshots), do: max(slots - busy, 0)
  defp available_slots(_, [{_, snapshot}]), do: get_in(snapshot, [:upcoming, :available_slots])

  defp project_status(projects, snapshots) do
    failures = Projects.failures()
    snapshots = Map.new(snapshots)

    for project <- projects do
      snapshot = snapshots[project.id]

      %{
        id: project.id,
        started: is_pid(GenServer.whereis(Project.via(project.id, :orchestrator))),
        snapshot_status: if(is_map(snapshot), do: "ok", else: to_string(snapshot || :not_selected)),
        observed_at: if(is_map(snapshot), do: snapshot.observed_at),
        tracker_ready: if(is_map(snapshot), do: snapshot.tracker_ready),
        running: if(is_map(snapshot), do: length(snapshot.running)),
        ready: if(is_map(snapshot), do: length(snapshot.upcoming.ready)),
        failure: failures[project.id]
      }
    end
  end
end
