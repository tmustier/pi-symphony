defmodule SymphonyElixir.PresenterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.Presenter

  test "state payload surfaces tracked workpad merge metadata" do
    orchestrator_name = Module.concat(__MODULE__, :StatePayloadOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    tracked_issue = tracked_issue_fixture()

    :sys.replace_state(pid, fn state ->
      %{state | tracked: %{tracked_issue.issue_id => tracked_issue}}
    end)

    payload = Presenter.state_payload(orchestrator_name, 50)

    assert [%{issue_identifier: "MT-990"} = tracked_payload] = payload.tracked
    assert tracked_payload.phase == "blocked"
    assert tracked_payload.waiting_reason == "human_approval_required"
    assert tracked_payload.workpad.pr == %{number: 112, url: "https://github.com/acme/widgets/pull/112", head_sha: "abc123def456"}

    assert tracked_payload.workpad.review == %{
             comment_id: 456_789,
             passes_completed: 1,
             last_reviewed_head_sha: "abc123def456",
             last_fixed_head_sha: "abc123def456"
           }

    assert tracked_payload.workpad.merge == %{
             last_attempted_at: "2026-03-14T23:19:00Z",
             last_attempted_head_sha: "abc123def456",
             last_merge_commit_sha: "merge112999",
             last_merged_head_sha: "abc123def456"
           }

    assert tracked_payload.workpad.observation == %{
             last_observed_at: "2026-03-14T23:20:00Z",
             next_intended_action: "reconcile_merged_pr",
             rollout_mode: "merge",
             gates: %{"human_approval" => "required", "mergeability" => "pass"}
           }
  end

  test "issue payload includes tracked merge metadata for passive issues" do
    orchestrator_name = Module.concat(__MODULE__, :IssuePayloadOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    tracked_issue = tracked_issue_fixture(%{phase: "waiting_for_checks", waiting_reason: "checks_pending", next_intended_action: "confirm_merge_completion"})

    :sys.replace_state(pid, fn state ->
      %{state | tracked: %{tracked_issue.issue_id => tracked_issue}}
    end)

    assert {:ok, payload} = Presenter.issue_payload("MT-990", orchestrator_name, 50)
    assert payload.status == "tracked"
    assert payload.tracked.phase == "waiting_for_checks"
    assert payload.tracked.waiting_reason == "checks_pending"
    assert payload.tracked.next_intended_action == "confirm_merge_completion"
    assert payload.tracked.workpad.merge.last_merge_commit_sha == "merge112999"
    assert payload.tracked.workpad.merge.last_merged_head_sha == "abc123def456"
  end

  defp tracked_issue_fixture(overrides \\ %{}) do
    base = %{
      issue_id: "issue-passive-merge",
      issue_identifier: "MT-990",
      state: "In Review",
      labels: ["symphony"],
      phase: "blocked",
      phase_source: "workpad",
      passive_phase: true,
      rollout_mode: "merge",
      dispatch_allowed: false,
      waiting_reason: "human_approval_required",
      next_intended_action: "reconcile_merged_pr",
      ownership: %{allowed: true, label_present: true, marker_present: true},
      kill_switch: %{active: false},
      workpad: %{
        marker: "## Symphony Workpad",
        marker_found: true,
        comment_id: "comment-1",
        matched_comment_ids: ["comment-1"],
        metadata_status: "ok",
        phase_source: "workpad",
        waiting_reason: "human_approval_required",
        metadata: %{
          "pr" => %{
            "number" => 112,
            "url" => "https://github.com/acme/widgets/pull/112",
            "head_sha" => "abc123def456"
          },
          "review" => %{
            "comment_id" => 456_789,
            "passes_completed" => 1,
            "last_reviewed_head_sha" => "abc123def456",
            "last_fixed_head_sha" => "abc123def456"
          },
          "merge" => %{
            "last_attempted_at" => "2026-03-14T23:19:00Z",
            "last_attempted_head_sha" => "abc123def456",
            "last_merge_commit_sha" => "merge112999",
            "last_merged_head_sha" => "abc123def456",
            "last_failure_reason" => nil
          }
        },
        observation: %{
          "last_observed_at" => "2026-03-14T23:20:00Z",
          "next_intended_action" => "reconcile_merged_pr",
          "rollout_mode" => "merge",
          "gates" => %{"human_approval" => "required", "mergeability" => "pass"}
        }
      }
    }

    Map.merge(base, overrides)
  end
end
