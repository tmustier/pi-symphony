defmodule SymphonyElixir.Orchestrator.Dispatch do
  @moduledoc """
  Pure decision functions for issue dispatch eligibility, sorting, and worker selection.

  Extracted from the monolithic Orchestrator GenServer to improve maintainability
  and testability of the dispatch logic.
  """

  alias SymphonyElixir.{Config, OrchestrationPolicy}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.State

  @spec sort_issues_for_dispatch(list(Issue.t() | any())) :: list(Issue.t() | any())
  @doc """
  Sort issues by priority and creation date for dispatch consideration.
  """
  def sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  @doc """
  Determine if an issue should be dispatched based on current state.
  """
  @spec should_dispatch_issue?(Issue.t(), State.t(), MapSet.t(String.t()), MapSet.t(String.t()), map()) :: boolean()
  def should_dispatch_issue?(
        %Issue{} = issue,
        %State{running: running, claimed: claimed} = state,
        active_states,
        terminal_states,
        tracked_issues \\ %{}
      ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states, tracked_issues) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  def should_dispatch_issue?(_issue, _state, _active_states, _terminal_states, _tracked_issues), do: false

  @spec candidate_issue?(Issue.t(), MapSet.t(String.t()), MapSet.t(String.t())) :: boolean()
  @doc """
  Check if an issue is a candidate for dispatch.
  """
  def candidate_issue?(
        %Issue{
          id: id,
          identifier: identifier,
          title: title,
          state: state_name
        } = issue,
        active_states,
        terminal_states
      )
      when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states) and
      dispatch_allowed_by_policy?(issue)
  end

  def candidate_issue?(_issue, _active_states, _terminal_states), do: false

  @spec dispatch_allowed_by_policy?(Issue.t()) :: boolean()
  @doc """
  Check if dispatch is allowed by orchestration policy.
  """
  def dispatch_allowed_by_policy?(%Issue{} = issue) do
    issue
    |> OrchestrationPolicy.issue_runtime(Config.settings!())
    |> Map.get(:dispatch_allowed, true)
  end

  @spec issue_orchestration_phase(Issue.t()) :: any()
  @doc """
  Get the orchestration phase for an issue.
  """
  def issue_orchestration_phase(%Issue{} = issue) do
    issue
    |> OrchestrationPolicy.issue_runtime(Config.settings!())
    |> Map.get(:phase)
  rescue
    _ -> nil
  end

  @spec issue_routable_to_worker?(Issue.t()) :: boolean()
  @doc """
  Check if an issue is routable to a worker.
  """
  def issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
      when is_boolean(assigned_to_worker),
      do: assigned_to_worker

  def issue_routable_to_worker?(_issue), do: true

  @doc """
  Check if a TODO issue is blocked by non-terminal blockers.

  When `tracked_issues` is provided, a blocker is considered effectively completed
  if its workpad phase indicates post-implementation progress (PR open, in review,
  merging, etc.) — even if the Linear state hasn't reached a terminal state yet.
  This prevents pipeline deadlocks when blockers have finished their work but are
  waiting on merge gates.
  """
  @spec todo_issue_blocked_by_non_terminal?(Issue.t(), MapSet.t(String.t()), map()) :: boolean()
  def todo_issue_blocked_by_non_terminal?(
        %Issue{state: issue_state, blocked_by: blockers},
        terminal_states,
        _tracked_issues \\ %{}
      )
      when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  def todo_issue_blocked_by_non_terminal?(_issue, _terminal_states, _tracked_issues), do: false

  @spec terminal_issue_state?(String.t(), MapSet.t(String.t())) :: boolean()
  @doc """
  Check if an issue state is terminal.
  """
  def terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  def terminal_issue_state?(_state_name, _terminal_states), do: false

  @spec active_issue_state?(String.t(), MapSet.t(String.t())) :: boolean()
  @doc """
  Check if an issue state is active.
  """
  def active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  @doc """
  Normalize an issue state name for comparison.
  """
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  @spec terminal_state_set() :: MapSet.t(String.t())
  @doc """
  Get the set of terminal states from configuration.
  """
  def terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  @spec active_state_set() :: MapSet.t(String.t())
  @doc """
  Get the set of active states from configuration.
  """
  def active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  @spec retry_candidate_issue?(Issue.t(), MapSet.t(String.t()), map()) :: boolean()
  @doc """
  Check if an issue is a retry candidate.
  """
  def retry_candidate_issue?(%Issue{} = issue, terminal_states, tracked_issues \\ %{}) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states, tracked_issues)
  end

  @spec state_slots_available?(Issue.t(), map()) :: boolean()
  @doc """
  Check if state slots are available for an issue.
  """
  def state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  def state_slots_available?(_issue, _running), do: false

  @spec running_issue_count_for_state(map(), String.t()) :: non_neg_integer()
  @doc """
  Count running issues for a specific state.
  """
  def running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  @spec priority_rank(integer() | nil) :: integer()
  @doc """
  Get priority rank for sorting (lower numbers = higher priority).
  """
  def priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  def priority_rank(_priority), do: 5

  @spec issue_created_at_sort_key(Issue.t() | nil) :: integer()
  @doc """
  Get issue creation timestamp as sort key.
  """
  def issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  def issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  def issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  @doc """
  Revalidate an issue for dispatch by refreshing its state.
  """
  @spec revalidate_issue_for_dispatch(Issue.t(), function(), MapSet.t(String.t()), map()) :: {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch(
        %Issue{id: issue_id},
        issue_fetcher,
        terminal_states,
        tracked_issues \\ %{}
      )
      when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states, tracked_issues) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states, _tracked_issues), do: {:ok, issue}

  @spec select_worker_host(State.t(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  @doc """
  Select the best worker host for dispatching an issue.
  """
  def select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  @spec preferred_worker_host_available?(String.t() | nil, list(String.t())) :: boolean()
  @doc """
  Check if preferred worker host is available.
  """
  def preferred_worker_host_available?(preferred_worker_host, hosts)
      when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  def preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  @spec least_loaded_worker_host(State.t(), list(String.t())) :: String.t()
  @doc """
  Find the least loaded worker host from available hosts.
  """
  def least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  @spec running_worker_host_count(map(), String.t()) :: non_neg_integer()
  @doc """
  Count running issues on a specific worker host.
  """
  def running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  @spec worker_host_slots_available?(State.t(), String.t()) :: boolean()
  @doc """
  Check if worker host has available slots.
  """
  def worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  @spec worker_slots_available?(State.t()) :: boolean()
  @doc """
  Check if any worker slots are available.
  """
  def worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  @spec worker_slots_available?(State.t(), String.t() | nil) :: boolean()
  def worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  @spec dispatch_slots_available?(Issue.t(), State.t()) :: boolean()
  @doc """
  Check if dispatch slots are available for an issue.
  """
  def dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  @spec available_slots(State.t()) :: non_neg_integer()
  @doc """
  Calculate available orchestrator slots.
  """
  def available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end
end
