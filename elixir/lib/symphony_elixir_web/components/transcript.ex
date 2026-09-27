defmodule SymphonyElixirWeb.TranscriptComponents do
  @moduledoc """
  The Active Agent Workspace's observed chat: one run's transcript shown the
  way an editor's agent chat shows it. Messages are bubbles, thinking folds
  away, commands are terminal cards, edits carry their diffs, and images sit
  inline where the agent saw them.

  Agent text gets light formatting (headings, lists, code, bold, links) from
  parsed blocks rendered through HEEx, so every character stays escaped.
  Collapsible parts keep the reader's open/closed choice across live updates.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr(:id, :string, required: true)
  attr(:entries, :list, required: true)
  attr(:now, :any, required: true)

  @spec transcript(map()) :: Phoenix.LiveView.Rendered.t()
  def transcript(assigns) do
    ~H"""
    <ol id={@id} class="chat" phx-hook="ChatScroll" aria-label="Agent transcript" aria-live="polite">
      <li :if={@entries == []} class="chat-empty">Waiting for the agent's first step…</li>
      <li :for={entry <- @entries} :key={entry.id} id={"#{@id}-#{entry.id}"} class={"chat-row chat-#{entry.kind}"}>
        <.entry entry={entry} now={@now} />
      </li>
    </ol>
    """
  end

  attr(:steps, :list, required: true)
  attr(:explanation, :string, default: nil)

  @spec plan_checklist(map()) :: Phoenix.LiveView.Rendered.t()
  def plan_checklist(assigns) do
    ~H"""
    <p :if={@explanation} class="plan-note"><%= @explanation %></p>
    <ol class="plan">
      <li :for={step <- @steps} class={"plan-step plan-#{step.status}"}>
        <span class="plan-mark" aria-hidden="true"></span>
        <span class="plan-text"><%= step.step %></span>
        <span class="sr-only"><%= step_status_label(step.status) %></span>
      </li>
    </ol>
    """
  end

  attr(:files, :list, required: true)

  @spec files_changed(map()) :: Phoenix.LiveView.Rendered.t()
  def files_changed(assigns) do
    assigns =
      assign(assigns,
        additions: assigns.files |> Enum.map(&(&1[:additions] || 0)) |> Enum.sum(),
        deletions: assigns.files |> Enum.map(&(&1[:deletions] || 0)) |> Enum.sum()
      )

    ~H"""
    <ul class="file-list">
      <li :for={file <- @files} class="file-row" title={file.path}>
        <span class={"file-badge file-#{file_change_class(file[:change])}"}><%= file_change_letter(file[:change]) %></span>
        <span class="file-path"><span class="file-dir"><%= dir_part(file.path) %></span><%= Path.basename(file.path) %></span>
        <span class="diff-add">+<%= file[:additions] || 0 %></span>
        <span class="diff-del">−<%= file[:deletions] || 0 %></span>
      </li>
    </ul>
    <p class="file-total"><span class="diff-add">+<%= @additions %></span> <span class="diff-del">−<%= @deletions %></span> · <%= length(@files) %> file<%= if length(@files) == 1, do: "", else: "s" %> changed</p>
    """
  end

  attr(:entry, :map, default: nil)
  attr(:fallback, :string, default: nil)

  @doc """
  One glanceable line for an agent's latest step, for the dashboard HUD.
  `fallback` covers runs that have no transcript yet.
  """
  @spec status_line(map()) :: Phoenix.LiveView.Rendered.t()
  def status_line(assigns) do
    {state, icon, text} = headline(assigns.entry, assigns.fallback)
    assigns = assign(assigns, state: state, icon: icon, text: text)

    ~H"""
    <span class={"now now-#{@state}"}><span class="now-icon" aria-hidden="true"><%= @icon %></span><span class="now-text"><%= @text %></span></span>
    """
  end

  defp headline(nil, nil), do: {"idle", "…", "Starting…"}
  defp headline(nil, fallback), do: {"idle", "•", fallback}
  defp headline(%{kind: "reasoning", status: "running"}, _fallback), do: {"running", "◌", "Thinking…"}
  defp headline(%{kind: "reasoning"} = entry, _fallback), do: {"done", "◌", preview(entry.text)}
  defp headline(%{kind: "command"} = entry, _fallback), do: command_headline(command_state(entry), entry[:summary] || entry.command, entry)
  defp headline(%{kind: "message"} = entry, _fallback), do: {"done", "✦", preview(entry.text)}
  defp headline(%{kind: "file_change"} = entry, _fallback), do: {step_state(entry), "✎", "#{if entry[:status] == "running", do: "Editing", else: "Edited"} #{files_text(entry.files)}"}
  defp headline(%{kind: "tool"} = entry, _fallback), do: {step_state(entry), "⚙", [entry.name, entry[:call]] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")}
  defp headline(%{kind: "image"} = entry, _fallback), do: {"done", "▣", "Viewed #{entry[:label] || "an image"}"}
  defp headline(%{kind: "search"} = entry, _fallback), do: {"done", "⌕", "Searched the web for #{entry.query}"}
  defp headline(%{kind: "plan"} = entry, _fallback), do: {"done", "☰", "Updated the plan · #{Enum.count(entry.steps, &(&1.status == "completed"))}/#{length(entry.steps)} steps"}
  defp headline(%{kind: "notice"} = entry, _fallback), do: {if(entry[:tone] == "error", do: "failed", else: "done"), "!", entry.text}
  defp headline(%{kind: "prompt"}, _fallback), do: {"done", "↳", "Read the task"}
  defp headline(entry, _fallback), do: {"done", "•", to_string(entry[:kind])}

  defp command_headline("running", what, _entry), do: {"running", "◔", "Running #{what}"}
  defp command_headline("failed", what, entry), do: {"failed", "✕", "#{what} failed#{if is_integer(entry[:exit_code]), do: " (exit #{entry.exit_code})"}"}
  defp command_headline(_state, what, _entry), do: {"done", "✓", what}

  defp step_state(%{status: "running"}), do: "running"
  defp step_state(%{status: "failed"}), do: "failed"
  defp step_state(_entry), do: "done"

  defp files_text([_file]), do: "1 file"
  defp files_text(files), do: "#{length(files)} files"

  attr(:entries, :list, required: true)

  @doc "Every image in a run, newest first; each opens full size."
  @spec gallery(map()) :: Phoenix.LiveView.Rendered.t()
  def gallery(assigns) do
    images =
      for entry <- Enum.reverse(assigns.entries), image <- Map.get(entry, :images, []) do
        %{src: image.src, label: entry[:label] || entry[:name] || "Image"}
      end

    assigns = assign(assigns, :images, images)

    ~H"""
    <p :if={@images == []} class="empty-state">No images in this run yet.</p>
    <div :if={@images != []} class="gallery">
      <a :for={image <- @images} class="shot gallery-shot" href={image.src} target="_blank" rel="noopener" title={image.label}>
        <img src={image.src} alt={image.label} loading="lazy" />
        <span class="gallery-label"><%= image.label %></span>
      </a>
    </div>
    """
  end

  attr(:entry, :map, required: true)
  attr(:now, :any, required: true)

  defp entry(%{entry: %{kind: "prompt"}} = assigns) do
    ~H"""
    <div class="msg msg-user">
      <div class="bubble bubble-user">
        <header class="bubble-head"><span class="who">Symphony</span><span class="who-note">task prompt</span><.stamp at={@entry.at} now={@now} /></header>
        <details class="fold" phx-mounted={keep_open()}>
          <summary><%= first_line(@entry.text) %></summary>
          <pre class="prompt-text"><%= @entry.text %></pre>
        </details>
      </div>
      <span class="avatar avatar-user" aria-hidden="true">S</span>
    </div>
    """
  end

  defp entry(%{entry: %{kind: "message"}} = assigns) do
    ~H"""
    <div class={["msg msg-agent", @entry[:phase] == "final_answer" && "msg-final"]}>
      <span class="avatar avatar-agent" aria-hidden="true">✦</span>
      <div class="bubble">
        <header class="bubble-head">
          <span class="who">Codex</span>
          <span :if={phase_label(@entry[:phase])} class="who-note"><%= phase_label(@entry[:phase]) %></span>
          <.stamp at={@entry.at} now={@now} />
        </header>
        <.rich text={@entry.text} />
      </div>
    </div>
    """
  end

  defp entry(%{entry: %{kind: "reasoning", text: ""}} = assigns) do
    ~H"""
    <div class="act act-thinking act-live">
      <div class="act-line">
        <span class="act-icon status-running" aria-hidden="true">◌</span>
        <span class="act-title">Thinking…</span>
        <.stamp at={@entry.at} now={@now} />
      </div>
    </div>
    """
  end

  defp entry(%{entry: %{kind: "reasoning"}} = assigns) do
    ~H"""
    <details class="act act-thinking" phx-mounted={keep_open()}>
      <summary>
        <span class="act-icon" aria-hidden="true">◌</span>
        <span class="act-title">Thinking</span>
        <span class="act-preview"><%= preview(@entry.text) %></span>
        <.stamp at={@entry.at} now={@now} />
      </summary>
      <div class="thinking-text"><.rich text={@entry.text} /></div>
    </details>
    """
  end

  defp entry(%{entry: %{kind: "command"}} = assigns) do
    assigns = assign(assigns, :state, command_state(assigns.entry))

    ~H"""
    <div class={"term term-#{@state}"}>
      <details class="fold" open={@state == "failed"} phx-mounted={keep_open()}>
        <summary class="term-head">
          <span class={"term-status status-#{@state}"} aria-label={command_label(@state, @entry)}><%= command_icon(@state) %></span>
          <%= if @entry[:summary] do %>
            <span class="term-summary" title={@entry.command}><%= @entry.summary %></span>
          <% else %>
            <code class="term-command" title={@entry.command}><span class="term-prompt">$</span> <%= @entry.command %></code>
          <% end %>
          <span class="term-meta"><%= command_meta(@state, @entry) %></span>
          <.stamp at={@entry.at} now={@now} />
        </summary>
        <p :if={@entry[:summary]} class="term-script"><span class="term-prompt">$</span> <%= @entry.command %></p>
        <%= if @entry[:output] in [nil, ""] do %>
          <p class="term-empty"><%= if @state == "running", do: "Running…", else: "No output" %></p>
        <% else %>
          <pre class="term-output"><span :if={@entry[:output_truncated]} class="term-clip">… earlier output trimmed</span><%= @entry.output %></pre>
        <% end %>
      </details>
    </div>
    """
  end

  defp entry(%{entry: %{kind: "file_change"}} = assigns) do
    ~H"""
    <div class="edit-card">
      <header class="edit-head">
        <span class="act-icon" aria-hidden="true">✎</span>
        <span class="act-title"><%= if @entry[:status] == "running", do: "Editing", else: "Edited" %> <%= length(@entry.files) %> file<%= if length(@entry.files) == 1, do: "", else: "s" %></span>
        <.stamp at={@entry.at} now={@now} />
      </header>
      <details :for={file <- @entry.files} class="edit-file" phx-mounted={keep_open()}>
        <summary>
          <span class={"file-badge file-#{file_change_class(file.change)}"}><%= file_change_letter(file.change) %></span>
          <span class="file-path" title={file.path}><span class="file-dir"><%= dir_part(file.path) %></span><%= Path.basename(file.path) %></span>
          <span class="diff-add">+<%= file.additions %></span>
          <span class="diff-del">−<%= file.deletions %></span>
        </summary>
        <pre class="diff"><span :for={line <- diff_lines(file.diff)} class={diff_class(line)}><%= line %></span></pre>
      </details>
    </div>
    """
  end

  defp entry(%{entry: %{kind: "image"}} = assigns) do
    ~H"""
    <div class="act act-image">
      <div class="act-line">
        <span class="act-icon" aria-hidden="true">▣</span>
        <span class="act-title">Viewed image</span>
        <span class="act-preview"><%= @entry[:label] %></span>
        <.stamp at={@entry.at} now={@now} />
      </div>
      <.images images={@entry[:images] || []} label={@entry[:label]} large={true} />
      <p :if={(@entry[:images] || []) == []} class="act-note">Image not kept (unsupported type or too large).</p>
    </div>
    """
  end

  defp entry(%{entry: %{kind: "tool"}} = assigns) do
    ~H"""
    <div class={["act act-tool", @entry[:status] == "failed" && "act-failed"]}>
      <details class="act-fold" phx-mounted={keep_open()}>
        <summary class="act-line">
          <span class="act-icon" aria-hidden="true"><%= if @entry[:status] == "running", do: "◔", else: "⚙" %></span>
          <span class="act-title"><%= @entry.name %></span>
          <span class="act-preview"><%= preview(@entry[:call] || @entry[:detail]) %></span>
          <.stamp at={@entry.at} now={@now} />
        </summary>
        <pre class="act-detail"><%= @entry[:detail] || "No result text" %></pre>
      </details>
      <.images images={@entry[:images] || []} label={@entry.name} large={true} />
    </div>
    """
  end

  defp entry(%{entry: %{kind: "search"}} = assigns) do
    ~H"""
    <div class="act act-search">
      <div class="act-line">
        <span class="act-icon" aria-hidden="true">⌕</span>
        <span class="act-title">Searched the web</span>
        <span class="act-preview"><%= @entry.query %></span>
        <.stamp at={@entry.at} now={@now} />
      </div>
    </div>
    """
  end

  defp entry(%{entry: %{kind: "plan"}} = assigns) do
    assigns = assign(assigns, :done, Enum.count(assigns.entry.steps, &(&1.status == "completed")))

    ~H"""
    <details class="act act-plan" phx-mounted={keep_open()}>
      <summary>
        <span class="act-icon" aria-hidden="true">☰</span>
        <span class="act-title">Updated plan</span>
        <span class="act-preview"><%= @done %>/<%= length(@entry.steps) %> steps done</span>
        <.stamp at={@entry.at} now={@now} />
      </summary>
      <.plan_checklist steps={@entry.steps} explanation={@entry[:explanation]} />
    </details>
    """
  end

  defp entry(%{entry: %{kind: "notice"}} = assigns) do
    ~H"""
    <p class={"notice notice-#{@entry[:tone] || "info"}"}><%= @entry.text %> <.stamp at={@entry.at} now={@now} /></p>
    """
  end

  defp entry(assigns) do
    ~H"""
    <p class="notice notice-info"><%= @entry[:kind] %> <.stamp at={@entry.at} now={@now} /></p>
    """
  end

  attr(:images, :list, required: true)
  attr(:label, :string, default: nil)
  attr(:large, :boolean, default: false)

  defp images(assigns) do
    ~H"""
    <div :if={@images != []} class={["shots", @large && "shots-large"]}>
      <a :for={image <- @images} class="shot" href={image.src} target="_blank" rel="noopener" title="Open full size">
        <img src={image.src} alt={@label || "Image from the agent run"} loading="lazy" />
      </a>
    </div>
    """
  end

  attr(:at, :any, required: true)
  attr(:now, :any, required: true)

  defp stamp(assigns) do
    ~H"""
    <time class="stamp" datetime={iso(@at)} title={iso(@at)}><%= ago(@at, @now) %></time>
    """
  end

  attr(:text, :string, required: true)

  defp rich(assigns) do
    assigns = assign(assigns, :blocks, blocks(assigns.text))

    ~H"""
    <div class="rich">
      <%= for block <- @blocks do %>
        <%= case block do %>
          <% {:heading, parts} -> %>
            <p class="rich-h"><.inline parts={parts} /></p>
          <% {:para, parts} -> %>
            <p><.inline parts={parts} /></p>
          <% {:list, items} -> %>
            <ul><li :for={parts <- items}><.inline parts={parts} /></li></ul>
          <% {:code, code} -> %>
            <pre class="rich-code"><code><%= code %></code></pre>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr(:parts, :list, required: true)

  # Written on one line so HEEx adds no whitespace between inline parts.
  defp inline(assigns) do
    ~H"""
    <%= for part <- @parts do %><%= case part do %><% {:code, text} -> %><code><%= text %></code><% {:strong, text} -> %><strong><%= text %></strong><% {:link, text, url} -> %><a href={url} target="_blank" rel="noopener noreferrer"><%= text %></a><% {:ref, text, target} -> %><code class="ref" title={target}><%= text %></code><% {:text, text} -> %><%= text %><% end %><% end %>
    """
  end

  @doc """
  Splits agent text into display blocks: `{:heading, parts}`, `{:para, parts}`,
  `{:list, [parts]}` and `{:code, text}`, where parts come from `inline_parts/1`.
  """
  @spec blocks(String.t()) :: [tuple()]
  def blocks(text) when is_binary(text) do
    {blocks, open} = text |> String.split("\n") |> Enum.reduce({[], nil}, &block_line/2)
    blocks |> close(open) |> Enum.reverse()
  end

  def blocks(_text), do: []

  # Inside a fence everything is code until the closing fence.
  defp block_line(line, {blocks, {:code, lines}}) do
    if fence?(line), do: {close(blocks, {:code, lines}), nil}, else: {blocks, {:code, [line | lines]}}
  end

  defp block_line(line, {blocks, open}) do
    trimmed = String.trim(line)

    cond do
      fence?(line) -> {close(blocks, open), {:code, []}}
      trimmed == "" -> {close(blocks, open), nil}
      match = Regex.run(~r/^\#{1,6}\s+(.+)$/, trimmed) -> {[{:heading, inline_parts(Enum.at(match, 1))} | close(blocks, open)], nil}
      match = Regex.run(~r/^(?:[-*+]|\d{1,3}[.)])\s+(.+)$/, trimmed) -> list_item(blocks, open, Enum.at(match, 1))
      true -> text_line(blocks, open, trimmed)
    end
  end

  defp list_item(blocks, {:list, items}, text), do: {blocks, {:list, [text | items]}}
  defp list_item(blocks, open, text), do: {close(blocks, open), {:list, [text]}}

  defp text_line(blocks, {:para, lines}, text), do: {blocks, {:para, [text | lines]}}
  defp text_line(blocks, {:list, [last | items]}, text), do: {blocks, {:list, ["#{last} #{text}" | items]}}
  defp text_line(blocks, open, text), do: {close(blocks, open), {:para, [text]}}

  defp close(blocks, nil), do: blocks
  defp close(blocks, {:para, lines}), do: [{:para, lines |> Enum.reverse() |> Enum.join("\n") |> inline_parts()} | blocks]
  defp close(blocks, {:list, items}), do: [{:list, items |> Enum.reverse() |> Enum.map(&inline_parts/1)} | blocks]
  defp close(blocks, {:code, lines}), do: [{:code, lines |> Enum.reverse() |> Enum.join("\n")} | blocks]

  defp fence?(line), do: line |> String.trim_leading() |> String.starts_with?("```")

  @inline ~r/`[^`\n]+`|\*\*[^*\n]+\*\*|\[[^\]\n]+\]\([^)\s]+\)/
  @link ~r/\A\[([^\]\n]+)\]\(([^)\s]+)\)\z/

  @doc "Splits a line into `{:text | :code | :strong, text}`, `{:link, text, url}` and `{:ref, text, target}` parts."
  @spec inline_parts(String.t()) :: [tuple()]
  def inline_parts(text) do
    @inline
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(&inline_part/1)
  end

  defp inline_part(token) do
    cond do
      Regex.match?(~r/\A`[^`\n]+`\z/, token) -> {:code, String.slice(token, 1..-2//1)}
      Regex.match?(~r/\A\*\*[^*\n]+\*\*\z/, token) -> {:strong, String.slice(token, 2..-3//1)}
      match = Regex.run(@link, token) -> link_part(Enum.at(match, 1), Enum.at(match, 2))
      true -> {:text, token}
    end
  end

  # Only web links become links; file references stay text with the target as a tooltip.
  defp link_part(text, "http://" <> _ = url), do: {:link, text, url}
  defp link_part(text, "https://" <> _ = url), do: {:link, text, url}
  defp link_part(text, target), do: {:ref, text, target}

  defp keep_open, do: JS.ignore_attributes(["open"])

  defp phase_label("final_answer"), do: "final answer"
  defp phase_label("plan"), do: "plan"
  defp phase_label(_phase), do: nil

  defp command_state(%{status: "running"}), do: "running"
  defp command_state(%{status: "failed"}), do: "failed"
  defp command_state(%{exit_code: code}) when is_integer(code) and code != 0, do: "failed"
  defp command_state(_entry), do: "ok"

  defp command_icon("running"), do: "◔"
  defp command_icon("failed"), do: "✕"
  defp command_icon(_state), do: "✓"

  defp command_label("running", _entry), do: "Running"
  defp command_label(state, entry), do: "#{if state == "failed", do: "Failed", else: "Succeeded"}#{exit_text(entry)}"

  defp command_meta("running", _entry), do: "running"

  defp command_meta(_state, entry) do
    [exit_text(entry), duration(entry[:duration_ms])] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")
  end

  defp exit_text(%{exit_code: code}) when is_integer(code), do: "exit #{code}"
  defp exit_text(_entry), do: ""

  defp duration(ms) when is_integer(ms) and ms >= 60_000, do: "#{div(ms, 60_000)}m #{rem(div(ms, 1_000), 60)}s"
  defp duration(ms) when is_integer(ms) and ms >= 1_000, do: "#{Float.round(ms / 1_000, 1)}s"
  defp duration(ms) when is_integer(ms), do: "#{ms}ms"
  defp duration(_ms), do: nil

  defp file_change_letter("add"), do: "A"
  defp file_change_letter("delete"), do: "D"
  defp file_change_letter(_change), do: "M"

  defp file_change_class("add"), do: "add"
  defp file_change_class("delete"), do: "del"
  defp file_change_class(_change), do: "mod"

  defp dir_part(path) do
    case Path.dirname(path) do
      "." -> ""
      dir -> dir <> "/"
    end
  end

  defp diff_lines(diff) when is_binary(diff) and diff != "", do: String.split(diff, "\n")
  defp diff_lines(_diff), do: ["(no diff captured)"]

  defp diff_class("@@" <> _), do: "diff-hunk"
  defp diff_class("+++" <> _), do: "diff-meta"
  defp diff_class("---" <> _), do: "diff-meta"
  defp diff_class("+" <> _), do: "diff-line-add"
  defp diff_class("-" <> _), do: "diff-line-del"
  defp diff_class(_line), do: "diff-ctx"

  defp step_status_label("completed"), do: "done"
  defp step_status_label("in_progress"), do: "in progress"
  defp step_status_label(_status), do: "pending"

  defp first_line(text) do
    text |> String.split("\n", trim: true) |> List.first("") |> preview()
  end

  defp preview(nil), do: nil

  defp preview(text) do
    line = text |> String.replace(~r/\*\*|`|^#+\s*/m, "") |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(line) > 160, do: String.slice(line, 0, 159) <> "…", else: line
  end

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(at) when is_binary(at), do: at
  defp iso(_at), do: nil

  # Minute resolution keeps a live transcript from re-sending every stamp each second.
  defp ago(at, %DateTime{} = now) do
    case parse(at) do
      nil ->
        ""

      time ->
        seconds = DateTime.diff(now, time)

        cond do
          seconds < 60 -> "now"
          seconds < 3_600 -> "#{div(seconds, 60)}m ago"
          true -> "#{div(seconds, 3_600)}h #{rem(div(seconds, 60), 60)}m ago"
        end
    end
  end

  defp ago(_at, _now), do: ""

  defp parse(%DateTime{} = at), do: at

  defp parse(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, time, _offset} -> time
      _ -> nil
    end
  end

  defp parse(_at), do: nil
end
