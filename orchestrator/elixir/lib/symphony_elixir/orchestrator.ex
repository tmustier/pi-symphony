defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{
    AgentRunner,
    Config,
    OrchestrationLifecycle,
    OrchestrationPolicy,
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
      worker_rate_limits: nil
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

        state =
          case reason do
            :normal ->
              Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; evaluating continuation policy")

              state
              |> complete_issue(issue_id)
              |> reconcile_completed_issue_lifecycle(issue_id, running_entry)
              |> maybe_schedule_continuation_retry(issue_id, running_entry)

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = Retry.next_retry_attempt_from_running(running_entry)

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
          end

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
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    Dispatch.should_dispatch_issue?(issue, state, Dispatch.active_state_set(), Dispatch.terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    Dispatch.revalidate_issue_for_dispatch(issue, issue_fetcher, Dispatch.terminal_state_set())
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

        terminate_running_issue(state, issue.id, true)

      !Dispatch.issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      Dispatch.active_issue_state?(issue.state, active_states) and not Dispatch.dispatch_allowed_by_policy?(issue) ->
        Logger.info("Issue failed orchestration policy gates: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      Dispatch.active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
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
        terminate_running_issue(state_acc, issue_id, false)
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

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

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
      |> terminate_running_issue(issue_id, false)
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
      if Dispatch.should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end



  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case Dispatch.revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, Dispatch.terminal_state_set()) do
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
        if Dispatch.retry_candidate_issue?(refreshed_issue, Dispatch.terminal_state_set()) and
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

      Dispatch.retry_candidate_issue?(issue, terminal_states) ->
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
    if Dispatch.retry_candidate_issue?(issue, Dispatch.terminal_state_set()) and
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

    {:reply,
     %{
       running: running,
       retrying: retrying,
       tracked: tracked,
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

    %{state | tracked: tracked}
  end

  defp update_tracked_issues(state, _issues), do: state

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
