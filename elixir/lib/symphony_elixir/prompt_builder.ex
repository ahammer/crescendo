defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from normalized tracker work item data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Tracker.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    workflow = Workflow.current()

    template =
      workflow
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
    |> append_sections(issue, workflow, opts)
  end

  # Generated sections follow the template, so repository guidelines and task
  # rules reach every prompt without template edits. Guidelines are plain
  # text, never rendered as a template.
  defp append_sections(prompt, issue, {:ok, workflow}, opts) do
    sections = [deliverables(issue), task_scope(issue), guidelines(workflow), handoff(issue, opts)]

    ([prompt | sections] ++ [quiet_continuation(issue, opts)])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp quiet_continuation(%{kind: :issue}, opts) do
    case Keyword.get(opts, :quiet_continuation) do
      nil ->
        if Keyword.get(opts, :quiet_continuation_available, false) do
          """
          ## Prepared quiet acceptance

          A prepared delivery can yield once per logical attempt with `defer_quiet_acceptance`
          until the configured quiet window. Commit preparation and evidence, keep the existing PR draft,
          and pass its URL, exact HEAD, committed evidence paths, durable reason and all unmet acceptance.
          Include failed product gates explicitly. Deferral does not pass them. After tool success update
          the workpad and end the turn without a blocked label; do not wait or poll the window.
          """
        end

      prepared ->
        """
        ## Resume prepared quiet acceptance

        Continue the same canonical issue and logical attempt. Reuse exactly this PR: #{prepared.pull_request}.
        Retained preparation (including source and evidence digest revalidation): #{Jason.encode!(prepared)}
        Recheck evidence applicability against the current source, task and environment before reuse.
        If evidence_applicable is false, repair or regenerate stale evidence; retained evidence proves no current gate.
        Complete every unmet acceptance gate, including product failures. Deferral is never accepted delivery.
        No second quiet deferral is available in this attempt. If acceptance cannot be achieved, follow
        the existing blocked/final-attempt reduced-scope or retirement rules; do not clone the issue or PR.
        """
    end
  end

  defp quiet_continuation(_issue, _opts), do: nil

  defp handoff(%{kind: :issue}, opts) do
    if Keyword.get(opts, :final_attempt, false), do: SymphonyElixir.Handoff.instructions()
  end

  defp handoff(_issue, _opts), do: nil

  defp guidelines(workflow) do
    case Map.get(workflow.prompt_templates, "guidelines") do
      text when is_binary(text) and text != "" -> "## Repository guidelines\n\n" <> text
      _ -> nil
    end
  end

  defp deliverables(%{kind: :research, research: research, labels: labels}) when is_map(research) do
    label = Enum.find(labels, &String.contains?(&1, ":channel:"))
    pulls = research[:pull_requests]

    lines =
      [
        "- Issues: at least #{research.min_issues} and at most #{research.max_issues}, each labelled `#{label}`.",
        pulls && "- Pull requests: at least #{pulls.min}#{if pulls.max, do: " and at most #{pulls.max}"}, each labelled `#{label}`" <> path_rule(pulls.paths) <> ".",
        "- Crescendo counts what this run opens with that label. Falling short counts as a failed attempt and the task is retried later."
      ] ++ Enum.map(research[:expectations] || [], &"- Expectation: #{&1}")

    "## Deliverables\n\n" <> (lines |> Enum.reject(&is_nil/1) |> Enum.join("\n"))
  end

  defp deliverables(_issue), do: nil

  defp path_rule([]), do: ""
  defp path_rule(paths), do: ", changing only #{Enum.map_join(paths, ", ", &"`#{&1}`")}"

  # A pull request opened by a task that limits its paths is reviewed against them.
  defp task_scope(%{kind: :pull_request, labels: labels}) do
    scoped =
      for label <- labels,
          [_prefix, channel] <- [String.split(label, ":channel:", parts: 2)],
          %{"delivers" => %{"pull_requests" => %{"paths" => [_ | _] = paths}}} <- [Map.get(Config.settings!().autopilot.channels, channel)],
          do:
            "This pull request comes from the `#{channel}` task, which may only change #{Enum.map_join(paths, ", ", &"`#{&1}`")}. " <>
              "If it changes anything else, close it as out of scope and say which files broke the rule."

    if scoped == [], do: nil, else: "## Task scope\n\n" <> Enum.join(scoped, "\n\n")
  end

  defp task_scope(_issue), do: nil

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
