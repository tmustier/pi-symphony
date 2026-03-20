defmodule SymphonyElixir.PiAnalyticsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PiAnalytics

  test "emit_symphony_run writes a local extract under the logs root by default" do
    logs_root = tmp_dir("symphony-pi-analytics-logs")
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)
    previous_local_dir = System.get_env("PI_ANALYTICS_LOCAL_DIR")
    previous_mirror_home = System.get_env("PI_ANALYTICS_MIRROR_HOME")
    previous_ledger_root = System.get_env("PI_ANALYTICS_LEDGER_ROOT")

    on_exit(fn ->
      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end

      restore_env("PI_ANALYTICS_LOCAL_DIR", previous_local_dir)
      restore_env("PI_ANALYTICS_MIRROR_HOME", previous_mirror_home)
      restore_env("PI_ANALYTICS_LEDGER_ROOT", previous_ledger_root)
      File.rm_rf(logs_root)
    end)

    Application.put_env(:symphony_elixir, :log_file, Path.join(logs_root, "log/symphony.log"))
    System.delete_env("PI_ANALYTICS_LOCAL_DIR")
    System.delete_env("PI_ANALYTICS_LEDGER_ROOT")
    System.put_env("PI_ANALYTICS_MIRROR_HOME", "0")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_team_key: "THO",
      tracker_project_slug: "booking-demo-polish",
      pi_model_provider: "anthropic",
      pi_model_id: "claude-sonnet-4-6",
      pi_thinking_level: "high"
    )

    now = ~U[2026-03-20 17:10:11Z]

    assert :ok =
             PiAnalytics.emit_symphony_run(sample_running_entry(),
               status: "success",
               notes: "agent_task_completed",
               now: now
             )

    output_path = Path.join(logs_root, "pi-analytics/2026-03-20.jsonl")
    [line] = File.read!(output_path) |> String.split("\n", trim: true)
    record = Jason.decode!(line)

    assert record["record_type"] == "symphony_run"
    assert record["issue_key"] == "THO-41"
    assert record["role"] == "worker"
    assert record["status"] == "success"
    assert record["phase"] == "implementing"
    assert record["repo_root"] == Path.dirname(Workflow.workflow_file_path()) |> Path.expand()
    assert record["workspace_path"] == "/tmp/workspaces/THO-41"
    assert record["session_id"] == "pi-session-turn-2"
    assert record["session_path"] == "/tmp/workspaces/THO-41/.pi/session.jsonl"
    assert record["artifacts_root"] == "/tmp/workspaces/THO-41/.pi/proof"
    assert record["team_key"] == "THO"
    assert record["linear_project"] == "booking-demo-polish"
    assert record["workflow_path"] == Path.expand(Workflow.workflow_file_path())
    assert record["model"] == "anthropic/claude-sonnet-4-6"
    assert record["thinking_level"] == "high"
    assert record["notes"] == "agent_task_completed"
    assert record["metrics"]["worker_total_tokens"] == 30
    assert record["metrics"]["turn_count"] == 2
    assert record["metrics"]["runtime_seconds"] == 71
    assert record["metrics"]["worker_host"] == "local"
  end

  test "emit_symphony_run mirrors to the home ledger when enabled" do
    local_dir = tmp_dir("symphony-pi-analytics-local")
    home_root = tmp_dir("symphony-pi-analytics-home")
    previous_local_dir = System.get_env("PI_ANALYTICS_LOCAL_DIR")
    previous_mirror_home = System.get_env("PI_ANALYTICS_MIRROR_HOME")
    previous_ledger_root = System.get_env("PI_ANALYTICS_LEDGER_ROOT")

    on_exit(fn ->
      restore_env("PI_ANALYTICS_LOCAL_DIR", previous_local_dir)
      restore_env("PI_ANALYTICS_MIRROR_HOME", previous_mirror_home)
      restore_env("PI_ANALYTICS_LEDGER_ROOT", previous_ledger_root)
      File.rm_rf(local_dir)
      File.rm_rf(home_root)
    end)

    System.put_env("PI_ANALYTICS_LOCAL_DIR", local_dir)
    System.put_env("PI_ANALYTICS_MIRROR_HOME", "1")
    System.put_env("PI_ANALYTICS_LEDGER_ROOT", home_root)

    now = ~U[2026-03-20 17:12:30Z]

    assert :ok =
             PiAnalytics.emit_symphony_run(sample_running_entry(),
               status: "waiting",
               notes: "continuation_retry_scheduled",
               metrics: %{retry_scheduled: true},
               now: now
             )

    local_path = Path.join(local_dir, "2026-03-20.jsonl")
    home_path = Path.join(home_root, "events/2026-03-20.jsonl")

    local_line = File.read!(local_path) |> String.trim()
    home_line = File.read!(home_path) |> String.trim()

    assert local_line == home_line

    record = Jason.decode!(local_line)
    assert record["status"] == "waiting"
    assert record["notes"] == "continuation_retry_scheduled"
    assert record["metrics"]["retry_scheduled"] == true
  end

  defp sample_running_entry do
    %{
      identifier: "THO-41",
      workspace_path: "/tmp/workspaces/THO-41",
      session_id: "pi-session-turn-2",
      session_file: "/tmp/workspaces/THO-41/.pi/session.jsonl",
      proof_dir: "/tmp/workspaces/THO-41/.pi/proof",
      proof_events_path: "/tmp/workspaces/THO-41/.pi/proof/events.jsonl",
      proof_summary_path: "/tmp/workspaces/THO-41/.pi/proof/summary.json",
      worker_host: nil,
      worker_input_tokens: 10,
      worker_output_tokens: 20,
      worker_total_tokens: 30,
      turn_count: 2,
      retry_attempt: 1,
      orchestration_phase: "implementing",
      started_at: ~U[2026-03-20 17:09:00Z],
      issue: %Issue{
        id: "issue-41",
        identifier: "THO-41",
        title: "Polish bookings filters",
        state: "In Progress",
        branch_name: "symphony/tho-41"
      }
    }
  end

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(path)
    path
  end
end
