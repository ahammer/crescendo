defmodule SymphonyElixir.Codex.Usage do
  @moduledoc "Normalizes cumulative thread usage without charging context estimates or subsets twice."

  @fields [
    :input_tokens,
    :cached_input_tokens,
    :cache_write_input_tokens,
    :output_tokens,
    :reasoning_output_tokens
  ]
  @input_keys ["inputTokens", :inputTokens, "input_tokens", :input_tokens, "prompt_tokens", :prompt_tokens]
  @output_keys [
    "outputTokens",
    :outputTokens,
    "output_tokens",
    :output_tokens,
    "completion_tokens",
    :completion_tokens
  ]

  @spec snapshot(map()) :: map() | nil
  def snapshot(update) do
    payload = update[:payload] || update
    params = get(payload, "params", :params) || %{}

    {source, usage} = cumulative(get(payload, "method", :method), params)

    if is_map(usage) do
      %{
        source: source,
        turn_id: get(params, "turnId", :turnId),
        complete: observed?(usage, @input_keys) and observed?(usage, @output_keys),
        thread_id: get(params, "threadId", :threadId) || get(params, "id", :id) || update[:thread_id],
        total: normalize(usage),
        reported_total_tokens: integer(get(usage, "totalTokens", :totalTokens) || get(usage, "total_tokens", :total_tokens)),
        model_context_window: context_window(params)
      }
    end
  end

  defp cumulative("thread/tokenUsage/updated", params),
    do: {:canonical, get(get(params, "tokenUsage", :tokenUsage), "total", :total)}

  defp cumulative("codex/event/token_count", params) do
    msg = get(params, "msg", :msg) || %{}
    info = get(get(msg, "payload", :payload) || msg, "info", :info)
    {:legacy, get(info, "total_token_usage", :total_token_usage)}
  end

  defp cumulative(_, _), do: {nil, nil}

  defp context_window(params) do
    canonical = get(get(params, "tokenUsage", :tokenUsage), "modelContextWindow", :modelContextWindow)
    msg = get(params, "msg", :msg) || %{}
    info = get(get(msg, "payload", :payload) || msg, "info", :info)
    integer(canonical || get(info, "model_context_window", :model_context_window))
  end

  @spec normalize(map()) :: map()
  def normalize(usage) do
    input = counter(usage, @input_keys)
    output = counter(usage, @output_keys)

    write_keys = [
      "cacheWriteInputTokens",
      :cacheWriteInputTokens,
      "cacheWriteTokens",
      :cacheWriteTokens,
      "cache_write_tokens",
      :cache_write_tokens,
      "cache_write_input_tokens",
      :cache_write_input_tokens
    ]

    write = counter(usage, write_keys)

    %{
      input_tokens: input,
      cached_input_tokens:
        min(
          input,
          counter(usage, [
            "cachedInputTokens",
            :cachedInputTokens,
            "cached_input_tokens",
            :cached_input_tokens
          ])
        ),
      cache_write_input_tokens: min(input, write),
      output_tokens: output,
      reasoning_output_tokens:
        min(
          output,
          counter(usage, [
            "reasoningOutputTokens",
            :reasoningOutputTokens,
            "reasoning_output_tokens",
            :reasoning_output_tokens
          ])
        ),
      total_tokens: input + output
    }
  end

  @spec delta(map(), map()) :: {map(), map()}
  def delta(previous, total) do
    watermark = Map.new(@fields, &{&1, max(Map.get(previous, &1, 0), Map.get(total, &1, 0))})
    delta = Map.new(@fields, &{&1, watermark[&1] - Map.get(previous, &1, 0)})

    {Map.put(watermark, :total_tokens, watermark.input_tokens + watermark.output_tokens), Map.put(delta, :total_tokens, delta.input_tokens + delta.output_tokens)}
  end

  defp counter(map, keys), do: Enum.find_value(keys, &integer(Map.get(map, &1))) || 0
  defp observed?(map, keys), do: Enum.any?(keys, &(not is_nil(integer(Map.get(map, &1)))))
  defp integer(value) when is_integer(value) and value >= 0, do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _ -> nil
    end
  end

  defp integer(_), do: nil
  defp get(map, key, atom) when is_map(map), do: Map.get(map, key) || Map.get(map, atom)
  defp get(_, _, _), do: nil
end
