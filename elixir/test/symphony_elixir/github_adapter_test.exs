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

  test "orchestrator refreshes the GitHub pull request inventory" do
    write_github_workflow!(Workflow.workflow_file_path(), "test-token")
    Application.put_env(:symphony_elixir, :github_client_module, InventoryGitHubClient)

    supervisor = Module.concat(__MODULE__, :InventoryTaskSupervisor)
    orchestrator = Module.concat(__MODULE__, :InventoryOrchestrator)
    start_supervised!({Task.Supervisor, name: supervisor})
    start_supervised!({Orchestrator, name: orchestrator, task_supervisor: supervisor})

    expected_pull = %{number: 12, title: "Finish water", url: "https://github.test/pull/12", draft: true, updated_at: "2026-09-01T00:00:00Z"}
    expected_issue = %{issue_identifier: "GH-42", reason: "needs attention", title: "Blocked water", issue_url: nil, priority: nil, blocked_by: []}

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
      ---

      You are working on {{ issue.identifier }}.
      """
    )

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      assert :ok = SymphonyElixir.WorkflowStore.force_reload()
    end
  end
end
