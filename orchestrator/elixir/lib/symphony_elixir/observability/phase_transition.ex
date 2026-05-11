defmodule SymphonyElixir.Observability.PhaseTransition do
  @moduledoc """
  Builds phase-transition observability events from tracked issue snapshots.
  """

  import SymphonyElixir.MapUtils, only: [fetch_value: 2]

  @tracked_change_keys [:phase, :waiting_reason, :next_intended_action, :state, :dispatch_allowed, :passive_phase]

  @spec transitions_from_tracked_update(map(), map()) :: [map()]
  def transitions_from_tracked_update(previous_tracked, current_tracked) do
    transitions_from_tracked_update(previous_tracked, current_tracked, [])
  end

  @spec transitions_from_tracked_update(map(), map(), keyword()) :: [map()]
  def transitions_from_tracked_update(previous_tracked, current_tracked, opts)
      when is_map(previous_tracked) and is_map(current_tracked) do
    at = Keyword.get(opts, :at, DateTime.utc_now() |> DateTime.truncate(:second))
    source = Keyword.get(opts, :source, "poll_reconcile")

    current_tracked
    |> Enum.flat_map(fn {issue_id, current_entry} ->
      previous_entry = Map.get(previous_tracked, issue_id)
      transition_for(issue_id, previous_entry, current_entry, at, source)
    end)
  end

  def transitions_from_tracked_update(_previous_tracked, _current_tracked, _opts), do: []

  @spec transition_for(String.t(), map() | nil, map(), DateTime.t(), String.t()) :: [map()]
  def transition_for(issue_id, previous_entry, current_entry, at, source)
      when is_binary(issue_id) and is_map(previous_entry) and is_map(current_entry) do
    if changed?(previous_entry, current_entry) do
      issue_identifier = fetch_value(current_entry, :issue_identifier) || fetch_value(previous_entry, :issue_identifier)

      [
        %{
          issue_id: issue_id,
          issue_identifier: issue_identifier,
          at: at,
          from: fetch_value(previous_entry, :phase),
          to: fetch_value(current_entry, :phase),
          tracker_state_from: fetch_value(previous_entry, :state),
          tracker_state_to: fetch_value(current_entry, :state),
          waiting_reason: fetch_value(current_entry, :waiting_reason),
          previous_waiting_reason: fetch_value(previous_entry, :waiting_reason),
          next_intended_action: fetch_value(current_entry, :next_intended_action),
          previous_next_intended_action: fetch_value(previous_entry, :next_intended_action),
          dispatch_allowed: fetch_value(current_entry, :dispatch_allowed),
          previous_dispatch_allowed: fetch_value(previous_entry, :dispatch_allowed),
          passive_phase: fetch_value(current_entry, :passive_phase),
          previous_passive_phase: fetch_value(previous_entry, :passive_phase),
          source: source,
          workpad_comment_id: workpad_comment_id(current_entry)
        }
      ]
    else
      []
    end
  end

  def transition_for(_issue_id, _previous_entry, _current_entry, _at, _source), do: []

  @spec transition_payload(map()) :: map()
  def transition_payload(event) when is_map(event) do
    payload = Map.get(event, :payload, %{})

    %{
      id: Map.get(event, :id),
      at: event |> Map.get(:at) |> iso8601(),
      from: payload_value(payload, :from),
      to: payload_value(payload, :to),
      tracker_state_from: payload_value(payload, :tracker_state_from),
      tracker_state_to: payload_value(payload, :tracker_state_to),
      waiting_reason: payload_value(payload, :waiting_reason),
      next_intended_action: payload_value(payload, :next_intended_action),
      source: payload_value(payload, :source),
      workpad_comment_id: payload_value(payload, :workpad_comment_id)
    }
  end

  defp changed?(previous_entry, current_entry) do
    Enum.any?(@tracked_change_keys, fn key -> fetch_value(previous_entry, key) != fetch_value(current_entry, key) end)
  end

  defp workpad_comment_id(entry) do
    entry
    |> fetch_value(:workpad)
    |> fetch_value(:comment_id)
  end

  defp payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp payload_value(_payload, _key), do: nil

  defp iso8601(%DateTime{} = datetime), do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(_value), do: nil
end
