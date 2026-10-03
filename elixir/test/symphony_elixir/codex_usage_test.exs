defmodule SymphonyElixir.CodexUsageTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Codex.Usage

  test "canonical snapshots preserve subsets and separate context estimates from spend" do
    usage = %{
      "inputTokens" => "100",
      "cachedInputTokens" => 80,
      "cacheWriteTokens" => 5,
      "outputTokens" => 20,
      "reasoningOutputTokens" => 10,
      "totalTokens" => 400_000
    }

    assert %{source: :canonical, thread_id: "thread", reported_total_tokens: 400_000, total: total} =
             Usage.snapshot(%{
               payload: %{
                 "method" => "thread/tokenUsage/updated",
                 "params" => %{"threadId" => "thread", "tokenUsage" => %{"total" => usage}}
               }
             })

    assert total == %{
             input_tokens: 100,
             cached_input_tokens: 80,
             cache_write_input_tokens: 5,
             output_tokens: 20,
             reasoning_output_tokens: 10,
             total_tokens: 120
           }

    assert Usage.snapshot(%{method: "thread/tokenUsage/updated", params: %{tokenUsage: %{last: usage}}}) ==
             nil
  end

  test "legacy usage needs its event-specific cumulative envelope" do
    usage = %{prompt_tokens: "12", completion_tokens: 4, cached_input_tokens: 99, reasoning_output_tokens: 99}

    assert %{
             source: :legacy,
             thread_id: "legacy",
             total: %{input_tokens: 12, output_tokens: 4, cached_input_tokens: 12, reasoning_output_tokens: 4}
           } =
             Usage.snapshot(%{
               thread_id: "legacy",
               payload: %{
                 method: "codex/event/token_count",
                 params: %{msg: %{info: %{total_token_usage: usage}}}
               }
             })

    assert %{total: %{input_tokens: 12}} =
             Usage.snapshot(%{
               "method" => "codex/event/token_count",
               "params" => %{"msg" => %{"payload" => %{"info" => %{"total_token_usage" => usage}}}}
             })

    for update <- [
          %{payload: "bad"},
          %{usage: usage},
          %{method: "turn/completed", usage: usage},
          %{method: "other", params: nil}
        ] do
      assert Usage.snapshot(update) == nil
    end
  end

  test "watermarks survive lower, missing and malformed counters" do
    previous = Usage.normalize(%{input_tokens: 100, output_tokens: 20, cached_input_tokens: 80})

    malformed =
      Usage.normalize(%{
        input_tokens: "12x",
        output_tokens: -1,
        cached_input_tokens: 1.5,
        cache_write_tokens: "-1"
      })

    assert malformed.total_tokens == 0
    {watermark, delta} = Usage.delta(previous, malformed)
    assert watermark == Map.merge(malformed, previous)
    assert Enum.all?(delta, fn {_, count} -> count == 0 end)

    {_, delta} =
      Usage.delta(
        watermark,
        Usage.normalize(%{
          input_tokens: 120,
          output_tokens: 25,
          cached_input_tokens: 90,
          cache_write_input_tokens: 3,
          reasoning_output_tokens: 2
        })
      )

    assert delta == %{
             input_tokens: 20,
             output_tokens: 5,
             cached_input_tokens: 10,
             cache_write_input_tokens: 3,
             reasoning_output_tokens: 2,
             total_tokens: 25
           }
  end

  test "native cache-write names, context limits and incomplete parents are explicit" do
    usage = %{"inputTokens" => 100, "outputTokens" => 20, "cacheWriteInputTokens" => 10}

    assert %{complete: true, model_context_window: 258_400, total: %{cache_write_input_tokens: 10}} =
             Usage.snapshot(%{
               "method" => "thread/tokenUsage/updated",
               "params" => %{
                 "turnId" => "turn",
                 "tokenUsage" => %{"total" => usage, "modelContextWindow" => 258_400}
               }
             })

    assert %{complete: false} =
             Usage.snapshot(%{
               "method" => "thread/tokenUsage/updated",
               "params" => %{"tokenUsage" => %{"total" => %{}}}
             })

    assert %{model_context_window: 400_000} =
             Usage.snapshot(%{
               "method" => "codex/event/token_count",
               "params" => %{
                 "msg" => %{"info" => %{"model_context_window" => 400_000, "total_token_usage" => usage}}
               }
             })
  end
end
