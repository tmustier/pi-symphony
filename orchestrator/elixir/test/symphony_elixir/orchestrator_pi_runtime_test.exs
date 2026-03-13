defmodule SymphonyElixir.OrchestratorPiRuntimeTest do
  use SymphonyElixir.TestSupport

  test "orchestrator dispatches memory tracker candidates through the Pi runtime" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-orchestrator-pi-runtime-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      fake_pi = Path.join(test_root, "fake-pi")
      trace_file = Path.join(test_root, "pi.trace")

      File.mkdir_p!(workspace_root)

      File.write!(
        fake_pi,
        """
        #!/bin/sh
        trace_file="#{trace_file}"
        count=0

        while IFS= read -r line; do
          count=$((count + 1))
          printf 'JSON:%s\\n' "$line" >> "$trace_file"

          case "$count" in
            1)
              printf '%s\\n' '{"type":"response","id":1,"command":"get_state","success":true,"data":{"sessionId":"pi-orchestrator-session","sessionFile":"/tmp/pi-orchestrator/session.jsonl"}}'
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
              sleep 2
              printf '%s\\n' '{"type":"agent_end","messages":[]}'
              exit 0
              ;;
          esac
        done
        """
      )

      File.chmod!(fake_pi, 0o755)

      issue = %Issue{
        id: "issue-pi-dispatch",
        identifier: "PI-401",
        title: "Dispatch with orchestrator",
        description: "Validate candidate issue dispatch through Pi runtime",
        state: "In Progress",
        url: "https://example.org/issues/PI-401",
        labels: ["backend"]
      }

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        worker_runtime: "pi",
        pi_command: fake_pi,
        pi_response_timeout_ms: 1_000,
        max_turns: 1,
        observability_enabled: false
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      orchestrator_name = Module.concat(__MODULE__, :PiRuntimeOrchestrator)
      {:ok, _pid} = Orchestrator.start_link(name: orchestrator_name)

      snapshot_entry = wait_for_running_entry(orchestrator_name, issue.id)

      assert snapshot_entry.identifier == "PI-401"
      assert snapshot_entry.session_id == "pi-orchestrator-session-turn-1"
      assert snapshot_entry.session_file == "/tmp/pi-orchestrator/session.jsonl"
      assert snapshot_entry.session_dir == "/tmp/pi-orchestrator"
      assert snapshot_entry.proof_dir == "/tmp/pi-orchestrator/proof"
      assert snapshot_entry.proof_events_path == "/tmp/pi-orchestrator/proof/events.jsonl"
      assert snapshot_entry.proof_summary_path == "/tmp/pi-orchestrator/proof/summary.json"
      assert snapshot_entry.workspace_path == Path.join(workspace_root, "PI-401")
    after
      if pid = Process.whereis(Module.concat(__MODULE__, :PiRuntimeOrchestrator)) do
        Process.exit(pid, :normal)
      end

      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  defp wait_for_running_entry(orchestrator_name, issue_id, attempts \\ 40)

  defp wait_for_running_entry(_orchestrator_name, issue_id, 0) do
    flunk("timed out waiting for running Pi worker entry for #{inspect(issue_id)}")
  end

  defp wait_for_running_entry(orchestrator_name, issue_id, attempts) do
    case Orchestrator.snapshot(orchestrator_name, 100) do
      %{running: running} when is_list(running) ->
        case Enum.find(running, &(&1.issue_id == issue_id)) do
          nil ->
            Process.sleep(50)
            wait_for_running_entry(orchestrator_name, issue_id, attempts - 1)

          entry ->
            entry
        end

      _ ->
        Process.sleep(50)
        wait_for_running_entry(orchestrator_name, issue_id, attempts - 1)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
