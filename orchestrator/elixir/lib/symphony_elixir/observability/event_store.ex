defmodule SymphonyElixir.Observability.EventStore do
  @moduledoc """
  Bounded in-memory event store for operator-facing observability timelines.

  The store keeps sanitized events only. It is intentionally a read model: callers
  can append facts and query them with cursor pagination, but orchestration state
  remains owned by the orchestrator.
  """

  use GenServer

  @default_max_global_events 5_000
  @default_max_events_per_issue 500
  @default_limit 100
  @max_limit 500
  @max_payload_bytes 4_096
  @max_string_bytes 1_000
  @max_map_entries 40
  @max_list_entries 25
  @sensitive_payload_keys [
    "authorization",
    "api_key",
    "apikey",
    "access_token",
    "refresh_token",
    "token",
    "secret",
    "password",
    "raw"
  ]

  @type event :: map()
  @type append_attrs :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       sequence: 0,
       events: [],
       max_global_events: Keyword.get(opts, :max_global_events, @default_max_global_events),
       max_events_per_issue: Keyword.get(opts, :max_events_per_issue, @default_max_events_per_issue)
     }}
  end

  @spec append(append_attrs(), GenServer.server()) :: {:ok, event()} | :unavailable
  def append(attrs, server \\ __MODULE__) when is_map(attrs) do
    safe_call(server, {:append, attrs}, :unavailable)
  end

  @spec append_worker_update(String.t(), String.t() | nil, map(), map(), GenServer.server()) ::
          {:ok, event()} | :unavailable
  def append_worker_update(issue_id, issue_identifier, update, running_entry, server \\ __MODULE__)
      when is_binary(issue_id) and is_map(update) and is_map(running_entry) do
    append(
      %{
        issue_id: issue_id,
        issue_identifier: issue_identifier,
        type: "worker",
        name: stringify(Map.get(update, :event) || Map.get(update, "event")),
        source: "pi",
        at: Map.get(update, :timestamp) || Map.get(update, "timestamp") || DateTime.utc_now(),
        session_id: Map.get(update, :session_id) || Map.get(update, "session_id") || Map.get(running_entry, :session_id),
        turn: Map.get(update, :turn) || Map.get(update, "turn"),
        severity: severity_for_worker_update(update),
        summary: worker_update_summary(update),
        payload: worker_update_payload(update)
      },
      server
    )
  end

  @spec append_phase_transition(map(), GenServer.server()) :: {:ok, event()} | :unavailable
  def append_phase_transition(transition, server \\ __MODULE__) when is_map(transition) do
    append(
      %{
        issue_id: Map.get(transition, :issue_id),
        issue_identifier: Map.get(transition, :issue_identifier),
        type: "phase",
        name: "phase.changed",
        source: Map.get(transition, :source, "poll_reconcile"),
        at: Map.get(transition, :at, DateTime.utc_now()),
        severity: "info",
        summary: transition_summary(transition),
        payload: Map.drop(transition, [:issue_id, :issue_identifier, :at])
      },
      server
    )
  end

  @spec list(keyword(), GenServer.server()) :: map()
  def list(opts \\ [], server \\ __MODULE__) do
    safe_call(server, {:list, opts}, empty_page(opts))
  end

  @spec list_for_issue(String.t(), keyword(), GenServer.server()) :: map()
  def list_for_issue(issue_identifier, opts \\ [], server \\ __MODULE__) when is_binary(issue_identifier) do
    opts
    |> Keyword.put(:issue_identifier, issue_identifier)
    |> list(server)
  end

  @spec clear(GenServer.server()) :: :ok | :unavailable
  def clear(server \\ __MODULE__) do
    safe_call(server, :clear, :unavailable)
  end

  @impl true
  def handle_call({:append, attrs}, _from, state) do
    sequence = state.sequence + 1

    event =
      attrs
      |> sanitize_event(sequence)
      |> Map.put(:sequence, sequence)
      |> Map.put(:id, event_id(sequence))

    events =
      state.events
      |> Kernel.++([event])
      |> trim_global(state.max_global_events)
      |> trim_per_issue(state.max_events_per_issue)

    {:reply, {:ok, event}, %{state | sequence: sequence, events: events}}
  end

  def handle_call({:list, opts}, _from, state) do
    {:reply, page_events(state.events, opts), state}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | sequence: 0, events: []}}
  end

  defp safe_call(server, message, fallback) do
    if server_available?(server) do
      GenServer.call(server, message)
    else
      fallback
    end
  catch
    :exit, _reason -> fallback
  end

  defp server_available?(server) when is_atom(server), do: Process.whereis(server) != nil
  defp server_available?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp server_available?(_server), do: false

  defp sanitize_event(attrs, sequence) do
    at = attrs |> Map.get(:at, DateTime.utc_now()) |> normalize_datetime()
    payload = attrs |> Map.get(:payload, %{}) |> sanitize_payload()

    %{
      at: at,
      type: attrs |> Map.get(:type, "system") |> stringify() |> bounded_string(80),
      name: attrs |> Map.get(:name, "event") |> stringify() |> bounded_string(160),
      source: attrs |> Map.get(:source, "symphony") |> stringify() |> bounded_string(80),
      severity: attrs |> Map.get(:severity, "info") |> stringify() |> bounded_string(40),
      summary: attrs |> Map.get(:summary) |> bounded_string(240),
      issue_id: attrs |> Map.get(:issue_id) |> bounded_string(160),
      issue_identifier: attrs |> Map.get(:issue_identifier) |> bounded_string(160),
      run_id: attrs |> Map.get(:run_id) |> bounded_string(240),
      session_id: attrs |> Map.get(:session_id) |> bounded_string(240),
      turn: normalize_scalar(Map.get(attrs, :turn), 0),
      payload: payload,
      redacted?: true
    }
    |> maybe_default_summary(sequence)
  end

  defp maybe_default_summary(%{summary: nil, name: name} = event, _sequence), do: %{event | summary: name}
  defp maybe_default_summary(event, _sequence), do: event

  defp page_events(events, opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> parse_limit()
    cursor_sequence = opts |> Keyword.get(:cursor) |> cursor_sequence()
    issue_identifier = Keyword.get(opts, :issue_identifier)
    types = opts |> Keyword.get(:types, Keyword.get(opts, :type)) |> parse_types()
    direction = opts |> Keyword.get(:direction, "forward") |> to_string()

    filtered =
      events
      |> Enum.filter(fn event ->
        issue_match?(event, issue_identifier) and type_match?(event, types) and cursor_match?(event, cursor_sequence, direction)
      end)
      |> maybe_reverse(direction)

    page = Enum.take(filtered, limit)
    next_cursor = page |> List.last() |> then(&(&1 && &1.id))

    %{
      events: page,
      page_info: %{
        next_cursor: next_cursor,
        has_next_page: length(filtered) > length(page)
      }
    }
  end

  defp empty_page(opts) do
    %{
      events: [],
      page_info: %{next_cursor: Keyword.get(opts, :cursor), has_next_page: false}
    }
  end

  defp issue_match?(_event, nil), do: true
  defp issue_match?(event, issue_identifier), do: event.issue_identifier == issue_identifier

  defp type_match?(_event, []), do: true
  defp type_match?(event, types), do: event.type in types

  defp cursor_match?(_event, nil, _direction), do: true
  defp cursor_match?(event, cursor_sequence, "backward"), do: event.sequence < cursor_sequence
  defp cursor_match?(event, cursor_sequence, _direction), do: event.sequence > cursor_sequence

  defp maybe_reverse(events, "backward"), do: Enum.reverse(events)
  defp maybe_reverse(events, _direction), do: events

  defp parse_limit(limit) when is_integer(limit), do: min(max(limit, 1), @max_limit)

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, _rest} -> parse_limit(value)
      :error -> @default_limit
    end
  end

  defp parse_limit(_limit), do: @default_limit

  defp parse_types(nil), do: []

  defp parse_types(types) when is_binary(types) do
    types
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_types(types) when is_list(types), do: types |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == ""))
  defp parse_types(type), do: [to_string(type)]

  defp cursor_sequence(nil), do: nil

  defp cursor_sequence("evt_" <> digits) do
    case Integer.parse(digits) do
      {value, _rest} -> value
      :error -> nil
    end
  end

  defp cursor_sequence(value) when is_integer(value), do: value
  defp cursor_sequence(_value), do: nil

  defp trim_global(events, max_events) when is_integer(max_events) and max_events > 0 do
    excess = length(events) - max_events
    if excess > 0, do: Enum.drop(events, excess), else: events
  end

  defp trim_global(events, _max_events), do: events

  defp trim_per_issue(events, max_events_per_issue) when is_integer(max_events_per_issue) and max_events_per_issue > 0 do
    {_counts, kept_reversed} =
      events
      |> Enum.reverse()
      |> Enum.reduce({%{}, []}, fn event, {counts, kept} ->
        issue_key = event.issue_identifier || "__global__"
        count = Map.get(counts, issue_key, 0)

        if count < max_events_per_issue do
          {Map.put(counts, issue_key, count + 1), [event | kept]}
        else
          {counts, kept}
        end
      end)

    kept_reversed
  end

  defp trim_per_issue(events, _max_events_per_issue), do: events

  defp event_id(sequence), do: "evt_" <> String.pad_leading(Integer.to_string(sequence), 10, "0")

  defp worker_update_summary(update) do
    event = Map.get(update, :event) || Map.get(update, "event")
    payload = Map.get(update, :payload) || Map.get(update, "payload")

    # Worker messages and payload deltas can contain arbitrary user/code content or
    # secrets. Keep summaries to structural fields that are already whitelisted in
    # the event payload rather than copying message text into the API response.
    [stringify(event), payload_type(payload), payload_event_type(payload)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(": ")
    |> case do
      "" -> nil
      summary -> bounded_string(summary, 240)
    end
  end

  defp worker_update_payload(update) do
    payload = Map.get(update, :payload) || Map.get(update, "payload")

    %{}
    |> maybe_put_safe(:event, Map.get(update, :event) || Map.get(update, "event"))
    |> maybe_put_safe(:session_id, Map.get(update, :session_id) || Map.get(update, "session_id"))
    |> maybe_put_safe(:turn, Map.get(update, :turn) || Map.get(update, "turn"))
    |> maybe_put_safe(:usage, safe_usage(Map.get(update, :usage) || Map.get(update, "usage")))
    |> maybe_put_safe(:payload_type, payload_type(payload))
    |> maybe_put_safe(:payload_event_type, payload_event_type(payload))
  end

  defp severity_for_worker_update(update) do
    case Map.get(update, :event) || Map.get(update, "event") do
      :malformed -> "warning"
      "malformed" -> "warning"
      :error -> "error"
      "error" -> "error"
      _ -> "info"
    end
  end

  defp transition_summary(%{from: from, to: to}), do: "#{from || "unknown"} → #{to || "unknown"}"
  defp transition_summary(_transition), do: "phase changed"

  defp maybe_put_safe(map, _key, nil), do: map
  defp maybe_put_safe(map, _key, %{} = value) when map_size(value) == 0, do: map
  defp maybe_put_safe(map, key, value), do: Map.put(map, key, value)

  defp safe_usage(%{} = usage) do
    usage
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key = stringify(key)

      if key in ["input", "output", "total", "inputTokens", "outputTokens", "totalTokens"] and is_number(value) do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp safe_usage(_usage), do: nil

  defp payload_type(%{"type" => type}), do: type
  defp payload_type(%{type: type}), do: type
  defp payload_type(_payload), do: nil

  defp payload_event_type(%{"assistantMessageEvent" => %{"type" => type}}), do: type
  defp payload_event_type(%{assistantMessageEvent: %{type: type}}), do: type
  defp payload_event_type(_payload), do: nil

  defp sanitize_payload(payload) do
    sanitized = sanitize_value(payload, 0)

    case Jason.encode(sanitized) do
      {:ok, encoded} when byte_size(encoded) <= @max_payload_bytes -> sanitized
      _ -> %{truncated: true, summary: sanitized |> inspect(limit: 20, printable_limit: 500) |> bounded_string(800)}
    end
  end

  defp sanitize_value(value, depth) when depth >= 4, do: bounded_string(inspect(value), 200)

  defp sanitize_value(%DateTime{} = value, _depth), do: DateTime.to_iso8601(value)

  defp sanitize_value(value, depth) when is_map(value) do
    value
    |> Enum.take(@max_map_entries)
    |> Map.new(fn {key, nested} ->
      key = stringify(key)

      if sensitive_payload_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, sanitize_value(nested, depth + 1)}
      end
    end)
  end

  defp sanitize_value(value, depth) when is_list(value) do
    value
    |> Enum.take(@max_list_entries)
    |> Enum.map(&sanitize_value(&1, depth + 1))
  end

  defp sanitize_value(value, _depth), do: normalize_scalar(value, @max_string_bytes)

  defp sensitive_payload_key?(key) when is_binary(key), do: String.downcase(key) in @sensitive_payload_keys
  defp sensitive_payload_key?(_key), do: false

  defp normalize_scalar(value, max_bytes) when is_binary(value), do: bounded_string(value, max_bytes)
  defp normalize_scalar(value, _max_bytes) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp normalize_scalar(value, _max_bytes) when is_atom(value), do: Atom.to_string(value)
  defp normalize_scalar(%DateTime{} = value, _max_bytes), do: DateTime.to_iso8601(value)
  defp normalize_scalar(value, max_bytes), do: value |> inspect(limit: 10, printable_limit: max_bytes) |> bounded_string(max_bytes)

  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp stringify(value), do: inspect(value, limit: 10, printable_limit: 500)

  defp bounded_string(nil, _max_bytes), do: nil

  defp bounded_string(value, max_bytes) when is_binary(value) do
    if byte_size(value) <= max_bytes do
      value
    else
      value
      |> String.slice(0, max_bytes)
      |> Kernel.<>("…")
    end
  end

  defp bounded_string(value, max_bytes), do: value |> stringify() |> bounded_string(max_bytes)

  defp normalize_datetime(%DateTime{} = datetime), do: DateTime.truncate(datetime, :second)

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp normalize_datetime(_value), do: DateTime.utc_now() |> DateTime.truncate(:second)
end
