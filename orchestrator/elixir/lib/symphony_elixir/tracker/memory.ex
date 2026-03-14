defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Issue

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, issue_entries()}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    persist_issues(fn issues ->
      Enum.map(issues, fn
        %Issue{id: ^issue_id, comments: comments} = issue when is_list(comments) ->
          comment = %{id: generated_comment_id(), body: body, updated_at: now}
          %{issue | comments: comments ++ [comment], updated_at: now}

        %Issue{id: ^issue_id} = issue ->
          comment = %{id: generated_comment_id(), body: body, updated_at: now}
          %{issue | comments: [comment], updated_at: now}

        issue ->
          issue
      end)
    end)

    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  @spec update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(comment_id, body) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    persist_issues(fn issues ->
      Enum.map(issues, &update_issue_comment(&1, comment_id, body, now))
    end)

    send_event({:memory_tracker_comment_update, comment_id, body})
    :ok
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    persist_issues(fn issues ->
      Enum.map(issues, fn
        %Issue{id: ^issue_id} = issue -> %{issue | state: state_name, updated_at: now}
        issue -> issue
      end)
    end)

    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp persist_issues(fun) when is_function(fun, 1) do
    updated_issues = fun.(configured_issues())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, updated_issues)
    updated_issues
  end

  defp update_issue_comment(%Issue{comments: comments} = issue, comment_id, body, now)
       when is_list(comments) do
    updated_comments =
      Enum.map(comments, fn
        %{id: ^comment_id} = comment -> Map.merge(comment, %{body: body, updated_at: now})
        comment -> comment
      end)

    %{issue | comments: updated_comments, updated_at: now}
  end

  defp update_issue_comment(issue, _comment_id, _body, _now), do: issue

  defp generated_comment_id do
    "memory-comment-#{System.unique_integer([:positive])}"
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
