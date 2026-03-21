---
tracker:
  kind: linear
  api_key: "$LINEAR_API_KEY"
  team_key: "SYM"
  project_slug: "d63e7b02d039"
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
  root: ~/code/symphony-workspaces/pi-symphony
worker:
  runtime: pi
agent:
  max_concurrent_agents: 3
  max_turns: 12
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
    provider: anthropic
    model_id: claude-opus-4-6
  thinking_level: xhigh
  extension_paths:
    - ./extensions/workspace-guard/index.ts
    - ./extensions/proof/index.ts
    - ./extensions/linear-graphql/index.ts
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
  preflight_required: true
  kill_switch_label: no-symphony-automation
  kill_switch_file: /tmp/pi-symphony.pause
pr:
  auto_create: true
  base_branch: main
  repo_slug: tmustier/pi-symphony
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
  # TODO(SYM-21): model/thinking_level for review not yet supported in schema
  # model:
  #   provider: openai-codex
  #   model_id: gpt-5.4
  # thinking_level: high
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
  port: 4042
  host: 127.0.0.1
---

You are working on the pi-symphony orchestrator codebase itself.

## Project context

pi-symphony is an unattended issue orchestration system for Pi. It polls Linear for issues,
creates isolated workspaces, launches Pi coding workers in RPC mode, and manages the full
PR lifecycle. The orchestrator is written in Elixir/OTP; worker extensions are TypeScript.

## Required reading before implementation

1. Read `AGENTS.md` — project conventions and quality bar
2. Read `docs/DEV.md` — development workflow, build commands, test commands
3. Read `docs/PLAN.md` — architecture and module boundaries
4. Read the `agent-friendly-design` skill at `~/.pi/agent/skills/agent-friendly-design/SKILL.md` —
   all interfaces in this project (CLIs, config formats, error messages, dashboard APIs) are
   consumed by AI agents as the primary user. Design for agent operability:
   - Structured JSON output for machine consumption
   - Classified errors with retryable flags and recovery hints
   - Progressive disclosure in context files
   - Idempotent operations where possible

## Repo shape

```
orchestrator/elixir/  — Elixir/OTP orchestrator (main codebase)
extensions/           — Pi worker extensions (TypeScript)
skills/               — Pi skill for operating symphony
docs/                 — architecture, contracts, developer docs
examples/             — fixtures and sample workflows
```

## Quality bar

### Elixir
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test`
- `credo --strict`
- `dialyzer`
- All public functions must have `@spec` annotations

### TypeScript
- `tsc --noEmit` with strict settings
- No `any`, no `as` casts, no `@ts-ignore`

### Before pushing
Run `make check` from the repo root — it runs all quality checks for both languages.

## Model selection — MANDATORY

Your training data contains outdated model names. DO NOT use model names from memory.

### Current models (March 2026)
- `anthropic/claude-opus-4-6` — best overall, use for complex work
- `anthropic/claude-sonnet-4-6` — fast, use for straightforward tasks
- `anthropic/claude-haiku-4-5` — lightweight tasks
- `openai-codex/gpt-5.4` — alternative frontier model

### Deprecated — DO NOT USE
- claude-sonnet-4-20250514, claude-sonnet-4-0, claude-sonnet-4-5
- claude-opus-4-0, claude-opus-4-1, claude-opus-4-5
- claude-3-5-sonnet, claude-3-7-sonnet
- Any model with a date suffix like -20250514

When invoking subagents, use `anthropic/claude-opus-4-6` with `xhigh` thinking.
If unsure about a model name, run `pi --list-models` to verify.
