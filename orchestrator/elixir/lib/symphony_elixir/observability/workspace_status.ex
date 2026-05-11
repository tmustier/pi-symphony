defmodule SymphonyElixir.Observability.WorkspaceStatus do
  @moduledoc """
  Detail-only workspace projection for run APIs.

  The list endpoint remains cached-only. This module performs only local,
  bounded filesystem/git inspection and never calls GitHub or Linear.
  """

  alias SymphonyElixir.Config
  import SymphonyElixir.MapUtils, only: [fetch_value: 2, normalize_map: 1, pick_string: 1]

  @inspect_timeout_ms 1_000

  @spec payload(map()) :: map()
  def payload(run) when is_map(run) do
    entry = Map.get(run, :running) || Map.get(run, :retrying) || %{}
    tracked = Map.get(run, :tracked) || %{}
    metadata = workpad_metadata(tracked)
    workspace_path = pick_string([fetch_value(entry, :workspace_path), default_workspace_path(Map.get(run, :issue_identifier))])
    worker_host = fetch_value(entry, :worker_host)

    base = %{
      path: workspace_path,
      exists: local_dir?(workspace_path, worker_host),
      root: Config.settings!().workspace.root,
      branch: metadata["branch"],
      head_sha: metadata["head_sha"],
      remote_branch_published: nil,
      dirty: nil,
      stale: nil,
      age_hours: local_age_hours(workspace_path, worker_host),
      host: worker_host,
      session_dir: fetch_value(entry, :session_dir),
      proof_dir: fetch_value(entry, :proof_dir),
      source: "snapshot"
    }

    base
    |> maybe_merge_git_inspection(workspace_path, worker_host)
    |> then(&%{issue_identifier: Map.get(run, :issue_identifier), workspace: &1})
  end

  defp maybe_merge_git_inspection(base, workspace_path, nil) when is_binary(workspace_path) do
    case inspect_local_git(workspace_path) do
      {:ok, git} ->
        base
        |> Map.put(:branch, git.branch || base.branch)
        |> Map.put(:head_sha, git.head_sha || base.head_sha)
        |> Map.put(:remote_branch_published, git.remote_branch_published)
        |> Map.put(:dirty, git.dirty)
        |> Map.put(:source, "snapshot+local_git")

      {:error, _reason} ->
        base
    end
  end

  defp maybe_merge_git_inspection(base, _workspace_path, _worker_host), do: base

  defp inspect_local_git(workspace_path) do
    if safe_local_workspace_path?(workspace_path) and File.dir?(workspace_path) do
      task =
        Task.async(fn ->
          with {:ok, branch} <- git(workspace_path, ["branch", "--show-current"]),
               {:ok, head_sha} <- git(workspace_path, ["rev-parse", "HEAD"]),
               {:ok, status} <- git(workspace_path, ["status", "--porcelain"]) do
            {:ok,
             %{
               branch: present(branch),
               head_sha: present(head_sha),
               dirty: String.trim(status) != "",
               remote_branch_published: cached_remote_branch?(workspace_path, branch)
             }}
          else
            {:error, _reason} = error -> error
          end
        end)

      case Task.yield(task, @inspect_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, git}} -> {:ok, git}
        {:ok, {:error, reason}} -> {:error, reason}
        nil -> {:error, :timeout}
      end
    else
      {:error, :missing_workspace}
    end
  end

  defp cached_remote_branch?(_workspace_path, branch) when not is_binary(branch) or branch == "", do: false

  defp cached_remote_branch?(workspace_path, branch) do
    case git(workspace_path, ["show-ref", "--verify", "--quiet", "refs/remotes/origin/#{branch}"]) do
      {:ok, _output} -> true
      {:error, {:git_failed, _args, 1, _output}} -> false
      {:error, _reason} -> false
    end
  end

  defp git(workspace_path, args) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_not_found}

      git ->
        case System.cmd(git, ["-C", workspace_path | args], stderr_to_stdout: true, env: [{"GIT_TERMINAL_PROMPT", "0"}]) do
          {output, 0} -> {:ok, String.trim(output)}
          {output, status} -> {:error, {:git_failed, args, status, output}}
        end
    end
  end

  defp local_dir?(_workspace_path, worker_host) when is_binary(worker_host), do: nil
  defp local_dir?(workspace_path, nil) when is_binary(workspace_path), do: safe_local_workspace_path?(workspace_path) and File.dir?(workspace_path)
  defp local_dir?(_workspace_path, _worker_host), do: false

  defp local_age_hours(_workspace_path, worker_host) when is_binary(worker_host), do: nil

  defp local_age_hours(workspace_path, nil) when is_binary(workspace_path) do
    if safe_local_workspace_path?(workspace_path) do
      case File.stat(workspace_path, time: :posix) do
        {:ok, stat} -> Float.round((System.os_time(:second) - stat.mtime) / 3600, 1)
        {:error, _reason} -> nil
      end
    end
  end

  defp local_age_hours(_workspace_path, _worker_host), do: nil

  defp safe_local_workspace_path?(workspace_path) when is_binary(workspace_path) do
    with {:ok, path} <- canonical_path(workspace_path),
         {:ok, root} <- canonical_path(Config.settings!().workspace.root) do
      path == root or String.starts_with?(path, root <> "/")
    else
      {:error, _reason} -> false
    end
  end

  defp safe_local_workspace_path?(_workspace_path), do: false

  defp canonical_path(path) do
    case path |> Path.expand() |> resolve_symlinks(0) do
      resolved when is_binary(resolved) -> {:ok, resolved}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_symlinks(_path, depth) when depth >= 20, do: {:error, :too_many_symlinks}

  defp resolve_symlinks(path, depth) do
    path
    |> Path.split()
    |> resolve_components([], depth)
  end

  defp resolve_components([], resolved_parts, _depth), do: join_resolved(resolved_parts)

  defp resolve_components([part | remaining], resolved_parts, depth) do
    candidate = join_resolved(resolved_parts ++ [part])

    case :file.read_link(String.to_charlist(candidate)) do
      {:ok, target} ->
        target_path = target |> List.to_string() |> expand_link_target(candidate)
        target_path |> append_remaining(remaining) |> resolve_symlinks(depth + 1)

      {:error, _reason} ->
        resolve_components(remaining, resolved_parts ++ [part], depth)
    end
  end

  defp append_remaining(path, []), do: path
  defp append_remaining(path, remaining), do: Path.join(path, Path.join(remaining))

  defp expand_link_target(target, link_path) do
    if Path.type(target) == :absolute do
      Path.expand(target)
    else
      Path.expand(target, Path.dirname(link_path))
    end
  end

  defp join_resolved([]), do: ""
  defp join_resolved([part]), do: part
  defp join_resolved(parts), do: Path.join(parts)

  defp workpad_metadata(tracked) do
    tracked
    |> fetch_value(:workpad)
    |> fetch_value(:metadata)
    |> normalize_map()
  end

  defp default_workspace_path(issue_identifier) when is_binary(issue_identifier) do
    Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp default_workspace_path(_issue_identifier), do: nil

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
