defmodule SymphonyElixir.OrchestrationLifecycle do
  @moduledoc """
  Reconciles durable workpad metadata and branch pull-request state.
  """

  require Logger

  alias SymphonyElixir.{Config, OrchestrationPolicy, PullRequests, ReviewArtifact, Tracker, Workpad, WorkspaceGit}
  alias SymphonyElixir.Linear.Issue

  @type reconcile_result :: {:ok, Issue.t()} | {:ok, :missing} | {:error, term()}

  @doc false
  @spec bootstrap_issue_for_test(Issue.t(), keyword()) :: {:ok, Issue.t()} | {:error, term()}
  def bootstrap_issue_for_test(issue, opts \\ []), do: bootstrap_issue(issue, opts)

  @doc false
  @spec reconcile_after_run_for_test(String.t(), map(), keyword()) :: reconcile_result()
  def reconcile_after_run_for_test(issue_id, running_entry, opts \\ []),
    do: reconcile_after_run(issue_id, running_entry, opts)

  @spec bootstrap_issue(Issue.t(), keyword()) :: {:ok, Issue.t()} | {:error, term()}
  def bootstrap_issue(%Issue{} = issue, opts \\ []) do
    settings = Keyword.get(opts, :settings, Config.settings!())
    runtime = OrchestrationPolicy.issue_runtime(issue, settings)
    passive_pr_updates = passive_pr_updates(issue, runtime, opts, settings)

    if manage_workpad?(issue, runtime) do
      Workpad.sync(
        issue,
        %{
          owned: managed_owned?(issue, runtime),
          phase: Map.get(passive_pr_updates, :phase, runtime.phase),
          branch: issue.branch_name,
          pr: Map.get(passive_pr_updates, :pr),
          waiting_reason: Map.get(passive_pr_updates, :waiting_reason, runtime.waiting_reason),
          next_intended_action: Map.get(passive_pr_updates, :next_intended_action, runtime.next_intended_action),
          observation_gates: Map.merge(bootstrap_gates(issue, runtime), Map.get(passive_pr_updates, :observation_gates, %{}))
        },
        Keyword.put(opts, :settings, settings)
      )
    else
      {:ok, issue}
    end
  end

  @spec reconcile_after_run(String.t(), map(), keyword()) :: reconcile_result()
  def reconcile_after_run(issue_id, running_entry, opts \\ [])
      when is_binary(issue_id) and is_map(running_entry) and is_list(opts) do
    settings = Keyword.get(opts, :settings, Config.settings!())
    issue_fetcher = Keyword.get(opts, :issue_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    case fetch_issue(issue_id, issue_fetcher) do
      {:ok, %Issue{} = issue} ->
        git_state = inspect_workspace_git(running_entry, opts)
        pr_result = PullRequests.resolve_or_create(issue, git_state, Keyword.put(opts, :settings, settings))
        runtime = OrchestrationPolicy.issue_runtime(issue, settings)
        review_result = maybe_persist_review_comment(issue, runtime, pr_result, running_entry, opts, settings)

        updates =
          lifecycle_updates(
            issue,
            runtime,
            git_state,
            pr_result,
            review_result,
            settings
          )

        Workpad.sync(issue, updates, Keyword.put(opts, :settings, settings))

      {:ok, :missing} ->
        {:ok, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_issue(issue_id, issue_fetcher) when is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = issue | _]} -> {:ok, issue}
      {:ok, []} -> {:ok, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp inspect_workspace_git(running_entry, _opts) do
    workspace_path = Map.get(running_entry, :workspace_path)
    worker_host = Map.get(running_entry, :worker_host)

    case WorkspaceGit.inspect_workspace(workspace_path, worker_host) do
      {:ok, git_state} ->
        git_state

      {:error, reason} ->
        Logger.debug("Workspace git inspection unavailable workspace=#{inspect(workspace_path)} worker_host=#{inspect(worker_host)} reason=#{inspect(reason)}")
        %{}
    end
  end

  defp lifecycle_updates(issue, runtime, git_state, pr_result, review_result, settings) do
    branch = pick_string([Map.get(git_state, :branch), issue.branch_name])
    head_sha = pick_string([Map.get(git_state, :head_sha)])
    pr_metadata = pr_metadata(pr_result, head_sha)

    base_updates =
      %{
        owned: managed_owned?(issue, runtime),
        branch: branch,
        pr: pr_metadata,
        observation_gates: observation_gates(issue, runtime, pr_result, review_result, pr_metadata, settings),
        next_intended_action: next_action(runtime, pr_result),
        waiting_reason: waiting_reason(runtime, pr_result),
        phase: phase_after_reconcile(runtime, pr_result)
      }
      |> maybe_put_review_update(review_update(runtime, pr_metadata, review_result))

    cond do
      match?({:error, _reason}, pr_result) and settings.pr.auto_create == true and settings.rollout.mode in ["mutate", "merge"] ->
        Map.merge(base_updates, %{phase: "blocked", waiting_reason: "tool_unavailable", next_intended_action: "restore_pr_tooling"})

      review_persistence_blocked?(review_result) ->
        Map.merge(base_updates, %{phase: "reviewing", waiting_reason: nil, next_intended_action: review_followup_action(review_result)})

      true ->
        base_updates
    end
  end

  defp phase_after_reconcile(runtime, {:ok, pr_info}) do
    if promote_to_waiting_for_checks?(runtime, pr_info) do
      "waiting_for_checks"
    else
      runtime.phase
    end
  end

  defp phase_after_reconcile(_runtime, {:skip, %{reason: :closed_pr_policy_stop}}), do: "blocked"
  defp phase_after_reconcile(_runtime, {:skip, %{reason: :merged_pr_cannot_reopen}}), do: "blocked"
  defp phase_after_reconcile(runtime, _pr_result), do: runtime.phase

  defp waiting_reason(runtime, {:ok, pr_info}) do
    if promote_to_waiting_for_checks?(runtime, pr_info) do
      "checks_pending"
    else
      runtime.waiting_reason
    end
  end

  defp waiting_reason(_runtime, {:skip, %{reason: :closed_pr_policy_stop}}), do: "missing_context"
  defp waiting_reason(_runtime, {:skip, %{reason: :merged_pr_cannot_reopen}}), do: "missing_context"
  defp waiting_reason(runtime, _pr_result), do: runtime.waiting_reason

  defp next_action(runtime, {:ok, pr_info}) do
    if promote_to_waiting_for_checks?(runtime, pr_info) do
      "poll_on_next_cycle"
    else
      runtime.next_intended_action
    end
  end

  defp next_action(_runtime, {:skip, %{next_intended_action: action}}) when is_binary(action), do: action
  defp next_action(_runtime, {:error, _reason}), do: "repair_pr_publication"

  defp pr_metadata({:ok, pr_info}, fallback_head_sha) do
    %{
      number: Map.get(pr_info, :number),
      url: Map.get(pr_info, :url),
      head_sha: pick_string([Map.get(pr_info, :head_sha), fallback_head_sha])
    }
  end

  defp pr_metadata({:skip, %{pr: pr}}, fallback_head_sha) when is_map(pr) do
    %{
      number: Map.get(pr, :number),
      url: Map.get(pr, :url),
      head_sha: pick_string([Map.get(pr, :head_sha), fallback_head_sha])
    }
  end

  defp pr_metadata(_pr_result, fallback_head_sha) do
    %{
      number: nil,
      url: nil,
      head_sha: fallback_head_sha
    }
  end

  defp observation_gates(issue, runtime, pr_result, review_result, pr_metadata, settings) do
    bootstrap_gates(issue, runtime)
    |> Map.put("pr", pr_gate(pr_result))
    |> Map.put("review", review_gate(runtime, pr_metadata, review_result, settings))
  end

  defp pr_gate({:ok, _pr_info}), do: "open"
  defp pr_gate({:skip, %{reason: :observe_only}}), do: "observe_only"
  defp pr_gate({:skip, %{reason: :auto_create_disabled}}), do: "policy_disabled"
  defp pr_gate({:skip, %{reason: :closed_pr_policy_stop}}), do: "blocked"
  defp pr_gate({:skip, %{reason: :merged_pr_cannot_reopen}}), do: "blocked"
  defp pr_gate({:skip, _details}), do: "pending"
  defp pr_gate({:error, _reason}), do: "tool_unavailable"

  defp review_gate(_runtime, _pr_metadata, _review_result, settings) when settings.review.enabled != true,
    do: "disabled"

  defp review_gate(_runtime, _pr_metadata, {:ok, _details}, _settings), do: "persisted"
  defp review_gate(_runtime, _pr_metadata, {:skip, %{reason: :review_comment_mode_off}}, _settings), do: "disabled"
  defp review_gate(_runtime, _pr_metadata, {:skip, %{reason: :observe_only}}, _settings), do: "observe_only"
  defp review_gate(_runtime, _pr_metadata, {:skip, %{reason: :missing_review_body}}, _settings), do: "missing"
  defp review_gate(_runtime, _pr_metadata, {:skip, %{reason: :stale_review_artifact}}, _settings), do: "stale"
  defp review_gate(_runtime, _pr_metadata, {:error, _reason}, _settings), do: "tool_unavailable"

  defp review_gate(runtime, pr_metadata, _review_result, _settings) do
    current_head_sha = Map.get(pr_metadata, :head_sha) || Map.get(pr_metadata, "head_sha")
    review_metadata = current_review_metadata(runtime)
    last_reviewed_head_sha = Map.get(review_metadata, "last_reviewed_head_sha")
    passes_completed = Map.get(review_metadata, "passes_completed") || 0

    review_head_state(current_head_sha, last_reviewed_head_sha, passes_completed)
  end

  defp review_head_state(current_head_sha, last_reviewed_head_sha, passes_completed)
       when is_binary(current_head_sha) and is_binary(last_reviewed_head_sha) and passes_completed > 0 do
    if current_head_sha == last_reviewed_head_sha, do: "current", else: "stale"
  end

  defp review_head_state(_current_head_sha, _last_reviewed_head_sha, _passes_completed), do: "missing"

  defp review_persistence_blocked?({:error, _reason}), do: true
  defp review_persistence_blocked?({:skip, %{reason: reason}}), do: reason in [:missing_review_body, :stale_review_artifact]
  defp review_persistence_blocked?(_review_result), do: false

  defp review_followup_action({:skip, %{next_intended_action: action}}) when is_binary(action), do: action
  defp review_followup_action({:error, _reason}), do: "repair_review_comment_persistence"
  defp review_followup_action(_review_result), do: "persist_review_artifact"

  defp maybe_persist_review_comment(_issue, runtime, pr_result, running_entry, opts, settings) do
    with true <- settings.review.enabled == true,
         {:ok, pr_info} <- pr_result,
         {:ok, artifact} <- load_current_review_artifact(running_entry, pr_info) do
      PullRequests.upsert_review_comment(
        %{
          number: Map.get(pr_info, :number),
          repo_slug: Map.get(pr_info, :repo_slug),
          comment_id: current_review_comment_id(runtime)
        },
        artifact.body,
        Keyword.put(opts, :settings, settings)
      )
    else
      false -> {:skip, %{reason: :review_disabled}}
      {:skip, _details} = skip -> skip
      {:error, _reason} = error -> error
    end
  end

  defp load_current_review_artifact(running_entry, pr_info) when is_map(running_entry) and is_map(pr_info) do
    with {:ok, artifact} <- load_review_artifact(running_entry),
         %{} = artifact <- artifact,
         :ok <- validate_review_artifact_head(artifact, pr_info) do
      {:ok, artifact}
    else
      :missing -> {:skip, %{reason: :missing_review_body, next_intended_action: "persist_review_artifact"}}
      {:review_head, _reason} -> {:skip, %{reason: :stale_review_artifact, next_intended_action: "rerun_review_for_current_head"}}
      {:error, _reason} = error -> error
    end
  end

  defp load_review_artifact(running_entry) when is_map(running_entry) do
    running_entry
    |> Map.get(:workspace_path)
    |> ReviewArtifact.load()
  end

  defp validate_review_artifact_head(artifact, pr_info) when is_map(artifact) and is_map(pr_info) do
    current_head_sha = Map.get(pr_info, :head_sha)
    reviewed_head_sha = Map.get(artifact, :reviewed_head_sha)

    cond do
      not is_binary(current_head_sha) -> {:review_head, :missing_current_head}
      not is_binary(reviewed_head_sha) -> {:review_head, :missing_artifact_head}
      reviewed_head_sha != current_head_sha -> {:review_head, :mismatch}
      true -> :ok
    end
  end

  defp review_update(runtime, pr_metadata, {:ok, details}) do
    review_metadata = current_review_metadata(runtime)
    head_sha = Map.get(pr_metadata, :head_sha) || Map.get(pr_metadata, "head_sha")
    last_reviewed_head_sha = Map.get(review_metadata, "last_reviewed_head_sha")
    passes_completed = Map.get(review_metadata, "passes_completed") || 0

    %{
      comment_id: Map.get(details, :comment_id),
      passes_completed: persisted_review_pass_count(last_reviewed_head_sha, head_sha, passes_completed),
      last_reviewed_head_sha: head_sha,
      last_fixed_head_sha: last_fixed_head_sha(review_metadata, last_reviewed_head_sha, head_sha)
    }
  end

  defp review_update(_runtime, _pr_metadata, _review_result), do: nil

  defp persisted_review_pass_count(last_reviewed_head_sha, head_sha, passes_completed) do
    if last_reviewed_head_sha == head_sha and passes_completed > 0 do
      passes_completed
    else
      passes_completed + 1
    end
  end

  defp last_fixed_head_sha(review_metadata, previous_reviewed_head_sha, current_head_sha) do
    if is_binary(previous_reviewed_head_sha) and previous_reviewed_head_sha != current_head_sha do
      current_head_sha
    else
      Map.get(review_metadata, "last_fixed_head_sha")
    end
  end

  defp current_review_metadata(runtime) do
    runtime
    |> fetch_value(:workpad)
    |> fetch_value(:metadata)
    |> normalize_map()
    |> Map.get("review", %{})
    |> normalize_map()
  end

  defp current_review_comment_id(runtime) do
    runtime
    |> current_review_metadata()
    |> Map.get("comment_id")
  end

  defp current_pr_metadata(runtime) do
    runtime
    |> fetch_value(:workpad)
    |> fetch_value(:metadata)
    |> normalize_map()
    |> Map.get("pr", %{})
    |> normalize_map()
  end

  defp passive_pr_updates(issue, runtime, opts, settings) do
    with true <- runtime.passive_phase == true,
         {:ok, context} <- passive_pr_context(runtime, opts),
         result <- PullRequests.inspect_state(context, Keyword.put(opts, :settings, settings)) do
      passive_pr_updates_from_result(result, issue, runtime, settings)
    else
      false -> %{}
      {:skip, _details} -> %{}
    end
  end

  defp passive_pr_context(runtime, opts) do
    pr_metadata = current_pr_metadata(runtime)
    pr_number = Map.get(pr_metadata, "number")
    pr_url = Map.get(pr_metadata, "url")
    repo_slug = Keyword.get(opts, :repo_slug)

    if is_integer(pr_number) or (is_binary(pr_number) and String.trim(pr_number) != "") do
      {:ok, %{number: pr_number, url: pr_url, repo_slug: repo_slug}}
    else
      {:skip, %{reason: :missing_pr_number}}
    end
  end

  defp passive_pr_updates_from_result({:ok, pr_state}, issue, runtime, settings) when is_map(pr_state) do
    review_status = review_gate(runtime, %{head_sha: pr_state.head_sha}, nil, settings)
    observation_gates = passive_pr_observation_gates(issue, runtime, pr_state, review_status, settings)

    %{
      phase: passive_phase_after_observation(issue, runtime, pr_state, review_status, settings),
      pr: %{number: pr_state.number, url: pr_state.url, head_sha: pr_state.head_sha},
      waiting_reason: passive_waiting_reason(issue, runtime, pr_state, review_status, settings),
      next_intended_action: passive_next_action(issue, runtime, pr_state, review_status, settings),
      observation_gates: observation_gates
    }
  end

  defp passive_pr_updates_from_result({:error, _reason}, _issue, _runtime, _settings) do
    %{
      observation_gates: %{
        "pr" => "tool_unavailable",
        "checks" => "unknown",
        "mergeability" => "unknown"
      }
    }
  end

  defp passive_pr_updates_from_result(_result, _issue, _runtime, _settings), do: %{}

  defp passive_pr_observation_gates(issue, runtime, pr_state, review_status, settings) do
    %{
      "pr" => passive_pr_gate(pr_state),
      "review" => review_status,
      "checks" => checks_gate(pr_state),
      "human_approval" => human_approval_gate(issue, settings),
      "mergeability" => mergeability_gate(pr_state),
      "head_match" => head_match_gate(runtime, pr_state)
    }
  end

  defp passive_phase_after_observation(issue, runtime, pr_state, review_status, settings) do
    cond do
      passive_pr_gate(pr_state) != "open" -> runtime.phase
      mergeability_gate(pr_state) == "blocked" -> "waiting_for_checks"
      checks_ready?(pr_state, settings) != true -> "waiting_for_checks"
      review_ready?(review_status, settings) != true -> "waiting_for_checks"
      human_approval_ready?(issue, settings) != true -> "waiting_for_human"
      true -> "ready_to_merge"
    end
  end

  defp passive_waiting_reason(issue, runtime, pr_state, review_status, settings) do
    cond do
      passive_pr_gate(pr_state) != "open" -> runtime.waiting_reason
      mergeability_gate(pr_state) == "blocked" -> "mergeability_changed"
      checks_ready?(pr_state, settings) != true -> "checks_pending"
      review_ready?(review_status, settings) != true -> runtime.waiting_reason || "checks_pending"
      human_approval_ready?(issue, settings) != true -> "human_approval_required"
      true -> nil
    end
  end

  defp passive_next_action(issue, runtime, pr_state, review_status, settings) do
    cond do
      passive_pr_gate(pr_state) != "open" -> runtime.next_intended_action
      mergeability_gate(pr_state) == "blocked" -> "repair_mergeability"
      true -> passive_readiness_next_action(issue, runtime, pr_state, review_status, settings)
    end
  end

  defp passive_readiness_next_action(issue, runtime, pr_state, review_status, settings) do
    cond do
      checks_gate(pr_state) == "fail" -> "investigate_failing_checks"
      checks_ready?(pr_state, settings) != true -> "poll_on_next_cycle"
      review_status == "stale" -> "rerun_review_for_current_head"
      review_status == "missing" -> "persist_review_artifact"
      review_ready?(review_status, settings) != true -> runtime.next_intended_action
      human_approval_ready?(issue, settings) != true -> "await_human_approval"
      true -> "merge_when_green"
    end
  end

  defp passive_pr_gate(%{state: state, draft?: draft?}) do
    cond do
      state == "MERGED" -> "merged"
      state == "CLOSED" -> "closed"
      draft? == true -> "draft"
      true -> "open"
    end
  end

  defp checks_gate(%{checks: %{state: state}}) when is_binary(state), do: state
  defp checks_gate(_pr_state), do: "unknown"

  defp human_approval_gate(_issue, settings)
       when settings.merge.require_human_approval != true or settings.merge.approval_states == [],
       do: "not_required"

  defp human_approval_gate(%Issue{state: state}, settings) do
    if state in settings.merge.approval_states do
      "approved"
    else
      "required"
    end
  end

  defp human_approval_ready?(issue, settings), do: human_approval_gate(issue, settings) in ["approved", "not_required"]

  defp mergeability_gate(%{state: state, draft?: draft?, mergeable: mergeable, merge_state_status: merge_state_status}) do
    mergeable = normalize_token(mergeable)
    merge_state_status = normalize_token(merge_state_status)

    cond do
      state in ["MERGED", "CLOSED"] -> "blocked"
      draft? == true -> "blocked"
      mergeable == "CONFLICTING" -> "blocked"
      merge_state_status in ["DIRTY", "BLOCKED", "DRAFT", "BEHIND"] -> "blocked"
      mergeable == "MERGEABLE" -> "pass"
      merge_state_status in ["CLEAN", "UNSTABLE", "HAS_HOOKS"] -> "pass"
      true -> "unknown"
    end
  end

  defp head_match_gate(runtime, %{head_sha: current_head_sha}) do
    persisted_head_sha =
      runtime
      |> current_pr_metadata()
      |> Map.get("head_sha")

    cond do
      not is_binary(current_head_sha) -> "missing"
      not is_binary(persisted_head_sha) -> "missing"
      current_head_sha == persisted_head_sha -> "current"
      true -> "stale"
    end
  end

  defp checks_ready?(pr_state, settings) do
    settings.merge.require_green_checks != true or checks_gate(pr_state) == "pass"
  end

  defp review_ready?(_review_status, settings) when settings.review.enabled != true, do: true
  defp review_ready?(review_status, _settings), do: review_status in ["current", "persisted"]

  defp normalize_token(value) when is_binary(value), do: String.upcase(String.trim(value))
  defp normalize_token(_value), do: nil

  defp maybe_put_review_update(updates, nil), do: updates
  defp maybe_put_review_update(updates, review), do: Map.put(updates, :review, review)

  defp bootstrap_gates(issue, runtime) do
    %{
      "ownership" => if(managed_owned?(issue, runtime), do: "pass", else: "fail"),
      "kill_switch" => if(fetch_value(runtime.kill_switch, :active) == true, do: "active", else: "pass"),
      "dispatch" => if(runtime.dispatch_allowed, do: "pass", else: "blocked")
    }
  end

  defp manage_workpad?(issue, runtime) do
    managed_owned?(issue, runtime)
  end

  defp managed_owned?(%Issue{assigned_to_worker: assigned_to_worker}, runtime)
       when is_boolean(assigned_to_worker) do
    assigned_to_worker and label_gate_passed?(runtime)
  end

  defp promote_to_waiting_for_checks?(runtime, pr_info) when is_map(pr_info) do
    action = Map.get(pr_info, :action)

    action in [:created, :reopened] or runtime.phase in ["implementing", "reviewing", "rework"]
  end

  defp label_gate_passed?(runtime) do
    case fetch_value(runtime.ownership, :required_label) do
      value when is_binary(value) -> fetch_value(runtime.ownership, :label_present) == true
      _ -> true
    end
  end

  defp fetch_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch_value(_map, _key), do: nil

  defp normalize_map(%{} = map), do: map
  defp normalize_map(_value), do: %{}

  defp pick_string(values) when is_list(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          normalized -> normalized
        end

      _ ->
        nil
    end)
  end
end
