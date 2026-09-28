defmodule SymphonyElixir.Scheduling do
  @moduledoc """
  Pure slot scheduling for a service's projects.

  The service has `slots` worker slots. Each project has a `weight`, an
  optional `cap` on its own slots, and a research exclusivity mode. Slots are
  shared by stride scheduling: every grant advances the project's `pass` by
  `1 / weight`, and while projects with waiting work (`demand`) compete, the
  slot goes to the lowest pass, so weights 3, 1, 1 give the first project
  about three fifths of the grants. Passes start at one stride (`1 /
  weight`), so the heaviest project goes first, and equal passes favor the
  heavier project. A project returning from idle (no demand, no slots)
  rejoins at the lowest pass among the active projects instead of spending
  credit it banked while idle.

  Research exclusivity:

  - `none`: a research run is an ordinary run.
  - `project`: research runs only when its own project is idle and holds the
    project's dispatch while it runs (the orchestrator enforces this part).
  - `global`: research needs the whole service idle and holds every slot
    while it runs. A research request that finds other runs in flight
    reserves the service, so nothing new starts elsewhere until the
    research gets its turn; a reservation that is not renewed lapses.

  Nothing here counts as a failed attempt: a wait just means "not yet".
  """

  @type project :: %{
          weight: pos_integer(),
          cap: pos_integer() | nil,
          exclusive: String.t(),
          pass: float(),
          demand: non_neg_integer(),
          held: %{optional(String.t()) => atom()}
        }
  @type t :: %{
          slots: pos_integer(),
          projects: %{optional(String.t()) => project()},
          reservation: %{project: String.t(), until_ms: integer()} | nil
        }
  @type decision :: {:ok, t()} | {:wait, String.t(), t(), [String.t()]}

  @reservation_ms 90_000

  @doc "A schedule for `slots` shared by `projects` (id => weight, cap, exclusivity)."
  @spec new(pos_integer(), [{String.t(), pos_integer(), pos_integer() | nil, String.t()}]) :: t()
  def new(slots, projects) do
    %{
      slots: slots,
      projects:
        Map.new(projects, fn {id, weight, cap, exclusive} ->
          {id, %{weight: weight, cap: cap, exclusive: exclusive, pass: 1 / weight, demand: 0, held: %{}}}
        end),
      reservation: nil
    }
  end

  @doc """
  Asks for a slot for one run. Returns the new schedule, or why the run must
  wait together with the projects that should be told to dispatch now (the
  one the slot is kept for).
  """
  @spec acquire(t(), String.t(), String.t(), atom(), integer()) :: decision()
  def acquire(schedule, id, item, class, now_ms) do
    schedule = schedule |> expire_reservation(now_ms) |> activate(id)
    project = Map.fetch!(schedule.projects, id)

    cond do
      Map.has_key?(project.held, item) -> {:ok, schedule}
      reason = exclusive_block(schedule, id) -> {:wait, reason, schedule, []}
      class == :research and project.exclusive == "global" -> acquire_global_research(schedule, id, item, now_ms)
      true -> acquire_slot(schedule, id, project, item, class)
    end
  end

  defp acquire_slot(schedule, id, project, item, class) do
    cond do
      used(schedule) >= schedule.slots -> {:wait, "all #{schedule.slots} slots are busy", schedule, []}
      project.cap && map_size(project.held) >= project.cap -> {:wait, "#{id} is at its cap of #{project.cap}", schedule, []}
      favored = favored_rival(schedule, id) -> {:wait, "the next slot is #{favored}'s turn", schedule, [favored]}
      true -> {:ok, grant(schedule, id, item, class)}
    end
  end

  @doc "Frees a run's slot; returns the projects with waiting work that should dispatch now."
  @spec release(t(), String.t(), String.t()) :: {t(), [String.t()]}
  def release(schedule, id, item) do
    case schedule.projects do
      %{^id => project} ->
        schedule = put_in(schedule.projects[id], %{project | held: Map.delete(project.held, item)})
        {schedule, waiting(schedule)}

      _ ->
        {schedule, []}
    end
  end

  @doc "Records how many runs a project could start now (its unmet demand)."
  @spec report_demand(t(), String.t(), non_neg_integer()) :: t()
  def report_demand(schedule, id, demand) do
    case schedule.projects do
      %{^id => _project} ->
        schedule = if demand > 0, do: activate(schedule, id), else: schedule
        put_in(schedule.projects[id].demand, demand)

      _ ->
        schedule
    end
  end

  @doc "Forgets every slot and the demand of a project whose orchestrator stopped."
  @spec drop(t(), String.t()) :: {t(), [String.t()]}
  def drop(schedule, id) do
    case schedule.projects do
      %{^id => project} ->
        schedule = put_in(schedule.projects[id], %{project | held: %{}, demand: 0})
        {schedule, waiting(schedule)}

      _ ->
        {schedule, []}
    end
  end

  @doc "Slots a project could fill right now, before fairness among competing projects."
  @spec free_for(t(), String.t(), integer()) :: non_neg_integer()
  def free_for(schedule, id, now_ms) do
    schedule = schedule |> expire_reservation(now_ms) |> activate(id)
    project = Map.fetch!(schedule.projects, id)

    cond do
      exclusive_block(schedule, id) -> 0
      favored_rival(schedule, id) -> 0
      true -> max(min(schedule.slots - used(schedule), (project.cap || schedule.slots) - map_size(project.held)), 0)
    end
  end

  @spec used(t()) :: non_neg_integer()
  def used(schedule), do: schedule.projects |> Map.values() |> Enum.map(&map_size(&1.held)) |> Enum.sum()

  # Global research holds the service; a reservation keeps it for the project that asked.
  defp exclusive_block(schedule, id) do
    cond do
      rival = global_research(schedule, id) -> "#{rival} is researching with the service to itself"
      match?(%{project: other} when other != id, schedule.reservation) -> "the service is held for #{schedule.reservation.project}'s research"
      true -> nil
    end
  end

  defp global_research(schedule, id) do
    Enum.find_value(schedule.projects, fn {other, project} ->
      other != id and project.exclusive == "global" and :research in Map.values(project.held) and other
    end)
  end

  defp acquire_global_research(schedule, id, item, now_ms) do
    if used(schedule) == 0 do
      {:ok, schedule |> Map.put(:reservation, nil) |> grant(id, item, :research)}
    else
      reserved = %{schedule | reservation: %{project: id, until_ms: now_ms + @reservation_ms}}
      {:wait, "waiting for the service to go idle for research", reserved, []}
    end
  end

  defp expire_reservation(%{reservation: %{until_ms: until_ms}} = schedule, now_ms) when now_ms >= until_ms, do: %{schedule | reservation: nil}
  defp expire_reservation(schedule, _now_ms), do: schedule

  # Another project with waiting work, room under its cap and a better turn
  # (a lower pass, or an equal pass and a higher weight) gets the next slot.
  defp favored_rival(schedule, id) do
    own = turn(Map.fetch!(schedule.projects, id))

    schedule.projects
    |> Enum.filter(fn {other, project} -> other != id and competing?(project) and turn(project) < own end)
    |> Enum.min_by(fn {_other, project} -> turn(project) end, fn -> nil end)
    |> case do
      nil -> nil
      {other, _project} -> other
    end
  end

  defp turn(project), do: {project.pass, -project.weight}

  defp competing?(project), do: project.demand > 0 and (is_nil(project.cap) or map_size(project.held) < project.cap)
  defp active?(project), do: project.demand > 0 or project.held != %{}

  # A project going from idle to active rejoins one of its own strides past
  # the virtual time (the active projects' earliest pass, less the stride
  # that led to it): idling never banks credit, and a heavier project keeps
  # its head start when everyone starts together.
  defp activate(schedule, id) do
    project = Map.fetch!(schedule.projects, id)

    if active?(project) do
      schedule
    else
      now =
        schedule.projects
        |> Enum.filter(fn {other, other_project} -> other != id and active?(other_project) end)
        |> Enum.map(fn {_other, other_project} -> other_project.pass - 1 / other_project.weight end)
        |> Enum.min(fn -> nil end)

      if now, do: put_in(schedule.projects[id].pass, max(project.pass, now + 1 / project.weight)), else: schedule
    end
  end

  defp grant(schedule, id, item, class) do
    project = Map.fetch!(schedule.projects, id)
    put_in(schedule.projects[id], %{project | pass: project.pass + 1 / project.weight, held: Map.put(project.held, item, class)})
  end

  # After a slot frees, the waiting project with the lowest pass goes first.
  defp waiting(schedule) do
    schedule.projects
    |> Enum.filter(fn {_id, project} -> competing?(project) end)
    |> Enum.min_by(fn {_id, project} -> turn(project) end, fn -> nil end)
    |> case do
      nil -> []
      {id, _project} -> [id]
    end
  end
end
