defmodule SymphonyElixir.Pi.RpcClient do
  @moduledoc """
  Minimal Pi RPC client over stdio ports.
  """

  alias SymphonyElixir.{Config, PathSafety}

  @get_state_id 1
  @set_session_name_id 2
  @set_auto_retry_id 3
  @set_auto_compaction_id 4
  @prompt_id 5
  @extension_ui_response_id 6
  @set_model_id 97
  @set_thinking_level_id 98
  @port_line_bytes 1_048_576

  @type session :: %{
          port: port(),
          metadata: map(),
          base_session_id: String.t(),
          session_file: String.t() | nil,
          session_dir: Path.t(),
          workspace: Path.t(),
          response_timeout_ms: pos_integer(),
          worker_host: String.t() | nil
        }

  @type incoming_message ::
          {:response, map()}
          | {:event, map()}
          | {:extension_ui_request, map()}
          | {:malformed, String.t()}

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with :ok <- validate_worker_host(worker_host),
         {:ok, expanded_workspace} <- validate_workspace_cwd(workspace),
         {:ok, session_dir} <- ensure_session_dir(expanded_workspace),
         {:ok, port} <- start_port(expanded_workspace, session_dir),
         {:ok, response} <-
           request_response(
             port,
             @get_state_id,
             %{"type" => "get_state"},
             Config.settings!().pi.response_timeout_ms
           ),
         {:ok, base_session_id, session_file} <- session_identity_from_response(response) do
      {:ok,
       %{
         port: port,
         metadata: port_metadata(port, worker_host),
         base_session_id: base_session_id,
         session_file: session_file,
         session_dir: session_dir,
         workspace: expanded_workspace,
         response_timeout_ms: Config.settings!().pi.response_timeout_ms,
         worker_host: worker_host
       }}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec configure_turn(session(), map()) :: :ok | {:error, term()}
  def configure_turn(%{port: port, response_timeout_ms: timeout_ms}, %{name: session_name} = turn_config) when is_binary(session_name) do
    with {:ok, _} <- request_response(port, @set_session_name_id, %{"type" => "set_session_name", "name" => session_name}, timeout_ms),
         {:ok, _} <- request_response(port, @set_auto_retry_id, %{"type" => "set_auto_retry", "enabled" => false}, timeout_ms),
         {:ok, _} <- request_response(port, @set_auto_compaction_id, %{"type" => "set_auto_compaction", "enabled" => false}, timeout_ms) do
      resolved_model = Map.get(turn_config, :model)
      resolved_thinking = Map.get(turn_config, :thinking_level)

      case maybe_set_model(port, timeout_ms, resolved_model) do
        :ok -> maybe_set_thinking_level(port, timeout_ms, resolved_thinking)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_set_model(port, timeout_ms, override_model) do
    model = override_model || Config.settings!().pi.model

    case model do
      %{provider: provider, model_id: model_id}
      when is_binary(provider) and is_binary(model_id) ->
        case request_response(
               port,
               @set_model_id,
               %{"type" => "set_model", "provider" => provider, "modelId" => model_id},
               timeout_ms
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        :ok
    end
  end

  defp maybe_set_thinking_level(port, timeout_ms, override_thinking) do
    thinking_level = override_thinking || Config.settings!().pi.thinking_level

    case thinking_level do
      level when is_binary(level) ->
        case request_response(
               port,
               @set_thinking_level_id,
               %{"type" => "set_thinking_level", "level" => level},
               timeout_ms
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        :ok
    end
  end

  @spec start_prompt(session(), String.t()) :: {:ok, pos_integer()} | {:error, term()}
  def start_prompt(%{port: port, response_timeout_ms: timeout_ms}, prompt) when is_binary(prompt) do
    case request_response(port, @prompt_id, %{"type" => "prompt", "message" => prompt}, timeout_ms) do
      {:ok, _} -> {:ok, @prompt_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec abort(session()) :: :ok | {:error, term()}
  def abort(%{port: port, response_timeout_ms: timeout_ms}) do
    case request_response(port, 99, %{"type" => "abort"}, timeout_ms) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec receive_message(session(), timeout(), String.t()) :: {:ok, incoming_message(), String.t()} | {:error, term()}
  def receive_message(%{port: port} = session, timeout_ms, pending_line \\ "") do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        handle_data_line(session, pending_line <> to_string(chunk), timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_message(session, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :timeout}
    end
  end

  @spec auto_cancel_extension_request(session(), map()) :: :ok
  def auto_cancel_extension_request(%{port: port}, %{"id" => request_id, "method" => method})
      when method in ["select", "confirm", "input", "editor"] do
    send_message(port, %{
      "type" => "extension_ui_response",
      "id" => request_id,
      "cancelled" => true,
      "requestId" => @extension_ui_response_id
    })

    :ok
  end

  def auto_cancel_extension_request(_session, _request), do: :ok

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp handle_data_line(_session, data, _timeout_ms) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"type" => "response"} = payload} ->
        {:ok, {:response, payload}, ""}

      {:ok, %{"type" => "extension_ui_request"} = payload} ->
        {:ok, {:extension_ui_request, payload}, ""}

      {:ok, %{"type" => _type} = payload} ->
        {:ok, {:event, payload}, ""}

      {:ok, payload} when is_map(payload) ->
        {:ok, {:event, payload}, ""}

      {:error, _reason} ->
        {:ok, {:malformed, payload_string}, ""}
    end
  end

  defp validate_worker_host(nil), do: :ok
  defp validate_worker_host(_worker_host), do: {:error, :remote_pi_workers_not_supported}

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
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

  defp ensure_session_dir(workspace) do
    session_dir = Path.join([workspace, Config.settings!().pi.session_dir_name, unique_suffix()])
    File.mkdir_p!(session_dir)
    {:ok, session_dir}
  rescue
    error in [File.Error, SystemLimitError] -> {:error, error}
  end

  defp start_port(workspace, session_dir) do
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
            args: [~c"-lc", String.to_charlist(build_command(session_dir))],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp request_response(port, request_id, payload, timeout_ms) do
    payload = Map.put(payload, "id", request_id)
    send_message(port, payload)
    await_response(port, request_id, timeout_ms)
  end

  defp await_response(port, request_id, timeout_ms, pending_line \\ "") do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        payload_string = pending_line <> to_string(chunk)

        case Jason.decode(payload_string) do
          {:ok, %{"type" => "response", "id" => ^request_id, "success" => true} = response} ->
            {:ok, response}

          {:ok, %{"type" => "response", "id" => ^request_id, "success" => false, "error" => error}} ->
            {:error, {:rpc_command_failed, error}}

          {:ok, %{"type" => "response"}} ->
            await_response(port, request_id, timeout_ms, "")

          {:ok, %{"type" => "extension_ui_request"} = payload} ->
            auto_cancel_inline(port, payload)
            await_response(port, request_id, timeout_ms, "")

          {:ok, _payload} ->
            await_response(port, request_id, timeout_ms, "")

          {:error, _reason} ->
            await_response(port, request_id, timeout_ms, "")
        end

      {^port, {:data, {:noeol, chunk}}} ->
        await_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp session_identity_from_response(%{"data" => %{"sessionId" => session_id} = data}) when is_binary(session_id) do
    {:ok, session_id, Map.get(data, "sessionFile")}
  end

  defp session_identity_from_response(response), do: {:error, {:invalid_get_state_response, response}}

  defp auto_cancel_inline(port, %{"id" => request_id, "method" => method})
       when method in ["select", "confirm", "input", "editor"] do
    send_message(port, %{"type" => "extension_ui_response", "id" => request_id, "cancelled" => true})
  end

  defp auto_cancel_inline(_port, _payload), do: :ok

  defp build_command(session_dir) do
    settings = Config.settings!()
    pi = settings.pi

    flags =
      [
        pi.command,
        "--mode rpc",
        "--session-dir #{shell_escape(session_dir)}",
        pi.disable_extensions && "--no-extensions",
        pi.disable_themes && "--no-themes"
      ] ++ Enum.map(pi.extension_paths, &"--extension #{shell_escape(&1)}")

    flags =
      flags
      |> Enum.reject(&(&1 in [nil, false, ""]))
      |> Enum.join(" ")

    # headless_git_env_assignments/0 always returns at least two entries,
    # so the combined list is guaranteed non-empty.
    all_assignments = headless_git_env_assignments() ++ tracker_env_assignments(settings)

    "exec env #{Enum.join(all_assignments, " ")} #{flags}"
  end

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} -> %{worker_pid: to_string(os_pid)}
        _ -> %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp unique_suffix do
    integer = System.unique_integer([:positive])
    Integer.to_string(integer)
  end

  # Prevent git from spawning interactive editors or terminal prompts
  # in headless worker environments. Without these, operations like
  # `git rebase --continue` open vi and block the process forever.
  # See: https://github.com/tmustier/pi-symphony/issues/58
  defp headless_git_env_assignments do
    [
      env_assignment("GIT_EDITOR", "true"),
      env_assignment("GIT_TERMINAL_PROMPT", "0")
    ]
  end

  defp tracker_env_assignments(settings) do
    tracker = settings.tracker

    [
      tracker.kind && env_assignment("PI_SYMPHONY_TRACKER_KIND", tracker.kind),
      tracker.endpoint && env_assignment("PI_SYMPHONY_LINEAR_ENDPOINT", tracker.endpoint),
      tracker.api_key && env_assignment("PI_SYMPHONY_LINEAR_API_KEY", tracker.api_key)
    ]
    |> Enum.reject(&(&1 in [nil, false, ""]))
  end

  defp env_assignment(key, value) when is_binary(key) and is_binary(value) do
    "#{key}=#{shell_escape(value)}"
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
