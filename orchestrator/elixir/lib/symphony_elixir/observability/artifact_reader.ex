defmodule SymphonyElixir.Observability.ArtifactReader do
  @moduledoc """
  Safe bounded reads of run artifacts exposed through observability APIs.

  Callers choose an artifact kind; this module resolves that kind from
  snapshot-known run metadata only. It never accepts an arbitrary path from API
  params.
  """

  alias SymphonyElixir.{Config, LogFile}
  import SymphonyElixir.MapUtils, only: [fetch_value: 2]

  @default_limit_bytes 65_536
  @max_limit_bytes 1_048_576
  @jsonl_kinds MapSet.new(["session", "proof_events"])
  @valid_kinds MapSet.new(["session", "proof_events", "proof_summary", "stderr"])

  @spec read(map(), map()) :: {:ok, map()} | {:error, atom()}
  def read(run, params) when is_map(run) and is_map(params) do
    kind = normalize_kind(Map.get(params, "kind") || Map.get(params, :kind))
    offset = parse_offset(Map.get(params, "offset") || Map.get(params, :offset))
    limit_bytes = parse_limit_bytes(Map.get(params, "limit_bytes") || Map.get(params, :limit_bytes))

    with :ok <- validate_kind(kind),
         {:ok, path} <- resolve_path(run, kind),
         :ok <- validate_safe_path(path, run),
         {:ok, read_result} <- bounded_read(path, offset, limit_bytes) do
      {:ok,
       read_result
       |> Map.drop([:content])
       |> Map.merge(parse_content(kind, read_result.content))
       |> Map.merge(%{
         issue_identifier: Map.get(run, :issue_identifier),
         kind: kind,
         path: path,
         file: Path.basename(path),
         offset: offset,
         limit_bytes: limit_bytes
       })}
    end
  end

  defp validate_kind(kind) do
    if MapSet.member?(@valid_kinds, kind), do: :ok, else: {:error, :invalid_kind}
  end

  defp normalize_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> case do
      "" -> "session"
      value -> value
    end
  end

  defp normalize_kind(_kind), do: "session"

  defp resolve_path(run, "session") do
    run
    |> artifact_entry()
    |> fetch_value(:session_file)
    |> present_path()
  end

  defp resolve_path(run, "proof_events") do
    run
    |> artifact_entry()
    |> fetch_value(:proof_events_path)
    |> present_path()
  end

  defp resolve_path(run, "proof_summary") do
    run
    |> artifact_entry()
    |> fetch_value(:proof_summary_path)
    |> present_path()
  end

  defp resolve_path(run, "stderr") do
    entry = artifact_entry(run)

    [
      fetch_value(entry, :stderr_path),
      fetch_value(entry, :stderr_file),
      fetch_value(entry, :worker_stderr_path)
    ]
    |> Enum.find(&present?/1)
    |> present_path()
  end

  defp artifact_entry(run), do: Map.get(run, :running) || Map.get(run, :retrying) || %{}

  defp present_path(path) when is_binary(path) do
    case String.trim(path) do
      "" -> {:error, :no_artifact_path}
      value -> {:ok, value}
    end
  end

  defp present_path(_path), do: {:error, :no_artifact_path}

  defp validate_safe_path(path, run) do
    cond do
      not present?(path) ->
        {:error, :unsafe_path}

      not metadata_path?(path, run) ->
        {:error, :unsafe_path}

      not under_allowed_root?(path, run) ->
        {:error, :unsafe_path}

      true ->
        :ok
    end
  end

  defp metadata_path?(path, run) do
    expanded = Path.expand(path)

    run
    |> metadata_paths()
    |> Enum.map(&Path.expand/1)
    |> Enum.any?(&(&1 == expanded))
  end

  defp metadata_paths(run) do
    entry = artifact_entry(run)

    [
      fetch_value(entry, :session_file),
      fetch_value(entry, :proof_events_path),
      fetch_value(entry, :proof_summary_path),
      fetch_value(entry, :stderr_path),
      fetch_value(entry, :stderr_file),
      fetch_value(entry, :worker_stderr_path)
    ]
    |> Enum.filter(&present?/1)
  end

  defp under_allowed_root?(path, run) do
    path_candidates = canonical_candidates(path)
    root_candidates = run |> allowed_roots() |> Enum.flat_map(&canonical_candidates/1)

    Enum.any?(path_candidates, fn candidate ->
      Enum.any?(root_candidates, &under_root?(candidate, &1))
    end)
  end

  defp allowed_roots(_run) do
    [Config.settings!().workspace.root, logs_root()]
    |> Enum.filter(&present?/1)
  end

  defp under_root?(path, root) when is_binary(path) and is_binary(root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp under_root?(_path, _root), do: false

  defp canonical_candidates(path) do
    case resolve_symlinks(Path.expand(path), 0) do
      resolved when is_binary(resolved) -> [resolved]
      {:error, _reason} -> []
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

  defp bounded_read(path, offset, limit_bytes) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular,
         {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        case :file.pread(file, offset, limit_bytes + 1) do
          {:ok, bytes} ->
            truncated = byte_size(bytes) > limit_bytes
            content = if truncated, do: binary_part(bytes, 0, limit_bytes), else: bytes

            {:ok,
             %{
               content: content,
               bytes_read: byte_size(content),
               truncated: truncated or offset + byte_size(content) < stat.size,
               next_offset: if(offset + byte_size(content) < stat.size, do: offset + byte_size(content), else: nil),
               size_bytes: stat.size
             }}

          :eof ->
            {:ok, %{content: "", bytes_read: 0, truncated: false, next_offset: nil, size_bytes: stat.size}}

          {:error, _reason} ->
            {:error, :read_failed}
        end
      after
        File.close(file)
      end
    else
      {:error, _reason} -> {:error, :read_failed}
      false -> {:error, :not_regular_file}
    end
  end

  defp parse_content(kind, content) do
    cond do
      MapSet.member?(@jsonl_kinds, kind) ->
        %{entries: parse_jsonl(content)}

      kind == "proof_summary" ->
        case Jason.decode(content) do
          {:ok, decoded} -> %{summary: decoded}
          {:error, _reason} -> raw_content(content)
        end

      true ->
        raw_content(content)
    end
  end

  defp parse_jsonl(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_jsonl_line/1)
  end

  defp parse_jsonl_line(line) do
    case Jason.decode(line) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{"raw" => bounded_text(line, 500)}
    end
  end

  defp raw_content(content) do
    if String.valid?(content) do
      %{content: bounded_text(content, @max_limit_bytes), encoding: "utf-8"}
    else
      %{content: Base.encode64(content), encoding: "base64"}
    end
  end

  defp parse_offset(offset) when is_integer(offset), do: max(offset, 0)

  defp parse_offset(offset) when is_binary(offset) do
    case Integer.parse(offset) do
      {value, _rest} -> parse_offset(value)
      :error -> 0
    end
  end

  defp parse_offset(_offset), do: 0

  defp parse_limit_bytes(limit) when is_integer(limit), do: min(max(limit, 1), @max_limit_bytes)

  defp parse_limit_bytes(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, _rest} -> parse_limit_bytes(value)
      :error -> @default_limit_bytes
    end
  end

  defp parse_limit_bytes(_limit), do: @default_limit_bytes

  defp logs_root do
    :symphony_elixir
    |> Application.get_env(:log_file, LogFile.default_log_file())
    |> Path.dirname()
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp bounded_text(text, max_bytes) when byte_size(text) <= max_bytes, do: text
  defp bounded_text(text, max_bytes), do: binary_part(text, 0, max_bytes)
end
