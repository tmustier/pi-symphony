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
end
