defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Dispatches client-side tool calls to the configured tracker adapter.
  """

  alias SymphonyElixir.{Helpers, Tracker}

  @spec execute(String.t() | nil, term(), map(), keyword()) :: map()
  def execute(tool, arguments, binding, opts \\ []) do
    if tool in Helpers.tool_names() and binding[:helper_context],
      do: Helpers.execute(tool, arguments, binding.helper_context),
      else: Tracker.execute_bound_agent_tool(binding, tool, arguments, opts)
  end

  @spec bind(keyword()) :: map()
  def bind(opts \\ []) do
    binding = Tracker.bind_agent_tools()

    case Keyword.get(opts, :helper_context) do
      %{run_id: run_id} = context when is_binary(run_id) ->
        context = Map.put(context, :secret_environment_names, binding.secret_environment_names)

        if Helpers.enabled?(),
          do: binding |> Map.put(:helper_context, context) |> Map.update!(:tool_specs, &(&1 ++ Helpers.tool_specs())),
          else: binding

      _ ->
        binding
    end
  end
end
