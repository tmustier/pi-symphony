defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{
    AgentRunner,
    Config,
    MergeQueue,
    OrchestrationLifecycle,
    OrchestrationPolicy,
    PiAnalytics,
    PullRequests,
    StatusDashboard,
    Tracker,
    Workspace
  }

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.{Dispatch, Metrics, Retry}

  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_worker_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    @type t :: %__MODULE__{}

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      running: %{},
      tracked: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      worker_totals: nil,
      worker_rate_limits: nil,
      merge_queue: %{},
      merge_in_progress: nil,
      merge_current_entry: nil,
      merge_task_ref: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    log_startup_config(config)

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      worker_totals: @empty_worker_totals,
      worker_rate_limits: nil
    }

    run_terminal_workspace_cleanup()
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({merge_ref, result}, %{merge_task_ref: merge_ref, merge_in_progress: issue_id} = state)
      when is_reference(merge_ref) do
    Process.demonitor(merge_ref, [:flush])
    state = complete_merge_task(state, issue_id, result)
    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{merge_task_ref: ref} = state) do
    state = handle_merge_task_down(state, reason)
    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        {state, analytics_status, analytics_note} =
          case reason do
            :normal ->
              Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; evaluating continuation policy")

              updated_state =
                state
                |> complete_issue(issue_id)
                |> reconcile_completed_issue_lifecycle(issue_id, running_entry)
                |> maybe_schedule_continuation_retry(issue_id, running_entry)

              if retry_scheduled?(updated_state, issue_id) do
                {updated_state, "waiting", "continuation_retry_scheduled"}
              else
                {updated_state, "success", "agent_task_completed"}
              end

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = Retry.next_retry_attempt_from_running(running_entry)

              updated_state =
                Retry.schedule_issue_retry(
                  state,
                  issue_id,
                  next_attempt,
                  Map.merge(
                    %{
                      identifier: running_entry.identifier,
                      error: "agent exited: #{inspect(reason)}",
                      worker_host: Map.get(running_entry, :worker_host),
                      workspace_path: Map.get(running_entry, :workspace_path)
                    },
                    Retry.retry_runtime_metadata(running_entry)
                  )
                )

              {updated_state, "error", "agent_task_exited"}
          end

        emit_symphony_run_analytics(running_entry, analytics_status, analytics_note, %{
          retry_scheduled: retry_scheduled?(state, issue_id),
          process_exit_reason: inspect(reason)
        })

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])
          |> maybe_put_runtime_value(:session_file, runtime_info[:session_file])
          |> maybe_put_runtime_value(:session_dir, runtime_info[:session_dir])
          |> maybe_put_runtime_value(:proof_dir, runtime_info[:proof_dir])
          |> maybe_put_runtime_value(:proof_events_path, runtime_info[:proof_events_path])
          |> maybe_put_runtime_value(:proof_summary_path, runtime_info[:proof_summary_path])
          |> reset_stall_baseline()

        log_worker_runtime_info(running_entry.identifier, issue_id, runtime_info)
        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = Metrics.integrate_worker_update(running_entry, update)

        state =
          state
          |> apply_worker_token_delta(token_delta)
          |> apply_worker_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case Retry.pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues() do
      issues = reconcile_candidate_issue_lifecycles(issues, state)
      state = update_tracked_issues(state, issues)
      state = sync_merge_queue(state, issues)
      state = maybe_start_merge_task(state)

      if Dispatch.available_slots(state) > 0 do
        choose_issues(issues, state)
      else
        state
      end
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_scope} ->
        Logger.error("Linear scope missing in WORKFLOW.md; set tracker.project_slug or tracker.team_key")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state
    end
  end

  defp merge_queue_enabled? do
    settings = Config.settings!()
    settings.merge.mode == "auto" and settings.merge.strategy == "queue"
  end

  defp sync_merge_queue(%State{} = state, issues) when is_list(issues) do
    if merge_queue_enabled?() do
      sync_enabled_merge_queue(state, issues)
    else
      %{state | merge_queue: %{}}
    end
  end

  defp sync_merge_queue(%State{} = state, _issues), do: state

  defp sync_enabled_merge_queue(%State{} = state, issues) do
    candidate_entries = merge_queue_candidates(issues, state)
    candidate_ids = candidate_entries |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    queue =
      state.merge_queue
      |> retain_candidate_queue_entries(candidate_ids)
      |> merge_candidate_queue_entries(candidate_entries, state.merge_queue)

    %{state | merge_queue: queue}
  end

  defp merge_queue_candidates(issues, %State{} = state) when is_list(issues) do
    Enum.flat_map(issues, &merge_queue_candidate(&1, state))
  end

  defp merge_queue_candidate(%Issue{id: issue_id}, %State{merge_in_progress: issue_id}), do: []

  defp merge_queue_candidate(%Issue{} = issue, %State{tracked: tracked}) do
    case merge_queue_entry(issue, tracked) do
      {:ok, entry} -> [{issue.id, entry}]
      _ -> []
    end
  end

  defp merge_queue_candidate(_issue, _state), do: []

  defp retain_candidate_queue_entries(queue, candidate_ids) when is_map(queue) do
    Enum.reduce(queue, %{}, fn {issue_id, entry}, acc ->
      if MapSet.member?(candidate_ids, issue_id) do
        Map.put(acc, issue_id, entry)
      else
        acc
      end
    end)
  end

  defp merge_candidate_queue_entries(queue, candidate_entries, existing_queue)
       when is_map(queue) and is_list(candidate_entries) and is_map(existing_queue) do
    Enum.reduce(candidate_entries, queue, fn {issue_id, entry}, acc ->
      MergeQueue.add(acc, issue_id, entry.pr_context, entry.priority,
        issue_identifier: entry.issue_identifier,
        enqueued_at_ms: Map.get(Map.get(existing_queue, issue_id, %{}), :enqueued_at_ms)
      )
    end)
  end

  defp merge_queue_entry(%Issue{id: issue_id} = issue, tracked)
       when is_binary(issue_id) and is_map(tracked) do
    with %{} = tracked_entry <- Map.get(tracked, issue_id),
         phase when phase in ["ready_to_merge", "merging"] <- Map.get(tracked_entry, :phase),
         %{} = pr_context <- tracked_pr_context(tracked_entry) do
      {:ok,
       %{
         issue_identifier: issue.identifier,
         priority: Dispatch.priority_rank(issue.priority),
         pr_context: pr_context
       }}
    else
      _ -> :skip
    end
  end

  defp merge_queue_entry(_issue, _tracked), do: :skip

  defp tracked_pr_context(tracked_entry) when is_map(tracked_entry) do
    pr_metadata = get_in(tracked_entry, [:workpad, :metadata, "pr"]) || %{}
    pr_number = Map.get(pr_metadata, "number")
    pr_url = Map.get(pr_metadata, "url")
    head_sha = Map.get(pr_metadata, "head_sha")
    repo_slug = first_present_string([Config.settings!().pr.repo_slug, repo_slug_from_pr_url(pr_url)])

    if is_integer(pr_number) or is_binary(pr_url) do
      %{
        number: pr_number,
        url: pr_url,
        repo_slug: repo_slug,
        expected_head_sha: head_sha
      }
    end
  end

  defp maybe_start_merge_task(%State{merge_in_progress: issue_id} = state) when is_binary(issue_id),
    do: state

  defp maybe_start_merge_task(%State{merge_task_ref: merge_task_ref} = state)
       when is_reference(merge_task_ref),
       do: state

  defp maybe_start_merge_task(%State{} = state) do
    if merge_queue_enabled?() do
      start_next_merge_task(state)
    else
      state
    end
  end

  defp start_next_merge_task(%State{} = state) do
    case MergeQueue.take_next(state.merge_queue) do
      {%{issue_id: issue_id} = entry, next_queue} ->
        launch_merge_task(state, issue_id, entry, next_queue)

      :empty ->
        state
    end
  end

  defp launch_merge_task(%State{} = state, issue_id, entry, next_queue) when is_binary(issue_id) do
    rebase_targets = build_rebase_targets(next_queue, state)

    task =
      Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
        process_merge_task(issue_id, rebase_targets)
      end)

    Logger.info("Queued merge task started for issue_id=#{issue_id} issue_identifier=#{entry.issue_identifier || issue_id}")

    %{
      state
      | merge_queue: next_queue,
        merge_in_progress: issue_id,
        merge_current_entry: entry,
        merge_task_ref: task.ref
    }
  end

  defp build_rebase_targets(merge_queue, %State{} = state) when is_map(merge_queue) do
    running_ids = Map.keys(state.running) |> MapSet.new()

    merge_queue
    |> MergeQueue.ordered_entries()
    |> Enum.reject(&MapSet.member?(running_ids, &1.issue_id))
    |> Enum.map(fn entry ->
      %{
        issue_id: entry.issue_id,
        issue_identifier: entry.issue_identifier,
        pr_context: entry.pr_context
      }
    end)
    |> Enum.filter(&is_map(&1.pr_context))
  end

  defp first_present_string(values) when is_list(values) do
    Enum.find(values, fn value ->
      is_binary(value) and String.trim(value) != ""
    end)
  end

  defp repo_slug_from_pr_url(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{host: host, path: path} when host in ["github.com", "www.github.com"] and is_binary(path) ->
        case String.split(String.trim_leading(path, "/"), "/", trim: true) do
          [owner, repo, "pull", _pr_number | _rest] -> "#{owner}/#{repo}"
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp repo_slug_from_pr_url(_url), do: nil

  defp process_merge_task(issue_id, rebase_targets) when is_binary(issue_id) and is_list(rebase_targets) do
    merge_result = OrchestrationLifecycle.reconcile_after_run(issue_id, %{}, queue_merge: true)

    case merge_result do
      {:ok, %Issue{} = issue} ->
        merge_completed? = merge_successful_issue?(issue)

        %{
          updated_issue: issue,
          merge_completed?: merge_completed?,
          rebased_issues: if(merge_completed?, do: auto_rebase_targets(rebase_targets), else: [])
        }

      {:ok, :missing} ->
        %{updated_issue: :missing, merge_completed?: false, rebased_issues: []}

      {:error, reason} ->
        %{error: reason, rebased_issues: []}
    end
  end

  defp merge_successful_issue?(%Issue{} = issue) do
    runtime = OrchestrationPolicy.issue_runtime(issue, Config.settings!())

    runtime
    |> get_in([:workpad, :metadata, "merge", "last_merged_head_sha"])
    |> is_binary()
  end

  defp auto_rebase_targets(targets) when is_list(targets) do
    max_attempts = Config.settings!().merge.max_rebase_attempts

    Enum.map(targets, fn target ->
      result = rebase_target(target, max_attempts)
      refreshed_issue = refresh_issue_after_rebase(target.issue_id)
      %{target: target, result: result, refreshed_issue: refreshed_issue}
    end)
  end

  defp rebase_target(%{pr_context: pr_context}, attempts_left)
       when is_map(pr_context) and is_integer(attempts_left) and attempts_left > 0 do
    case PullRequests.rebase_pr(pr_context) do
      {:error, _reason} when attempts_left > 1 ->
        Process.sleep(1_000)
        rebase_target(%{pr_context: pr_context}, attempts_left - 1)

      result ->
        Process.sleep(1_000)
        result
    end
  end

  defp rebase_target(_target, _attempts_left), do: {:skip, %{reason: :missing_pr_number}}

  defp refresh_issue_after_rebase(issue_id) when is_binary(issue_id) do
    with {:ok, [%Issue{} = issue | _]} <- Tracker.fetch_issue_states_by_ids([issue_id]),
         {:ok, %Issue{} = updated_issue} <- OrchestrationLifecycle.bootstrap_issue(issue) do
      updated_issue
    else
      _ -> nil
    end
  end

  defp refresh_issue_after_rebase(_issue_id), do: nil

  defp complete_merge_task(%State{} = state, _issue_id, %{updated_issue: updated_issue, rebased_issues: rebased_issues} = result) do
    state = update_merge_task_issue(state, updated_issue)
    state = Enum.reduce(rebased_issues, state, &maybe_update_rebased_issue(&2, &1))

    if Map.get(result, :merge_completed?) do
      state
      |> clear_merge_task_state()
      |> maybe_start_merge_task()
    else
      requeue_current_merge_entry(state)
    end
  end

  defp complete_merge_task(%State{} = state, issue_id, %{error: reason}) do
    Logger.warning("Merge task failed for issue_id=#{issue_id}: #{inspect(reason)}")
    requeue_current_merge_entry(state)
  end

  defp update_merge_task_issue(state, %Issue{} = issue), do: update_tracked_issue(state, issue)
  defp update_merge_task_issue(state, _updated_issue), do: state

  defp maybe_update_rebased_issue(state, %{refreshed_issue: %Issue{} = issue}), do: update_tracked_issue(state, issue)
  defp maybe_update_rebased_issue(state, _entry), do: state

  defp clear_merge_task_state(%State{} = state) do
    %{state | merge_in_progress: nil, merge_current_entry: nil, merge_task_ref: nil}
  end

  defp requeue_current_merge_entry(%State{merge_current_entry: %{issue_id: issue_id} = entry} = state)
       when is_binary(issue_id) do
    queue =
      MergeQueue.add(state.merge_queue, issue_id, entry.pr_context, entry.priority,
        issue_identifier: entry.issue_identifier,
        enqueued_at_ms: entry.enqueued_at_ms
      )

    %{state | merge_queue: queue, merge_in_progress: nil, merge_current_entry: nil, merge_task_ref: nil}
  end

  defp requeue_current_merge_entry(%State{} = state), do: clear_merge_task_state(state)

  defp handle_merge_task_down(%State{} = state, :normal), do: clear_merge_task_state(state)

  defp handle_merge_task_down(%State{} = state, reason) do
    issue_id = state.merge_in_progress || "unknown"
    Logger.warning("Merge task crashed for issue_id=#{issue_id}: #{inspect(reason)}")
    requeue_current_merge_entry(state)
  end

  defp reconcile_candidate_issue_lifecycles(issues, %State{} = state) when is_list(issues) do
    running_issue_ids = Map.keys(state.running) |> MapSet.new()

    Enum.map(issues, &reconcile_candidate_issue_lifecycle(&1, running_issue_ids))
  end

  defp reconcile_candidate_issue_lifecycles(issues, _state) when is_list(issues), do: issues

  defp reconcile_candidate_issue_lifecycle(%Issue{id: issue_id} = issue, running_issue_ids)
       when is_binary(issue_id) and is_struct(running_issue_ids, MapSet) do
    if MapSet.member?(running_issue_ids, issue_id) do
      issue
    else
      case OrchestrationLifecycle.bootstrap_issue(issue) do
        {:ok, %Issue{} = updated_issue} ->
          updated_issue

        {:error, reason} ->
          Logger.debug("Failed to bootstrap workpad lifecycle for #{issue_context(issue)}: #{inspect(reason)}")

          issue
      end
    end
  end

  defp reconcile_candidate_issue_lifecycle(issue, _running_issue_ids), do: issue

  defp reconcile_completed_issue_lifecycle(%State{} = state, issue_id, running_entry)
       when is_binary(issue_id) and is_map(running_entry) do
    case OrchestrationLifecycle.reconcile_after_run(issue_id, running_entry) do
      {:ok, %Issue{} = updated_issue} ->
        state
        |> update_tracked_issue(updated_issue)

      {:ok, :missing} ->
        state

      {:error, reason} ->
        Logger.warning("Failed to reconcile completed issue lifecycle issue_id=#{issue_id}: #{inspect(reason)}")
        state
    end
  end

  defp reconcile_completed_issue_lifecycle(%State{} = state, _issue_id, _running_entry), do: state

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            Dispatch.active_state_set(),
            Dispatch.terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, Dispatch.active_state_set(), Dispatch.terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, Dispatch.active_state_set(), Dispatch.terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term(), map()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state, tracked_issues \\ %{}) do
    Dispatch.should_dispatch_issue?(
      issue,
      state,
      Dispatch.active_state_set(),
      Dispatch.terminal_state_set(),
      tracked_issues
    )
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term()), map()) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher, tracked_issues \\ %{})
      when is_function(issue_fetcher, 1) do
    Dispatch.revalidate_issue_for_dispatch(issue, issue_fetcher, Dispatch.terminal_state_set(), tracked_issues)
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    Dispatch.sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    Dispatch.select_worker_host(state, preferred_worker_host)
  end

  @doc false
  @spec reconcile_candidate_issue_lifecycles_for_test([Issue.t()], term()) :: [Issue.t()]
  def reconcile_candidate_issue_lifecycles_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_candidate_issue_lifecycles(issues, state)
  end

  def reconcile_candidate_issue_lifecycles_for_test(issues, _state) when is_list(issues) do
    issues
  end

  @doc false
  @spec tracked_pr_context_for_test(map()) :: map() | nil
  def tracked_pr_context_for_test(tracked_entry) when is_map(tracked_entry) do
    tracked_pr_context(tracked_entry)
  end

  @doc false
  @spec build_rebase_targets_for_test(map(), term()) :: [map()]
  def build_rebase_targets_for_test(merge_queue, %State{} = state) when is_map(merge_queue) do
    build_rebase_targets(merge_queue, state)
  end

  def build_rebase_targets_for_test(_merge_queue, _state), do: []

  @doc false
  @spec complete_merge_task_for_test(term(), String.t(), map()) :: term()
  def complete_merge_task_for_test(%State{} = state, issue_id, result)
      when is_binary(issue_id) and is_map(result) do
    complete_merge_task(state, issue_id, result)
  end

  @doc false
  @spec handle_merge_task_down_for_test(term(), term()) :: term()
  def handle_merge_task_down_for_test(%State{} = state, reason), do: handle_merge_task_down(state, reason)

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      Dispatch.terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true, :terminal_state, %{})

      !Dispatch.issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false, :worker_unassigned, %{})

      Dispatch.active_issue_state?(issue.state, active_states) and not Dispatch.dispatch_allowed_by_policy?(issue) ->
        Logger.info("Issue failed orchestration policy gates: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false, :policy_gate_failed, %{})

      Dispatch.active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false, :non_active_state, %{})
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false, :issue_no_longer_visible, %{})
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace, termination_reason, analytics_metrics) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        emit_symphony_run_analytics(
          running_entry,
          "cancelled",
          termination_note(termination_reason),
          Map.merge(
            %{
              cleanup_workspace: cleanup_workspace,
              termination_reason: termination_reason,
              process_exit_reason: "terminated_by_orchestrator"
            },
            analytics_metrics
          )
        )

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = Retry.next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false, :stall_timeout, %{retry_scheduled: true})
      |> Retry.schedule_issue_retry(
        issue_id,
        next_attempt,
        Map.merge(
          %{
            identifier: identifier,
            error: "stalled for #{elapsed_ms}ms without codex activity"
          },
          Retry.retry_runtime_metadata(running_entry)
        )
      )
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_worker_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp log_worker_runtime_info(identifier, issue_id, runtime_info) do
    session_file = runtime_info[:session_file]
    workspace_path = runtime_info[:workspace_path]
    worker_host = runtime_info[:worker_host]

    Logger.info(
      "Worker runtime ready for issue_id=#{issue_id} issue_identifier=#{identifier}" <>
        " worker_host=#{worker_host || "local"}" <>
        " workspace=#{workspace_path}" <>
        if(is_binary(session_file), do: " session_file=#{session_file}", else: "")
    )
  end

  defp reset_stall_baseline(running_entry) when is_map(running_entry) do
    Map.put(running_entry, :last_worker_timestamp, DateTime.utc_now())
  end

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    active_states = Dispatch.active_state_set()
    terminal_states = Dispatch.terminal_state_set()

    issues
    |> Dispatch.sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if Dispatch.should_dispatch_issue?(issue, state_acc, active_states, terminal_states, state_acc.tracked) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case Dispatch.revalidate_issue_for_dispatch(
           issue,
           &Tracker.fetch_issue_states_by_ids/1,
           Dispatch.terminal_state_set(),
           state.tracked
         ) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    recipient = self()

    case Dispatch.select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient, attempt: attempt, worker_host: worker_host)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            last_worker_message: nil,
            last_worker_timestamp: nil,
            last_worker_event: nil,
            worker_pid: nil,
            worker_input_tokens: 0,
            worker_output_tokens: 0,
            worker_total_tokens: 0,
            worker_last_reported_input_tokens: 0,
            worker_last_reported_output_tokens: 0,
            worker_last_reported_total_tokens: 0,
            turn_count: 0,
            orchestration_phase: Dispatch.issue_orchestration_phase(issue),
            retry_attempt: Retry.normalize_retry_attempt(attempt),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        Retry.schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp maybe_schedule_continuation_retry(%State{} = state, issue_id, running_entry)
       when is_binary(issue_id) and is_map(running_entry) do
    metadata =
      Map.merge(
        %{
          identifier: running_entry.identifier,
          delay_type: :continuation,
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path)
        },
        Retry.retry_runtime_metadata(running_entry)
      )

    case refresh_issue_for_continuation(issue_id) do
      {:ok, %Issue{} = refreshed_issue} ->
        if Dispatch.retry_candidate_issue?(refreshed_issue, Dispatch.terminal_state_set(), state.tracked) and
             immediate_continuation_allowed?(refreshed_issue) do
          Retry.schedule_issue_retry(state, issue_id, 1, metadata)
        else
          release_issue_claim(state, issue_id)
        end

      {:ok, :missing} ->
        release_issue_claim(state, issue_id)

      {:error, reason} ->
        Logger.debug("Failed to refresh issue for continuation retry issue_id=#{issue_id}: #{inspect(reason)}; preserving prior continuation behavior")
        Retry.schedule_issue_retry(state, issue_id, 1, metadata)
    end
  end

  defp maybe_schedule_continuation_retry(%State{} = state, _issue_id, _running_entry), do: state

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         Retry.schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = Dispatch.terminal_state_set()

    cond do
      Dispatch.terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      Dispatch.retry_candidate_issue?(issue, terminal_states, state.tracked) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp log_startup_config(config) do
    model_display =
      case config.pi.model do
        %{provider: provider, model_id: model_id}
        when is_binary(provider) and is_binary(model_id) ->
          thinking = config.pi.thinking_level
          base = "#{provider}/#{model_id}"
          if is_binary(thinking), do: "#{base} (thinking: #{thinking})", else: base

        _ ->
          "default"
      end

    Logger.info("Symphony starting with model: #{model_display}")
    Logger.info("Symphony rollout mode: #{config.rollout.mode}")
  end

  defp run_terminal_workspace_cleanup do
    if Config.settings!().rollout.mode == "observe" do
      Logger.info("Skipping terminal workspace cleanup in observe mode")
    else
      run_terminal_workspace_cleanup!()
    end
  end

  defp run_terminal_workspace_cleanup! do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if Dispatch.retry_candidate_issue?(issue, Dispatch.terminal_state_set(), state.tracked) and
         Dispatch.dispatch_slots_available?(issue, state) and
         Dispatch.worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host])}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       Retry.schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: Map.get(metadata, :session_id),
          session_file: Map.get(metadata, :session_file),
          session_dir: Map.get(metadata, :session_dir),
          proof_dir: Map.get(metadata, :proof_dir),
          proof_events_path: Map.get(metadata, :proof_events_path),
          proof_summary_path: Map.get(metadata, :proof_summary_path),
          worker_pid: Map.get(metadata, :worker_pid),
          worker_input_tokens: Map.get(metadata, :worker_input_tokens, 0),
          worker_output_tokens: Map.get(metadata, :worker_output_tokens, 0),
          worker_total_tokens: Map.get(metadata, :worker_total_tokens, 0),
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: Map.get(metadata, :started_at),
          last_worker_timestamp: Map.get(metadata, :last_worker_timestamp),
          last_worker_message: Map.get(metadata, :last_worker_message),
          last_worker_event: Map.get(metadata, :last_worker_event),
          runtime_seconds: Metrics.running_seconds(Map.get(metadata, :started_at), now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path),
          session_file: Map.get(retry, :session_file),
          session_dir: Map.get(retry, :session_dir),
          proof_dir: Map.get(retry, :proof_dir),
          proof_events_path: Map.get(retry, :proof_events_path),
          proof_summary_path: Map.get(retry, :proof_summary_path)
        }
      end)

    tracked =
      state.tracked
      |> Map.values()
      |> Enum.sort_by(&{&1.issue_identifier || "", &1.issue_id || ""})

    merge = merge_snapshot(state)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       tracked: tracked,
       merge: merge,
       worker_totals: state.worker_totals,
       rate_limits: Map.get(state, :worker_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp merge_snapshot(%State{} = state) do
    queued =
      state.merge_queue
      |> MergeQueue.ordered_entries()
      |> Enum.map(fn entry ->
        %{
          issue_id: entry.issue_id,
          issue_identifier: entry.issue_identifier,
          pr_number: get_in(entry, [:pr_context, :number]),
          priority: entry.priority,
          enqueued_at_ms: entry.enqueued_at_ms
        }
      end)

    %{
      in_progress_issue_id: state.merge_in_progress,
      in_progress_issue_identifier: merge_in_progress_identifier(state),
      queued: queued
    }
  end

  defp merge_in_progress_identifier(%State{merge_in_progress: nil}), do: nil

  defp merge_in_progress_identifier(%State{} = state) do
    case Map.get(state.tracked, state.merge_in_progress) do
      %{issue_identifier: identifier} -> identifier
      _ -> get_in(state, [:merge_current_entry, :issue_identifier])
    end
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = Metrics.running_seconds(running_entry.started_at, DateTime.utc_now())

    worker_totals =
      Metrics.apply_token_delta(
        state.worker_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | worker_totals: worker_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp emit_symphony_run_analytics(running_entry, status, note, metrics) when is_map(running_entry) do
    PiAnalytics.emit_symphony_run(running_entry,
      status: status,
      notes: note,
      metrics: metrics
    )
  end

  defp emit_symphony_run_analytics(_running_entry, _status, _note, _metrics), do: :ok

  defp retry_scheduled?(%State{} = state, issue_id) when is_binary(issue_id) do
    Map.has_key?(state.retry_attempts, issue_id)
  end

  defp retry_scheduled?(_state, _issue_id), do: false

  defp termination_note(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp termination_note(reason) when is_binary(reason), do: reason
  defp termination_note(reason), do: inspect(reason)

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp refresh_issue_for_continuation(issue_id) when is_binary(issue_id) do
    case Tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} -> {:ok, refreshed_issue}
      {:ok, []} -> {:ok, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp immediate_continuation_allowed?(%Issue{} = issue) do
    OrchestrationPolicy.continuation_allowed?(issue, Config.settings!())
  end

  defp update_tracked_issues(%State{} = state, issues) when is_list(issues) do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
    settings = Config.settings!()

    tracked =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} = issue when is_binary(issue_id) ->
          [
            issue
            |> OrchestrationPolicy.tracked_issue(settings)
            |> Map.put(:observed_at, observed_at)
          ]

        _ ->
          []
      end)
      |> Map.new(fn tracked_issue -> {tracked_issue.issue_id, tracked_issue} end)

    tracked = compute_blocks(tracked)

    %{state | tracked: tracked}
  end

  defp update_tracked_issues(state, _issues), do: state

  defp compute_blocks(tracked) when is_map(tracked) do
    # Invert blocked_by: if B says "blocked_by A", then A blocks B.
    blocks_map =
      tracked
      |> Enum.flat_map(fn {issue_id, entry} ->
        entry
        |> Map.get(:blocked_by, [])
        |> Enum.flat_map(fn
          %{id: blocker_id, identifier: _} when is_binary(blocker_id) ->
            [{blocker_id, %{id: issue_id, identifier: entry.issue_identifier}}]

          _ ->
            []
        end)
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Map.new(tracked, fn {issue_id, entry} ->
      {issue_id, Map.put(entry, :blocks, Map.get(blocks_map, issue_id, []))}
    end)
  end

  defp update_tracked_issue(%State{} = state, %Issue{id: issue_id} = issue) when is_binary(issue_id) do
    tracked_issue =
      issue
      |> OrchestrationPolicy.tracked_issue(Config.settings!())
      |> Map.put(:observed_at, DateTime.utc_now() |> DateTime.truncate(:second))

    %{state | tracked: Map.put(state.tracked, issue_id, tracked_issue)}
  end

  defp update_tracked_issue(state, _issue), do: state

  defp apply_worker_token_delta(
         %{worker_totals: worker_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | worker_totals: Metrics.apply_token_delta(worker_totals, token_delta)}
  end

  defp apply_worker_token_delta(state, _token_delta), do: state

  defp apply_worker_rate_limits(%State{} = state, update) when is_map(update) do
    case Metrics.extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | worker_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_worker_rate_limits(state, _update), do: state
end
