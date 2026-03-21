defmodule Mix.Tasks.Workspace.CleanupTest do
  use SymphonyElixir.TestSupport

  test "mix workspace.cleanup --help prints usage" do
    output = ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Workspace.Cleanup.run(["--help"]) end)
    assert output =~ "Removes workspace directories"
    assert output =~ "--dry-run"
    assert output =~ "--retention-hours"
  end

  test "mix workspace.cleanup --dry-run --json returns structured output" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-mix-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace_root, "STALE-1"))

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Workspace.Cleanup.run(["--dry-run", "--json", "--all"])
        end)

      assert {:ok, payload} = Jason.decode(output)
      assert payload["dry_run"] == true
      assert is_list(payload["would_remove"])
      assert Enum.any?(payload["would_remove"], &(&1["identifier"] == "STALE-1"))

      # Workspace should still exist (dry run)
      assert File.exists?(Path.join(workspace_root, "STALE-1"))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "mix workspace.cleanup --all removes all workspaces" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-mix-cleanup-all-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace_root, "WS-1"))
      File.mkdir_p!(Path.join(workspace_root, "WS-2"))

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      _output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Workspace.Cleanup.run(["--all"])
        end)

      refute File.exists?(Path.join(workspace_root, "WS-1"))
      refute File.exists?(Path.join(workspace_root, "WS-2"))
    after
      File.rm_rf(workspace_root)
    end
  end
end
