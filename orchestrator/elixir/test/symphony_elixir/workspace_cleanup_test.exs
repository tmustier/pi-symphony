defmodule SymphonyElixir.WorkspaceCleanupTest do
  use SymphonyElixir.TestSupport

  test "list_workspaces returns all workspace directories" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-list-workspaces-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace_root, "SYM-1"))
      File.mkdir_p!(Path.join(workspace_root, "SYM-2"))
      File.write!(Path.join(workspace_root, "stale-file.txt"), "not a workspace")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, workspaces} = Workspace.list_workspaces()
      identifiers = Enum.map(workspaces, & &1.identifier) |> Enum.sort()

      assert identifiers == ["SYM-1", "SYM-2"]
      assert Enum.all?(workspaces, &String.starts_with?(&1.path, workspace_root))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "list_workspaces excludes dot directories" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-list-dot-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace_root, ".hidden"))
      File.mkdir_p!(Path.join(workspace_root, "SYM-3"))

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, workspaces} = Workspace.list_workspaces()
      assert length(workspaces) == 1
      assert hd(workspaces).identifier == "SYM-3"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "list_workspaces returns empty list for missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-list-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert {:ok, []} = Workspace.list_workspaces()
  end

  test "stale_workspaces identifies workspaces not in active set" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stale-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace_root, "SYM-10"))
      File.mkdir_p!(Path.join(workspace_root, "SYM-11"))
      File.mkdir_p!(Path.join(workspace_root, "SYM-12"))

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      active = MapSet.new(["SYM-10"])
      assert {:ok, stale} = Workspace.stale_workspaces(active)

      stale_ids = Enum.map(stale, & &1.identifier) |> Enum.sort()
      assert stale_ids == ["SYM-11", "SYM-12"]
      assert Enum.all?(stale, &is_float(&1.age_hours))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "stale_workspaces returns empty when all match active set" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stale-all-active-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace_root, "SYM-20"))

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      active = MapSet.new(["SYM-20"])
      assert {:ok, []} = Workspace.stale_workspaces(active)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "cleanup_stale removes stale workspaces" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cleanup-stale-#{System.unique_integer([:positive])}"
      )

    try do
      stale_ws = Path.join(workspace_root, "SYM-30")
      active_ws = Path.join(workspace_root, "SYM-31")
      File.mkdir_p!(stale_ws)
      File.mkdir_p!(active_ws)
      File.write!(Path.join(stale_ws, "marker.txt"), "stale")
      File.write!(Path.join(active_ws, "marker.txt"), "active")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      active = MapSet.new(["SYM-31"])
      assert {:ok, removed, []} = Workspace.cleanup_stale(active)
      assert length(removed) == 1
      assert hd(removed).identifier == "SYM-30"

      refute File.exists?(stale_ws)
      assert File.exists?(active_ws)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "cleanup_stale respects retention_hours" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cleanup-retention-#{System.unique_integer([:positive])}"
      )

    try do
      # Create a workspace — it will have age ~0 hours
      recent_ws = Path.join(workspace_root, "SYM-40")
      File.mkdir_p!(recent_ws)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      active = MapSet.new()
      # With 24h retention, a just-created workspace should be retained
      assert {:ok, removed, retained} = Workspace.cleanup_stale(active, 24.0)
      assert removed == []
      assert length(retained) == 1
      assert hd(retained).identifier == "SYM-40"
      assert File.exists?(recent_ws)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "cleanup_stale with nil retention removes all stale" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cleanup-no-retention-#{System.unique_integer([:positive])}"
      )

    try do
      stale_ws = Path.join(workspace_root, "SYM-50")
      File.mkdir_p!(stale_ws)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      active = MapSet.new()
      assert {:ok, removed, retained} = Workspace.cleanup_stale(active, nil)
      assert length(removed) == 1
      assert retained == []
      refute File.exists?(stale_ws)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace config schema accepts cleanup settings" do
    workflow = """
    ---
    workspace:
      root: /tmp/test-workspaces
      cleanup_on_shutdown: true
      cleanup_after_merge: false
      retention_hours: 48.0
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    config = Config.settings!()
    assert config.workspace.cleanup_on_shutdown == true
    assert config.workspace.cleanup_after_merge == false
    assert config.workspace.retention_hours == 48.0
  end

  test "workspace config defaults cleanup options" do
    write_workflow_file!(Workflow.workflow_file_path())

    config = Config.settings!()
    assert config.workspace.cleanup_on_shutdown == true
    assert config.workspace.cleanup_after_merge == true
    assert config.workspace.retention_hours == nil
  end

  test "workspace config rejects invalid retention_hours" do
    workflow = """
    ---
    workspace:
      retention_hours: -1
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "retention_hours"
  end
end
