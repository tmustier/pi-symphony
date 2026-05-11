defmodule SymphonyElixir.Pi.CommandResolver do
  @moduledoc """
  Resolves the configured Pi executable before workers enter `bash -lc`.

  Symphony workers run Pi through a login shell so they can inherit the usual
  CLI environment. On machines with more than one `pi` installed, that login
  shell can resolve a different PATH order than the orchestrator process. This
  resolver turns a bare `pi` command into an absolute executable path up front,
  preferring the newest Pi binary visible on the orchestrator PATH.
  """

  import Bitwise

  @default_command "pi"
  @version_timeout_ms 1_000

  @type resolved :: %{
          configured: String.t(),
          path: Path.t(),
          version: String.t() | nil,
          resolution: :configured_path | :path_first | :path_latest
        }

  @spec resolve(String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def resolve(command) do
    command = normalize(command)

    cond do
      path_like?(command) ->
        resolve_configured_path(command, version?: false)

      command == @default_command ->
        case resolve_latest_pi_on_path(command) do
          {:ok, %{path: path}} -> {:ok, path}
          {:error, reason} -> {:error, reason}
        end

      true ->
        case executable_candidates(command) do
          [] -> {:error, {:pi_command_not_found, command}}
          [path | _] -> {:ok, path}
        end
    end
  end

  @spec resolve_info(String.t() | nil) :: {:ok, resolved()} | {:error, term()}
  def resolve_info(command) do
    command = normalize(command)

    cond do
      path_like?(command) ->
        resolve_configured_path(command, version?: true)

      command == @default_command ->
        resolve_latest_pi_on_path(command)

      true ->
        resolve_first_on_path(command)
    end
  end

  defp normalize(command) when is_binary(command) do
    case String.trim(command) do
      "" -> @default_command
      trimmed -> trimmed
    end
  end

  defp normalize(_command), do: @default_command

  defp path_like?(command) do
    String.contains?(command, "/") || String.contains?(command, "\\")
  end

  defp resolve_configured_path(command, opts) do
    case expand_configured_path(command) do
      {:ok, path} -> configured_path_result(command, path, opts)
      {:error, _reason} = error -> error
    end
  end

  defp configured_path_result(command, path, opts) do
    cond do
      not executable_file?(path) -> {:error, {:pi_command_not_found, command}}
      Keyword.get(opts, :version?, true) -> {:ok, resolved(command, path, :configured_path)}
      true -> {:ok, path}
    end
  end

  defp expand_configured_path(command) do
    cond do
      Path.type(command) == :absolute -> {:ok, Path.expand(command)}
      String.starts_with?(command, "~/") -> {:ok, Path.expand(command)}
      true -> {:error, {:relative_pi_command_not_supported, command}}
    end
  end

  defp resolve_first_on_path(command) do
    case executable_candidates(command) do
      [] -> {:error, {:pi_command_not_found, command}}
      [path | _] -> {:ok, resolved(command, path, :path_first)}
    end
  end

  defp resolve_latest_pi_on_path(command) do
    case executable_candidates(command) do
      [] ->
        {:error, {:pi_command_not_found, command}}

      candidates ->
        selected =
          candidates
          |> Enum.with_index()
          |> Enum.map(fn {path, index} -> Map.put(resolved(command, path, :path_latest), :index, index) end)
          |> select_latest_versioned_candidate()

        {:ok, Map.delete(selected, :index)}
    end
  end

  defp executable_candidates(command) do
    (System.get_env("PATH") || "")
    |> String.split(":", trim: true)
    |> Enum.map(&Path.expand(Path.join(&1, command)))
    |> Enum.filter(&executable_file?/1)
    |> Enum.uniq()
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> (mode &&& 0o111) != 0
      _ -> false
    end
  end

  defp resolved(configured, path, resolution) do
    %{configured: configured, path: path, resolution: resolution, version: pi_version(path)}
  end

  defp select_latest_versioned_candidate(candidates) do
    versioned = Enum.filter(candidates, &version_tuple(&1.version))

    if versioned == [] do
      List.first(candidates)
    else
      Enum.max_by(versioned, fn candidate ->
        {major, minor, patch, build} = version_tuple(candidate.version)
        {major, minor, patch, build, -candidate.index}
      end)
    end
  end

  defp pi_version(path) do
    task =
      Task.async(fn ->
        try do
          {:ok, System.cmd(path, ["--version"], stderr_to_stdout: true)}
        rescue
          error -> {:error, error}
        catch
          :exit, reason -> {:error, reason}
        end
      end)

    case Task.yield(task, @version_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {output, 0}}} -> parse_version(output)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp parse_version(output) do
    case Regex.run(~r/(\d+\.\d+(?:\.\d+){0,2})/, output) do
      [_, version] -> version
      _ -> nil
    end
  end

  defp version_tuple(nil), do: nil

  defp version_tuple(version) do
    version
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> then(&(&1 ++ List.duplicate(0, 4 - length(&1))))
    |> Enum.take(4)
    |> List.to_tuple()
  end
end
