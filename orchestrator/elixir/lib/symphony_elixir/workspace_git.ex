defmodule SymphonyElixir.WorkspaceGit do
  @moduledoc """
  Inspects git state for a Symphony workspace.
  """

  alias SymphonyElixir.{MapUtils, SSH}

  @type git_state :: %{
          branch: String.t() | nil,
          head_sha: String.t() | nil,
          origin_url: String.t() | nil,
          repo_slug: String.t() | nil,
          remote_branch_published: boolean()
        }

  @doc false
  @spec repo_slug_from_remote_for_test(String.t() | nil) :: String.t() | nil
  def repo_slug_from_remote_for_test(remote_url), do: repo_slug_from_remote(remote_url)

  @doc false
  @spec inspect_for_test(Path.t(), String.t() | nil) :: {:ok, git_state()} | {:error, term()}
  def inspect_for_test(workspace, worker_host \\ nil), do: inspect_workspace(workspace, worker_host)

  @spec inspect_workspace(Path.t(), String.t() | nil) :: {:ok, git_state()} | {:error, term()}
  def inspect_workspace(workspace, worker_host \\ nil)

  @spec inspect_workspace(Path.t(), nil) :: {:ok, git_state()} | {:error, term()}
  def inspect_workspace(workspace, _worker_host) when not is_binary(workspace) do
    {:error, :missing_workspace}
  end

  @spec inspect_workspace(Path.t(), nil) :: {:ok, git_state()} | {:error, term()}
  def inspect_workspace(workspace, nil) do
    case System.find_executable("bash") do
      nil ->
        {:error, :bash_not_found}

      bash ->
        case System.cmd(bash, ["-lc", inspect_script(workspace)], stderr_to_stdout: true) do
          {output, 0} -> {:ok, parse_inspect_output(output)}
          {output, status} -> {:error, {:workspace_git_inspect_failed, status, output}}
        end
    end
  end

  @spec inspect_workspace(Path.t(), String.t()) :: {:ok, git_state()} | {:error, term()}
  def inspect_workspace(workspace, worker_host) when is_binary(worker_host) do
    case SSH.run(worker_host, inspect_script(workspace)) do
      {:ok, {output, 0}} -> {:ok, parse_inspect_output(output)}
      {:ok, {output, status}} -> {:error, {:workspace_git_inspect_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp inspect_script(workspace) do
    escaped_workspace = shell_escape(workspace)

    [
      "set -eu",
      "cd #{escaped_workspace}",
      "branch=$(git branch --show-current 2>/dev/null || true)",
      "head_sha=$(git rev-parse HEAD 2>/dev/null || true)",
      "origin_url=$(git remote get-url origin 2>/dev/null || true)",
      "remote_branch_published=0",
      "if [ -n \"$branch\" ] && [ -n \"$origin_url\" ] && GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code --heads origin \"$branch\" >/dev/null 2>&1; then",
      "  remote_branch_published=1",
      "fi",
      "printf 'branch=%s\nhead_sha=%s\norigin_url=%s\nremote_branch_published=%s\n' \"$branch\" \"$head_sha\" \"$origin_url\" \"$remote_branch_published\""
    ]
    |> Enum.join("\n")
  end

  defp parse_inspect_output(output) when is_binary(output) do
    values =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> Map.put(acc, key, normalize_optional_string(value))
          _ -> acc
        end
      end)

    origin_url = Map.get(values, "origin_url")

    %{
      branch: Map.get(values, "branch"),
      head_sha: Map.get(values, "head_sha"),
      origin_url: origin_url,
      repo_slug: repo_slug_from_remote(origin_url),
      remote_branch_published: Map.get(values, "remote_branch_published") == "1"
    }
  end

  defp repo_slug_from_remote(nil), do: nil

  defp repo_slug_from_remote(remote_url) when is_binary(remote_url) do
    trimmed = String.trim(remote_url)

    Regex.run(~r{github\.com[:/](?<slug>[^\s]+?)(?:\.git)?$}, trimmed, capture: :all_names)
    |> case do
      [slug] -> slug
      _ -> nil
    end
  end

  defp normalize_optional_string(value), do: MapUtils.normalize_optional_string(value)

  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
