defmodule SymphonyElixir.Orchestrator.Retry do
  @moduledoc """
  Retry scheduling, backoff calculation, and retry state management.

  Extracted from the monolithic Orchestrator GenServer to isolate retry logic
  and make it more testable and maintainable.

  ## Error classification integration

  When scheduling a retry, the caller can include an `error_classification` map
  in the metadata. The retry module checks both permanent error classification
  and the hard retry cap (`agent.max_retries`) before scheduling.

  - Permanent errors → no retry scheduled, returns state unchanged
  - Max retries exceeded → no retry scheduled, returns state unchanged
  - Transient within limit → normal retry with exponential backoff
  """

  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.Config
  alias SymphonyElixir.Orchestrator.{ErrorClassifier, State}

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000

  @spec max_retries_exceeded?(non_neg_integer()) :: boolean()
  @doc """
  Returns true if the attempt count exceeds the configured max retries.
  """
  def max_retries_exceeded?(attempt) when is_integer(attempt) and attempt > 0 do
    attempt > Config.settings!().agent.max_retries
  end

  def max_retries_exceeded?(_attempt), do: false

  @spec schedule_issue_retry(State.t(), String.t(), integer() | nil, map()) :: State.t()
  @doc """
  Schedule a retry attempt for an issue.

  Returns the state unchanged (no retry scheduled) when:
  - The error is classified as permanent
  - The max retries limit has been exceeded

  In both cases, a warning is logged with structured context for observability.
  """
  def schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)

    case check_retry_eligibility(next_attempt, metadata) do
      :eligible ->
        do_schedule_retry(state, issue_id, next_attempt, metadata, previous_retry)

      {:blocked, reason, classified_error} ->
        require Logger

        Logger.warning(
          "Retry blocked for issue_id=#{issue_id} issue_identifier=#{identifier}" <>
            " reason=#{reason}" <>
            " category=#{classified_error.category}" <>
            " classification=#{classified_error.classification}" <>
            " recovery_hint=#{classified_error.recovery_hint || "none"}" <>
            " attempt=#{next_attempt}"
        )

        state
    end
  end

  @spec check_retry_eligibility(pos_integer(), map()) ::
          :eligible | {:blocked, String.t(), ErrorClassifier.classified_error()}
  defp check_retry_eligibility(attempt, metadata) do
    error = metadata[:error]
    classified = if error, do: ErrorClassifier.classify(error), else: nil

    cond do
      not is_nil(classified) and classified.classification == :permanent ->
        {:blocked, "permanent_error", classified}

      max_retries_exceeded?(attempt) ->
        category = if classified, do: classified.category, else: "unknown"

        {:blocked, "max_retries_exceeded",
         %{
           classification: :transient,
           category: category,
           message: "Max retries (#{Config.settings!().agent.max_retries}) exceeded at attempt #{attempt}",
           retryable: false,
           recovery_hint: "Increase agent.max_retries in WORKFLOW.md or investigate the underlying error"
         }}

      true ->
        :eligible
    end
  end

  @spec do_schedule_retry(State.t(), String.t(), pos_integer(), map(), map()) :: State.t()
  defp do_schedule_retry(%State{} = state, issue_id, next_attempt, metadata, previous_retry) do
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    session_file = pick_retry_session_file(previous_retry, metadata)
    session_dir = pick_retry_session_dir(previous_retry, metadata)
    proof_dir = pick_retry_proof_dir(previous_retry, metadata)
    proof_events_path = pick_retry_proof_events_path(previous_retry, metadata)
    proof_summary_path = pick_retry_proof_summary_path(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""
    require Logger
    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    error_classification =
      if is_binary(error), do: ErrorClassifier.classify(error), else: nil

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            error_classification: error_classification,
            worker_host: worker_host,
            workspace_path: workspace_path,
            session_file: session_file,
            session_dir: session_dir,
            proof_dir: proof_dir,
            proof_events_path: proof_events_path,
            proof_summary_path: proof_summary_path
          })
    }
  end

  @spec pop_retry_attempt_state(State.t(), String.t(), reference()) ::
          {:ok, non_neg_integer(), map(), State.t()} | :missing
  @doc """
  Pop retry attempt state for processing.
  """
  def pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          error_classification: Map.get(retry_entry, :error_classification),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          session_file: Map.get(retry_entry, :session_file),
          session_dir: Map.get(retry_entry, :session_dir),
          proof_dir: Map.get(retry_entry, :proof_dir),
          proof_events_path: Map.get(retry_entry, :proof_events_path),
          proof_summary_path: Map.get(retry_entry, :proof_summary_path)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  @spec retry_delay(pos_integer(), map()) :: pos_integer()
  @doc """
  Calculate retry delay based on attempt number and metadata.

  Delay types:
  - `:continuation` — worker ran long enough and exited normally; short delay
  - `:short_lived_exit` — worker exited normally but ran below the short-run
    threshold (e.g. hit a rate limit on the first API call); uses failure backoff
    with `min_retry_interval_ms` floor
  - anything else — failure backoff with `min_retry_interval_ms` floor
  """
  def retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    base_delay =
      if metadata[:delay_type] == :continuation and attempt == 1 do
        @continuation_retry_delay_ms
      else
        failure_retry_delay(attempt)
      end

    enforce_minimum_interval(base_delay, metadata)
  end

  @spec enforce_minimum_interval(pos_integer(), map()) :: pos_integer()
  @doc """
  Apply the configured minimum retry interval as a floor.

  Genuine continuation retries (long-running workers that completed some work)
  are exempt from the floor — they should resume quickly. Short-lived exits
  and failure retries always respect the floor.

  When rate limit information is present in `metadata[:retry_after_ms]`, it is
  used as an additional floor alongside `min_retry_interval_ms`. The final
  delay is the maximum of the base delay, the config floor, and the
  rate-limit-derived floor.
  """
  def enforce_minimum_interval(delay_ms, metadata) when is_integer(delay_ms) and is_map(metadata) do
    if metadata[:delay_type] == :continuation do
      delay_ms
    else
      config_floor = Config.settings!().agent.min_retry_interval_ms
      rate_limit_floor = Map.get(metadata, :retry_after_ms, 0)
      Enum.max([delay_ms, config_floor, rate_limit_floor])
    end
  end

  @spec failure_retry_delay(pos_integer()) :: pos_integer()
  @doc """
  Calculate exponential backoff delay for failures.
  """
  def failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  @spec short_lived_exit?(map()) :: boolean()
  @doc """
  Determine whether a running entry represents a short-lived run.

  A run is short-lived when it completed in less time than the configured
  `short_run_threshold_ms`. Short-lived normal exits are treated as transient
  failures (e.g. rate limits) rather than genuine work completions.
  """
  def short_lived_exit?(running_entry) when is_map(running_entry) do
    threshold_ms = Config.settings!().agent.short_run_threshold_ms

    case running_entry_runtime_ms(running_entry) do
      ms when is_integer(ms) and ms < threshold_ms -> true
      _ -> false
    end
  end

  @spec running_entry_runtime_ms(map()) :: non_neg_integer() | nil
  @doc """
  Compute the runtime in milliseconds for a running entry.
  """
  def running_entry_runtime_ms(%{started_at: %DateTime{} = started_at}) do
    max(0, DateTime.diff(DateTime.utc_now(), started_at, :millisecond))
  end

  def running_entry_runtime_ms(_running_entry), do: nil

  @spec extract_retry_after_ms(map() | nil) :: non_neg_integer()
  @doc """
  Extract a retry-after floor (in milliseconds) from rate limit data.

  Inspects the `primary` and `secondary` buckets for `reset_in_seconds`
  values. When a bucket's `remaining` count is zero (rate limited), its
  `reset_in_seconds` is converted to milliseconds. The maximum across
  all exhausted buckets is returned.

  Returns `0` when no actionable rate limit data is present.
  """
  def extract_retry_after_ms(rate_limits) when is_map(rate_limits) do
    Enum.max([
      bucket_retry_after_ms(rate_limits, ["primary", :primary]),
      bucket_retry_after_ms(rate_limits, ["secondary", :secondary]),
      0
    ])
  end

  def extract_retry_after_ms(_rate_limits), do: 0

  @spec normalize_retry_attempt(integer() | any()) :: non_neg_integer()
  @doc """
  Normalize retry attempt to valid range.
  """
  def normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  def normalize_retry_attempt(_attempt), do: 0

  @spec next_retry_attempt_from_running(map()) :: integer() | nil
  @doc """
  Calculate next retry attempt from running entry.
  """
  def next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  @spec retry_runtime_metadata(map()) :: map()
  @doc """
  Extract retry runtime metadata from running entry.
  """
  def retry_runtime_metadata(running_entry) when is_map(running_entry) do
    %{
      session_file: Map.get(running_entry, :session_file),
      session_dir: Map.get(running_entry, :session_dir),
      proof_dir: Map.get(running_entry, :proof_dir),
      proof_events_path: Map.get(running_entry, :proof_events_path),
      proof_summary_path: Map.get(running_entry, :proof_summary_path)
    }
  end

  # Private helpers for rate-limit-aware backoff

  defp bucket_retry_after_ms(rate_limits, keys) when is_map(rate_limits) and is_list(keys) do
    bucket = Enum.find_value(keys, fn key -> Map.get(rate_limits, key) end)
    bucket_reset_ms(bucket)
  end

  defp bucket_reset_ms(bucket) when is_map(bucket) do
    remaining = bucket_remaining(bucket)
    reset_seconds = bucket_reset_seconds(bucket)

    if is_number(remaining) and remaining <= 0 and is_number(reset_seconds) and reset_seconds > 0 do
      round(reset_seconds * 1_000)
    else
      0
    end
  end

  defp bucket_reset_ms(_bucket), do: 0

  defp bucket_remaining(bucket) do
    Map.get(bucket, "remaining") || Map.get(bucket, :remaining)
  end

  defp bucket_reset_seconds(bucket) do
    Map.get(bucket, "reset_in_seconds") || Map.get(bucket, :reset_in_seconds)
  end

  # Private helper functions for picking retry values
  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_session_file(previous_retry, metadata) do
    metadata[:session_file] || Map.get(previous_retry, :session_file)
  end

  defp pick_retry_session_dir(previous_retry, metadata) do
    metadata[:session_dir] || Map.get(previous_retry, :session_dir)
  end

  defp pick_retry_proof_dir(previous_retry, metadata) do
    metadata[:proof_dir] || Map.get(previous_retry, :proof_dir)
  end

  defp pick_retry_proof_events_path(previous_retry, metadata) do
    metadata[:proof_events_path] || Map.get(previous_retry, :proof_events_path)
  end

  defp pick_retry_proof_summary_path(previous_retry, metadata) do
    metadata[:proof_summary_path] || Map.get(previous_retry, :proof_summary_path)
  end
end
