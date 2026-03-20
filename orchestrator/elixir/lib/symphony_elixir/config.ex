defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{OrchestrationPolicy, Workflow}

  @default_prompt_template """
  You are an unattended coding agent assigned to this issue:

  - identifier: {{ issue.identifier }}
  - title: {{ issue.title }}
  - url: {{ issue.url }}
  - branch: {{ issue.branch_name }}

  {% if issue.description %}
  Description:
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}

  Start by understanding the codebase. Read AGENTS.md, READMEs, relevant source files, tests, and CI config in full. Understand the project's conventions, tech stack, and how changes are validated before writing any code.

  Then implement the issue on branch `{{ issue.branch_name }}`. Create it from the base branch if it doesn't exist. Validate your changes the way the project validates itself — run the tests, the linter, the build, whatever applies. Treat non-zero exit codes as real failures.

  Do not spend turns rebasing against the base branch at the end of the task. The orchestrator manages integration and merge sequencing.

  Then run a self-review on the code you are about to push:
  1. Get the current HEAD SHA with `git rev-parse HEAD`.
  2. Generate the diff with `git diff origin/{{ policy.pr.base_branch }}...HEAD`.
  3. Run the `pr-reviewer` subagent with the diff to review your changes.
  4. Write the review output to `.symphony/review.md` with a leading `<!-- symphony-review-head: <SHA> -->` line.
  5. If the review surfaces P0 or P1 findings you agree with, fix them and re-review once.

  Then push your branch and create a pull request with a clear, descriptive title and body explaining what changed and why.

  Constraints:
  1. Work only on branch `{{ issue.branch_name }}`.
  2. Never move the issue to a terminal state (Done, Closed, etc). The orchestrator manages tracker transitions.
  3. If the task is genuinely unclear before any code changes, record a blocker and stop.
  4. Never ask interactive questions. Gather context from the issue, codebase, and branch state.

  If this is a continuation attempt, resume from the current workspace state instead of restarting.
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @settings_cache_key :symphony_settings_cache

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        cached_settings_parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cached_settings_parse(config) when is_map(config) do
    cache_key = :erlang.phash2(config)

    case Process.get(@settings_cache_key) do
      {^cache_key, settings} ->
        {:ok, settings}

      _ ->
        case Schema.parse(config) do
          {:ok, settings} = result ->
            Process.put(@settings_cache_key, {cache_key, settings})
            result

          error ->
            error
        end
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec prompt_policy() :: map()
  def prompt_policy do
    settings_to_prompt_policy(settings!())
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  @spec worker_runtime() :: :codex | :pi
  def worker_runtime do
    case settings!().worker.runtime do
      "pi" -> :pi
      _ -> :codex
    end
  end

  defp validate_semantics(settings) do
    with :ok <- validate_tracker_kind(settings),
         :ok <- validate_linear_requirements(settings),
         :ok <- validate_worker_runtime_semantics(settings),
         :ok <- validate_orchestration_semantics(settings),
         :ok <- validate_rollout_semantics(settings),
         :ok <- validate_pr_semantics(settings),
         :ok <- validate_review_semantics(settings) do
      validate_merge_semantics(settings)
    end
  end

  defp validate_tracker_kind(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      true ->
        :ok
    end
  end

  defp validate_linear_requirements(%{tracker: %{kind: "linear", api_key: api_key}})
       when not is_binary(api_key) do
    {:error, :missing_linear_api_token}
  end

  defp validate_linear_requirements(%{tracker: %{kind: "linear"} = tracker}) do
    if linear_scope_present?(tracker.project_slug) or linear_scope_present?(tracker.team_key) do
      :ok
    else
      {:error, :missing_linear_scope}
    end
  end

  defp validate_linear_requirements(_settings), do: :ok

  defp linear_scope_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp linear_scope_present?(_value), do: false

  defp validate_worker_runtime_semantics(%{worker: %{runtime: "pi", ssh_hosts: ssh_hosts}})
       when is_list(ssh_hosts) and ssh_hosts != [] do
    {:error, {:invalid_workflow_config, "worker.ssh_hosts is not supported when worker.runtime is set to pi"}}
  end

  defp validate_worker_runtime_semantics(_settings), do: :ok

  defp validate_orchestration_semantics(settings) do
    orchestration = settings.orchestration

    cond do
      orchestration.default_phase not in OrchestrationPolicy.phase_values() ->
        {:error, {:invalid_workflow_config, "orchestration.default_phase must be one of #{Enum.join(OrchestrationPolicy.phase_values(), ", ")}"}}

      Enum.any?(orchestration.passive_phases, &(&1 not in OrchestrationPolicy.phase_values())) ->
        {:error, {:invalid_workflow_config, "orchestration.passive_phases must be a subset of #{Enum.join(OrchestrationPolicy.phase_values(), ", ")}"}}

      "blocked" not in orchestration.passive_phases ->
        {:error, {:invalid_workflow_config, "orchestration.passive_phases must include blocked to preserve conservative recovery behavior"}}

      not is_integer(orchestration.max_rework_cycles) or orchestration.max_rework_cycles <= 0 ->
        {:error, {:invalid_workflow_config, "orchestration.max_rework_cycles must be greater than 0"}}

      true ->
        :ok
    end
  end

  defp validate_rollout_semantics(settings) do
    rollout = settings.rollout
    merge = settings.merge

    cond do
      rollout.mode == "observe" and merge.mode == "auto" ->
        :ok

      rollout.mode == "mutate" and merge.mode == "auto" ->
        :ok

      rollout.mode == "merge" and rollout.preflight_required != true ->
        {:error, {:invalid_workflow_config, "rollout.preflight_required must be true when rollout.mode is set to merge"}}

      true ->
        :ok
    end
  end

  defp validate_pr_semantics(settings) do
    pr = settings.pr

    if pr.review_comment_mode == "upsert" and not is_binary(pr.review_comment_marker) do
      {:error, {:invalid_workflow_config, "pr.review_comment_marker is required when pr.review_comment_mode is upsert"}}
    else
      :ok
    end
  end

  defp validate_review_semantics(settings) do
    review = settings.review

    cond do
      review.enabled != true ->
        :ok

      not is_binary(review.agent) ->
        {:error, {:invalid_workflow_config, "review.agent is required when review.enabled is true"}}

      not is_binary(review.output_format) ->
        {:error, {:invalid_workflow_config, "review.output_format is required when review.enabled is true"}}

      review.output_format not in OrchestrationPolicy.review_output_formats() ->
        {:error, {:invalid_workflow_config, "review.output_format must be one of #{Enum.join(OrchestrationPolicy.review_output_formats(), ", ")}"}}

      not is_integer(review.max_passes) or review.max_passes <= 0 ->
        {:error, {:invalid_workflow_config, "review.max_passes must be greater than 0"}}

      true ->
        :ok
    end
  end

  defp validate_merge_semantics(settings) do
    merge = settings.merge

    cond do
      merge.mode == "auto" and merge.require_human_approval == true and merge.approval_states == [] ->
        {:error, {:invalid_workflow_config, "merge.approval_states must be set when merge.require_human_approval is true"}}

      merge.strategy == "queue" and merge.method == "rebase" ->
        {:error, {:invalid_workflow_config, "merge.method must be squash or merge when merge.strategy is queue"}}

      not is_integer(merge.max_rebase_attempts) or merge.max_rebase_attempts <= 0 ->
        {:error, {:invalid_workflow_config, "merge.max_rebase_attempts must be greater than 0"}}

      merge.mode == "auto" and rollout_disallows_merge?(settings.rollout.mode) ->
        :ok

      true ->
        :ok
    end
  end

  defp rollout_disallows_merge?(mode), do: mode in ["observe", "mutate"]

  defp settings_to_prompt_policy(settings) do
    %{
      "orchestration" => struct_to_prompt_map(settings.orchestration),
      "rollout" => struct_to_prompt_map(settings.rollout),
      "pr" => struct_to_prompt_map(settings.pr),
      "review" => struct_to_prompt_map(settings.review),
      "merge" => struct_to_prompt_map(settings.merge)
    }
  end

  defp struct_to_prompt_map(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Enum.reject(fn {key, _value} -> key == :__meta__ end)
    |> Map.new(fn {key, value} -> {to_string(key), prompt_value(value)} end)
  end

  defp struct_to_prompt_map(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {to_string(key), prompt_value(nested_value)} end)
  end

  defp prompt_value(%_{} = value), do: struct_to_prompt_map(value)
  defp prompt_value(value) when is_map(value), do: struct_to_prompt_map(value)
  defp prompt_value(value) when is_list(value), do: Enum.map(value, &prompt_value/1)
  defp prompt_value(value), do: value

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      :missing_linear_scope ->
        "Invalid WORKFLOW.md config: tracker.project_slug or tracker.team_key must be set for Linear"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
