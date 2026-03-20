defmodule SymphonyElixir.MergeQueue do
  @moduledoc """
  Priority queue for serialized orchestrator-owned merges.

  Stored as a map keyed by issue id so entries can be refreshed idempotently on
  every poll cycle while preserving first-enqueue order.
  """

  @type queue_entry :: %{
          required(:issue_id) => String.t(),
          required(:pr_context) => map(),
          required(:priority) => integer(),
          required(:enqueued_at_ms) => integer(),
          optional(:issue_identifier) => String.t() | nil
        }

  @type t :: %{optional(String.t()) => queue_entry()}

  @spec add(t(), String.t(), map(), integer(), keyword()) :: t()
  def add(queue, issue_id, pr_context, priority, opts \\ [])
      when is_map(queue) and is_binary(issue_id) and is_map(pr_context) and is_integer(priority) do
    existing = Map.get(queue, issue_id, %{})
    enqueued_at_ms = Map.get(existing, :enqueued_at_ms) || Keyword.get(opts, :enqueued_at_ms) || System.monotonic_time(:millisecond)

    Map.put(queue, issue_id, %{
      issue_id: issue_id,
      issue_identifier: Keyword.get(opts, :issue_identifier) || Map.get(existing, :issue_identifier),
      pr_context: pr_context,
      priority: priority,
      enqueued_at_ms: enqueued_at_ms
    })
  end

  @spec remove(t(), String.t()) :: t()
  def remove(queue, issue_id) when is_map(queue) and is_binary(issue_id) do
    Map.delete(queue, issue_id)
  end

  @spec member?(t(), String.t()) :: boolean()
  def member?(queue, issue_id) when is_map(queue) and is_binary(issue_id) do
    Map.has_key?(queue, issue_id)
  end

  @spec size(t()) :: non_neg_integer()
  def size(queue) when is_map(queue), do: map_size(queue)

  @spec ordered_entries(t()) :: [queue_entry()]
  def ordered_entries(queue) when is_map(queue) do
    queue
    |> Map.values()
    |> Enum.sort_by(fn entry ->
      {
        Map.get(entry, :priority, 5),
        Map.get(entry, :enqueued_at_ms, 0),
        Map.get(entry, :issue_identifier) || Map.get(entry, :issue_id) || ""
      }
    end)
  end

  @spec take_next(t()) :: {queue_entry(), t()} | :empty
  def take_next(queue) when is_map(queue) do
    case ordered_entries(queue) do
      [%{issue_id: issue_id} = entry | _rest] ->
        {entry, Map.delete(queue, issue_id)}

      [] ->
        :empty
    end
  end
end
