defmodule SymphonyElixir.WorkpadPrLifecycleTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Memory

  test "workspace git inspects local branch, head sha, and remote publication state" do
    test_root = Path.join(System.tmp_dir!(), "symphony-workspace-git-#{System.unique_integer([:positive])}")
    origin_repo = Path.join(test_root, "origin.git")
    repo = Path.join(test_root, "repo")

    try do
      File.mkdir_p!(test_root)
      System.cmd("git", ["init", "--bare", origin_repo])
      System.cmd("git", ["init", "-b", "feature/workpad-lifecycle", repo])
      System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      File.write!(Path.join(repo, "README.md"), "# demo\n")
      System.cmd("git", ["-C", repo, "add", "README.md"])
      System.cmd("git", ["-C", repo, "commit", "-m", "initial"])
      System.cmd("git", ["-C", repo, "remote", "add", "origin", origin_repo])
      System.cmd("git", ["-C", repo, "push", "-u", "origin", "feature/workpad-lifecycle"])
      {head_sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])

      assert {:ok, git_state} = WorkspaceGit.inspect_for_test(repo)
      assert git_state.branch == "feature/workpad-lifecycle"
      assert git_state.remote_branch_published == true
      assert git_state.head_sha == String.trim(head_sha)
      assert WorkspaceGit.repo_slug_from_remote_for_test("git@github.com:acme/widgets.git") == "acme/widgets"
    after
      File.rm_rf(test_root)
    end
  end

  test "pull requests reuse an existing open branch PR" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "mutate",
      pr_auto_create: true,
      pr_required_labels: []
    )

    issue = %Issue{identifier: "MT-700", title: "Reuse PR", url: "https://example.org/issues/MT-700"}

    Process.put(:github_runner_results, [
      {:ok,
       Jason.encode!([
         %{
           "number" => 42,
           "url" => "https://github.com/acme/widgets/pull/42",
           "state" => "OPEN",
           "isDraft" => false,
           "headRefName" => "feature/reuse-pr",
           "headRefOid" => "abc123",
           "baseRefName" => "main"
         }
       ])}
    ])

    runner = fn command, args, _opts ->
      send(self(), {:github_command, command, args})

      case Process.get(:github_runner_results) do
        [result | rest] ->
          Process.put(:github_runner_results, rest)
          result

        _ ->
          {:error, :no_github_result}
      end
    end

    assert {:ok, pr_info} =
             PullRequests.resolve_or_create_for_test(
               issue,
               %{repo_slug: "acme/widgets", branch: "feature/reuse-pr"},
               runner: runner
             )

    assert pr_info.action == :reused
    assert pr_info.number == 42
    assert pr_info.url == "https://github.com/acme/widgets/pull/42"
    assert_receive {:github_command, "gh", args}
    assert Enum.take(args, 2) == ["pr", "list"]
    assert Enum.any?(Enum.chunk_every(args, 2, 1, :discard), &(&1 == ["--base", "main"]))
  end

  test "pull requests create a branch PR when none exists and mutation is allowed" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "mutate",
      pr_auto_create: true,
      pr_required_labels: []
    )

    issue = %Issue{identifier: "MT-701", title: "Create PR", url: "https://example.org/issues/MT-701"}

    Process.put(:github_runner_results, [
      {:ok, "[]"},
      {:ok, "https://github.com/acme/widgets/pull/77\n"},
      {:ok,
       Jason.encode!([
         %{
           "number" => 77,
           "url" => "https://github.com/acme/widgets/pull/77",
           "state" => "OPEN",
           "isDraft" => false,
           "headRefName" => "feature/create-pr",
           "headRefOid" => "def456",
           "baseRefName" => "main"
         }
       ])}
    ])

    runner = fn command, args, _opts ->
      send(self(), {:github_command, command, args})

      case Process.get(:github_runner_results) do
        [result | rest] ->
          Process.put(:github_runner_results, rest)
          result

        _ ->
          {:error, :no_github_result}
      end
    end

    assert {:ok, pr_info} =
             PullRequests.resolve_or_create_for_test(
               issue,
               %{repo_slug: "acme/widgets", branch: "feature/create-pr", remote_branch_published: true},
               runner: runner
             )

    assert pr_info.action == :created
    assert pr_info.number == 77
    assert_receive {:github_command, "gh", ["pr", "create" | _]}
  end

  test "pull requests wait for the branch to be published before creating a PR" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "mutate",
      pr_auto_create: true,
      pr_required_labels: []
    )

    issue = %Issue{identifier: "MT-701R", title: "Publish branch first", url: "https://example.org/issues/MT-701R"}

    Process.put(:github_runner_results, [{:ok, "[]"}])

    runner = fn _command, _args, _opts ->
      case Process.get(:github_runner_results) do
        [result | rest] ->
          Process.put(:github_runner_results, rest)
          result

        _ ->
          {:error, :no_github_result}
      end
    end

    assert {:skip, details} =
             PullRequests.resolve_or_create_for_test(
               issue,
               %{repo_slug: "acme/widgets", branch: "feature/local-only", remote_branch_published: false},
               runner: runner
             )

    assert details.reason == :remote_branch_missing
    assert details.next_intended_action == "push_branch_to_origin"
  end

  test "pull requests stop with an explicit next action when closed_pr_policy is new_branch" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "mutate",
      pr_auto_create: true,
      pr_required_labels: []
    )

    issue = %Issue{identifier: "MT-701B", title: "Need a new branch", url: "https://example.org/issues/MT-701B"}

    Process.put(:github_runner_results, [
      {:ok,
       Jason.encode!([
         %{
           "number" => 51,
           "url" => "https://github.com/acme/widgets/pull/51",
           "state" => "CLOSED",
           "isDraft" => false,
           "headRefName" => "feature/closed-pr",
           "headRefOid" => "deadbeef",
           "baseRefName" => "main"
         }
       ])}
    ])

    runner = fn _command, _args, _opts ->
      case Process.get(:github_runner_results) do
        [result | rest] ->
          Process.put(:github_runner_results, rest)
          result

        _ ->
          {:error, :no_github_result}
      end
    end

    assert {:skip, details} =
             PullRequests.resolve_or_create_for_test(
               issue,
               %{repo_slug: "acme/widgets", branch: "feature/closed-pr", remote_branch_published: true},
               runner: runner
             )

    assert details.reason == :new_branch_required
    assert details.next_intended_action == "push_new_branch_for_followup"
  end

  test "pull requests inspect readiness state and derive repo context from the PR url" do
    Process.put(:github_runner_results, [
      {:ok,
       Jason.encode!(%{
         "number" => 77,
         "url" => "https://github.com/acme/widgets/pull/77",
         "state" => "OPEN",
         "isDraft" => false,
         "headRefName" => "feature/inspect-pr",
         "headRefOid" => "abc123",
         "baseRefName" => "main",
         "mergeStateStatus" => "CLEAN",
         "mergeable" => "MERGEABLE",
         "reviewDecision" => "APPROVED",
         "statusCheckRollup" => [
           %{"status" => "COMPLETED", "conclusion" => "SUCCESS"},
           %{"status" => "IN_PROGRESS", "conclusion" => nil}
         ]
       })}
    ])

    runner = fn command, args, _opts ->
      send(self(), {:github_command, command, args})

      case Process.get(:github_runner_results) do
        [result | rest] ->
          Process.put(:github_runner_results, rest)
          result

        _ ->
          {:error, :no_github_result}
      end
    end

    assert {:ok, result} =
             PullRequests.inspect_state_for_test(
               %{url: "https://github.com/acme/widgets/pull/77"},
               runner: runner
             )

    assert result.number == 77
    assert result.head_sha == "abc123"
    assert result.mergeable == "MERGEABLE"
    assert result.review_decision == "APPROVED"
    assert result.checks.state == "pending"
    assert result.checks.passing == 1
    assert result.checks.pending == 1
    assert_receive {:github_command, "gh", ["pr", "view", "77", "--repo", "acme/widgets" | _]}
  end

  test "review artifact loads the canonical workspace review file" do
    workspace = Path.join(System.tmp_dir!(), "symphony-review-artifact-#{System.unique_integer([:positive])}")
    artifact_path = ReviewArtifact.path_for_test(workspace)

    try do
      File.mkdir_p!(Path.dirname(artifact_path))
      File.write!(artifact_path, "<!-- symphony-review-head: abc123 -->\n\n### Findings\n\n- none\n")

      assert {:ok, artifact} = ReviewArtifact.load_for_test(workspace)
      assert artifact.path == artifact_path
      assert artifact.reviewed_head_sha == "abc123"
      assert artifact.body == "### Findings\n\n- none"
    after
      File.rm_rf(workspace)
    end
  end

  test "pull requests upsert review comments by marker" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "mutate",
      pr_review_comment_mode: "upsert"
    )

    Process.put(:github_runner_results, [
      {:ok,
       Jason.encode!([
         %{
           "id" => 321,
           "body" => "<!-- symphony-review -->\n\nPrevious review",
           "html_url" => "https://github.com/acme/widgets/pull/77#issuecomment-321"
         }
       ])},
      {:ok,
       Jason.encode!(%{
         "id" => 321,
         "body" => "<!-- symphony-review -->\n\nUpdated review",
         "html_url" => "https://github.com/acme/widgets/pull/77#issuecomment-321"
       })}
    ])

    runner = fn command, args, _opts ->
      send(self(), {:github_command, command, args})

      case Process.get(:github_runner_results) do
        [result | rest] ->
          Process.put(:github_runner_results, rest)
          result

        _ ->
          {:error, :no_github_result}
      end
    end

    assert {:ok, result} =
             PullRequests.upsert_review_comment_for_test(
               %{number: 77, repo_slug: "acme/widgets"},
               "Updated review",
               runner: runner
             )

    assert result.action == :updated
    assert result.comment_id == 321
    assert_receive {:github_command, "gh", ["api", "repos/acme/widgets/issues/77/comments?per_page=100&page=1"]}
    assert_receive {:github_command, "gh", ["api", "repos/acme/widgets/issues/comments/321", "--method", "PATCH", "-f", body_arg]}
    assert String.contains?(body_arg, "body=<!-- symphony-review -->")
  end

  test "pull requests paginate marker lookup when the durable review comment is beyond the first page" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "mutate",
      pr_review_comment_mode: "upsert"
    )

    first_page =
      Enum.map(1..100, fn index ->
        %{
          "id" => index,
          "body" => "Regular comment #{index}",
          "html_url" => "https://github.com/acme/widgets/pull/77#issuecomment-#{index}"
        }
      end)

    Process.put(:github_runner_results, [
      {:ok, Jason.encode!(first_page)},
      {:ok,
       Jason.encode!([
         %{
           "id" => 321,
           "body" => "<!-- symphony-review -->\n\nPrevious review",
           "html_url" => "https://github.com/acme/widgets/pull/77#issuecomment-321"
         }
       ])},
      {:ok,
       Jason.encode!(%{
         "id" => 321,
         "body" => "<!-- symphony-review -->\n\nUpdated review",
         "html_url" => "https://github.com/acme/widgets/pull/77#issuecomment-321"
       })}
    ])

    runner = fn command, args, _opts ->
      send(self(), {:github_command, command, args})

      case Process.get(:github_runner_results) do
        [result | rest] ->
          Process.put(:github_runner_results, rest)
          result

        _ ->
          {:error, :no_github_result}
      end
    end

    assert {:ok, result} =
             PullRequests.upsert_review_comment_for_test(
               %{number: 77, repo_slug: "acme/widgets"},
               "Updated review",
               runner: runner
             )

    assert result.action == :updated
    assert result.comment_id == 321
    assert_receive {:github_command, "gh", ["api", "repos/acme/widgets/issues/77/comments?per_page=100&page=1"]}
    assert_receive {:github_command, "gh", ["api", "repos/acme/widgets/issues/77/comments?per_page=100&page=2"]}
    assert_receive {:github_command, "gh", ["api", "repos/acme/widgets/issues/comments/321", "--method", "PATCH", "-f", _body_arg]}
  end

  test "bootstrap lifecycle observes green checks and waits for human approval" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "observe",
      orchestration_required_label: "symphony",
      orchestration_required_workpad_marker: "## Symphony Workpad",
      merge_mode: "auto",
      merge_approval_states: ["Merging"],
      review_enabled: true,
      review_agent: "pr-reviewer",
      review_output_format: "structured_markdown_v1"
    )

    issue = %Issue{
      id: "issue-passive-pr-human",
      identifier: "MT-704P",
      state: "In Review",
      title: "Wait for human approval",
      description: "Observe passive PR readiness without dispatching",
      url: "https://example.org/issues/MT-704P",
      branch_name: "feature/passive-pr-human",
      labels: ["symphony"],
      comments: [
        %{
          id: "comment-1",
          body:
            "## Symphony Workpad\n\n```yaml\nsymphony:\n  phase: waiting_for_checks\n  branch: feature/passive-pr-human\n  pr:\n    url: https://github.com/acme/widgets/pull/100\n    head_sha: stale123\n  review:\n    passes_completed: 1\n    last_reviewed_head_sha: fresh123\n```",
          updated_at: DateTime.utc_now()
        }
      ]
    }

    try do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Process.put(:github_runner_results, [
        {:ok,
         Jason.encode!(%{
           "number" => 100,
           "url" => "https://github.com/acme/widgets/pull/100",
           "state" => "OPEN",
           "isDraft" => false,
           "headRefName" => "feature/passive-pr-human",
           "headRefOid" => "fresh123",
           "baseRefName" => "main",
           "mergeStateStatus" => "CLEAN",
           "mergeable" => "MERGEABLE",
           "reviewDecision" => "APPROVED",
           "statusCheckRollup" => [%{"status" => "COMPLETED", "conclusion" => "SUCCESS"}]
         })}
      ])

      runner = fn _command, _args, _opts ->
        case Process.get(:github_runner_results) do
          [result | rest] ->
            Process.put(:github_runner_results, rest)
            result

          _ ->
            {:error, :no_github_result}
        end
      end

      assert {:ok, updated_issue} =
               OrchestrationLifecycle.bootstrap_issue_for_test(
                 issue,
                 runner: runner,
                 tracker_module: Memory
               )

      runtime = SymphonyElixir.OrchestrationPolicy.issue_runtime(updated_issue, Config.settings!())
      gates = runtime.workpad.metadata["observation"]["gates"]

      assert runtime.phase == "waiting_for_human"
      assert runtime.waiting_reason == "human_approval_required"
      assert runtime.next_intended_action == "await_human_approval"
      assert runtime.workpad.metadata["pr"]["number"] == 100
      assert runtime.workpad.metadata["pr"]["head_sha"] == "fresh123"
      assert gates["pr"] == "open"
      assert gates["checks"] == "pass"
      assert gates["human_approval"] == "required"
      assert gates["mergeability"] == "pass"
      assert gates["review"] == "current"
    after
      if is_nil(previous_memory_issues),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_issues),
        else: Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)

      if is_nil(previous_memory_recipient),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_recipient),
        else: Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_memory_recipient)
    end
  end

  test "bootstrap lifecycle keeps green PRs passive in observe mode" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "observe",
      orchestration_required_label: "symphony",
      orchestration_required_workpad_marker: "## Symphony Workpad",
      merge_mode: "auto",
      merge_approval_states: ["Merging"],
      review_enabled: true,
      review_agent: "pr-reviewer",
      review_output_format: "structured_markdown_v1"
    )

    issue = %Issue{
      id: "issue-passive-pr-ready",
      identifier: "MT-704Q",
      state: "Merging",
      title: "Promote merge-ready issues",
      description: "Allow passive polling to notice when merge gates are satisfied",
      url: "https://example.org/issues/MT-704Q",
      branch_name: "feature/passive-pr-ready",
      labels: ["symphony"],
      comments: [
        %{
          id: "comment-1",
          body:
            "## Symphony Workpad\n\n```yaml\nsymphony:\n  phase: waiting_for_human\n  branch: feature/passive-pr-ready\n  pr:\n    number: 101\n    url: https://github.com/acme/widgets/pull/101\n    head_sha: ready123\n  review:\n    passes_completed: 1\n    last_reviewed_head_sha: ready123\n```",
          updated_at: DateTime.utc_now()
        }
      ]
    }

    try do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Process.put(:github_runner_results, [
        {:ok,
         Jason.encode!(%{
           "number" => 101,
           "url" => "https://github.com/acme/widgets/pull/101",
           "state" => "OPEN",
           "isDraft" => false,
           "headRefName" => "feature/passive-pr-ready",
           "headRefOid" => "ready123",
           "baseRefName" => "main",
           "mergeStateStatus" => "CLEAN",
           "mergeable" => "MERGEABLE",
           "reviewDecision" => "APPROVED",
           "statusCheckRollup" => [%{"status" => "COMPLETED", "conclusion" => "SUCCESS"}]
         })}
      ])

      runner = fn _command, _args, _opts ->
        case Process.get(:github_runner_results) do
          [result | rest] ->
            Process.put(:github_runner_results, rest)
            result

          _ ->
            {:error, :no_github_result}
        end
      end

      assert {:ok, updated_issue} =
               OrchestrationLifecycle.bootstrap_issue_for_test(
                 issue,
                 runner: runner,
                 tracker_module: Memory
               )

      runtime = SymphonyElixir.OrchestrationPolicy.issue_runtime(updated_issue, Config.settings!())
      gates = runtime.workpad.metadata["observation"]["gates"]

      assert runtime.phase == "waiting_for_human"
      assert runtime.waiting_reason == "observe_only"
      assert runtime.next_intended_action == "merge_when_green"
      assert runtime.workpad.metadata["waiting"]["reason"] == "observe_only"
      assert runtime.passive_phase == true
      assert SymphonyElixir.OrchestrationPolicy.continuation_allowed?(updated_issue, Config.settings!()) == false
      assert gates["human_approval"] == "approved"
      assert gates["checks"] == "pass"
      assert gates["review"] == "current"
    after
      if is_nil(previous_memory_issues),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_issues),
        else: Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)

      if is_nil(previous_memory_recipient),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_recipient),
        else: Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_memory_recipient)
    end
  end

  test "bootstrap lifecycle promotes approval-state issues into ready_to_merge when passive gates are green" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "mutate",
      orchestration_required_label: "symphony",
      orchestration_required_workpad_marker: "## Symphony Workpad",
      merge_mode: "auto",
      merge_approval_states: ["Merging"],
      review_enabled: true,
      review_agent: "pr-reviewer",
      review_output_format: "structured_markdown_v1"
    )

    issue = %Issue{
      id: "issue-passive-pr-ready-mutate",
      identifier: "MT-704Q1",
      state: "Merging",
      title: "Promote merge-ready issues",
      description: "Allow passive polling to notice when merge gates are satisfied",
      url: "https://example.org/issues/MT-704Q1",
      branch_name: "feature/passive-pr-ready-mutate",
      labels: ["symphony"],
      comments: [
        %{
          id: "comment-1",
          body:
            "## Symphony Workpad\n\n```yaml\nsymphony:\n  phase: waiting_for_human\n  branch: feature/passive-pr-ready-mutate\n  pr:\n    number: 101\n    url: https://github.com/acme/widgets/pull/101\n    head_sha: ready123\n  review:\n    passes_completed: 1\n    last_reviewed_head_sha: ready123\n```",
          updated_at: DateTime.utc_now()
        }
      ]
    }

    try do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Process.put(:github_runner_results, [
        {:ok,
         Jason.encode!(%{
           "number" => 101,
           "url" => "https://github.com/acme/widgets/pull/101",
           "state" => "OPEN",
           "isDraft" => false,
           "headRefName" => "feature/passive-pr-ready-mutate",
           "headRefOid" => "ready123",
           "baseRefName" => "main",
           "mergeStateStatus" => "BEHIND",
           "mergeable" => "MERGEABLE",
           "reviewDecision" => "APPROVED",
           "statusCheckRollup" => [%{"status" => "COMPLETED", "conclusion" => "SUCCESS"}]
         })}
      ])

      runner = fn _command, _args, _opts ->
        case Process.get(:github_runner_results) do
          [result | rest] ->
            Process.put(:github_runner_results, rest)
            result

          _ ->
            {:error, :no_github_result}
        end
      end

      assert {:ok, updated_issue} =
               OrchestrationLifecycle.bootstrap_issue_for_test(
                 issue,
                 runner: runner,
                 tracker_module: Memory
               )

      runtime = SymphonyElixir.OrchestrationPolicy.issue_runtime(updated_issue, Config.settings!())
      gates = runtime.workpad.metadata["observation"]["gates"]

      assert runtime.phase == "ready_to_merge"
      assert runtime.waiting_reason == nil
      assert runtime.next_intended_action == "merge_when_green"
      assert runtime.workpad.metadata["waiting"]["reason"] == nil
      assert runtime.passive_phase == false
      assert SymphonyElixir.OrchestrationPolicy.continuation_allowed?(updated_issue, Config.settings!()) == true
      assert gates["human_approval"] == "approved"
      assert gates["checks"] == "pass"
      assert gates["review"] == "current"
      assert gates["mergeability"] == "pass"
    after
      if is_nil(previous_memory_issues),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_issues),
        else: Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)

      if is_nil(previous_memory_recipient),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_recipient),
        else: Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_memory_recipient)
    end
  end

  test "bootstrap lifecycle keeps unknown passive PR gates in waiting_for_checks" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "observe",
      orchestration_required_label: "symphony",
      orchestration_required_workpad_marker: "## Symphony Workpad",
      merge_mode: "auto",
      merge_approval_states: ["Merging"],
      review_enabled: true,
      review_agent: "pr-reviewer",
      review_output_format: "structured_markdown_v1"
    )

    issue = %Issue{
      id: "issue-passive-pr-unknown",
      identifier: "MT-704QA",
      state: "Merging",
      title: "Wait for unknown PR readiness",
      description: "Unknown mergeability or check state must not promote the PR",
      url: "https://example.org/issues/MT-704QA",
      branch_name: "feature/passive-pr-unknown",
      labels: ["symphony"],
      comments: [
        %{
          id: "comment-1",
          body:
            "## Symphony Workpad\n\n```yaml\nsymphony:\n  phase: waiting_for_human\n  branch: feature/passive-pr-unknown\n  pr:\n    number: 102\n    url: https://github.com/acme/widgets/pull/102\n    head_sha: unknown123\n  review:\n    passes_completed: 1\n    last_reviewed_head_sha: unknown123\n```",
          updated_at: DateTime.utc_now()
        }
      ]
    }

    try do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Process.put(:github_runner_results, [
        {:ok,
         Jason.encode!(%{
           "number" => 102,
           "url" => "https://github.com/acme/widgets/pull/102",
           "state" => "OPEN",
           "isDraft" => false,
           "headRefName" => "feature/passive-pr-unknown",
           "headRefOid" => "unknown123",
           "baseRefName" => "main",
           "mergeStateStatus" => "UNKNOWN",
           "mergeable" => "UNKNOWN",
           "reviewDecision" => "APPROVED",
           "statusCheckRollup" => nil
         })}
      ])

      runner = fn _command, _args, _opts ->
        case Process.get(:github_runner_results) do
          [result | rest] ->
            Process.put(:github_runner_results, rest)
            result

          _ ->
            {:error, :no_github_result}
        end
      end

      assert {:ok, updated_issue} =
               OrchestrationLifecycle.bootstrap_issue_for_test(
                 issue,
                 runner: runner,
                 tracker_module: Memory
               )

      runtime = SymphonyElixir.OrchestrationPolicy.issue_runtime(updated_issue, Config.settings!())
      gates = runtime.workpad.metadata["observation"]["gates"]

      assert runtime.phase == "waiting_for_checks"
      assert runtime.waiting_reason == "checks_pending"
      assert runtime.next_intended_action == "poll_on_next_cycle"
      assert gates["checks"] == "unknown"
      assert gates["mergeability"] == "unknown"
      assert gates["human_approval"] == "approved"
    after
      if is_nil(previous_memory_issues),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_issues),
        else: Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)

      if is_nil(previous_memory_recipient),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_recipient),
        else: Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_memory_recipient)
    end
  end

  test "workpad sync refreshes core observation gates over stale persisted values" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "mutate",
      orchestration_required_label: "symphony",
      orchestration_required_workpad_marker: "## Symphony Workpad"
    )

    issue = %Issue{
      id: "issue-workpad-gates-refresh",
      identifier: "MT-704QB",
      state: "In Progress",
      title: "Refresh core observation gates",
      description: "Fresh ownership and dispatch gates should win over stale persisted values",
      url: "https://example.org/issues/MT-704QB",
      branch_name: "feature/workpad-gates-refresh",
      labels: ["symphony"],
      comments: [
        %{
          id: "comment-1",
          body:
            "## Symphony Workpad\n\n```yaml\nsymphony:\n  phase: implementing\n  observation:\n    gates:\n      ownership: fail\n      kill_switch: active\n      dispatch: blocked\n      pr: stale\n```",
          updated_at: DateTime.utc_now()
        }
      ]
    }

    try do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      assert {:ok, updated_issue} =
               Workpad.sync_for_test(
                 issue,
                 %{observation_gates: %{"pr" => "open"}},
                 tracker_module: Memory
               )

      gates =
        updated_issue
        |> SymphonyElixir.OrchestrationPolicy.issue_runtime(Config.settings!())
        |> then(& &1.workpad.metadata["observation"]["gates"])

      assert gates["ownership"] == "pass"
      assert gates["kill_switch"] == "pass"
      assert gates["dispatch"] == "pass"
      assert gates["pr"] == "open"
    after
      if is_nil(previous_memory_issues),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_issues),
        else: Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)

      if is_nil(previous_memory_recipient),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_recipient),
        else: Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_memory_recipient)
    end
  end

  test "post-run lifecycle persists review comment metadata from workspace artifacts" do
    test_root = Path.join(System.tmp_dir!(), "symphony-review-persistence-#{System.unique_integer([:positive])}")
    origin_repo = Path.join(test_root, "origin.git")
    repo = Path.join(test_root, "repo")
    review_path = ReviewArtifact.path_for_test(repo)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "mutate",
      orchestration_required_label: "symphony",
      orchestration_required_workpad_marker: "## Symphony Workpad",
      pr_auto_create: true,
      pr_required_labels: [],
      pr_review_comment_mode: "upsert",
      review_enabled: true,
      review_agent: "pr-reviewer",
      review_output_format: "structured_markdown_v1",
      review_max_passes: 2
    )

    issue = %Issue{
      id: "issue-review-persistence",
      identifier: "MT-704V",
      state: "In Review",
      title: "Persist review metadata",
      description: "Upsert review comment after a successful run",
      url: "https://example.org/issues/MT-704V",
      branch_name: "feature/review-persistence",
      labels: ["symphony"],
      comments: []
    }

    try do
      File.mkdir_p!(test_root)
      System.cmd("git", ["init", "--bare", origin_repo])
      System.cmd("git", ["init", "-b", "feature/review-persistence", repo])
      System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      File.write!(Path.join(repo, "README.md"), "# review persistence\n")
      System.cmd("git", ["-C", repo, "add", "README.md"])
      System.cmd("git", ["-C", repo, "commit", "-m", "initial"])
      System.cmd("git", ["-C", repo, "remote", "add", "origin", origin_repo])
      System.cmd("git", ["-C", repo, "push", "-u", "origin", "feature/review-persistence"])
      {head_sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])
      File.mkdir_p!(Path.dirname(review_path))
      File.write!(review_path, "<!-- symphony-review-head: #{String.trim(head_sha)} -->\n\n### Findings\n\n- No actionable issues found.")

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Process.put(:github_runner_results, [
        {:ok, "[]"},
        {:ok, "https://github.com/acme/widgets/pull/88\n"},
        {:ok,
         Jason.encode!([
           %{
             "number" => 88,
             "url" => "https://github.com/acme/widgets/pull/88",
             "state" => "OPEN",
             "isDraft" => false,
             "headRefName" => "feature/review-persistence",
             "headRefOid" => String.trim(head_sha),
             "baseRefName" => "main"
           }
         ])},
        {:ok, "[]"},
        {:ok,
         Jason.encode!(%{
           "id" => 444,
           "body" => "<!-- symphony-review -->\n\n### Findings\n\n- No actionable issues found.",
           "html_url" => "https://github.com/acme/widgets/pull/88#issuecomment-444"
         })}
      ])

      runner = fn command, args, _opts ->
        send(self(), {:github_command, command, args})

        case Process.get(:github_runner_results) do
          [result | rest] ->
            Process.put(:github_runner_results, rest)
            result

          _ ->
            {:error, :no_github_result}
        end
      end

      issue_fetcher = fn ["issue-review-persistence"] -> {:ok, [issue]} end

      assert {:ok, updated_issue} =
               OrchestrationLifecycle.reconcile_after_run_for_test(
                 "issue-review-persistence",
                 %{workspace_path: repo, worker_host: nil},
                 runner: runner,
                 issue_fetcher: issue_fetcher,
                 repo_slug: "acme/widgets",
                 tracker_module: Memory
               )

      runtime = SymphonyElixir.OrchestrationPolicy.issue_runtime(updated_issue, Config.settings!())
      assert runtime.phase == "waiting_for_checks"
      assert runtime.workpad.metadata["review"]["comment_id"] == 444
      assert runtime.workpad.metadata["review"]["passes_completed"] == 1
      assert runtime.workpad.metadata["review"]["last_reviewed_head_sha"] == String.trim(head_sha)
      assert runtime.workpad.metadata["observation"]["gates"]["review"] == "persisted"
      assert_receive {:github_command, "gh", ["api", "repos/acme/widgets/issues/88/comments?per_page=100&page=1"]}
      assert_receive {:github_command, "gh", ["api", "repos/acme/widgets/issues/88/comments", "--method", "POST", "-f", _body]}
    after
      File.rm_rf(test_root)

      if is_nil(previous_memory_issues),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_issues),
        else: Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)

      if is_nil(previous_memory_recipient),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_recipient),
        else: Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_memory_recipient)
    end
  end

  test "post-run lifecycle does not increment persisted review passes for the same head" do
    test_root = Path.join(System.tmp_dir!(), "symphony-review-same-head-#{System.unique_integer([:positive])}")
    origin_repo = Path.join(test_root, "origin.git")
    repo = Path.join(test_root, "repo")
    review_path = ReviewArtifact.path_for_test(repo)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "mutate",
      orchestration_required_label: "symphony",
      orchestration_required_workpad_marker: "## Symphony Workpad",
      pr_auto_create: true,
      pr_required_labels: [],
      pr_review_comment_mode: "upsert",
      review_enabled: true,
      review_agent: "pr-reviewer",
      review_output_format: "structured_markdown_v1",
      review_max_passes: 2
    )

    try do
      File.mkdir_p!(test_root)
      System.cmd("git", ["init", "--bare", origin_repo])
      System.cmd("git", ["init", "-b", "feature/review-same-head", repo])
      System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      File.write!(Path.join(repo, "README.md"), "# review same head\n")
      System.cmd("git", ["-C", repo, "add", "README.md"])
      System.cmd("git", ["-C", repo, "commit", "-m", "initial"])
      System.cmd("git", ["-C", repo, "remote", "add", "origin", origin_repo])
      System.cmd("git", ["-C", repo, "push", "-u", "origin", "feature/review-same-head"])
      {head_sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])
      trimmed_head_sha = String.trim(head_sha)
      File.mkdir_p!(Path.dirname(review_path))
      File.write!(review_path, "<!-- symphony-review-head: #{trimmed_head_sha} -->\n\n### Findings\n\n- Updated wording only.")

      issue = %Issue{
        id: "issue-review-same-head",
        identifier: "MT-704X",
        state: "In Review",
        title: "Do not double count review passes",
        description: "Same-head comment refreshes should not increment passes",
        url: "https://example.org/issues/MT-704X",
        branch_name: "feature/review-same-head",
        labels: ["symphony"],
        comments: [
          %{
            id: "comment-1",
            body:
              "## Symphony Workpad\n\n```yaml\nsymphony:\n  phase: waiting_for_checks\n  branch: feature/review-same-head\n  pr:\n    number: 90\n    url: https://github.com/acme/widgets/pull/90\n    head_sha: #{trimmed_head_sha}\n  review:\n    comment_id: 555\n    passes_completed: 1\n    last_reviewed_head_sha: #{trimmed_head_sha}\n    last_fixed_head_sha: null\n```",
            updated_at: DateTime.utc_now()
          }
        ]
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Process.put(:github_runner_results, [
        {:ok,
         Jason.encode!([
           %{
             "number" => 90,
             "url" => "https://github.com/acme/widgets/pull/90",
             "state" => "OPEN",
             "isDraft" => false,
             "headRefName" => "feature/review-same-head",
             "headRefOid" => trimmed_head_sha,
             "baseRefName" => "main"
           }
         ])},
        {:ok,
         Jason.encode!(%{
           "id" => 555,
           "body" => "<!-- symphony-review -->\n\nOld review",
           "html_url" => "https://github.com/acme/widgets/pull/90#issuecomment-555"
         })},
        {:ok,
         Jason.encode!(%{
           "id" => 555,
           "body" => "<!-- symphony-review -->\n\n### Findings\n\n- Updated wording only.",
           "html_url" => "https://github.com/acme/widgets/pull/90#issuecomment-555"
         })}
      ])

      runner = fn _command, _args, _opts ->
        case Process.get(:github_runner_results) do
          [result | rest] ->
            Process.put(:github_runner_results, rest)
            result

          _ ->
            {:error, :no_github_result}
        end
      end

      issue_fetcher = fn ["issue-review-same-head"] -> {:ok, [issue]} end

      assert {:ok, updated_issue} =
               OrchestrationLifecycle.reconcile_after_run_for_test(
                 "issue-review-same-head",
                 %{workspace_path: repo, worker_host: nil},
                 runner: runner,
                 issue_fetcher: issue_fetcher,
                 repo_slug: "acme/widgets",
                 tracker_module: Memory
               )

      runtime = SymphonyElixir.OrchestrationPolicy.issue_runtime(updated_issue, Config.settings!())
      assert runtime.workpad.metadata["review"]["comment_id"] == 555
      assert runtime.workpad.metadata["review"]["passes_completed"] == 1
      assert runtime.workpad.metadata["review"]["last_reviewed_head_sha"] == trimmed_head_sha
    after
      File.rm_rf(test_root)

      if is_nil(previous_memory_issues),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_issues),
        else: Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)

      if is_nil(previous_memory_recipient),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_recipient),
        else: Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_memory_recipient)
    end
  end

  test "post-run lifecycle keeps the issue in reviewing when the review artifact head is stale" do
    test_root = Path.join(System.tmp_dir!(), "symphony-review-stale-artifact-#{System.unique_integer([:positive])}")
    origin_repo = Path.join(test_root, "origin.git")
    repo = Path.join(test_root, "repo")
    review_path = ReviewArtifact.path_for_test(repo)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "mutate",
      orchestration_required_label: "symphony",
      orchestration_required_workpad_marker: "## Symphony Workpad",
      pr_auto_create: true,
      pr_required_labels: [],
      pr_review_comment_mode: "upsert",
      review_enabled: true,
      review_agent: "pr-reviewer",
      review_output_format: "structured_markdown_v1",
      review_max_passes: 2
    )

    issue = %Issue{
      id: "issue-review-stale-artifact",
      identifier: "MT-704Z",
      state: "In Progress",
      title: "Ignore stale review artifacts",
      description: "Do not count an old review file for a new head",
      url: "https://example.org/issues/MT-704Z",
      branch_name: "feature/review-stale-artifact",
      labels: ["symphony"],
      comments: []
    }

    try do
      File.mkdir_p!(test_root)
      System.cmd("git", ["init", "--bare", origin_repo])
      System.cmd("git", ["init", "-b", "feature/review-stale-artifact", repo])
      System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      File.write!(Path.join(repo, "README.md"), "# review stale artifact\n")
      System.cmd("git", ["-C", repo, "add", "README.md"])
      System.cmd("git", ["-C", repo, "commit", "-m", "initial"])
      System.cmd("git", ["-C", repo, "remote", "add", "origin", origin_repo])
      System.cmd("git", ["-C", repo, "push", "-u", "origin", "feature/review-stale-artifact"])
      {head_sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])
      File.mkdir_p!(Path.dirname(review_path))
      File.write!(review_path, "<!-- symphony-review-head: stale123 -->\n\n### Findings\n\n- Stale review output.")

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Process.put(:github_runner_results, [
        {:ok, "[]"},
        {:ok, "https://github.com/acme/widgets/pull/92\n"},
        {:ok,
         Jason.encode!([
           %{
             "number" => 92,
             "url" => "https://github.com/acme/widgets/pull/92",
             "state" => "OPEN",
             "isDraft" => false,
             "headRefName" => "feature/review-stale-artifact",
             "headRefOid" => String.trim(head_sha),
             "baseRefName" => "main"
           }
         ])}
      ])

      runner = fn _command, _args, _opts ->
        case Process.get(:github_runner_results) do
          [result | rest] ->
            Process.put(:github_runner_results, rest)
            result

          _ ->
            {:error, :no_github_result}
        end
      end

      issue_fetcher = fn ["issue-review-stale-artifact"] -> {:ok, [issue]} end

      assert {:ok, updated_issue} =
               OrchestrationLifecycle.reconcile_after_run_for_test(
                 "issue-review-stale-artifact",
                 %{workspace_path: repo, worker_host: nil},
                 runner: runner,
                 issue_fetcher: issue_fetcher,
                 repo_slug: "acme/widgets",
                 tracker_module: Memory
               )

      runtime = SymphonyElixir.OrchestrationPolicy.issue_runtime(updated_issue, Config.settings!())
      assert runtime.phase == "reviewing"
      assert runtime.workpad.metadata["review"]["passes_completed"] == 0
      assert runtime.workpad.metadata["observation"]["gates"]["review"] == "stale"
      assert runtime.workpad.metadata["observation"]["next_intended_action"] == "rerun_review_for_current_head"
    after
      File.rm_rf(test_root)

      if is_nil(previous_memory_issues),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_issues),
        else: Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)

      if is_nil(previous_memory_recipient),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_recipient),
        else: Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_memory_recipient)
    end
  end

  test "post-run lifecycle marks review continuity as missing when the current head sha is unavailable" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "mutate",
      orchestration_required_label: "symphony",
      orchestration_required_workpad_marker: "## Symphony Workpad",
      pr_auto_create: true,
      pr_required_labels: [],
      pr_review_comment_mode: "upsert",
      review_enabled: true,
      review_agent: "pr-reviewer",
      review_output_format: "structured_markdown_v1",
      review_max_passes: 2
    )

    issue = %Issue{
      id: "issue-review-head-missing",
      identifier: "MT-704Y",
      state: "In Review",
      title: "Handle missing head continuity",
      description: "Review gates should not report current without a known head",
      url: "https://example.org/issues/MT-704Y",
      branch_name: "feature/review-head-missing",
      labels: ["symphony"],
      comments: [
        %{
          id: "comment-1",
          body:
            "## Symphony Workpad\n\n```yaml\nsymphony:\n  phase: waiting_for_checks\n  branch: feature/review-head-missing\n  pr:\n    number: 91\n    url: https://github.com/acme/widgets/pull/91\n    head_sha: null\n  review:\n    comment_id: 555\n    passes_completed: 1\n    last_reviewed_head_sha: abc123\n```",
          updated_at: DateTime.utc_now()
        }
      ]
    }

    try do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Process.put(:github_runner_results, [
        {:ok,
         Jason.encode!([
           %{
             "number" => 91,
             "url" => "https://github.com/acme/widgets/pull/91",
             "state" => "OPEN",
             "isDraft" => false,
             "headRefName" => "feature/review-head-missing",
             "headRefOid" => nil,
             "baseRefName" => "main"
           }
         ])}
      ])

      runner = fn _command, _args, _opts ->
        case Process.get(:github_runner_results) do
          [result | rest] ->
            Process.put(:github_runner_results, rest)
            result

          _ ->
            {:error, :no_github_result}
        end
      end

      issue_fetcher = fn ["issue-review-head-missing"] -> {:ok, [issue]} end

      assert {:ok, updated_issue} =
               OrchestrationLifecycle.reconcile_after_run_for_test(
                 "issue-review-head-missing",
                 %{workspace_path: nil, worker_host: nil},
                 runner: runner,
                 issue_fetcher: issue_fetcher,
                 repo_slug: "acme/widgets",
                 tracker_module: Memory
               )

      runtime = SymphonyElixir.OrchestrationPolicy.issue_runtime(updated_issue, Config.settings!())
      assert runtime.workpad.metadata["observation"]["gates"]["review"] == "missing"
    after
      if is_nil(previous_memory_issues),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_issues),
        else: Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)

      if is_nil(previous_memory_recipient),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_recipient),
        else: Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_memory_recipient)
    end
  end

  test "post-run lifecycle keeps the issue in reviewing when review comment persistence fails" do
    test_root = Path.join(System.tmp_dir!(), "symphony-review-failure-#{System.unique_integer([:positive])}")
    origin_repo = Path.join(test_root, "origin.git")
    repo = Path.join(test_root, "repo")
    review_path = ReviewArtifact.path_for_test(repo)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "mutate",
      orchestration_required_label: "symphony",
      orchestration_required_workpad_marker: "## Symphony Workpad",
      pr_auto_create: true,
      pr_required_labels: [],
      pr_review_comment_mode: "upsert",
      review_enabled: true,
      review_agent: "pr-reviewer",
      review_output_format: "structured_markdown_v1",
      review_max_passes: 2
    )

    issue = %Issue{
      id: "issue-review-failure",
      identifier: "MT-704W",
      state: "In Progress",
      title: "Handle review upsert failures",
      description: "Stay in reviewing until the comment is persisted",
      url: "https://example.org/issues/MT-704W",
      branch_name: "feature/review-failure",
      labels: ["symphony"],
      comments: []
    }

    try do
      File.mkdir_p!(test_root)
      System.cmd("git", ["init", "--bare", origin_repo])
      System.cmd("git", ["init", "-b", "feature/review-failure", repo])
      System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      File.write!(Path.join(repo, "README.md"), "# review failure\n")
      System.cmd("git", ["-C", repo, "add", "README.md"])
      System.cmd("git", ["-C", repo, "commit", "-m", "initial"])
      System.cmd("git", ["-C", repo, "remote", "add", "origin", origin_repo])
      System.cmd("git", ["-C", repo, "push", "-u", "origin", "feature/review-failure"])
      {head_sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])
      File.mkdir_p!(Path.dirname(review_path))
      File.write!(review_path, "<!-- symphony-review-head: #{String.trim(head_sha)} -->\n\n### Findings\n\n- Please persist this review.")

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Process.put(:github_runner_results, [
        {:ok, "[]"},
        {:ok, "https://github.com/acme/widgets/pull/89\n"},
        {:ok,
         Jason.encode!([
           %{
             "number" => 89,
             "url" => "https://github.com/acme/widgets/pull/89",
             "state" => "OPEN",
             "isDraft" => false,
             "headRefName" => "feature/review-failure",
             "headRefOid" => String.trim(head_sha),
             "baseRefName" => "main"
           }
         ])},
        {:error, {1, "boom"}}
      ])

      runner = fn _command, _args, _opts ->
        case Process.get(:github_runner_results) do
          [result | rest] ->
            Process.put(:github_runner_results, rest)
            result

          _ ->
            {:error, :no_github_result}
        end
      end

      issue_fetcher = fn ["issue-review-failure"] -> {:ok, [issue]} end

      assert {:ok, updated_issue} =
               OrchestrationLifecycle.reconcile_after_run_for_test(
                 "issue-review-failure",
                 %{workspace_path: repo, worker_host: nil},
                 runner: runner,
                 issue_fetcher: issue_fetcher,
                 repo_slug: "acme/widgets",
                 tracker_module: Memory
               )

      runtime = SymphonyElixir.OrchestrationPolicy.issue_runtime(updated_issue, Config.settings!())
      assert runtime.phase == "reviewing"
      assert runtime.workpad.metadata["observation"]["next_intended_action"] == "repair_review_comment_persistence"
      assert runtime.workpad.metadata["review"]["passes_completed"] == 0
      assert runtime.workpad.metadata["observation"]["gates"]["review"] == "tool_unavailable"
    after
      File.rm_rf(test_root)

      if is_nil(previous_memory_issues),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_issues),
        else: Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)

      if is_nil(previous_memory_recipient),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_recipient),
        else: Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_memory_recipient)
    end
  end

  test "workpad sync recovers ambiguous duplicate comments by archiving extras" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      orchestration_required_label: "symphony",
      orchestration_required_workpad_marker: "## Symphony Workpad"
    )

    issue = %Issue{
      id: "issue-ambiguous",
      identifier: "MT-702",
      state: "In Review",
      title: "Ambiguous workpad",
      description: "Recover duplicate workpads",
      labels: ["symphony"],
      comments: [
        %{
          id: "comment-new",
          body: "## Symphony Workpad\n\n```yaml\nsymphony:\n  phase: waiting_for_checks\n```",
          updated_at: DateTime.utc_now()
        },
        %{
          id: "comment-old",
          body: "## Symphony Workpad\n\n```yaml\nsymphony:\n  phase: implementing\n```",
          updated_at: DateTime.add(DateTime.utc_now(), -120, :second)
        }
      ]
    }

    try do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      assert {:ok, updated_issue} = Workpad.sync_for_test(issue, %{}, tracker_module: Memory)
      runtime = SymphonyElixir.OrchestrationPolicy.issue_runtime(updated_issue, Config.settings!())

      assert runtime.phase == "blocked"
      assert runtime.waiting_reason == "metadata_recovery_required"
      assert runtime.workpad.metadata_status == "ok"
      assert Enum.count(updated_issue.comments, fn comment -> String.contains?(comment.body, "## Symphony Workpad") end) == 1
      assert Enum.any?(updated_issue.comments, fn comment -> String.starts_with?(comment.body, "## Archived Symphony Workpad") end)
      assert_receive {:memory_tracker_comment_update, "comment-new", _body}
      assert_receive {:memory_tracker_comment_update, "comment-old", _body}
    after
      if is_nil(previous_memory_issues),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_issues),
        else: Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)

      if is_nil(previous_memory_recipient),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_recipient),
        else: Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_memory_recipient)
    end
  end

  test "candidate lifecycle bootstrap skips issues not routed to this worker when no label gate is configured" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "In Review"],
      orchestration_required_label: nil,
      orchestration_required_workpad_marker: "## Symphony Workpad"
    )

    issue = %Issue{
      id: "issue-unowned-bootstrap",
      identifier: "MT-703U",
      state: "Todo",
      title: "Do not mutate unowned issues",
      description: "Bootstrap should skip issues routed elsewhere",
      labels: [],
      comments: [],
      assigned_to_worker: false
    }

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      completed: MapSet.new(),
      retry_attempts: %{},
      tracked: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    try do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      [same_issue] = Orchestrator.reconcile_candidate_issue_lifecycles_for_test([issue], state)
      refute_receive {:memory_tracker_comment, _, _}
      assert same_issue.comments == []
    after
      if is_nil(previous_memory_issues),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_issues),
        else: Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)

      if is_nil(previous_memory_recipient),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_recipient),
        else: Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_memory_recipient)
    end
  end

  test "candidate lifecycle bootstrap creates a missing workpad for owned issues before dispatch" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "In Review"],
      orchestration_required_label: "symphony",
      orchestration_required_workpad_marker: "## Symphony Workpad"
    )

    issue = %Issue{
      id: "issue-bootstrap",
      identifier: "MT-703",
      state: "Todo",
      title: "Bootstrap workpad",
      description: "Create the missing workpad before dispatch",
      labels: ["symphony"],
      comments: []
    }

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      completed: MapSet.new(),
      retry_attempts: %{},
      tracked: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    try do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      [bootstrapped_issue] = Orchestrator.reconcile_candidate_issue_lifecycles_for_test([issue], state)
      assert_receive {:memory_tracker_comment, "issue-bootstrap", _body}
      assert Orchestrator.should_dispatch_issue_for_test(bootstrapped_issue, state)
      assert Enum.any?(bootstrapped_issue.comments, fn comment -> String.contains?(comment.body, "## Symphony Workpad") end)
    after
      if is_nil(previous_memory_issues),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_issues),
        else: Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)

      if is_nil(previous_memory_recipient),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_recipient),
        else: Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_memory_recipient)
    end
  end

  test "post-run lifecycle preserves later PR phases when it only reuses an existing open PR" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "mutate",
      orchestration_required_label: "symphony",
      orchestration_required_workpad_marker: "## Symphony Workpad",
      pr_auto_create: true,
      pr_required_labels: []
    )

    issue = %Issue{
      id: "issue-pr-reuse",
      identifier: "MT-704R",
      state: "In Review",
      title: "Keep later phase",
      description: "Do not regress waiting_for_human",
      url: "https://example.org/issues/MT-704R",
      branch_name: "feature/pr-reuse",
      labels: ["symphony"],
      comments: [
        %{
          id: "comment-1",
          body: "## Symphony Workpad\n\n```yaml\nsymphony:\n  phase: waiting_for_human\n  branch: feature/pr-reuse\n```",
          updated_at: DateTime.utc_now()
        }
      ]
    }

    try do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Process.put(:github_runner_results, [
        {:ok,
         Jason.encode!([
           %{
             "number" => 99,
             "url" => "https://github.com/acme/widgets/pull/99",
             "state" => "OPEN",
             "isDraft" => false,
             "headRefName" => "feature/pr-reuse",
             "headRefOid" => "reuse123",
             "baseRefName" => "main"
           }
         ])}
      ])

      runner = fn _command, _args, _opts ->
        case Process.get(:github_runner_results) do
          [result | rest] ->
            Process.put(:github_runner_results, rest)
            result

          _ ->
            {:error, :no_github_result}
        end
      end

      issue_fetcher = fn ["issue-pr-reuse"] -> {:ok, [issue]} end

      assert {:ok, updated_issue} =
               OrchestrationLifecycle.reconcile_after_run_for_test(
                 "issue-pr-reuse",
                 %{workspace_path: nil, worker_host: nil},
                 runner: runner,
                 issue_fetcher: issue_fetcher,
                 repo_slug: "acme/widgets",
                 tracker_module: Memory
               )

      runtime = SymphonyElixir.OrchestrationPolicy.issue_runtime(updated_issue, Config.settings!())
      assert runtime.phase == "waiting_for_human"
      assert runtime.waiting_reason == nil
      assert runtime.workpad.metadata["pr"]["number"] == 99
    after
      if is_nil(previous_memory_issues),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_issues),
        else: Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)

      if is_nil(previous_memory_recipient),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_recipient),
        else: Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_memory_recipient)
    end
  end

  test "post-run lifecycle creates or reuses a PR and moves the workpad into waiting_for_checks" do
    test_root = Path.join(System.tmp_dir!(), "symphony-pr-lifecycle-#{System.unique_integer([:positive])}")
    origin_repo = Path.join(test_root, "origin.git")
    repo = Path.join(test_root, "repo")
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "mutate",
      orchestration_required_label: "symphony",
      orchestration_required_workpad_marker: "## Symphony Workpad",
      pr_auto_create: true,
      pr_required_labels: []
    )

    issue = %Issue{
      id: "issue-pr-lifecycle",
      identifier: "MT-704",
      state: "In Review",
      title: "Publish PR",
      description: "Create or reuse a branch PR",
      url: "https://example.org/issues/MT-704",
      branch_name: "feature/pr-lifecycle",
      labels: ["symphony"],
      comments: []
    }

    try do
      File.mkdir_p!(test_root)
      System.cmd("git", ["init", "--bare", origin_repo])
      System.cmd("git", ["init", "-b", "feature/pr-lifecycle", repo])
      System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      File.write!(Path.join(repo, "README.md"), "# lifecycle\n")
      System.cmd("git", ["-C", repo, "add", "README.md"])
      System.cmd("git", ["-C", repo, "commit", "-m", "initial"])
      System.cmd("git", ["-C", repo, "remote", "add", "origin", origin_repo])
      System.cmd("git", ["-C", repo, "push", "-u", "origin", "feature/pr-lifecycle"])
      {head_sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Process.put(:github_runner_results, [
        {:ok, "[]"},
        {:ok, "https://github.com/acme/widgets/pull/88\n"},
        {:ok,
         Jason.encode!([
           %{
             "number" => 88,
             "url" => "https://github.com/acme/widgets/pull/88",
             "state" => "OPEN",
             "isDraft" => false,
             "headRefName" => "feature/pr-lifecycle",
             "headRefOid" => String.trim(head_sha),
             "baseRefName" => "main"
           }
         ])}
      ])

      runner = fn command, args, _opts ->
        send(self(), {:github_command, command, args})

        case Process.get(:github_runner_results) do
          [result | rest] ->
            Process.put(:github_runner_results, rest)
            result

          _ ->
            {:error, :no_github_result}
        end
      end

      issue_fetcher = fn ["issue-pr-lifecycle"] -> {:ok, [issue]} end

      assert {:ok, updated_issue} =
               OrchestrationLifecycle.reconcile_after_run_for_test(
                 "issue-pr-lifecycle",
                 %{workspace_path: repo, worker_host: nil},
                 runner: runner,
                 issue_fetcher: issue_fetcher,
                 repo_slug: "acme/widgets",
                 tracker_module: Memory
               )

      runtime = SymphonyElixir.OrchestrationPolicy.issue_runtime(updated_issue, Config.settings!())
      assert runtime.phase == "waiting_for_checks"
      assert runtime.waiting_reason == "checks_pending"
      assert runtime.workpad.metadata["pr"]["number"] == 88
      assert runtime.workpad.metadata["pr"]["url"] == "https://github.com/acme/widgets/pull/88"
      assert runtime.workpad.metadata["pr"]["head_sha"] == String.trim(head_sha)
      assert_receive {:memory_tracker_comment, "issue-pr-lifecycle", _body}
      assert_receive {:github_command, "gh", ["pr", "create" | _]}
    after
      File.rm_rf(test_root)

      if is_nil(previous_memory_issues),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_issues),
        else: Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)

      if is_nil(previous_memory_recipient),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_recipient),
        else: Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_memory_recipient)
    end
  end
end
