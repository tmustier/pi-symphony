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
    - Rework
    - Human Review
    - Merging
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

{% if issue.description %}
Description:
{{ issue.description }}
{% else %}
Description:
No description provided.
{% endif %}

Operating rules:
1. Work only inside the provided workspace.
2. Do not ask a human for follow-up actions unless blocked by missing auth, permissions, or required tools.
3. Keep tracker state accurate using the available tracker bridge/tooling.
4. Prefer small, reviewable commits on the issue branch.
5. Final output should summarize completed work, validation run, blockers, and proof artifacts only.

If this is a continuation attempt, resume from the current workspace/session state instead of restarting from scratch.
