defmodule Mix.Tasks.Symphony.PreflightTest do
  use ExUnit.Case, async: false

  import SymphonyElixir.TestSupport

  alias Mix.Tasks.Symphony.Preflight
  alias SymphonyElixir.Workflow

  setup do
    stop_default_http_server()
    previous_workflow = File.read!(Workflow.workflow_file_path())

    on_exit(fn ->
      File.write!(Workflow.workflow_file_path(), previous_workflow)
      stop_default_http_server()
    end)

    :ok
  end

  test "preflight passes with a valid memory-tracker workflow" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "observe"
    )

    assert :ok = Preflight.run([])
  end
end
