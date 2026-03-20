defmodule SymphonyElixir.MergeQueueTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.MergeQueue

  test "preserves first enqueue time while refreshing priority and pr context" do
    queue =
      %{}
      |> MergeQueue.add("issue-1", %{number: 101}, 3, issue_identifier: "MT-101", enqueued_at_ms: 100)
      |> MergeQueue.add("issue-1", %{number: 101, expected_head_sha: "abc123"}, 1,
        issue_identifier: "MT-101",
        enqueued_at_ms: 999
      )

    assert [%{issue_id: "issue-1", priority: 1, enqueued_at_ms: 100, pr_context: %{expected_head_sha: "abc123"}}] =
             MergeQueue.ordered_entries(queue)
  end

  test "orders by priority before enqueue time" do
    queue =
      %{}
      |> MergeQueue.add("issue-2", %{number: 202}, 4, issue_identifier: "MT-202", enqueued_at_ms: 200)
      |> MergeQueue.add("issue-1", %{number: 201}, 1, issue_identifier: "MT-201", enqueued_at_ms: 300)
      |> MergeQueue.add("issue-3", %{number: 203}, 1, issue_identifier: "MT-203", enqueued_at_ms: 400)

    assert [
             %{issue_id: "issue-1"},
             %{issue_id: "issue-3"},
             %{issue_id: "issue-2"}
           ] = MergeQueue.ordered_entries(queue)
  end

  test "take_next pops the highest-priority entry" do
    queue =
      %{}
      |> MergeQueue.add("issue-1", %{number: 101}, 2, issue_identifier: "MT-101", enqueued_at_ms: 100)
      |> MergeQueue.add("issue-2", %{number: 102}, 1, issue_identifier: "MT-102", enqueued_at_ms: 200)

    assert {%{issue_id: "issue-2"}, next_queue} = MergeQueue.take_next(queue)
    assert MergeQueue.member?(next_queue, "issue-1")
    refute MergeQueue.member?(next_queue, "issue-2")
    assert MergeQueue.size(next_queue) == 1
  end
end
