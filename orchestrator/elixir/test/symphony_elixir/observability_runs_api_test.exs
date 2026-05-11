defmodule SymphonyElixir.ObservabilityRunsApiTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.Observability.EventStore

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    github_runner = Application.get_env(:symphony_elixir, :github_command_runner)
    pr_refresh_timeout = Application.get_env(:symphony_elixir, :observability_pr_refresh_timeout_ms)
    EventStore.clear()

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
      restore_application_env(:github_command_runner, github_runner)
      restore_application_env(:observability_pr_refresh_timeout_ms, pr_refresh_timeout)
    end)

    :ok
  end

  test "GET /api/v1/runs lists run projections from orchestrator snapshot" do
    orchestrator_name = Module.concat(__MODULE__, :RunsListOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot()})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload =
      build_conn()
      |> get("/api/v1/runs")
      |> json_response(200)

    assert payload["counts"] == %{"active" => 1, "retrying" => 1, "tracked" => 2, "needs_attention" => 1, "merge_queued" => 1}

    assert [active, retrying] = payload["runs"]

    assert active["issue"]["identifier"] == "MT-ACTIVE"
    assert active["runtime"]["status"] == "active"
    assert active["runtime"]["phase"] == "implementing"
    assert active["worker"]["session_id"] == "session-active"
    assert active["workspace"]["path"] == "/tmp/workspaces/MT-ACTIVE"
    assert active["pr"]["number"] == 123
    assert active["attention"]["required"] == false

    assert retrying["issue"]["identifier"] == "MT-RETRY"
    assert retrying["runtime"]["status"] == "retrying"
    assert retrying["attention"] == %{"required" => true, "reason" => "blocked", "severity" => "warning"}

    assert payload["page_info"] == %{"has_next_page" => false, "limit" => 100, "next_cursor" => "MT-RETRY"}
  end

  test "GET /api/v1/runs paginates and hard-caps list responses" do
    orchestrator_name = Module.concat(__MODULE__, :RunsPaginationOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: many_tracked_snapshot(501)})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    first_page =
      build_conn()
      |> get("/api/v1/runs")
      |> json_response(200)

    assert length(first_page["runs"]) == 100
    assert first_page["page_info"] == %{"has_next_page" => true, "limit" => 100, "next_cursor" => "MT-PAGE-100"}

    second_page =
      build_conn()
      |> get("/api/v1/runs", %{cursor: first_page["page_info"]["next_cursor"], limit: "2"})
      |> json_response(200)

    assert Enum.map(second_page["runs"], &get_in(&1, ["issue", "identifier"])) == ["MT-PAGE-101", "MT-PAGE-102"]
    assert second_page["page_info"] == %{"has_next_page" => true, "limit" => 2, "next_cursor" => "MT-PAGE-102"}

    capped_page =
      build_conn()
      |> get("/api/v1/runs", %{limit: "999"})
      |> json_response(200)

    assert length(capped_page["runs"]) == 500
    assert capped_page["page_info"]["limit"] == 500
  end

  test "GET /api/v1/runs filters by final status after combining snapshot buckets" do
    orchestrator_name = Module.concat(__MODULE__, :RunsStatusFilterOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot()})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload =
      build_conn()
      |> get("/api/v1/runs", %{status: "tracked"})
      |> json_response(200)

    assert payload["runs"] == []
    assert payload["page_info"] == %{"has_next_page" => false, "limit" => 100, "next_cursor" => nil}
  end

  test "GET /api/v1/runs routes do not shadow the legacy issue wildcard route" do
    orchestrator_name = Module.concat(__MODULE__, :RunsLegacyWildcardOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot()})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert %{"run" => %{"issue" => %{"identifier" => "MT-ACTIVE"}}} =
             build_conn()
             |> get("/api/v1/runs/MT-ACTIVE")
             |> json_response(200)

    assert %{"issue_identifier" => "MT-ACTIVE", "status" => "running"} =
             build_conn()
             |> get("/api/v1/MT-ACTIVE")
             |> json_response(200)
  end

  test "GET /api/v1/runs/:issue_identifier returns run detail and 404s for missing runs" do
    orchestrator_name = Module.concat(__MODULE__, :RunsDetailOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot()})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload =
      build_conn()
      |> get("/api/v1/runs/MT-RETRY")
      |> json_response(200)

    assert payload["run"]["issue"]["identifier"] == "MT-RETRY"
    assert payload["run"]["attempts"]["current"] == 2
    assert payload["run"]["attempts"]["restart_count"] == 1
    assert payload["run"]["proof"]["events_path"] == "/tmp/proof/retry-events.jsonl"
    assert payload["run"]["workpad"]["comment_id"] == "comment-retry"
    assert payload["run"]["dependencies"]["blocked_by"] == [%{"id" => "issue-active", "identifier" => "MT-ACTIVE"}]

    assert build_conn()
           |> get("/api/v1/runs/MT-MISSING")
           |> json_response(404) == %{"error" => %{"code" => "issue_not_found", "message" => "Issue not found"}}
  end

  test "GET /api/v1/runs/:issue_identifier returns 503 for snapshot failures" do
    timeout_orchestrator_name = Module.concat(__MODULE__, :RunsDetailTimeoutOrchestrator)
    start_supervised!({StaticOrchestrator, name: timeout_orchestrator_name, snapshot: :timeout})
    start_test_endpoint(orchestrator: timeout_orchestrator_name, snapshot_timeout_ms: 50)

    assert build_conn()
           |> get("/api/v1/runs/MT-ACTIVE")
           |> json_response(503) == %{"error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}}
  end

  test "GET /api/v1/runs/:issue_identifier returns 503 for unavailable orchestrator" do
    unavailable_orchestrator_name = Module.concat(__MODULE__, :RunsDetailUnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator_name, snapshot_timeout_ms: 50)

    assert build_conn()
           |> get("/api/v1/runs/MT-ACTIVE")
           |> json_response(503) == %{"error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}}
  end

  test "GET /api/v1/runs/:issue_identifier/workspace returns detail-only local workspace status" do
    workspace = Path.join(Config.settings!().workspace.root, "MT-ACTIVE-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    git!(workspace, ["init"])
    git!(workspace, ["config", "user.email", "symphony@example.test"])
    git!(workspace, ["config", "user.name", "Symphony Test"])
    git!(workspace, ["checkout", "-b", "symphony/MT-ACTIVE"])
    File.write!(Path.join(workspace, "README.md"), "hello")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "initial"])
    File.write!(Path.join(workspace, "dirty.txt"), "dirty")

    orchestrator_name = Module.concat(__MODULE__, :RunsWorkspaceOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(%{workspace_path: workspace})})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload =
      build_conn()
      |> get("/api/v1/runs/MT-ACTIVE/workspace")
      |> json_response(200)

    assert payload["issue_identifier"] == "MT-ACTIVE"
    assert payload["workspace"]["path"] == workspace
    assert payload["workspace"]["exists"] == true
    assert payload["workspace"]["branch"] == "symphony/MT-ACTIVE"
    assert is_binary(payload["workspace"]["head_sha"])
    assert payload["workspace"]["dirty"] == true
    assert payload["workspace"]["remote_branch_published"] == false
    assert payload["workspace"]["source"] == "snapshot+local_git"
  end

  test "GET /api/v1/runs/:issue_identifier/workspace does not inspect paths outside workspace root" do
    outside_workspace = Path.join(System.tmp_dir!(), "symphony-outside-workspace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside_workspace)
    git!(outside_workspace, ["init"])
    git!(outside_workspace, ["checkout", "-b", "outside-branch"])

    orchestrator_name = Module.concat(__MODULE__, :RunsWorkspaceOutsideRootOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(%{workspace_path: outside_workspace})})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload =
      build_conn()
      |> get("/api/v1/runs/MT-ACTIVE/workspace")
      |> json_response(200)

    assert payload["workspace"]["path"] == outside_workspace
    assert payload["workspace"]["exists"] == false
    assert payload["workspace"]["branch"] == "symphony/MT-ACTIVE"
    assert payload["workspace"]["dirty"] == nil
    assert payload["workspace"]["source"] == "snapshot"
  end

  test "GET /api/v1/runs/:issue_identifier/workspace does not follow workspace symlinks outside root" do
    outside_workspace = Path.join(System.tmp_dir!(), "symphony-outside-symlink-workspace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside_workspace)
    symlink_path = Path.join(Config.settings!().workspace.root, "MT-ACTIVE-symlink-#{System.unique_integer([:positive])}")
    File.ln_s!(outside_workspace, symlink_path)

    orchestrator_name = Module.concat(__MODULE__, :RunsWorkspaceSymlinkOutsideRootOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(%{workspace_path: symlink_path})})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload =
      build_conn()
      |> get("/api/v1/runs/MT-ACTIVE/workspace")
      |> json_response(200)

    assert payload["workspace"]["path"] == symlink_path
    assert payload["workspace"]["exists"] == false
    assert payload["workspace"]["dirty"] == nil
    assert payload["workspace"]["source"] == "snapshot"
  end

  test "GET /api/v1/runs/:issue_identifier/workspace fails closed for long symlink chains" do
    outside_workspace = Path.join(System.tmp_dir!(), "symphony-outside-long-symlink-workspace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside_workspace)
    symlink_root = Path.join(Config.settings!().workspace.root, "MT-ACTIVE-long-symlink-#{System.unique_integer([:positive])}")
    symlink_path = create_symlink_chain!(symlink_root, outside_workspace, 25)

    orchestrator_name = Module.concat(__MODULE__, :RunsWorkspaceLongSymlinkOutsideRootOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(%{workspace_path: symlink_path})})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload =
      build_conn()
      |> get("/api/v1/runs/MT-ACTIVE/workspace")
      |> json_response(200)

    assert payload["workspace"]["path"] == symlink_path
    assert payload["workspace"]["exists"] == false
    assert payload["workspace"]["dirty"] == nil
    assert payload["workspace"]["source"] == "snapshot"
  end

  test "GET /api/v1/runs/:issue_identifier/pr returns cached and opt-in live PR projections" do
    parent = self()

    Application.put_env(:symphony_elixir, :github_command_runner, fn command, args, _opts ->
      send(parent, {:github_command, command, args})

      {:ok,
       Jason.encode!(%{
         "number" => 123,
         "url" => "https://github.com/acme/widgets/pull/123",
         "state" => "OPEN",
         "isDraft" => false,
         "headRefName" => "symphony/MT-ACTIVE",
         "headRefOid" => "abc123",
         "baseRefName" => "main",
         "mergeStateStatus" => "CLEAN",
         "mergeable" => "MERGEABLE",
         "reviewDecision" => "APPROVED",
         "statusCheckRollup" => [
           %{"status" => "COMPLETED", "conclusion" => "SUCCESS"},
           %{"status" => "COMPLETED", "conclusion" => "SUCCESS"}
         ],
         "mergeCommit" => nil
       })}
    end)

    orchestrator_name = Module.concat(__MODULE__, :RunsPrOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(%{})})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload =
      build_conn()
      |> get("/api/v1/runs/MT-ACTIVE/pr")
      |> json_response(200)

    assert payload["issue_identifier"] == "MT-ACTIVE"
    assert payload["pr"]["source"] == "cached"
    assert payload["pr"]["number"] == 123
    assert payload["pr"]["checks"] == %{"state" => "pass", "passing" => 2, "pending" => 0, "failing" => 0, "total" => 2, "items" => []}
    assert payload["pr"]["review"]["symphony_review_state"] == "current"
    assert payload["pr"]["review"]["decision"] == "APPROVED"
    assert payload["pr"]["review"]["current_for_head"] == true
    assert payload["pr"]["mergeability"] == %{"state" => "pass", "mergeable" => "MERGEABLE", "merge_state_status" => "CLEAN"}
    assert payload["pr"]["gates"]["human_approval"] == "approved"
    assert payload["pr"]["merge"]["failure_reason"] == "merge_queue_failed"
    assert payload["pr"]["next_intended_action"] == "merge_when_green"
    refute_received {:github_command, _, _}

    live_payload =
      build_conn()
      |> get("/api/v1/runs/MT-ACTIVE/pr", %{refresh: "true"})
      |> json_response(200)

    assert_receive {:github_command, "gh", ["pr", "view", "123", "--repo", "acme/widgets" | _]}
    assert live_payload["issue_identifier"] == "MT-ACTIVE"
    assert live_payload["pr"]["source"] == "live"
    assert live_payload["pr"]["state"] == "OPEN"
    assert live_payload["pr"]["draft"] == false
    assert live_payload["pr"]["head_sha"] == "abc123"
    assert live_payload["pr"]["checks"] == %{"state" => "pass", "passing" => 2, "pending" => 0, "failing" => 0, "total" => 2, "items" => []}
    assert live_payload["pr"]["review"]["decision"] == "APPROVED"
    assert live_payload["pr"]["review"]["symphony_review_state"] == "current"
    assert live_payload["pr"]["review"]["current_for_head"] == true
    assert live_payload["pr"]["mergeability"] == %{"state" => "pass", "mergeable" => "MERGEABLE", "merge_state_status" => "CLEAN"}
    assert live_payload["pr"]["gates"]["pr"] == "open"
    assert live_payload["pr"]["gates"]["checks"] == "pass"
    assert live_payload["pr"]["gates"]["mergeability"] == "pass"
  end

  test "GET /api/v1/runs/:issue_identifier/pr live refresh failure does not expose raw command output" do
    secret_output = String.duplicate("super-secret-gh-output", 200)

    Application.put_env(:symphony_elixir, :github_command_runner, fn _command, _args, _opts ->
      {:error, {1, secret_output}}
    end)

    orchestrator_name = Module.concat(__MODULE__, :RunsPrFailureOutputOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(%{})})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert %{"error" => %{"code" => "pr_refresh_failed", "message" => message}} =
             build_conn()
             |> get("/api/v1/runs/MT-ACTIVE/pr", %{refresh: "true"})
             |> json_response(502)

    assert message == "Live PR refresh failed: gh exited with status 1"
    refute message =~ "super-secret"
  end

  test "GET /api/v1/runs/:issue_identifier/pr live refresh unexpected JSON shape returns sanitized failure" do
    Application.put_env(:symphony_elixir, :github_command_runner, fn _command, _args, _opts ->
      {:ok, "[]"}
    end)

    orchestrator_name = Module.concat(__MODULE__, :RunsPrUnexpectedJsonShapeOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(%{})})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert build_conn()
           |> get("/api/v1/runs/MT-ACTIVE/pr", %{refresh: "true"})
           |> json_response(502) == %{
             "error" => %{
               "code" => "pr_refresh_failed",
               "message" => "Live PR refresh failed: :invalid_pr_view_response"
             }
           }
  end

  test "GET /api/v1/runs/:issue_identifier/pr live refresh invalid JSON does not expose raw command output" do
    secret_output = String.duplicate("super-secret-json-output", 200)

    Application.put_env(:symphony_elixir, :github_command_runner, fn _command, _args, _opts ->
      {:ok, "{#{secret_output}"}
    end)

    orchestrator_name = Module.concat(__MODULE__, :RunsPrInvalidJsonOutputOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(%{})})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert %{"error" => %{"code" => "pr_refresh_failed", "message" => message}} =
             build_conn()
             |> get("/api/v1/runs/MT-ACTIVE/pr", %{refresh: "true"})
             |> json_response(502)

    assert message == "Live PR refresh failed: invalid GitHub response JSON"
    refute message =~ "super-secret"
  end

  test "GET /api/v1/runs/:issue_identifier/pr live refresh times out bounded GitHub reads" do
    Application.put_env(:symphony_elixir, :observability_pr_refresh_timeout_ms, 1)

    Application.put_env(:symphony_elixir, :github_command_runner, fn _command, _args, _opts ->
      Process.sleep(50)
      {:ok, "{}"}
    end)

    orchestrator_name = Module.concat(__MODULE__, :RunsPrTimeoutOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(%{})})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert build_conn()
           |> get("/api/v1/runs/MT-ACTIVE/pr", %{refresh: "true"})
           |> json_response(504) == %{"error" => %{"code" => "pr_refresh_timeout", "message" => "Live PR refresh timed out"}}
  end

  test "GET /api/v1/runs/:issue_identifier/pr live refresh reports missing PR context without GitHub calls" do
    parent = self()

    Application.put_env(:symphony_elixir, :github_command_runner, fn command, args, _opts ->
      send(parent, {:github_command, command, args})
      {:error, :unexpected_call}
    end)

    orchestrator_name = Module.concat(__MODULE__, :RunsPrMissingContextOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(%{})})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert %{"error" => %{"code" => "pr_refresh_skipped", "message" => message}} =
             build_conn()
             |> get("/api/v1/runs/MT-RETRY/pr", %{refresh: "true"})
             |> json_response(422)

    assert message =~ "missing_repo_slug"
    refute_received {:github_command, _, _}
  end

  test "GET /api/v1/runs/:issue_identifier/logs reads bounded known artifacts only" do
    artifacts = write_artifacts!()
    orchestrator_name = Module.concat(__MODULE__, :RunsLogsOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(artifacts)})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    session_payload =
      build_conn()
      |> get("/api/v1/runs/MT-ACTIVE/logs", %{kind: "session"})
      |> json_response(200)

    assert session_payload["kind"] == "session"
    assert session_payload["entries"] == [%{"event" => "started"}, %{"raw" => "not-json"}]
    assert session_payload["limit_bytes"] == 65_536

    proof_events_payload =
      build_conn()
      |> get("/api/v1/runs/MT-ACTIVE/logs", %{kind: "proof_events"})
      |> json_response(200)

    assert proof_events_payload["entries"] == [%{"event" => "proof"}]

    summary_payload =
      build_conn()
      |> get("/api/v1/runs/MT-ACTIVE/logs", %{kind: "proof_summary"})
      |> json_response(200)

    assert summary_payload["summary"] == %{"ok" => true, "tests" => 3}

    stderr_payload =
      build_conn()
      |> get("/api/v1/runs/MT-ACTIVE/logs", %{kind: "stderr", limit_bytes: "4"})
      |> json_response(200)

    assert stderr_payload["content"] == "abcd"
    assert stderr_payload["bytes_read"] == 4
    assert stderr_payload["truncated"] == true
    assert stderr_payload["next_offset"] == 4

    assert build_conn()
           |> get("/api/v1/runs/MT-ACTIVE/logs", %{kind: "unknown"})
           |> json_response(400) == %{"error" => %{"code" => "invalid_kind", "message" => "Invalid log kind"}}
  end

  test "legacy GET /api/v1/transcript/:issue_identifier is backed by the safe session artifact reader" do
    artifacts = write_artifacts!()
    orchestrator_name = Module.concat(__MODULE__, :RunsTranscriptOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(artifacts)})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload =
      build_conn()
      |> get("/api/v1/transcript/MT-ACTIVE")
      |> json_response(200)

    assert payload["issue_identifier"] == "MT-ACTIVE"
    assert payload["file"] == "session.jsonl"
    assert payload["entries"] == [%{"event" => "started"}, %{"raw" => "not-json"}]
    assert payload["truncated"] == false
  end

  test "legacy GET /api/v1/transcript/:issue_identifier preserves the legacy 500-entry cap" do
    artifacts = write_artifacts!()

    many_lines =
      1..600
      |> Enum.map(&Jason.encode!(%{event: "line", n: &1}))
      |> Enum.join("\n")

    File.write!(artifacts.session_file, many_lines <> "\n")

    orchestrator_name = Module.concat(__MODULE__, :RunsTranscriptCapOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(artifacts)})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload =
      build_conn()
      |> get("/api/v1/transcript/MT-ACTIVE")
      |> json_response(200)

    assert length(payload["entries"]) == 500
    assert payload["truncated"] == true
  end

  test "legacy GET /api/v1/transcript/:issue_identifier does not infer session files from session_dir" do
    artifacts = write_artifacts!()
    File.write!(Path.join(artifacts.session_dir, "zzzz-untracked.jsonl"), Jason.encode!(%{event: "untracked"}) <> "\n")
    artifacts_without_session_file = Map.delete(artifacts, :session_file)

    orchestrator_name = Module.concat(__MODULE__, :RunsTranscriptNoSessionFallbackOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(artifacts_without_session_file)})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert build_conn()
           |> get("/api/v1/transcript/MT-ACTIVE")
           |> json_response(404) == %{"error" => %{"code" => "no_session_file", "message" => "No session file available for this issue"}}
  end

  test "legacy GET /api/v1/transcript/:issue_identifier rejects symlinks that escape allowed roots" do
    artifacts = write_artifacts!()
    outside = Path.join(System.tmp_dir!(), "symphony-transcript-secret-#{System.unique_integer([:positive])}.txt")
    File.write!(outside, "secret")
    File.rm!(artifacts.session_file)
    File.ln_s!(outside, artifacts.session_file)

    orchestrator_name = Module.concat(__MODULE__, :RunsTranscriptUnsafeOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(artifacts)})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert build_conn()
           |> get("/api/v1/transcript/MT-ACTIVE")
           |> json_response(403) == %{"error" => %{"code" => "unsafe_path", "message" => "Artifact path is outside allowed roots"}}
  end

  test "ArtifactReader rejects long metadata symlink chains before they escape allowed roots" do
    artifacts = write_artifacts!()
    outside = Path.join(System.tmp_dir!(), "symphony-long-symlink-secret-#{System.unique_integer([:positive])}.txt")
    File.write!(outside, "secret")
    File.rm!(artifacts.session_file)
    first_link = create_symlink_chain!(artifacts.session_file, outside, 25)

    artifacts = Map.put(artifacts, :session_file, first_link)
    orchestrator_name = Module.concat(__MODULE__, :RunsLogsLongSymlinkUnsafeOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(artifacts)})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert build_conn()
           |> get("/api/v1/runs/MT-ACTIVE/logs", %{kind: "session"})
           |> json_response(403) == %{"error" => %{"code" => "unsafe_path", "message" => "Artifact path is outside allowed roots"}}
  end

  test "ArtifactReader rejects metadata symlinks that escape allowed roots" do
    artifacts = write_artifacts!()
    outside = Path.join(System.tmp_dir!(), "symphony-secret-#{System.unique_integer([:positive])}.txt")
    File.write!(outside, "secret")
    File.rm!(artifacts.session_file)
    File.ln_s!(outside, artifacts.session_file)

    orchestrator_name = Module.concat(__MODULE__, :RunsLogsUnsafeOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(artifacts)})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert build_conn()
           |> get("/api/v1/runs/MT-ACTIVE/logs", %{kind: "session"})
           |> json_response(403) == %{"error" => %{"code" => "unsafe_path", "message" => "Artifact path is outside allowed roots"}}
  end

  test "ArtifactReader rejects app root files outside the configured log directory" do
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)
    app_root = File.cwd!()
    outside_log_root = Path.join(app_root, "artifact-reader-outside-log-#{System.unique_integer([:positive])}.jsonl")

    on_exit(fn ->
      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end

      File.rm(outside_log_root)
    end)

    Application.put_env(:symphony_elixir, :log_file, Path.join([app_root, "log", "symphony.log"]))
    File.write!(outside_log_root, Jason.encode!(%{event: "outside"}) <> "\n")

    artifacts =
      write_artifacts!()
      |> Map.put(:session_file, outside_log_root)

    orchestrator_name = Module.concat(__MODULE__, :RunsLogsAppRootUnsafeOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(artifacts)})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert build_conn()
           |> get("/api/v1/runs/MT-ACTIVE/logs", %{kind: "session"})
           |> json_response(403) == %{"error" => %{"code" => "unsafe_path", "message" => "Artifact path is outside allowed roots"}}
  end

  test "ArtifactReader does not infer session files by enumerating session_dir" do
    artifacts = write_artifacts!()
    untracked_session_file = Path.join(artifacts.session_dir, "zzzz-untracked.jsonl")
    File.write!(untracked_session_file, Jason.encode!(%{event: "untracked"}) <> "\n")

    artifacts_without_session_file = Map.delete(artifacts, :session_file)

    orchestrator_name = Module.concat(__MODULE__, :RunsLogsNoSessionFallbackOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: phase_two_snapshot(artifacts_without_session_file)})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert build_conn()
           |> get("/api/v1/runs/MT-ACTIVE/logs", %{kind: "session"})
           |> json_response(404) == %{
             "error" => %{"code" => "no_artifact_path", "message" => "No artifact path is available for this run/kind"}
           }
  end

  test "legacy workspace listing uses orchestrator snapshot active identifiers instead of live tracker reads" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-observability-workspaces-#{System.unique_integer([:positive])}")
    active_workspace = Path.join(workspace_root, "MT_ACTIVE")
    stale_workspace = Path.join(workspace_root, "MT-STALE")
    File.mkdir_p!(active_workspace)
    File.mkdir_p!(stale_workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    snapshot = %{
      running: [%{identifier: "MT/ACTIVE"}],
      retrying: [],
      tracked: [],
      merge: %{queued: []},
      worker_totals: %{},
      rate_limits: nil
    }

    orchestrator_name = Module.concat(__MODULE__, :WorkspaceListingSnapshotOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload =
      build_conn()
      |> get("/api/v1/workspaces")
      |> json_response(200)

    assert payload["total"] == 2
    assert %{"identifier" => "MT_ACTIVE", "stale" => false} = Enum.find(payload["workspaces"], &(&1["identifier"] == "MT_ACTIVE"))
    assert %{"identifier" => "MT-STALE", "stale" => true} = Enum.find(payload["workspaces"], &(&1["identifier"] == "MT-STALE"))
  end

  test "GET /api/v1/runs/:issue_identifier/events and transitions read event store timelines" do
    orchestrator_name = Module.concat(__MODULE__, :RunsEventsOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot()})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, first} =
      EventStore.append(%{
        issue_id: "issue-active",
        issue_identifier: "MT-ACTIVE",
        type: "worker",
        name: "heartbeat",
        summary: "still running"
      })

    {:ok, _transition} =
      EventStore.append_phase_transition(%{
        issue_id: "issue-active",
        issue_identifier: "MT-ACTIVE",
        from: "implementing",
        to: "waiting_for_checks",
        tracker_state_from: "In Progress",
        tracker_state_to: "In Review",
        waiting_reason: "checks_pending",
        next_intended_action: "poll_on_next_cycle",
        source: "test",
        workpad_comment_id: "comment-active"
      })

    events_payload =
      build_conn()
      |> get("/api/v1/runs/MT-ACTIVE/events", %{cursor: first.id})
      |> json_response(200)

    assert events_payload["issue_identifier"] == "MT-ACTIVE"
    assert [%{"type" => "phase", "name" => "phase.changed"}] = events_payload["events"]

    transitions_payload =
      build_conn()
      |> get("/api/v1/runs/MT-ACTIVE/transitions")
      |> json_response(200)

    assert transitions_payload["issue_identifier"] == "MT-ACTIVE"
    assert [transition] = transitions_payload["transitions"]
    assert transition["from"] == "implementing"
    assert transition["to"] == "waiting_for_checks"
    assert transition["tracker_state_from"] == "In Progress"
    assert transition["tracker_state_to"] == "In Review"
    assert transition["waiting_reason"] == "checks_pending"
    assert transition["next_intended_action"] == "poll_on_next_cycle"
    assert transition["source"] == "test"
  end

  test "GET /api/v1/events returns a global cursor-paginated event feed" do
    orchestrator_name = Module.concat(__MODULE__, :GlobalEventsOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot()})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, first} = EventStore.append(%{issue_identifier: "MT-ACTIVE", type: "worker", name: "first"})
    {:ok, _second} = EventStore.append(%{issue_identifier: "MT-RETRY", type: "phase", name: "phase.changed"})
    {:ok, _third} = EventStore.append(%{issue_identifier: "MT-ACTIVE", type: "worker", name: "third"})

    payload =
      build_conn()
      |> get("/api/v1/events", %{cursor: first.id, type: "worker", limit: "1"})
      |> json_response(200)

    assert [%{"issue_identifier" => "MT-ACTIVE", "name" => "third"}] = payload["events"]
    assert payload["page_info"] == %{"has_next_page" => false, "next_cursor" => "evt_0000000003"}
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_application_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp create_symlink_chain!(first_link, target, link_count) when link_count > 0 do
    File.mkdir_p!(Path.dirname(first_link))

    links = Enum.map(0..(link_count - 1), &(first_link <> ".#{&1}"))
    [first | _rest] = links

    Enum.each(Enum.reverse(Enum.with_index(links)), fn {link, index} ->
      next = Enum.at(links, index + 1) || target
      File.rm(link)
      File.ln_s!(next, link)
    end)

    File.rm(first_link)
    File.ln_s!(first, first_link)
    first_link
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp write_artifacts! do
    root = Path.join(Config.settings!().workspace.root, "MT-ACTIVE-#{System.unique_integer([:positive])}")
    session_dir = Path.join(root, ".pi-session")
    proof_dir = Path.join(session_dir, "proof")
    File.mkdir_p!(proof_dir)

    session_file = Path.join(session_dir, "session.jsonl")
    proof_events_path = Path.join(proof_dir, "events.jsonl")
    proof_summary_path = Path.join(proof_dir, "summary.json")
    stderr_path = Path.join(session_dir, "stderr.log")

    File.write!(session_file, Jason.encode!(%{event: "started"}) <> "\nnot-json\n")
    File.write!(proof_events_path, Jason.encode!(%{event: "proof"}) <> "\n")
    File.write!(proof_summary_path, Jason.encode!(%{ok: true, tests: 3}))
    File.write!(stderr_path, "abcdef")

    %{
      workspace_path: root,
      session_dir: session_dir,
      session_file: session_file,
      proof_dir: proof_dir,
      proof_events_path: proof_events_path,
      proof_summary_path: proof_summary_path,
      stderr_path: stderr_path
    }
  end

  defp phase_two_snapshot(paths) do
    base = snapshot()
    active_running = hd(base.running)

    running_entry =
      active_running
      |> Map.merge(%{
        workspace_path: Map.get(paths, :workspace_path, active_running.workspace_path),
        session_dir: Map.get(paths, :session_dir),
        session_file: Map.get(paths, :session_file),
        proof_dir: Map.get(paths, :proof_dir),
        proof_events_path: Map.get(paths, :proof_events_path),
        proof_summary_path: Map.get(paths, :proof_summary_path),
        stderr_path: Map.get(paths, :stderr_path)
      })
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    tracked =
      Enum.map(base.tracked, fn
        %{issue_identifier: "MT-ACTIVE"} = entry ->
          put_in(entry, [:workpad], phase_two_workpad(entry.workpad))

        entry ->
          entry
      end)

    %{base | running: [running_entry], tracked: tracked}
  end

  defp phase_two_workpad(workpad) do
    workpad
    |> put_in([:metadata, "review"], %{"passes_completed" => 1, "last_reviewed_head_sha" => "abc123"})
    |> put_in([:metadata, "merge"], %{"last_attempted_head_sha" => "abc123", "last_failure_reason" => "merge_queue_failed"})
    |> put_in(
      [:observation],
      %{
        "last_observed_at" => "2026-05-11T10:00:00Z",
        "next_intended_action" => "merge_when_green",
        "gates" => %{
          "pr" => "open",
          "checks" => "pass",
          "checks_passing" => 2,
          "checks_pending" => 0,
          "checks_failing" => 0,
          "checks_total" => 2,
          "review" => "current",
          "review_decision" => "APPROVED",
          "human_approval" => "approved",
          "mergeability" => "pass",
          "mergeable" => "MERGEABLE",
          "merge_state_status" => "CLEAN"
        }
      }
    )
  end

  defp git!(workspace, args) do
    {output, status} = System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true)
    assert status == 0, output
    output
  end

  defp many_tracked_snapshot(count) do
    tracked =
      for index <- 1..count do
        identifier = "MT-PAGE-" <> String.pad_leading(Integer.to_string(index), 3, "0")

        %{
          issue_id: "issue-page-#{index}",
          issue_identifier: identifier,
          state: "Todo",
          labels: ["symphony"],
          phase: "implementing",
          phase_source: "workpad",
          passive_phase: false,
          dispatch_allowed: true,
          waiting_reason: nil,
          next_intended_action: "dispatch_worker",
          observed_at: ~U[2026-05-11 10:00:00Z],
          workpad: %{comment_id: "comment-page-#{index}", metadata_status: "ok", metadata: %{}},
          kill_switch: %{active: false},
          blocked_by: [],
          blocks: []
        }
      end

    %{
      running: [],
      retrying: [],
      tracked: tracked,
      merge: %{queued: [], in_progress_issue_id: nil, in_progress_issue_identifier: nil},
      worker_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }
  end

  defp snapshot do
    %{
      running: [
        %{
          issue_id: "issue-active",
          identifier: "MT-ACTIVE",
          state: "In Progress",
          workspace_path: "/tmp/workspaces/MT-ACTIVE",
          session_id: "session-active",
          worker_pid: 123,
          turn_count: 4,
          last_worker_event: :notification,
          last_worker_message: "working",
          last_worker_timestamp: ~U[2026-05-11 10:00:00Z],
          worker_input_tokens: 10,
          worker_output_tokens: 20,
          worker_total_tokens: 30,
          started_at: ~U[2026-05-11 09:55:00Z]
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          max_retries: 5,
          due_in_ms: 2_000,
          error: "boom",
          error_classification: "transient",
          workspace_path: "/tmp/workspaces/MT-RETRY",
          proof_events_path: "/tmp/proof/retry-events.jsonl"
        }
      ],
      tracked: [
        %{
          issue_id: "issue-active",
          issue_identifier: "MT-ACTIVE",
          state: "In Progress",
          labels: ["symphony"],
          phase: "implementing",
          phase_source: "workpad",
          passive_phase: false,
          dispatch_allowed: false,
          waiting_reason: nil,
          next_intended_action: "continue_worker",
          observed_at: ~U[2026-05-11 10:00:00Z],
          workpad: %{
            comment_id: "comment-active",
            metadata_status: "ok",
            phase_source: "workpad",
            metadata: %{
              "branch" => "symphony/MT-ACTIVE",
              "pr" => %{"number" => 123, "url" => "https://github.com/acme/widgets/pull/123", "head_sha" => "abc123"},
              "review" => %{"passes_completed" => 1}
            },
            observation: %{"last_observed_at" => "2026-05-11T10:00:00Z", "gates" => %{"checks" => "pending"}}
          },
          kill_switch: %{active: false},
          blocked_by: [],
          blocks: [%{id: "issue-retry", identifier: "MT-RETRY"}]
        },
        %{
          issue_id: "issue-retry",
          issue_identifier: "MT-RETRY",
          state: "Todo",
          labels: ["symphony"],
          phase: "blocked",
          phase_source: "workpad",
          passive_phase: true,
          dispatch_allowed: false,
          waiting_reason: "blocked",
          next_intended_action: "wait_for_dependency",
          observed_at: ~U[2026-05-11 10:00:00Z],
          workpad: %{comment_id: "comment-retry", metadata_status: "ok", metadata: %{}},
          kill_switch: %{active: false},
          blocked_by: [%{id: "issue-active", identifier: "MT-ACTIVE"}],
          blocks: []
        }
      ],
      merge: %{queued: [%{issue_id: "issue-active"}], in_progress_issue_id: nil, in_progress_issue_identifier: nil},
      worker_totals: %{input_tokens: 10, output_tokens: 20, total_tokens: 30, seconds_running: 1},
      rate_limits: nil
    }
  end
end
