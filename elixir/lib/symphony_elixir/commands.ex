defmodule SymphonyElixir.Commands do
  @moduledoc """
  Local operator commands. They change local files, or a project's own
  repository through the operator's `gh` login, never the running service:

      crescendo project add <crescendo.yml> <id> <owner/repo> [--branch main] [--prefix crescendo] [--tools java@21,gradle@8]
      crescendo labels sync <crescendo.yml> [<project>]
      crescendo labels migrate <crescendo.yml> <project> --from <old-prefix>
      crescendo drain on|off <crescendo.yml>

  `project add` writes `projects/<id>/` from the built-in templates (never
  overwriting) and prints the line to add under `projects:`. `labels sync`
  creates the labels a project's workflow uses that its repository lacks.
  `labels migrate` moves every open issue and pull request from each
  `<old-prefix>:` label to its twin under the project's prefix (run
  `labels sync` first); the old labels stay for history.
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
  def run(["labels", "migrate", path, project, "--from", old], gh), do: labels_migrate(path, project, old, gh)
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
      crescendo labels migrate <crescendo.yml> <project> --from <old-prefix>
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
    prefix = Keyword.get(opts, :prefix, "crescendo")

    cond do
      not Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, id) ->
        {:error, "project ids are lowercase letters, digits, or dashes"}

      not Regex.match?(~r{^[\w.-]+/[\w.-]+$}, repo) ->
        {:error, "the repository must be owner/name"}

      File.exists?(target) ->
        {:error, "#{target} already exists; nothing was written"}

      true ->
        with {:ok, prefix} <- validate_label_prefix(prefix), do: render_project(target, id, repo, Keyword.put(opts, :prefix, prefix))
    end
  end

  defp validate_label_prefix(prefix) do
    case Schema.parse(%{"labels" => %{"prefix" => prefix}}) do
      {:ok, settings} -> {:ok, settings.labels.prefix}
      {:error, {:invalid_workflow_config, reason}} -> {:error, "invalid --prefix value #{inspect(prefix)}: #{reason}"}
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
      projects = Service.projects(service)

      case validate_requested_projects(only, projects) do
        :ok ->
          projects
          |> Enum.filter(&(only == [] or &1.id in only))
          |> Enum.find_value(:ok, &sync_error(&1, gh))

        error ->
          error
      end
    end
  end

  defp validate_requested_projects(only, projects) do
    case Enum.find(only, fn id -> not Enum.any?(projects, &(&1.id == id)) end) do
      nil -> :ok
      id -> {:error, "no project #{id}"}
    end
  end

  defp sync_error(project, gh) do
    case sync_project(project, gh) do
      :ok -> nil
      error -> error
    end
  end

  defp sync_project(project, gh) do
    with {:ok, settings, repo} <- project_settings(project),
         {:ok, existing} <- existing_labels(project.id, repo, gh) do
      Enum.reduce_while(labels(settings), :ok, &sync_label(&1, &2, project.id, repo, existing, gh))
    end
  end

  defp sync_label({name, _color, _description} = label, :ok, id, repo, existing, gh) do
    if String.downcase(name) in existing do
      {:cont, :ok}
    else
      case create_label(id, repo, label, gh) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end
  end

  defp labels_migrate(path, id, old_prefix, gh) do
    with {:ok, service} <- Service.load(path),
         %Service.Project{} = project <- Enum.find(Service.projects(service), &(&1.id == id)) || {:error, "no project #{id}"},
         {:ok, settings, repo} <- project_settings(project) do
      prefix = settings.labels.prefix

      labels(settings)
      |> Enum.filter(fn {name, _color, _description} -> String.starts_with?(name, prefix <> ":") end)
      |> Enum.reduce_while(:ok, &migrate_label_entry(&1, &2, id, repo, prefix, old_prefix, gh))
    end
  end

  defp migrate_label_entry({name, _color, _description}, :ok, id, repo, prefix, old_prefix, gh) do
    old = old_prefix <> String.replace_prefix(name, prefix, "")

    case migrate_label(id, repo, old, name, gh) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp project_settings(project) do
    with {:ok, workflow} <- Workflow.load(project.workflow, project.defaults),
         {:ok, settings} <- Schema.parse(workflow.config),
         repo when is_binary(repo) <- settings.tracker.provider["repo"] do
      {:ok, settings, repo}
    else
      nil -> {:error, "#{project.id}: tracker.provider.repo is not set"}
      {:error, reason} -> {:error, "#{project.id}: #{inspect(reason)}"}
    end
  end

  # The issues API lists pull requests too, and labels them the same way.
  defp open_items(repo, label, gh) do
    case gh.(["api", "--paginate", "repos/#{repo}/issues?state=open&per_page=100&labels=#{URI.encode_www_form(label)}", "--jq", ".[].number"]) do
      {output, 0} -> {:ok, String.split(output, "\n", trim: true)}
      {output, _status} -> {:error, String.trim(output)}
    end
  end

  defp migrate_label(id, repo, old, new, gh) do
    case open_items(repo, old, gh) do
      {:ok, items} ->
        Enum.reduce_while(items, :ok, &migrate_item(&1, &2, id, repo, old, new, gh))

      {:error, reason} ->
        {:error, "#{id}: #{old}: could not list items: #{reason}"}
    end
  end

  defp migrate_item(number, :ok, id, repo, old, new, gh) do
    case move_label(id, repo, number, old, new, gh) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp move_label(id, repo, number, old, new, gh) do
    case gh.(["api", "-X", "POST", "repos/#{repo}/issues/#{number}/labels", "-f", "labels[]=#{new}"]) do
      {_output, 0} ->
        case gh.(["api", "-X", "DELETE", "repos/#{repo}/issues/#{number}/labels/#{URI.encode(old)}"]) do
          {_output, 0} ->
            IO.puts("#{id}: ##{number} #{old} -> #{new}")
            :ok

          {output, _status} ->
            {:error, "#{id}: ##{number} could not remove #{old} after adding #{new}: #{String.trim(output)}"}
        end

      {output, _status} ->
        {:error, "#{id}: ##{number} could not add #{new} while moving #{old}: #{String.trim(output)}"}
    end
  end

  defp create_label(id, repo, {name, color, description}, gh) do
    case gh.(["label", "create", name, "--repo", repo, "--color", color, "--description", description]) do
      {_output, 0} ->
        IO.puts("#{id}: created #{name}")
        :ok

      {output, _status} ->
        {:error, "#{id}: could not create #{name}: #{String.trim(output)}"}
    end
  end

  defp existing_labels(id, repo, gh) do
    case gh.(["label", "list", "--repo", repo, "--limit", "500", "--json", "name", "--jq", ".[].name"]) do
      {output, 0} -> {:ok, output |> String.split("\n", trim: true) |> Enum.map(&String.downcase/1)}
      {output, _status} -> {:error, "#{id}: could not list labels: #{String.trim(output)}"}
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
      change_drain(mode, file)
    end
  end

  defp change_drain("on", file) do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, DateTime.utc_now() |> DateTime.to_iso8601())
    IO.puts("Draining: no new runs start until `crescendo drain off`.")
    :ok
  end

  defp change_drain("off", file) do
    case File.rm(file) do
      :ok ->
        IO.puts("Drain off: dispatch resumes.")
        :ok

      {:error, reason} ->
        {:error, "could not remove drain flag #{file}: #{:file.format_error(reason)}"}
    end
  end
end
