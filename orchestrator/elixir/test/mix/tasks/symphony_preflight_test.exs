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
    fake_bin = Path.join(System.tmp_dir!(), "symphony-preflight-bin-#{System.unique_integer([:positive])}")
    fake_gh = Path.join(fake_bin, "gh")
    original_path = System.get_env("PATH") || ""

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "observe"
    )

    try do
      File.mkdir_p!(fake_bin)

      File.write!(fake_gh, "#!/bin/sh\necho 'Logged in to github.com account test-user'\n")
      File.chmod!(fake_gh, 0o755)
      System.put_env("PATH", fake_bin <> ":" <> original_path)

      assert :ok = Preflight.run([])
    after
      System.put_env("PATH", original_path)
      File.rm_rf(fake_bin)
    end
  end

  test "preflight shows configured model and warns on deprecated model IDs" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      rollout_mode: "observe",
      pi_model_provider: "anthropic",
      pi_model_id: "claude-3-5-sonnet-20241022",
      pi_thinking_level: "high"
    )

    output = ExUnit.CaptureIO.capture_io(fn -> Preflight.run([]) end)

    assert output =~ "Model"
    assert output =~ "anthropic/claude-3-5-sonnet-20241022"
    assert output =~ "thinking: high"
    assert output =~ "superseded"
  end
end
