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
    tracker_module = Keyword.get(opts, :tracker_module, Tracker)
    issue_fetcher = Keyword.get(opts, :issue_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second))

    case fetch_issue(issue_id, issue_fetcher) do
      {:ok, %Issue{} = issue} ->
        git_state = inspect_workspace_git(running_entry, opts)
        pr_result = PullRequests.resolve_or_create(issue, git_state, Keyword.put(opts, :settings, settings))
        runtime = OrchestrationPolicy.issue_runtime(issue, settings)
        review_result = maybe_persist_review_comment(issue, runtime, pr_result, running_entry, opts, settings)
        merge_result = maybe_merge_pull_request(issue, runtime, pr_result, opts, settings)

        updates =
          lifecycle_updates(
            issue,
            runtime,
            git_state,
            pr_result,
            review_result,
            merge_result,
            settings,
            now
          )

        with {:ok, updated_issue} <-
               Workpad.sync(
                 issue,
                 updates,
                 Keyword.merge(opts, settings: settings, tracker_module: tracker_module, now: now)
               ) do
          maybe_reconcile_tracker_completion(updated_issue, merge_result, tracker_module, settings)
        end

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

  defp lifecycle_updates(issue, runtime, git_state, pr_result, review_result, merge_result, settings, now) do
    branch = pick_string([Map.get(git_state, :branch), issue.branch_name])
    head_sha = pick_string([Map.get(git_state, :head_sha)])
    base_pr_metadata = pr_metadata(pr_result, head_sha)
    current_pr_metadata = merge_pr_metadata(base_pr_metadata, merge_result)

    base_updates =
      %{
        owned: managed_owned?(issue, runtime),
        branch: branch,
        pr: current_pr_metadata,
        observation_gates:
          observation_gates(
            issue,
            runtime,
            pr_result,
            review_result,
            current_pr_metadata,
            merge_result,
            settings
          ),
        next_intended_action: next_action(issue, runtime, pr_result, merge_result, settings),
        waiting_reason: waiting_reason(issue, runtime, pr_result, merge_result, settings),
        phase: phase_after_reconcile(issue, runtime, pr_result, merge_result, settings)
      }
      |> maybe_put_review_update(review_update(runtime, current_pr_metadata, review_result))
      |> maybe_put_merge_update(merge_update(current_pr_metadata, merge_result, now))

    cond do
      match?({:error, _reason}, pr_result) and settings.pr.auto_create == true and settings.rollout.mode in ["mutate", "merge"] ->
        Map.merge(base_updates, %{phase: "blocked", waiting_reason: "tool_unavailable", next_intended_action: "restore_pr_tooling"})

      review_persistence_blocked?(review_result) ->
        Map.merge(base_updates, %{phase: "reviewing", waiting_reason: nil, next_intended_action: review_followup_action(review_result)})

      merge_execution_failed?(merge_result) ->
        Map.merge(base_updates, %{phase: "blocked", waiting_reason: "tool_unavailable", next_intended_action: "repair_merge_tooling"})

      true ->
        base_updates
    end
  end

  defp phase_after_reconcile(issue, runtime, pr_result, merge_result, settings) do
    cond do
      merge_phase?(runtime.phase) ->
        phase_after_merge(issue, runtime, merge_result, settings)

      match?({:ok, _pr_info}, pr_result) and promote_to_waiting_for_checks?(runtime, elem(pr_result, 1)) ->
        "waiting_for_checks"

      match?({:skip, %{reason: :closed_pr_policy_stop}}, pr_result) ->
        "blocked"

      match?({:skip, %{reason: :merged_pr_cannot_reopen}}, pr_result) ->
        "blocked"

      true ->
        runtime.phase
    end
  end

  defp waiting_reason(issue, runtime, pr_result, merge_result, settings) do
    cond do
      merge_phase?(runtime.phase) ->
        waiting_reason_after_merge(issue, runtime, merge_result, settings)

      match?({:ok, _pr_info}, pr_result) and promote_to_waiting_for_checks?(runtime, elem(pr_result, 1)) ->
        "checks_pending"

      match?({:skip, %{reason: :closed_pr_policy_stop}}, pr_result) ->
        "missing_context"

      match?({:skip, %{reason: :merged_pr_cannot_reopen}}, pr_result) ->
        "missing_context"

      true ->
        runtime.waiting_reason
    end
  end

  defp next_action(issue, runtime, pr_result, merge_result, settings) do
    cond do
      merge_phase?(runtime.phase) ->
        next_action_after_merge(issue, runtime, merge_result, settings)

      match?({:ok, _pr_info}, pr_result) and promote_to_waiting_for_checks?(runtime, elem(pr_result, 1)) ->
        "poll_on_next_cycle"

      match?({:skip, %{next_intended_action: action}} when is_binary(action), pr_result) ->
        get_in(elem(pr_result, 1), [:next_intended_action])

      match?({:error, _reason}, pr_result) ->
        "repair_pr_publication"

      true ->
        runtime.next_intended_action
    end
  end

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

  defp merge_pr_metadata(pr_metadata, merge_result) do
    case merge_result_pr_state(merge_result) do
      %{} = pr_state ->
        %{
          number: Map.get(pr_state, :number) || Map.get(pr_metadata, :number),
          url: Map.get(pr_state, :url) || Map.get(pr_metadata, :url),
          head_sha: pick_string([Map.get(pr_state, :head_sha), Map.get(pr_metadata, :head_sha)])
        }

      _ ->
        pr_metadata
    end
  end

  defp observation_gates(issue, runtime, pr_result, review_result, pr_metadata, merge_result, settings) do
    case merge_observation_gates(issue, runtime, merge_result, settings) do
      nil ->
        bootstrap_gates(issue, runtime)
        |> Map.put("pr", pr_gate(pr_result))
        |> Map.put("review", review_gate(runtime, pr_metadata, review_result, settings))

      merge_gates ->
        bootstrap_gates(issue, runtime)
        |> Map.merge(merge_gates)
    end
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
         true <- review_persistence_phase?(runtime.phase),
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
      false -> {:skip, %{reason: :review_persistence_not_requested}}
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

  defp review_persistence_phase?(phase), do: phase in ["implementing", "reviewing", "rework"]

  defp merge_phase?(phase), do: phase in ["ready_to_merge", "merging"]

  defp maybe_merge_pull_request(issue, runtime, pr_result, opts, settings) do
    cond do
      merge_phase?(runtime.phase) != true ->
        {:skip, %{reason: :merge_not_requested}}

      human_approval_ready?(issue, settings) != true ->
        {:skip, %{reason: :human_approval_required, next_intended_action: "await_human_approval"}}

      true ->
        case merge_pr_context(runtime, pr_result, opts, settings) do
          {:ok, context} ->
            PullRequests.merge_if_head_matches(context, Keyword.put(opts, :settings, settings))

          {:skip, _details} = skip ->
            skip
        end
    end
  end

  defp merge_pr_context(runtime, {:ok, pr_info}, _opts, settings) when is_map(pr_info) do
    {:ok,
     %{
       number: Map.get(pr_info, :number),
       repo_slug: Map.get(pr_info, :repo_slug),
       url: Map.get(pr_info, :url),
       expected_head_sha: expected_merge_head_sha(runtime, pr_info, settings)
     }}
  end

  defp merge_pr_context(runtime, _pr_result, opts, settings) do
    pr_metadata = current_pr_metadata(runtime)
    repo_slug = Keyword.get(opts, :repo_slug)

    context = %{
      number: Map.get(pr_metadata, "number"),
      repo_slug: repo_slug,
      url: Map.get(pr_metadata, "url"),
      expected_head_sha:
        expected_merge_head_sha(
          runtime,
          %{head_sha: Map.get(pr_metadata, "head_sha")},
          settings
        )
    }

    if is_nil(context.number) and not is_binary(context.url) do
      {:skip, %{reason: :missing_pr_number, next_intended_action: "record_pr_context"}}
    else
      {:ok, context}
    end
  end

  defp expected_merge_head_sha(runtime, pr_info, settings) do
    review_metadata = current_review_metadata(runtime)
    pr_metadata = current_pr_metadata(runtime)

    if settings.review.enabled == true do
      pick_string([Map.get(review_metadata, "last_reviewed_head_sha")])
    else
      pick_string([Map.get(pr_info, :head_sha), Map.get(pr_metadata, "head_sha")])
    end
  end

  defp merge_execution_failed?({:error, _reason}), do: true
  defp merge_execution_failed?(_merge_result), do: false

  defp merge_successful?({:ok, %{state: "MERGED"}}), do: true
  defp merge_successful?(_merge_result), do: false

  defp merge_already_completed?({:skip, %{reason: :already_merged}}), do: true
  defp merge_already_completed?(_merge_result), do: false

  defp merge_result_pr_state({:ok, %{pr_state: pr_state}}) when is_map(pr_state), do: pr_state
  defp merge_result_pr_state({:skip, %{pr_state: pr_state}}) when is_map(pr_state), do: pr_state
  defp merge_result_pr_state(_merge_result), do: nil

  defp merge_skip_reason({:skip, %{reason: reason}}), do: reason
  defp merge_skip_reason(_merge_result), do: nil

  defp merge_review_status(runtime, merge_result, settings) do
    case merge_result_pr_state(merge_result) do
      %{} = pr_state -> review_gate(runtime, %{head_sha: pr_state.head_sha}, nil, settings)
      _ -> review_gate(runtime, current_pr_metadata(runtime), nil, settings)
    end
  end

  defp merge_observation_gates(issue, runtime, merge_result, settings) do
    case merge_result_pr_state(merge_result) do
      %{} = pr_state ->
        passive_pr_observation_gates(issue, pr_state, merge_review_status(runtime, merge_result, settings), settings)

      _ ->
        nil
    end
  end

  defp phase_after_merge(issue, runtime, merge_result, settings) do
    review_status = merge_review_status(runtime, merge_result, settings)
    reason = merge_skip_reason(merge_result)
    pr_state = merge_result_pr_state(merge_result)

    cond do
      merge_successful?(merge_result) or merge_already_completed?(merge_result) ->
        "merging"

      reason == :human_approval_required ->
        "waiting_for_human"

      reason in [:missing_expected_head_sha, :missing_pr_number, :missing_repo_slug] ->
        "blocked"

      is_map(pr_state) ->
        passive_phase_after_observation(issue, runtime, pr_state, review_status, settings)

      match?({:error, _reason}, merge_result) ->
        "blocked"

      true ->
        runtime.phase
    end
  end

  defp waiting_reason_after_merge(issue, runtime, merge_result, settings) do
    review_status = merge_review_status(runtime, merge_result, settings)
    reason = merge_skip_reason(merge_result)
    pr_state = merge_result_pr_state(merge_result)

    cond do
      merge_successful?(merge_result) or merge_already_completed?(merge_result) ->
        nil

      reason == :human_approval_required ->
        "human_approval_required"

      reason in [:missing_expected_head_sha, :missing_pr_number, :missing_repo_slug] ->
        "missing_context"

      is_map(pr_state) ->
        passive_waiting_reason(issue, runtime, pr_state, review_status, settings)

      match?({:error, _reason}, merge_result) ->
        "tool_unavailable"

      true ->
        runtime.waiting_reason
    end
  end

  defp next_action_after_merge(_issue, runtime, merge_result, _settings) do
    cond do
      merge_successful?(merge_result) or merge_already_completed?(merge_result) ->
        "reconcile_tracker_completion"

      match?({:skip, %{next_intended_action: action}} when is_binary(action), merge_result) ->
        get_in(elem(merge_result, 1), [:next_intended_action])

      match?({:error, _reason}, merge_result) ->
        "repair_merge_tooling"

      true ->
        runtime.next_intended_action
    end
  end

  defp merge_update(pr_metadata, merge_result, now) do
    timestamp = DateTime.to_iso8601(now)
    attempted_head_sha = pick_string([merge_expected_head_sha(merge_result), Map.get(pr_metadata, :head_sha), Map.get(pr_metadata, "head_sha")])

    cond do
      match?({:skip, %{reason: :merge_not_requested}}, merge_result) ->
        nil

      merge_successful?(merge_result) or merge_already_completed?(merge_result) ->
        %{
          last_attempted_at: timestamp,
          last_attempted_head_sha: attempted_head_sha,
          last_merge_commit_sha: merge_commit_sha(merge_result),
          last_merged_head_sha: merge_live_head_sha(merge_result),
          last_failure_reason: nil
        }

      match?({:skip, _details}, merge_result) ->
        %{
          last_attempted_at: timestamp,
          last_attempted_head_sha: attempted_head_sha,
          last_failure_reason: merge_failure_reason(merge_result)
        }

      match?({:error, _reason}, merge_result) ->
        %{
          last_attempted_at: timestamp,
          last_attempted_head_sha: attempted_head_sha,
          last_failure_reason: "tool_unavailable"
        }

      true ->
        nil
    end
  end

  defp merge_expected_head_sha({:ok, details}), do: Map.get(details, :expected_head_sha)
  defp merge_expected_head_sha({:skip, details}), do: Map.get(details, :expected_head_sha)
  defp merge_expected_head_sha(_merge_result), do: nil

  defp merge_live_head_sha(merge_result) do
    case merge_result_pr_state(merge_result) do
      %{} = pr_state -> Map.get(pr_state, :head_sha)
      _ -> nil
    end
  end

  defp merge_commit_sha({:ok, details}), do: Map.get(details, :merge_commit_sha)
  defp merge_commit_sha(_merge_result), do: nil

  defp merge_failure_reason({:skip, %{reason: reason}}) when is_atom(reason), do: Atom.to_string(reason)
  defp merge_failure_reason(_merge_result), do: nil

  defp maybe_reconcile_tracker_completion(%Issue{} = issue, merge_result, tracker_module, settings) do
    done_state = done_tracker_state(settings)

    cond do
      issue.id == nil or done_state == nil ->
        {:ok, issue}

      not merge_tracker_completion_required?(merge_result) ->
        {:ok, issue}

      issue.state == done_state ->
        {:ok, issue}

      true ->
        apply_tracker_completion_update(issue, done_state, tracker_module)
    end
  end

  defp merge_tracker_completion_required?(merge_result) do
    merge_successful?(merge_result) or merge_already_completed?(merge_result)
  end

  defp apply_tracker_completion_update(%Issue{} = issue, done_state, tracker_module) do
    case tracker_module.update_issue_state(issue.id, done_state) do
      :ok ->
        {:ok, %{issue | state: done_state}}

      {:error, reason} ->
        Logger.warning("Tracker completion update failed issue_id=#{issue.id} state=#{done_state} reason=#{inspect(reason)}")

        {:ok, issue}
    end
  end

  defp done_tracker_state(settings) do
    terminal_states = Enum.filter(settings.tracker.terminal_states, &is_binary/1)

    find_preferred_terminal_state(terminal_states, ["done", "completed", "closed"]) ||
      List.first(terminal_states)
  end

  defp find_preferred_terminal_state(terminal_states, preferred_states) do
    Enum.find_value(preferred_states, fn preferred_state ->
      Enum.find(terminal_states, &(normalize_tracker_state(&1) == preferred_state))
    end)
  end

  defp normalize_tracker_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_tracker_state(_state), do: ""

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

    if is_integer(pr_number) or (is_binary(pr_number) and String.trim(pr_number) != "") or is_binary(pr_url) do
      {:ok, %{number: pr_number, url: pr_url, repo_slug: repo_slug}}
    else
      {:skip, %{reason: :missing_pr_number}}
    end
  end

  defp passive_pr_updates_from_result({:ok, pr_state}, issue, runtime, settings) when is_map(pr_state) do
    pr_metadata = %{number: pr_state.number, url: pr_state.url, head_sha: pr_state.head_sha}
    review_status = review_gate(runtime, %{head_sha: pr_state.head_sha}, nil, settings)
    observation_gates = passive_pr_observation_gates(issue, pr_state, review_status, settings)

    %{
      phase: passive_phase_after_observation(issue, runtime, pr_state, review_status, settings),
      pr: pr_metadata,
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

  defp passive_pr_observation_gates(issue, pr_state, review_status, settings) do
    %{
      "pr" => passive_pr_gate(pr_state),
      "review" => review_status,
      "checks" => checks_gate(pr_state),
      "human_approval" => human_approval_gate(issue, settings),
      "mergeability" => mergeability_gate(pr_state)
    }
  end

  defp passive_phase_after_observation(issue, runtime, pr_state, review_status, settings) do
    cond do
      passive_pr_gate(pr_state) != "open" -> "blocked"
      mergeability_ready?(pr_state) != true -> "waiting_for_checks"
      checks_ready?(pr_state, settings) != true -> "waiting_for_checks"
      review_ready?(review_status, settings) != true -> "waiting_for_checks"
      human_approval_ready?(issue, settings) != true -> "waiting_for_human"
      ready_to_merge_promotion_allowed?(settings) -> "ready_to_merge"
      true -> runtime.phase
    end
  end

  defp passive_waiting_reason(issue, _runtime, pr_state, review_status, settings) do
    cond do
      passive_pr_gate(pr_state) != "open" -> "missing_context"
      mergeability_gate(pr_state) == "blocked" -> "mergeability_changed"
      true -> passive_readiness_waiting_reason(issue, pr_state, review_status, settings)
    end
  end

  defp passive_readiness_waiting_reason(issue, pr_state, review_status, settings) do
    cond do
      mergeability_ready?(pr_state) != true -> "checks_pending"
      checks_ready?(pr_state, settings) != true -> "checks_pending"
      review_ready?(review_status, settings) != true -> "checks_pending"
      human_approval_ready?(issue, settings) != true -> "human_approval_required"
      true -> nil
    end
  end

  defp passive_next_action(issue, runtime, pr_state, review_status, settings) do
    cond do
      passive_pr_gate(pr_state) != "open" -> non_open_pr_next_action(pr_state)
      mergeability_gate(pr_state) == "blocked" -> "repair_mergeability"
      mergeability_ready?(pr_state) != true -> "poll_on_next_cycle"
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

  defp non_open_pr_next_action(pr_state) do
    case passive_pr_gate(pr_state) do
      "merged" -> "reconcile_merged_pr"
      "closed" -> "reconcile_closed_pr"
      "draft" -> "resolve_pr_draft_state"
      _ -> "poll_on_next_cycle"
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
      merge_state_status in ["DIRTY", "BLOCKED", "DRAFT"] -> "blocked"
      mergeable == "MERGEABLE" -> "pass"
      merge_state_status in ["CLEAN", "UNSTABLE", "HAS_HOOKS"] -> "pass"
      true -> "unknown"
    end
  end

  defp mergeability_ready?(pr_state), do: mergeability_gate(pr_state) == "pass"

  defp ready_to_merge_promotion_allowed?(settings), do: settings.rollout.mode in ["mutate", "merge"]

  defp checks_ready?(pr_state, settings) do
    settings.merge.require_green_checks != true or checks_gate(pr_state) == "pass"
  end

  defp review_ready?(_review_status, settings) when settings.review.enabled != true, do: true
  defp review_ready?(review_status, _settings), do: review_status in ["current", "persisted"]

  defp normalize_token(value) when is_binary(value), do: String.upcase(String.trim(value))
  defp normalize_token(_value), do: nil

  defp maybe_put_review_update(updates, nil), do: updates
  defp maybe_put_review_update(updates, review), do: Map.put(updates, :review, review)

  defp maybe_put_merge_update(updates, nil), do: updates
  defp maybe_put_merge_update(updates, merge), do: Map.put(updates, :merge, merge)

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
