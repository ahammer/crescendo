defmodule SymphonyElixir.Workflow do
  @moduledoc """
  Loads workflow configuration and prompt from WORKFLOW.md.
  """

  alias SymphonyElixir.WorkflowStore

  @workflow_file_name "WORKFLOW.md"

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path) ||
      Path.join(File.cwd!(), @workflow_file_name)
  end

  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :workflow_file_path, path)
    maybe_reload_store()
    :ok
  end

  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    maybe_reload_store()
    :ok
  end

  @type loaded_workflow :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t(),
          prompt_templates: %{optional(String.t()) => String.t()},
          prompt_paths: [Path.t()]
        }

  @spec current() :: {:ok, loaded_workflow()} | {:error, term()}
  def current, do: WorkflowStore.current()

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    load(workflow_file_path())
  end

  @doc """
  Loads a workflow file. `defaults` (service-wide settings) are merged under
  its front matter: maps merge key by key and the file's values win.

  `overlay` is the local mirror of the repository's `.crescendo/autopilot/`
  folder (see `SymphonyElixir.RepoAutopilot`). When it holds tasks, they
  replace `autopilot.channels` (less `autopilot.disabled_tasks`), unless
  `autopilot.repo_tasks` is false, and its `guidelines.md` joins every
  prompt. Everything the service owns (routes, budget, trust) stays local.
  """
  @spec load(Path.t(), map(), Path.t() | nil) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path, defaults \\ %{}, overlay \\ nil) when is_binary(path) and is_map(defaults) do
    case File.read(path) do
      {:ok, content} ->
        with {:ok, workflow} <- parse(content),
             config = deep_merge(defaults, workflow.config),
             {:ok, config, overlay_paths} <- apply_overlay(config, overlay),
             {:ok, loaded} <- load_prompt_files(%{workflow | config: config}, Path.dirname(Path.expand(path))) do
          {:ok, %{loaded | prompt_paths: overlay_paths ++ loaded.prompt_paths}}
        end

      {:error, reason} ->
        {:error, {:missing_workflow_file, path, reason}}
    end
  end

  @doc """
  Reads a repository autopilot folder (or its mirror): its settings, its
  guidelines file and one channel object per `tasks/<name>.md`, with the
  task file as the channel's prompt.
  """
  @spec read_autopilot_folder(Path.t()) ::
          {:ok, %{channels: map(), guidelines: Path.t() | nil, paths: [Path.t()]}} | {:error, term()}
  def read_autopilot_folder(dir) do
    settings_path = Path.join(dir, "autopilot.yml")

    with {:ok, settings} <- read_folder_settings(settings_path),
         {:ok, channels} <- read_tasks(Path.join(dir, "tasks"), Map.get(settings, "defaults") || %{}) do
      guidelines = Path.join(dir, Map.get(settings, "guidelines") || "guidelines.md")
      guidelines = if File.regular?(guidelines), do: guidelines, else: nil
      paths = Enum.filter([settings_path], &File.regular?/1)
      {:ok, %{channels: channels, guidelines: guidelines, paths: paths}}
    end
  end

  defp apply_overlay(config, overlay) do
    autopilot = Map.get(config, "autopilot") || %{}

    if is_nil(overlay) or not File.dir?(overlay) or autopilot["repo_tasks"] == false do
      {:ok, config, []}
    else
      case read_autopilot_folder(overlay) do
        {:ok, folder} -> {:ok, Map.put(config, "autopilot", merge_folder(autopilot, folder)), folder.paths}
        {:error, reason} -> {:error, {:repo_autopilot, reason}}
      end
    end
  end

  defp merge_folder(autopilot, folder) do
    channels = Map.drop(folder.channels, List.wrap(autopilot["disabled_tasks"]))
    autopilot = if channels == %{}, do: autopilot, else: Map.put(autopilot, "channels", channels)
    if folder.guidelines, do: Map.put(autopilot, "guidelines", folder.guidelines), else: autopilot
  end

  defp read_folder_settings(path) do
    case File.read(path) do
      {:ok, yaml} ->
        case front_matter_yaml_to_map(String.split(yaml, ~r/\R/)) do
          {:ok, settings} -> {:ok, settings}
          {:error, reason} -> {:error, {:invalid_autopilot_yml, reason}}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:unreadable, path, reason}}
    end
  end

  # Each task file is YAML front matter (schedule, deliveries, expectations)
  # over its seed prompt; `defaults` from autopilot.yml fill what it omits.
  defp read_tasks(dir, defaults) do
    files = if File.dir?(dir), do: dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".md")) |> Enum.sort(), else: []

    Enum.reduce_while(files, {:ok, %{}}, fn file, {:ok, acc} ->
      path = Path.join(dir, file)

      case File.read!(path) |> parse() do
        {:ok, %{config: front}} ->
          channel = Map.merge(%{"focus" => Path.rootname(file)}, defaults) |> Map.merge(front) |> Map.merge(%{"prompt" => path, "source" => "repo"})
          {:cont, {:ok, Map.put(acc, Path.rootname(file), channel)}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_task, file, reason}}}
      end
    end)
  end

  defp parse(content) do
    {front_matter_lines, prompt_lines} = split_front_matter(content)

    case front_matter_yaml_to_map(front_matter_lines) do
      {:ok, front_matter} ->
        prompt = Enum.join(prompt_lines, "\n") |> String.trim()

        {:ok,
         %{
           config: front_matter,
           prompt: prompt,
           prompt_template: prompt,
           prompt_templates: %{},
           prompt_paths: []
         }}

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  # `autopilot.prompts` maps a work-item kind to a template file resolved
  # relative to WORKFLOW.md, and a research channel may name its own file
  # (`research:<channel>`). The WORKFLOW.md body stays the issue prompt.
  defp load_prompt_files(%{config: config} = workflow, base_dir) do
    # Unknown kinds are left for schema validation to reject.
    prompts =
      case config do
        %{"autopilot" => %{} = autopilot} -> autopilot_prompts(autopilot)
        _ -> []
      end

    Enum.reduce_while(prompts, {:ok, workflow}, fn {kind, relative_path}, {:ok, acc} ->
      path = Path.expand(to_string(relative_path), base_dir)

      case read_prompt(path) do
        {:ok, template} ->
          templates = Map.put(acc.prompt_templates, to_string(kind), template)
          {:cont, {:ok, %{acc | prompt_templates: templates, prompt_paths: [path | acc.prompt_paths]}}}

        {:error, reason} ->
          {:halt, {:error, {:missing_prompt_file, path, reason}}}
      end
    end)
  end

  # A prompt file may carry front matter (repository task files do); the template is its body.
  defp read_prompt(path) do
    with {:ok, content} <- File.read(path) do
      {_front, body} = split_front_matter(content)
      {:ok, String.trim(if body == [], do: content, else: Enum.join(body, "\n"))}
    end
  end

  @doc "Merges `override` into `base`: nested maps merge, anything else is replaced."
  @spec deep_merge(map(), map()) :: map()
  def deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn
      _key, %{} = left, %{} = right -> deep_merge(left, right)
      _key, _left, right -> right
    end)
  end

  defp autopilot_prompts(autopilot), do: kind_prompts(autopilot) ++ channel_prompts(autopilot) ++ guideline_prompts(autopilot)

  defp kind_prompts(%{"prompts" => %{} = prompts}), do: prompts |> Map.take(["pull_request", "research"]) |> Enum.to_list()
  defp kind_prompts(_autopilot), do: []

  defp channel_prompts(%{"channels" => %{} = channels}),
    do: for({name, %{"prompt" => path}} <- channels, is_binary(path) and String.trim(path) != "", do: {"research:#{name}", path})

  defp channel_prompts(_autopilot), do: []

  defp guideline_prompts(%{"guidelines" => path}) when is_binary(path) and path != "", do: [{"guidelines", path}]
  defp guideline_prompts(_autopilot), do: []

  defp split_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  defp front_matter_yaml_to_map(lines) do
    yaml = Enum.join(lines, "\n")

    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :workflow_front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_reload_store do
    if Process.whereis(WorkflowStore) do
      _ = WorkflowStore.force_reload()
    end

    :ok
  end
end
