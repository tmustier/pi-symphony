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

  test "preflight validates models against the latest Pi resolved on PATH" do
    root = Path.join(System.tmp_dir!(), "symphony-preflight-pi-path-#{System.unique_integer([:positive])}")
    old_bin = Path.join(root, "old")
    new_bin = Path.join(root, "new")
    original_path = System.get_env("PATH") || ""

    try do
      File.mkdir_p!(old_bin)
      File.mkdir_p!(new_bin)

      old_pi = Path.join(old_bin, "pi")
      new_pi = Path.join(new_bin, "pi")
      fake_gh = Path.join(old_bin, "gh")

      File.write!(old_pi, fake_pi_script("0.52.12", "anthropic/claude-sonnet-4-6"))
      File.write!(new_pi, fake_pi_script("0.74.0", "anthropic/claude-opus-4-7"))
      File.write!(fake_gh, "#!/bin/sh\necho 'Logged in to github.com account test-user'\n")
      Enum.each([old_pi, new_pi, fake_gh], &File.chmod!(&1, 0o755))

      System.put_env("PATH", Enum.join([old_bin, new_bin, original_path], ":"))

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        rollout_mode: "observe",
        worker_runtime: "pi",
        pi_command: "pi",
        pi_model_provider: "anthropic",
        pi_model_id: "claude-opus-4-7"
      )

      output = ExUnit.CaptureIO.capture_io(fn -> Preflight.run([]) end)

      assert output =~ "Pi command"
      assert output =~ new_pi
      assert output =~ "version 0.74.0"
      assert output =~ "anthropic/claude-opus-4-7 found"
      refute output =~ "not found in `#{old_pi} --list-models`"
    after
      System.put_env("PATH", original_path)
      File.rm_rf(root)
    end
  end

  defp fake_pi_script(version, listed_model) do
    """
    #!/bin/sh
    case "$1" in
      --version) echo "#{version}" ;;
      --list-models) echo "#{listed_model}" ;;
      *) exit 0 ;;
    esac
    """
  end
end
