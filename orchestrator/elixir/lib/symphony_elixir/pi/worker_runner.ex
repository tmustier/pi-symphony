defmodule SymphonyElixir.Pi.WorkerRunner do
  @moduledoc """
  Pi-backed replacement for the Codex app-server worker runtime.

  The public interface intentionally mirrors `SymphonyElixir.Codex.AppServer`
  closely so `AgentRunner` can switch runtimes with minimal change.
  """

  require Logger

  alias SymphonyElixir.Pi.{EventMapper, RpcClient}

  @spec start_session(Path.t(), keyword()) :: {:ok, RpcClient.session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    RpcClient.start_session(workspace, opts)
  end

  @spec run_turn(RpcClient.session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_number = Keyword.get(opts, :turn_number, 1)
    turn_session_id = turn_session_id(session.base_session_id, turn_number)

    with :ok <- RpcClient.configure_turn(session, %{name: session_name(issue)}),
         {:ok, _prompt_id} <- RpcClient.start_prompt(session, prompt) do
      emit(on_message, EventMapper.session_started(turn_session_id, session.metadata))
      await_turn_completion(session, turn_session_id, on_message, issue)
    end
  end

  @spec stop_session(RpcClient.session()) :: :ok
  def stop_session(session) do
    RpcClient.stop_session(session)
  end

  defp await_turn_completion(session, turn_session_id, on_message, issue) do
    timeout_ms = issue_turn_timeout_ms()
    receive_loop(session, turn_session_id, on_message, issue, timeout_ms, "")
  end

  defp receive_loop(session, turn_session_id, on_message, issue, timeout_ms, pending_line) do
    case RpcClient.receive_message(session, timeout_ms, pending_line) do
      {:ok, {:response, _response}, next_pending_line} ->
        emit(on_message, EventMapper.heartbeat(turn_session_id, session.metadata))
        receive_loop(session, turn_session_id, on_message, issue, timeout_ms, next_pending_line)

      {:ok, {:extension_ui_request, payload}, next_pending_line} ->
        :ok = RpcClient.auto_cancel_extension_request(session, payload)
        emit(on_message, EventMapper.extension_ui_request(payload, Jason.encode!(payload), turn_session_id, session.metadata))
        receive_loop(session, turn_session_id, on_message, issue, timeout_ms, next_pending_line)

      {:ok, {:event, %{"type" => "agent_end"} = payload}, _next_pending_line} ->
        emit(on_message, EventMapper.rpc_event(payload, Jason.encode!(payload), turn_session_id, session.metadata))

        Logger.info("Pi worker turn completed for #{issue_context(issue)} session_id=#{turn_session_id} session_file=#{inspect(session.session_file)}")

        {:ok,
         %{
           result: payload,
           session_id: turn_session_id,
           base_session_id: session.base_session_id,
           session_file: session.session_file
         }}

      {:ok, {:event, payload}, next_pending_line} ->
        emit(on_message, EventMapper.rpc_event(payload, Jason.encode!(payload), turn_session_id, session.metadata))
        receive_loop(session, turn_session_id, on_message, issue, timeout_ms, next_pending_line)

      {:ok, {:malformed, raw}, next_pending_line} ->
        emit(on_message, EventMapper.malformed(raw, turn_session_id, session.metadata))
        receive_loop(session, turn_session_id, on_message, issue, timeout_ms, next_pending_line)

      {:error, :timeout} ->
        :ok = maybe_abort(session)
        {:error, :turn_timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_abort(session) do
    case RpcClient.abort(session) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp issue_turn_timeout_ms do
    SymphonyElixir.Config.settings!().codex.turn_timeout_ms
  end

  defp turn_session_id(base_session_id, turn_number) when is_binary(base_session_id) and is_integer(turn_number) do
    "#{base_session_id}-turn-#{turn_number}"
  end

  defp session_name(%{identifier: identifier, title: title}) when is_binary(identifier) and is_binary(title) do
    "#{identifier}: #{title}"
  end

  defp session_name(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp session_name(_issue), do: "pi-worker-run"

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_issue), do: "issue_id=n/a issue_identifier=n/a"

  defp emit(on_message, message) when is_function(on_message, 1) and is_map(message) do
    on_message.(message)
  end

  defp default_on_message(_message), do: :ok
end
