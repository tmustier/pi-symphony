defmodule SymphonyElixir.OrchestrationLifecycle do
  @moduledoc """
  Reconciles durable workpad metadata and branch pull-request state.
  """

  require Logger

  alias SymphonyElixir.{Config, OrchestrationPolicy, PullRequests, Tracker, Workpad, WorkspaceGit}
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

    if manage_workpad?(runtime) do
      Workpad.sync(
        issue,
        %{
          owned: managed_owned?(runtime),
          phase: runtime.phase,
          branch: issue.branch_name,
          waiting_reason: runtime.waiting_reason,
          next_intended_action: runtime.next_intended_action,
          observation_gates: bootstrap_gates(runtime)
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

        updates =
          lifecycle_updates(
            issue,
            runtime,
            git_state,
            pr_result,
            settings,
            running_entry
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

  defp lifecycle_updates(issue, runtime, git_state, pr_result, settings, _running_entry) do
    branch = pick_string([Map.get(git_state, :branch), issue.branch_name])
    head_sha = pick_string([Map.get(git_state, :head_sha)])
    pr_metadata = pr_metadata(pr_result, head_sha)

    base_updates = %{
      owned: managed_owned?(runtime),
      branch: branch,
      pr: pr_metadata,
      observation_gates: observation_gates(runtime, pr_result),
      next_intended_action: next_action(runtime, pr_result),
      waiting_reason: waiting_reason(runtime, pr_result),
      phase: phase_after_reconcile(runtime, pr_result)
    }

    case pr_result do
      {:error, _reason} when settings.pr.auto_create == true and settings.rollout.mode in ["mutate", "merge"] ->
        Map.merge(base_updates, %{phase: "blocked", waiting_reason: "tool_unavailable", next_intended_action: "restore_pr_tooling"})

      _ ->
        base_updates
    end
  end

  defp phase_after_reconcile(_runtime, {:ok, _pr_info}), do: "waiting_for_checks"

  defp phase_after_reconcile(_runtime, {:skip, %{reason: :closed_pr_policy_stop}}), do: "blocked"
  defp phase_after_reconcile(_runtime, {:skip, %{reason: :merged_pr_cannot_reopen}}), do: "blocked"
  defp phase_after_reconcile(runtime, _pr_result), do: runtime.phase

  defp waiting_reason(_runtime, {:ok, _pr_info}), do: "checks_pending"
  defp waiting_reason(_runtime, {:skip, %{reason: :closed_pr_policy_stop}}), do: "missing_context"
  defp waiting_reason(_runtime, {:skip, %{reason: :merged_pr_cannot_reopen}}), do: "missing_context"
  defp waiting_reason(runtime, _pr_result), do: runtime.waiting_reason

  defp next_action(_runtime, {:ok, _pr_info}), do: "poll_on_next_cycle"
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

  defp observation_gates(runtime, {:ok, _pr_info}) do
    Map.merge(bootstrap_gates(runtime), %{"pr" => "open"})
  end

  defp observation_gates(runtime, {:skip, %{reason: :observe_only}}) do
    Map.merge(bootstrap_gates(runtime), %{"pr" => "observe_only"})
  end

  defp observation_gates(runtime, {:skip, %{reason: :auto_create_disabled}}) do
    Map.merge(bootstrap_gates(runtime), %{"pr" => "policy_disabled"})
  end

  defp observation_gates(runtime, {:skip, %{reason: :closed_pr_policy_stop}}) do
    Map.merge(bootstrap_gates(runtime), %{"pr" => "blocked"})
  end

  defp observation_gates(runtime, {:skip, %{reason: :merged_pr_cannot_reopen}}) do
    Map.merge(bootstrap_gates(runtime), %{"pr" => "blocked"})
  end

  defp observation_gates(runtime, {:skip, _details}) do
    Map.merge(bootstrap_gates(runtime), %{"pr" => "pending"})
  end

  defp observation_gates(runtime, {:error, _reason}) do
    Map.merge(bootstrap_gates(runtime), %{"pr" => "tool_unavailable"})
  end

  defp bootstrap_gates(runtime) do
    %{
      "ownership" => if(managed_owned?(runtime), do: "pass", else: "fail"),
      "kill_switch" => if(fetch_value(runtime.kill_switch, :active) == true, do: "active", else: "pass"),
      "dispatch" => if(runtime.dispatch_allowed, do: "pass", else: "blocked")
    }
  end

  defp manage_workpad?(runtime) do
    case fetch_value(runtime.ownership, :required_label) do
      value when is_binary(value) -> fetch_value(runtime.ownership, :label_present) == true
      _ -> true
    end
  end

  defp managed_owned?(runtime) do
    case fetch_value(runtime.ownership, :required_label) do
      value when is_binary(value) -> fetch_value(runtime.ownership, :label_present) == true
      _ -> true
    end
  end

  defp fetch_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch_value(_map, _key), do: nil

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
