defmodule SymphonyElixir.Pi.Proof do
  @moduledoc false

  @type artifact_paths :: %{
          proof_dir: Path.t() | nil,
          proof_events_path: Path.t() | nil,
          proof_summary_path: Path.t() | nil
        }

  @spec artifact_paths(Path.t() | nil) :: artifact_paths()
  def artifact_paths(workspace_path) do
    artifact_paths(workspace_path, nil)
  end

  @spec artifact_paths(Path.t() | nil, Path.t() | nil) :: artifact_paths()
  def artifact_paths(_workspace_path, session_file) when is_binary(session_file) do
    proof_dir = Path.join(Path.dirname(session_file), "proof")

    %{
      proof_dir: proof_dir,
      proof_events_path: Path.join(proof_dir, "events.jsonl"),
      proof_summary_path: Path.join(proof_dir, "summary.json")
    }
  end

  def artifact_paths(workspace_path, _session_file) when is_binary(workspace_path) do
    proof_dir = Path.join(workspace_path, ".pi-symphony-proof")

    %{
      proof_dir: proof_dir,
      proof_events_path: Path.join(proof_dir, "events.jsonl"),
      proof_summary_path: Path.join(proof_dir, "summary.json")
    }
  end

  def artifact_paths(_workspace_path, _session_file) do
    %{
      proof_dir: nil,
      proof_events_path: nil,
      proof_summary_path: nil
    }
  end
end
