defmodule SymphonyElixir.RecoveryPathsTest do
  @moduledoc """
  Dedicated tests for PR recovery paths introduced in PR #59:
  - CI failure remediation (checks_failed → rework)
  - Merge conflict remediation (merge_conflict → rework)
  - Durable remediation_attempts counter
  - Recovery limit enforcement (recovery_limit_exceeded → blocked)
  - Recovery config (enabled/max_attempts) schema and defaults
  - Prompt builder CI/conflict instruction prepending
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Tracker.Memory

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp save_memory_tracker(issues) do
    previous_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    {previous_issues, previous_recipient}
  end

  defp restore_memory_tracker({previous_issues, previous_recipient}) do
    if is_nil(previous_issues),
      do: Application.delete_env(:symphony_elixir, :memory_tracker_issues),
      else: Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_issues)

    if is_nil(previous_recipient),
      do: Application.delete_env(:symphony_elixir, :memory_tracker_recipient),
      else: Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_recipient)
  end

  defp github_runner(results) do
    Process.put(:github_runner_results, results)

    fn _command, _args, _opts ->
      case Process.get(:github_runner_results) do
        [result | rest] ->
          Process.put(:github_runner_results, rest)
          result

        _ ->
          {:error, :no_github_result}
      end
    end
  end

  defp runtime_for(issue) do
    SymphonyElixir.OrchestrationPolicy.issue_runtime(issue, Config.settings!())
  end

  defp open_pr_state(number, head_sha, opts) do
    merge_state_status = Keyword.get(opts, :merge_state_status, "CLEAN")
    mergeable = Keyword.get(opts, :mergeable, "MERGEABLE")
    checks_conclusion = Keyword.get(opts, :checks_conclusion, "SUCCESS")
    checks_status = Keyword.get(opts, :checks_status, "COMPLETED")

    Jason.encode!(%{
      "number" => number,
      "url" => "https://github.com/acme/widgets/pull/#{number}",
      "state" => "OPEN",
      "isDraft" => false,
      "headRefName" => "feature/recovery-test",
      "headRefOid" => head_sha,
      "baseRefName" => "main",
      "mergeStateStatus" => merge_state_status,
      "mergeable" => mergeable,
      "reviewDecision" => nil,
      "statusCheckRollup" => [
        %{"status" => checks_status, "conclusion" => checks_conclusion}
      ]
    })
  end

  defp workpad_yaml(phase, opts \\ []) do
    branch = Keyword.get(opts, :branch, "feature/recovery-test")
    remediation_attempts = Keyword.get(opts, :remediation_attempts, 0)
    rework_cycles = Keyword.get(opts, :rework_cycles, 0)
    pr_head_sha = Keyword.get(opts, :pr_head_sha, "head123")
    pr_number = Keyword.get(opts, :pr_number)
    gates = Keyword.get(opts, :gates, %{})

    pr_yaml =
      if pr_number do
        "    number: #{pr_number}\n    url: https://github.com/acme/widgets/pull/#{pr_number}\n    head_sha: #{pr_head_sha}"
      else
        "    url: https://github.com/acme/widgets/pull/999\n    head_sha: #{pr_head_sha}"
      end

    gates_yaml =
      Enum.map_join(gates, "\n", fn {k, v} -> "      #{k}: #{v}" end)

    gates_section = if gates_yaml == "", do: "", else: "\n  observation:\n    gates:\n#{gates_yaml}"

    "## Symphony Workpad\n\n```yaml\nsymphony:\n  phase: #{phase}\n  remediation_attempts: #{remediation_attempts}\n  rework_cycles: #{rework_cycles}\n  branch: #{branch}\n  pr:\n#{pr_yaml}#{gates_section}\n```"
  end

  defp default_recovery_workflow_opts do
    [
      tracker_kind: "memory",
      rollout_mode: "mutate",
      orchestration_required_label: "symphony",
      orchestration_required_workpad_marker: "## Symphony Workpad",
      merge_mode: "auto",
      merge_require_green_checks: true,
      recovery_enabled: true,
      recovery_max_attempts: 3
    ]
  end

  # ---------------------------------------------------------------------------
  # Config / Schema: recovery defaults and validation
  # ---------------------------------------------------------------------------

  describe "recovery config defaults" do
    test "recovery is enabled with max_attempts=5 by default" do
      write_workflow_file!(Workflow.workflow_file_path())

      config = Config.settings!()
      assert config.recovery.enabled == true
      assert config.recovery.max_attempts == 5
    end

    test "recovery config can be overridden" do
      write_workflow_file!(Workflow.workflow_file_path(),
        recovery_enabled: false,
        recovery_max_attempts: 10
      )

      config = Config.settings!()
      assert config.recovery.enabled == false
      assert config.recovery.max_attempts == 10
    end

    test "recovery.max_attempts must be a positive integer" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{recovery: %{max_attempts: 0}})

      assert message =~ "recovery.max_attempts"
    end

    test "recovery schema round-trips through parse" do
      assert {:ok, settings} = Schema.parse(%{recovery: %{enabled: false, max_attempts: 2}})
      assert settings.recovery.enabled == false
      assert settings.recovery.max_attempts == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Workpad: remediation_attempts counter
  # ---------------------------------------------------------------------------

  describe "workpad remediation_attempts counter" do
    test "increments when entering rework with checks_failed reason" do
      previous = save_memory_tracker([])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        orchestration_required_label: "symphony",
        orchestration_required_workpad_marker: "## Symphony Workpad"
      )

      issue = %Issue{
        id: "issue-rem-ci",
        identifier: "MT-REM-CI",
        state: "In Progress",
        title: "CI failure remediation counter",
        url: "https://example.org/issues/MT-REM-CI",
        branch_name: "feature/recovery-test",
        labels: ["symphony"],
        comments: [
          %{
            id: "comment-1",
            body: workpad_yaml("waiting_for_checks", remediation_attempts: 1),
            updated_at: DateTime.utc_now()
          }
        ]
      }

      try do
        assert {:ok, updated_issue} =
                 Workpad.sync_for_test(
                   issue,
                   %{phase: "rework", waiting_reason: "checks_failed"},
                   tracker_module: Memory
                 )

        runtime = runtime_for(updated_issue)
        assert runtime.workpad.metadata["remediation_attempts"] == 2
      after
        restore_memory_tracker(previous)
      end
    end

    test "increments when entering rework with merge_conflict reason" do
      previous = save_memory_tracker([])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        orchestration_required_label: "symphony",
        orchestration_required_workpad_marker: "## Symphony Workpad"
      )

      issue = %Issue{
        id: "issue-rem-mc",
        identifier: "MT-REM-MC",
        state: "In Progress",
        title: "Merge conflict remediation counter",
        url: "https://example.org/issues/MT-REM-MC",
        branch_name: "feature/recovery-test",
        labels: ["symphony"],
        comments: [
          %{
            id: "comment-1",
            body: workpad_yaml("waiting_for_checks", remediation_attempts: 2),
            updated_at: DateTime.utc_now()
          }
        ]
      }

      try do
        assert {:ok, updated_issue} =
                 Workpad.sync_for_test(
                   issue,
                   %{phase: "rework", waiting_reason: "merge_conflict"},
                   tracker_module: Memory
                 )

        runtime = runtime_for(updated_issue)
        assert runtime.workpad.metadata["remediation_attempts"] == 3
      after
        restore_memory_tracker(previous)
      end
    end

    test "does NOT increment when entering rework without recovery reason" do
      previous = save_memory_tracker([])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        orchestration_required_label: "symphony",
        orchestration_required_workpad_marker: "## Symphony Workpad"
      )

      issue = %Issue{
        id: "issue-rem-normal",
        identifier: "MT-REM-NORMAL",
        state: "In Progress",
        title: "Normal rework (not recovery)",
        url: "https://example.org/issues/MT-REM-NORMAL",
        branch_name: "feature/recovery-test",
        labels: ["symphony"],
        comments: [
          %{
            id: "comment-1",
            body: workpad_yaml("implementing", remediation_attempts: 1),
            updated_at: DateTime.utc_now()
          }
        ]
      }

      try do
        assert {:ok, updated_issue} =
                 Workpad.sync_for_test(
                   issue,
                   %{phase: "rework"},
                   tracker_module: Memory
                 )

        runtime = runtime_for(updated_issue)
        # remediation_attempts stays at 1 — only recovery-related rework transitions bump it
        assert runtime.workpad.metadata["remediation_attempts"] == 1
      after
        restore_memory_tracker(previous)
      end
    end

    test "does NOT increment when already in rework phase (idempotent)" do
      previous = save_memory_tracker([])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        orchestration_required_label: "symphony",
        orchestration_required_workpad_marker: "## Symphony Workpad"
      )

      issue = %Issue{
        id: "issue-rem-idem",
        identifier: "MT-REM-IDEM",
        state: "In Progress",
        title: "Already in rework",
        url: "https://example.org/issues/MT-REM-IDEM",
        branch_name: "feature/recovery-test",
        labels: ["symphony"],
        comments: [
          %{
            id: "comment-1",
            body: workpad_yaml("rework", remediation_attempts: 2),
            updated_at: DateTime.utc_now()
          }
        ]
      }

      try do
        assert {:ok, updated_issue} =
                 Workpad.sync_for_test(
                   issue,
                   %{phase: "rework", waiting_reason: "checks_failed"},
                   tracker_module: Memory
                 )

        runtime = runtime_for(updated_issue)
        # Already in rework — should NOT double-increment
        assert runtime.workpad.metadata["remediation_attempts"] == 2
      after
        restore_memory_tracker(previous)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # OrchestrationLifecycle: CI failure → rework
  # ---------------------------------------------------------------------------

  describe "CI failure recovery via bootstrap" do
    test "failing checks with recovery enabled transitions to rework phase" do
      previous = save_memory_tracker([])

      write_workflow_file!(Workflow.workflow_file_path(), default_recovery_workflow_opts())

      issue = %Issue{
        id: "issue-ci-rework",
        identifier: "MT-CI-RW",
        state: "In Review",
        title: "CI failures need remediation",
        url: "https://example.org/issues/MT-CI-RW",
        branch_name: "feature/recovery-test",
        labels: ["symphony"],
        comments: [
          %{
            id: "comment-1",
            body: workpad_yaml("waiting_for_checks", pr_number: 400, pr_head_sha: "ci-fail-head"),
            updated_at: DateTime.utc_now()
          }
        ]
      }

      runner =
        github_runner([
          {:ok,
           open_pr_state(400, "ci-fail-head",
             checks_conclusion: "FAILURE",
             checks_status: "COMPLETED"
           )}
        ])

      try do
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

        assert {:ok, updated_issue} =
                 OrchestrationLifecycle.bootstrap_issue_for_test(
                   issue,
                   runner: runner,
                   tracker_module: Memory
                 )

        runtime = runtime_for(updated_issue)
        assert runtime.phase == "rework"
        assert runtime.dispatch_allowed == true

        observation = runtime.workpad.metadata["observation"]
        assert observation["next_intended_action"] == "resolve_failing_checks"

        gates = observation["gates"]
        assert gates["checks"] == "fail"
        assert gates["pr"] == "open"
      after
        restore_memory_tracker(previous)
      end
    end

    test "failing checks do NOT trigger rework when require_green_checks is false" do
      previous = save_memory_tracker([])

      write_workflow_file!(
        Workflow.workflow_file_path(),
        Keyword.merge(default_recovery_workflow_opts(), merge_require_green_checks: false)
      )

      issue = %Issue{
        id: "issue-ci-no-req",
        identifier: "MT-CI-NRQ",
        state: "In Review",
        title: "Green checks not required",
        url: "https://example.org/issues/MT-CI-NRQ",
        branch_name: "feature/recovery-test",
        labels: ["symphony"],
        comments: [
          %{
            id: "comment-1",
            body: workpad_yaml("waiting_for_checks", pr_number: 401, pr_head_sha: "no-req-head"),
            updated_at: DateTime.utc_now()
          }
        ]
      }

      runner =
        github_runner([
          {:ok,
           open_pr_state(401, "no-req-head",
             checks_conclusion: "FAILURE",
             checks_status: "COMPLETED"
           )}
        ])

      try do
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

        assert {:ok, updated_issue} =
                 OrchestrationLifecycle.bootstrap_issue_for_test(
                   issue,
                   runner: runner,
                   tracker_module: Memory
                 )

        runtime = runtime_for(updated_issue)
        # Without require_green_checks, check failures don't trigger rework
        refute runtime.phase == "rework"
      after
        restore_memory_tracker(previous)
      end
    end

    test "failing checks do NOT trigger rework when recovery is disabled" do
      previous = save_memory_tracker([])

      write_workflow_file!(
        Workflow.workflow_file_path(),
        Keyword.merge(default_recovery_workflow_opts(), recovery_enabled: false)
      )

      issue = %Issue{
        id: "issue-ci-no-rec",
        identifier: "MT-CI-NRC",
        state: "In Review",
        title: "Recovery disabled — no rework for CI",
        url: "https://example.org/issues/MT-CI-NRC",
        branch_name: "feature/recovery-test",
        labels: ["symphony"],
        comments: [
          %{
            id: "comment-1",
            body: workpad_yaml("waiting_for_checks", pr_number: 402, pr_head_sha: "no-rec-head"),
            updated_at: DateTime.utc_now()
          }
        ]
      }

      runner =
        github_runner([
          {:ok,
           open_pr_state(402, "no-rec-head",
             checks_conclusion: "FAILURE",
             checks_status: "COMPLETED"
           )}
        ])

      try do
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

        assert {:ok, updated_issue} =
                 OrchestrationLifecycle.bootstrap_issue_for_test(
                   issue,
                   runner: runner,
                   tracker_module: Memory
                 )

        runtime = runtime_for(updated_issue)
        # Recovery disabled: CI failure stays in waiting_for_checks (with investigate action)
        refute runtime.phase == "rework"
      after
        restore_memory_tracker(previous)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # OrchestrationLifecycle: recovery limit enforcement
  # ---------------------------------------------------------------------------

  describe "recovery limit enforcement" do
    test "CI failure at recovery limit transitions to blocked with recovery_limit_exceeded" do
      previous = save_memory_tracker([])

      write_workflow_file!(Workflow.workflow_file_path(), default_recovery_workflow_opts())

      issue = %Issue{
        id: "issue-ci-limit",
        identifier: "MT-CI-LIM",
        state: "In Review",
        title: "CI failure at recovery cap",
        url: "https://example.org/issues/MT-CI-LIM",
        branch_name: "feature/recovery-test",
        labels: ["symphony"],
        comments: [
          %{
            id: "comment-1",
            body:
              workpad_yaml("waiting_for_checks",
                pr_number: 403,
                pr_head_sha: "lim-head",
                remediation_attempts: 3
              ),
            updated_at: DateTime.utc_now()
          }
        ]
      }

      runner =
        github_runner([
          {:ok,
           open_pr_state(403, "lim-head",
             checks_conclusion: "FAILURE",
             checks_status: "COMPLETED"
           )}
        ])

      try do
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

        assert {:ok, updated_issue} =
                 OrchestrationLifecycle.bootstrap_issue_for_test(
                   issue,
                   runner: runner,
                   tracker_module: Memory
                 )

        runtime = runtime_for(updated_issue)
        assert runtime.phase == "blocked"

        observation = runtime.workpad.metadata["observation"]
        assert observation["next_intended_action"] == "operator_intervention_required"
      after
        restore_memory_tracker(previous)
      end
    end

    test "merge conflict at recovery limit transitions to blocked with recovery_limit_exceeded" do
      previous = save_memory_tracker([])

      write_workflow_file!(Workflow.workflow_file_path(), default_recovery_workflow_opts())

      issue = %Issue{
        id: "issue-mc-limit",
        identifier: "MT-MC-LIM",
        state: "In Review",
        title: "Merge conflict at recovery cap",
        url: "https://example.org/issues/MT-MC-LIM",
        branch_name: "feature/recovery-test",
        labels: ["symphony"],
        comments: [
          %{
            id: "comment-1",
            body:
              workpad_yaml("waiting_for_checks",
                pr_number: 404,
                pr_head_sha: "mc-lim-head",
                remediation_attempts: 3
              ),
            updated_at: DateTime.utc_now()
          }
        ]
      }

      runner =
        github_runner([
          {:ok,
           open_pr_state(404, "mc-lim-head",
             mergeable: "CONFLICTING",
             merge_state_status: "DIRTY"
           )}
        ])

      try do
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

        assert {:ok, updated_issue} =
                 OrchestrationLifecycle.bootstrap_issue_for_test(
                   issue,
                   runner: runner,
                   tracker_module: Memory
                 )

        runtime = runtime_for(updated_issue)
        assert runtime.phase == "blocked"

        observation = runtime.workpad.metadata["observation"]
        assert observation["next_intended_action"] == "operator_intervention_required"
      after
        restore_memory_tracker(previous)
      end
    end

    test "merge conflict below recovery limit still transitions to rework" do
      previous = save_memory_tracker([])

      write_workflow_file!(Workflow.workflow_file_path(), default_recovery_workflow_opts())

      issue = %Issue{
        id: "issue-mc-ok",
        identifier: "MT-MC-OK",
        state: "In Review",
        title: "Merge conflict below cap",
        url: "https://example.org/issues/MT-MC-OK",
        branch_name: "feature/recovery-test",
        labels: ["symphony"],
        comments: [
          %{
            id: "comment-1",
            body:
              workpad_yaml("waiting_for_checks",
                pr_number: 405,
                pr_head_sha: "mc-ok-head",
                remediation_attempts: 1
              ),
            updated_at: DateTime.utc_now()
          }
        ]
      }

      runner =
        github_runner([
          {:ok,
           open_pr_state(405, "mc-ok-head",
             mergeable: "CONFLICTING",
             merge_state_status: "DIRTY"
           )}
        ])

      try do
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

        assert {:ok, updated_issue} =
                 OrchestrationLifecycle.bootstrap_issue_for_test(
                   issue,
                   runner: runner,
                   tracker_module: Memory
                 )

        runtime = runtime_for(updated_issue)
        assert runtime.phase == "rework"
        assert runtime.dispatch_allowed == true

        observation = runtime.workpad.metadata["observation"]
        assert observation["next_intended_action"] == "rebase_onto_base_branch"
      after
        restore_memory_tracker(previous)
      end
    end

    test "recovery limit blocks in reconcile_after_run when rework phase persists" do
      previous = save_memory_tracker([])

      write_workflow_file!(
        Workflow.workflow_file_path(),
        Keyword.merge(default_recovery_workflow_opts(),
          pr_auto_create: true,
          pr_required_labels: []
        )
      )

      test_root = Path.join(System.tmp_dir!(), "symphony-recovery-limit-rar-#{System.unique_integer([:positive])}")
      origin_repo = Path.join(test_root, "origin.git")
      workspace = Path.join(test_root, "repo")

      try do
        File.mkdir_p!(test_root)
        System.cmd("git", ["init", "--bare", origin_repo])
        System.cmd("git", ["init", "-b", "feature/recovery-test", workspace])
        System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
        System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
        File.write!(Path.join(workspace, "README.md"), "# recovery limit\n")
        System.cmd("git", ["-C", workspace, "add", "README.md"])
        System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
        System.cmd("git", ["-C", workspace, "remote", "add", "origin", origin_repo])
        System.cmd("git", ["-C", workspace, "push", "-u", "origin", "feature/recovery-test"])

        # Issue already in rework phase with remediation_attempts at the cap.
        # The workspace git remote points to a local bare repo (no GitHub slug),
        # so PR resolution will skip. This means phase stays "rework" and
        # remediation_attempts_exceeded? fires, transitioning to "blocked".
        issue = %Issue{
          id: "issue-rar-limit",
          identifier: "MT-RAR-LIM",
          state: "In Review",
          title: "Recovery limit via reconcile_after_run",
          url: "https://example.org/issues/MT-RAR-LIM",
          branch_name: "feature/recovery-test",
          labels: ["symphony"],
          comments: [
            %{
              id: "comment-1",
              body:
                workpad_yaml("rework",
                  remediation_attempts: 3,
                  pr_number: 406,
                  pr_head_sha: "rar-head"
                ),
              updated_at: DateTime.utc_now()
            }
          ]
        }

        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

        fetcher = fn [_issue_id] -> {:ok, [issue]} end

        # No repo_slug in git remote or settings — PR resolution skips,
        # phase stays "rework", remediation_attempts_exceeded? fires.
        runner = github_runner([])

        running_entry = %{workspace_path: workspace, worker_host: nil}

        assert {:ok, updated_issue} =
                 OrchestrationLifecycle.reconcile_after_run_for_test(
                   "issue-rar-limit",
                   running_entry,
                   runner: runner,
                   tracker_module: Memory,
                   issue_fetcher: fetcher
                 )

        runtime = runtime_for(updated_issue)
        assert runtime.phase == "blocked"
        assert runtime.workpad.metadata["remediation_attempts"] == 3

        observation = runtime.workpad.metadata["observation"]
        assert observation["next_intended_action"] == "operator_intervention_required"
      after
        restore_memory_tracker(previous)
        File.rm_rf(test_root)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # OrchestrationLifecycle: recovery only in mutate/merge rollout modes
  # ---------------------------------------------------------------------------

  describe "recovery rollout mode guards" do
    test "CI failure recovery does NOT trigger in observe mode" do
      previous = save_memory_tracker([])

      write_workflow_file!(
        Workflow.workflow_file_path(),
        Keyword.merge(default_recovery_workflow_opts(), rollout_mode: "observe")
      )

      issue = %Issue{
        id: "issue-ci-observe",
        identifier: "MT-CI-OBS",
        state: "In Review",
        title: "Observe mode — no CI recovery",
        url: "https://example.org/issues/MT-CI-OBS",
        branch_name: "feature/recovery-test",
        labels: ["symphony"],
        comments: [
          %{
            id: "comment-1",
            body: workpad_yaml("waiting_for_checks", pr_number: 410, pr_head_sha: "obs-head"),
            updated_at: DateTime.utc_now()
          }
        ]
      }

      runner =
        github_runner([
          {:ok,
           open_pr_state(410, "obs-head",
             checks_conclusion: "FAILURE",
             checks_status: "COMPLETED"
           )}
        ])

      try do
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

        assert {:ok, updated_issue} =
                 OrchestrationLifecycle.bootstrap_issue_for_test(
                   issue,
                   runner: runner,
                   tracker_module: Memory
                 )

        runtime = runtime_for(updated_issue)
        # In observe mode, recovery_enabled? returns false, so CI failures don't enter rework
        refute runtime.phase == "rework"
      after
        restore_memory_tracker(previous)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # PromptBuilder: recovery instruction prepending
  # ---------------------------------------------------------------------------

  describe "prompt builder recovery instructions" do
    test "prepends merge conflict instructions when in rework with conflict gate" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        orchestration_required_label: "symphony",
        orchestration_required_workpad_marker: "## Symphony Workpad"
      )

      issue = %Issue{
        id: "issue-prompt-mc",
        identifier: "MT-PROMPT-MC",
        state: "In Progress",
        title: "Conflict prompt",
        url: "https://example.org/issues/MT-PROMPT-MC",
        branch_name: "feature/recovery-test",
        labels: ["symphony"],
        comments: [
          %{
            id: "comment-1",
            body:
              workpad_yaml("rework",
                gates: %{"mergeability" => "conflict"}
              ),
            updated_at: DateTime.utc_now()
          }
        ]
      }

      prompt = PromptBuilder.build_prompt(issue)
      assert prompt =~ "URGENT: Merge Conflict Resolution Required"
      assert prompt =~ "git rebase"
      assert prompt =~ "git push --force-with-lease"
    end

    test "prepends CI failure instructions when in rework with failing checks gate" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        orchestration_required_label: "symphony",
        orchestration_required_workpad_marker: "## Symphony Workpad"
      )

      issue = %Issue{
        id: "issue-prompt-ci",
        identifier: "MT-PROMPT-CI",
        state: "In Progress",
        title: "CI failure prompt",
        url: "https://example.org/issues/MT-PROMPT-CI",
        branch_name: "feature/recovery-test",
        labels: ["symphony"],
        comments: [
          %{
            id: "comment-1",
            body:
              workpad_yaml("rework",
                gates: %{"checks" => "fail"}
              ),
            updated_at: DateTime.utc_now()
          }
        ]
      }

      prompt = PromptBuilder.build_prompt(issue)
      assert prompt =~ "URGENT: CI Check Failures"
      assert prompt =~ "gh pr checks"
      assert prompt =~ "gh run view"
    end

    test "does NOT prepend recovery instructions when NOT in rework phase" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        orchestration_required_label: "symphony",
        orchestration_required_workpad_marker: "## Symphony Workpad"
      )

      issue = %Issue{
        id: "issue-prompt-normal",
        identifier: "MT-PROMPT-N",
        state: "In Progress",
        title: "Normal prompt",
        url: "https://example.org/issues/MT-PROMPT-N",
        branch_name: "feature/recovery-test",
        labels: ["symphony"],
        comments: [
          %{
            id: "comment-1",
            body: workpad_yaml("implementing"),
            updated_at: DateTime.utc_now()
          }
        ]
      }

      prompt = PromptBuilder.build_prompt(issue)
      refute prompt =~ "URGENT"
      refute prompt =~ "Merge Conflict"
      refute prompt =~ "CI Check Failures"
    end

    test "does NOT prepend recovery instructions when in rework but gates are clean" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        orchestration_required_label: "symphony",
        orchestration_required_workpad_marker: "## Symphony Workpad"
      )

      issue = %Issue{
        id: "issue-prompt-clean-rework",
        identifier: "MT-PROMPT-CR",
        state: "In Progress",
        title: "Rework but clean gates",
        url: "https://example.org/issues/MT-PROMPT-CR",
        branch_name: "feature/recovery-test",
        labels: ["symphony"],
        comments: [
          %{
            id: "comment-1",
            body:
              workpad_yaml("rework",
                gates: %{"mergeability" => "pass", "checks" => "pass"}
              ),
            updated_at: DateTime.utc_now()
          }
        ]
      }

      prompt = PromptBuilder.build_prompt(issue)
      refute prompt =~ "URGENT"
    end

    test "merge conflict instructions reference the configured base branch" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        orchestration_required_label: "symphony",
        orchestration_required_workpad_marker: "## Symphony Workpad",
        pr_base_branch: "develop"
      )

      issue = %Issue{
        id: "issue-prompt-branch",
        identifier: "MT-PROMPT-BR",
        state: "In Progress",
        title: "Custom base branch",
        url: "https://example.org/issues/MT-PROMPT-BR",
        branch_name: "feature/recovery-test",
        labels: ["symphony"],
        comments: [
          %{
            id: "comment-1",
            body:
              workpad_yaml("rework",
                gates: %{"mergeability" => "conflict"}
              ),
            updated_at: DateTime.utc_now()
          }
        ]
      }

      prompt = PromptBuilder.build_prompt(issue)
      assert prompt =~ "origin/develop"
      refute prompt =~ "origin/main"
    end
  end
end
