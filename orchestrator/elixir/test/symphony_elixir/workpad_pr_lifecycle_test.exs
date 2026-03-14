defmodule SymphonyElixir.WorkpadPrLifecycleTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Memory

  test "workspace git inspects local branch, head sha, and repo slug" do
    test_root = Path.join(System.tmp_dir!(), "symphony-workspace-git-#{System.unique_integer([:positive])}")
    repo = Path.join(test_root, "repo")

    try do
      File.mkdir_p!(repo)
      System.cmd("git", ["-C", repo, "init", "-b", "feature/workpad-lifecycle"])
      System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      File.write!(Path.join(repo, "README.md"), "# demo\n")
      System.cmd("git", ["-C", repo, "add", "README.md"])
      System.cmd("git", ["-C", repo, "commit", "-m", "initial"])
      System.cmd("git", ["-C", repo, "remote", "add", "origin", "git@github.com:acme/widgets.git"])
      {head_sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])

      assert {:ok, git_state} = WorkspaceGit.inspect_for_test(repo)
      assert git_state.branch == "feature/workpad-lifecycle"
      assert git_state.repo_slug == "acme/widgets"
      assert git_state.head_sha == String.trim(head_sha)
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
             PullRequests.resolve_or_create_for_test(issue, %{repo_slug: "acme/widgets", branch: "feature/reuse-pr"}, runner: runner)

    assert pr_info.action == :reused
    assert pr_info.number == 42
    assert pr_info.url == "https://github.com/acme/widgets/pull/42"
    assert_receive {:github_command, "gh", ["pr", "list" | _]}
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
             PullRequests.resolve_or_create_for_test(issue, %{repo_slug: "acme/widgets", branch: "feature/create-pr"}, runner: runner)

    assert pr_info.action == :created
    assert pr_info.number == 77
    assert_receive {:github_command, "gh", ["pr", "create" | _]}
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

  test "post-run lifecycle creates or reuses a PR and moves the workpad into waiting_for_checks" do
    test_root = Path.join(System.tmp_dir!(), "symphony-pr-lifecycle-#{System.unique_integer([:positive])}")
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
      File.mkdir_p!(repo)
      System.cmd("git", ["-C", repo, "init", "-b", "feature/pr-lifecycle"])
      System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      File.write!(Path.join(repo, "README.md"), "# lifecycle\n")
      System.cmd("git", ["-C", repo, "add", "README.md"])
      System.cmd("git", ["-C", repo, "commit", "-m", "initial"])
      System.cmd("git", ["-C", repo, "remote", "add", "origin", "git@github.com:acme/widgets.git"])
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
