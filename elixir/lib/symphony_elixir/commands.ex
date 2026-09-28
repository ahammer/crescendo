defmodule SymphonyElixir.Commands do
  @moduledoc """
  Local operator commands. They change local files, or a project's own
  repository through the operator's `gh` login, never the running service:

      crescendo project add <crescendo.yml> <id> <owner/repo> [--branch main] [--prefix crescendo] [--tools java@21,gradle@8]
      crescendo labels sync <crescendo.yml> [<project>]
      crescendo drain on|off <crescendo.yml>

  `project add` writes `projects/<id>/` from the built-in templates (never
  overwriting) and prints the line to add under `projects:`. `labels sync`
  creates the labels a project's workflow uses that its repository lacks.
  `drain on` holds all new dispatch (running work finishes); `drain off`
  releases it.
  """

  alias SymphonyElixir.{Config.Schema, Service, Workflow}

  @templates Path.expand("../../priv/templates/project", __DIR__)
  @template_files ["WORKFLOW.md.eex", "prompts/pull_request.md.eex", "prompts/research.md.eex"]
  for file <- @template_files, do: @external_resource(Path.join(@templates, file))
  @template_sources Map.new(@template_files, &{&1, File.read!(Path.join(@templates, &1))})
  @codex "codex --config shell_environment_policy.inherit=all app-server"

  @type gh :: ([String.t()] -> {String.t(), non_neg_integer()})

  @doc "Runs a command with `gh` running the GitHub CLI, or returns `:not_a_command` (the service start)."
  @spec run([String.t()], gh()) :: :ok | {:error, String.t()} | :not_a_command

  def run(["project", "add" | rest], _gh), do: with_service_dir(rest, &project_add/2)
  def run(["labels", "sync", path | projects], gh), do: labels_sync(path, projects, gh)
  def run(["drain", mode, path], _gh) when mode in ["on", "off"], do: drain(mode, path)
  def run(["project" | _rest], _gh), do: {:error, usage()}
  def run(["labels" | _rest], _gh), do: {:error, usage()}
  def run(["drain" | _rest], _gh), do: {:error, usage()}
  def run(_args, _gh), do: :not_a_command

  @spec usage() :: String.t()
  def usage do
    """
    Usage:
      crescendo project add <crescendo.yml> <id> <owner/repo> [--branch main] [--prefix crescendo] [--tools java@21]
      crescendo labels sync <crescendo.yml> [<project>...]
      crescendo drain on|off <crescendo.yml>
    """
  end

  defp with_service_dir([path | rest], fun), do: fun.(Path.dirname(Path.expand(path)), rest)
  defp with_service_dir([], _fun), do: {:error, usage()}

  defp project_add(dir, args) do
    case OptionParser.parse(args, strict: [branch: :string, prefix: :string, tools: :string]) do
      {opts, [id, repo], []} -> write_project(dir, id, repo, opts)
      _ -> {:error, usage()}
    end
  end

  defp write_project(dir, id, repo, opts) do
    target = Path.join([dir, "projects", id])

    cond do
      not Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, id) -> {:error, "project ids are lowercase letters, digits, or dashes"}
      not Regex.match?(~r{^[\w.-]+/[\w.-]+$}, repo) -> {:error, "the repository must be owner/name"}
      File.exists?(target) -> {:error, "#{target} already exists; nothing was written"}
      true -> render_project(target, id, repo, opts)
    end
  end

  defp render_project(target, id, repo, opts) do
    tools = opts |> Keyword.get(:tools, "") |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    assigns = [
      id: id,
      repo: repo,
      owner: repo |> String.split("/") |> hd(),
      prefix: Keyword.get(opts, :prefix, "crescendo"),
      base_branch: Keyword.get(opts, :branch, "main"),
      codex_command: if(tools == [], do: @codex, else: "mise exec #{Enum.join(tools, " ")} -- #{@codex}")
    ]

    for {file, source} <- @template_sources do
      path = Path.join(target, String.replace_suffix(file, ".eex", ""))
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, EEx.eval_string(source, assigns: assigns))
    end

    IO.puts("Wrote #{target}.\nAdd it to the service file under `projects:` and restart the service:\n  #{id}: {weight: 1}")
    :ok
  end

  defp labels_sync(path, only, gh) do
    with {:ok, service} <- Service.load(path) do
      service
      |> Service.projects()
      |> Enum.filter(&(only == [] or &1.id in only))
      |> Enum.find_value(:ok, &sync_error(&1, gh))
    end
  end

  defp sync_error(project, gh) do
    case sync_project(project, gh) do
      :ok -> nil
      error -> error
    end
  end

  defp sync_project(project, gh) do
    with {:ok, workflow} <- Workflow.load(project.workflow, project.defaults),
         {:ok, settings} <- Schema.parse(workflow.config),
         repo when is_binary(repo) <- settings.tracker.provider["repo"] do
      existing = existing_labels(repo, gh)

      for {name, _color, _description} = label <- labels(settings), String.downcase(name) not in existing, do: create_label(project.id, repo, label, gh)

      :ok
    else
      nil -> {:error, "#{project.id}: tracker.provider.repo is not set"}
      {:error, reason} -> {:error, "#{project.id}: #{inspect(reason)}"}
    end
  end

  defp create_label(id, repo, {name, color, description}, gh) do
    case gh.(["label", "create", name, "--repo", repo, "--color", color, "--description", description]) do
      {_output, 0} -> IO.puts("#{id}: created #{name}")
      {output, _status} -> IO.puts("#{id}: could not create #{name}: #{String.trim(output)}")
    end
  end

  defp existing_labels(repo, gh) do
    case gh.(["label", "list", "--repo", repo, "--limit", "500", "--json", "name", "--jq", ".[].name"]) do
      {output, 0} -> output |> String.split("\n", trim: true) |> Enum.map(&String.downcase/1)
      _ -> []
    end
  end

  # Every label the workflow reads or tells agents to apply, with what it means.
  defp labels(settings) do
    prefix = settings.labels.prefix
    routing = settings.codex.routing || %{}
    size_prefix = routing["size_label_prefix"] || "#{prefix}:size:"

    # The blocked label comes first: it is also excluded, and its own description wins.
    ([{settings.autopilot.blocked_label, "ededed", "The last attempt ended blocked; Crescendo retries it later."}] ++
       Enum.map(settings.tracker.required_labels, &{&1, "0e8a16", "Authorizes Crescendo to work on this issue."}) ++
       Enum.map(settings.tracker.excluded_labels, &{&1, "bfd4f2", excluded_description(&1, prefix)}) ++
       Enum.map(Map.keys(settings.autopilot.channels), &{"#{prefix}:channel:#{&1}", "d4c5f9", "Filed by Crescendo's #{&1} research."}) ++
       Enum.map(Map.keys(routing["sizes"] || %{}), &{size_prefix <> &1, "c2e0c6", "Starts on a cheaper model; failed attempts escalate."}) ++
       Enum.map(routing["labels"] || %{}, fn {label, route} ->
         {label, "fbca04", "Start this issue on #{route["model"]} #{route["effort"]}; failed attempts escalate."}
       end))
    |> Enum.uniq_by(fn {name, _color, _description} -> String.downcase(name) end)
  end

  defp excluded_description(label, prefix) do
    if label == "#{prefix}:in-review",
      do: "A pull request is delivering this issue.",
      else: "Crescendo leaves this alone while the label is present."
  end

  defp drain(mode, path) do
    with {:ok, service} <- Service.load(path) do
      file = Path.join(Service.state_root(service), "drain")

      if mode == "on" do
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, DateTime.utc_now() |> DateTime.to_iso8601())
        IO.puts("Draining: no new runs start until `crescendo drain off`.")
      else
        File.rm(file)
        IO.puts("Drain off: dispatch resumes.")
      end

      :ok
    end
  end
end
