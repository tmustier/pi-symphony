# WORKFLOW.md Configuration Reference

The WORKFLOW.md file uses YAML frontmatter to configure symphony. Below is the full field reference.

## tracker

| Field | Required | Description |
|---|---|---|
| `kind` | yes | Tracker type. Currently only `linear`. |
| `api_key` | yes | Linear API key. Use `"$LINEAR_API_KEY"` to read from env. |
| `team_key` | yes | Linear team prefix (e.g. "THO"). Primary safety boundary. |
| `project_slug` | no | Linear project slug ID — the short hash at the end of the project URL. For example, if the project URL is `https://linear.app/my-org/project/my-project-abc123def456`, the slug is `abc123def456`. This is **not** the full UUID or the project name. Find it by opening the project in Linear and copying the trailing hash from the URL. |
| `active_states` | yes | Linear states symphony treats as active (polls and dispatches). |
| `terminal_states` | yes | Linear states that mean "done" (symphony stops tracking). |

## polling

| Field | Default | Description |
|---|---|---|
| `interval_ms` | 30000 | How often to poll Linear for changes (milliseconds). |

## workspace

| Field | Required | Description |
|---|---|---|
| `root` | yes | Directory where symphony creates per-issue workspaces. Must exist. Supports `$ENV_VAR` expansion. |

## worker

| Field | Default | Description |
|---|---|---|
| `runtime` | `pi` | Worker runtime. Use `pi`. |

## agent

| Field | Default | Description |
|---|---|---|
| `max_concurrent_agents` | 4 | Maximum parallel workers across this symphony instance. |
| `max_turns` | 8 | Maximum conversation turns per worker before forced stop. |
| `max_retry_backoff_ms` | 300000 | Maximum backoff between retries (5 minutes). |

## pi

Worker process configuration.

| Field | Default | Description |
|---|---|---|
| `command` | `pi` | Path to the pi binary. Use absolute path if pi isn't in PATH. |
| `response_timeout_ms` | 60000 | Timeout waiting for a Pi RPC response. |
| `session_dir_name` | `.pi-rpc-sessions` | Subdirectory name for Pi session files within the workspace. |
| `model.provider` | — | Model provider (e.g. `anthropic`, `openai-codex`). |
| `model.model_id` | — | Model ID. Use current models only: `claude-opus-4-6` (best), `claude-sonnet-4-6` (fast), `gpt-5.4`. Do NOT use deprecated dated models like `claude-sonnet-4-20250514`. |
| `thinking_level` | — | Thinking level for workers (`off`, `low`, `medium`, `high`, `xhigh`). |
| `extension_paths` | `[]` | Paths to worker extensions, resolved relative to WORKFLOW.md. |
| `disable_extensions` | `true` | Disable ambient extension discovery in workers. Recommended. |
| `disable_themes` | `true` | Disable ambient theme discovery in workers. |

## orchestration

| Field | Default | Description |
|---|---|---|
| `phase_store` | `workpad` | Where phase state is persisted. Use `workpad`. |
| `default_phase` | `implementing` | Phase assigned to newly dispatched issues. |
| `passive_phases` | `[]` | Phases where symphony polls but does not retry immediately. |
| `max_rework_cycles` | 3 | Maximum rework loops before moving to `blocked`. |
| `ownership.required_label` | — | Linear label required on issues for symphony to claim them. |
| `ownership.required_workpad_marker` | — | Heading marker in workpad comments that identifies symphony ownership. |

## rollout

Safety controls for progressive rollout.

| Field | Default | Description |
|---|---|---|
| `mode` | `observe` | Rollout mode: `observe` (read-only), `mutate` (create PRs, no merge), `merge` (full auto). |
| `preflight_required` | `true` | Whether preflight validation must pass before dispatch. |
| `kill_switch_label` | — | Linear label that immediately stops symphony for that issue. |
| `kill_switch_file` | — | Local file path — if this file exists, symphony pauses all work. |

## pr

PR automation settings.

| Field | Default | Description |
|---|---|---|
| `auto_create` | `true` | Automatically create PRs for completed work. |
| `base_branch` | `main` | Target branch for PRs. |
| `repo_slug` | — | GitHub `owner/repo`. Required for PR operations. |
| `reuse_branch_pr` | `true` | Reuse existing PR if the branch already has one. |
| `closed_pr_policy` | `new_branch` | What to do when the branch's PR was closed. |
| `attach_to_tracker` | `true` | Link PR URL back to the Linear issue. |
| `required_labels` | `[]` | Labels automatically added to created PRs. |
| `review_comment_mode` | `upsert` | How to manage the review comment (`upsert` = one living comment). |
| `review_comment_marker` | — | HTML comment marker to identify the symphony review comment. |

## review

Self-review configuration.

| Field | Default | Description |
|---|---|---|
| `enabled` | `true` | Whether workers run self-review after implementation. |
| `agent` | `pr-reviewer` | Subagent used for review. |
| `output_format` | `structured_markdown_v1` | Review output format. |
| `max_passes` | 2 | Maximum review-fix cycles. |
| `fix_consideration_severities` | `[P0, P1, P2]` | Which severity findings trigger fixes. |
| `model.provider` | — | Optional model provider for the review subagent (e.g. `anthropic`). When omitted, the worker's default model applies. |
| `model.model_id` | — | Optional model ID for the review subagent (e.g. `claude-sonnet-4-6`). |
| `thinking_level` | — | Optional thinking level for the review subagent (`off`, `low`, `medium`, `high`, `xhigh`). When omitted, the worker's default thinking level applies. |

## merge

Merge automation. Start with `mode: disabled`, then switch to `mode: auto` when you want symphony to merge on your behalf.

| Field | Default | Description |
|---|---|---|
| `mode` | `disabled` | Merge mode: `disabled` or `auto`. |
| `executor` | `gh` | Merge execution strategy / executor. |
| `method` | `squash` | Git merge method. With `strategy: queue`, use `squash` or `merge` — not `rebase`. |
| `strategy` | `queue` when `mode: auto`, otherwise `immediate` | Merge orchestration strategy. `queue` serializes merges in the orchestrator and auto-rebases remaining PRs; `immediate` preserves legacy immediate merge behavior. |
| `max_rebase_attempts` | `2` | How many times auto-rebase should retry transient API failures before giving up. |
| `require_green_checks` | `true` | Block merge until CI passes. |
| `require_head_match` | `true` | Block merge if HEAD changed since review. |
| `require_human_approval` | `true` | Require human to move issue to approval state before merge. |
| `approval_states` | `[Merging]` | Linear states that count as human merge approval. |

## hooks

| Field | Default | Description |
|---|---|---|
| `timeout_ms` | 60000 | Timeout for hook execution. |

## observability

| Field | Default | Description |
|---|---|---|
| `dashboard_enabled` | `true` | Serve the web dashboard. |
| `refresh_ms` | 1000 | Dashboard data refresh interval. |
| `render_interval_ms` | 16 | Dashboard render interval. |

## server

| Field | Default | Description |
|---|---|---|
| `port` | 4040 | HTTP port for dashboard and API. |
| `host` | `127.0.0.1` | Bind address. |
