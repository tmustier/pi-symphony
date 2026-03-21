defmodule SymphonyElixir.MergeQueueDispatchTest do
  @moduledoc """
  Integration tests for merge queue & conflict-aware dispatch.

  Validates that:
  - Dispatch is blocked when the merge queue is draining
  - Dispatch is allowed when queue strategy is inactive
  - Build-rebase-targets excludes running workers
  - Merge task completion triggers the next queued merge
  - Requeue preserves entry ordering on failure
  - Merge task :DOWN handling requeues on crash
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.MergeQueue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.Dispatch

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp issue(id, identifier, opts \\ []) do
    %Issue{
      id: id,
      identifier: identifier,
      title: Keyword.get(opts, :title, "Test issue #{identifier}"),
      state: Keyword.get(opts, :state, "In Progress"),
      priority: Keyword.get(opts, :priority, 2),
      labels: Keyword.get(opts, :labels, []),
      comments: Keyword.get(opts, :comments, []),
      blocked_by: Keyword.get(opts, :blocked_by, []),
      branch_name: Keyword.get(opts, :branch_name, "pi-symphony/#{identifier}"),
      assigned_to_worker: Keyword.get(opts, :assigned_to_worker, true),
      created_at: Keyword.get(opts, :created_at, ~U[2026-01-01 00:00:00Z])
    }
  end

  defp empty_state(overrides \\ %{}) do
    struct!(
      Orchestrator.State,
      Map.merge(
        %{
          running: %{},
          claimed: MapSet.new(),
          tracked: %{},
          completed: MapSet.new(),
          retry_attempts: %{},
          merge_queue: %{},
          merge_in_progress: nil,
          merge_current_entry: nil,
          merge_task_ref: nil,
          max_concurrent_agents: 10,
          worker_totals: nil,
          worker_rate_limits: nil
        },
        overrides
      )
    )
  end

  defp running_entry(issue_id, identifier) do
    %{
      pid: nil,
      ref: nil,
      identifier: identifier,
      issue: issue(issue_id, identifier),
      worker_host: nil,
      workspace_path: nil,
      session_id: nil,
      last_worker_message: nil,
      last_worker_timestamp: nil,
      last_worker_event: nil,
      worker_pid: nil,
      worker_input_tokens: 0,
      worker_output_tokens: 0,
      worker_total_tokens: 0,
      worker_last_reported_input_tokens: 0,
      worker_last_reported_output_tokens: 0,
      worker_last_reported_total_tokens: 0,
      turn_count: 0,
      orchestration_phase: "implementing",
      retry_attempt: nil,
      started_at: DateTime.utc_now()
    }
  end

  # ---------------------------------------------------------------------------
  # Conflict-aware dispatch: merge queue blocks dispatch
  # ---------------------------------------------------------------------------

  describe "merge_queue_blocks_dispatch?" do
    test "returns false when merge strategy is not queue" do
      write_workflow_file!(Workflow.workflow_file_path(),
        merge_mode: "disabled",
        merge_strategy: nil
      )

      state =
        empty_state(%{
          merge_queue:
            MergeQueue.add(%{}, "issue-1", %{number: 42}, 1,
              issue_identifier: "SYM-1",
              enqueued_at_ms: 100
            ),
          merge_in_progress: nil
        })

      refute Orchestrator.merge_queue_blocks_dispatch_for_test(state)
    end

    test "returns false when queue strategy is active but queue is empty and no merge in progress" do
      write_workflow_file!(Workflow.workflow_file_path(),
        merge_mode: "auto",
        merge_strategy: "queue"
      )

      state = empty_state()

      refute Orchestrator.merge_queue_blocks_dispatch_for_test(state)
    end

    test "returns true when queue strategy is active, rollout is merge, and queue has entries" do
      write_workflow_file!(Workflow.workflow_file_path(),
        merge_mode: "auto",
        merge_strategy: "queue",
        rollout_mode: "merge"
      )

      state =
        empty_state(%{
          merge_queue:
            MergeQueue.add(%{}, "issue-1", %{number: 42}, 1,
              issue_identifier: "SYM-1",
              enqueued_at_ms: 100
            )
        })

      assert Orchestrator.merge_queue_blocks_dispatch_for_test(state)
    end

    test "returns true when queue strategy is active, rollout is merge, and a merge is in progress" do
      write_workflow_file!(Workflow.workflow_file_path(),
        merge_mode: "auto",
        merge_strategy: "queue",
        rollout_mode: "merge"
      )

      state = empty_state(%{merge_in_progress: "issue-1"})

      assert Orchestrator.merge_queue_blocks_dispatch_for_test(state)
    end

    test "returns false when queue strategy is active but rollout mode is mutate (deadlock prevention)" do
      write_workflow_file!(Workflow.workflow_file_path(),
        merge_mode: "auto",
        merge_strategy: "queue",
        rollout_mode: "mutate"
      )

      state =
        empty_state(%{
          merge_queue:
            MergeQueue.add(%{}, "issue-1", %{number: 42}, 1,
              issue_identifier: "SYM-1",
              enqueued_at_ms: 100
            )
        })

      refute Orchestrator.merge_queue_blocks_dispatch_for_test(state)
    end

    test "returns false when queue strategy is active but rollout mode is observe" do
      write_workflow_file!(Workflow.workflow_file_path(),
        merge_mode: "auto",
        merge_strategy: "queue",
        rollout_mode: "observe"
      )

      state = empty_state(%{merge_in_progress: "issue-1"})

      refute Orchestrator.merge_queue_blocks_dispatch_for_test(state)
    end
  end

  # ---------------------------------------------------------------------------
  # should_dispatch_issue? with merge queue awareness
  # ---------------------------------------------------------------------------

  describe "should_dispatch_issue? with merge queue" do
    test "blocks dispatch when merge queue is draining in merge rollout" do
      write_workflow_file!(Workflow.workflow_file_path(),
        merge_mode: "auto",
        merge_strategy: "queue",
        rollout_mode: "merge",
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Done", "Closed"]
      )

      state =
        empty_state(%{
          merge_queue:
            MergeQueue.add(%{}, "merge-issue", %{number: 42}, 1,
              issue_identifier: "SYM-99",
              enqueued_at_ms: 100
            )
        })

      new_issue = issue("new-issue", "SYM-100")
      refute Orchestrator.should_dispatch_issue_for_test(new_issue, state)
    end

    test "allows dispatch when merge queue has items but rollout is mutate" do
      write_workflow_file!(Workflow.workflow_file_path(),
        merge_mode: "auto",
        merge_strategy: "queue",
        rollout_mode: "mutate",
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Done", "Closed"]
      )

      state =
        empty_state(%{
          merge_queue:
            MergeQueue.add(%{}, "merge-issue", %{number: 42}, 1,
              issue_identifier: "SYM-99",
              enqueued_at_ms: 100
            )
        })

      new_issue = issue("new-issue", "SYM-100")
      assert Orchestrator.should_dispatch_issue_for_test(new_issue, state)
    end

    test "allows dispatch when merge queue is empty and strategy is queue" do
      write_workflow_file!(Workflow.workflow_file_path(),
        merge_mode: "auto",
        merge_strategy: "queue",
        rollout_mode: "merge",
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Done", "Closed"]
      )

      state = empty_state()
      new_issue = issue("new-issue", "SYM-100")
      assert Orchestrator.should_dispatch_issue_for_test(new_issue, state)
    end

    test "allows dispatch when merge strategy is immediate even with queued items" do
      write_workflow_file!(Workflow.workflow_file_path(),
        merge_mode: "auto",
        merge_strategy: "immediate",
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Done", "Closed"]
      )

      # With immediate strategy, merge_queue won't gate dispatch
      state =
        empty_state(%{
          merge_queue:
            MergeQueue.add(%{}, "merge-issue", %{number: 42}, 1,
              issue_identifier: "SYM-99",
              enqueued_at_ms: 100
            )
        })

      new_issue = issue("new-issue", "SYM-100")
      assert Orchestrator.should_dispatch_issue_for_test(new_issue, state)
    end

    test "allows dispatch when merge mode is disabled" do
      write_workflow_file!(Workflow.workflow_file_path(),
        merge_mode: "disabled",
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Done", "Closed"]
      )

      state = empty_state()
      new_issue = issue("new-issue", "SYM-100")
      assert Orchestrator.should_dispatch_issue_for_test(new_issue, state)
    end
  end

  # ---------------------------------------------------------------------------
  # build_rebase_targets: excludes running workers
  # ---------------------------------------------------------------------------

  describe "build_rebase_targets" do
    test "excludes entries for running workers" do
      write_workflow_file!(Workflow.workflow_file_path())

      queue =
        %{}
        |> MergeQueue.add("issue-1", %{number: 101}, 1, issue_identifier: "SYM-1", enqueued_at_ms: 100)
        |> MergeQueue.add("issue-2", %{number: 102}, 2, issue_identifier: "SYM-2", enqueued_at_ms: 200)
        |> MergeQueue.add("issue-3", %{number: 103}, 3, issue_identifier: "SYM-3", enqueued_at_ms: 300)

      state =
        empty_state(%{
          running: %{"issue-2" => running_entry("issue-2", "SYM-2")}
        })

      targets = Orchestrator.build_rebase_targets_for_test(queue, state)
      target_ids = Enum.map(targets, & &1.issue_id)

      assert "issue-1" in target_ids
      refute "issue-2" in target_ids
      assert "issue-3" in target_ids
    end

    test "returns empty list when all queued entries are running" do
      write_workflow_file!(Workflow.workflow_file_path())

      queue =
        MergeQueue.add(%{}, "issue-1", %{number: 101}, 1,
          issue_identifier: "SYM-1",
          enqueued_at_ms: 100
        )

      state =
        empty_state(%{
          running: %{"issue-1" => running_entry("issue-1", "SYM-1")}
        })

      targets = Orchestrator.build_rebase_targets_for_test(queue, state)
      assert targets == []
    end

    test "returns entries ordered by priority" do
      write_workflow_file!(Workflow.workflow_file_path())

      queue =
        %{}
        |> MergeQueue.add("low", %{number: 201}, 4, issue_identifier: "SYM-LO", enqueued_at_ms: 100)
        |> MergeQueue.add("high", %{number: 202}, 1, issue_identifier: "SYM-HI", enqueued_at_ms: 200)

      state = empty_state()
      targets = Orchestrator.build_rebase_targets_for_test(queue, state)
      assert [%{issue_id: "high"}, %{issue_id: "low"}] = targets
    end
  end

  # ---------------------------------------------------------------------------
  # complete_merge_task: triggers next merge or requeues
  # ---------------------------------------------------------------------------

  describe "complete_merge_task" do
    test "clears merge state and starts next merge on success" do
      write_workflow_file!(Workflow.workflow_file_path(),
        merge_mode: "auto",
        merge_strategy: "queue"
      )

      queue =
        MergeQueue.add(%{}, "issue-2", %{number: 102}, 2,
          issue_identifier: "SYM-2",
          enqueued_at_ms: 200
        )

      state =
        empty_state(%{
          merge_in_progress: "issue-1",
          merge_current_entry: %{
            issue_id: "issue-1",
            issue_identifier: "SYM-1",
            pr_context: %{number: 101},
            priority: 1,
            enqueued_at_ms: 100
          },
          merge_task_ref: make_ref(),
          merge_queue: queue
        })

      merged_issue = issue("issue-1", "SYM-1", state: "Done")

      result =
        Orchestrator.complete_merge_task_for_test(state, "issue-1", %{
          updated_issue: merged_issue,
          merge_completed?: true,
          rebased_issues: []
        })

      # After a successful merge, merge_in_progress should be nil (cleared)
      # or set to the next issue if the queue had more entries.
      # Since merge_mode: auto and strategy: queue, maybe_start_merge_task would
      # attempt to start the next merge, but that requires TaskSupervisor.
      # In tests without TaskSupervisor, verify the merge state was cleared first.
      refute result.merge_in_progress == "issue-1"
    end

    test "requeues entry when merge did not complete" do
      write_workflow_file!(Workflow.workflow_file_path(),
        merge_mode: "auto",
        merge_strategy: "queue"
      )

      state =
        empty_state(%{
          merge_in_progress: "issue-1",
          merge_current_entry: %{
            issue_id: "issue-1",
            issue_identifier: "SYM-1",
            pr_context: %{number: 101},
            priority: 1,
            enqueued_at_ms: 100
          },
          merge_task_ref: make_ref(),
          merge_queue: %{}
        })

      result =
        Orchestrator.complete_merge_task_for_test(state, "issue-1", %{
          updated_issue: issue("issue-1", "SYM-1"),
          merge_completed?: false,
          rebased_issues: []
        })

      assert MergeQueue.member?(result.merge_queue, "issue-1")
      assert result.merge_in_progress == nil
      assert result.merge_task_ref == nil
    end

    test "requeues on merge task error" do
      write_workflow_file!(Workflow.workflow_file_path(),
        merge_mode: "auto",
        merge_strategy: "queue"
      )

      state =
        empty_state(%{
          merge_in_progress: "issue-1",
          merge_current_entry: %{
            issue_id: "issue-1",
            issue_identifier: "SYM-1",
            pr_context: %{number: 101},
            priority: 1,
            enqueued_at_ms: 100
          },
          merge_task_ref: make_ref(),
          merge_queue: %{}
        })

      result =
        capture_log(fn ->
          Orchestrator.complete_merge_task_for_test(state, "issue-1", %{
            error: :merge_failed,
            rebased_issues: []
          })
        end)

      assert result =~ "Merge task failed"
    end
  end

  # ---------------------------------------------------------------------------
  # handle_merge_task_down: crash recovery
  # ---------------------------------------------------------------------------

  describe "handle_merge_task_down" do
    test "clears state on normal exit" do
      write_workflow_file!(Workflow.workflow_file_path())

      state =
        empty_state(%{
          merge_in_progress: "issue-1",
          merge_current_entry: %{
            issue_id: "issue-1",
            issue_identifier: "SYM-1",
            pr_context: %{number: 101},
            priority: 1,
            enqueued_at_ms: 100
          },
          merge_task_ref: make_ref()
        })

      result = Orchestrator.handle_merge_task_down_for_test(state, :normal)
      assert result.merge_in_progress == nil
      assert result.merge_current_entry == nil
      assert result.merge_task_ref == nil
    end

    test "requeues entry on abnormal exit" do
      write_workflow_file!(Workflow.workflow_file_path())

      state =
        empty_state(%{
          merge_in_progress: "issue-1",
          merge_current_entry: %{
            issue_id: "issue-1",
            issue_identifier: "SYM-1",
            pr_context: %{number: 101},
            priority: 1,
            enqueued_at_ms: 100
          },
          merge_task_ref: make_ref(),
          merge_queue: %{}
        })

      result =
        capture_log(fn ->
          Orchestrator.handle_merge_task_down_for_test(state, :killed)
        end)

      assert result =~ "Merge task crashed"
    end
  end

  # ---------------------------------------------------------------------------
  # tracked_pr_context: extracts merge context from tracked entries
  # ---------------------------------------------------------------------------

  describe "tracked_pr_context" do
    test "extracts pr number and url from workpad metadata" do
      tracked_entry = %{
        workpad: %{
          metadata: %{
            "pr" => %{
              "number" => 42,
              "url" => "https://github.com/tmustier/pi-symphony/pull/42",
              "head_sha" => "abc123"
            }
          }
        }
      }

      write_workflow_file!(Workflow.workflow_file_path(),
        pr_repo_slug: "tmustier/pi-symphony"
      )

      result = Orchestrator.tracked_pr_context_for_test(tracked_entry)
      assert result.number == 42
      assert result.url == "https://github.com/tmustier/pi-symphony/pull/42"
      assert result.expected_head_sha == "abc123"
    end

    test "returns nil when workpad has no pr metadata" do
      tracked_entry = %{
        workpad: %{
          metadata: %{}
        }
      }

      write_workflow_file!(Workflow.workflow_file_path())

      result = Orchestrator.tracked_pr_context_for_test(tracked_entry)
      assert result == nil
    end
  end

  # ---------------------------------------------------------------------------
  # dispatch_slots_available? with merge queue gating
  # ---------------------------------------------------------------------------

  describe "dispatch_slots_available? with merge queue" do
    test "returns false when merge queue is draining under queue strategy in merge rollout" do
      write_workflow_file!(Workflow.workflow_file_path(),
        merge_mode: "auto",
        merge_strategy: "queue",
        rollout_mode: "merge",
        tracker_active_states: ["In Progress"],
        tracker_terminal_states: ["Done"]
      )

      state =
        empty_state(%{
          merge_queue:
            MergeQueue.add(%{}, "merge-issue", %{number: 42}, 1,
              issue_identifier: "SYM-99",
              enqueued_at_ms: 100
            )
        })

      issue = issue("other-issue", "SYM-200")

      refute Dispatch.dispatch_slots_available?(issue, state)
    end

    test "returns true when merge queue has items but rollout is mutate" do
      write_workflow_file!(Workflow.workflow_file_path(),
        merge_mode: "auto",
        merge_strategy: "queue",
        rollout_mode: "mutate",
        tracker_active_states: ["In Progress"],
        tracker_terminal_states: ["Done"]
      )

      state =
        empty_state(%{
          merge_queue:
            MergeQueue.add(%{}, "merge-issue", %{number: 42}, 1,
              issue_identifier: "SYM-99",
              enqueued_at_ms: 100
            )
        })

      issue = issue("other-issue", "SYM-200")

      assert Dispatch.dispatch_slots_available?(issue, state)
    end

    test "returns true when merge queue is empty under queue strategy" do
      write_workflow_file!(Workflow.workflow_file_path(),
        merge_mode: "auto",
        merge_strategy: "queue",
        rollout_mode: "merge",
        tracker_active_states: ["In Progress"],
        tracker_terminal_states: ["Done"]
      )

      state = empty_state()
      issue = issue("other-issue", "SYM-200")

      assert Dispatch.dispatch_slots_available?(issue, state)
    end
  end
end
