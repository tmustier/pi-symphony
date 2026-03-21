---
tracker:
  kind: linear
  api_key: "$LINEAR_API_KEY"
  team_key: "TEAMKEY"
  # Optional extra narrowing inside the team:
  # project_slug: "$LINEAR_PROJECT_SLUG"
  active_states:
    - Todo
    - In Progress
    - In Review
    - Merging
    - Rework
  terminal_states:
    - Done
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
polling:
  interval_ms: 30000
workspace:
  root: "$PI_SYMPHONY_WORKSPACE_ROOT"
worker:
  runtime: pi
agent:
  max_concurrent_agents: 4
  max_turns: 8
  max_retry_backoff_ms: 300000
  max_retries: 10
codex:
  turn_timeout_ms: 3600000
  read_timeout_ms: 5000
  stall_timeout_ms: 300000
pi:
  command: pi
  response_timeout_ms: 60000
  session_dir_name: .pi-rpc-sessions
  model:
    provider: anthropic
    model_id: claude-opus-4-6
  thinking_level: xhigh
  extension_paths:
    - ../extensions/workspace-guard/index.ts
    - ../extensions/proof/index.ts
    - ../extensions/linear-graphql/index.ts
  disable_extensions: true
  disable_themes: true
orchestration:
  phase_store: workpad
  default_phase: implementing
  passive_phases:
    - waiting_for_checks
    - waiting_for_human
    - blocked
  max_rework_cycles: 3
  ownership:
    required_label: symphony
    required_workpad_marker: "## Symphony Workpad"
rollout:
  mode: observe
  preflight_required: true
  kill_switch_label: no-symphony-automation
  kill_switch_file: /tmp/pi-symphony.pause
pr:
  auto_create: true
  base_branch: main
  repo_slug: owner/repo
  reuse_branch_pr: true
  closed_pr_policy: new_branch
  attach_to_tracker: true
  required_labels:
    - symphony
  review_comment_mode: upsert
  review_comment_marker: "<!-- symphony-review -->"
review:
  enabled: true
  agent: pr-reviewer
  output_format: structured_markdown_v1
  max_passes: 2
  fix_consideration_severities:
    - P0
    - P1
    - P2
recovery:
  enabled: true
  max_attempts: 5
merge:
  mode: disabled
  executor: land_skill
  method: squash
  require_green_checks: true
  require_head_match: true
  require_human_approval: true
  approval_states:
    - Merging
hooks:
  timeout_ms: 60000
observability:
  dashboard_enabled: true
  refresh_ms: 1000
  render_interval_ms: 16
server:
  port: 4040
  host: 127.0.0.1
---

<!-- Prompt template below. Leave empty to use the built-in default prompt. -->
<!-- The default prompt tells the agent to: read the codebase, implement the issue -->
<!-- on the specified branch, validate, self-review, push, and create a PR. -->
<!-- Override here only if you need repo-specific instructions beyond what -->
<!-- AGENTS.md in the target repo provides. -->
