defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Thin GitHub REST client for repository issue polling.
  """

  require Logger
  alias SymphonyElixir.{Config, Handoff}
  alias SymphonyElixir.GitHub.ETagCache
  alias SymphonyElixir.Tracker.Issue

  @default_api_url "https://api.github.com"
  @api_version "2022-11-28"
  @page_size 100
  @user_agent "symphony"

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker_settings) do
    with {:ok, _settings} <- settings(tracker_settings), do: :ok
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings) do
    provider = provider_settings(tracker_settings)

    [
      "GITHUB_TOKEN",
      "GH_TOKEN",
      "GITHUB_ENTERPRISE_TOKEN",
      "GH_ENTERPRISE_TOKEN" | env_reference_names([provider["token"]])
    ]
    |> Enum.uniq()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    config = Config.settings!()
    fetch_issues_by_states(state_names, planning_tracker(config), &perform_request/5, pull_policy(config))
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) when is_list(issue_ids) do
    config = Config.settings!()
    fetch_issues_by_ids(issue_ids, planning_tracker(config), &perform_request/5, pull_policy(config))
  end

  @spec clear_label(Issue.t(), String.t()) :: :ok | {:error, term()}
  def clear_label(issue, label), do: clear_label_for_test(issue, label, Config.settings!().tracker, &perform_request/5)

  @spec retire(Issue.t(), String.t()) :: :ok | {:error, term()}
  def retire(issue, reason), do: retire_for_test(issue, reason, Config.settings!().tracker, &perform_request/5)

  @doc false
  @spec clear_label_for_test(Issue.t(), String.t(), map(), function()) :: :ok | {:error, term()}
  def clear_label_for_test(%Issue{id: id}, label, tracker_settings, request_fun) do
    with {:ok, settings} <- settings(tracker_settings),
         path = "#{repository_issues_path(settings)}/#{id}/labels/#{URI.encode(label, &URI.char_unreserved?/1)}",
         {:ok, _} <- request_with_settings("DELETE", path, %{}, nil, settings, request_fun, true) do
      :ok
    end
  end

  @doc false
  @spec retire_for_test(Issue.t(), String.t(), map(), function()) :: :ok | {:error, term()}
  def retire_for_test(%Issue{} = issue, reason, tracker_settings, request_fun) do
    with {:ok, settings} <- settings(tracker_settings),
         :ok <- comment_and_close(settings, request_fun, issue.kind, issue.id, reason) do
      close_draft_pulls(settings, request_fun, issue)
    end
  end

  defp comment_and_close(settings, request_fun, kind, number, reason) do
    {path, body} =
      if kind == :pull_request,
        do: {"#{repository_pulls_path(settings)}/#{number}", %{"state" => "closed"}},
        else: {"#{repository_issues_path(settings)}/#{number}", %{"state" => "closed", "state_reason" => "not_planned"}}

    comments = "#{repository_issues_path(settings)}/#{number}/comments"

    with {:ok, _} <- request_with_settings("POST", comments, %{}, %{"body" => reason}, settings, request_fun, true),
         {:ok, _} <- request_with_settings("PATCH", path, %{}, body, settings, request_fun, true) do
      :ok
    end
  end

  # Drafts left behind by an issue's worker would otherwise linger forever:
  # close drafts with explicit ownership, never incidental dependency references.
  defp close_draft_pulls(_settings, _request_fun, %Issue{kind: :pull_request}), do: :ok

  defp close_draft_pulls(settings, request_fun, %Issue{id: id}) do
    number = Regex.escape(id)
    reference = ~r/^\s*(?:(?:close[sd]?|fix(?:es|ed)?|resolve[sd]?)\s+|(?:Symphony|Crescendo) issue:\s*)##{number}\b/im
    branch = ~r/(?:^|\/)issue-#{number}(?:-|$)/
    reason = "Closed by Symphony: issue ##{id} was retired after exhausting its attempts."

    with {:ok, pulls} <- fetch_raw_pull_pages(settings, request_fun, 1, []) do
      pulls
      |> Enum.filter(&draft_for_issue?(&1, reference, branch))
      |> Enum.reduce_while(:ok, &close_pull(&1, &2, settings, request_fun, reason))
    end
  end

  defp draft_for_issue?(pull, reference, branch) do
    pull["draft"] == true and
      (Regex.match?(reference, pull["body"] || "") or Regex.match?(branch, get_in(pull, ["head", "ref"]) || ""))
  end

  defp close_pull(pull, :ok, settings, request_fun, reason) do
    case comment_and_close(settings, request_fun, :pull_request, Integer.to_string(pull["number"]), reason) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  @doc """
  Summarizes CI for a commit as `"pending"`, `"failure"`, `"success"`, or
  `"none"` from both commit statuses and check runs.
  """
  @spec fetch_commit_ci_state(String.t()) :: {:ok, String.t()} | {:error, term()}
  def fetch_commit_ci_state(sha) when is_binary(sha) do
    fetch_commit_ci_state_for_test(sha, Config.settings!().tracker, &perform_request/5)
  end

  @doc false
  @spec fetch_commit_ci_state_for_test(String.t(), map(), function()) :: {:ok, String.t()} | {:error, term()}
  def fetch_commit_ci_state_for_test(sha, tracker_settings, request_fun) do
    get = fn settings, suffix, params ->
      path = "/repos/#{encoded_repo(settings.repo)}/commits/#{URI.encode(sha, &URI.char_unreserved?/1)}/#{suffix}"
      request_with_settings("GET", path, params, nil, settings, request_fun, false)
    end

    with {:ok, settings} <- settings(tracker_settings),
         {:ok, %{} = status} <- get.(settings, "status", %{}),
         {:ok, %{} = checks} <- get.(settings, "check-runs", %{"per_page" => @page_size}) do
      check_states = checks["check_runs"] |> List.wrap() |> Enum.map(&check_run_ci_state/1)
      {:ok, combine_ci_states([status_ci_state(status) | check_states])}
    else
      {:ok, _payload} -> {:error, :github_unknown_payload}
      error -> error
    end
  end

  @doc """
  Reads a file or directory listing from the repository's default branch
  (the contents API). A missing path answers `{:ok, :not_found}`.
  """
  @spec fetch_contents(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def fetch_contents(path, opts \\ []) when is_binary(path) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)
    encoded = path |> String.split("/") |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))

    with {:ok, settings} <- settings(tracker_settings) do
      request_with_settings("GET", "/repos/#{encoded_repo(settings.repo)}/contents/#{encoded}", %{}, nil, settings, request_fun, true)
    end
  end

  @doc "Reads the current default-branch commit for native planning preflight."
  @spec source_revision(keyword()) :: {:ok, String.t()} | {:error, term()}
  def source_revision(opts \\ []) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    with {:ok, settings} <- settings(tracker_settings),
         path = "/repos/#{encoded_repo(settings.repo)}/commits",
         {:ok, [%{"sha" => sha} | _]} when is_binary(sha) <-
           request_with_settings("GET", path, %{"per_page" => 1}, nil, settings, request_fun, true) do
      {:ok, sha}
    else
      {:error, _} = error -> error
      _ -> {:error, :source_revision_unavailable}
    end
  end

  @doc """
  Counts the issues and pull requests carrying `label` that were opened at or
  after `since`: what an autopilot task run delivered.
  """
  @spec fetch_task_deliveries(String.t(), DateTime.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_task_deliveries(label, %DateTime{} = since, opts \\ []) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)
    params = %{"labels" => label, "state" => "all", "since" => DateTime.to_iso8601(since), "per_page" => @page_size}

    with {:ok, settings} <- settings(tracker_settings),
         {:ok, items} when is_list(items) <- request_with_settings("GET", "/repos/#{encoded_repo(settings.repo)}/issues", params, nil, settings, request_fun, false) do
      opened = Enum.filter(items, &opened_since?(&1, since))
      {prs, issues} = Enum.split_with(opened, &Map.has_key?(&1, "pull_request"))
      outputs = Enum.map(opened, &research_output/1)
      {:ok, %{issues: length(issues), pull_requests: length(prs), outputs: outputs, association: "channel_label_and_creation_window"}}
    else
      {:ok, _payload} -> {:error, :github_unknown_payload}
      error -> error
    end
  end

  defp research_output(item) do
    %{number: item["number"], url: item["html_url"], created_at: item["created_at"], kind: if(item["pull_request"], do: "pull_request", else: "issue")}
  end

  defp opened_since?(%{"created_at" => created_at}, since) do
    case DateTime.from_iso8601(to_string(created_at)) do
      {:ok, at, _offset} -> DateTime.compare(at, since) != :lt
      _ -> false
    end
  end

  defp opened_since?(_item, _since), do: false

  @spec fetch_open_pull_requests() :: {:ok, [map()]} | {:error, term()}
  def fetch_open_pull_requests do
    fetch_open_pull_requests_for_test(Config.settings!().tracker, &perform_request/5)
  end

  @spec fetch_pull_status(pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def fetch_pull_status(number) when is_integer(number) and number > 0 do
    with {:ok, settings} <- settings(Config.settings!().tracker),
         {:ok, payload} <- request_with_settings("GET", "/repos/#{encoded_repo(settings.repo)}/pulls/#{number}", %{}, nil, settings, &perform_request/5, false),
         true <- is_map(payload) or {:error, :github_unknown_payload} do
      {:ok, if(payload["merged_at"], do: "merged", else: payload["state"] || "unknown")}
    end
  end

  @doc "Head and merge evidence observed from GitHub; does not assert review acceptance."
  @spec fetch_pull_observation(pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_pull_observation(number, opts \\ []) do
    tracker = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    with {:ok, settings} <- settings(tracker),
         {:ok, payload} <- request_with_settings("GET", "/repos/#{encoded_repo(settings.repo)}/pulls/#{number}", %{}, nil, settings, request_fun, false),
         true <- is_map(payload) or {:error, :github_unknown_payload} do
      {:ok,
       %{
         status: if(payload["merged_at"], do: "merged", else: payload["state"] || "unknown"),
         head_sha: get_in(payload, ["head", "sha"]),
         head_ref: get_in(payload, ["head", "ref"]),
         head_repo: get_in(payload, ["head", "repo", "full_name"]),
         body: payload["body"],
         draft: payload["draft"] == true,
         created_at: payload["created_at"],
         updated_at: payload["updated_at"],
         merged_at: payload["merged_at"],
         merge_commit_sha: payload["merge_commit_sha"],
         author: get_in(payload, ["user", "login"]),
         pr_number: number,
         pr_url: payload["html_url"]
       }}
    end
  end

  @doc "Reads explicit worker source and tracker disposition evidence; mentions and titles are not ownership."
  @spec fetch_delivery_observation(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_delivery_observation(id, opts \\ []) do
    tracker = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    with {:ok, settings} <- settings(tracker),
         {:ok, raw} when is_map(raw) <- delivery_issue(settings, request_fun, id),
         true <- to_string(raw["number"]) == id or {:error, :github_wrong_issue},
         {:ok, timeline} <- delivery_timeline(settings, request_fun, id, 1, []),
         {:ok, sources} <- delivery_sources(timeline, settings, request_fun, id) do
      issue = normalize_issue(raw, settings.repo)
      root = Keyword.get(opts, :evidence_root, System.get_env("METALRAIN_SYMPHONY_EVIDENCE_ROOT"))
      reports = report_verifications(raw, timeline, settings, root)

      {:ok,
       %{
         issue: issue,
         closed_at: raw["closed_at"],
         sources: sources,
         report_verifications: reports,
         scope_digest: report_scope_digest([raw["title"], raw["body"]]),
         evidence_source: "github_issue_and_cross_reference"
       }}
    else
      {:ok, _} -> {:error, :github_unknown_payload}
      error -> error
    end
  end

  # Canonical receipts are repository reports, never independent acceptance or billing proof.
  defp report_verifications(raw, timeline, settings, root) do
    number = to_string(raw["number"])
    url = "https://github.com/#{settings.repo}/issues/#{number}"
    closed = Enum.filter(timeline, &(&1["event"] == "closed"))

    references =
      for %{"event" => "commented", "body" => body} <- timeline,
          is_binary(body),
          match <-
            Regex.scan(
              ~r/## Symphony existing-implementation verification\r?\nReviewed current main `([a-f0-9]{40})`\. Retained evidence: `issue-([1-9][0-9]*)\/([a-f0-9]{40})\/([a-f0-9]{32})`\./,
              body
            ),
          do: tl(match)

    with true <- is_binary(root) and raw["html_url"] == url,
         true <- raw["state"] == "closed" and raw["state_reason"] == "completed",
         %{"created_at" => at} <- List.last(closed),
         true <- is_binary(at) and at == raw["closed_at"],
         references <- Enum.reject(Enum.uniq(references), &prior_report_reference?(&1, root, number, timeline)),
         [[sha, ^number, sha, receipt]] <- references,
         {:ok, report} <- read_report(root, number, sha, receipt, url, [raw["title"], raw["body"]]),
         true <- report_after_reopen?(report, timeline) do
      [Map.put(report, :closed_at, at)]
    else
      _ -> []
    end
  end

  defp prior_report_reference?([sha, number, sha, receipt], root, number, timeline) do
    with {:ok, usage} <- report_json(root, ["issue-#{number}", sha, receipt], "review-usage.json"),
         true <- report_worker?(usage, number, sha) do
      not report_after_reopen?(%{reviewed_s: usage["observed_at_epoch"]}, timeline)
    else
      _ -> false
    end
  end

  defp prior_report_reference?(_, _, _, _), do: false

  defp report_after_reopen?(report, timeline) do
    case timeline |> Enum.filter(&(&1["event"] == "reopened")) |> List.last() do
      nil ->
        true

      %{"created_at" => at} ->
        case DateTime.from_iso8601(to_string(at)) do
          {:ok, reopened, _} -> report.reviewed_s >= DateTime.to_unix(reopened, :microsecond) / 1_000_000
          _ -> false
        end

      _ ->
        false
    end
  end

  defp read_report(root, number, sha, receipt, url, scope) do
    parts = ["issue-#{number}", sha, receipt]

    with {:ok, intent} <- report_json(root, parts, "closure-intent.json"),
         {:ok, input} <- report_json(root, parts, "input.json"),
         true <- report_scope?(intent, input, number, sha, url, scope),
         {:ok, acceptance} <- report_bytes(root, parts, "acceptance.md"),
         true <- String.valid?(acceptance) and String.contains?(acceptance, sha),
         {:ok, review} <- report_json(root, parts, "review.json"),
         true <- approved_report_review?(review, sha),
         {:ok, source} <- report_json(root, parts, "delivery-source.json"),
         true <- exact_report_source?(source, sha) and source["clean_after"] == true,
         {:ok, adjudicated} <- report_json(root, parts, "adjudicated-failures.json"),
         true <- report_adjudication?(adjudicated, review, number, sha),
         {:ok, digest} <- report_json(root, parts, "review-input-digest.json"),
         true <- unchanged_report_inputs?(digest),
         {:ok, hosted} <- report_json(root, parts, "hosted-checks.json"),
         true <- completed_report_checks?(hosted),
         {:ok, usage} <- report_json(root, parts, "review-usage.json"),
         true <- report_worker?(usage, number, sha) do
      {:ok,
       %{
         verification_id: receipt,
         scope_digest: report_scope_digest(scope),
         source_sha: sha,
         issue_url: url,
         run_id: usage["parent_run_id"],
         reviewed_s: usage["observed_at_epoch"],
         evidence_source: "canonical_verify_existing_receipts_and_github_closure"
       }}
    else
      _ -> {:error, :incomplete_report_verification}
    end
  end

  defp report_scope?(intent, input, number, sha, url, scope) do
    case input["issue"] do
      %{"number" => issue_number, "html_url" => ^url, "title" => title, "body" => body} ->
        issue_number == String.to_integer(number) and intent["issue"] == issue_number and
          intent["head"] == sha and input["head"] == sha and intent["retirement"] == false and
          intent["scope"] == [title, body] and intent["scope"] == scope

      _ ->
        false
    end
  end

  defp report_scope_digest(scope), do: :crypto.hash(:sha256, Jason.encode!(scope)) |> Base.encode16(case: :lower)

  defp unchanged_report_inputs?(digest) do
    is_binary(digest["before"]) and digest["before"] == digest["after"] and digest["new_own_issue_paths"] == []
  end

  defp report_worker?(usage, number, sha) do
    usage["role"] == "reviewer" and usage["source_sha"] == sha and usage["terminal_event"] == "turn.completed" and
      usage["work_item"] == "GH-#{number}" and is_binary(usage["parent_run_id"]) and is_number(usage["observed_at_epoch"])
  end

  defp approved_report_review?(review, sha) do
    exact_report_source?(review, sha) and review["approved"] == true and
      is_binary(review["summary"]) and String.trim(review["summary"]) != "" and
      review["findings"] == [] and review["missing_evidence"] == [] and is_list(review["preexisting"])
  end

  defp report_adjudication?(%{"failures" => failures} = adjudicated, review, number, sha) when is_list(failures) do
    entries = review["preexisting"]

    exact_report_source?(adjudicated, sha) and length(failures) == length(entries) and
      Enum.all?(Enum.zip(failures, entries), fn {failure, entry} -> reviewed_report_failure?(failure, entry, number) end) and
      length(Enum.uniq_by(failures, &{&1["check"], &1["failure"]})) == length(failures)
  end

  defp report_adjudication?(_, _, _, _), do: false

  defp reviewed_report_failure?(
         %{"check" => check, "failure" => failure, "tracking_issue" => issue, "base_evidence" => path, "classification" => "equivalent-main-failure"},
         %{"check" => check, "failure" => failure, "issue" => issue, "base_evidence" => path},
         number
       ) do
    is_integer(issue) and issue > 0 and issue != String.to_integer(number) and
      is_binary(check) and check != "" and is_binary(failure) and failure != "" and is_binary(path) and path != ""
  end

  defp reviewed_report_failure?(_, _, _), do: false

  defp exact_report_source?(record, sha), do: record["base"] == sha and record["head"] == sha

  defp completed_report_checks?(%{"statuses" => %{"total_count" => count} = statuses, "checks" => checks})
       when is_integer(count) and count >= 0 and is_list(checks) do
    (count == 0 or statuses["state"] == "success") and
      Enum.all?(checks, fn
        %{"status" => "completed", "conclusion" => conclusion} -> conclusion in ["success", "neutral", "skipped"]
        _ -> false
      end)
  end

  defp completed_report_checks?(_), do: false

  defp report_json(root, parts, name) do
    with {:ok, bytes} <- report_bytes(root, parts, name),
         {:ok, %{} = value} <- Jason.decode(bytes) do
      {:ok, value}
    else
      _ -> {:error, :invalid_report_receipt}
    end
  end

  defp report_bytes(root, parts, name) do
    paths = Enum.scan(parts ++ [name], Path.expand(root), &Path.join(&2, &1))

    with true <- Enum.all?(Enum.drop(paths, -1), &match?({:ok, %{type: :directory}}, File.lstat(&1))),
         path = List.last(paths),
         {:ok, %{type: :regular, size: size}} when size <= 131_072 <- File.lstat(path),
         {:ok, bytes} <- File.open(path, [:read, :binary], &IO.binread(&1, 131_073)),
         true <- is_binary(bytes) and byte_size(bytes) <= 131_072 do
      {:ok, bytes}
    else
      _ -> {:error, :report_receipt_unavailable}
    end
  end

  defp delivery_issue(settings, request_fun, id) do
    request_with_settings("GET", repository_issue_path(settings, id), %{}, nil, settings, request_fun, true)
  end

  defp delivery_timeline(settings, request_fun, id, page, acc) do
    path = "#{repository_issue_path(settings, id)}/timeline"

    case request_with_settings("GET", path, %{"per_page" => @page_size, "page" => page}, nil, settings, request_fun, false) do
      {:ok, events} when is_list(events) and length(events) == @page_size ->
        delivery_timeline(settings, request_fun, id, page + 1, acc ++ events)

      {:ok, events} when is_list(events) ->
        {:ok, acc ++ events}

      {:ok, _} ->
        {:error, :github_unknown_payload}

      error ->
        error
    end
  end

  defp delivery_sources(timeline, settings, request_fun, id) do
    timeline
    |> Enum.flat_map(fn event ->
      source = get_in(event, ["source", "issue"]) || %{}

      if event["event"] == "cross-referenced" and is_map(source["pull_request"]) and
           get_in(source, ["repository", "full_name"]) == settings.repo, do: [source["number"]], else: []
    end)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn number, {:ok, acc} ->
      opts = [tracker_settings: %{provider: %{"repo" => settings.repo, "token" => settings.token, "api_url" => settings.api_url}}, request_fun: request_fun]

      case fetch_pull_observation(number, opts) do
        {:ok, source} -> {:cont, {:ok, if(owned_delivery_source?(source, id, settings.repo), do: [source | acc], else: acc)}}
        error -> {:halt, error}
      end
    end)
  end

  defp owned_delivery_source?(source, id, repo) do
    number = Regex.escape(id)
    closes = ~r/^\s*(?:close[sd]?|fix(?:es|ed)?|resolve[sd]?)\s+##{number}\b/im
    declares = ~r/^[\t ]*Symphony issue: ##{number}[\t ]*\r?$/m
    branch = ~r/^(?:(?:crescendo|symphony)\/#{number}-|(?:.*\/)?issue-#{number}(?:-|$))/

    source[:head_repo] == repo and (Regex.match?(closes, source[:body] || "") or Regex.match?(declares, source[:body] || "")) and
      Regex.match?(branch, source[:head_ref] || "")
  end

  @doc false
  @spec fetch_open_pull_requests_for_test(map(), function()) :: {:ok, [map()]} | {:error, term()}
  def fetch_open_pull_requests_for_test(tracker_settings, request_fun) do
    with {:ok, github_settings} <- settings(tracker_settings) do
      do_fetch_pull_pages(github_settings, request_fun, 1, [])
    end
  end

  @spec request(String.t(), String.t(), map(), term(), keyword()) ::
          {:ok, %{status: integer(), body: term()}} | {:error, term()}
  def request(method, path, params, body, opts \\ [])
      when is_binary(method) and is_binary(path) and is_map(params) and is_list(opts) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    with {:ok, github_settings} <- settings(tracker_settings) do
      request_fun.(method, path, params, body, github_settings)
    end
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t()) :: Issue.t() | nil
  def normalize_issue_for_test(issue, repo) when is_map(issue) and is_binary(repo) do
    normalize_issue(issue, repo)
  end

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], map(), function(), map() | nil) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(state_names, tracker_settings, request_fun, pull_policy \\ nil)
      when is_list(state_names) and is_map(tracker_settings) and is_function(request_fun, 5) do
    fetch_issues_by_states(state_names, tracker_settings, request_fun, pull_policy)
  end

  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], map(), function(), map() | nil) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(issue_ids, tracker_settings, request_fun, pull_policy \\ nil)
      when is_list(issue_ids) and is_map(tracker_settings) and is_function(request_fun, 5) do
    fetch_issues_by_ids(issue_ids, tracker_settings, request_fun, pull_policy)
  end

  # Unchanged-input planning requires dependencies for unready issues too.
  defp planning_tracker(config) do
    complete = config.autopilot.enabled and Enum.any?(config.autopilot.channels, fn {_name, task} -> is_map(task) and task["skip_unchanged"] == true end)
    Map.put(config.tracker, :planning_dependencies, complete)
  end

  # Pull requests are work items only when autopilot is enabled. The policy
  # decides which authors are trusted to have their code run and merged.
  defp pull_policy(%{autopilot: %{enabled: true} = autopilot, tracker: tracker}) do
    %{
      trusted_associations: autopilot.trusted_associations,
      trusted_authors: autopilot.trusted_authors,
      required_labels: tracker.required_labels
    }
  end

  defp pull_policy(_config), do: nil

  defp fetch_issues_by_states(state_names, tracker_settings, request_fun, pull_policy) do
    normalized_states = state_names |> Enum.map(&normalize_state/1) |> MapSet.new()

    case github_state_query(normalized_states) do
      nil ->
        {:ok, []}

      state_query ->
        with {:ok, github_settings} <- settings(tracker_settings),
             {:ok, issues} <-
               do_fetch_pages(github_settings, state_query, normalized_states, 1, request_fun, [], pull_policy),
             {:ok, issues} <- attach_open_pull_details(issues, github_settings, request_fun, pull_policy) do
          fetch_dependencies(issues, tracker_settings, github_settings, request_fun)
        end
    end
  end

  defp fetch_issues_by_ids(issue_ids, tracker_settings, request_fun, pull_policy) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, github_settings} <- settings(tracker_settings),
             {:ok, issues} <- fetch_issue_ids(ids, github_settings, request_fun, []),
             {:ok, issues} <- attach_pull_details_by_number(issues, github_settings, request_fun, pull_policy) do
          fetch_dependencies(issues, tracker_settings, github_settings, request_fun)
        end
    end
  end

  defp do_fetch_pages(settings, state_query, requested_states, page, request_fun, acc, pull_policy) do
    params = %{
      "state" => state_query,
      "per_page" => @page_size,
      "page" => page,
      "sort" => "created",
      "direction" => "asc"
    }

    with {:ok, payload} <-
           request_with_settings(
             "GET",
             repository_issues_path(settings),
             params,
             nil,
             settings,
             request_fun,
             false
           ),
         true <- is_list(payload) or {:error, :github_unknown_payload} do
      issues = normalize_state_page(payload, settings.repo, requested_states, not is_nil(pull_policy))
      updated_acc = [issues | acc]

      if length(payload) < @page_size do
        {:ok, updated_acc |> Enum.reverse() |> List.flatten()}
      else
        do_fetch_pages(settings, state_query, requested_states, page + 1, request_fun, updated_acc, pull_policy)
      end
    end
  end

  defp do_fetch_pull_pages(settings, request_fun, page, acc) do
    with {:ok, payload} <- fetch_raw_pull_pages(settings, request_fun, page, acc),
         pulls <- Enum.map(payload, &normalize_pull/1),
         true <- Enum.all?(pulls, &is_map/1) or {:error, :github_unknown_payload} do
      {:ok, pulls}
    end
  end

  defp fetch_raw_pull_pages(settings, request_fun, page, acc) do
    params = %{"state" => "open", "per_page" => @page_size, "page" => page, "sort" => "updated", "direction" => "asc"}

    path = repository_pulls_path(settings)

    with {:ok, payload} <- request_with_settings("GET", path, params, nil, settings, request_fun, false),
         true <- is_list(payload) or {:error, :github_unknown_payload} do
      acc = [payload | acc]

      if length(payload) < @page_size do
        {:ok, acc |> Enum.reverse() |> List.flatten()}
      else
        fetch_raw_pull_pages(settings, request_fun, page + 1, acc)
      end
    end
  end

  # Joins open pull request items with their `/pulls` records, which carry the
  # head commit, draft flag, and fork details that `/issues` lacks.
  defp attach_open_pull_details(issues, _settings, _request_fun, nil), do: {:ok, issues}

  defp attach_open_pull_details(issues, settings, request_fun, pull_policy) do
    if Enum.any?(issues, &open_pull_request?/1) do
      with {:ok, payload} <- fetch_raw_pull_pages(settings, request_fun, 1, []) do
        pulls = Map.new(payload, &{&1["number"], &1})
        {:ok, Enum.map(issues, &attach_pull_detail(&1, pulls, settings.repo, pull_policy))}
      end
    else
      {:ok, issues}
    end
  end

  defp attach_pull_details_by_number(issues, _settings, _request_fun, nil), do: {:ok, issues}

  defp attach_pull_details_by_number(issues, settings, request_fun, pull_policy) do
    Enum.reduce_while(issues, {:ok, []}, fn issue, {:ok, acc} ->
      case refresh_pull_detail(issue, settings, request_fun, pull_policy) do
        {:ok, issue} -> {:cont, {:ok, [issue | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp refresh_pull_detail(issue, settings, request_fun, pull_policy) do
    if open_pull_request?(issue) do
      path = "#{repository_pulls_path(settings)}/#{issue.id}"

      case request_with_settings("GET", path, %{}, nil, settings, request_fun, true) do
        {:ok, %{} = pull} -> {:ok, attach_pull_detail(issue, %{pull["number"] => pull}, settings.repo, pull_policy)}
        {:ok, missing} when missing in [:not_found, :gone] -> {:ok, issue}
        {:ok, _payload} -> {:error, :github_unknown_payload}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, issue}
    end
  end

  defp open_pull_request?(%Issue{kind: :pull_request, state: "open"}), do: true
  defp open_pull_request?(_issue), do: false

  defp attach_pull_detail(%Issue{kind: :pull_request} = issue, pulls, repo, pull_policy) do
    case Map.get(pulls, String.to_integer(issue.id)) do
      %{"head" => %{"sha" => head_sha} = head} = pull when is_binary(head_sha) ->
        head_repo = get_in(head, ["repo", "full_name"])
        author = get_in(pull, ["user", "login"])
        association = pull["author_association"]
        trusted = pull_trusted?(author, association, pull_policy)
        draft = pull["draft"] == true

        detail = %{
          number: pull["number"],
          head_sha: head_sha,
          head_ref: head["ref"],
          head_repo: head_repo,
          base_ref: get_in(pull, ["base", "ref"]),
          draft: draft,
          can_push: head_repo == repo or pull["maintainer_can_modify"] == true,
          author: author,
          author_association: association,
          trusted: trusted
        }

        admitted = trusted or label_opt_in?(issue, pull_policy.required_labels)
        %{issue | pull_request: detail, dispatchable: admitted and not draft, branch_name: head["ref"]}

      _ ->
        issue
    end
  end

  defp attach_pull_detail(issue, _pulls, _repo, _pull_policy), do: issue

  defp pull_trusted?(author, association, pull_policy) do
    (is_binary(association) and String.upcase(association) in pull_policy.trusted_associations) or
      (is_binary(author) and String.downcase(author) in pull_policy.trusted_authors)
  end

  # A maintainer opts an untrusted pull request in by adding every required
  # label; with no required labels configured there is no label opt-in.
  defp label_opt_in?(_issue, []), do: false
  defp label_opt_in?(issue, required_labels), do: Issue.has_required_labels?(issue, required_labels)

  defp status_ci_state(%{"total_count" => 0}), do: "none"
  defp status_ci_state(%{"state" => state}) when state in ["success", "pending"], do: state
  defp status_ci_state(%{"state" => _state}), do: "failure"
  defp status_ci_state(_status), do: "none"

  defp check_run_ci_state(%{"status" => "completed", "conclusion" => conclusion})
       when conclusion in ["success", "neutral", "skipped"],
       do: "success"

  defp check_run_ci_state(%{"status" => "completed"}), do: "failure"
  defp check_run_ci_state(_check_run), do: "pending"

  defp combine_ci_states(states) do
    Enum.find(["pending", "failure", "success"], "none", &(&1 in states))
  end

  defp normalize_pull(%{"number" => number, "title" => title, "html_url" => url, "draft" => draft, "updated_at" => updated_at})
       when is_integer(number) and number > 0 and is_binary(title) and is_binary(url) and is_boolean(draft) do
    %{number: number, title: title, url: url, draft: draft, updated_at: updated_at}
  end

  defp normalize_pull(_), do: nil

  defp fetch_issue_ids([], _settings, _request_fun, acc), do: {:ok, Enum.reverse(acc)}

  defp fetch_issue_ids([id | rest], settings, request_fun, acc) do
    with {:ok, issue_number} <- parse_issue_number(id),
         {:ok, payload} <-
           request_with_settings(
             "GET",
             repository_issue_path(settings, issue_number),
             %{},
             nil,
             settings,
             request_fun,
             true
           ) do
      case payload do
        :gone -> fetch_issue_ids(rest, settings, request_fun, [deleted_issue(issue_number, settings.repo) | acc])
        payload -> continue_issue_id_fetch(payload, rest, settings, request_fun, acc)
      end
    end
  end

  # GitHub answers 410 for an issue deleted outside Symphony. It can never come
  # back, so it is reported as closed: reconciliation then stops its worker and
  # cleans its workspace, where a 404 (hidden or transferred) only stops it.
  defp deleted_issue(issue_number, repo) do
    %Issue{
      id: Integer.to_string(issue_number),
      identifier: "GH-#{issue_number}",
      native_ref: %{"number" => issue_number, "repo" => repo},
      title: "Deleted on GitHub",
      state: "closed",
      dispatchable: false
    }
  end

  defp continue_issue_id_fetch(:not_found, rest, settings, request_fun, acc) do
    fetch_issue_ids(rest, settings, request_fun, acc)
  end

  defp continue_issue_id_fetch(%{} = raw_issue, rest, settings, request_fun, acc) do
    case normalize_issue(raw_issue, settings.repo) do
      %Issue{} = issue -> fetch_issue_ids(rest, settings, request_fun, [issue | acc])
      nil -> {:error, :github_unknown_payload}
    end
  end

  defp continue_issue_id_fetch(_payload, _rest, _settings, _request_fun, _acc) do
    {:error, :github_unknown_payload}
  end

  defp normalize_state_page(payload, repo, requested_states, include_pulls) do
    issues =
      payload
      |> Enum.reject(&(not include_pulls and is_map(&1) and Map.has_key?(&1, "pull_request")))
      |> Enum.map(&normalize_issue(&1, repo))

    malformed_count = Enum.count(issues, &is_nil/1)

    if malformed_count > 0 do
      Logger.warning("Dropping malformed GitHub issue records count=#{malformed_count}")
    end

    issues
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&MapSet.member?(requested_states, normalize_state(&1.state)))
  end

  defp normalize_issue(issue, repo) when is_map(issue) and is_binary(repo) do
    issue_number = issue["number"]
    state = issue["state"]

    pull_request? = Map.has_key?(issue, "pull_request")

    if is_integer(issue_number) and issue_number > 0 and
         Enum.all?([issue["title"], state], &present_string?/1) do
      %Issue{
        id: Integer.to_string(issue_number),
        kind: if(pull_request?, do: :pull_request, else: :issue),
        native_ref: native_ref(issue, repo),
        identifier: if(pull_request?, do: "PR-#{issue_number}", else: "GH-#{issue_number}"),
        title: issue["title"],
        description: issue["body"],
        state: state,
        state_reason: issue["state_reason"],
        url: issue["html_url"],
        assignee_id: get_in(issue, ["assignee", "login"]),
        labels: extract_labels(issue),
        blocked_by: [],
        # Pull requests become dispatchable only once their details are attached.
        dispatchable: not pull_request?,
        created_at: parse_datetime(issue["created_at"]),
        updated_at: parse_datetime(issue["updated_at"])
      }
    end
  end

  defp normalize_issue(_issue, _repo), do: nil

  defp fetch_dependencies(issues, tracker_settings, settings, request_fun) do
    required_labels = Map.get(tracker_settings, :required_labels, [])
    settings = settings |> Map.put(:excluded_labels, Map.get(tracker_settings, :excluded_labels, [])) |> Map.put(:planning_dependencies, Map.get(tracker_settings, :planning_dependencies) == true)

    Enum.reduce_while(issues, {:ok, []}, fn issue, {:ok, acc} ->
      case fetch_dependencies_for_issue(issue, required_labels, settings, request_fun) do
        {:ok, updated_issue} -> {:cont, {:ok, [updated_issue | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp fetch_dependencies_for_issue(issue, required_labels, settings, request_fun) do
    if issue.kind == :issue and (settings.planning_dependencies or Issue.routable?(issue, required_labels)) and issue.state == "open" do
      with {:ok, blockers} <- fetch_blockers(settings, issue.id, request_fun, 1, []) do
        dispatchable = Enum.all?(blockers, &satisfied_blocker?/1)
        admit_handoff(%{issue | blocked_by: blockers, dispatchable: dispatchable}, settings, request_fun)
      end
    else
      {:ok, issue}
    end
  end

  # Admission only reads tracker evidence. It never rewrites dependencies, closes
  # successors or touches their PRs; the worker/groomer preserves the disposition.
  defp admit_handoff(issue, settings, request_fun) do
    case Handoff.record(issue) do
      nil ->
        {:ok, issue}

      :invalid ->
        {:ok, %{issue | dispatchable: false}}

      %{"owner" => owner} = record ->
        if Integer.to_string(owner) == issue.id, do: {:ok, issue}, else: verify_handoff(issue, record, settings, request_fun)
    end
  end

  defp verify_handoff(issue, record, settings, request_fun) do
    owner = record["owner"]

    with {:ok, %{"state" => "closed"} = raw_owner} <-
           request_with_settings("GET", repository_issue_path(settings, owner), %{}, nil, settings, request_fun, true),
         %Issue{} = canonical <- normalize_issue(raw_owner, settings.repo),
         ^record <- Handoff.record(canonical),
         nil <- Issue.excluded_label(canonical, settings.excluded_labels),
         {:ok, blockers} <- fetch_blockers(settings, Integer.to_string(owner), request_fun, 1, []),
         true <- dependencies_preserved?(blockers, issue.blocked_by),
         true <- valid_handoff_evidence?(record, raw_owner, blockers, settings, request_fun) do
      {:ok, %{issue | delivery_key: Handoff.budget_key(record)}}
    else
      _ -> {:ok, %{issue | dispatchable: false}}
    end
  end

  defp valid_handoff_evidence?(%{"change" => "partial_delivery", "owner" => owner, "evidence" => number}, raw_owner, _blockers, settings, request_fun) do
    path = "#{repository_pulls_path(settings)}/#{number}"
    reference = ~r/^\s*(?:close[sd]?|fix(?:es|ed)?|resolve[sd]?)\s+##{owner}\b/im

    case request_with_settings("GET", path, %{}, nil, settings, request_fun, true) do
      {:ok, %{"merged_at" => at, "body" => body}} when is_binary(at) and is_binary(body) ->
        Regex.match?(reference, body) and later?(at, raw_owner["created_at"])

      _ ->
        false
    end
  end

  defp valid_handoff_evidence?(%{"change" => "prerequisite", "evidence" => number}, raw_owner, blockers, settings, request_fun) do
    case request_with_settings("GET", repository_issue_path(settings, number), %{}, nil, settings, request_fun, true) do
      {:ok, %{"id" => id, "state" => "closed", "state_reason" => "completed", "closed_at" => at}} ->
        Enum.any?(blockers, &(&1.id == to_string(id) and &1.identifier == "GH-#{number}")) and later?(at, raw_owner["closed_at"])

      _ ->
        false
    end
  end

  defp dependencies_preserved?(canonical, successor) do
    Enum.all?(canonical, fn blocker ->
      satisfied_blocker?(blocker) or Enum.any?(successor, &(&1.id == blocker.id))
    end)
  end

  defp later?(at, baseline) do
    with %DateTime{} = at <- parse_datetime(at),
         %DateTime{} = baseline <- parse_datetime(baseline) do
      DateTime.compare(at, baseline) == :gt
    else
      _ -> false
    end
  end

  defp fetch_blockers(settings, issue_id, request_fun, page, acc) do
    path = "#{repository_issue_path(settings, issue_id)}/dependencies/blocked_by"
    params = %{"per_page" => @page_size, "page" => page}

    with {:ok, payload} <- request_with_settings("GET", path, params, nil, settings, request_fun, false),
         true <- is_list(payload) or {:error, :github_unknown_payload},
         {:ok, blockers} <- normalize_blockers(payload, settings[:planning_dependencies] == true) do
      acc = [blockers | acc]

      if length(payload) < @page_size do
        {:ok, acc |> Enum.reverse() |> List.flatten()}
      else
        fetch_blockers(settings, issue_id, request_fun, page + 1, acc)
      end
    end
  end

  defp normalize_blockers(payload, planning?) do
    blockers =
      Enum.map(payload, fn
        %{"id" => id, "number" => number, "state" => state} = blocker
        when is_integer(id) and is_integer(number) and number > 0 and state in ["open", "closed"] ->
          value = %{id: Integer.to_string(id), identifier: "GH-#{number}", state: state, state_reason: blocker["state_reason"]}
          if planning?, do: Map.put(value, :planning, Map.take(blocker, ~w(title body labels updated_at))), else: value

        _ ->
          nil
      end)

    if Enum.any?(blockers, &is_nil/1), do: {:error, :github_unknown_payload}, else: {:ok, blockers}
  end

  defp satisfied_blocker?(%{state: "closed", state_reason: reason}), do: reason != "not_planned"
  defp satisfied_blocker?(_), do: false

  defp native_ref(issue, repo) do
    %{
      "id" => issue["id"],
      "node_id" => issue["node_id"],
      "number" => issue["number"],
      "repo" => repo
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> case do
      empty when map_size(empty) == 0 -> nil
      ref -> ref
    end
  end

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _ -> []
    end)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_labels(_issue), do: []

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp request_with_settings(method, path, params, body, settings, request_fun, allow_not_found) do
    case request_fun.(method, path, params, body, settings) do
      {:ok, %{status: status, body: payload}} when status in 200..299 ->
        {:ok, payload}

      {:ok, %{status: 404}} when allow_not_found ->
        {:ok, :not_found}

      {:ok, %{status: 410}} when allow_not_found ->
        {:ok, :gone}

      {:ok, %{status: status}} when is_integer(status) ->
        Logger.error("GitHub API request failed status=#{status} method=#{method} path=#{path}")
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :github_unknown_payload}
    end
  end

  # GETs are conditional (see ETagCache): unchanged resources answer 304,
  # which GitHub does not count against the rate limit.
  defp perform_request(method, path, params, body, settings) do
    with {:ok, request_method} <- request_method(method) do
      url = settings.api_url <> path
      cache_key = if request_method == :get, do: ETagCache.key(url, params, settings.token)
      conditional = if cache_key, do: ETagCache.headers(cache_key), else: []

      request_opts = [
        method: request_method,
        url: url,
        headers: github_headers(settings.token) ++ conditional,
        params: params,
        connect_options: [timeout: 30_000]
      ]

      request_opts = if is_nil(body), do: request_opts, else: Keyword.put(request_opts, :json, body)

      case Req.request(request_opts) do
        {:ok, response} when is_tuple(cache_key) -> {:ok, ETagCache.resolve(cache_key, Map.take(response, [:status, :headers, :body]))}
        {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
        {:error, reason} -> {:error, {:github_api_request, reason}}
      end
    end
  end

  defp settings(tracker_settings) when is_map(tracker_settings) do
    provider = provider_settings(tracker_settings)
    api_url = provider["api_url"] || @default_api_url
    repo = resolve_setting(provider["repo"], System.get_env("GITHUB_REPO"))
    token = resolve_setting(provider["token"], System.get_env("GITHUB_TOKEN"))

    cond do
      not valid_api_url?(api_url) -> {:error, :invalid_github_api_url}
      not present_string?(repo) -> {:error, :missing_github_repo}
      not valid_repo?(repo) -> {:error, :invalid_github_repo}
      not present_string?(token) -> {:error, :missing_github_token}
      true -> {:ok, %{api_url: String.trim_trailing(api_url, "/"), repo: repo, token: token}}
    end
  end

  defp provider_settings(%{provider: provider}) when is_map(provider), do: provider
  defp provider_settings(_tracker_settings), do: %{}

  defp resolve_setting(nil, fallback), do: normalize_string(fallback)

  defp resolve_setting("$" <> env_name, fallback) do
    if valid_env_name?(env_name) do
      normalize_string(System.get_env(env_name) || fallback)
    else
      nil
    end
  end

  defp resolve_setting(value, _fallback), do: normalize_string(value)

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp env_reference_names(values) do
    Enum.flat_map(values, fn
      "$" <> env_name when is_binary(env_name) -> if valid_env_name?(env_name), do: [env_name], else: []
      _ -> []
    end)
  end

  defp valid_env_name?(name), do: String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp valid_api_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) -> true
      _ -> false
    end
  end

  defp valid_api_url?(_value), do: false
  defp valid_repo?(repo) when is_binary(repo), do: String.match?(repo, ~r/^[^\s\/]+\/[^\s\/]+$/)
  defp valid_repo?(_repo), do: false

  defp repository_issues_path(settings), do: "/repos/#{encoded_repo(settings.repo)}/issues"
  defp repository_pulls_path(settings), do: "/repos/#{encoded_repo(settings.repo)}/pulls"

  defp repository_issue_path(settings, issue_number),
    do: "#{repository_issues_path(settings)}/#{issue_number}"

  defp encoded_repo(repo) do
    repo
    |> String.split("/", parts: 2)
    |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
  end

  defp github_headers(token) do
    [
      {"Accept", "application/vnd.github+json"},
      {"Authorization", "Bearer #{token}"},
      {"X-GitHub-Api-Version", @api_version},
      {"User-Agent", @user_agent}
    ]
  end

  defp github_state_query(states) do
    has_open? = MapSet.member?(states, "open")
    has_closed? = MapSet.member?(states, "closed")

    cond do
      has_open? and has_closed? -> "all"
      has_open? -> "open"
      has_closed? -> "closed"
      true -> nil
    end
  end

  defp parse_issue_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_github_issue_id}
    end
  end

  defp parse_issue_number(_value), do: {:error, :invalid_github_issue_id}

  defp request_method("GET"), do: {:ok, :get}
  defp request_method("POST"), do: {:ok, :post}
  defp request_method("PATCH"), do: {:ok, :patch}
  defp request_method("PUT"), do: {:ok, :put}
  defp request_method("DELETE"), do: {:ok, :delete}
  defp request_method(_method), do: {:error, :invalid_github_method}

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_value), do: ""

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
