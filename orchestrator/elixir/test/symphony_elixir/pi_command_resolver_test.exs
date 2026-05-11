defmodule SymphonyElixir.Pi.CommandResolverTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Pi.CommandResolver

  setup do
    original_path = System.get_env("PATH") || ""

    on_exit(fn ->
      System.put_env("PATH", original_path)
    end)

    :ok
  end

  test "bare pi resolves to the newest visible Pi on PATH" do
    root = Path.join(System.tmp_dir!(), "symphony-pi-resolver-#{System.unique_integer([:positive])}")
    old_bin = Path.join(root, "old")
    new_bin = Path.join(root, "new")

    try do
      old_pi = write_fake_pi!(old_bin, "0.52.12")
      new_pi = write_fake_pi!(new_bin, "0.74.0")

      System.put_env("PATH", Enum.join([old_bin, new_bin], ":"))

      assert {:ok, %{path: ^new_pi, version: "0.74.0", resolution: :path_latest}} =
               CommandResolver.resolve_info("pi")

      assert {:ok, ^new_pi} = CommandResolver.resolve("pi")
      refute old_pi == new_pi
    after
      File.rm_rf(root)
    end
  end

  test "explicit configured path wins over PATH candidates" do
    root = Path.join(System.tmp_dir!(), "symphony-pi-resolver-explicit-#{System.unique_integer([:positive])}")
    old_bin = Path.join(root, "old")
    new_bin = Path.join(root, "new")

    try do
      explicit_pi = write_fake_pi!(old_bin, "0.52.12")
      _new_pi = write_fake_pi!(new_bin, "0.74.0")

      System.put_env("PATH", new_bin)

      assert {:ok, %{path: ^explicit_pi, version: "0.52.12", resolution: :configured_path}} =
               CommandResolver.resolve_info(explicit_pi)
    after
      File.rm_rf(root)
    end
  end

  test "relative path-like commands are rejected to avoid cwd ambiguity" do
    assert {:error, {:relative_pi_command_not_supported, "./bin/pi"}} =
             CommandResolver.resolve("./bin/pi")

    assert {:error, {:relative_pi_command_not_supported, "./bin/pi"}} =
             CommandResolver.resolve_info("./bin/pi")
  end

  test "broken Pi candidates do not crash latest-version resolution" do
    root = Path.join(System.tmp_dir!(), "symphony-pi-resolver-broken-#{System.unique_integer([:positive])}")
    broken_bin = Path.join(root, "broken")
    valid_bin = Path.join(root, "valid")

    try do
      broken_pi = write_broken_pi!(broken_bin)
      valid_pi = write_fake_pi!(valid_bin, "0.74.0")

      System.put_env("PATH", Enum.join([broken_bin, valid_bin], ":"))

      assert {:ok, %{path: ^valid_pi, version: "0.74.0", resolution: :path_latest}} =
               CommandResolver.resolve_info("pi")

      refute broken_pi == valid_pi
    after
      File.rm_rf(root)
    end
  end

  defp write_broken_pi!(dir) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "pi")
    File.write!(path, "#!/definitely/missing/interpreter\n")
    File.chmod!(path, 0o755)
    path
  end

  defp write_fake_pi!(dir, version) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "pi")

    File.write!(path, """
    #!/bin/sh
    case "$1" in
      --version) echo "#{version}" ;;
      *) exit 0 ;;
    esac
    """)

    File.chmod!(path, 0o755)
    path
  end
end
