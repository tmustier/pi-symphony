defmodule SymphonyElixir.Observability.RunSnapshot do
  @moduledoc """
  Pure-ish projections from the orchestrator snapshot into run-oriented API DTOs.

  This module deliberately works from the existing snapshot shape only. It does
  not call Linear, GitHub, or inspect the filesystem.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}
  import SymphonyElixir.MapUtils, only: [fetch_value: 2]

  @default_status_values ["active", "retrying", "tracked"]
  @default_limit 100
  @max_limit 500

  @spec list_payload(GenServer.name(), timeout(), map()) :: map()
  def list_payload(orchestrator, snapshot_timeout_ms, params \\ %{}) do
    generated_at = now_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        all_runs = snapshot |> build_runs(default_statuses()) |> Enum.map(&public_run_payload(&1, false))
        page = snapshot |> build_runs(status_filter(params)) |> page_runs(params)

        %{
          generated_at: generated_at,
          counts: counts_payload(snapshot, all_runs),
          runs: Enum.map(page.runs, &public_run_payload(&1, false)),
          page_info: page.page_info
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec detail_payload(String.t(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, :issue_not_found | :snapshot_timeout | :snapshot_unavailable}
  def detail_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    generated_at = now_iso8601()

    case lookup_run(issue_identifier, orchestrator, snapshot_timeout_ms) do
      {:ok, run} -> {:ok, %{generated_at: generated_at, run: public_run_payload(run, true)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec lookup_run(String.t(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, :issue_not_found | :snapshot_timeout | :snapshot_unavailable}
  def lookup_run(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        snapshot
        |> build_runs(default_statuses())
        |> Enum.find(&(&1.issue_identifier == issue_identifier))
        |> case do
          nil -> {:error, :issue_not_found}
          run -> {:ok, run}
        end

      :timeout ->
        {:error, :snapshot_timeout}

      :unavailable ->
        {:error, :snapshot_unavailable}
    end
  end

  @spec status_filter(map()) :: [String.t()]
  defp status_filter(%{"status" => statuses}), do: parse_statuses(statuses)
  defp status_filter(%{status: statuses}), do: parse_statuses(statuses)
  defp status_filter(_params), do: default_statuses()

  @spec parse_statuses(term()) :: [String.t()]
  defp parse_statuses(statuses) when is_binary(statuses) do
    statuses
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn
      "running" -> "active"
      status -> status
    end)
    |> Enum.filter(&(&1 in @default_status_values))
    |> case do
      [] -> default_statuses()
      parsed -> Enum.uniq(parsed)
    end
  end

  defp parse_statuses(statuses) when is_list(statuses) do
    statuses
    |> Enum.map_join(",", &to_string/1)
    |> parse_statuses()
  end

  defp parse_statuses(_statuses), do: default_statuses()

  @spec default_statuses() :: [String.t()]
  defp default_statuses, do: @default_status_values

  @spec build_runs(map(), [String.t()]) :: [map()]
  defp build_runs(snapshot, statuses) do
    running_by_identifier =
      snapshot
      |> Map.get(:running, [])
      |> Enum.reject(&(identifier_for_running(&1) in [nil, ""]))
      |> Map.new(&{identifier_for_running(&1), &1})

    retrying_by_identifier =
      snapshot
      |> Map.get(:retrying, [])
      |> Enum.reject(&(identifier_for_retry(&1) in [nil, ""]))
      |> Map.new(&{identifier_for_retry(&1), &1})

    tracked_by_identifier =
      snapshot
      |> Map.get(:tracked, [])
      |> Enum.reject(&(identifier_for_tracked(&1) in [nil, ""]))
      |> Map.new(&{identifier_for_tracked(&1), &1})

    identifiers =
      [Map.keys(running_by_identifier), Map.keys(retrying_by_identifier), Map.keys(tracked_by_identifier)]
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    identifiers
    |> Enum.map(fn identifier ->
      running = Map.get(running_by_identifier, identifier)
      retrying = Map.get(retrying_by_identifier, identifier)
      tracked = Map.get(tracked_by_identifier, identifier)

      %{
        issue_identifier: identifier,
        status: status_for(running, retrying, tracked),
        running: running,
        retrying: retrying,
        tracked: tracked
      }
    end)
    |> Enum.filter(&(&1.status in statuses))
  end

  defp page_runs(runs, params) do
    limit = params |> query_param("limit") |> parse_limit()
    cursor = params |> query_param("cursor") |> parse_cursor()

    filtered =
      case cursor do
        nil -> runs
        cursor -> Enum.drop_while(runs, &(&1.issue_identifier <= cursor))
      end

    page_runs = Enum.take(filtered, limit)
    next_cursor = page_runs |> List.last() |> then(&(&1 && &1.issue_identifier))

    %{
      runs: page_runs,
      page_info: %{
        next_cursor: next_cursor,
        has_next_page: length(filtered) > length(page_runs),
        limit: limit
      }
    }
  end

  defp query_param(params, "limit") when is_map(params), do: Map.get(params, "limit") || Map.get(params, :limit)
  defp query_param(params, "cursor") when is_map(params), do: Map.get(params, "cursor") || Map.get(params, :cursor)
  defp query_param(_params, _key), do: nil

  defp parse_limit(limit) when is_integer(limit), do: min(max(limit, 1), @max_limit)

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, _rest} -> parse_limit(value)
      :error -> @default_limit
    end
  end

  defp parse_limit(_limit), do: @default_limit

  defp parse_cursor(cursor) when is_binary(cursor) do
    case String.trim(cursor) do
      "" -> nil
      value -> value
    end
  end

  defp parse_cursor(_cursor), do: nil

  defp public_run_payload(run, detail?) do
    payload = %{
      issue: issue_payload(run),
      runtime: runtime_payload(run),
      worker: worker_payload(run.running),
      workspace: workspace_payload(run),
      pr: pr_payload(run.tracked),
      attention: attention_payload(run)
    }

    if detail? do
      payload
      |> Map.put(:attempts, attempts_payload(run.retrying))
      |> Map.put(:proof, proof_payload(run.running || run.retrying))
      |> Map.put(:workpad, workpad_payload(run.tracked))
      |> Map.put(:dependencies, dependencies_payload(run.tracked))
    else
      payload
    end
  end

  defp issue_payload(run) do
    tracked = run.tracked || %{}
    running = run.running || %{}
    retrying = run.retrying || %{}

    %{
      id:
        first_present([
          fetch_value(tracked, :issue_id),
          fetch_value(running, :issue_id),
          fetch_value(retrying, :issue_id)
        ]),
      identifier: run.issue_identifier,
      title: fetch_value(tracked, :title),
      url: fetch_value(tracked, :url),
      state: first_present([fetch_value(tracked, :state), fetch_value(running, :state)]),
      labels: fetch_value(tracked, :labels) || [],
      priority: fetch_value(tracked, :priority)
    }
  end

  defp runtime_payload(run) do
    tracked = run.tracked || %{}
    running = run.running || %{}

    phase = fetch_value(tracked, :phase) || fetch_value(running, :orchestration_phase)

    %{
      status: run.status,
      phase: phase,
      phase_class: phase_class(run.status, phase, fetch_value(tracked, :waiting_reason)),
      dispatch_allowed: fetch_value(tracked, :dispatch_allowed) || false,
      next_intended_action: fetch_value(tracked, :next_intended_action),
      waiting_reason: fetch_value(tracked, :waiting_reason),
      started_at: iso8601(fetch_value(running, :started_at)),
      last_event_at: iso8601(fetch_value(running, :last_worker_timestamp) || fetch_value(tracked, :observed_at))
    }
  end

  defp worker_payload(nil) do
    %{
      runtime: nil,
      session_id: nil,
      pid: nil,
      turn_count: 0,
      last_event: nil,
      last_message: nil,
      tokens: %{input: 0, output: 0, total: 0}
    }
  end

  defp worker_payload(running) when is_map(running) do
    %{
      runtime: "pi",
      session_id: fetch_value(running, :session_id),
      pid: fetch_value(running, :worker_pid),
      turn_count: fetch_value(running, :turn_count) || 0,
      last_event: fetch_value(running, :last_worker_event),
      last_message: summarize_message(fetch_value(running, :last_worker_message)),
      tokens: %{
        input: fetch_value(running, :worker_input_tokens) || 0,
        output: fetch_value(running, :worker_output_tokens) || 0,
        total: fetch_value(running, :worker_total_tokens) || 0
      }
    }
  end

  defp workspace_payload(run) do
    entry = run.running || run.retrying || %{}
    tracked = run.tracked || %{}

    %{
      path: fetch_value(entry, :workspace_path) || default_workspace_path(run.issue_identifier),
      branch: workpad_metadata(tracked)["branch"],
      host: fetch_value(entry, :worker_host),
      exists: nil,
      stale: nil
    }
  end

  defp pr_payload(nil), do: empty_pr_payload()

  defp pr_payload(tracked) when is_map(tracked) do
    metadata = workpad_metadata(tracked)
    observation = workpad_observation(tracked)
    pr = normalize_map(metadata["pr"])
    review = normalize_map(metadata["review"])
    gates = normalize_map(observation["gates"])

    %{
      repo_slug: Config.settings!().pr.repo_slug,
      number: pr["number"],
      url: pr["url"],
      state: nil,
      head_sha: pr["head_sha"],
      draft: nil,
      checks: checks_payload(gates),
      review: %{
        state: gates["review"],
        decision: gates["review_decision"],
        passes_completed: review["passes_completed"]
      },
      mergeability: %{
        state: gates["mergeability"],
        mergeable: gates["mergeable"],
        merge_state_status: gates["merge_state_status"]
      },
      last_observed_at: observation["last_observed_at"]
    }
  end

  defp empty_pr_payload do
    %{
      repo_slug: Config.settings!().pr.repo_slug,
      number: nil,
      url: nil,
      state: nil,
      head_sha: nil,
      draft: nil,
      checks: %{state: nil, passing: 0, pending: 0, failing: 0, total: 0},
      review: %{state: nil, decision: nil, passes_completed: nil},
      mergeability: %{state: nil, mergeable: nil, merge_state_status: nil},
      last_observed_at: nil
    }
  end

  defp checks_payload(gates) when is_map(gates) do
    check_state = gates["checks"] || gates["check_suite"]

    %{
      state: check_state,
      passing: numeric_gate(gates, "checks_passing"),
      pending: numeric_gate(gates, "checks_pending"),
      failing: numeric_gate(gates, "checks_failing"),
      total: numeric_gate(gates, "checks_total")
    }
  end

  defp attention_payload(run) do
    run
    |> attention_context()
    |> attention_payload_from_context()
  end

  defp attention_context(run) do
    tracked = run.tracked || %{}
    retrying = run.retrying || %{}
    kill_switch = fetch_value(tracked, :kill_switch) || %{}

    %{
      kill_switch_active?: fetch_value(kill_switch, :active) == true,
      waiting_reason: fetch_value(tracked, :waiting_reason),
      phase: fetch_value(tracked, :phase),
      retry_attempt: fetch_value(retrying, :attempt) || 0,
      max_retries: fetch_value(retrying, :max_retries) || Config.settings!().agent.max_retries
    }
  end

  defp attention_payload_from_context(%{kill_switch_active?: true}) do
    %{required: true, reason: "kill_switch_active", severity: "error"}
  end

  defp attention_payload_from_context(%{phase: "blocked", waiting_reason: waiting_reason}) do
    %{required: true, reason: waiting_reason || "blocked", severity: "warning"}
  end

  defp attention_payload_from_context(%{waiting_reason: waiting_reason})
       when waiting_reason in ["human_approval_required", "needs_human", "input_required"] do
    %{required: true, reason: waiting_reason, severity: "warning"}
  end

  defp attention_payload_from_context(%{retry_attempt: retry_attempt, max_retries: max_retries})
       when retry_attempt > 0 and retry_attempt >= max_retries do
    %{required: true, reason: "retry_exhausted", severity: "error"}
  end

  defp attention_payload_from_context(_context) do
    %{required: false, reason: nil, severity: "info"}
  end

  defp attempts_payload(nil) do
    %{
      current: 0,
      max: Config.settings!().agent.max_retries,
      restart_count: 0,
      retry_due_at: nil,
      last_error: nil,
      error_classification: nil
    }
  end

  defp attempts_payload(retrying) when is_map(retrying) do
    attempt = fetch_value(retrying, :attempt) || 0

    %{
      current: attempt,
      max: fetch_value(retrying, :max_retries) || Config.settings!().agent.max_retries,
      restart_count: max(attempt - 1, 0),
      retry_due_at: due_at_iso8601(fetch_value(retrying, :due_in_ms)),
      last_error: fetch_value(retrying, :error),
      error_classification: fetch_value(retrying, :error_classification)
    }
  end

  defp proof_payload(nil), do: %{dir: nil, events_path: nil, summary_path: nil, html_path: nil}

  defp proof_payload(entry) when is_map(entry) do
    %{
      dir: fetch_value(entry, :proof_dir),
      events_path: fetch_value(entry, :proof_events_path),
      summary_path: fetch_value(entry, :proof_summary_path),
      html_path: nil
    }
  end

  defp workpad_payload(nil), do: %{comment_id: nil, metadata_status: nil, phase_source: nil, metadata: %{}}

  defp workpad_payload(tracked) when is_map(tracked) do
    workpad = fetch_value(tracked, :workpad) || %{}

    %{
      comment_id: fetch_value(workpad, :comment_id),
      metadata_status: fetch_value(workpad, :metadata_status),
      phase_source: fetch_value(workpad, :phase_source) || fetch_value(tracked, :phase_source),
      metadata: workpad_metadata(tracked)
    }
  end

  defp dependencies_payload(nil), do: %{blocked_by: [], blocks: []}

  defp dependencies_payload(tracked) when is_map(tracked) do
    %{
      blocked_by: fetch_value(tracked, :blocked_by) || [],
      blocks: fetch_value(tracked, :blocks) || []
    }
  end

  defp counts_payload(snapshot, runs) do
    merge = Map.get(snapshot, :merge, %{})

    %{
      active: length(Map.get(snapshot, :running, [])),
      retrying: length(Map.get(snapshot, :retrying, [])),
      tracked: length(Map.get(snapshot, :tracked, [])),
      needs_attention: Enum.count(runs, &(get_in(&1, [:attention, :required]) == true)),
      merge_queued: length(Map.get(merge, :queued, []))
    }
  end

  defp status_for(running, _retrying, _tracked) when is_map(running), do: "active"
  defp status_for(nil, retrying, _tracked) when is_map(retrying), do: "retrying"
  defp status_for(nil, nil, tracked) when is_map(tracked), do: "tracked"

  defp phase_class("active", _phase, _waiting_reason), do: "active"
  defp phase_class(_status, "ready_to_merge", _waiting_reason), do: "ready"
  defp phase_class(_status, "blocked", _waiting_reason), do: "blocked"
  defp phase_class(_status, _phase, waiting_reason) when is_binary(waiting_reason), do: "waiting"
  defp phase_class(_status, _phase, _waiting_reason), do: "idle"

  defp identifier_for_running(entry), do: fetch_value(entry, :identifier)
  defp identifier_for_retry(entry), do: fetch_value(entry, :identifier)
  defp identifier_for_tracked(entry), do: fetch_value(entry, :issue_identifier)

  defp workpad_metadata(tracked) when is_map(tracked) do
    tracked
    |> fetch_value(:workpad)
    |> fetch_value(:metadata)
    |> normalize_map()
  end

  defp workpad_metadata(_tracked), do: %{}

  defp workpad_observation(tracked) do
    tracked
    |> fetch_value(:workpad)
    |> fetch_value(:observation)
    |> normalize_map()
  end

  defp normalize_map(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), nested} end)
  end

  defp normalize_map(_value), do: %{}

  defp numeric_gate(gates, key) do
    case gates[key] do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp default_workspace_path(issue_identifier) do
    Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp first_present(values) do
    Enum.find(values, fn
      value when is_binary(value) -> String.trim(value) != ""
      nil -> false
      _ -> true
    end)
  end

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

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
