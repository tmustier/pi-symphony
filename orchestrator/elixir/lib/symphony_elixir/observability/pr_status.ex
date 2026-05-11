defmodule SymphonyElixir.Observability.PrStatus do
  @moduledoc """
  Cached PR/check/review/mergeability projection for run detail APIs.

  Cached reads only use orchestrator snapshot/workpad metadata. Live refresh is
  opt-in and performs a bounded read-only `gh pr view` through `PullRequests.inspect_state/2`.
  """

  alias SymphonyElixir.{Config, PullRequests}
  import SymphonyElixir.MapUtils, only: [fetch_value: 2, normalize_map: 1, pick_string: 1]

  @default_live_timeout_ms 5_000

  @spec cached_payload(map()) :: map()
  def cached_payload(run) when is_map(run) do
    tracked = Map.get(run, :tracked) || %{}
    metadata = workpad_metadata(tracked)
    observation = workpad_observation(tracked)
    gates = normalize_map(observation["gates"])
    pr = normalize_map(metadata["pr"])
    review = normalize_map(metadata["review"])
    merge = normalize_map(metadata["merge"])

    %{
      issue_identifier: Map.get(run, :issue_identifier),
      pr: %{
        repo_slug: repo_slug(pr),
        number: pr["number"],
        url: pr["url"],
        state: gates["pr"],
        draft: booleanish(pr["draft"] || pr["draft?"]),
        head_sha: pr["head_sha"],
        base_branch: pr["base_branch"] || Config.settings!().pr.base_branch,
        checks: checks_payload(gates),
        review: review_payload(review, gates, pr),
        mergeability: mergeability_payload(gates),
        gates: gates_payload(gates),
        merge: merge_payload(merge),
        next_intended_action: observation["next_intended_action"] || fetch_value(tracked, :next_intended_action),
        last_observed_at: observation["last_observed_at"],
        source: "cached"
      }
    }
  end

  @spec live_payload(map(), keyword()) :: {:ok, map()} | {:skip, map()} | {:error, term()}
  def live_payload(run, opts \\ []) when is_map(run) do
    timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:symphony_elixir, :observability_pr_refresh_timeout_ms, @default_live_timeout_ms))
    cached = cached_payload(run)
    context = pr_context(run, cached)
    runner = opts |> Keyword.get(:runner, command_runner()) |> timeout_runner(timeout_ms)

    case PullRequests.inspect_state(context, runner: runner) do
      {:ok, pr_state} -> {:ok, live_payload_from_state(cached, pr_state)}
      {:skip, reason} -> {:skip, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp live_payload_from_state(cached, pr_state) do
    pr_state = normalize_map(pr_state)
    cached_pr = Map.get(cached, :pr, %{})
    cached_review = Map.get(cached_pr, :review, %{})
    cached_gates = Map.get(cached_pr, :gates, %{})
    checks = normalize_map(pr_state["checks"])
    head_sha = pr_state["head_sha"]
    review = live_review_payload(cached_review, pr_state, head_sha)
    mergeability = live_mergeability_payload(pr_state)

    %{
      issue_identifier: Map.get(cached, :issue_identifier),
      pr: %{
        repo_slug: pr_state["repo_slug"] || Map.get(cached_pr, :repo_slug),
        number: pr_state["number"] || Map.get(cached_pr, :number),
        url: pr_state["url"] || Map.get(cached_pr, :url),
        state: pr_state["state"],
        draft: booleanish(pr_state["draft?"]),
        head_sha: head_sha,
        base_branch: pr_state["base_branch"] || Map.get(cached_pr, :base_branch),
        checks: live_checks_payload(checks),
        review: review,
        mergeability: mergeability,
        gates: live_gates_payload(cached_gates, pr_state, checks, review, mergeability),
        merge: Map.get(cached_pr, :merge, %{}),
        next_intended_action: Map.get(cached_pr, :next_intended_action),
        last_observed_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        source: "live"
      }
    }
  end

  defp pr_context(run, cached) do
    tracked = Map.get(run, :tracked) || %{}
    metadata = workpad_metadata(tracked)
    pr = normalize_map(metadata["pr"])
    cached_pr = Map.get(cached, :pr, %{})

    %{
      number: integerish(pr["number"] || Map.get(cached_pr, :number)),
      url: pick_string([pr["url"], Map.get(cached_pr, :url)]),
      repo_slug: pick_string([pr["repo_slug"], pr["repository"], Map.get(cached_pr, :repo_slug), Config.settings!().pr.repo_slug]),
      head_sha: pick_string([pr["head_sha"], Map.get(cached_pr, :head_sha)])
    }
  end

  defp live_checks_payload(checks) do
    %{
      state: checks["state"],
      passing: integerish(checks["passing"]) || 0,
      pending: integerish(checks["pending"]) || 0,
      failing: integerish(checks["failing"]) || 0,
      total: integerish(checks["total"]) || 0,
      items: normalize_list(checks["items"])
    }
  end

  defp live_review_payload(cached_review, pr_state, head_sha) do
    last_reviewed_head_sha = Map.get(cached_review, :last_reviewed_head_sha)
    current_for_head = is_binary(head_sha) and head_sha != "" and head_sha == last_reviewed_head_sha

    %{
      decision: pr_state["review_decision"],
      symphony_review_state: live_symphony_review_state(cached_review, current_for_head),
      passes_completed: Map.get(cached_review, :passes_completed),
      last_reviewed_head_sha: last_reviewed_head_sha,
      current_for_head: current_for_head
    }
  end

  defp live_symphony_review_state(cached_review, true), do: Map.get(cached_review, :symphony_review_state) || "current"

  defp live_symphony_review_state(cached_review, false) do
    if Map.get(cached_review, :last_reviewed_head_sha), do: "stale", else: Map.get(cached_review, :symphony_review_state)
  end

  defp live_mergeability_payload(pr_state) do
    %{
      state: live_mergeability_state(pr_state),
      mergeable: pr_state["mergeable"],
      merge_state_status: pr_state["merge_state_status"]
    }
  end

  defp live_gates_payload(cached_gates, pr_state, checks, review, mergeability) do
    cached_gates
    |> Map.merge(%{
      pr: pr_gate(pr_state["state"]),
      checks: checks["state"],
      review: review.symphony_review_state,
      mergeability: mergeability.state
    })
  end

  defp live_mergeability_state(pr_state) do
    mergeable = pr_state["mergeable"] |> normalize_token()
    merge_state_status = pr_state["merge_state_status"] |> normalize_token()

    cond do
      booleanish(pr_state["draft?"]) == true -> "blocked"
      pr_state["state"] != "OPEN" -> pr_gate(pr_state["state"])
      mergeable == "CONFLICTING" -> "blocked"
      merge_state_status in ["DIRTY", "BLOCKED"] -> "blocked"
      mergeable == "MERGEABLE" -> "pass"
      true -> "unknown"
    end
  end

  defp pr_gate("OPEN"), do: "open"
  defp pr_gate("MERGED"), do: "merged"
  defp pr_gate("CLOSED"), do: "closed"
  defp pr_gate(state) when is_binary(state), do: state |> String.downcase() |> String.trim()
  defp pr_gate(_state), do: nil

  defp timeout_runner(runner, timeout_ms) when is_function(runner, 3) do
    fn command, args, opts ->
      task = Task.async(fn -> runner.(command, args, opts) end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
      end
    end
  end

  defp command_runner do
    Application.get_env(:symphony_elixir, :github_command_runner, &default_command_runner/3)
  end

  defp default_command_runner(command, args, opts) do
    stderr_to_stdout = Keyword.get(opts, :stderr_to_stdout, true)

    case System.find_executable(command) do
      nil ->
        {:error, {command, :enoent}}

      executable ->
        case System.cmd(executable, args, stderr_to_stdout: stderr_to_stdout, env: [{"GIT_TERMINAL_PROMPT", "0"}]) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {status, output}}
        end
    end
  end

  defp repo_slug(pr) do
    pick_string([pr["repo_slug"], pr["repository"], Config.settings!().pr.repo_slug])
  end

  defp checks_payload(gates) do
    %{
      state: gates["checks"] || gates["check_suite"],
      passing: numeric_gate(gates, "checks_passing"),
      pending: numeric_gate(gates, "checks_pending"),
      failing: numeric_gate(gates, "checks_failing"),
      total: numeric_gate(gates, "checks_total"),
      items: normalize_list(gates["check_items"] || gates["checks_items"])
    }
  end

  defp review_payload(review, gates, pr) do
    head_sha = pr["head_sha"]
    last_reviewed_head_sha = review["last_reviewed_head_sha"]

    %{
      decision: gates["review_decision"],
      symphony_review_state: gates["review"],
      passes_completed: review["passes_completed"],
      last_reviewed_head_sha: last_reviewed_head_sha,
      current_for_head: is_binary(head_sha) and head_sha != "" and head_sha == last_reviewed_head_sha
    }
  end

  defp mergeability_payload(gates) do
    %{
      state: gates["mergeability"],
      mergeable: gates["mergeable"],
      merge_state_status: gates["merge_state_status"]
    }
  end

  defp gates_payload(gates) do
    %{
      pr: gates["pr"],
      checks: gates["checks"] || gates["check_suite"],
      review: gates["review"],
      human_approval: gates["human_approval"],
      mergeability: gates["mergeability"],
      ownership: gates["ownership"],
      kill_switch: gates["kill_switch"],
      dispatch: gates["dispatch"]
    }
  end

  defp merge_payload(merge) do
    %{
      last_attempted_head_sha: merge["last_attempted_head_sha"],
      last_merged_head_sha: merge["last_merged_head_sha"],
      failure_reason: merge["failure_reason"] || merge["last_failure_reason"],
      last_attempted_at: merge["last_attempted_at"],
      last_merged_at: merge["last_merged_at"]
    }
  end

  defp workpad_metadata(tracked) do
    tracked
    |> fetch_value(:workpad)
    |> fetch_value(:metadata)
    |> normalize_map()
  end

  defp workpad_observation(tracked) do
    tracked
    |> fetch_value(:workpad)
    |> fetch_value(:observation)
    |> normalize_map()
  end

  defp numeric_gate(gates, key) do
    case gates[key] do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(_value), do: []

  defp integerish(value) when is_integer(value), do: value

  defp integerish(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integerish(_value), do: nil

  defp normalize_token(value) when is_binary(value), do: value |> String.trim() |> String.upcase()
  defp normalize_token(_value), do: nil

  defp booleanish(value) when is_boolean(value), do: value
  defp booleanish("true"), do: true
  defp booleanish("false"), do: false
  defp booleanish(_value), do: nil
end
