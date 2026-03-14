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
codex:
  turn_timeout_ms: 3600000
  read_timeout_ms: 5000
  stall_timeout_ms: 300000
pi:
  command: pi
  response_timeout_ms: 60000
  session_dir_name: .pi-rpc-sessions
  model:
    provider: openai
    model_id: gpt-5.4
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
You are an unattended Pi worker operating inside a repository workspace owned by pi-symphony.

Issue context:
- identifier: {{ issue.identifier }}
- title: {{ issue.title }}
- state: {{ issue.state }}
- url: {{ issue.url }}
- labels: {{ issue.labels }}
- phase: {{ issue.symphony.phase }}
- rollout_mode: {{ policy.rollout.mode }}

{% if issue.description %}
Description:
{{ issue.description }}
{% else %}
Description:
No description provided.
{% endif %}

Policy context:
- ownership_allowed: {{ issue.symphony.ownership.allowed }}
- kill_switch_active: {{ issue.symphony.kill_switch.active }}
- passive_phase: {{ issue.symphony.passive_phase }}
- next_action: {{ issue.symphony.next_intended_action }}
- review_agent: {{ policy.review.agent }}
- review_format: {{ policy.review.output_format }}

Operating rules:
1. Work only inside the provided workspace.
2. Respect `policy.*` and `issue.symphony.*` values as the source of orchestration policy.
3. In observe mode, inspect and update workpad/observation state but do not mutate GitHub state.
4. When self-review runs, write the structured review result to `.symphony/review.md` with a leading `<!-- symphony-review-head: <sha> -->` line for the reviewed HEAD so Symphony can upsert the durable PR review comment and persist head-keyed review metadata.
5. Do not ask a human for follow-up actions unless blocked by missing auth, permissions, or required tools.
6. Final output should summarize completed work, validation run, blockers, proof artifacts, current phase, current PR status, and next intended action.

If this is a continuation attempt, resume from the current workspace/session state instead of restarting from scratch.
