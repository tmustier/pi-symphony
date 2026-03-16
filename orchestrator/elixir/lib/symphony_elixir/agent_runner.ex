defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with the configured worker runtime.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, OrchestrationPolicy, PromptBuilder, ReviewArtifact, Tracker, Workspace}
  alias SymphonyElixir.Pi.{Proof, WorkerRunner}
  alias SymphonyElixir.WorkspaceGit

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, worker_update_recipient \\ nil, opts \\ []) do
    worker_hosts =
      candidate_worker_hosts(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_hosts=#{inspect(worker_hosts_for_log(worker_hosts))}")

    case run_on_worker_hosts(issue, worker_update_recipient, opts, worker_hosts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_hosts(issue, worker_update_recipient, opts, [worker_host | rest]) do
    case run_on_worker_host(issue, worker_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} when rest != [] ->
        Logger.warning("Agent run failed for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}; trying next worker host")
        run_on_worker_hosts(issue, worker_update_recipient, opts, rest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_on_worker_hosts(_issue, _worker_update_recipient, _opts, []), do: {:error, :no_worker_hosts_available}

  defp run_on_worker_host(issue, worker_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(worker_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_worker_turns(workspace, issue, worker_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp worker_message_handler(recipient, issue) do
    fn message ->
      send_worker_update(recipient, issue, message)
    end
  end

  defp send_worker_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:worker_update, issue_id, message})
    :ok
  end

  defp send_worker_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, runtime_info)
       when is_binary(issue_id) and is_pid(recipient) and is_map(runtime_info) do
    send(recipient, {:worker_runtime_info, issue_id, runtime_info})
    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _runtime_info), do: :ok

  defp send_worker_runtime_info(recipient, issue, worker_host, workspace)
       when is_binary(workspace) do
    send_worker_runtime_info(recipient, issue, %{
      worker_host: worker_host,
      workspace_path: workspace
    })
  end

  defp send_worker_session_runtime_info(recipient, issue, session) when is_map(session) do
    proof_paths = Proof.artifact_paths(Map.get(session, :workspace), Map.get(session, :session_file))

    send_worker_runtime_info(recipient, issue, %{
      session_file: Map.get(session, :session_file),
      session_dir: Map.get(session, :session_dir),
      proof_dir: proof_paths.proof_dir,
      proof_events_path: proof_paths.proof_events_path,
      proof_summary_path: proof_paths.proof_summary_path
    })
  end

  defp send_worker_session_runtime_info(_recipient, _issue, _session), do: :ok

  defp run_worker_turns(workspace, issue, worker_update_recipient, opts, worker_host) do
    execution_context = %{
      workspace: workspace,
      worker_host: worker_host,
      worker_update_recipient: worker_update_recipient,
      opts: opts,
      issue_state_fetcher: Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1),
      max_turns: Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    }

    runtime_module = worker_runtime_module()

    with {:ok, session} <- runtime_module.start_session(workspace, worker_host: worker_host) do
      if runtime_module == WorkerRunner do
        send_worker_session_runtime_info(worker_update_recipient, issue, session)
      end

      try do
        do_run_worker_turns(runtime_module, session, issue, execution_context, 1)
      after
        runtime_module.stop_session(session)
      end
    end
  end

  defp do_run_worker_turns(runtime_module, session, issue, execution_context, turn_number) do
    max_turns = execution_context.max_turns
    workspace = execution_context.workspace
    prompt = build_turn_prompt(issue, execution_context.opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           runtime_module.run_turn(
             session,
             prompt,
             issue,
             on_message: worker_message_handler(execution_context.worker_update_recipient, issue),
             turn_number: turn_number
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      maybe_continue_after_turn(runtime_module, session, issue, execution_context, turn_number)
    end
  end

  defp maybe_continue_after_turn(runtime_module, session, issue, execution_context, turn_number) do
    max_turns = execution_context.max_turns

    case continue_with_issue?(issue, execution_context.issue_state_fetcher) do
      {:continue, refreshed_issue} when turn_number < max_turns ->
        if workspace_work_completed?(execution_context.workspace, execution_context.worker_host) do
          Logger.info("Worker completed implementation (branch pushed to remote); stopping agent turns for #{issue_context(refreshed_issue)} turn=#{turn_number}/#{max_turns}")

          :ok
        else
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_worker_turns(
            runtime_module,
            session,
            refreshed_issue,
            execution_context,
            turn_number + 1
          )
        end

      {:continue, refreshed_issue} ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp workspace_work_completed?(workspace, worker_host) do
    case WorkspaceGit.inspect_workspace(workspace, worker_host) do
      {:ok, %{remote_branch_published: true}} ->
        review_enabled = Config.settings!().review.enabled == true
        not review_enabled or ReviewArtifact.exists?(workspace)

      _ ->
        false
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous worker turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this session, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and
             OrchestrationPolicy.continuation_allowed?(refreshed_issue, Config.settings!()) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp candidate_worker_hosts(nil, []), do: [nil]

  defp candidate_worker_hosts(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" ->
        [host | Enum.reject(hosts, &(&1 == host))]

      _ when hosts == [] ->
        [nil]

      _ ->
        hosts
    end
  end

  defp worker_hosts_for_log(worker_hosts) do
    Enum.map(worker_hosts, &worker_host_for_log/1)
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp worker_runtime_module do
    case Config.worker_runtime() do
      :pi -> WorkerRunner
      :codex -> AppServer
    end
  end
end
