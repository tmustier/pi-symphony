---
tracker:
  kind: linear
  api_key: "$LINEAR_API_KEY"
  team_key: "THO"
  project_slug: "10f58de5e214"
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
  root: ~/code/symphony-workspaces/booking-demo
hooks:
  after_create: |
    git clone --depth 1 git@github.com:Nexcade/booking-demo.git .
worker:
  runtime: pi
agent:
  max_concurrent_agents: 2
  max_turns: 12
  max_retry_backoff_ms: 300000
pi:
  command: pi
  response_timeout_ms: 120000
  session_dir_name: .pi-rpc-sessions
  model:
    provider: anthropic
    model_id: claude-opus-4-6
  thinking_level: xhigh
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
  mode: mutate
  preflight_required: false
  kill_switch_label: no-symphony-automation
  kill_switch_file: /tmp/pi-symphony-booking.pause
pr:
  auto_create: true
  base_branch: main
  repo_slug: Nexcade/booking-demo
  reuse_branch_pr: true
  closed_pr_policy: new_branch
  attach_to_tracker: true
  required_labels:
    - symphony
  review_comment_mode: upsert
  review_comment_marker: "<!-- symphony-review -->"
review:
  enabled: false
merge:
  mode: disabled
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

You are working on a Linear ticket `{{ issue.identifier }}` in the **Nexcade booking-demo** repository.

{% if attempt %}
Continuation context:
- This is retry attempt #{{ attempt }}. Resume from current workspace state.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. Read AGENTS.md, then relevant READMEs and feature docs before writing code.
2. This is an unattended session. Never ask a human for follow-up actions.
3. Only stop early for a true blocker (missing auth/permissions/secrets).
4. Implement on branch `{{ issue.branch_name }}`, created from `origin/main` if needed.
5. Validate: run `npm run build` and relevant tests from `frontends/booking-agent`.
6. Visually verify UI changes with agent-browser (see AGENTS.md for workflow).
7. Push and create a PR with a clear title and body.
8. Final message: completed actions and blockers only. No "next steps for user".

Work only in the provided repository copy.
