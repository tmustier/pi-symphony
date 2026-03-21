defmodule SymphonyElixir.Orchestrator.RetryErrorClassificationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.{Retry, State}

  describe "schedule_issue_retry with error classification" do
    test "blocks retry for permanent errors (model not found)" do
      state = %State{retry_attempts: %{}}

      metadata = %{
        identifier: "TEST-1",
        error: "Model not found: anthropic/claude-nonexistent"
      }

      result = Retry.schedule_issue_retry(state, "issue-1", 1, metadata)

      # Should return state unchanged — no retry scheduled
      assert result.retry_attempts == %{}
    end

    test "blocks retry for permanent errors (auth failure)" do
      state = %State{retry_attempts: %{}}

      metadata = %{
        identifier: "TEST-2",
        error: "authentication failed"
      }

      result = Retry.schedule_issue_retry(state, "issue-2", 1, metadata)
      assert result.retry_attempts == %{}
    end

    test "blocks retry for permanent errors (api key invalid)" do
      state = %State{retry_attempts: %{}}

      metadata = %{
        identifier: "TEST-3",
        error: "api key invalid for provider anthropic"
      }

      result = Retry.schedule_issue_retry(state, "issue-3", 1, metadata)
      assert result.retry_attempts == %{}
    end

    test "allows retry for transient errors" do
      state = %State{retry_attempts: %{}}

      metadata = %{
        identifier: "TEST-4",
        error: "connection reset by peer"
      }

      result = Retry.schedule_issue_retry(state, "issue-4", 1, metadata)
      assert Map.has_key?(result.retry_attempts, "issue-4")

      retry_entry = result.retry_attempts["issue-4"]
      assert retry_entry.attempt == 1
      assert is_reference(retry_entry.timer_ref)
    end

    test "includes error_classification in retry entry" do
      state = %State{retry_attempts: %{}}

      metadata = %{
        identifier: "TEST-5",
        error: "connection timeout"
      }

      result = Retry.schedule_issue_retry(state, "issue-5", 1, metadata)
      retry_entry = result.retry_attempts["issue-5"]

      assert retry_entry.error_classification.classification == :transient
      assert retry_entry.error_classification.category == "unknown"
      assert retry_entry.error_classification.retryable == true
    end
  end

  describe "schedule_issue_retry with max_retries cap" do
    test "blocks retry when max_retries exceeded" do
      state = %State{retry_attempts: %{}}

      # Default max_retries is 10, so attempt 11 should be blocked
      metadata = %{
        identifier: "TEST-6",
        error: "connection timeout"
      }

      result = Retry.schedule_issue_retry(state, "issue-6", 11, metadata)
      assert result.retry_attempts == %{}
    end

    test "allows retry at max_retries boundary" do
      state = %State{retry_attempts: %{}}

      # Default max_retries is 10, so attempt 10 should be allowed
      metadata = %{
        identifier: "TEST-7",
        error: "connection timeout"
      }

      result = Retry.schedule_issue_retry(state, "issue-7", 10, metadata)
      assert Map.has_key?(result.retry_attempts, "issue-7")
    end

    test "allows retry below max_retries" do
      state = %State{retry_attempts: %{}}

      metadata = %{
        identifier: "TEST-8",
        error: "transient network error"
      }

      result = Retry.schedule_issue_retry(state, "issue-8", 5, metadata)
      assert Map.has_key?(result.retry_attempts, "issue-8")
      assert result.retry_attempts["issue-8"].attempt == 5
    end
  end

  describe "max_retries_exceeded?/1" do
    test "returns false for attempts within limit" do
      assert Retry.max_retries_exceeded?(1) == false
      assert Retry.max_retries_exceeded?(5) == false
      assert Retry.max_retries_exceeded?(10) == false
    end

    test "returns true when exceeding limit" do
      assert Retry.max_retries_exceeded?(11) == true
      assert Retry.max_retries_exceeded?(100) == true
    end

    test "returns false for invalid inputs" do
      assert Retry.max_retries_exceeded?(0) == false
      assert Retry.max_retries_exceeded?(-1) == false
      assert Retry.max_retries_exceeded?(nil) == false
    end
  end

  describe "pop_retry_attempt_state includes error_classification" do
    test "metadata includes error_classification when present" do
      retry_token = make_ref()

      state = %State{
        retry_attempts: %{
          "issue-1" => %{
            attempt: 3,
            retry_token: retry_token,
            due_at_ms: 0,
            identifier: "TEST-1",
            error: "timeout",
            error_classification: %{
              classification: :transient,
              category: "timeout",
              message: "timeout",
              retryable: true,
              recovery_hint: nil
            },
            worker_host: nil,
            workspace_path: nil,
            session_file: nil,
            session_dir: nil,
            proof_dir: nil,
            proof_events_path: nil,
            proof_summary_path: nil
          }
        }
      }

      {:ok, attempt, metadata, _new_state} =
        Retry.pop_retry_attempt_state(state, "issue-1", retry_token)

      assert attempt == 3
      assert metadata.error_classification.classification == :transient
      assert metadata.error_classification.category == "timeout"
    end
  end
end
