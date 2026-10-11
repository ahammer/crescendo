defmodule SymphonyElixir.QuietContinuationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.{Operations, QuietContinuation, Service}

  setup do
    root = Path.join(System.tmp_dir!(), "quiet-evidence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "evidence.md"), "p99 failed: 21.00/20.67 ms; 20 ms gate unchanged")
    git(root, ["init", "-q"])
    git(root, ["add", "."])
    git(root, ["-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm", "prepared"])
    sha = git(root, ["rev-parse", "HEAD"]) |> String.trim()
    on_exit(fn -> File.rm_rf(root) end)

    args = %{
      "reason" => "Quiet-only acceptance unavailable",
      "source_sha" => sha,
      "pull_request" => "https://github.test/pull/1257",
      "evidence" => ["evidence.md"],
      "unmet_acceptance" => ["p99 failed", "quiet digest missing"]
    }

    %{root: root, args: args}
  end

  test "committed evidence has exact identity and changes invalidate reuse", %{root: root, args: args} do
    assert {:ok, prepared} = QuietContinuation.prepare(args, root)
    assert [%{path: "evidence.md", sha256: digest}] = prepared.evidence
    assert byte_size(digest) == 64
    assert QuietContinuation.revalidate(prepared, root).evidence_applicable
    File.write!(Path.join(root, "evidence.md"), "changed p99 evidence")
    refute QuietContinuation.revalidate(prepared, root).evidence_applicable
    assert {:error, _} = QuietContinuation.prepare(args, root)
    git(root, ["add", "."])
    git(root, ["-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm", "changed"])
    refute QuietContinuation.revalidate(prepared, root).evidence_applicable
    assert {:error, _} = QuietContinuation.prepare(args, root)
    assert {:ok, prepared} = QuietContinuation.prepare(%{args | "source_sha" => git(root, ["rev-parse", "HEAD"]) |> String.trim()}, root)
    File.rm!(Path.join(root, "evidence.md"))
    refute QuietContinuation.revalidate(prepared, root).evidence_applicable
  end

  test "untracked source invalidates preparation and reuse, while ignored artifacts do not", %{root: root, args: args} do
    File.write!(Path.join(root, ".git/info/exclude"), "scratch/\n")
    File.mkdir_p!(Path.join(root, "scratch"))
    File.write!(Path.join(root, "scratch/capture.txt"), "generated artifact")
    assert {:ok, prepared} = QuietContinuation.prepare(args, root)
    assert QuietContinuation.revalidate(prepared, root).evidence_applicable

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/new_source.ex"), "defmodule UncommittedSource do\nend\n")
    refute QuietContinuation.revalidate(prepared, root).evidence_applicable
    assert {:error, :invalid_prepared_evidence} = QuietContinuation.prepare(args, root)
  end

  test "a committed symlink cannot stand in for uncommitted evidence bytes", %{root: root, args: args} do
    File.write!(Path.join(root, ".git/mutable-report.md"), "p99 failed")
    File.ln_s!(".git/mutable-report.md", Path.join(root, "evidence-link.md"))
    git(root, ["add", "evidence-link.md"])
    git(root, ["-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm", "linked evidence"])
    args = %{args | "source_sha" => git(root, ["rev-parse", "HEAD"]) |> String.trim(), "evidence" => ["evidence-link.md"]}
    assert {:error, :invalid_prepared_evidence} = QuietContinuation.prepare(args, root)
  end

  test "invalid, missing, escaping, directory and oversized evidence fail closed", %{root: root, args: args} do
    for invalid <- [
          nil,
          %{},
          Map.put(args, "extra", true),
          %{args | "source_sha" => %{}},
          %{args | "source_sha" => "bad"},
          %{args | "reason" => " "},
          %{args | "evidence" => []},
          %{args | "unmet_acceptance" => []},
          %{args | "evidence" => ["missing"]},
          %{args | "evidence" => ["../evidence.md"]},
          %{args | "evidence" => ["/etc/passwd"]},
          %{args | "evidence" => [".git/config"]},
          %{args | "evidence" => ["evidence.md" <> <<0>>]},
          %{args | "evidence" => List.duplicate("evidence.md", 13)}
        ] do
      assert {:error, :invalid_prepared_evidence} = QuietContinuation.prepare(invalid, root)
    end

    assert {:error, _} = QuietContinuation.prepare(args, Path.dirname(root))
    assert {:error, _} = QuietContinuation.prepare(args, Path.join(root, "missing-workspace"))
    File.mkdir_p!(Path.join(root, "reports"))
    File.write!(Path.join(root, "reports/large"), String.duplicate("x", 131_073))
    git(root, ["add", "."])
    git(root, ["-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm", "large"])
    args = %{args | "source_sha" => git(root, ["rev-parse", "HEAD"]) |> String.trim()}
    assert {:error, _} = QuietContinuation.prepare(%{args | "evidence" => ["reports"]}, root)
    assert {:error, _} = QuietContinuation.prepare(%{args | "evidence" => ["reports/large"]}, root)
  end

  test "only selected local issue workers receive the tool and unavailable owners fail", %{root: root, args: args} do
    assert QuietContinuation.window() == %{}
    assert QuietContinuation.execute(args, %{})["success"] == false
    previous = Service.current()
    {:ok, service} = Service.parse(%{"quiet_window" => %{}, "projects" => %{"p" => %{}}}, Path.join(root, "service.yml"))
    Service.put_current(service)
    on_exit(fn -> :persistent_term.put({Service, :current}, previous) end)
    context = %{kind: :issue, recipient: self(), run_id: "run", issue_id: "1", workspace: root}
    assert QuietContinuation.available?(context)
    binding = DynamicTool.bind(helper_context: context)
    assert Enum.any?(binding.tool_specs, &(&1["name"] == "defer_quiet_acceptance"))

    for invalid <- [%{context | kind: :research}, %{context | kind: :pull_request}, Map.put(context, :worker_host, "remote")] do
      refute QuietContinuation.available?(invalid)
      refute Enum.any?(DynamicTool.bind(helper_context: invalid).tool_specs, &(&1["name"] == "defer_quiet_acceptance"))
    end

    assert QuietContinuation.execute(nil, context)["success"] == false
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}
    assert QuietContinuation.execute(args, %{context | recipient: dead})["success"] == false
    Service.put_current(%{service | quiet_window: nil})
    refute QuietContinuation.available?(context)
    refute Enum.any?(DynamicTool.bind(helper_context: context).tool_specs, &(&1["name"] == "defer_quiet_acceptance"))
  end

  test "missing git cannot establish prepared source or evidence applicability", %{root: root, args: args} do
    {:ok, prepared} = QuietContinuation.prepare(args, root)
    previous = System.get_env("PATH")

    try do
      System.put_env("PATH", root)
      assert {:error, :invalid_prepared_evidence} = QuietContinuation.prepare(args, root)
      refute QuietContinuation.revalidate(prepared, root).evidence_applicable
    after
      restore_env("PATH", previous)
    end
  end

  test "persistence is synchronous, survives reopen and fails without a store", %{root: root} do
    assert Operations.quiet_continuations(nil) == %{}
    assert {:error, :operations_unavailable} = Operations.save_quiet_continuations(nil, %{})
    path = Path.join(root, "operations.dets")
    {:ok, table} = Operations.open(path, :quiet_continuation_store)
    assert Operations.quiet_continuations(table) == %{}
    value = %{"canonical" => %{item_attempt: 3, reason: "quiet acceptance pending"}}
    assert :ok = Operations.save_quiet_continuations(table, value)
    Operations.close(table)
    {:ok, table} = Operations.open(path, :quiet_continuation_store)
    assert Operations.quiet_continuations(table) == value
    Operations.close(table)
    assert {:error, _} = Operations.save_quiet_continuations(table, value)
  end

  defp git(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    output
  end
end
