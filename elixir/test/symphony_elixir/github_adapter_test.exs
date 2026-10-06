defmodule SymphonyElixir.GitHub.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Adapter, as: GitHubAdapter
  alias SymphonyElixir.GitHub.AgentTool, as: GitHubAgentTool
  alias SymphonyElixir.GitHub.Client, as: GitHubClient

  defmodule FakeGitHubClient do
    def fetch_issues_by_states(states) do
      send(self(), {:github_states_called, states})
      {:ok, states}
    end

    def fetch_issues_by_ids(ids) do
      send(self(), {:github_ids_called, ids})
      {:ok, ids}
    end

    def clear_label(issue, label) do
      send(self(), {:github_clear_label, issue.id, label})
      :ok
    end

    def retire(issue, reason) do
      send(self(), {:github_retire, issue.id, reason})
      :ok
    end
  end

  defmodule InventoryGitHubClient do
    def fetch_issues_by_states(_states) do
      {:ok,
       [
         %SymphonyElixir.Tracker.Issue{
           id: "42",
           identifier: "GH-42",
           title: "Blocked water",
           state: "open",
           labels: ["symphony:portfolio", "symphony:needs-attention"],
           dispatchable: true,
           created_at: ~U[2026-09-01 00:00:00Z]
         }
       ]}
    end

    def fetch_issues_by_ids(_ids), do: {:ok, []}

    def fetch_open_pull_requests do
      {:ok, [%{number: 12, title: "Finish water", url: "https://github.test/pull/12", draft: true, updated_at: "2026-09-01T00:00:00Z"}]}
    end
  end

  setup do
    github_client_module = Application.get_env(:symphony_elixir, :github_client_module)

    on_exit(fn ->
      if is_nil(github_client_module) do
        Application.delete_env(:symphony_elixir, :github_client_module)
      else
        Application.put_env(:symphony_elixir, :github_client_module, github_client_module)
      end
    end)

    :ok
  end

  test "adapter validates GitHub config, delegates reads, and advertises github_api" do
    settings = tracker_settings()

    assert :ok = GitHubAdapter.validate_config(settings)

    assert {:error, :missing_github_active_states} =
             GitHubAdapter.validate_config(%{settings | active_states: nil})

    assert {:error, :missing_github_terminal_states} =
             GitHubAdapter.validate_config(%{settings | terminal_states: nil})

    assert :ok = GitHubAdapter.validate_config(%{settings | active_states: [], terminal_states: []})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | active_states: ["Todo"]})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | active_states: [42]})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | active_states: ["closed"]})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | terminal_states: ["open"]})

    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)

    assert {:ok, ["open"]} = GitHubAdapter.fetch_issues_by_states(["open"])
    assert_receive {:github_states_called, ["open"]}

    assert {:ok, ["42"]} = GitHubAdapter.fetch_issues_by_ids(["42"])
    assert_receive {:github_ids_called, ["42"]}

    assert :ok = GitHubAdapter.clear_label(%SymphonyElixir.Tracker.Issue{id: "42"}, "symphony:blocked")
    assert_receive {:github_clear_label, "42", "symphony:blocked"}
    assert :ok = GitHubAdapter.retire(%SymphonyElixir.Tracker.Issue{id: "42"}, "why")
    assert_receive {:github_retire, "42", "why"}

    assert [%{"name" => "github_api"}] = GitHubAdapter.agent_tool_specs()

    assert GitHubAdapter.execute_agent_tool(
             "github_api",
             %{"method" => "GET", "path" => "/user"},
             github_client: fn _method, _path, _params, _body, _opts ->
               {:ok, %{status: 200, body: %{"login" => "octocat"}}}
             end
           )["success"]
  end

  test "client validates repository settings and declares token environments" do
    assert :ok = GitHubClient.validate_settings(tracker_settings())

    assert {:error, :missing_github_repo} =
             GitHubClient.validate_settings(tracker_settings(%{"repo" => 123}))

    assert {:error, :invalid_github_repo} =
             GitHubClient.validate_settings(tracker_settings(%{"repo" => "not-a-repo"}))

    assert {:error, :missing_github_token} =
             GitHubClient.validate_settings(tracker_settings(%{"token" => 123}))

    assert {:error, :invalid_github_api_url} =
             GitHubClient.validate_settings(tracker_settings(%{"api_url" => "not a url"}))

    assert {:error, :invalid_github_api_url} =
             GitHubClient.validate_settings(tracker_settings(%{"api_url" => "http://api.github.com"}))

    assert GitHubClient.secret_environment_names(tracker_settings(%{"token" => "$SYMPHONY_GITHUB_TOKEN"})) == [
             "GITHUB_TOKEN",
             "GH_TOKEN",
             "GITHUB_ENTERPRISE_TOKEN",
             "GH_ENTERPRISE_TOKEN",
             "SYMPHONY_GITHUB_TOKEN"
           ]
  end

  test "client normalizes GitHub issues without dropping provider details" do
    issue = GitHubClient.normalize_issue_for_test(raw_issue(42), "octo/repo")

    assert issue.id == "42"
    assert issue.identifier == "GH-42"

    assert issue.native_ref == %{
             "id" => 1_042,
             "node_id" => "I_42",
             "number" => 42,
             "repo" => "octo/repo"
           }

    assert issue.title == "Issue 42"
    assert issue.description == "Body 42"
    assert issue.state == "open"
    closed = GitHubClient.normalize_issue_for_test(Map.merge(raw_issue(42), %{"state" => "closed", "state_reason" => "not_planned"}), "octo/repo")
    assert closed.state_reason == "not_planned"
    assert issue.url == "https://github.test/octo/repo/issues/42"
    assert issue.assignee_id == "octocat"
    assert issue.labels == ["bug", "platform"]
    assert issue.blocked_by == []
    assert issue.dispatchable
    assert %DateTime{} = issue.created_at
    assert %DateTime{} = issue.updated_at

    refute GitHubClient.normalize_issue_for_test(
             Map.put(raw_issue(43), "pull_request", %{"url" => "https://api.github.test/pulls/43"}),
             "octo/repo"
           ).dispatchable

    assert GitHubClient.normalize_issue_for_test(
             Map.put(raw_issue(44), "title", " "),
             "octo/repo"
           ) == nil
  end

  test "client pages state reads, filters requested states, and drops malformed records" do
    first_page =
      Enum.map(1..97, &raw_issue/1) ++
        [
          Map.put(raw_issue(98), "pull_request", %{"url" => "https://api.github.test/pulls/98"}),
          Map.put(raw_issue(99), "state", "closed"),
          Map.put(raw_issue(100), "title", "")
        ]

    request_fun = fn "GET", "/repos/octo/repo/issues", params, nil, settings ->
      send(self(), {:github_page, params, settings})

      body =
        case params["page"] do
          1 -> first_page
          2 -> [raw_issue(101)]
        end

      {:ok, %{status: 200, body: body}}
    end

    log =
      capture_log(fn ->
        assert {:ok, issues} =
                 GitHubClient.fetch_issues_by_states_for_test(
                   [" OPEN "],
                   tracker_settings(),
                   request_fun
                 )

        assert length(issues) == 98
        assert hd(issues).id == "1"
        assert List.last(issues).id == "101"
        refute Enum.any?(issues, &(&1.id == "99"))
        refute Enum.any?(issues, &(&1.id == "98"))
      end)

    assert log =~ "Dropping malformed GitHub issue records count=1"

    assert_receive {:github_page,
                    %{
                      "state" => "open",
                      "per_page" => 100,
                      "page" => 1,
                      "sort" => "created",
                      "direction" => "asc"
                    }, %{repo: "octo/repo"}}

    assert_receive {:github_page, %{"page" => 2}, %{repo: "octo/repo"}}

    assert {:ok, []} =
             GitHubClient.fetch_issues_by_states_for_test(
               ["In Progress"],
               tracker_settings(),
               fn _method, _path, _params, _body, _settings ->
                 flunk("unsupported GitHub states should not make an HTTP request")
               end
             )
  end

  test "client reads the open pull request inventory in update order" do
    request_fun = fn "GET", "/repos/octo/repo/pulls", params, nil, _settings ->
      send(self(), {:pull_params, params})

      {:ok,
       %{
         status: 200,
         body: [
           %{"number" => 12, "title" => "Finish water", "html_url" => "https://github.test/pull/12", "draft" => true, "updated_at" => "2026-09-01T00:00:00Z"}
         ]
       }}
    end

    assert {:ok, [%{number: 12, draft: true}]} =
             GitHubClient.fetch_open_pull_requests_for_test(tracker_settings(), request_fun)

    assert_receive {:pull_params, %{"state" => "open", "sort" => "updated", "direction" => "asc"}}
  end

  test "client refreshes numeric IDs in order, omits 404s, and rejects malformed refreshes" do
    request_fun = fn "GET", path, %{}, nil, _settings ->
      send(self(), {:github_id_path, path})

      case path do
        "/repos/octo/repo/issues/2" -> {:ok, %{status: 200, body: raw_issue(2)}}
        "/repos/octo/repo/issues/1" -> {:ok, %{status: 200, body: raw_issue(1)}}
        "/repos/octo/repo/issues/404" -> {:ok, %{status: 404, body: %{"message" => "Not Found"}}}
      end
    end

    assert {:ok, issues} =
             GitHubClient.fetch_issues_by_ids_for_test(
               ["2", "1", "404", "2"],
               tracker_settings(),
               request_fun
             )

    assert Enum.map(issues, & &1.id) == ["2", "1"]
    assert_receive {:github_id_path, "/repos/octo/repo/issues/2"}
    assert_receive {:github_id_path, "/repos/octo/repo/issues/1"}
    assert_receive {:github_id_path, "/repos/octo/repo/issues/404"}
    refute_receive {:github_id_path, "/repos/octo/repo/issues/2"}

    assert {:error, :invalid_github_issue_id} =
             GitHubClient.fetch_issues_by_ids_for_test(
               ["not-a-number"],
               tracker_settings(),
               request_fun
             )

    assert {:error, :github_unknown_payload} =
             GitHubClient.fetch_issues_by_ids_for_test(
               ["3"],
               tracker_settings(),
               fn _method, _path, _params, _body, _settings ->
                 {:ok, %{status: 200, body: Map.put(raw_issue(3), "title", "")}}
               end
             )
  end

  test "client clears labels and retires only an item's owned draft pull requests" do
    parent = self()

    request_fun = fn method, path, _params, body, _settings ->
      send(parent, {:github_write, method, path, body})

      case {method, path} do
        {"GET", "/repos/octo/repo/pulls"} ->
          {:ok,
           %{
             status: 200,
             body: [
               raw_pull(20, "OWNER", "octo/repo", %{"draft" => true, "body" => "Symphony issue: #5"}),
               raw_pull(21, "OWNER", "octo/repo", %{"draft" => true, "body" => "Unrelated #50", "head" => %{"sha" => "s", "ref" => "symphony/issue-5", "repo" => %{"full_name" => "octo/repo"}}}),
               raw_pull(22, "OWNER", "octo/repo", %{"draft" => false, "body" => "Closes #5"}),
               raw_pull(23, "OWNER", "octo/repo", %{"draft" => true, "body" => "Fixes #50"}),
               raw_pull(24, "OWNER", "octo/repo", %{
                 "draft" => true,
                 "body" => "Required validation failure tracked in #5.\n\nSymphony issue: #4",
                 "head" => %{"ref" => "symphony/issue-4"}
               }),
               raw_pull(25, "OWNER", "octo/repo", %{"draft" => true, "body" => "Retain issue-5 findings"}),
               raw_pull(26, "OWNER", "octo/repo", %{"draft" => true, "body" => "Closes #5"}),
               raw_pull(27, "OWNER", "octo/repo", %{"draft" => true, "body" => "fixes #5"}),
               raw_pull(28, "OWNER", "octo/repo", %{"draft" => true, "body" => "Resolved #5"}),
               raw_pull(29, "OWNER", "octo/repo", %{"draft" => true, "body" => "Crescendo issue: #5"}),
               raw_pull(30, "OWNER", "octo/repo", %{
                 "draft" => true,
                 "body" => "#5 is a dependency",
                 "head" => %{"ref" => "symphony/issue-50"}
               }),
               raw_pull(31, "OWNER", "octo/repo", %{"draft" => true, "body" => "Will not close #5"})
             ]
           }}

        {"DELETE", _} ->
          {:ok, %{status: 404, body: %{}}}

        _ ->
          {:ok, %{status: 200, body: %{}}}
      end
    end

    assert :ok = GitHubClient.clear_label_for_test(%Issue{id: "5"}, "symphony:blocked", tracker_settings(), request_fun)
    assert_receive {:github_write, "DELETE", "/repos/octo/repo/issues/5/labels/symphony%3Ablocked", nil}

    assert :ok = GitHubClient.retire_for_test(%Issue{id: "5", kind: :issue}, "Retired.", tracker_settings(), request_fun)
    assert_receive {:github_write, "POST", "/repos/octo/repo/issues/5/comments", %{"body" => "Retired."}}
    assert_receive {:github_write, "PATCH", "/repos/octo/repo/issues/5", %{"state" => "closed", "state_reason" => "not_planned"}}
    assert_receive {:github_write, "PATCH", "/repos/octo/repo/pulls/20", %{"state" => "closed"}}
    assert_receive {:github_write, "PATCH", "/repos/octo/repo/pulls/21", %{"state" => "closed"}}
    assert_receive {:github_write, "PATCH", "/repos/octo/repo/pulls/26", %{"state" => "closed"}}
    assert_receive {:github_write, "PATCH", "/repos/octo/repo/pulls/27", %{"state" => "closed"}}
    assert_receive {:github_write, "PATCH", "/repos/octo/repo/pulls/28", %{"state" => "closed"}}
    assert_receive {:github_write, "PATCH", "/repos/octo/repo/pulls/29", %{"state" => "closed"}}
    refute_receive {:github_write, "PATCH", "/repos/octo/repo/pulls/22", _}
    refute_receive {:github_write, "PATCH", "/repos/octo/repo/pulls/23", _}
    refute_receive {:github_write, "PATCH", "/repos/octo/repo/pulls/24", _}
    refute_receive {:github_write, "PATCH", "/repos/octo/repo/pulls/25", _}
    refute_receive {:github_write, "PATCH", "/repos/octo/repo/pulls/30", _}
    refute_receive {:github_write, "PATCH", "/repos/octo/repo/pulls/31", _}

    assert :ok = GitHubClient.retire_for_test(%Issue{id: "22", kind: :pull_request}, "Capped.", tracker_settings(), request_fun)
    assert_receive {:github_write, "PATCH", "/repos/octo/repo/pulls/22", %{"state" => "closed"}}

    failing = fn _method, _path, _params, _body, _settings -> {:ok, %{status: 500, body: %{}}} end
    retired = %Issue{id: "5", kind: :issue}
    assert {:error, {:github_api_status, 500}} = GitHubClient.retire_for_test(retired, "x", tracker_settings(), failing)
  end

  test "client reports externally deleted issues as closed so reconciliation retires them" do
    request_fun = fn "GET", path, %{}, nil, _settings ->
      case path do
        "/repos/octo/repo/issues/5" -> {:ok, %{status: 410, body: %{"message" => "This issue was deleted"}}}
        "/repos/octo/repo/issues/6" -> {:ok, %{status: 200, body: raw_issue(6)}}
        "/repos/octo/repo/issues/7" -> {:ok, %{status: 200, body: raw_pull_issue(7, [])}}
        "/repos/octo/repo/pulls/7" -> {:ok, %{status: 410, body: %{}}}
      end
    end

    assert {:ok, [deleted, live]} = GitHubClient.fetch_issues_by_ids_for_test(["5", "6"], tracker_settings(), request_fun)
    assert %Issue{id: "5", identifier: "GH-5", state: "closed", dispatchable: false, title: "Deleted on GitHub"} = deleted
    assert live.id == "6"

    assert {:ok, [%Issue{kind: :pull_request, pull_request: nil, dispatchable: false}]} =
             GitHubClient.fetch_issues_by_ids_for_test(["7"], tracker_settings(), request_fun, pull_policy())
  end

  test "ready issues wait for native dependencies, including dependencies added before dispatch" do
    issue = Map.put(raw_issue(42), "labels", [%{"name" => "symphony:ready"}])

    requests = fn "GET", path, _params, nil, _settings ->
      case path do
        "/repos/octo/repo/issues" ->
          {:ok, %{status: 200, body: [issue]}}

        "/repos/octo/repo/issues/42" ->
          {:ok, %{status: 200, body: issue}}

        "/repos/octo/repo/issues/42/dependencies/blocked_by" ->
          send(self(), :dependency_read)
          {:ok, %{status: 200, body: [%{"id" => 7, "number" => 7, "state" => "open"}]}}
      end
    end

    assert {:ok, [candidate]} =
             GitHubClient.fetch_issues_by_states_for_test(["open"], tracker_settings(), requests)

    refute candidate.dispatchable
    assert candidate.blocked_by == [%{id: "7", identifier: "GH-7", state: "open", state_reason: nil}]
    assert_receive :dependency_read

    assert {:ok, [refreshed]} =
             GitHubClient.fetch_issues_by_ids_for_test(["42"], tracker_settings(), requests)

    refute refreshed.dispatchable
    assert_receive :dependency_read
  end

  test "dependency reads fail closed and not-planned closures do not unblock work" do
    issue = Map.put(raw_issue(42), "labels", [%{"name" => "symphony:ready"}])

    requests = fn "GET", path, _params, nil, _settings ->
      case path do
        "/repos/octo/repo/issues/42" ->
          {:ok, %{status: 200, body: issue}}

        "/repos/octo/repo/issues/42/dependencies/blocked_by" ->
          {:ok, %{status: 200, body: [%{"id" => 7, "number" => 7, "state" => "closed", "state_reason" => "not_planned"}]}}
      end
    end

    assert {:ok, [blocked]} =
             GitHubClient.fetch_issues_by_ids_for_test(["42"], tracker_settings(), requests)

    refute blocked.dispatchable

    failed_requests = fn "GET", path, params, body, settings ->
      if String.ends_with?(path, "/blocked_by") do
        {:ok, %{status: 503, body: %{}}}
      else
        requests.("GET", path, params, body, settings)
      end
    end

    assert {:error, {:github_api_status, 503}} =
             GitHubClient.fetch_issues_by_ids_for_test(["42"], tracker_settings(), failed_requests)
  end

  test "dependency reads page through the final blocker" do
    issue = Map.put(raw_issue(42), "labels", [%{"name" => "symphony:ready"}])

    closed =
      for number <- 1..100,
          do: %{"id" => number, "number" => number, "state" => "closed", "state_reason" => "completed"}

    requests = fn "GET", path, params, nil, _settings ->
      case path do
        "/repos/octo/repo/issues/42" ->
          {:ok, %{status: 200, body: issue}}

        "/repos/octo/repo/issues/42/dependencies/blocked_by" ->
          send(self(), {:blocker_page, params["page"]})

          rows =
            if params["page"] == 1,
              do: closed,
              else: [%{"id" => 101, "number" => 101, "state" => "open"}]

          {:ok, %{status: 200, body: rows}}
      end
    end

    assert {:ok, [candidate]} =
             GitHubClient.fetch_issues_by_ids_for_test(["42"], tracker_settings(), requests)

    refute candidate.dispatchable
    assert length(candidate.blocked_by) == 101
    assert_receive {:blocker_page, 1}
    assert_receive {:blocker_page, 2}
  end

  test "github_api preserves REST status and body while rejecting unsafe arguments" do
    test_pid = self()
    tracker_settings = tracker_settings()

    response =
      GitHubAgentTool.execute(
        "github_api",
        %{
          "method" => "post",
          "path" => " /repos/octo/repo/issues/42/comments ",
          "params" => %{"per_page" => 10},
          "body" => %{"body" => "hello"}
        },
        tracker_settings: tracker_settings,
        github_client: fn method, path, params, body, opts ->
          send(test_pid, {:github_tool_called, method, path, params, body, opts})
          {:ok, %{status: 201, body: %{"id" => 9}}}
        end
      )

    assert_received {:github_tool_called, "POST", "/repos/octo/repo/issues/42/comments", %{"per_page" => 10}, %{"body" => "hello"}, [tracker_settings: ^tracker_settings]}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"status" => 201, "body" => %{"id" => 9}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]

    failure =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/repos/octo/repo/issues/404"},
        github_client: fn _method, _path, _params, _body, _opts ->
          {:ok, %{status: 404, body: %{"message" => "Not Found"}}}
        end
      )

    assert failure["success"] == false

    assert Jason.decode!(failure["output"]) == %{
             "status" => 404,
             "body" => %{"message" => "Not Found"}
           }

    Enum.each(
      [
        %{"method" => "GET", "path" => "https://api.github.com/user"},
        %{"method" => "GET", "path" => "/user", "params" => false},
        %{"path" => "/user"}
      ],
      fn arguments ->
        invalid =
          GitHubAgentTool.execute(
            "github_api",
            arguments,
            github_client: fn _method, _path, _params, _body, _opts ->
              flunk("invalid github_api arguments should not call the client")
            end
          )

        assert invalid["success"] == false
      end
    )
  end

  test "github_api reports unsupported tools, malformed calls, and client failures" do
    unsupported = GitHubAgentTool.execute("not_github_api", %{}, [])
    assert unsupported["success"] == false
    assert Jason.decode!(unsupported["output"])["error"]["supportedTools"] == ["github_api"]

    Enum.each(
      [
        "not-an-object",
        %{"method" => "GET", "path" => 123}
      ],
      fn arguments ->
        invalid =
          GitHubAgentTool.execute(
            "github_api",
            arguments,
            github_client: fn _method, _path, _params, _body, _opts ->
              flunk("malformed github_api arguments should not call the client")
            end
          )

        assert invalid["success"] == false
      end
    )

    malformed_response =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/user"},
        github_client: fn _method, _path, _params, _body, _opts ->
          {:ok, %{status: "not-an-integer", body: %{}}}
        end
      )

    assert malformed_response["success"] == false

    Enum.each(
      [
        :missing_github_token,
        {:github_api_request, :timeout},
        :unexpected_failure
      ],
      fn reason ->
        failure =
          GitHubAgentTool.execute(
            "github_api",
            %{"method" => "GET", "path" => "/user"},
            github_client: fn _method, _path, _params, _body, _opts ->
              {:error, reason}
            end
          )

        assert failure["success"] == false
        assert %{"error" => %{"message" => message}} = Jason.decode!(failure["output"])
        assert is_binary(message)
      end
    )

    non_json_body =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/user"},
        github_client: fn _method, _path, _params, _body, _opts ->
          {:ok, %{status: 200, body: self()}}
        end
      )

    assert non_json_body["success"]
    assert non_json_body["output"] =~ "#PID"
  end

  test "tracker binds GitHub tools and token env names from provider config" do
    token_env = "SYMPHONY_GITHUB_TOKEN_#{System.unique_integer([:positive])}"
    previous_token = System.get_env(token_env)
    System.put_env(token_env, "test-token")

    on_exit(fn -> restore_env(token_env, previous_token) end)

    write_github_workflow!(Workflow.workflow_file_path(), "$#{token_env}")

    binding = Tracker.bind_agent_tools()

    assert binding.adapter == GitHubAdapter

    assert binding.secret_environment_names == [
             "GITHUB_TOKEN",
             "GH_TOKEN",
             "GITHUB_ENTERPRISE_TOKEN",
             "GH_ENTERPRISE_TOKEN",
             token_env
           ]

    assert [%{"name" => "github_api"}] = binding.tool_specs
    assert :ok = Config.validate!()
  end

  test "autopilot keeps pull requests as work items gated by author trust or label opt-in" do
    issues = [
      raw_pull_issue(10, []),
      raw_pull_issue(11, []),
      raw_pull_issue(12, [%{"name" => "symphony:ready"}]),
      raw_pull_issue(13, []),
      raw_pull_issue(14, []),
      Map.put(raw_issue(15), "labels", [%{"name" => "symphony:ready"}])
    ]

    pulls = [
      raw_pull(10, "OWNER", "octo/repo"),
      raw_pull(11, "NONE", "stranger/fork", %{"maintainer_can_modify" => true}),
      raw_pull(12, "NONE", "stranger/fork"),
      raw_pull(13, "CONTRIBUTOR", "friend/fork", %{"user" => %{"login" => "AdamH"}, "draft" => true})
    ]

    request_fun = fn "GET", path, _params, nil, _settings ->
      send(self(), {:github_path, path})

      case path do
        "/repos/octo/repo/issues" -> {:ok, %{status: 200, body: issues}}
        "/repos/octo/repo/pulls" -> {:ok, %{status: 200, body: pulls}}
        "/repos/octo/repo/issues/15/dependencies/blocked_by" -> {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, [pr10, pr11, pr12, pr13, pr14, issue15]} =
             GitHubClient.fetch_issues_by_states_for_test(["open"], tracker_settings(), request_fun, pull_policy())

    assert %{kind: :pull_request, identifier: "PR-10", dispatchable: true, branch_name: "feature-10"} = pr10

    assert pr10.pull_request == %{
             number: 10,
             head_sha: "sha-10",
             head_ref: "feature-10",
             head_repo: "octo/repo",
             base_ref: "main",
             draft: false,
             can_push: true,
             author: "author10",
             author_association: "OWNER",
             trusted: true
           }

    assert %{dispatchable: false, pull_request: %{trusted: false, can_push: true}} = pr11
    assert %{dispatchable: true, pull_request: %{trusted: false, can_push: false}} = pr12
    assert %{dispatchable: false, pull_request: %{trusted: true, draft: true}} = pr13
    assert %{dispatchable: false, pull_request: nil} = pr14
    assert %{kind: :issue, identifier: "GH-15", dispatchable: true} = issue15

    assert Issue.routable?(pr12, ["symphony:ready"], [])
    refute Issue.routable?(%{pr10 | labels: ["symphony:hold"]}, [], ["symphony:hold"])
    refute_receive {:github_path, "/repos/octo/repo/issues/12/dependencies/blocked_by"}

    no_label_policy = %{pull_policy() | required_labels: []}

    no_label_settings = %{tracker_settings() | required_labels: []}

    assert {:ok, [_pr10, _pr11, %{dispatchable: false} | _]} =
             GitHubClient.fetch_issues_by_states_for_test(["open"], no_label_settings, request_fun, no_label_policy)

    # Without autopilot, pull requests stay out of the work queue.
    issues_only = fn "GET", "/repos/octo/repo/issues", _params, nil, _settings ->
      {:ok, %{status: 200, body: [raw_pull_issue(10, [])]}}
    end

    assert {:ok, []} = GitHubClient.fetch_issues_by_states_for_test(["open"], tracker_settings(), issues_only)
  end

  test "autopilot refreshes pull request details by number" do
    request_fun = fn "GET", path, _params, nil, _settings ->
      case path do
        "/repos/octo/repo/issues/10" -> {:ok, %{status: 200, body: raw_pull_issue(10, [])}}
        "/repos/octo/repo/issues/11" -> {:ok, %{status: 200, body: raw_pull_issue(11, [])}}
        "/repos/octo/repo/issues/12" -> {:ok, %{status: 200, body: raw_pull_issue(12, [])}}
        "/repos/octo/repo/issues/13" -> {:ok, %{status: 200, body: Map.put(raw_pull_issue(13, []), "state", "closed")}}
        "/repos/octo/repo/pulls/10" -> {:ok, %{status: 200, body: raw_pull(10, "MEMBER", "octo/repo")}}
        "/repos/octo/repo/pulls/11" -> {:ok, %{status: 404, body: %{}}}
        "/repos/octo/repo/pulls/12" -> {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, [pr10, pr11, pr13]} =
             GitHubClient.fetch_issues_by_ids_for_test(["10", "11", "13"], tracker_settings(), request_fun, pull_policy())

    assert %{dispatchable: true, pull_request: %{head_sha: "sha-10"}} = pr10
    assert %{dispatchable: false, pull_request: nil} = pr11
    assert %{state: "closed", pull_request: nil} = pr13

    assert {:error, :github_unknown_payload} =
             GitHubClient.fetch_issues_by_ids_for_test(["12"], tracker_settings(), request_fun, pull_policy())

    assert {:error, {:github_api_status, 500}} =
             GitHubClient.fetch_issues_by_ids_for_test(
               ["10"],
               tracker_settings(),
               fn "GET", path, _params, nil, _settings ->
                 if path == "/repos/octo/repo/issues/10",
                   do: {:ok, %{status: 200, body: raw_pull_issue(10, [])}},
                   else: {:ok, %{status: 500, body: %{}}}
               end,
               pull_policy()
             )
  end

  test "client summarizes commit CI from statuses and check runs" do
    ci = fn status, check_runs ->
      GitHubClient.fetch_commit_ci_state_for_test("abc123", tracker_settings(), fn "GET", path, _params, nil, _settings ->
        case path do
          "/repos/octo/repo/commits/abc123/status" -> {:ok, %{status: 200, body: status}}
          "/repos/octo/repo/commits/abc123/check-runs" -> {:ok, %{status: 200, body: %{"check_runs" => check_runs}}}
        end
      end)
    end

    completed = fn conclusion -> %{"status" => "completed", "conclusion" => conclusion} end

    assert {:ok, "none"} = ci.(%{"total_count" => 0, "state" => "pending"}, [])
    assert {:ok, "success"} = ci.(%{"total_count" => 1, "state" => "success"}, [completed.("skipped"), completed.("neutral")])
    assert {:ok, "pending"} = ci.(%{"total_count" => 1, "state" => "success"}, [%{"status" => "in_progress"}])
    assert {:ok, "failure"} = ci.(%{"total_count" => 0}, [completed.("success"), completed.("timed_out")])
    assert {:ok, "failure"} = ci.(%{"total_count" => 2, "state" => "error"}, [])
    assert {:ok, "none"} = ci.(%{}, [])

    malformed = fn "GET", _path, _params, nil, _settings -> {:ok, %{status: 200, body: []}} end

    assert {:error, :github_unknown_payload} =
             GitHubClient.fetch_commit_ci_state_for_test("abc123", tracker_settings(), malformed)
  end

  test "orchestrator refreshes the GitHub pull request inventory" do
    write_github_workflow!(Workflow.workflow_file_path(), "test-token")
    Application.put_env(:symphony_elixir, :github_client_module, InventoryGitHubClient)

    supervisor = Module.concat(__MODULE__, :InventoryTaskSupervisor)
    orchestrator = Module.concat(__MODULE__, :InventoryOrchestrator)
    start_supervised!({Task.Supervisor, name: supervisor})
    start_supervised!({Orchestrator, name: orchestrator, task_supervisor: supervisor})

    expected_pull = %{number: 12, title: "Finish water", url: "https://github.test/pull/12", draft: true, updated_at: "2026-09-01T00:00:00Z"}
    expected_issue = %{issue_identifier: "GH-42", reason: "excluded by symphony:needs-attention", title: "Blocked water", issue_url: nil, priority: nil, blocked_by: []}

    assert Enum.any?(1..30, fn _ ->
             snapshot = Orchestrator.snapshot(orchestrator, 5_000)
             if get_in(snapshot, [:pull_requests, :items]) == [], do: Process.sleep(50)

             get_in(snapshot, [:pull_requests, :items]) == [expected_pull] and
               get_in(snapshot, [:upcoming, :waiting]) == [expected_issue]
           end)
  end

  defp tracker_settings(provider_overrides \\ %{}) do
    %{
      kind: "github",
      provider:
        Map.merge(
          %{
            "repo" => "octo/repo",
            "token" => "test-token"
          },
          provider_overrides
        ),
      active_states: ["open"],
      terminal_states: ["closed"],
      required_labels: ["symphony:ready"]
    }
  end

  defp pull_policy do
    %{trusted_associations: ["OWNER", "MEMBER", "COLLABORATOR"], trusted_authors: ["adamh"], required_labels: ["symphony:ready"]}
  end

  defp raw_pull_issue(number, labels) do
    number
    |> raw_issue()
    |> Map.merge(%{"labels" => labels, "pull_request" => %{"url" => "https://api.github.test/pulls/#{number}"}})
  end

  defp raw_pull(number, association, head_repo, overrides \\ %{}) do
    Map.merge(
      %{
        "number" => number,
        "draft" => false,
        "author_association" => association,
        "user" => %{"login" => "author#{number}"},
        "maintainer_can_modify" => false,
        "head" => %{"sha" => "sha-#{number}", "ref" => "feature-#{number}", "repo" => %{"full_name" => head_repo}},
        "base" => %{"ref" => "main"}
      },
      overrides
    )
  end

  defp raw_issue(number) do
    %{
      "number" => number,
      "id" => 1_000 + number,
      "node_id" => "I_#{number}",
      "title" => "Issue #{number}",
      "body" => "Body #{number}",
      "state" => "open",
      "html_url" => "https://github.test/octo/repo/issues/#{number}",
      "assignee" => %{"login" => "octocat"},
      "labels" => [%{"name" => " Bug "}, %{"name" => "bug"}, %{"name" => "Platform"}],
      "created_at" => "2026-01-01T00:00:00Z",
      "updated_at" => "2026-01-02T00:00:00Z"
    }
  end

  defp write_github_workflow!(path, token) do
    File.write!(
      path,
      """
      ---
      tracker:
        kind: github
        provider:
          repo: "octo/repo"
          token: #{Jason.encode!(token)}
        active_states: ["open"]
        terminal_states: ["closed"]
        excluded_labels: ["symphony:needs-attention"]
      ---

      You are working on {{ issue.identifier }}.
      """
    )

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      assert :ok = SymphonyElixir.WorkflowStore.force_reload()
    end
  end
end
