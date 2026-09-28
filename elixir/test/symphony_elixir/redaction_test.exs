defmodule SymphonyElixirWeb.RedactionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.Redaction

  defp payload do
    running = %{
      project: "nubu3d",
      issue_identifier: "GH-1",
      title: "Secret feature",
      labels: ["area:billing"],
      description: "Internal details",
      branch: "feat/secret",
      workspace_path: "/w/GH-1",
      session_id: "s",
      run_id: "abc",
      last_message: "reading billing.ts",
      recent_events: [%{text: "x"}],
      pull_request: %{title: "Secret"},
      research: %{channel: "qa", focus: "billing flows"},
      workspace: %{files: [%{path: "billing.ts"}]},
      transcript: [%{text: "secret"}],
      tokens: %{total_tokens: 10},
      model: "gpt-6-sol"
    }

    %{
      running: [running, %{running | project: "metalrain", issue_identifier: "GH-2"}],
      retrying: [%{project: "nubu3d", issue_identifier: "GH-3", error: "stack trace", workspace_path: "/w"}],
      blocked: [%{project: "nubu3d", issue_identifier: "GH-4", error: "e", workspace_path: "/w", session_id: "s", last_message: "m"}],
      upcoming: %{
        ready: [%{project: "nubu3d", issue_identifier: "GH-5", title: "Secret"}],
        waiting: [%{project: "metalrain", issue_identifier: "GH-6", title: "Public"}]
      },
      pull_requests: %{items: [%{project: "nubu3d", number: 7, title: "Secret PR", head_ref: "feat/secret", author: "a", url: "u"}]},
      usage: %{
        activity: [
          %{project: "nubu3d", kind: "pr_opened", summary: "Secret PR"},
          %{project: "metalrain", kind: "dispatch", summary: "s"}
        ]
      }
    }
  end

  test "a private project's items keep only what they are and how they are doing" do
    scrubbed = Redaction.payload(payload(), MapSet.new(["nubu3d"]))

    [private, public] = scrubbed.running
    assert %{issue_identifier: "GH-1", title: "Private work", labels: [], description: nil, branch: nil} = private
    assert %{run_id: nil, transcript: [], last_message: nil, recent_events: [], pull_request: nil} = private
    assert %{research: %{channel: "qa"}, model: "gpt-6-sol", tokens: %{total_tokens: 10}} = private
    assert private.workspace.files == []
    assert public.title == "Secret feature"

    assert [%{error: nil, workspace_path: nil}] = scrubbed.retrying
    assert [%{error: nil, session_id: nil, last_message: nil}] = scrubbed.blocked
    assert [%{title: "Private work"}] = scrubbed.upcoming.ready
    assert [%{title: "Public"}] = scrubbed.upcoming.waiting
    assert [%{title: "Private work", number: 7, url: "u"} = pull] = scrubbed.pull_requests.items
    refute Map.has_key?(pull, :head_ref)
    assert [%{kind: "pr_opened"} = event, %{summary: "s"}] = scrubbed.usage.activity
    refute Map.has_key?(event, :summary)
  end

  test "nothing to redact, or an error payload, passes through; single items keep only their status" do
    assert Redaction.payload(payload(), MapSet.new()) == payload()
    assert Redaction.payload(%{error: %{code: "x"}}, MapSet.new(["nubu3d"])) == %{error: %{code: "x"}}

    running = hd(payload().running) |> Map.delete(:transcript) |> Map.put(:research, nil)
    assert [%{research: nil} = scrubbed] = Redaction.payload(%{payload() | running: [running]}, MapSet.new(["nubu3d"])).running
    refute Map.has_key?(scrubbed, :transcript)

    item = %{project: "nubu3d", issue_identifier: "GH-1", issue_id: "1", status: "running", transcript: [%{text: "secret"}]}
    assert Redaction.item(item) == %{project: "nubu3d", issue_identifier: "GH-1", issue_id: "1", status: "running", redacted: true}
  end
end
