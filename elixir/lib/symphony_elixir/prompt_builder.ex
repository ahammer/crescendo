defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from normalized tracker work item data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Tracker.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!(Map.get(issue, :kind, :issue), issue)
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "item_attempt" => Keyword.get(opts, :item_attempt, 1),
        "final_attempt" => Keyword.get(opts, :final_attempt, false),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}, :issue, _issue), do: default_prompt(prompt)

  defp prompt_template!({:ok, workflow}, kind, issue) do
    templates = Map.get(workflow, :prompt_templates, %{})
    Enum.find_value(template_keys(kind, issue), &Map.get(templates, &1)) || raise(RuntimeError, "missing_prompt_template: #{kind}")
  end

  defp prompt_template!({:error, reason}, _kind, _issue) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  # A research channel's own prompt wins over the shared research prompt.
  defp template_keys(:research, %{research: %{channel: channel}}) when is_binary(channel), do: ["research:#{channel}", "research"]
  defp template_keys(kind, _issue), do: [Atom.to_string(kind)]

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value) when is_atom(value) and not is_boolean(value) and not is_nil(value), do: Atom.to_string(value)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
