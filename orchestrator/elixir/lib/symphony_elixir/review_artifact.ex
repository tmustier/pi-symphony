defmodule SymphonyElixir.ReviewArtifact do
  @moduledoc """
  Loads the canonical self-review artifact that workers persist for runtime-owned
  PR comment upsert.
  """

  @relative_path ".symphony/review.md"
  @head_marker ~r/^<!--\s*symphony-review-head:\s*([^\s]+)\s*-->\s*/

  @type artifact :: %{
          path: Path.t(),
          body: String.t(),
          reviewed_head_sha: String.t() | nil
        }

  @doc false
  @spec relative_path_for_test() :: String.t()
  def relative_path_for_test, do: @relative_path

  @doc false
  @spec path_for_test(Path.t()) :: Path.t()
  def path_for_test(workspace_path), do: artifact_path(workspace_path)

  @doc false
  @spec load_for_test(Path.t() | nil) :: {:ok, artifact()} | {:ok, :missing} | {:error, term()}
  def load_for_test(workspace_path), do: load(workspace_path)

  @spec relative_path() :: String.t()
  def relative_path, do: @relative_path

  @spec artifact_path(Path.t()) :: Path.t()
  def artifact_path(workspace_path) when is_binary(workspace_path) do
    Path.join(workspace_path, @relative_path)
  end

  @spec exists?(Path.t(), String.t() | nil) :: boolean()
  def exists?(workspace_path, worker_host \\ nil)

  def exists?(workspace_path, nil) when is_binary(workspace_path) do
    workspace_path |> artifact_path() |> File.exists?()
  end

  def exists?(workspace_path, worker_host) when is_binary(workspace_path) and is_binary(worker_host) do
    path = artifact_path(workspace_path)

    case SymphonyElixir.SSH.run(worker_host, "test -f #{path} && echo exists") do
      {:ok, {output, 0}} -> String.contains?(output, "exists")
      _ -> false
    end
  end

  def exists?(_workspace_path, _worker_host), do: false

  @spec load(Path.t() | nil, String.t() | nil) :: {:ok, artifact()} | {:ok, :missing} | {:error, term()}
  def load(workspace_path, worker_host \\ nil)

  def load(workspace_path, nil) when is_binary(workspace_path) do
    path = artifact_path(workspace_path)

    case File.read(path) do
      {:ok, body} -> parse_artifact(path, body)
      {:error, :enoent} -> {:ok, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  def load(workspace_path, worker_host) when is_binary(workspace_path) and is_binary(worker_host) do
    path = artifact_path(workspace_path)

    case SymphonyElixir.SSH.run(worker_host, "cat #{path} 2>/dev/null") do
      {:ok, {body, 0}} -> parse_artifact(path, body)
      {:ok, {_output, _nonzero}} -> {:ok, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  def load(_workspace_path, _worker_host), do: {:ok, :missing}

  defp parse_artifact(path, body) do
    case normalize_body(body) do
      nil -> {:ok, :missing}
      %{body: normalized_body, reviewed_head_sha: sha} ->
        {:ok, %{path: path, body: normalized_body, reviewed_head_sha: sha}}
    end
  end

  defp normalize_body(body) when is_binary(body) do
    case String.trim(body) do
      "" ->
        nil

      normalized ->
        {reviewed_head_sha, normalized_body} = extract_reviewed_head_sha(normalized)
        %{body: normalized_body, reviewed_head_sha: reviewed_head_sha}
    end
  end

  defp extract_reviewed_head_sha(body) when is_binary(body) do
    case Regex.run(@head_marker, body) do
      [full_match, reviewed_head_sha] ->
        {String.trim(reviewed_head_sha), String.trim(String.replace_prefix(body, full_match, ""))}

      _ ->
        {nil, body}
    end
  end
end
