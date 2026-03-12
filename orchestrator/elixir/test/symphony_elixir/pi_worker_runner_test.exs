defmodule SymphonyElixir.PiWorkerRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Pi.WorkerRunner

  test "agent runner can switch to the Pi runtime via worker.runtime" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pi-worker-runner-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      fake_pi = Path.join(test_root, "fake-pi")

      File.mkdir_p!(workspace_root)

      File.write!(
        fake_pi,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{"type":"response","id":1,"command":"get_state","success":true,"data":{"sessionId":"pi-session","sessionFile":"/tmp/pi-session.jsonl"}}'
              ;;
            2)
              printf '%s\\n' '{"type":"response","id":2,"command":"set_session_name","success":true}'
              ;;
            3)
              printf '%s\\n' '{"type":"response","id":3,"command":"set_auto_retry","success":true}'
              ;;
            4)
              printf '%s\\n' '{"type":"response","id":4,"command":"set_auto_compaction","success":true}'
              ;;
            5)
              printf '%s\\n' '{"type":"response","id":5,"command":"prompt","success":true}'
              printf '%s\\n' '{"type":"agent_start"}'
              printf '%s\\n' '{"type":"turn_start"}'
              printf '%s\\n' '{"type":"turn_end","message":{"role":"assistant","usage":{"input":12,"output":4,"totalTokens":16}},"toolResults":[]}'
              printf '%s\\n' '{"type":"agent_end","messages":[{"role":"assistant","usage":{"input":12,"output":4,"totalTokens":16}}]}'
              ;;
            6)
              printf '%s\\n' '{"type":"response","id":99,"command":"abort","success":true}'
              ;;
          esac
        done
        """
      )

      File.chmod!(fake_pi, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_runtime: "pi",
        pi_command: fake_pi,
        pi_response_timeout_ms: 1_000,
        pi_session_dir_name: ".pi-rpc-sessions"
      )

      issue = %Issue{
        id: "issue-pi-runtime",
        identifier: "PI-101",
        title: "Run with Pi",
        description: "Exercise the Pi worker adapter",
        state: "In Progress",
        url: "https://example.org/issues/PI-101",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:codex_worker_update, "issue-pi-runtime",
                      %{event: :session_started, session_id: "pi-session-turn-1", timestamp: %DateTime{}}},
                     1_000

      assert_receive {:codex_worker_update, "issue-pi-runtime",
                      %{event: :turn_completed, usage: %{"input" => 12, "output" => 4, "totalTokens" => 16}}},
                     1_000
    after
      File.rm_rf(test_root)
    end
  end

  test "pi worker runner rejects remote worker hosts for now" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-elixir-pi-worker-runner-remote")
    workspace = Path.join(workspace_root, "PI-102")

    try do
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_runtime: "pi"
      )

      assert {:error, :remote_pi_workers_not_supported} =
               WorkerRunner.start_session(workspace, worker_host: "remote-host")
    after
      File.rm_rf(workspace_root)
    end
  end
end
