defmodule SymphonyElixir.Orchestrator.ErrorClassifierTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator.ErrorClassifier

  describe "classify/1" do
    test "classifies 'model not found' as permanent" do
      result = ErrorClassifier.classify("Model not found: anthropic/claude-nonexistent")

      assert result.classification == :permanent
      assert result.category == "model_not_found"
      assert result.retryable == false
      assert is_binary(result.recovery_hint)
      assert result.recovery_hint =~ "pi --list-models"
    end

    test "classifies 'invalid model' as permanent" do
      result = ErrorClassifier.classify("invalid model specified")

      assert result.classification == :permanent
      assert result.category == "model_not_found"
      assert result.retryable == false
    end

    test "classifies 'no such model' as permanent" do
      result = ErrorClassifier.classify("no such model openai/gpt-5.5")

      assert result.classification == :permanent
      assert result.category == "model_not_found"
      assert result.retryable == false
    end

    test "classifies 'api key invalid' as permanent" do
      result = ErrorClassifier.classify("api key invalid")

      assert result.classification == :permanent
      assert result.category == "invalid_api_key"
      assert result.retryable == false
    end

    test "classifies 'api key missing' as permanent" do
      result = ErrorClassifier.classify("api key missing for provider")

      assert result.classification == :permanent
      assert result.category == "invalid_api_key"
      assert result.retryable == false
    end

    test "classifies 'api key expired' as permanent" do
      result = ErrorClassifier.classify("api key expired")

      assert result.classification == :permanent
      assert result.category == "invalid_api_key"
      assert result.retryable == false
    end

    test "classifies 'invalid api key' as permanent" do
      result = ErrorClassifier.classify("invalid api key provided")

      assert result.classification == :permanent
      assert result.category == "invalid_api_key"
      assert result.retryable == false
    end

    test "classifies 'authentication failed' as permanent" do
      result = ErrorClassifier.classify("authentication failed for endpoint")

      assert result.classification == :permanent
      assert result.category == "auth_failure"
      assert result.retryable == false
    end

    test "classifies 'unauthorized' as permanent" do
      result = ErrorClassifier.classify("unauthorized access to API")

      assert result.classification == :permanent
      assert result.category == "auth_failure"
      assert result.retryable == false
    end

    test "classifies 'permission denied' as permanent" do
      result = ErrorClassifier.classify("permission denied for operation")

      assert result.classification == :permanent
      assert result.category == "permission_denied"
      assert result.retryable == false
    end

    test "classifies 'forbidden' as permanent" do
      result = ErrorClassifier.classify("forbidden: insufficient permissions")

      assert result.classification == :permanent
      assert result.category == "permission_denied"
      assert result.retryable == false
    end

    test "classifies 'invalid workflow config' as permanent" do
      result = ErrorClassifier.classify("invalid workflow config: missing field")

      assert result.classification == :permanent
      assert result.category == "invalid_config"
      assert result.retryable == false
    end

    test "classifies 'bash not found' as permanent" do
      result = ErrorClassifier.classify("bash not found in PATH")

      assert result.classification == :permanent
      assert result.category == "missing_dependency"
      assert result.retryable == false
    end

    test "classifies 'remote pi workers not supported' as permanent" do
      result = ErrorClassifier.classify("remote pi workers not supported")

      assert result.classification == :permanent
      assert result.category == "unsupported_config"
      assert result.retryable == false
    end

    test "classifies port exit 127 (command not found) as permanent" do
      result = ErrorClassifier.classify({:port_exit, 127})

      assert result.classification == :permanent
      assert result.category == "command_not_found"
      assert result.retryable == false
    end

    test "classifies port exit 126 (not executable) as permanent" do
      result = ErrorClassifier.classify({:port_exit, 126})

      assert result.classification == :permanent
      assert result.category == "command_not_found"
      assert result.retryable == false
    end

    test "classifies rpc_command_failed with permanent error string as permanent" do
      result = ErrorClassifier.classify({:rpc_command_failed, "Model not found: test/model"})

      assert result.classification == :permanent
      assert result.category == "model_not_found"
      assert result.retryable == false
    end

    test "classifies rpc_command_failed with permanent error map as permanent" do
      result =
        ErrorClassifier.classify({:rpc_command_failed, %{"message" => "Model not found", "error" => "invalid model"}})

      assert result.classification == :permanent
      assert result.category == "model_not_found"
      assert result.retryable == false
    end

    test "classifies workspace_root error as permanent" do
      result = ErrorClassifier.classify({:invalid_workspace_cwd, :workspace_root, "/tmp/ws"})

      assert result.classification == :permanent
      assert result.category == "invalid_workspace"
      assert result.retryable == false
    end

    test "classifies symlink_escape workspace error as permanent" do
      result =
        ErrorClassifier.classify({:invalid_workspace_cwd, :symlink_escape, "/tmp/ws", "/tmp/root"})

      assert result.classification == :permanent
      assert result.category == "invalid_workspace"
      assert result.retryable == false
    end

    test "classifies outside_workspace_root as permanent" do
      result =
        ErrorClassifier.classify({:invalid_workspace_cwd, :outside_workspace_root, "/other/path", "/tmp/root"})

      assert result.classification == :permanent
      assert result.category == "invalid_workspace"
      assert result.retryable == false
    end

    test "classifies :remote_pi_workers_not_supported atom as permanent" do
      result = ErrorClassifier.classify(:remote_pi_workers_not_supported)

      assert result.classification == :permanent
      assert result.category == "unsupported_config"
      assert result.retryable == false
    end

    # --- Transient errors ---

    test "classifies generic port exit as transient" do
      result = ErrorClassifier.classify({:port_exit, 1})

      assert result.classification == :transient
      assert result.category == "process_exit"
      assert result.retryable == true
      assert is_nil(result.recovery_hint)
    end

    test "classifies :turn_timeout as transient" do
      result = ErrorClassifier.classify(:turn_timeout)

      assert result.classification == :transient
      assert result.category == "timeout"
      assert result.retryable == true
    end

    test "classifies :response_timeout as transient" do
      result = ErrorClassifier.classify(:response_timeout)

      assert result.classification == :transient
      assert result.category == "timeout"
      assert result.retryable == true
    end

    test "classifies :timeout as transient" do
      result = ErrorClassifier.classify(:timeout)

      assert result.classification == :transient
      assert result.category == "timeout"
      assert result.retryable == true
    end

    test "classifies unknown error as transient" do
      result = ErrorClassifier.classify("some random error happened")

      assert result.classification == :transient
      assert result.category == "unknown"
      assert result.retryable == true
    end

    test "classifies rpc_command_failed with transient error as transient" do
      result = ErrorClassifier.classify({:rpc_command_failed, "connection reset"})

      assert result.classification == :transient
      assert result.retryable == true
    end

    test "classifies RuntimeError as transient for generic messages" do
      result = ErrorClassifier.classify(%RuntimeError{message: "something went wrong"})

      assert result.classification == :transient
      assert result.retryable == true
      assert result.message == "something went wrong"
    end

    test "classifies RuntimeError with model error as permanent" do
      result = ErrorClassifier.classify(%RuntimeError{message: "Model not found: test/bad"})

      assert result.classification == :permanent
      assert result.category == "model_not_found"
    end
  end

  describe "permanent?/1" do
    test "returns true for permanent errors" do
      assert ErrorClassifier.permanent?("Model not found: test") == true
      assert ErrorClassifier.permanent?({:port_exit, 127}) == true
    end

    test "returns false for transient errors" do
      assert ErrorClassifier.permanent?(:turn_timeout) == false
      assert ErrorClassifier.permanent?({:port_exit, 1}) == false
      assert ErrorClassifier.permanent?("random error") == false
    end
  end

  describe "normalize_error (via classify message)" do
    test "normalizes string errors" do
      result = ErrorClassifier.classify("plain error")
      assert result.message == "plain error"
    end

    test "normalizes RuntimeError" do
      result = ErrorClassifier.classify(%RuntimeError{message: "runtime issue"})
      assert result.message == "runtime issue"
    end

    test "normalizes rpc_command_failed with string" do
      result = ErrorClassifier.classify({:rpc_command_failed, "bad request"})
      assert result.message == "RPC command failed: bad request"
    end

    test "normalizes rpc_command_failed with map" do
      result = ErrorClassifier.classify({:rpc_command_failed, %{"message" => "invalid"}})
      assert result.message == "RPC command failed: invalid"
    end

    test "normalizes port_exit" do
      result = ErrorClassifier.classify({:port_exit, 42})
      assert result.message == "Pi process exited with status 42"
    end

    test "normalizes arbitrary terms" do
      result = ErrorClassifier.classify({:some, :tuple, :error})
      assert result.message == "{:some, :tuple, :error}"
    end
  end
end
