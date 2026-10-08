defmodule SymphonyElixir.HelperOutputTest do
  use SymphonyElixir.TestSupport

  test "native content maps and tool previews are bounded without changing control fields or action arguments" do
    root = Path.join(System.tmp_dir!(), "crescendo-helper-output-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspaces/lead")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    observed = Path.join(root, "observed.jsonl")
    peer = Path.expand("../fixtures/helper_app_server.py", __DIR__)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(root, "workspaces"), codex_command: "python3 '#{peer}' '#{observed}' large-previews")
    recipient = self()

    executor = fn "read_source", args ->
      send(recipient, {:action_arguments, args})

      items =
        for n <- 1..25 do
          %{"type" => "inputText", "text" => String.duplicate("y", 50_000), "id" => "#{n}"}
        end

      %{"success" => true, "output" => String.duplicate("x", 500_000), "contentItems" => items}
    end

    assert {:ok, _} = AppServer.run(workspace, "inspect", %Issue{id: "lead", identifier: "LEAD"}, on_message: &send(recipient, {:update, &1}), tool_executor: executor)

    assert_received {:update,
                     %{
                       payload: %{
                         "method" => "item/completed",
                         "params" => %{"item" => %{"id" => "file-change", "type" => "FileChange", "status" => "completed", "changes" => changes, "outputTruncated" => true}}
                       }
                     }}

    texts = Enum.map(changes, fn {_path, entry} -> entry["content"] end)
    assert Enum.all?(texts, &(byte_size(&1) <= 16_384))
    assert Enum.sum(Enum.map(texts, &byte_size/1)) <= 262_144
    assert_received {:update, %{payload: %{"method" => "item/completed", "params" => %{"item" => %{"id" => "legacy", "changes" => [%{"path" => "legacy.txt", "diff" => diff}]}}}}}
    assert byte_size(diff) <= 16_384

    assert_received {:update, %{payload: %{"method" => "item/completed", "params" => %{"item" => %{"id" => "tool-call"} = item}}}}
    assert %{"arguments" => %{"query" => query}, "content_items" => [%{"text" => tool_text}]} = item

    assert query == String.duplicate("preserve", 3000)
    assert byte_size(tool_text) <= 16_384
    assert_received {:action_arguments, %{"query" => action_query}}
    assert action_query == String.duplicate("argument", 3000)

    assert_received {:update,
                     %{
                       payload: %{
                         "method" => "turn/completed",
                         "params" => %{"turn" => %{"status" => "completed", "usage" => %{"total_tokens" => 77}, "items" => [%{"id" => "final", "text" => final}]}}
                       }
                     }}

    assert byte_size(final) <= 16_384
    result = File.stream!(observed) |> Enum.map(&Jason.decode!/1) |> Enum.find(&(&1["id"] == 101 and is_map(&1["result"])))
    assert result["result"]["success"] == true
    assert byte_size(result["result"]["output"]) <= 16_384
    assert Enum.sum(Enum.map(result["result"]["contentItems"], &byte_size(&1["text"]))) <= 262_144
  end
end
