defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Thin GitHub REST client for repository issue polling.
  """

  require Logger
  alias SymphonyElixir.Config
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
    fetch_issues_by_states(state_names, config.tracker, &perform_request/5, pull_policy(config))
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) when is_list(issue_ids) do
    config = Config.settings!()
    fetch_issues_by_ids(issue_ids, config.tracker, &perform_request/5, pull_policy(config))
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
  # close every open draft that references the issue or uses its branch.
  defp close_draft_pulls(_settings, _request_fun, %Issue{kind: :pull_request}), do: :ok

  defp close_draft_pulls(settings, request_fun, %Issue{id: id}) do
    reference = ~r/#{Regex.escape("#" <> id)}\b|issue-#{Regex.escape(id)}\b/
    reason = "Closed by Symphony: issue ##{id} was retired after exhausting its attempts."

    with {:ok, pulls} <- fetch_raw_pull_pages(settings, request_fun, 1, []) do
      pulls
      |> Enum.filter(&draft_for_issue?(&1, reference))
      |> Enum.reduce_while(:ok, &close_pull(&1, &2, settings, request_fun, reason))
    end
  end

  defp draft_for_issue?(pull, reference) do
    pull["draft"] == true and
      (Regex.match?(reference, pull["body"] || "") or Regex.match?(reference, get_in(pull, ["head", "ref"]) || ""))
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
    if issue.kind == :issue and Issue.routable?(issue, required_labels) and issue.state == "open" do
      with {:ok, blockers} <- fetch_blockers(settings, issue.id, request_fun, 1, []) do
        dispatchable = Enum.all?(blockers, &satisfied_blocker?/1)
        {:ok, %{issue | blocked_by: blockers, dispatchable: dispatchable}}
      end
    else
      {:ok, issue}
    end
  end

  defp fetch_blockers(settings, issue_id, request_fun, page, acc) do
    path = "#{repository_issue_path(settings, issue_id)}/dependencies/blocked_by"
    params = %{"per_page" => @page_size, "page" => page}

    with {:ok, payload} <- request_with_settings("GET", path, params, nil, settings, request_fun, false),
         true <- is_list(payload) or {:error, :github_unknown_payload},
         {:ok, blockers} <- normalize_blockers(payload) do
      acc = [blockers | acc]

      if length(payload) < @page_size do
        {:ok, acc |> Enum.reverse() |> List.flatten()}
      else
        fetch_blockers(settings, issue_id, request_fun, page + 1, acc)
      end
    end
  end

  defp normalize_blockers(payload) do
    blockers =
      Enum.map(payload, fn
        %{"id" => id, "number" => number, "state" => state} = blocker
        when is_integer(id) and is_integer(number) and number > 0 and state in ["open", "closed"] ->
          %{id: Integer.to_string(id), identifier: "GH-#{number}", state: state, state_reason: blocker["state_reason"]}

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

  defp perform_request(method, path, params, body, settings) do
    with {:ok, request_method} <- request_method(method) do
      request_opts = [
        method: request_method,
        url: settings.api_url <> path,
        headers: github_headers(settings.token),
        params: params,
        connect_options: [timeout: 30_000]
      ]

      request_opts = if is_nil(body), do: request_opts, else: Keyword.put(request_opts, :json, body)

      case Req.request(request_opts) do
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
