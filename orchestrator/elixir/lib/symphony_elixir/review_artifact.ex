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

  @spec exists?(Path.t()) :: boolean()
  def exists?(workspace_path) when is_binary(workspace_path) do
    workspace_path |> artifact_path() |> File.exists?()
  end

  def exists?(_workspace_path), do: false

  @spec load(Path.t() | nil) :: {:ok, artifact()} | {:ok, :missing} | {:error, term()}
  def load(workspace_path) when is_binary(workspace_path) do
    path = artifact_path(workspace_path)

    case File.read(path) do
      {:ok, body} ->
        case normalize_body(body) do
          nil ->
            {:ok, :missing}

          %{body: normalized_body, reviewed_head_sha: reviewed_head_sha} ->
            {:ok, %{path: path, body: normalized_body, reviewed_head_sha: reviewed_head_sha}}
        end

      {:error, :enoent} ->
        {:ok, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def load(_workspace_path), do: {:ok, :missing}

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
