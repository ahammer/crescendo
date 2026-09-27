defmodule SymphonyElixir.TranscriptTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias SymphonyElixir.Transcript
  alias SymphonyElixirWeb.TranscriptComponents

  @at ~U[2026-09-27 10:00:00Z]

  defp note(method, params), do: %{payload: %{"method" => method, "params" => params}, timestamp: @at}
  defp completed(item), do: note("item/completed", %{"item" => item})
  defp started(item), do: note("item/started", %{"item" => item})
  defp fold(updates, opts \\ []), do: Enum.reduce(updates, Transcript.new(), &Transcript.apply(&2, &1, opts))

  defp plan(statuses) do
    note("turn/plan/updated", %{
      "explanation" => "Steps",
      "plan" => statuses |> Enum.with_index() |> Enum.map(fn {status, index} -> %{"step" => "Step #{index}", "status" => status} end)
    })
  end

  test "the prompt, reasoning and agent messages become chat entries in order" do
    transcript =
      fold([
        completed(%{"id" => "u1", "type" => "userMessage", "content" => [%{"type" => "text", "text" => "Fix GH-1"}]}),
        completed(%{"id" => "r1", "type" => "reasoning", "summary" => ["Look at the solver", "Then run tests"], "content" => []}),
        completed(%{"id" => "m1", "type" => "agentMessage", "text" => "Done.", "phase" => "final_answer"}),
        completed(%{"id" => "m2", "type" => "agentMessage", "text" => "   "})
      ])

    assert [
             %{kind: "prompt", text: "Fix GH-1", at: @at},
             %{kind: "reasoning", text: "Look at the solver\n\nThen run tests"},
             %{kind: "message", text: "Done.", phase: "final_answer", status: "completed"}
           ] = transcript.entries
  end

  test "a started command runs, streams output, and completes with exit code, duration and an output tail" do
    transcript = fold([started(%{"id" => "c1", "type" => "commandExecution", "command" => "cargo test", "status" => "inProgress"})])
    assert [%{kind: "command", status: "running", command: "cargo test", output: ""}] = transcript.entries

    transcript = Transcript.apply(transcript, note("item/commandExecution/outputDelta", %{"itemId" => "c1", "delta" => "compiling\n"}))
    assert [%{output: "compiling\n", status: "running"}] = transcript.entries

    output = Enum.map_join(1..100, "\n", &"line #{&1}") <> "\n\e[31mred\e[0m"

    transcript =
      Transcript.apply(
        transcript,
        completed(%{"id" => "c1", "type" => "commandExecution", "command" => "cargo test", "aggregatedOutput" => output, "exitCode" => 101, "durationMs" => 6_400, "status" => "failed"})
      )

    assert [%{status: "failed", exit_code: 101, duration_ms: 6_400, output_truncated: true, output: tail}] =
             transcript.entries

    assert tail |> String.split("\n") |> length() == 60
    assert String.ends_with?(tail, "line 100\nred")
    refute tail =~ "\e["

    # Output for a finished or unknown command is ignored.
    assert Transcript.apply(transcript, note("item/commandExecution/outputDelta", %{"itemId" => "c1", "delta" => "late"})) == transcript
    assert Transcript.apply(transcript, note("item/commandExecution/outputDelta", %{"itemId" => "zz", "delta" => "x"})) == transcript
  end

  test "reasoning shows while it runs and leaves no trace when it completes without a summary" do
    transcript = fold([started(%{"id" => "r1", "type" => "reasoning"}), started(%{"id" => "r2", "type" => "reasoning"})])
    assert [%{kind: "reasoning", text: "", status: "running"}, %{id: "r2"}] = transcript.entries

    transcript =
      transcript
      |> Transcript.apply(completed(%{"id" => "r1", "type" => "reasoning", "summary" => [], "content" => []}))
      |> Transcript.apply(completed(%{"id" => "r2", "type" => "reasoning", "summary" => ["Check the inlet"]}))

    assert [%{id: "r2", kind: "reasoning", text: "Check the inlet", status: "completed"}] = transcript.entries

    thinking = %{id: "r3", kind: "reasoning", text: "", status: "running", at: @at}
    html = render_component(&TranscriptComponents.transcript/1, id: "chat", entries: [thinking], now: @at)
    assert html =~ "Thinking…"
  end

  test "message and reasoning deltas stream into one entry that the completed item replaces" do
    transcript =
      fold([
        note("item/reasoning/summaryTextDelta", %{"itemId" => "r1", "delta" => "First", "summaryIndex" => 0}),
        note("item/reasoning/summaryTextDelta", %{"itemId" => "r1", "delta" => " part", "summaryIndex" => 0}),
        note("item/reasoning/summaryTextDelta", %{"itemId" => "r1", "delta" => "Second", "summaryIndex" => 1}),
        note("item/agentMessage/delta", %{"itemId" => "m1", "delta" => "Hel"}),
        note("item/agentMessage/delta", %{"itemId" => "m1", "delta" => "lo"})
      ])

    assert [%{kind: "reasoning", text: "First part\n\nSecond", status: "running"}, %{kind: "message", text: "Hello", status: "running"}] = transcript.entries

    # Deltas without an item, or for an item of another kind, are ignored.
    assert Transcript.apply(transcript, note("item/agentMessage/delta", %{"delta" => "x"})) == transcript
    assert Transcript.apply(transcript, note("item/agentMessage/delta", %{"itemId" => "r1", "delta" => "x"})) == transcript

    transcript = Transcript.apply(transcript, completed(%{"id" => "m1", "type" => "agentMessage", "text" => "Hello there", "phase" => "final_answer"}))
    assert [_reasoning, %{kind: "message", text: "Hello there", status: "completed", phase: "final_answer", started_at: @at}] = transcript.entries
  end

  test "file changes carry per-file stats and diffs, and turn diffs give the files-changed summary" do
    transcript =
      fold([
        completed(%{
          "id" => "f1",
          "type" => "fileChange",
          "status" => "completed",
          "changes" => [
            %{"path" => "src/a.rs", "kind" => %{"type" => "update", "move_path" => nil}, "diff" => "@@ -1,2 +1,3 @@\n-old\n+new\n+more\n context"},
            %{"path" => "docs/b.md", "kind" => %{"type" => "add"}, "diff" => "line one\nline two\n"}
          ]
        }),
        note("turn/diff/updated", %{
          "diff" => "diff --git a/src/a.rs b/src/a.rs\n--- a/src/a.rs\n+++ b/src/a.rs\n-old\n+new\n+more\ndiff --git a/docs/b.md b/docs/b.md\n+++ b/docs/b.md\n+line one\n"
        })
      ])

    assert [
             %{
               kind: "file_change",
               files: [
                 %{path: "src/a.rs", change: "update", additions: 2, deletions: 1, diff: "@@ -1,2 +1,3 @@" <> _},
                 %{path: "docs/b.md", change: "add", additions: 2, deletions: 0}
               ]
             }
           ] = transcript.entries

    assert [%{path: "src/a.rs", additions: 2, deletions: 1}, %{path: "docs/b.md", additions: 1, deletions: 0}] = transcript.files

    transcript =
      fold([
        completed(%{
          "id" => "f2",
          "type" => "fileChange",
          "changes" => [%{"path" => "old.txt", "kind" => %{"type" => "delete"}, "diff" => "gone\n"}, %{"path" => "same.txt", "kind" => %{"type" => "update"}, "diff" => ""}]
        }),
        note("turn/diff/updated", %{"diff" => "preamble\n+stray\ndiff --git a/x b/x\n+y\n"})
      ])

    assert [%{files: [deleted, unchanged]}] = transcript.entries
    assert %{change: "delete", additions: 0, deletions: 1} = deleted
    assert %{change: "update", additions: 0, deletions: 0} = unchanged
    assert [%{path: "x", additions: 1, deletions: 0}] = transcript.files
  end

  test "plan updates drive progress, and consecutive updates share one entry" do
    transcript = fold([plan(["completed", "inProgress", "pending"]), plan(["completed", "completed", "inProgress"])])

    assert Transcript.progress(transcript) == %{done: 2, total: 3}
    assert transcript.plan_explanation == "Steps"
    assert [%{kind: "plan", steps: [_, %{status: "completed"}, %{status: "in_progress", step: "Step 2"}]}] = transcript.entries

    transcript =
      transcript
      |> Transcript.apply(completed(%{"id" => "m", "type" => "agentMessage", "text" => "hi"}))
      |> Transcript.apply(plan(["completed", "completed", "completed"]))

    assert [%{kind: "plan"}, %{kind: "message"}, %{kind: "plan"}] = transcript.entries
    assert Transcript.progress(nil) == %{done: 0, total: 0}
  end

  test "images the agent saw are stored through the callback wherever they appear" do
    png = <<0x89, "PNG", 0::64>>
    b64 = Base.encode64(png)
    parent = self()

    store = fn source ->
      send(parent, {:stored, source})
      {:ok, %{name: "1.png", src: "/artifacts/0123456789abcdef01234567/1.png"}}
    end

    transcript =
      fold(
        [
          completed(%{"id" => "v1", "type" => "imageView", "path" => "/tmp/shot.png"}),
          completed(%{"id" => "g1", "type" => "imageGeneration", "status" => "completed", "revisedPrompt" => "a chart", "result" => "", "savedPath" => "/tmp/gen.png"}),
          completed(%{
            "id" => "d1",
            "type" => "dynamicToolCall",
            "namespace" => "computer_use",
            "tool" => "screenshot",
            "success" => true,
            "arguments" => %{},
            "contentItems" => [%{"type" => "inputText", "text" => "Captured"}, %{"type" => "inputImage", "imageUrl" => "data:image/png;base64," <> b64}]
          }),
          completed(%{
            "id" => "p1",
            "type" => "mcpToolCall",
            "server" => "desktop",
            "tool" => "capture",
            "arguments" => %{"window" => "main"},
            "result" => %{"content" => [%{"type" => "image", "data" => b64, "mimeType" => "image/png"}]}
          }),
          completed(%{"id" => "o1", "type" => "functionCallOutput", "name" => "exec", "output" => [%{"type" => "input_image", "image_url" => "data:image/png;base64," <> b64}]})
        ],
        store_image: store
      )

    assert_received {:stored, {:file, "/tmp/shot.png"}}
    assert_received {:stored, {:file, "/tmp/gen.png"}}
    assert_received {:stored, {:data_url, "data:image/png;base64," <> _}}
    assert_received {:stored, {:base64, ^b64, "image/png"}}
    assert_received {:stored, {:data_url, _}}

    assert [
             %{kind: "image", label: "shot.png", images: [%{src: "/artifacts/" <> _}]},
             %{kind: "image", label: "a chart", images: [_]},
             %{kind: "tool", name: "computer_use · screenshot", detail: "Captured", images: [_]},
             %{kind: "tool", name: "desktop · capture", call: ~s({"window":"main"}), detail: nil, images: [_]},
             %{kind: "tool", name: "exec", images: [_]}
           ] = transcript.entries

    # Without a store nothing is kept, and the entry says so by having no images.
    assert [%{kind: "image", images: []}] = fold([completed(%{"id" => "v1", "type" => "imageView", "path" => "/tmp/shot.png"})]).entries
  end

  test "entries are bounded, text is clipped on byte limits, and unknown item types fall back to a tool line" do
    transcript = fold(for index <- 1..160, do: completed(%{"id" => "m#{index}", "type" => "agentMessage", "text" => "message #{index}"}))
    assert length(transcript.entries) == 150
    assert hd(transcript.entries).text == "message 11"

    transcript =
      fold([
        completed(%{"id" => "x", "type" => "somethingNew"}),
        completed(%{"id" => "s", "type" => "sleep"}),
        completed(%{"id" => "w", "type" => "webSearch", "query" => "dam break"}),
        completed(%{"id" => "c", "type" => "contextCompaction"}),
        completed(%{"type" => nil})
      ])

    assert [%{kind: "tool", name: "somethingNew"}, %{kind: "search", query: "dam break"}, %{kind: "notice", tone: "info"}] = transcript.entries

    [%{text: text}] = fold([completed(%{"id" => "l", "type" => "agentMessage", "text" => String.duplicate("é", 15_000)})]).entries
    assert byte_size(text) <= 20_000 + byte_size("…")
    assert String.valid?(text)
  end

  test "failed turns and errors become notices, and other notifications change nothing" do
    transcript =
      fold([
        note("turn/completed", %{"turn" => %{"status" => "failed", "error" => %{"message" => "context window exceeded"}}}),
        note("turn/completed", %{"turn" => %{"status" => "completed"}}),
        note("error", %{"error" => %{"message" => "stream disconnected"}}),
        note("thread/tokenUsage/updated", %{})
      ])

    assert [%{kind: "notice", tone: "error", text: "Turn failed: context window exceeded"}, %{kind: "notice", text: "stream disconnected"}] = transcript.entries
    assert Transcript.apply(transcript, %{event: :startup_failed}) == transcript
  end

  test "protocol capture writes shortened JSON lines" do
    path = Path.join(System.tmp_dir!(), "transcript-capture-#{System.unique_integer([:positive])}/run.jsonl")
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)

    item = %{"type" => "imageView", "blob" => String.duplicate("a", 1_000), "parts" => [String.duplicate("é", 300)]}
    :ok = Transcript.capture(completed(item), path)
    [line] = path |> File.read!() |> String.split("\n", trim: true)
    assert %{"method" => "item/completed", "params" => %{"item" => %{"blob" => blob, "parts" => [part]}}} = Jason.decode!(line)
    assert String.length(blob) == 401
    assert String.length(part) == 201
    assert Transcript.capture(%{}, path) == :ok

    # Capture never takes the orchestrator down, even when it cannot write.
    blocker = Path.join(Path.dirname(path), "blocker")
    File.write!(blocker, "")
    assert Transcript.capture(completed(%{"type" => "x"}), Path.join(blocker, "run.jsonl")) == :ok
  end

  test "agent text keeps its structure through light formatting" do
    blocks = TranscriptComponents.blocks("# Plan\n\nRun `cargo test` **now**.\n- one\n- two\n\n```\n<script>x</script>\n```\nSee [docs](https://example.org) and [file](src/a.rs:3)")

    assert [
             {:heading, [{:text, "Plan"}]},
             {:para, [{:text, "Run "}, {:code, "cargo test"}, {:text, " "}, {:strong, "now"}, {:text, "."}]},
             {:list, [[{:text, "one"}], [{:text, "two"}]]},
             {:code, "<script>x</script>"},
             {:para, [{:text, "See "}, {:link, "docs", "https://example.org"}, {:text, " and "}, {:ref, "file", "src/a.rs:3"}]}
           ] = blocks

    assert TranscriptComponents.blocks(nil) == []
    assert TranscriptComponents.inline_parts("[x] done `") == [{:text, "[x] done `"}]
  end

  test "the chat renders every entry kind escaped, with images inline and failed output open" do
    transcript =
      fold(
        [
          completed(%{"id" => "u", "type" => "userMessage", "content" => [%{"type" => "text", "text" => "Task <b>prompt</b>"}]}),
          completed(%{"id" => "m", "type" => "agentMessage", "text" => "Hello <script>alert(1)</script> **bold**"}),
          completed(%{"id" => "r", "type" => "reasoning", "summary" => ["Thinking about it"]}),
          completed(%{"id" => "c", "type" => "commandExecution", "command" => "cargo test", "aggregatedOutput" => "boom", "exitCode" => 1, "durationMs" => 1_500}),
          completed(%{"id" => "f", "type" => "fileChange", "changes" => [%{"path" => "src/a.rs", "kind" => %{"type" => "update"}, "diff" => "@@ -1 +1 @@\n-a\n+b"}]}),
          completed(%{"id" => "v", "type" => "imageView", "path" => "/tmp/shot.png"}),
          completed(%{"id" => "t", "type" => "mcpToolCall", "server" => "gh", "tool" => "search", "result" => %{"content" => [%{"type" => "text", "text" => "3 results"}]}}),
          completed(%{"id" => "w", "type" => "webSearch", "query" => "lattice boltzmann"}),
          plan(["completed", "inProgress"]),
          note("error", %{"message" => "stream disconnected"})
        ],
        store_image: fn _source -> {:ok, %{name: "1.png", src: "/artifacts/0123456789abcdef01234567/1.png"}} end
      )

    html = render_component(&TranscriptComponents.transcript/1, id: "chat-GH-1", entries: transcript.entries, now: DateTime.add(@at, 300, :second))

    assert html =~ ~s(phx-hook="ChatScroll")
    assert html =~ "Task &lt;b&gt;prompt&lt;/b&gt;"
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute html =~ "<script>alert"
    assert html =~ "<strong>bold</strong>"
    assert html =~ "Thinking"
    assert html =~ "cargo test" and html =~ "exit 1 · 1.5s"
    assert html =~ ~r/<details[^>]*class="fold"[^>]*open/
    assert html =~ ~s(class="diff-line-add")
    assert html =~ ~s(<img src="/artifacts/0123456789abcdef01234567/1.png")
    assert html =~ "gh · search" and html =~ "3 results"
    assert html =~ "Searched the web" and html =~ "lattice boltzmann"
    assert html =~ "1/2 steps done"
    assert html =~ "stream disconnected"
    assert html =~ "5m ago"

    html = render_component(&TranscriptComponents.transcript/1, id: "chat-empty", entries: [], now: @at)
    assert html =~ "Waiting for the agent"
  end

  test "malformed and partial notifications degrade safely" do
    transcript =
      fold([
        note("item/started", %{}),
        note("item/completed", %{}),
        started(%{"id" => "a", "type" => "agentMessage"}),
        note("error", %{}),
        note("error", %{"error" => "plain failure"}),
        note("turn/diff/updated", %{}),
        %{payload: %{"method" => "item/completed", "params" => %{"item" => %{"id" => "p", "type" => "plan", "text" => "1. Do it"}}}},
        completed(%{"id" => "f", "type" => "fileChange"}),
        completed(%{"id" => "r", "type" => "reasoning", "summary" => [], "content" => ["raw thought"]}),
        completed(%{"id" => "g", "type" => "collabAgentToolCall", "tool" => "spawn"}),
        note("turn/plan/updated", %{"plan" => [%{"step" => "Odd", "status" => "weird"}]})
      ])

    assert [
             %{kind: "notice", text: "plain failure"},
             %{kind: "message", phase: "plan", text: "1. Do it", at: %DateTime{}},
             %{kind: "file_change", files: []},
             %{kind: "reasoning", text: "raw thought"},
             %{kind: "tool", name: "agents · spawn"},
             %{kind: "plan", steps: [%{status: "pending"}]}
           ] = transcript.entries

    assert transcript.files == []
  end

  test "tool lines show what was called and what came back, and unreadable images are skipped" do
    deep_text = Enum.reduce(1..10, %{"text" => "hidden"}, fn _level, inner -> %{"content" => [inner]} end)
    deep_image = Enum.reduce(1..10, %{"type" => "image", "data" => "eA=="}, fn _level, inner -> %{"inner" => inner} end)

    transcript =
      fold(
        [
          completed(%{"id" => "a", "type" => "mcpToolCall", "server" => "s", "tool" => "t", "arguments" => ~s({"q":1})}),
          completed(%{"id" => "b", "type" => "mcpToolCall", "server" => "s", "tool" => "t"}),
          completed(%{"id" => "c", "type" => "mcpToolCall", "server" => "s", "tool" => "t", "arguments" => %{"x" => <<0xFF>>}}),
          completed(%{"id" => "d", "type" => "mcpToolCall", "server" => "s", "tool" => "t", "error" => %{"message" => "denied"}}),
          completed(%{"id" => "e", "type" => "functionCallOutput", "output" => "done"}),
          completed(%{"id" => "f", "type" => "dynamicToolCall", "tool" => "t", "contentItems" => [deep_text, deep_image, 42]}),
          completed(%{"id" => "v", "type" => "imageView"}),
          completed(%{"id" => "g", "type" => "imageGeneration", "result" => Base.encode64("not really an image")}),
          completed(%{"id" => "h", "type" => "imageGeneration", "result" => ""}),
          completed(%{"id" => "i", "type" => "dynamicToolCall", "tool" => "github_api", "arguments" => %{"method" => "GET", "path" => "/repos/o/r/issues/1"}})
        ],
        store_image: fn _source -> :error end
      )

    assert [
             %{call: ~s({"q":1}), detail: nil},
             %{call: nil, detail: nil},
             %{call: nil, detail: nil},
             %{detail: "denied"},
             %{name: "tool", detail: "done"},
             %{name: "t", detail: nil, images: []},
             %{kind: "image", label: "Image", images: []},
             %{kind: "image", label: "Generated image", images: []},
             %{kind: "image", images: []},
             %{name: "github_api", call: "GET /repos/o/r/issues/1"}
           ] = transcript.entries
  end

  test "commands drop the login-shell wrapper and read as sentences when Codex parsed them" do
    command = fn id, text, actions -> completed(%{"id" => id, "type" => "commandExecution", "command" => text, "commandActions" => actions, "exitCode" => 0}) end

    transcript =
      fold([
        command.("a", ~S(/bin/bash -lc 'echo '"'"'hi'"'"''), [%{"type" => "unknown", "command" => "echo 'hi'"}]),
        command.("b", ~S(/bin/bash -lc "rg -n \"x\" src | wc -l"), []),
        command.("c", "cargo test", [
          %{"type" => "read", "name" => "a.md", "path" => "docs/a.md"},
          %{"type" => "listFiles", "path" => "src"},
          %{"type" => "search", "query" => "fn main", "path" => "src"}
        ]),
        command.("d", "rg --files", [%{"type" => "search"}, %{"type" => "search", "query" => "todo"}, %{"type" => "read", "path" => "/x/y/z.rs"}, %{"type" => "listFiles"}])
      ])

    assert [
             %{command: "echo 'hi'", summary: nil},
             %{command: ~S(rg -n "x" src | wc -l), summary: nil},
             %{command: "cargo test", summary: "Read a.md, Listed src, Searched for fn main in src"},
             %{summary: "Searched files, Searched for todo, Read z.rs, Listed files"}
           ] = transcript.entries
  end

  test "long command output keeps a valid UTF-8 tail within the byte limit" do
    [%{output: tail, output_truncated: true}] =
      fold([completed(%{"id" => "c", "type" => "commandExecution", "command" => "x", "aggregatedOutput" => String.duplicate("€", 4_000), "exitCode" => 0})]).entries

    assert byte_size(tail) <= 8_000
    assert String.valid?(tail)
  end

  test "chat rendering covers running, finished and unusual entries" do
    now = ~U[2026-09-27 12:00:00Z]

    command = %{kind: "command", status: "completed", output_truncated: false, at: now}

    entries = [
      %{id: "1", kind: "command", status: "running", command: "cargo xtask ci", output: "", exit_code: nil, duration_ms: nil, at: DateTime.add(now, -7_200, :second)},
      %{id: "2", kind: "command", status: "failed", command: "rm -rf build", output: nil, exit_code: nil, duration_ms: 61_000, at: "not a time"},
      Map.merge(command, %{id: "3", command: "ls", output: "a\nb", output_truncated: true, exit_code: 0, duration_ms: 42, at: nil}),
      Map.merge(command, %{id: "4", command: "true", output: "ok", exit_code: 0, duration_ms: nil, at: DateTime.to_iso8601(now)}),
      %{
        id: "5",
        kind: "file_change",
        status: "running",
        at: now,
        files: [
          %{path: "README.md", change: "add", additions: 1, deletions: 0, diff: "+++ b/README.md\n--- a/README.md\n+hi\n ctx"},
          %{path: "src/old.rs", change: "delete", additions: 0, deletions: 3, diff: ""}
        ]
      },
      %{id: "6", kind: "message", phase: "final_answer", text: "Done: see [site](http://example.org)\nsecond line\n- item\n  continued", at: now},
      %{id: "7", kind: "message", phase: "plan", text: "Plan text", at: now},
      %{id: "8", kind: "tool", name: "probe", detail: nil, images: [], status: "running", at: now},
      %{id: "10", kind: "tool", name: "github_api", call: "GET /repos/o/r", detail: "{}", images: [], status: "completed", at: now},
      Map.merge(command, %{id: "11", command: "cat docs/a.md", summary: "Read a.md", output: "text", exit_code: 0, duration_ms: 5}),
      %{id: "9", kind: "mystery", at: now}
    ]

    html = render_component(&TranscriptComponents.transcript/1, id: "chat", entries: entries, now: now)

    for text <- ["Running…", "No output", "1m 1s", "42ms", "exit 0", "earlier output trimmed", "2h 0m ago", "Editing 2 files", "(no diff captured)"] do
      assert html =~ text
    end

    assert html =~ ~s(class="file-badge file-add">A<) and html =~ ~s(class="file-badge file-del">D<)
    assert html =~ ~s(class="diff-meta") and html =~ ~s(class="diff-ctx") and html =~ ~s(class="diff-line-add")
    assert html =~ "final answer" and html =~ ~s(<a href="http://example.org")
    assert html =~ "second line" and html =~ "item continued"
    assert html =~ ~s(<span class="who-note">plan</span>)
    assert html =~ "probe" and html =~ "mystery"
    assert html =~ "GET /repos/o/r"
    assert html =~ ~s(<span class="term-summary" title="cat docs/a.md">Read a.md</span>) and html =~ ~s(class="term-script")

    html = render_component(&TranscriptComponents.transcript/1, id: "chat", entries: [hd(entries)], now: nil)
    refute html =~ "ago"
  end

  test "the rail shows plan steps and changed files with totals" do
    steps = [%{step: "A", status: "completed"}, %{step: "B", status: "in_progress"}, %{step: "C", status: "pending"}]
    html = render_component(&TranscriptComponents.plan_checklist/1, steps: steps, explanation: "Why")
    assert html =~ "plan-completed" and html =~ "plan-in_progress" and html =~ "plan-pending" and html =~ "Why"

    files = [%{path: "src/a.rs", additions: 2, deletions: 1}, %{path: "b.md", change: "add", additions: 3, deletions: 0}]
    html = render_component(&TranscriptComponents.files_changed/1, files: files)
    assert html =~ "+5" and html =~ "−1" and html =~ "2 files changed" and html =~ ~s(<span class="file-dir">src/</span>a.rs)

    assert render_component(&TranscriptComponents.files_changed/1, files: [%{path: "one.rs"}]) =~ "1 file changed"
  end
end
