defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Codex.Usage, Config, PathSafety, SSH}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @pending_limit 4_194_304
  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          dynamic_tool_binding: map(),
          model_route: map() | nil,
          resumed: boolean(),
          reuse_context: map() | nil
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <-
           start_session(workspace, Keyword.put_new(opts, :work_item, Map.get(issue, :identifier))) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        try do
          read_account_usage(session, opts)
        after
          stop_session(session)
        end
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    model_route = Keyword.get(opts, :model_route)
    codex = Keyword.get(opts, :codex_settings, Config.settings!().codex)
    session_env = %{route: model_route, work_item: Keyword.get(opts, :work_item), command: codex.command}
    dynamic_tool_binding = DynamicTool.bind()

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host, dynamic_tool_binding, session_env) do
      metadata = port_metadata(port, worker_host)

      with {:ok, policies} <- session_policies(expanded_workspace, worker_host),
           {:ok, native} <-
             do_start_session(
               port,
               expanded_workspace,
               policies,
               dynamic_tool_binding,
               model_route,
               codex,
               opts
             ) do
        session = %{
          port: port,
          metadata: Map.merge(metadata, native.metadata),
          approval_policy: policies.approval_policy,
          auto_approve_requests: policies.approval_policy == "never",
          thread_sandbox: policies.thread_sandbox,
          turn_sandbox_policy: policies.turn_sandbox_policy,
          thread_id: native.thread_id,
          workspace: expanded_workspace,
          worker_host: worker_host,
          dynamic_tool_binding: dynamic_tool_binding,
          model_route: model_route,
          resumed: native.resumed,
          reuse_context: native.reuse_context
        }

        Process.put({port, :metadata}, session.metadata)
        on_message = Keyword.get(opts, :on_message, &default_on_message/1)
        details = %{thread_id: session.thread_id, resumed: session.resumed}
        emit_message(on_message, :thread_initialized, details, session.metadata)
        flush_notifications(port, on_message, session.resumed)
        {:ok, session}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace,
          dynamic_tool_binding: dynamic_tool_binding,
          model_route: model_route
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments, dynamic_tool_binding, issue: issue)
      end)

    case start_turn(port, thread_id, prompt, workspace, approval_policy, turn_sandbox_policy, model_route) do
      {:ok, turn_id} ->
        Process.put({port, :active_turn}, {thread_id, turn_id})
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        case await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  @doc "Reads the native cumulative account estimate without making telemetry a worker failure."
  @spec read_account_usage(session(), keyword()) :: :ok
  def read_account_usage(session, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    if native_version(session.metadata[:user_agent]) do
      usage = native_account_usage(session)

      flush_notifications(session.port, on_message, false)

      emit_message(
        on_message,
        :account_usage,
        %{thread_id: session.thread_id, account_usage: usage},
        session.metadata
      )
    end

    :ok
  end

  defp native_account_usage(session) do
    case rpc(session.port, "account/usage/read", %{"threadId" => session.thread_id}, 1_000) do
      {:ok, result} -> result["threadUsage"]
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Captures a successful boundary only when the verified native context still matches."
  @spec checkpoint(session(), map(), keyword()) :: map() | nil
  def checkpoint(%{reuse_context: nil}, _turn, _opts), do: nil

  def checkpoint(session, turn, opts) do
    result =
      with {:ok, context} <-
             reuse_context(
               session.port,
               session.workspace,
               session.reuse_context.settings,
               session.reuse_context.sources
             ),
           true <- Process.get({session.port, :metadata})[:model] == session.metadata[:model],
           true <- context.instructions == session.reuse_context.instructions,
           true <- context.runtime == session.reuse_context.runtime do
        %{
          eligible: true,
          thread_id: session.thread_id,
          thread_key: session.metadata.thread_key,
          compatibility: context,
          native_settings: session.reuse_context.settings,
          turn_id: turn.turn_id,
          worker_host: session.worker_host,
          item_attempt: Keyword.get(opts, :item_attempt, 1)
        }
      else
        _ -> nil
      end

    flush_notifications(session.port, Keyword.get(opts, :on_message, &default_on_message/1), false)
    result
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil, dynamic_tool_binding, session_env) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [
              ~c"-lc",
              String.to_charlist(local_launch_command(dynamic_tool_binding, session_env.command))
            ],
            cd: String.to_charlist(workspace),
            env: tracker_secret_port_env(dynamic_tool_binding) ++ session_port_env(session_env),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host, dynamic_tool_binding, session_env) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, dynamic_tool_binding, session_env)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp local_launch_command(dynamic_tool_binding, command) do
    [
      tracker_secret_unset_command(dynamic_tool_binding),
      "exec #{command}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp remote_launch_command(workspace, dynamic_tool_binding, session_env) when is_binary(workspace) do
    exports =
      case session_vars(session_env) do
        [] ->
          nil

        vars ->
          "export " <> Enum.map_join(vars, " ", fn {name, value} -> "#{name}=#{shell_escape(value)}" end)
      end

    [
      "cd #{shell_escape(workspace)}",
      tracker_secret_unset_command(dynamic_tool_binding),
      exports,
      "exec #{session_env.command}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp session_port_env(session_env),
    do:
      Enum.map(session_vars(session_env), fn {name, value} ->
        {String.to_charlist(name), String.to_charlist(value)}
      end)

  # Every command in the run inherits these: the delivery helper checks the
  # route label, and machine-wide tooling attributes work to the work item.
  defp session_vars(%{route: route, work_item: work_item}),
    do: SymphonyElixir.RunEnv.vars(if(is_binary(work_item), do: work_item), route && route["label"])

  defp tracker_secret_port_env(dynamic_tool_binding) do
    dynamic_tool_binding.secret_environment_names
    |> valid_environment_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp tracker_secret_unset_command(dynamic_tool_binding) do
    case dynamic_tool_binding.secret_environment_names |> valid_environment_names() do
      [] -> nil
      names -> "unset " <> Enum.join(names, " ")
    end
  end

  defp valid_environment_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "crescendo-orchestrator",
          "title" => "Crescendo Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, result} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      {:ok, result}
    end
  end

  defp session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp do_start_session(port, workspace, policies, binding, route, codex, opts) do
    with {:ok, initialized} <- send_initialize(port),
         {:ok, additions} <- developer_instructions(port, workspace, codex.developer_instructions) do
      settings = %{
        reuse_contract: 1,
        workspace: workspace,
        policies: policies,
        tools_hash: fingerprint(binding.tool_specs),
        route: route,
        codex_hash: fingerprint(Map.from_struct(codex)),
        native: initialized,
        contract: Keyword.get(opts, :contract_hash)
      }

      candidate = Keyword.get(opts, :checkpoint)
      reuse = reuse_enabled?(codex, initialized, opts)
      resumed = if reuse, do: resume_thread(port, candidate, settings, additions)

      with {:ok, result, restored} <-
             resumed || fresh_thread(port, workspace, policies, binding, route, additions) do
        context = read_reuse_context(port, settings, result["instructionSources"], reuse)
        metadata = native_metadata(result, settings, opts)
        thread_id = result["thread"]["id"]
        {:ok, %{thread_id: thread_id, metadata: metadata, resumed: restored, reuse_context: context}}
      end
    end
  end

  defp reuse_enabled?(codex, initialized, opts) do
    codex.resume_threads and is_nil(Keyword.get(opts, :worker_host)) and Keyword.get(opts, :kind) == :issue and
      native_version(initialized["userAgent"]) in ["0.156.1", "0.160.0"]
  end

  defp read_reuse_context(_port, _settings, _sources, false), do: nil

  defp read_reuse_context(port, settings, sources, true) do
    case reuse_context(port, settings.workspace, settings, sources) do
      {:ok, context} -> context
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp native_metadata(result, %{native: initialized, route: route, tools_hash: tools_hash}, opts) do
    sources = result["instructionSources"]

    %{
      thread_key: {fingerprint({Keyword.get(opts, :worker_host), initialized["codexHome"]}), result["thread"]["id"]},
      user_agent: initialized["userAgent"],
      codex_version: native_version(initialized["userAgent"]),
      model: result["model"] || (route && route["model"]),
      requested_model: route && route["model"],
      model_provider: result["modelProvider"],
      effort: (route && route["effort"]) || result["reasoningEffort"],
      effort_source: if(route && route["effort"], do: "turn_override", else: "thread_response"),
      service_tier: result["serviceTier"],
      instruction_sources_hash: fingerprint(sources),
      instruction_files_hash: native_instruction_hash(sources, Keyword.get(opts, :worker_host)),
      dynamic_tools_hash: tools_hash,
      effective_settings_hash: fingerprint(Map.drop(result, ["thread", "instructionSources"])),
      native_storage_hash: fingerprint(initialized["codexHome"])
    }
  end

  defp native_instruction_hash(sources, nil) when is_list(sources) do
    case instruction_fingerprints(sources) do
      {:ok, files} -> fingerprint(files)
      _ -> nil
    end
  end

  defp native_instruction_hash(_sources, _host), do: nil

  defp developer_instructions(_port, _workspace, nil), do: {:ok, nil}

  defp developer_instructions(port, workspace, addition) do
    with {:ok, %{"config" => config}} <-
           rpc(port, "config/read", %{"cwd" => workspace, "includeLayers" => false}),
         true <- is_nil(config["developer_instructions"]) or is_binary(config["developer_instructions"]) do
      {:ok, Enum.reject([config["developer_instructions"], addition], &is_nil/1) |> Enum.join("\n\n")}
    else
      error -> {:error, {:developer_instructions_unverified, error}}
    end
  end

  defp fresh_thread(port, workspace, policies, binding, route, additions) do
    case start_thread(port, workspace, policies, binding, route, additions) do
      {:ok, result} -> {:ok, result, false}
      error -> error
    end
  end

  # Reuse is deliberately conservative: unknown history, missing baselines,
  # remote files, or any changed native configuration start a new thread.
  defp resume_thread(
         port,
         %{
           eligible: true,
           native_settings: _,
           compatibility: %{sources: _},
           usage_watermark: %{input_tokens: _, output_tokens: _},
           thread_id: thread,
           turn_id: last
         } = checkpoint,
         settings,
         additions
       )
       when is_binary(thread) and is_binary(last) do
    with true <- checkpoint.native_settings == settings,
         {:ok, context} <- reuse_context(port, settings.workspace, settings, checkpoint.compatibility.sources),
         true <- context == checkpoint.compatibility,
         {:ok, %{"data" => [%{"id" => turn, "status" => "completed"}]}} <-
           rpc(port, "thread/turns/list", %{
             "threadId" => checkpoint.thread_id,
             "limit" => 1,
             "sortDirection" => "desc",
             "itemsView" => "notLoaded"
           }),
         true <- turn == checkpoint.turn_id,
         {:ok, %{"thread" => %{"id" => thread, "status" => %{"type" => "idle"}}} = result} <-
           rpc(port, "thread/resume", resume_params(checkpoint, settings, additions)),
         true <- thread == checkpoint.thread_id,
         {:ok, baseline} <- restored_baseline(port, thread),
         true <- baseline.complete and baseline.turn_id == checkpoint.turn_id,
         true <- baseline.total.input_tokens == checkpoint.usage_watermark.input_tokens,
         true <- baseline.total.output_tokens == checkpoint.usage_watermark.output_tokens,
         true <- result["instructionSources"] == checkpoint.compatibility.sources do
      {:ok, result, true}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp resume_thread(_port, _checkpoint, _settings, _additions), do: nil

  defp resume_params(checkpoint, settings, additions) do
    %{
      "threadId" => checkpoint.thread_id,
      "cwd" => settings.workspace,
      "approvalPolicy" => settings.policies.approval_policy,
      "sandbox" => settings.policies.thread_sandbox,
      "excludeTurns" => true
    }
    |> maybe_put("model", settings.route && settings.route["model"])
    |> maybe_put("developerInstructions", additions)
  end

  defp restored_baseline(port, thread) do
    # A read barrier lets already-emitted restore notifications arrive before
    # we inspect them. No turn is submitted unless the native baseline exists.
    with {:ok, _} <- rpc(port, "thread/read", %{"threadId" => thread, "includeTurns" => false}) do
      pending = Process.get({port, :pending}, :queue.new()) |> :queue.to_list()

      case Enum.find_value(pending, &decode_baseline(&1, thread)) do
        nil -> {:error, :restored_usage_unavailable}
        baseline -> {:ok, baseline}
      end
    end
  end

  defp decode_baseline(line, thread) do
    case Usage.snapshot(%{payload: Jason.decode!(line)}) do
      %{thread_id: ^thread, source: :canonical} = baseline -> baseline
      _ -> nil
    end
  end

  defp reuse_context(port, workspace, settings, sources) do
    with true <- is_list(sources) and Enum.all?(sources, &is_binary/1),
         {:ok, %{"config" => config}} <-
           rpc(port, "config/read", %{"cwd" => workspace, "includeLayers" => false}),
         {:ok, %{"data" => skills}} <-
           rpc(port, "skills/list", %{"cwds" => [workspace], "forceReload" => true}),
         true <- Enum.all?(skills, &(&1["errors"] == [])),
         {:ok, %{"data" => tools, "nextCursor" => nil}} <- rpc(port, "mcpServerStatus/list", %{}),
         {:ok, files} <- instruction_fingerprints(sources ++ skill_paths(skills)),
         {:ok, storage} <- native_storage_identity(settings.native["codexHome"]),
         {:ok, checkout} <- checkout_identity(workspace) do
      {:ok,
       %{
         settings: settings,
         sources: sources,
         instructions: files,
         checkout: checkout,
         runtime: fingerprint({config, skills, tools, storage, System.get_env()}),
         day: Date.to_iso8601(Date.utc_today())
       }}
    else
      _ -> {:error, :reuse_context_unverified}
    end
  end

  defp native_storage_identity(home) when is_binary(home) do
    with {:ok, %{type: :directory} = stat} <- File.stat(home),
         {:ok, auth} <- optional_file_hash(Path.join(home, "auth.json")),
         {:ok, config} <- optional_file_hash(Path.join(home, "config.toml")) do
      {:ok, {stat.inode, stat.major_device, auth, config}}
    end
  end

  defp native_storage_identity(_home), do: {:error, :native_storage_unknown}

  defp optional_file_hash(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, fingerprint(content)}
      {:error, :enoent} -> {:ok, :absent}
      error -> error
    end
  end

  defp skill_paths(skills) do
    for entry <- skills,
        skill <- entry["skills"] || [],
        is_binary(skill["path"]),
        path <- Path.wildcard(Path.join(Path.dirname(skill["path"]), "**/*"), match_dot: true),
        File.regular?(path),
        do: path
  end

  defp instruction_fingerprints(paths) do
    Enum.reduce_while(Enum.uniq(paths), {:ok, %{}}, fn path, {:ok, acc} ->
      case File.read(path) do
        {:ok, content} -> {:cont, {:ok, Map.put(acc, path, fingerprint(content))}}
        _ -> {:halt, {:error, :instruction_unreadable}}
      end
    end)
  end

  defp checkout_identity(workspace) do
    with {:ok, stat} <- File.stat(workspace),
         {head, 0} <- System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true),
         {git_dir, 0} <-
           System.cmd("git", ["rev-parse", "--absolute-git-dir"], cd: workspace, stderr_to_stdout: true),
         {:ok, git_stat} <- File.stat(String.trim(git_dir)),
         {diff, 0} <- System.cmd("git", ["diff", "HEAD", "--binary"], cd: workspace, stderr_to_stdout: true),
         {untracked, 0} <-
           System.cmd("git", ["ls-files", "--others", "--exclude-standard", "-z"],
             cd: workspace,
             stderr_to_stdout: true
           ),
         {:ok, untracked_hashes} <-
           instruction_fingerprints(Enum.map(String.split(untracked, <<0>>, trim: true), &Path.join(workspace, &1))) do
      {:ok, fingerprint({stat.inode, stat.major_device, git_stat.inode, String.trim(head), diff, untracked_hashes})}
    else
      _ -> {:error, :checkout_unverified}
    end
  rescue
    _ -> {:error, :checkout_unverified}
  end

  defp fingerprint(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)

  defp native_version(value) when is_binary(value) do
    case Regex.run(~r/\b(\d+\.\d+\.\d+)\b/, value) do
      [_, version] -> version
      _ -> nil
    end
  end

  defp native_version(_), do: nil

  defp start_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox},
         dynamic_tool_binding,
         model_route,
         developer_instructions
       ) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" =>
        %{
          "approvalPolicy" => approval_policy,
          "sandbox" => thread_sandbox,
          "cwd" => workspace,
          "dynamicTools" => dynamic_tool_binding.tool_specs
        }
        |> maybe_put("model", model_route && model_route["model"])
        |> maybe_put("developerInstructions", developer_instructions)
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload} = result} ->
        case thread_payload do
          %{"id" => thread_id} when is_binary(thread_id) -> {:ok, result}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp start_turn(port, thread_id, prompt, workspace, approval_policy, turn_sandbox_policy, model_route) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" =>
        %{
          "threadId" => thread_id,
          "input" => [
            %{
              "type" => "text",
              "text" => prompt
            }
          ],
          "cwd" => workspace,
          "approvalPolicy" => approval_policy,
          "sandboxPolicy" => turn_sandbox_policy
        }
        |> maybe_put("effort", model_route && model_route["effort"])
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests
    )
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    case pop_notification(port) do
      nil -> receive_port(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests)
      line -> handle_incoming(port, on_message, line, timeout_ms, tool_executor, auto_approve_requests)
    end
  end

  defp receive_port(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, on_message, complete_line, timeout_ms, tool_executor, auto_approve_requests)

      {^port, {:data, {:noeol, chunk}}} ->
        if byte_size(pending_line) + byte_size(chunk) > @pending_limit do
          {:error, :protocol_buffer_overflow}
        else
          receive_loop(
            port,
            on_message,
            timeout_ms,
            pending_line <> to_string(chunk),
            tool_executor,
            auto_approve_requests
          )
        end

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(_port, _on_message, data, _timeout, _executor, _auto)
       when byte_size(data) > @pending_limit,
       do: {:error, :protocol_buffer_overflow}

  defp handle_incoming(port, on_message, data, timeout_ms, tool_executor, auto_approve_requests) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        if current_turn?(port, payload) do
          complete_turn(port, on_message, payload, payload_string)
        else
          receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
        end

      {:ok, %{"method" => method, "params" => _} = payload}
      when method in ["turn/failed", "turn/cancelled"] ->
        failed_terminal(
          port,
          on_message,
          payload,
          payload_string,
          timeout_ms,
          tool_executor,
          auto_approve_requests
        )

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(
          port,
          on_message,
          payload,
          payload_string,
          method,
          timeout_ms,
          tool_executor,
          auto_approve_requests
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
    end
  end

  defp complete_turn(port, on_message, payload, payload_string) do
    case get_in(payload, ["params", "turn", "status"]) do
      "completed" ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, :turn_completed}

      status ->
        emit_turn_event(on_message, :turn_failed, payload, payload_string, port, payload)
        {:error, {:turn_not_completed, status}}
    end
  end

  defp failed_terminal(port, on_message, payload, raw, timeout, executor, auto_approve) do
    if current_turn?(port, payload) do
      event = if payload["method"] == "turn/failed", do: :turn_failed, else: :turn_cancelled
      emit_turn_event(on_message, event, payload, raw, port, payload["params"])
      {:error, {event, payload["params"]}}
    else
      receive_loop(port, on_message, timeout, "", executor, auto_approve)
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         auto_approve_requests
       ) do
    refresh_native_model(port, payload)
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
        end
    end
  end

  defp refresh_native_model(port, %{"method" => "model/rerouted", "params" => %{"toModel" => model}})
       when is_binary(model) do
    Process.put({port, :metadata}, Map.put(Process.get({port, :metadata}, %{}), :model, model))
  end

  defp refresh_native_model(_port, _payload), do: :ok

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         _port,
         _id,
         _params,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ),
       do: :input_required

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    if String.starts_with?(question_id, "mcp_tool_call_approval_") do
      case tool_request_user_input_approval_option_label(options) do
        nil -> :error
        answer_label -> {:ok, question_id, answer_label}
      end
    else
      :error
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    deadline = System.monotonic_time(:millisecond) + Config.settings!().codex.read_timeout_ms
    with_timeout_response(port, request_id, deadline, "")
  end

  defp rpc(port, method, params, timeout \\ nil) do
    id = "crescendo-#{System.unique_integer([:positive])}"
    send_message(port, %{"id" => id, "method" => method, "params" => params})
    deadline = System.monotonic_time(:millisecond) + (timeout || Config.settings!().codex.read_timeout_ms)
    with_timeout_response(port, id, deadline, "")
  end

  defp with_timeout_response(port, request_id, deadline, pending_line) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0,
      do: receive_response(port, request_id, deadline, remaining, pending_line),
      else: {:error, :response_timeout}
  end

  defp receive_response(port, request_id, deadline, remaining, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, deadline)

      {^port, {:data, {:noeol, chunk}}} ->
        if byte_size(pending_line) + byte_size(chunk) > @pending_limit do
          {:error, :protocol_buffer_overflow}
        else
          with_timeout_response(port, request_id, deadline, pending_line <> to_string(chunk))
        end

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      remaining ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(_port, _request, data, _deadline) when byte_size(data) > @pending_limit,
    do: {:error, :protocol_buffer_overflow}

  defp handle_response(port, request_id, data, deadline) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        case queue_notification(port, other, payload) do
          :ok -> with_timeout_response(port, request_id, deadline, "")
          error -> error
        end

      _ ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, deadline, "")
    end
  end

  defp queue_notification(port, %{"method" => _}, line) do
    bytes = Process.get({port, :pending_bytes}, 0) + byte_size(line)
    queue = Process.get({port, :pending}, :queue.new())

    if bytes <= @pending_limit and :queue.len(queue) < 1_024 do
      Process.put({port, :pending_bytes}, bytes)
      Process.put({port, :pending}, :queue.in(line, queue))
      :ok
    else
      {:error, :protocol_buffer_overflow}
    end
  end

  defp queue_notification(_port, _payload, _line), do: :ok

  defp pop_notification(port) do
    case :queue.out(Process.get({port, :pending}, :queue.new())) do
      {{:value, line}, queue} ->
        Process.put({port, :pending}, queue)
        Process.put({port, :pending_bytes}, Process.get({port, :pending_bytes}, 0) - byte_size(line))
        line

      _ ->
        nil
    end
  end

  defp flush_notifications(port, on_message, restored) do
    case pop_notification(port) do
      nil ->
        :ok

      line ->
        payload = Jason.decode!(line)
        # Requests must remain in the turn loop where tools and approvals have
        # their normal handlers; only startup notifications are emitted here.
        if payload["id"] do
          :ok = queue_notification(port, payload, line)
        else
          details = %{payload: payload, raw: line, restored: restored}
          emit_message(on_message, :notification, details, metadata_from_message(port, payload))
          flush_notifications(port, on_message, restored)
        end
    end
  end

  defp current_turn?(port, payload) do
    {thread, turn} = Process.get({port, :active_turn})
    params = payload["params"] || %{}
    supplied_thread = params["threadId"]
    supplied_turn = get_in(params, ["turn", "id"]) || params["turnId"]
    strict = native_version(Process.get({port, :metadata}, %{})[:user_agent]) != nil

    (supplied_thread == thread or (is_nil(supplied_thread) and not strict)) and
      (supplied_turn == turn or (is_nil(supplied_turn) and not strict))
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    for key <- [:metadata, :active_turn, :pending, :pending_bytes], do: Process.delete({port, key})

    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    metadata = Map.merge(port_metadata(port, nil), Process.get({port, :metadata}, %{}))
    maybe_set_usage(metadata, payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") ||
           Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
