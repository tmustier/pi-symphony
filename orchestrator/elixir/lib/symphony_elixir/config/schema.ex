defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.{OrchestrationPolicy, PathSafety, Workflow}
  import SymphonyElixir.MapUtils, only: [normalize_optional_string: 1, stringify_key: 1]

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:team_key, :string)
      field(:assignee, :string)
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:kind, :endpoint, :api_key, :project_slug, :team_key, :assignee, :active_states, :terminal_states],
        empty_values: []
      )
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
      field(:cleanup_on_shutdown, :boolean, default: true)
      field(:cleanup_after_merge, :boolean, default: true)
      field(:retention_hours, :float)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root, :cleanup_on_shutdown, :cleanup_after_merge, :retention_hours], empty_values: [])
      |> validate_number(:retention_hours, greater_than: 0)
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:runtime, :string, default: "codex")
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:runtime, :ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_inclusion(:runtime, ["codex", "pi"])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_retries, :integer, default: 10)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:max_concurrent_agents, :max_turns, :max_retry_backoff_ms, :max_retries, :max_concurrent_agents_by_state],
        empty_values: []
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> validate_number(:max_retries, greater_than: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule PiModel do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:provider, :string)
      field(:model_id, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:provider, :model_id], empty_values: [])
      |> validate_required([:provider, :model_id])
    end
  end

  defmodule Pi do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema.PiModel

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "pi")
      field(:response_timeout_ms, :integer, default: 60_000)
      field(:session_dir_name, :string, default: ".pi-rpc-sessions")
      field(:extension_paths, {:array, :string}, default: [])
      field(:disable_extensions, :boolean, default: true)
      field(:disable_themes, :boolean, default: true)
      field(:thinking_level, :string)
      embeds_one(:model, PiModel, on_replace: :update)
    end

    @thinking_levels ["off", "minimal", "low", "medium", "high", "xhigh"]

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :response_timeout_ms,
          :session_dir_name,
          :extension_paths,
          :disable_extensions,
          :disable_themes,
          :thinking_level
        ],
        empty_values: []
      )
      |> cast_embed(:model, with: &PiModel.changeset/2)
      |> validate_required([:command, :session_dir_name])
      |> validate_number(:response_timeout_ms, greater_than: 0)
      |> validate_inclusion(:thinking_level, @thinking_levels)
    end
  end

  defmodule OrchestrationOwnership do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:required_label, :string)
      field(:required_workpad_marker, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:required_label, :required_workpad_marker], empty_values: [])
    end
  end

  defmodule Orchestration do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema.OrchestrationOwnership

    @primary_key false
    embedded_schema do
      field(:phase_store, :string, default: "workpad")
      field(:default_phase, :string, default: "implementing")
      field(:passive_phases, {:array, :string}, default: OrchestrationPolicy.passive_default_phases())
      field(:max_rework_cycles, :integer, default: 3)
      embeds_one(:ownership, OrchestrationOwnership, on_replace: :update, defaults_to_struct: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:phase_store, :default_phase, :passive_phases, :max_rework_cycles], empty_values: [])
      |> cast_embed(:ownership, with: &OrchestrationOwnership.changeset/2)
      |> validate_inclusion(:phase_store, ["workpad"])
      |> validate_number(:max_rework_cycles, greater_than: 0)
    end
  end

  defmodule Rollout do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:mode, :string, default: "mutate")
      field(:preflight_required, :boolean, default: false)
      field(:kill_switch_label, :string)
      field(:kill_switch_file, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:mode, :preflight_required, :kill_switch_label, :kill_switch_file], empty_values: [])
      |> validate_inclusion(:mode, OrchestrationPolicy.rollout_modes())
    end
  end

  defmodule Pr do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:auto_create, :boolean, default: false)
      field(:base_branch, :string, default: "main")
      field(:repo_slug, :string)
      field(:reuse_branch_pr, :boolean, default: true)
      field(:closed_pr_policy, :string, default: "new_branch")
      field(:attach_to_tracker, :boolean, default: true)
      field(:required_labels, {:array, :string}, default: [])
      field(:review_comment_mode, :string, default: "off")
      field(:review_comment_marker, :string, default: "<!-- symphony-review -->")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :auto_create,
          :base_branch,
          :repo_slug,
          :reuse_branch_pr,
          :closed_pr_policy,
          :attach_to_tracker,
          :required_labels,
          :review_comment_mode,
          :review_comment_marker
        ],
        empty_values: []
      )
      |> validate_inclusion(:closed_pr_policy, OrchestrationPolicy.closed_pr_policies())
      |> validate_inclusion(:review_comment_mode, OrchestrationPolicy.review_comment_modes())
    end
  end

  defmodule Review do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema.PiModel

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:agent, :string)
      field(:output_format, :string)
      field(:max_passes, :integer, default: 1)
      field(:fix_consideration_severities, {:array, :string}, default: [])
      field(:thinking_level, :string)
      embeds_one(:model, PiModel, on_replace: :update)
    end

    @thinking_levels ["off", "minimal", "low", "medium", "high", "xhigh"]

    @review_fields [
      :enabled,
      :agent,
      :output_format,
      :max_passes,
      :fix_consideration_severities,
      :thinking_level
    ]

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @review_fields, empty_values: [])
      |> cast_embed(:model, with: &PiModel.changeset/2)
      |> validate_number(:max_passes, greater_than: 0)
      |> validate_inclusion(:thinking_level, @thinking_levels)
    end
  end

  defmodule Merge do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:mode, :string, default: "disabled")
      field(:executor, :string)
      field(:method, :string, default: "squash")
      field(:strategy, :string)
      field(:max_rebase_attempts, :integer, default: 2)
      field(:require_green_checks, :boolean, default: true)
      field(:require_head_match, :boolean, default: true)
      field(:require_human_approval, :boolean, default: true)
      field(:approval_states, {:array, :string}, default: [])
      field(:completion_state, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :mode,
          :executor,
          :method,
          :strategy,
          :max_rebase_attempts,
          :require_green_checks,
          :require_head_match,
          :require_human_approval,
          :approval_states,
          :completion_state
        ],
        empty_values: []
      )
      |> validate_inclusion(:mode, OrchestrationPolicy.merge_modes())
      |> validate_inclusion(:method, OrchestrationPolicy.merge_methods())
      |> validate_inclusion(:strategy, OrchestrationPolicy.merge_strategies())
      |> validate_number(:max_rebase_attempts, greater_than: 0)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Recovery do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: true)
      field(:max_attempts, :integer, default: 5)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:enabled, :max_attempts], empty_values: [])
      |> validate_number(:max_attempts, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:pi, Pi, on_replace: :update, defaults_to_struct: true)
    embeds_one(:orchestration, Orchestration, on_replace: :update, defaults_to_struct: true)
    embeds_one(:rollout, Rollout, on_replace: :update, defaults_to_struct: true)
    embeds_one(:pr, Pr, on_replace: :update, defaults_to_struct: true)
    embeds_one(:review, Review, on_replace: :update, defaults_to_struct: true)
    embeds_one(:merge, Merge, on_replace: :update, defaults_to_struct: true)
    embeds_one(:recovery, Recovery, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    normalized_config =
      config
      |> normalize_keys()
      |> drop_nil_values()

    case validate_policy_unknown_keys(normalized_config) do
      :ok ->
        normalized_config
        |> changeset()
        |> apply_action(:validate)
        |> case do
          {:ok, settings} ->
            {:ok, finalize_settings(settings)}

          {:error, changeset} ->
            {:error, {:invalid_workflow_config, format_errors(changeset)}}
        end

      {:error, message} ->
        {:error, {:invalid_workflow_config, message}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:pi, with: &Pi.changeset/2)
    |> cast_embed(:orchestration, with: &Orchestration.changeset/2)
    |> cast_embed(:rollout, with: &Rollout.changeset/2)
    |> cast_embed(:pr, with: &Pr.changeset/2)
    |> cast_embed(:review, with: &Review.changeset/2)
    |> cast_embed(:merge, with: &Merge.changeset/2)
    |> cast_embed(:recovery, with: &Recovery.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp finalize_settings(settings) do
    tracker = %{
      settings.tracker
      | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    pi = %{
      settings.pi
      | session_dir_name: normalize_pi_session_dir_name(settings.pi.session_dir_name),
        extension_paths: normalize_pi_extension_paths(settings.pi.extension_paths),
        thinking_level: normalize_pi_thinking_level(settings.pi.thinking_level),
        model: normalize_pi_model(settings.pi.model)
    }

    orchestration = %{
      settings.orchestration
      | phase_store: normalize_optional_string(settings.orchestration.phase_store) || "workpad",
        default_phase: normalize_optional_string(settings.orchestration.default_phase) || "implementing",
        passive_phases: normalize_string_list(settings.orchestration.passive_phases),
        ownership: %{
          settings.orchestration.ownership
          | required_label: normalize_optional_string(settings.orchestration.ownership.required_label),
            required_workpad_marker: normalize_optional_string(settings.orchestration.ownership.required_workpad_marker)
        }
    }

    rollout = %{
      settings.rollout
      | mode: normalize_optional_string(settings.rollout.mode) || "mutate",
        kill_switch_label: normalize_optional_string(settings.rollout.kill_switch_label),
        kill_switch_file: normalize_optional_path(settings.rollout.kill_switch_file)
    }

    pr = %{
      settings.pr
      | base_branch: normalize_optional_string(settings.pr.base_branch) || "main",
        closed_pr_policy: normalize_optional_string(settings.pr.closed_pr_policy) || "new_branch",
        required_labels: normalize_string_list(settings.pr.required_labels),
        review_comment_mode: normalize_optional_string(settings.pr.review_comment_mode) || "off",
        review_comment_marker: normalize_optional_string(settings.pr.review_comment_marker)
    }

    review = %{
      settings.review
      | agent: normalize_optional_string(settings.review.agent),
        output_format: normalize_optional_string(settings.review.output_format),
        fix_consideration_severities: normalize_string_list(settings.review.fix_consideration_severities),
        model: normalize_pi_model(settings.review.model),
        thinking_level: normalize_pi_thinking_level(settings.review.thinking_level)
    }

    merge = %{
      settings.merge
      | mode: normalize_optional_string(settings.merge.mode) || "disabled",
        executor: normalize_optional_string(settings.merge.executor),
        method: normalize_optional_string(settings.merge.method) || "squash",
        strategy:
          normalize_optional_string(settings.merge.strategy) ||
            default_merge_strategy(normalize_optional_string(settings.merge.mode) || "disabled"),
        approval_states: normalize_string_list(settings.merge.approval_states),
        completion_state: normalize_optional_string(settings.merge.completion_state)
    }

    %{
      settings
      | tracker: tracker,
        workspace: workspace,
        codex: codex,
        pi: pi,
        orchestration: orchestration,
        rollout: rollout,
        pr: pr,
        review: review,
        merge: merge
    }
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value), do: stringify_key(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp normalize_pi_session_dir_name(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        ".pi-rpc-sessions"

      Path.type(trimmed) == :absolute ->
        ".pi-rpc-sessions"

      String.contains?(trimmed, ["..", <<0>>]) ->
        ".pi-rpc-sessions"

      true ->
        Path.basename(trimmed)
    end
  end

  defp normalize_pi_session_dir_name(_value), do: ".pi-rpc-sessions"

  defp normalize_pi_extension_paths(paths) when is_list(paths) do
    workflow_dir = Workflow.workflow_file_path() |> Path.dirname() |> Path.expand()

    paths
    |> Enum.map(&normalize_pi_extension_path(&1, workflow_dir))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_pi_extension_paths(_paths), do: []

  defp normalize_pi_extension_path(path, workflow_dir) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" ->
        nil

      String.contains?(trimmed, <<0>>) ->
        nil

      true ->
        Path.expand(trimmed, workflow_dir)
    end
  end

  defp normalize_pi_extension_path(_path, _workflow_dir), do: nil

  defp normalize_pi_model(%PiModel{} = model) do
    provider = normalize_optional_string(model.provider)
    model_id = normalize_optional_string(model.model_id)

    if is_binary(provider) and is_binary(model_id) do
      %{model | provider: provider, model_id: model_id}
    else
      nil
    end
  end

  defp normalize_pi_model(_model), do: nil

  defp normalize_pi_thinking_level(value) when is_binary(value), do: normalize_optional_string(value)
  defp normalize_pi_thinking_level(_value), do: nil

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_optional_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(_values), do: []

  defp normalize_optional_path(value) when is_binary(value) do
    workflow_dir = Workflow.workflow_file_path() |> Path.dirname() |> Path.expand()

    value
    |> normalize_optional_string()
    |> case do
      nil -> nil
      trimmed -> Path.expand(trimmed, workflow_dir)
    end
  end

  defp normalize_optional_path(_value), do: nil

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp default_merge_strategy("auto"), do: "queue"
  defp default_merge_strategy(_mode), do: "immediate"

  defp validate_policy_unknown_keys(config) when is_map(config) do
    checks = [
      {"orchestration", ["phase_store", "default_phase", "passive_phases", "max_rework_cycles", "ownership"]},
      {"orchestration.ownership", ["required_label", "required_workpad_marker"]},
      {"rollout", ["mode", "preflight_required", "kill_switch_label", "kill_switch_file"]},
      {"pr", ["auto_create", "base_branch", "repo_slug", "reuse_branch_pr", "closed_pr_policy", "attach_to_tracker", "required_labels", "review_comment_mode", "review_comment_marker"]},
      {"review", ["enabled", "agent", "output_format", "max_passes", "fix_consideration_severities", "model", "thinking_level"]},
      {"merge", ["mode", "executor", "method", "strategy", "max_rebase_attempts", "require_green_checks", "require_head_match", "require_human_approval", "approval_states", "completion_state"]},
      {"recovery", ["enabled", "max_attempts"]}
    ]

    case Enum.find_value(checks, &unknown_key_error(config, &1)) do
      nil -> :ok
      message -> {:error, message}
    end
  end

  defp unknown_key_error(config, {path, allowed_keys}) do
    case get_path(config, String.split(path, ".")) do
      %{} = section ->
        section
        |> Map.keys()
        |> Enum.reject(&(&1 in allowed_keys))
        |> Enum.sort()
        |> case do
          [] -> nil
          unknown_keys -> "#{path} has unknown keys: #{Enum.join(unknown_keys, ", ")}"
        end

      _ ->
        nil
    end
  end

  defp get_path(value, []), do: value

  defp get_path(value, [segment | rest]) when is_map(value) do
    value
    |> Map.get(segment)
    |> get_path(rest)
  end

  defp get_path(_value, _segments), do: nil

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
