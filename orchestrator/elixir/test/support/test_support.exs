defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.OrchestrationLifecycle
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.PullRequests
      alias SymphonyElixir.ReviewArtifact
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workpad
      alias SymphonyElixir.Workspace
      alias SymphonyElixir.WorkspaceGit

      import SymphonyElixir.TestSupport,
        only: [write_workflow_file!: 1, write_workflow_file!: 2, restore_env: 2, stop_default_http_server: 0]

      setup do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        {:ok, _apps} = Application.ensure_all_started(:symphony_elixir)
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def stop_default_http_server do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) ->
        case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
               {SymphonyElixir.HttpServer, _child_pid, _type, _modules} -> true
               _child -> false
             end) do
          {SymphonyElixir.HttpServer, child_pid, _type, _modules} when is_pid(child_pid) ->
            :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

            if Process.alive?(child_pid) do
              Process.exit(child_pid, :normal)
            end

            :ok

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_team_key: nil,
          tracker_assignee: nil,
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_runtime: nil,
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          codex_command: "codex app-server",
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          pi_command: nil,
          pi_response_timeout_ms: nil,
          pi_session_dir_name: nil,
          pi_extension_paths: [],
          pi_model_provider: nil,
          pi_model_id: nil,
          pi_thinking_level: nil,
          pi_disable_extensions: nil,
          pi_disable_themes: nil,
          orchestration_phase_store: "workpad",
          orchestration_default_phase: "implementing",
          orchestration_passive_phases: ["waiting_for_checks", "waiting_for_human", "blocked"],
          orchestration_max_rework_cycles: 3,
          orchestration_required_label: nil,
          orchestration_required_workpad_marker: nil,
          rollout_mode: "mutate",
          rollout_preflight_required: false,
          rollout_kill_switch_label: nil,
          rollout_kill_switch_file: nil,
          pr_auto_create: false,
          pr_base_branch: "main",
          pr_repo_slug: nil,
          pr_reuse_branch_pr: true,
          pr_closed_pr_policy: "new_branch",
          pr_attach_to_tracker: true,
          pr_required_labels: [],
          pr_review_comment_mode: "off",
          pr_review_comment_marker: "<!-- symphony-review -->",
          review_enabled: false,
          review_agent: nil,
          review_output_format: nil,
          review_max_passes: 1,
          review_fix_consideration_severities: [],
          merge_mode: "disabled",
          merge_executor: nil,
          merge_method: "squash",
          merge_strategy: nil,
          merge_max_rebase_attempts: 2,
          merge_require_green_checks: true,
          merge_require_head_match: true,
          merge_require_human_approval: true,
          merge_approval_states: [],
          merge_completion_state: nil,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_team_key = Keyword.get(config, :tracker_team_key)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_runtime = Keyword.get(config, :worker_runtime)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    codex_command = Keyword.get(config, :codex_command)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    pi_command = Keyword.get(config, :pi_command)
    pi_response_timeout_ms = Keyword.get(config, :pi_response_timeout_ms)
    pi_session_dir_name = Keyword.get(config, :pi_session_dir_name)
    pi_extension_paths = Keyword.get(config, :pi_extension_paths)
    pi_model_provider = Keyword.get(config, :pi_model_provider)
    pi_model_id = Keyword.get(config, :pi_model_id)
    pi_thinking_level = Keyword.get(config, :pi_thinking_level)
    pi_disable_extensions = Keyword.get(config, :pi_disable_extensions)
    pi_disable_themes = Keyword.get(config, :pi_disable_themes)
    orchestration_phase_store = Keyword.get(config, :orchestration_phase_store)
    orchestration_default_phase = Keyword.get(config, :orchestration_default_phase)
    orchestration_passive_phases = Keyword.get(config, :orchestration_passive_phases)
    orchestration_max_rework_cycles = Keyword.get(config, :orchestration_max_rework_cycles)
    orchestration_required_label = Keyword.get(config, :orchestration_required_label)
    orchestration_required_workpad_marker = Keyword.get(config, :orchestration_required_workpad_marker)
    rollout_mode = Keyword.get(config, :rollout_mode)
    rollout_preflight_required = Keyword.get(config, :rollout_preflight_required)
    rollout_kill_switch_label = Keyword.get(config, :rollout_kill_switch_label)
    rollout_kill_switch_file = Keyword.get(config, :rollout_kill_switch_file)
    pr_auto_create = Keyword.get(config, :pr_auto_create)
    pr_base_branch = Keyword.get(config, :pr_base_branch)
    pr_repo_slug = Keyword.get(config, :pr_repo_slug)
    pr_reuse_branch_pr = Keyword.get(config, :pr_reuse_branch_pr)
    pr_closed_pr_policy = Keyword.get(config, :pr_closed_pr_policy)
    pr_attach_to_tracker = Keyword.get(config, :pr_attach_to_tracker)
    pr_required_labels = Keyword.get(config, :pr_required_labels)
    pr_review_comment_mode = Keyword.get(config, :pr_review_comment_mode)
    pr_review_comment_marker = Keyword.get(config, :pr_review_comment_marker)
    review_enabled = Keyword.get(config, :review_enabled)
    review_agent = Keyword.get(config, :review_agent)
    review_output_format = Keyword.get(config, :review_output_format)
    review_max_passes = Keyword.get(config, :review_max_passes)
    review_fix_consideration_severities = Keyword.get(config, :review_fix_consideration_severities)
    merge_mode = Keyword.get(config, :merge_mode)
    merge_executor = Keyword.get(config, :merge_executor)
    merge_method = Keyword.get(config, :merge_method)
    merge_strategy = Keyword.get(config, :merge_strategy)
    merge_max_rebase_attempts = Keyword.get(config, :merge_max_rebase_attempts)
    merge_require_green_checks = Keyword.get(config, :merge_require_green_checks)
    merge_require_head_match = Keyword.get(config, :merge_require_head_match)
    merge_require_human_approval = Keyword.get(config, :merge_require_human_approval)
    merge_approval_states = Keyword.get(config, :merge_approval_states)
    merge_completion_state = Keyword.get(config, :merge_completion_state)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  team_key: #{yaml_value(tracker_team_key)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_runtime, worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        pi_yaml(%{
          command: pi_command,
          response_timeout_ms: pi_response_timeout_ms,
          session_dir_name: pi_session_dir_name,
          extension_paths: pi_extension_paths,
          model_provider: pi_model_provider,
          model_id: pi_model_id,
          thinking_level: pi_thinking_level,
          disable_extensions: pi_disable_extensions,
          disable_themes: pi_disable_themes
        }),
        orchestration_yaml(%{
          phase_store: orchestration_phase_store,
          default_phase: orchestration_default_phase,
          passive_phases: orchestration_passive_phases,
          max_rework_cycles: orchestration_max_rework_cycles,
          required_label: orchestration_required_label,
          required_workpad_marker: orchestration_required_workpad_marker
        }),
        rollout_yaml(%{
          mode: rollout_mode,
          preflight_required: rollout_preflight_required,
          kill_switch_label: rollout_kill_switch_label,
          kill_switch_file: rollout_kill_switch_file
        }),
        pr_yaml(%{
          auto_create: pr_auto_create,
          base_branch: pr_base_branch,
          repo_slug: pr_repo_slug,
          reuse_branch_pr: pr_reuse_branch_pr,
          closed_pr_policy: pr_closed_pr_policy,
          attach_to_tracker: pr_attach_to_tracker,
          required_labels: pr_required_labels,
          review_comment_mode: pr_review_comment_mode,
          review_comment_marker: pr_review_comment_marker
        }),
        review_yaml(%{
          enabled: review_enabled,
          agent: review_agent,
          output_format: review_output_format,
          max_passes: review_max_passes,
          fix_consideration_severities: review_fix_consideration_severities
        }),
        merge_yaml(%{
          mode: merge_mode,
          executor: merge_executor,
          method: merge_method,
          strategy: merge_strategy,
          max_rebase_attempts: merge_max_rebase_attempts,
          require_green_checks: merge_require_green_checks,
          require_head_match: merge_require_head_match,
          require_human_approval: merge_require_human_approval,
          approval_states: merge_approval_states,
          completion_state: merge_completion_state
        }),
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp orchestration_yaml(config) do
    [
      "orchestration:",
      "  phase_store: #{yaml_value(config.phase_store)}",
      "  default_phase: #{yaml_value(config.default_phase)}",
      "  passive_phases: #{yaml_value(config.passive_phases)}",
      "  max_rework_cycles: #{yaml_value(config.max_rework_cycles)}",
      "  ownership:",
      "    required_label: #{yaml_value(config.required_label)}",
      "    required_workpad_marker: #{yaml_value(config.required_workpad_marker)}"
    ]
    |> Enum.join("\n")
  end

  defp rollout_yaml(config) do
    [
      "rollout:",
      "  mode: #{yaml_value(config.mode)}",
      "  preflight_required: #{yaml_value(config.preflight_required)}",
      "  kill_switch_label: #{yaml_value(config.kill_switch_label)}",
      "  kill_switch_file: #{yaml_value(config.kill_switch_file)}"
    ]
    |> Enum.join("\n")
  end

  defp pr_yaml(config) do
    [
      "pr:",
      "  auto_create: #{yaml_value(config.auto_create)}",
      "  base_branch: #{yaml_value(config.base_branch)}",
      if(config[:repo_slug], do: "  repo_slug: #{yaml_value(config[:repo_slug])}", else: nil),
      "  reuse_branch_pr: #{yaml_value(config.reuse_branch_pr)}",
      "  closed_pr_policy: #{yaml_value(config.closed_pr_policy)}",
      "  attach_to_tracker: #{yaml_value(config.attach_to_tracker)}",
      "  required_labels: #{yaml_value(config.required_labels)}",
      "  review_comment_mode: #{yaml_value(config.review_comment_mode)}",
      "  review_comment_marker: #{yaml_value(config.review_comment_marker)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp review_yaml(config) do
    [
      "review:",
      "  enabled: #{yaml_value(config.enabled)}",
      "  agent: #{yaml_value(config.agent)}",
      "  output_format: #{yaml_value(config.output_format)}",
      "  max_passes: #{yaml_value(config.max_passes)}",
      "  fix_consideration_severities: #{yaml_value(config.fix_consideration_severities)}"
    ]
    |> Enum.join("\n")
  end

  defp merge_yaml(config) do
    [
      "merge:",
      "  mode: #{yaml_value(config.mode)}",
      "  executor: #{yaml_value(config.executor)}",
      "  method: #{yaml_value(config.method)}",
      "  strategy: #{yaml_value(config.strategy)}",
      "  max_rebase_attempts: #{yaml_value(config.max_rebase_attempts)}",
      "  require_green_checks: #{yaml_value(config.require_green_checks)}",
      "  require_head_match: #{yaml_value(config.require_head_match)}",
      "  require_human_approval: #{yaml_value(config.require_human_approval)}",
      "  approval_states: #{yaml_value(config.approval_states)}",
      "  completion_state: #{yaml_value(config.completion_state)}"
    ]
    |> Enum.join("\n")
  end

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(runtime, ssh_hosts, max_concurrent_agents_per_host)
       when runtime in [nil, false] and ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(runtime, ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      runtime not in [nil, false] && "  runtime: #{yaml_value(runtime)}",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp pi_yaml(%{
         command: nil,
         response_timeout_ms: nil,
         session_dir_name: nil,
         extension_paths: extension_paths,
         model_provider: nil,
         model_id: nil,
         thinking_level: nil,
         disable_extensions: nil,
         disable_themes: nil
       })
       when extension_paths in [nil, []],
       do: nil

  defp pi_yaml(config) do
    [
      "pi:",
      config.command && "  command: #{yaml_value(config.command)}",
      config.response_timeout_ms && "  response_timeout_ms: #{yaml_value(config.response_timeout_ms)}",
      config.session_dir_name && "  session_dir_name: #{yaml_value(config.session_dir_name)}",
      config.extension_paths not in [nil, []] && "  extension_paths: #{yaml_value(config.extension_paths)}",
      pi_model_yaml(config.model_provider, config.model_id),
      config.thinking_level && "  thinking_level: #{yaml_value(config.thinking_level)}",
      !is_nil(config.disable_extensions) &&
        "  disable_extensions: #{yaml_value(config.disable_extensions)}",
      !is_nil(config.disable_themes) && "  disable_themes: #{yaml_value(config.disable_themes)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp pi_model_yaml(nil, nil), do: nil

  defp pi_model_yaml(provider, model_id) do
    [
      "  model:",
      provider && "    provider: #{yaml_value(provider)}",
      model_id && "    model_id: #{yaml_value(model_id)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
