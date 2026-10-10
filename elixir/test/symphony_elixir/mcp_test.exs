defmodule SymphonyElixir.MCPTest do
  use ExUnit.Case

  alias SymphonyElixir.{MCP, PriorityMode, Service}

  setup do
    root = Path.join(System.tmp_dir!(), "crescendo-mcp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "crescendo.yml")
    File.write!(path, "paths: {state: state}\nprojects: {demo: {}}\n")
    {:ok, service} = Service.load(path)
    on_exit(fn -> File.rm_rf(root) end)
    %{path: path, service: service}
  end

  test "stdio initialization, tool discovery and operator changes return JSON-RPC only", %{path: path, service: service} do
    messages = [
      request(1, "initialize", %{protocolVersion: "2025-11-25"}),
      %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
      request(2, "tools/list", %{}),
      request(3, "tools/call", %{name: "crescendo_priority_mode_set", arguments: %{enabled: true}}),
      request(4, "tools/call", %{name: "crescendo_priority_mode_get"})
    ]

    {:ok, input} = StringIO.open(Enum.map_join(messages, "\n", &Jason.encode!/1) <> "\n{\n")
    {:ok, output} = StringIO.open("")
    assert MCP.run(path, input, output) == :ok
    {_, data} = StringIO.contents(output)
    replies = data |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert [init, tools, set, get, invalid] = replies
    assert init["result"]["protocolVersion"] == "2025-11-25"
    assert Enum.map(tools["result"]["tools"], & &1["name"]) == ["crescendo_priority_mode_get", "crescendo_priority_mode_set"]
    assert set["result"]["structuredContent"]["service_tier"] == "fast"
    assert get["result"]["structuredContent"]["enabled"] == true
    assert invalid["error"]["code"] == -32_700
    assert PriorityMode.status(service).enabled
  end

  test "worker sessions cannot change cost policy while status remains readable", %{service: service} do
    set = request(1, "tools/call", %{name: "crescendo_priority_mode_set", arguments: %{enabled: true}})
    assert {response, true} = MCP.handle(set, service, true, false)
    assert response.result.isError
    refute PriorityMode.status(service).enabled
    assert {response, true} = MCP.handle(request(2, "tools/call", %{name: "crescendo_priority_mode_get"}), service, true, false)
    refute response.result.isError
  end

  test "invalid requests and parameters are returned without mutating the policy", %{service: service, path: path} do
    assert {:error, _} = MCP.run(path <> ".missing")
    assert {%{error: %{code: -32_002}}, false} = MCP.handle(request(1, "tools/list", %{}), service, false)
    assert {%{error: %{code: -32_600}}, true} = MCP.handle([], service, true)
    assert {%{error: %{code: -32_601}}, true} = MCP.handle(request(1, "missing", %{}), service, true)
    assert {nil, true} = MCP.handle(%{"jsonrpc" => "2.0", "method" => "notifications/cancelled"}, service, true)
    assert {%{result: %{}}, false} = MCP.handle(request(1, "ping", %{}), service, false)
    assert {%{result: %{protocolVersion: "2025-11-25"}}, true} = MCP.handle(request(1, "initialize", %{protocolVersion: "future"}), service, false)

    for params <- [
          %{name: "unknown"},
          %{name: "crescendo_priority_mode_get", arguments: %{unexpected: 1}},
          %{name: "crescendo_priority_mode_get", arguments: false},
          %{name: "crescendo_priority_mode_set", arguments: []},
          %{name: "crescendo_priority_mode_set", arguments: %{enabled: "yes"}}
        ] do
      assert {%{result: %{isError: true}}, true} = MCP.handle(request(2, "tools/call", params), service, true)
    end

    refute PriorityMode.status(service).enabled
  end

  test "a failed input device ends the server with a reported error", %{path: path} do
    device =
      spawn(fn ->
        receive do
          {:io_request, from, reply_as, _request} -> send(from, {:io_reply, reply_as, {:error, :eio}})
        end
      end)

    assert {:error, "could not read MCP input"} = MCP.run(path, device, :stdio)
  end

  defp request(id, method, params), do: Jason.decode!(Jason.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params}))
end
