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
  """
  @spec load(Path.t(), map()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path, defaults \\ %{}) when is_binary(path) and is_map(defaults) do
    case File.read(path) do
      {:ok, content} ->
        with {:ok, workflow} <- parse(content) do
          load_prompt_files(%{workflow | config: deep_merge(defaults, workflow.config)}, Path.dirname(Path.expand(path)))
        end

      {:error, reason} ->
        {:error, {:missing_workflow_file, path, reason}}
    end
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
        %{"autopilot" => %{} = autopilot} -> kind_prompts(autopilot) ++ channel_prompts(autopilot)
        _ -> []
      end

    Enum.reduce_while(prompts, {:ok, workflow}, fn {kind, relative_path}, {:ok, acc} ->
      path = Path.expand(to_string(relative_path), base_dir)

      case File.read(path) do
        {:ok, template} ->
          {:cont,
           {:ok,
            %{
              acc
              | prompt_templates: Map.put(acc.prompt_templates, to_string(kind), String.trim(template)),
                prompt_paths: [path | acc.prompt_paths]
            }}}

        {:error, reason} ->
          {:halt, {:error, {:missing_prompt_file, path, reason}}}
      end
    end)
  end

  @doc "Merges `override` into `base`: nested maps merge, anything else is replaced."
  @spec deep_merge(map(), map()) :: map()
  def deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn
      _key, %{} = left, %{} = right -> deep_merge(left, right)
      _key, _left, right -> right
    end)
  end

  defp kind_prompts(%{"prompts" => %{} = prompts}), do: prompts |> Map.take(["pull_request", "research"]) |> Enum.to_list()
  defp kind_prompts(_autopilot), do: []

  defp channel_prompts(%{"channels" => %{} = channels}),
    do: for({name, %{"prompt" => path}} <- channels, is_binary(path) and String.trim(path) != "", do: {"research:#{name}", path})

  defp channel_prompts(_autopilot), do: []

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
