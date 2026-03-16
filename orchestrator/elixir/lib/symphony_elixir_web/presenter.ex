defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}
  import SymphonyElixir.MapUtils, only: [fetch_value: 2]

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        tracked = Map.get(snapshot, :tracked, [])

        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            tracked: length(tracked)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          tracked: Enum.map(tracked, &tracked_entry_payload/1),
          worker_totals: snapshot.worker_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        tracked = snapshot |> Map.get(:tracked, []) |> Enum.find(&(&1.issue_identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(tracked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, tracked)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, tracked) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, tracked),
      status: issue_status(running, retry, tracked),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        worker_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: (tracked && tracked_issue_payload(tracked)) || %{}
    }
  end

  defp issue_id_from_entries(running, retry, tracked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (tracked && tracked.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _tracked) when not is_nil(running), do: "running"
  defp issue_status(nil, retry, _tracked) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, tracked) when not is_nil(tracked), do: "tracked"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_worker_event,
      last_message: summarize_message(entry.last_worker_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_worker_timestamp),
      tokens: %{
        input_tokens: entry.worker_input_tokens,
        output_tokens: entry.worker_output_tokens,
        total_tokens: entry.worker_total_tokens
      }
    }
    |> maybe_put(:session_file, Map.get(entry, :session_file))
    |> maybe_put(:session_dir, Map.get(entry, :session_dir))
    |> maybe_put(:proof, proof_payload(entry))
    |> maybe_put(:orchestration_phase, Map.get(entry, :orchestration_phase))
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
    |> maybe_put(:session_file, Map.get(entry, :session_file))
    |> maybe_put(:session_dir, Map.get(entry, :session_dir))
    |> maybe_put(:proof, proof_payload(entry))
  end

  defp tracked_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.issue_identifier,
      state: entry.state,
      labels: Map.get(entry, :labels, []),
      phase: Map.get(entry, :phase),
      phase_source: Map.get(entry, :phase_source),
      passive_phase: Map.get(entry, :passive_phase, false),
      rollout_mode: Map.get(entry, :rollout_mode),
      dispatch_allowed: Map.get(entry, :dispatch_allowed, false),
      waiting_reason: Map.get(entry, :waiting_reason),
      next_intended_action: Map.get(entry, :next_intended_action),
      observed_at: iso8601(Map.get(entry, :observed_at)),
      ownership: Map.get(entry, :ownership, %{}),
      kill_switch: Map.get(entry, :kill_switch, %{}),
      workpad: tracked_workpad_payload(Map.get(entry, :workpad, %{}))
    }
  end

  defp tracked_issue_payload(entry), do: tracked_entry_payload(entry)

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_worker_event,
      last_message: summarize_message(running.last_worker_message),
      last_event_at: iso8601(running.last_worker_timestamp),
      tokens: %{
        input_tokens: running.worker_input_tokens,
        output_tokens: running.worker_output_tokens,
        total_tokens: running.worker_total_tokens
      }
    }
    |> maybe_put(:session_file, Map.get(running, :session_file))
    |> maybe_put(:session_dir, Map.get(running, :session_dir))
    |> maybe_put(:proof, proof_payload(running))
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
    |> maybe_put(:session_file, Map.get(retry, :session_file))
    |> maybe_put(:session_dir, Map.get(retry, :session_dir))
    |> maybe_put(:proof, proof_payload(retry))
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_worker_timestamp),
        event: running.last_worker_event,
        message: summarize_message(running.last_worker_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp proof_payload(entry) when is_map(entry) do
    %{}
    |> maybe_put(:dir, Map.get(entry, :proof_dir))
    |> maybe_put(:events_path, Map.get(entry, :proof_events_path))
    |> maybe_put(:summary_path, Map.get(entry, :proof_summary_path))
    |> case do
      proof when map_size(proof) == 0 -> nil
      proof -> proof
    end
  end

  defp tracked_workpad_payload(workpad) when is_map(workpad) do
    metadata = fetch_value(workpad, :metadata) || %{}
    observation = fetch_value(workpad, :observation) || %{}

    %{}
    |> maybe_put(:marker, fetch_value(workpad, :marker))
    |> maybe_put(:marker_found, fetch_value(workpad, :marker_found))
    |> maybe_put(:comment_id, fetch_value(workpad, :comment_id))
    |> maybe_put(:matched_comment_ids, fetch_value(workpad, :matched_comment_ids))
    |> maybe_put(:metadata_status, fetch_value(workpad, :metadata_status))
    |> maybe_put(:phase_source, fetch_value(workpad, :phase_source))
    |> maybe_put(:waiting_reason, fetch_value(workpad, :waiting_reason))
    |> maybe_put(:pr, tracked_pr_metadata(metadata))
    |> maybe_put(:review, tracked_review_metadata(metadata))
    |> maybe_put(:merge, tracked_merge_metadata(metadata))
    |> maybe_put(:observation, tracked_observation_metadata(observation))
  end

  defp tracked_workpad_payload(_workpad), do: %{}

  defp tracked_pr_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.get("pr", %{})
    |> case do
      %{} = pr ->
        %{}
        |> maybe_put(:number, pr["number"])
        |> maybe_put(:url, pr["url"])
        |> maybe_put(:head_sha, pr["head_sha"])
        |> case do
          payload when map_size(payload) == 0 -> nil
          payload -> payload
        end

      _ ->
        nil
    end
  end

  defp tracked_pr_metadata(_metadata), do: nil

  defp tracked_review_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.get("review", %{})
    |> case do
      %{} = review ->
        %{}
        |> maybe_put(:comment_id, review["comment_id"])
        |> maybe_put(:passes_completed, review["passes_completed"])
        |> maybe_put(:last_reviewed_head_sha, review["last_reviewed_head_sha"])
        |> maybe_put(:last_fixed_head_sha, review["last_fixed_head_sha"])
        |> case do
          payload when map_size(payload) == 0 -> nil
          payload -> payload
        end

      _ ->
        nil
    end
  end

  defp tracked_review_metadata(_metadata), do: nil

  defp tracked_merge_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.get("merge", %{})
    |> case do
      %{} = merge ->
        %{}
        |> maybe_put(:last_attempted_at, merge["last_attempted_at"])
        |> maybe_put(:last_attempted_head_sha, merge["last_attempted_head_sha"])
        |> maybe_put(:last_merge_commit_sha, merge["last_merge_commit_sha"])
        |> maybe_put(:last_merged_head_sha, merge["last_merged_head_sha"])
        |> maybe_put(:last_failure_reason, merge["last_failure_reason"])
        |> case do
          payload when map_size(payload) == 0 -> nil
          payload -> payload
        end

      _ ->
        nil
    end
  end

  defp tracked_merge_metadata(_metadata), do: nil

  defp tracked_observation_metadata(observation) when is_map(observation) do
    %{}
    |> maybe_put(:last_observed_at, observation["last_observed_at"])
    |> maybe_put(:next_intended_action, observation["next_intended_action"])
    |> maybe_put(:rollout_mode, observation["rollout_mode"])
    |> maybe_put(:gates, observation["gates"])
    |> case do
      payload when map_size(payload) == 0 -> nil
      payload -> payload
    end
  end

  defp tracked_observation_metadata(_observation), do: nil


  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
