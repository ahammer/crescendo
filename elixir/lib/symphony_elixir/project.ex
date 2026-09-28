defmodule SymphonyElixir.Project do
  @moduledoc """
  The project a process works for.

  One service can run several projects, each with its own workflow store,
  orchestrator and agent tasks, registered in `SymphonyElixir.ProjectRegistry`
  under `{kind, project}`. Code that reads configuration (`Config.settings!/0`)
  resolves the store of the current project, so the same modules serve every
  project.

  A process sets its project with `put/1`. Tasks inherit it from the process
  that started them (through `$callers`), so work spawned by a project's
  orchestrator carries the right configuration without extra wiring. A
  process with no project uses the single-workflow runtime's legacy names.
  """

  @key :symphony_project
  @registry SymphonyElixir.ProjectRegistry

  @type id :: String.t()

  @doc "Sets (or with nil clears) the current process's project."
  @spec put(id() | nil) :: :ok
  def put(nil) do
    Process.delete(@key)
    :ok
  end

  def put(id) when is_binary(id) do
    Process.put(@key, id)
    :ok
  end

  @doc "The current project: set on this process, or inherited from the process that started this task."
  @spec current() :: id() | nil
  def current do
    case Process.get(@key) do
      nil -> inherit()
      id -> id
    end
  end

  @doc "Runs `fun` as the given project, restoring the previous project afterwards."
  @spec with_project(id() | nil, (-> result)) :: result when result: var
  def with_project(id, fun) when is_function(fun, 0) do
    previous = Process.get(@key)
    put(id)

    try do
      fun.()
    after
      put(previous)
    end
  end

  @doc "The registered name of a project's process of `kind` (`:workflow_store`, `:orchestrator`, ...)."
  @spec via(id(), atom()) :: {:via, Registry, {module(), {atom(), id()}}}
  def via(id, kind) when is_binary(id) and is_atom(kind), do: {:via, Registry, {@registry, {kind, id}}}

  @doc "The name of the current project's process of `kind`, or `legacy` without a project."
  @spec name(atom(), GenServer.name()) :: GenServer.name()
  def name(kind, legacy) do
    case current() do
      nil -> legacy
      id -> via(id, kind)
    end
  end

  @spec registry() :: module()
  def registry, do: @registry

  # The first caller with a project decides; the answer is cached for the
  # task's lifetime.
  defp inherit do
    case Enum.find_value(Process.get(:"$callers") || [], &project_of/1) do
      nil ->
        nil

      id ->
        Process.put(@key, id)
        id
    end
  end

  defp project_of(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> with {@key, id} <- List.keyfind(dictionary, @key, 0), do: id
      nil -> nil
    end
  end

  defp project_of(_caller), do: nil
end
