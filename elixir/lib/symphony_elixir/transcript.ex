defmodule SymphonyElixir.Transcript do
  @moduledoc """
  A bounded, user-facing transcript of one Codex run, rebuilt from app-server
  notifications: what the agent said, thought, ran, changed, planned and saw.

  Entries stay in chronological order. `item/started` adds a running entry that
  the matching `item/completed` fills in, so long commands appear while they
  run, and message, reasoning and command-output deltas stream into their entry
  until it completes. Reasoning without a summary shows only while it runs. Images the agent saw are handed to the `:store_image`
  callback, and the entry keeps only the reference it returns.
  """

  @max_entries 150
  @max_output_lines 60
  @max_output_bytes 8_000
  @max_diff_lines 150
  @max_text_bytes 20_000
  @max_prompt_bytes 4_000
  @max_detail_bytes 600
  @max_images_per_entry 4
  @started_kinds ~w(commandExecution fileChange mcpToolCall dynamicToolCall webSearch imageGeneration collabAgentToolCall)
  @ansi ~r/\e\[[0-9;?]*[ -\/]*[@-~]/

  @type t :: %{
          entries: [map()],
          plan: [%{step: String.t(), status: String.t()}],
          plan_explanation: String.t() | nil,
          files: [map()],
          seq: non_neg_integer()
        }

  @spec new() :: t()
  def new, do: %{entries: [], plan: [], plan_explanation: nil, files: [], seq: 0}

  @doc """
  Folds one Codex update into the transcript. Updates that are not app-server
  notifications, and notification kinds that carry nothing for a reader, leave
  it unchanged.
  """
  @spec apply(t(), map(), keyword()) :: t()
  def apply(transcript, update, opts \\ []), do: apply_update(transcript, update, opts)

  defp apply_update(transcript, %{payload: %{} = payload} = update, opts) do
    method(get(payload, "method"), transcript, get(payload, "params") || %{}, timestamp(update), opts)
  end

  defp apply_update(transcript, _update, _opts), do: transcript

  defp method("item/started", transcript, params, at, opts), do: started(transcript, get(params, "item"), at, opts)
  defp method("item/completed", transcript, params, at, opts), do: completed(transcript, get(params, "item"), at, opts)
  defp method("item/agentMessage/delta", transcript, params, at, _opts), do: stream_text(transcript, params, "message", at)
  defp method("item/reasoning/summaryTextDelta", transcript, params, at, _opts), do: stream_text(transcript, params, "reasoning", at)
  defp method("item/commandExecution/outputDelta", transcript, params, _at, _opts), do: stream_output(transcript, params)
  defp method("turn/plan/updated", transcript, params, at, _opts), do: plan_updated(transcript, params, at)
  defp method("turn/diff/updated", transcript, params, _at, _opts), do: %{transcript | files: diff_files(get(params, "diff"))}
  defp method("turn/completed", transcript, params, at, _opts), do: turn_completed(transcript, get(params, "turn") || %{}, at)
  defp method("error", transcript, params, at, _opts), do: notice(transcript, "error", error_text(params), at)
  defp method(_method, transcript, _params, _at, _opts), do: transcript

  @doc "Plan progress as completed and total steps."
  @spec progress(t() | nil) :: %{done: non_neg_integer(), total: non_neg_integer()}
  def progress(%{plan: plan}) when is_list(plan),
    do: %{done: Enum.count(plan, &(&1.status == "completed")), total: length(plan)}

  def progress(_transcript), do: %{done: 0, total: 0}

  @doc """
  Appends one notification to a JSON-lines file for protocol discovery, with
  long strings shortened so screenshots and outputs keep only their shape.
  """
  @spec capture(map(), Path.t()) :: :ok
  def capture(%{payload: %{} = payload}, path) do
    line = Jason.encode!(shorten(payload)) <> "\n"
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, line, [:append])
  rescue
    _ -> :ok
  end

  def capture(_update, _path), do: :ok

  # Only kinds that take a while get a running entry; each of them always yields one.
  defp started(transcript, %{} = item, at, opts) do
    case get(item, "type") do
      "reasoning" -> upsert(transcript, %{id: item_id(item), kind: "reasoning", text: "", at: at, status: "running"})
      type when type in @started_kinds -> upsert(transcript, %{entry(item, at, Keyword.delete(opts, :store_image)) | status: "running"})
      _type -> transcript
    end
  end

  defp started(transcript, _item, _at, _opts), do: transcript

  # An item that completes with nothing to show (such as reasoning without a
  # summary) takes its running placeholder with it.
  defp completed(transcript, %{} = item, at, opts) do
    case entry(item, at, opts) do
      nil -> %{transcript | entries: Enum.reject(transcript.entries, &(&1.id == item_id(item)))}
      entry -> upsert(transcript, entry)
    end
  end

  defp completed(transcript, _item, _at, _opts), do: transcript

  # Deltas grow an entry until `item/completed` replaces it with the final text.
  # Reasoning summaries arrive in numbered parts, kept as separate paragraphs.
  defp stream_text(transcript, params, kind, at) do
    id = get(params, "itemId")
    delta = get(params, "delta")
    part = get(params, "summaryIndex")

    with true <- is_binary(id) and is_binary(delta),
         entry = find(transcript, id) || %{id: id, kind: kind, text: "", at: at, status: "running", part: part},
         true <- entry.kind == kind and byte_size(entry.text) < @max_text_bytes do
      separator = if entry.text != "" and Map.get(entry, :part) != part, do: "\n\n", else: ""
      upsert(transcript, Map.merge(entry, %{text: clip(entry.text <> separator <> delta, @max_text_bytes), part: part}))
    else
      _ -> transcript
    end
  end

  defp stream_output(transcript, params) do
    delta = get(params, "delta")

    case is_binary(delta) && find(transcript, get(params, "itemId")) do
      %{kind: "command", status: "running"} = entry ->
        {output, truncated} = tail(Map.get(entry, :output, "") <> delta)
        upsert(transcript, %{entry | output: output, output_truncated: entry.output_truncated or truncated})

      _ ->
        transcript
    end
  end

  defp find(transcript, id), do: Enum.find(transcript.entries, &(&1.id == id))

  defp entry(item, at, opts) do
    base = %{id: item_id(item), at: at, status: item_status(item)}
    item_entry(get(item, "type"), base, item, opts)
  end

  @silent_items [nil, "hookPrompt", "sleep", "subAgentActivity"]
  @notices %{
    "contextCompaction" => "Context compacted to make room",
    "enteredReviewMode" => "Entered review mode",
    "exitedReviewMode" => "Left review mode"
  }

  defp item_entry("agentMessage", base, item, _opts), do: text_entry(base, "message", get(item, "text"), %{phase: get(item, "phase")})
  defp item_entry("plan", base, item, _opts), do: text_entry(base, "message", get(item, "text"), %{phase: "plan"})
  defp item_entry("reasoning", base, item, _opts), do: text_entry(base, "reasoning", reasoning_text(item), %{})
  defp item_entry("userMessage", base, item, _opts), do: prompt_entry(base, item)
  defp item_entry("commandExecution", base, item, _opts), do: command_entry(base, item)
  defp item_entry("fileChange", base, item, _opts), do: Map.merge(base, %{kind: "file_change", files: Enum.map(list(get(item, "changes")), &file_change/1)})
  defp item_entry("mcpToolCall", base, item, opts), do: mcp_entry(base, item, opts)
  defp item_entry("dynamicToolCall", base, item, opts), do: dynamic_entry(base, item, opts)
  defp item_entry("functionCallOutput", base, item, opts), do: function_output_entry(base, item, opts)
  defp item_entry("imageView", base, item, opts), do: image_entry(base, get(item, "path"), [{:file, get(item, "path")}], opts)
  defp item_entry("imageGeneration", base, item, opts), do: image_generation_entry(base, item, opts)
  defp item_entry("webSearch", base, item, _opts), do: Map.merge(base, %{kind: "search", query: clip(to_string(get(item, "query") || ""), @max_detail_bytes)})
  defp item_entry("collabAgentToolCall", base, item, _opts), do: tool_line(base, "agents · #{get(item, "tool")}")
  defp item_entry(type, base, _item, _opts) when is_map_key(@notices, type), do: Map.merge(base, %{kind: "notice", tone: "info", text: @notices[type]})
  defp item_entry(type, _base, _item, _opts) when type in @silent_items, do: nil
  defp item_entry(type, base, _item, _opts), do: tool_line(base, to_string(type))

  defp item_id(item), do: to_string(get(item, "id") || "item")

  defp tool_line(base, name), do: Map.merge(base, %{kind: "tool", name: name, detail: nil, images: []})

  defp text_entry(base, kind, text, extra) do
    text = clip(to_string(text || ""), @max_text_bytes)
    if String.trim(text) == "", do: nil, else: base |> Map.merge(extra) |> Map.merge(%{kind: kind, text: text})
  end

  defp prompt_entry(base, item) do
    text =
      item
      |> get("content")
      |> list()
      |> Enum.map_join("\n", fn part -> to_string(get(part, "text") || "") end)

    text_entry(base, "prompt", clip(text, @max_prompt_bytes), %{})
  end

  defp reasoning_text(item) do
    case list(get(item, "summary")) do
      [] -> item |> get("content") |> list() |> Enum.map_join("\n\n", &to_string/1)
      summary -> Enum.map_join(summary, "\n\n", &to_string/1)
    end
  end

  defp command_entry(base, item) do
    command = item |> get("command") |> to_string() |> unwrap_shell()
    {output, truncated} = tail(get(item, "aggregatedOutput"))

    Map.merge(base, %{
      kind: "command",
      command: clip(command, @max_detail_bytes * 4),
      summary: item |> get("commandActions") |> list() |> action_summary(),
      exit_code: get(item, "exitCode"),
      duration_ms: get(item, "durationMs"),
      output: output,
      output_truncated: truncated
    })
  end

  @shell ~r/\A\S*sh\s+-l?c\s+(?:'(?<single>.*)'|"(?<double>.*)")\z/s

  # Codex runs each command through a login shell; show the script the agent wrote.
  defp unwrap_shell(command) do
    case Regex.named_captures(@shell, command) do
      %{"single" => single} when single != "" -> String.replace(single, ~S('"'"'), "'")
      %{"double" => double} when double != "" -> Regex.replace(~r/\\([\\"$`])/, double, "\\1")
      _ -> command
    end
  end

  # Codex parses simple commands into reads, listings and searches, which read
  # better as a sentence; anything else stays shell.
  defp action_summary([_ | _] = actions) do
    parts = Enum.map(actions, &action_text/1)
    if Enum.all?(parts), do: Enum.join(parts, ", ")
  end

  defp action_summary(_actions), do: nil

  defp action_text(action) do
    case get(action, "type") do
      "read" -> "Read #{get(action, "name") || action |> get("path") |> to_string() |> Path.basename()}"
      "listFiles" -> "Listed #{get(action, "path") || "files"}"
      "search" -> search_text(get(action, "query"), get(action, "path"))
      _ -> nil
    end
  end

  defp search_text(nil, path), do: "Searched #{path || "files"}"
  defp search_text(query, nil), do: "Searched for #{query}"
  defp search_text(query, path), do: "Searched for #{query} in #{path}"

  defp file_change(change) do
    diff = to_string(get(change, "diff") || "")
    kind = to_string(get(get(change, "kind"), "type") || "update")
    {additions, deletions} = count_diff(diff, kind)

    %{
      path: to_string(get(change, "path") || "?"),
      change: kind,
      additions: additions,
      deletions: deletions,
      diff: diff |> String.split("\n") |> Enum.take(@max_diff_lines) |> Enum.join("\n")
    }
  end

  defp mcp_entry(base, item, opts) do
    result = get(item, "result")
    error = item |> get("error") |> get("message")

    Map.merge(base, %{
      kind: "tool",
      name: "#{get(item, "server")} · #{get(item, "tool")}",
      call: call_text(get(item, "arguments")),
      detail: error || text_of(result),
      images: store_images(image_sources(result), opts)
    })
  end

  defp dynamic_entry(base, item, opts) do
    contents = get(item, "contentItems")
    name = [get(item, "namespace"), get(item, "tool")] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

    Map.merge(base, %{
      kind: "tool",
      name: name,
      call: call_text(get(item, "arguments")),
      detail: text_of(contents),
      images: store_images(image_sources(contents), opts)
    })
  end

  defp function_output_entry(base, item, opts) do
    output = get(item, "output")
    name = [get(item, "namespace"), get(item, "name")] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

    Map.merge(base, %{
      kind: "tool",
      name: if(name == "", do: "tool", else: name),
      detail: text_of(output),
      images: store_images(image_sources(output), opts)
    })
  end

  # A generated image is kept from its saved file, or else from its base64 result.
  defp image_generation_entry(base, item, opts) do
    sources =
      case {get(item, "savedPath"), get(item, "result")} do
        {path, _result} when is_binary(path) -> [{:file, path}]
        {_path, result} when is_binary(result) and result != "" -> [{:base64, result, nil}]
        _ -> []
      end

    image_entry(base, get(item, "revisedPrompt") || "Generated image", sources, opts)
  end

  defp image_entry(base, label, sources, opts) do
    Map.merge(base, %{kind: "image", label: label_text(label), images: store_images(sources, opts)})
  end

  defp label_text(label) when is_binary(label), do: if(String.contains?(label, "/"), do: Path.basename(label), else: label)
  defp label_text(_label), do: "Image"

  defp store_images(sources, opts) do
    case Keyword.get(opts, :store_image) do
      store when is_function(store, 1) -> sources |> Enum.take(@max_images_per_entry) |> Enum.flat_map(&stored(store, &1))
      _ -> []
    end
  end

  defp stored(store, source) do
    case store.(source) do
      {:ok, image} -> [image]
      _ -> []
    end
  end

  # Images arrive inside tool results in several shapes: data URLs from
  # dynamic and function tools, and base64 MCP image content.
  defp image_sources(value, depth \\ 0)
  defp image_sources(_value, depth) when depth > 6, do: []
  defp image_sources(list, depth) when is_list(list), do: Enum.flat_map(list, &image_sources(&1, depth + 1))

  defp image_sources(%{} = map, depth) do
    url = get(map, "imageUrl") || get(map, "image_url")

    cond do
      is_binary(url) and String.starts_with?(url, "data:image/") ->
        [{:data_url, url}]

      get(map, "type") == "image" and is_binary(get(map, "data")) ->
        [{:base64, get(map, "data"), get(map, "mimeType")}]

      true ->
        map |> Map.values() |> Enum.flat_map(&image_sources(&1, depth + 1))
    end
  end

  defp image_sources(_value, _depth), do: []

  defp text_of(value) do
    text =
      value
      |> collect_text(0)
      |> Enum.join("\n")
      |> String.trim()

    if text == "", do: nil, else: clip(text, @max_detail_bytes)
  end

  defp collect_text(text, _depth) when is_binary(text), do: [text]
  defp collect_text(_value, depth) when depth > 6, do: []
  defp collect_text(list, depth) when is_list(list), do: Enum.flat_map(list, &collect_text(&1, depth + 1))

  defp collect_text(%{} = map, depth) do
    case get(map, "text") do
      text when is_binary(text) -> [text]
      _ -> (get(map, "content") || get(map, "output") || []) |> collect_text(depth + 1)
    end
  end

  defp collect_text(_value, _depth), do: []

  # REST-shaped tools (github_api and friends) read best as "GET /path".
  defp call_text(%{} = arguments) do
    case {get(arguments, "method"), get(arguments, "path")} do
      {method, path} when is_binary(method) and is_binary(path) -> "#{method} #{path}"
      _ -> arguments_text(arguments)
    end
  end

  defp call_text(arguments), do: arguments_text(arguments)

  defp arguments_text(nil), do: nil
  defp arguments_text(arguments) when is_binary(arguments), do: clip(arguments, @max_detail_bytes)

  defp arguments_text(arguments) do
    case Jason.encode(arguments) do
      {:ok, json} -> clip(json, @max_detail_bytes)
      _ -> nil
    end
  end

  defp plan_updated(transcript, params, at) do
    plan =
      params
      |> get("plan")
      |> list()
      |> Enum.map(fn step -> %{step: to_string(get(step, "step") || ""), status: plan_status(get(step, "status"))} end)

    transcript = %{transcript | plan: plan, plan_explanation: get(params, "explanation")}
    entry = %{kind: "plan", at: at, status: "completed", steps: plan, explanation: get(params, "explanation")}

    case List.last(transcript.entries) do
      %{kind: "plan", id: id} -> upsert(transcript, Map.put(entry, :id, id))
      _ -> transcript |> next_id() |> then(fn {transcript, id} -> upsert(transcript, Map.put(entry, :id, id)) end)
    end
  end

  defp plan_status("inProgress"), do: "in_progress"
  defp plan_status(status) when status in ["pending", "completed"], do: status
  defp plan_status(_status), do: "pending"

  defp turn_completed(transcript, turn, at) do
    case get(turn, "status") do
      status when status in ["failed", "interrupted"] ->
        message = turn |> get("error") |> error_text()
        notice(transcript, "error", "Turn #{status}#{if message, do: ": #{message}", else: ""}", at)

      _ ->
        transcript
    end
  end

  defp notice(transcript, tone, text, at) when is_binary(text) and text != "" do
    {transcript, id} = next_id(transcript)
    upsert(transcript, %{id: id, kind: "notice", tone: tone, text: clip(text, @max_detail_bytes), at: at, status: "completed"})
  end

  defp notice(transcript, _tone, _text, _at), do: transcript

  defp error_text(%{} = value), do: get(value, "message") || value |> get("error") |> error_text()
  defp error_text(value) when is_binary(value), do: value
  defp error_text(_value), do: nil

  defp upsert(transcript, %{id: id} = entry) do
    entries =
      case Enum.find_index(transcript.entries, &(&1.id == id)) do
        nil -> transcript.entries ++ [entry]
        index -> List.update_at(transcript.entries, index, &Map.merge(&1, Map.put(entry, :started_at, &1.at)))
      end

    %{transcript | entries: Enum.take(entries, -@max_entries)}
  end

  defp next_id(transcript), do: {%{transcript | seq: transcript.seq + 1}, "s#{transcript.seq + 1}"}

  defp item_status(item) do
    case get(item, "status") do
      "inProgress" -> "running"
      status when status in ["failed", "declined"] -> "failed"
      _ -> if get(item, "success") == false, do: "failed", else: "completed"
    end
  end

  defp tail(nil), do: {"", false}

  defp tail(output) do
    lines = output |> to_string() |> String.replace(@ansi, "") |> String.split("\n")
    kept = Enum.take(lines, -@max_output_lines) |> Enum.join("\n")

    clipped =
      if byte_size(kept) > @max_output_bytes,
        do: kept |> binary_part(byte_size(kept) - @max_output_bytes, @max_output_bytes) |> valid_suffix(),
        else: kept

    {clipped, length(lines) > @max_output_lines or clipped != kept}
  end

  defp valid_suffix(binary) do
    if String.valid?(binary), do: binary, else: valid_suffix(binary_part(binary, 1, byte_size(binary) - 1))
  end

  defp count_diff(diff, kind) do
    lines = String.split(diff, "\n")
    added = Enum.count(lines, &(String.starts_with?(&1, "+") and not String.starts_with?(&1, "+++")))
    removed = Enum.count(lines, &(String.starts_with?(&1, "-") and not String.starts_with?(&1, "---")))

    cond do
      added + removed > 0 -> {added, removed}
      kind == "add" -> {Enum.count(lines, &(&1 != "")), 0}
      kind == "delete" -> {0, Enum.count(lines, &(&1 != ""))}
      true -> {0, 0}
    end
  end

  @doc false
  @spec diff_files(term()) :: [map()]
  def diff_files(diff) when is_binary(diff) do
    diff
    |> String.split("\n")
    |> Enum.reduce([], fn line, files ->
      cond do
        String.starts_with?(line, "diff --git ") ->
          path = line |> String.split(" b/", parts: 2) |> List.last()
          [%{path: path, additions: 0, deletions: 0} | files]

        files == [] ->
          files

        String.starts_with?(line, "+++") or String.starts_with?(line, "---") ->
          files

        String.starts_with?(line, "+") ->
          [Map.update!(hd(files), :additions, &(&1 + 1)) | tl(files)]

        String.starts_with?(line, "-") ->
          [Map.update!(hd(files), :deletions, &(&1 + 1)) | tl(files)]

        true ->
          files
      end
    end)
    |> Enum.reverse()
  end

  def diff_files(_diff), do: []

  defp clip(text, limit) when byte_size(text) <= limit, do: text
  defp clip(text, limit), do: text |> binary_part(0, limit) |> valid_prefix() |> Kernel.<>("…")

  defp shorten(value) when is_binary(value) and byte_size(value) > 400, do: binary_part(value, 0, 400) |> valid_prefix() |> Kernel.<>("…")
  defp shorten(value) when is_list(value), do: Enum.map(value, &shorten/1)
  defp shorten(%{} = value), do: Map.new(value, fn {key, inner} -> {key, shorten(inner)} end)
  defp shorten(value), do: value

  defp valid_prefix(binary) do
    if String.valid?(binary), do: binary, else: valid_prefix(binary_part(binary, 0, byte_size(binary) - 1))
  end

  defp timestamp(%{timestamp: %DateTime{} = at}), do: at
  defp timestamp(_update), do: DateTime.utc_now()

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp get(%{} = map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_atom(key))
    end
  end

  defp get(_value, _key), do: nil
end
