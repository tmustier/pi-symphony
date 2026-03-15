defmodule SymphonyElixir.Pi.EventMapper do
  @moduledoc """
  Maps Pi RPC events into the smallest Codex-compatible update shape the current
  orchestrator can consume.
  """

  @type metadata :: map()
  @type payload :: map()
  @type mapped_update :: map()

  @spec session_started(String.t(), metadata()) :: mapped_update()
  def session_started(session_id, metadata \\ %{}) when is_binary(session_id) and is_map(metadata) do
    metadata
    |> Map.put(:session_id, session_id)
    |> Map.put(:event, :session_started)
    |> Map.put(:timestamp, DateTime.utc_now())
  end

  @spec heartbeat(String.t(), metadata()) :: mapped_update()
  def heartbeat(session_id, metadata \\ %{}) when is_binary(session_id) and is_map(metadata) do
    metadata
    |> Map.put(:session_id, session_id)
    |> Map.put(:event, :heartbeat)
    |> Map.put(:timestamp, DateTime.utc_now())
  end

  @spec rpc_event(payload(), String.t(), String.t(), metadata()) :: mapped_update()
  def rpc_event(payload, raw, session_id, metadata \\ %{})
      when is_map(payload) and is_binary(raw) and is_binary(session_id) and is_map(metadata) do
    event = map_rpc_event(payload)

    metadata
    |> Map.put(:session_id, session_id)
    |> maybe_put_usage(extract_usage(payload))
    |> Map.merge(%{
      event: event,
      payload: payload,
      raw: raw,
      timestamp: DateTime.utc_now()
    })
  end

  @spec extension_ui_request(payload(), String.t(), String.t(), metadata()) :: mapped_update()
  def extension_ui_request(payload, raw, session_id, metadata \\ %{})
      when is_map(payload) and is_binary(raw) and is_binary(session_id) and is_map(metadata) do
    metadata
    |> Map.put(:session_id, session_id)
    |> Map.merge(%{
      event: :notification,
      payload: payload,
      raw: raw,
      timestamp: DateTime.utc_now()
    })
  end

  @spec malformed(String.t(), String.t(), metadata()) :: mapped_update()
  def malformed(raw, session_id, metadata \\ %{})
      when is_binary(raw) and is_binary(session_id) and is_map(metadata) do
    metadata
    |> Map.put(:session_id, session_id)
    |> Map.merge(%{
      event: :malformed,
      raw: raw,
      payload: raw,
      timestamp: DateTime.utc_now()
    })
  end

  defp map_rpc_event(%{"type" => "turn_end"}), do: :turn_completed
  defp map_rpc_event(%{type: "turn_end"}), do: :turn_completed
  defp map_rpc_event(_payload), do: :notification

  defp maybe_put_usage(metadata, %{} = usage), do: Map.put(metadata, :usage, usage)
  defp maybe_put_usage(metadata, _usage), do: metadata

  defp extract_usage(%{"message" => %{"usage" => %{} = usage}}), do: usage
  defp extract_usage(%{message: %{usage: %{} = usage}}), do: usage

  defp extract_usage(%{"messages" => messages}) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(&assistant_usage/1)
  end

  defp extract_usage(%{messages: messages}) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(&assistant_usage/1)
  end

  defp extract_usage(_payload), do: nil

  defp assistant_usage(%{"role" => "assistant", "usage" => %{} = usage}), do: usage
  defp assistant_usage(%{role: "assistant", usage: %{} = usage}), do: usage
  defp assistant_usage(_message), do: nil
end
