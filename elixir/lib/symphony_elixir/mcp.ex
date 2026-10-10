defmodule SymphonyElixir.MCP do
  @moduledoc "Local stdio MCP for operator controls; it never starts an orchestrator or exposes a web mutation."

  alias SymphonyElixir.{PriorityMode, Service}

  @versions ~w(2025-11-25 2025-06-18 2025-03-26 2024-11-05)

  @spec run(Path.t(), IO.device(), IO.device()) :: :ok | {:error, String.t()}
  def run(path, input \\ :stdio, output \\ :stdio) do
    with {:ok, service} <- Service.load(path) do
      loop(input, output, service, false)
    end
  end

  def handle(message, service, initialized, operator \\ true)

  @spec handle(term(), Service.t(), boolean(), boolean()) :: {map() | nil, boolean()}
  def handle(%{"jsonrpc" => "2.0", "method" => "initialize", "id" => id, "params" => %{"protocolVersion" => version}}, _service, _initialized, _operator) do
    version = if version in @versions, do: version, else: hd(@versions)
    {result(id, %{protocolVersion: version, capabilities: %{tools: %{}}, serverInfo: %{name: "crescendo", version: "1"}}), true}
  end

  def handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, _service, initialized, _operator), do: {nil, initialized}
  def handle(%{"jsonrpc" => "2.0", "method" => "ping", "id" => id}, _service, initialized, _operator), do: {result(id, %{}), initialized}

  def handle(%{"jsonrpc" => "2.0", "id" => id}, _service, false, _operator), do: {error(id, -32_002, "initialize first"), false}

  def handle(%{"jsonrpc" => "2.0", "method" => "tools/list", "id" => id}, _service, true, _operator), do: {result(id, %{tools: tools()}), true}

  def handle(%{"jsonrpc" => "2.0", "method" => "tools/call", "id" => id, "params" => %{"name" => name} = params}, service, true, operator) do
    case call(name, Map.get(params, "arguments", %{}), service, operator) do
      {:ok, status} -> {result(id, %{content: [%{type: "text", text: Jason.encode!(status)}], structuredContent: status, isError: false}), true}
      {:error, reason} -> {result(id, %{content: [%{type: "text", text: reason}], isError: true}), true}
    end
  end

  def handle(%{"jsonrpc" => "2.0", "id" => id}, _service, initialized, _operator), do: {error(id, -32_601, "method not found"), initialized}
  def handle(%{"jsonrpc" => "2.0", "method" => method}, _service, initialized, _operator) when is_binary(method), do: {nil, initialized}
  def handle(_message, _service, initialized, _operator), do: {error(nil, -32_600, "invalid request"), initialized}

  defp loop(input, output, service, initialized) do
    case IO.gets(input, "") do
      :eof ->
        :ok

      {:error, _} ->
        {:error, "could not read MCP input"}

      line ->
        {reply, initialized} =
          case Jason.decode(line) do
            {:ok, message} -> handle(message, service, initialized, System.get_env("CRESCENDO_WORK_ITEM") in [nil, ""])
            {:error, _} -> {error(nil, -32_700, "invalid JSON"), initialized}
          end

        if reply, do: IO.puts(output, Jason.encode!(reply))
        loop(input, output, service, initialized)
    end
  end

  defp call("crescendo_priority_mode_get", args, service, _operator) when args == %{}, do: {:ok, PriorityMode.status(service)}
  defp call("crescendo_priority_mode_set", _args, _service, false), do: {:error, "priority changes require an operator session"}
  defp call("crescendo_priority_mode_set", args, service, true) when is_map(args), do: PriorityMode.set(service, args)
  defp call(_name, _args, _service, _operator), do: {:error, "unknown tool or invalid arguments"}

  defp tools do
    [
      %{
        name: "crescendo_priority_mode_get",
        description: "Read the service-wide OpenAI Fast-mode default and its expiry for all Crescendo agents.",
        inputSchema: %{type: "object", properties: %{}, additionalProperties: false},
        annotations: %{readOnlyHint: true}
      },
      %{
        name: "crescendo_priority_mode_set",
        description:
          "Enable or disable OpenAI Fast mode for all Crescendo agents. Optional expires_at is an ISO 8601 timestamp; expiry restores standard speed at the next turn. Operator-only; affects new turns without cancelling current work.",
        inputSchema: %{
          type: "object",
          properties: %{enabled: %{type: "boolean"}, expires_at: %{type: "string", format: "date-time"}},
          required: ["enabled"],
          additionalProperties: false
        },
        annotations: %{readOnlyHint: false, destructiveHint: false, idempotentHint: true}
      }
    ]
  end

  defp result(id, value), do: %{jsonrpc: "2.0", id: id, result: value}
  defp error(id, code, message), do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}
end
