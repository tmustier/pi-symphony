defmodule SymphonyElixir.PiProofTest do
  use ExUnit.Case

  alias SymphonyElixir.Pi.Proof

  test "artifact_paths uses the Pi session directory when a session file is available" do
    assert Proof.artifact_paths("/tmp/workspace", "/tmp/pi-rpc/session.jsonl") == %{
             proof_dir: "/tmp/pi-rpc/proof",
             proof_events_path: "/tmp/pi-rpc/proof/events.jsonl",
             proof_summary_path: "/tmp/pi-rpc/proof/summary.json"
           }
  end

  test "artifact_paths falls back to a workspace-local proof directory without a session file" do
    assert Proof.artifact_paths("/tmp/workspace", nil) == %{
             proof_dir: "/tmp/workspace/.pi-symphony-proof",
             proof_events_path: "/tmp/workspace/.pi-symphony-proof/events.jsonl",
             proof_summary_path: "/tmp/workspace/.pi-symphony-proof/summary.json"
           }
  end
end
