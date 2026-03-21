defmodule SymphonyElixir.Orchestrator.ErrorClassifier do
  @moduledoc """
  Classifies agent errors as permanent or transient.

  Permanent errors (model not found, auth failures, invalid config) immediately
  transition an issue to `blocked` phase without retrying.

  Transient errors (timeouts, rate limits, network issues) are retried with
  exponential backoff up to the configured `agent.max_retries` limit.

  ## Classification structure

  Each classified error includes:
  - `classification` — `:permanent` or `:transient`
  - `category` — machine-readable error category
  - `message` — human-readable error summary
  - `retryable` — boolean, false for permanent errors
  - `recovery_hint` — actionable guidance for operators (or nil)
  """

  @type classification :: :permanent | :transient

  @type classified_error :: %{
          classification: classification(),
          category: String.t(),
          message: String.t(),
          retryable: boolean(),
          recovery_hint: String.t() | nil
        }

  @permanent_patterns [
    {~r/model[_ ]not[_ ]found/i, "model_not_found", "Check pi.model in WORKFLOW.md; run `pi --list-models` to see available models"},
    {~r/invalid[_ ]model/i, "model_not_found", "Check pi.model in WORKFLOW.md; run `pi --list-models` to see available models"},
    {~r/no[_ ]such[_ ]model/i, "model_not_found", "Check pi.model in WORKFLOW.md; run `pi --list-models` to see available models"},
    {~r/api[_ ]key[_ ](invalid|missing|not[_ ]found|expired)/i, "invalid_api_key", "Set a valid API key in the environment or WORKFLOW.md tracker.api_key"},
    {~r/invalid[_ ]api[_ ]key/i, "invalid_api_key", "Set a valid API key in the environment or WORKFLOW.md tracker.api_key"},
    {~r/authentication[_ ]failed/i, "auth_failure", "Verify API credentials are valid and not expired"},
    {~r/unauthorized/i, "auth_failure", "Verify API credentials are valid and not expired"},
    {~r/permission[_ ]denied/i, "permission_denied", "Check that the API key has sufficient permissions"},
    {~r/forbidden/i, "permission_denied", "Check that the API key has sufficient permissions"},
    {~r/invalid[_ ]workflow[_ ]config/i, "invalid_config", "Fix the WORKFLOW.md configuration and restart"},
    {~r/missing[_ ]workflow[_ ]file/i, "invalid_config", "Ensure WORKFLOW.md exists at the expected path"},
    {~r/bash[_ ]not[_ ]found/i, "missing_dependency", "Ensure bash is installed and available in PATH"},
    {~r/remote[_ ]pi[_ ]workers[_ ]not[_ ]supported/i, "unsupported_config", "Pi runtime does not support SSH worker hosts; remove worker.ssh_hosts or use codex runtime"}
  ]

  @doc """
  Classify an error reason into a structured error with classification,
  category, message, retryable flag, and recovery hint.
  """
  @spec classify(term()) :: classified_error()
  def classify(reason) do
    error_string = normalize_error(reason)

    case match_permanent_pattern(error_string) do
      {:ok, category, recovery_hint} ->
        %{
          classification: :permanent,
          category: category,
          message: error_string,
          retryable: false,
          recovery_hint: recovery_hint
        }

      :no_match ->
        case classify_structured_error(reason) do
          {:permanent, category, hint} ->
            %{
              classification: :permanent,
              category: category,
              message: error_string,
              retryable: false,
              recovery_hint: hint
            }

          :transient ->
            %{
              classification: :transient,
              category: transient_category(reason),
              message: error_string,
              retryable: true,
              recovery_hint: nil
            }
        end
    end
  end

  @doc """
  Returns true if the error is classified as permanent (non-retryable).
  """
  @spec permanent?(term()) :: boolean()
  def permanent?(reason) do
    classify(reason).classification == :permanent
  end

  @spec match_permanent_pattern(String.t()) :: {:ok, String.t(), String.t()} | :no_match
  defp match_permanent_pattern(error_string) when is_binary(error_string) do
    Enum.find_value(@permanent_patterns, :no_match, fn {pattern, category, hint} ->
      if Regex.match?(pattern, error_string) do
        {:ok, category, hint}
      end
    end)
  end

  @spec classify_structured_error(term()) :: {:permanent, String.t(), String.t()} | :transient
  defp classify_structured_error({:rpc_command_failed, error}) when is_binary(error) do
    nested = classify(error)

    if nested.classification == :permanent do
      {:permanent, nested.category, nested.recovery_hint}
    else
      :transient
    end
  end

  defp classify_structured_error({:rpc_command_failed, error}) when is_map(error) do
    message = Map.get(error, "message", "") <> " " <> Map.get(error, "error", "")
    nested = classify(message)

    if nested.classification == :permanent do
      {:permanent, nested.category, nested.recovery_hint}
    else
      :transient
    end
  end

  defp classify_structured_error({:port_exit, status}) when is_integer(status) do
    # Exit codes 126 (command not executable) and 127 (command not found) are permanent
    if status in [126, 127] do
      {:permanent, "command_not_found", "The Pi command is not found or not executable; check pi.command in WORKFLOW.md"}
    else
      :transient
    end
  end

  defp classify_structured_error({:invalid_workspace_cwd, sub_reason, _path})
       when sub_reason in [:workspace_root, :symlink_escape] do
    {:permanent, "invalid_workspace", "Workspace path is invalid; check workspace.root in WORKFLOW.md"}
  end

  defp classify_structured_error({:invalid_workspace_cwd, sub_reason, _path, _root})
       when sub_reason in [:outside_workspace_root, :symlink_escape, :path_unreadable] do
    {:permanent, "invalid_workspace", "Workspace path is outside configured root; check workspace.root in WORKFLOW.md"}
  end

  defp classify_structured_error(:remote_pi_workers_not_supported) do
    {:permanent, "unsupported_config", "Pi runtime does not support SSH worker hosts; remove worker.ssh_hosts or use codex runtime"}
  end

  defp classify_structured_error(_reason), do: :transient

  @spec transient_category(term()) :: String.t()
  defp transient_category(:turn_timeout), do: "timeout"
  defp transient_category(:response_timeout), do: "timeout"
  defp transient_category({:port_exit, _status}), do: "process_exit"
  defp transient_category(:timeout), do: "timeout"
  defp transient_category(_reason), do: "unknown"

  @spec normalize_error(term()) :: String.t()
  defp normalize_error(reason) when is_binary(reason), do: reason

  defp normalize_error(%RuntimeError{message: message}), do: message

  defp normalize_error({:rpc_command_failed, error}) when is_binary(error) do
    "RPC command failed: #{error}"
  end

  defp normalize_error({:rpc_command_failed, error}) when is_map(error) do
    message = Map.get(error, "message", Map.get(error, "error", inspect(error)))
    "RPC command failed: #{message}"
  end

  defp normalize_error({:port_exit, status}) when is_integer(status) do
    "Pi process exited with status #{status}"
  end

  defp normalize_error(reason), do: inspect(reason)
end
