# Observability API

Status: implemented for `/api/v1` run-oriented observability endpoints.

This document describes the JSON API exposed by the Symphony orchestrator for dashboards, operator consoles, and Intern-style Mission Control clients.

## Compatibility

Existing legacy endpoints remain available. Response shapes are preserved for normal successful reads; `GET /api/v1/transcript/:issue_identifier` is now backed by the same safe artifact reader as the run logs endpoint, so it can additionally return explicit safety/read errors instead of reading arbitrary session paths.

- `GET /api/v1/state`
- `POST /api/v1/refresh`
- `GET /api/v1/:issue_identifier`
- `GET /api/v1/transcript/:issue_identifier` — compatibility adapter over `kind=session`, preserving the legacy 500-entry cap
- `GET /api/v1/workspaces`
- `POST /api/v1/workspaces/cleanup`

The run-oriented endpoints below are additive. Routes under `/api/v1/runs/*` are registered before the legacy `/api/v1/:issue_identifier` wildcard. Legacy workspace listing/cleanup now derives active workspace identifiers from the orchestrator snapshot rather than making live tracker reads; cleanup fails closed if active workspaces cannot be determined.

## Error shape

All new endpoints use this error shape:

```json
{
  "error": {
    "code": "issue_not_found",
    "message": "Issue not found"
  }
}
```

Common statuses:

| Status | Code | Meaning |
|---:|---|---|
| 400 | `invalid_kind` | Unsupported log/artifact kind |
| 400 | `not_regular_file` | Artifact path exists but is not a regular file |
| 403 | `unsafe_path` | Snapshot-known artifact path is outside allowed roots or escapes via symlink |
| 404 | `issue_not_found` | Issue is not present in the current orchestrator snapshot |
| 404 | `no_artifact_path` | No snapshot-known artifact path exists for the requested log kind |
| 404 | `read_failed` | Artifact file could not be read |
| 405 | `method_not_allowed` | Route exists, but not for the requested method |
| 422 | `pr_refresh_skipped` | Live PR refresh lacks required PR context, such as repo or PR number |
| 502 | `pr_refresh_failed` | Live PR refresh attempted a read-only GitHub call and failed |
| 200 | `snapshot_timeout` / `snapshot_unavailable` | `GET /api/v1/runs` embeds snapshot read failures in the response body for list-view compatibility. |
| 503 | `snapshot_timeout` / `snapshot_unavailable` | Detail endpoints that need a specific run could not read the orchestrator snapshot. |
| 504 | `pr_refresh_timeout` | Live PR refresh exceeded its timeout |

## Pagination

### Run list cursor

`GET /api/v1/runs` uses issue identifier cursors.

- default `limit`: `100`
- hard max `limit`: `500`
- `cursor`: last issue identifier returned by the previous page

Response:

```json
{
  "page_info": {
    "next_cursor": "NEX-123",
    "has_next_page": true,
    "limit": 100
  }
}
```

### Event cursor

Event endpoints use event IDs like `evt_0000000001`.

- default `limit`: `100`
- hard max `limit`: `500`
- `cursor`: last event ID returned by the previous page
- `direction`: `forward` (default) or `backward`
- `type`: optional comma-separated event type filter, e.g. `worker,phase`

Response:

```json
{
  "page_info": {
    "next_cursor": "evt_0000000002",
    "has_next_page": false
  }
}
```

## Endpoints

### `GET /api/v1/runs`

Lists active/retrying/tracked runs from the orchestrator snapshot.

Query params:

| Param | Default | Description |
|---|---|---|
| `status` | `active,retrying,tracked` | Comma-separated final run statuses. `running` is accepted as an alias for `active`. |
| `limit` | `100` | Page size, capped at `500`. |
| `cursor` | none | Issue identifier from previous `page_info.next_cursor`. |

This endpoint is snapshot-only. It does not call Linear, GitHub, git, or the filesystem. If the orchestrator snapshot times out or is unavailable, the endpoint returns HTTP 200 with an embedded `error` object so polling list clients can keep rendering their existing shell.

Example response:

```json
{
  "generated_at": "2026-05-11T10:15:30Z",
  "counts": {
    "active": 1,
    "retrying": 0,
    "tracked": 3,
    "needs_attention": 1,
    "merge_queued": 1
  },
  "runs": [
    {
      "issue": {
        "id": "issue-id",
        "identifier": "NEX-123",
        "title": "Fix checkout flow",
        "url": "https://linear.app/...",
        "state": "In Progress",
        "labels": ["symphony"],
        "priority": 2
      },
      "runtime": {
        "status": "active",
        "phase": "implementing",
        "phase_class": "active",
        "dispatch_allowed": false,
        "next_intended_action": "continue_worker",
        "waiting_reason": null,
        "started_at": "2026-05-11T10:10:00Z",
        "last_event_at": "2026-05-11T10:15:00Z"
      },
      "worker": {
        "runtime": "pi",
        "session_id": "session-id",
        "pid": 12345,
        "turn_count": 3,
        "last_event": "notification",
        "last_message": "Running tests",
        "tokens": {"input": 1000, "output": 500, "total": 1500}
      },
      "workspace": {
        "path": "/tmp/symphony-workspaces/NEX-123",
        "branch": "symphony/NEX-123",
        "host": null,
        "exists": null,
        "stale": null
      },
      "pr": {
        "repo_slug": "owner/repo",
        "number": 77,
        "url": "https://github.com/owner/repo/pull/77",
        "state": null,
        "head_sha": "abc123",
        "draft": null,
        "checks": {"state": "pending", "passing": 1, "pending": 1, "failing": 0, "total": 2},
        "review": {"state": "current", "decision": "APPROVED", "passes_completed": 1},
        "mergeability": {"state": "pass", "mergeable": "MERGEABLE", "merge_state_status": "CLEAN"},
        "last_observed_at": "2026-05-11T10:15:00Z"
      },
      "attention": {
        "required": false,
        "reason": null,
        "severity": "info"
      }
    }
  ],
  "page_info": {
    "next_cursor": "NEX-123",
    "has_next_page": false,
    "limit": 100
  }
}
```

### `GET /api/v1/runs/:issue_identifier`

Returns a single run projection. Extends the list payload with attempts, proof artifacts, workpad metadata, and dependencies.

Example response:

```json
{
  "generated_at": "2026-05-11T10:15:30Z",
  "run": {
    "issue": {},
    "runtime": {},
    "worker": {},
    "workspace": {},
    "pr": {},
    "attention": {},
    "attempts": {
      "current": 2,
      "max": 5,
      "restart_count": 1,
      "retry_due_at": "2026-05-11T10:20:00Z",
      "last_error": "turn_timeout",
      "error_classification": "transient"
    },
    "proof": {
      "dir": "/tmp/.../proof",
      "events_path": "/tmp/.../proof/events.jsonl",
      "summary_path": "/tmp/.../proof/summary.json",
      "html_path": null
    },
    "workpad": {
      "comment_id": "comment-id",
      "metadata_status": "ok",
      "phase_source": "workpad",
      "metadata": {}
    },
    "dependencies": {
      "blocked_by": [],
      "blocks": []
    }
  }
}
```

### `GET /api/v1/events`

Returns a global event feed across all issues.

Query params:

| Param | Description |
|---|---|
| `cursor` | Event ID cursor, e.g. `evt_0000000001`. |
| `limit` | Page size, capped at `500`. |
| `type` | Optional comma-separated event types, e.g. `worker,phase`. |
| `direction` | `forward` or `backward`. |

Example response:

```json
{
  "events": [
    {
      "id": "evt_0000000001",
      "sequence": 1,
      "at": "2026-05-11T10:15:01Z",
      "type": "worker",
      "name": "notification",
      "source": "pi",
      "severity": "info",
      "summary": "notification",
      "issue_id": "issue-id",
      "issue_identifier": "NEX-123",
      "run_id": null,
      "session_id": "session-id",
      "turn": 1,
      "payload": {"event": "notification", "session_id": "session-id"},
      "redacted?": true
    }
  ],
  "page_info": {"next_cursor": "evt_0000000001", "has_next_page": false}
}
```

Event storage is an in-memory bounded read model. It keeps sanitized payloads only and resets on process restart.

### `GET /api/v1/runs/:issue_identifier/events`

Returns the event feed for one issue.

Query params are the same as `GET /api/v1/events`.

Example response:

```json
{
  "issue_identifier": "NEX-123",
  "events": [],
  "page_info": {"next_cursor": null, "has_next_page": false}
}
```

### `GET /api/v1/runs/:issue_identifier/transitions`

Returns phase-transition events for one issue. This endpoint is a convenience projection over phase events.

Query params:

| Param | Description |
|---|---|
| `cursor` | Event ID cursor. |
| `limit` | Page size, capped at `500`. |
| `direction` | `forward` or `backward`. |

Example response:

```json
{
  "issue_identifier": "NEX-123",
  "transitions": [
    {
      "id": "evt_0000000042",
      "at": "2026-05-11T10:12:00Z",
      "from": "implementing",
      "to": "waiting_for_checks",
      "tracker_state_from": "In Progress",
      "tracker_state_to": "In Review",
      "waiting_reason": "checks_pending",
      "next_intended_action": "poll_on_next_cycle",
      "source": "poll_reconcile",
      "workpad_comment_id": "comment-id"
    }
  ],
  "page_info": {"next_cursor": "evt_0000000042", "has_next_page": false}
}
```

### `GET /api/v1/runs/:issue_identifier/workspace`

Returns detail-only workspace status.

This endpoint is local-only:

- no Linear calls
- no GitHub calls
- local git inspection is bounded to 1 second
- remote-worker workspaces are not inspected locally

Example response:

```json
{
  "issue_identifier": "NEX-123",
  "workspace": {
    "path": "/tmp/symphony-workspaces/NEX-123",
    "exists": true,
    "root": "/tmp/symphony-workspaces",
    "branch": "symphony/NEX-123",
    "head_sha": "abc123",
    "remote_branch_published": false,
    "dirty": true,
    "stale": null,
    "age_hours": 2.5,
    "host": null,
    "session_dir": "/tmp/.../.pi-session",
    "proof_dir": "/tmp/.../.pi-session/proof",
    "source": "snapshot+local_git"
  }
}
```

### `GET /api/v1/runs/:issue_identifier/pr`

Returns PR/check/review/mergeability status.

Query params:

| Param | Default | Description |
|---|---|---|
| `refresh` | `false` | When false, returns cached snapshot/workpad data only. When true, performs a bounded read-only `gh pr view`. |

Default cached reads do not call Linear or GitHub.

`refresh=true` behavior:

- uses `PullRequests.inspect_state/2`
- calls `gh pr view` only
- does not mutate GitHub, Linear, or workpad metadata
- times out and returns `504 pr_refresh_timeout` if GitHub inspection is too slow
- returns `422 pr_refresh_skipped` when required PR context is absent

Example cached response:

```json
{
  "issue_identifier": "NEX-123",
  "pr": {
    "repo_slug": "owner/repo",
    "number": 77,
    "url": "https://github.com/owner/repo/pull/77",
    "state": "open",
    "draft": false,
    "head_sha": "abc123",
    "base_branch": "main",
    "checks": {"state": "pass", "passing": 6, "pending": 0, "failing": 0, "total": 6, "items": []},
    "review": {
      "decision": "APPROVED",
      "symphony_review_state": "current",
      "passes_completed": 1,
      "last_reviewed_head_sha": "abc123",
      "current_for_head": true
    },
    "mergeability": {"state": "pass", "mergeable": "MERGEABLE", "merge_state_status": "CLEAN"},
    "gates": {
      "pr": "open",
      "checks": "pass",
      "review": "current",
      "human_approval": "approved",
      "mergeability": "pass",
      "ownership": null,
      "kill_switch": null,
      "dispatch": null
    },
    "merge": {
      "last_attempted_head_sha": "abc123",
      "last_merged_head_sha": null,
      "failure_reason": null,
      "last_attempted_at": null,
      "last_merged_at": null
    },
    "next_intended_action": "merge_when_green",
    "last_observed_at": "2026-05-11T10:15:00Z",
    "source": "cached"
  }
}
```

Live responses have the same shape with `source: "live"` and GitHub-derived `state`, `draft`, `head_sha`, checks, review decision, and mergeability.

### `GET /api/v1/runs/:issue_identifier/logs`

Safely reads snapshot-known worker/session/proof artifacts.

Query params:

| Param | Default | Description |
|---|---:|---|
| `kind` | `session` | One of `session`, `proof_events`, `proof_summary`, `stderr`. |
| `offset` | `0` | Byte offset. Negative or invalid values become `0`. |
| `limit_bytes` | `65536` | Read limit, capped at `1048576`. |

Safety rules:

- The API never accepts a raw file path from the client.
- `kind=session` resolves only explicit `session_file` metadata.
- `kind=proof_events` resolves only explicit `proof_events_path` metadata.
- `kind=proof_summary` resolves only explicit `proof_summary_path` metadata.
- `kind=stderr` resolves only explicit stderr metadata.
- Resolved paths must exactly match snapshot-known metadata.
- Resolved paths must be under `Config.settings!().workspace.root` or the configured log file directory.
- Symlinks are resolved and cannot escape allowed roots.
- Only regular files are read.

JSONL response example:

```json
{
  "issue_identifier": "NEX-123",
  "kind": "session",
  "path": "/tmp/.../session.jsonl",
  "file": "session.jsonl",
  "offset": 0,
  "limit_bytes": 65536,
  "bytes_read": 128,
  "truncated": false,
  "next_offset": null,
  "size_bytes": 128,
  "entries": [
    {"event": "started"},
    {"raw": "not-json"}
  ]
}
```

`proof_summary` response example:

```json
{
  "issue_identifier": "NEX-123",
  "kind": "proof_summary",
  "summary": {"ok": true}
}
```

`stderr` response example:

```json
{
  "issue_identifier": "NEX-123",
  "kind": "stderr",
  "content": "stderr text",
  "encoding": "utf-8",
  "bytes_read": 1024,
  "truncated": true,
  "next_offset": 1024
}
```

Binary non-UTF-8 content is base64 encoded with `encoding: "base64"`.

## Event redaction

Worker updates can include arbitrary tool output, user content, or credentials. The event store intentionally records a small safe payload only:

- event name
- session ID
- turn number
- numeric usage counters
- payload type
- assistant-message event type

Raw worker payloads and message text are not exposed through event payloads or summaries. Sensitive keys such as `authorization`, `api_key`, `token`, `secret`, `password`, and `raw` are redacted when generic events are appended.

## Implementation files

Core modules:

- `orchestrator/elixir/lib/symphony_elixir/observability/run_snapshot.ex`
- `orchestrator/elixir/lib/symphony_elixir/observability/event_store.ex`
- `orchestrator/elixir/lib/symphony_elixir/observability/phase_transition.ex`
- `orchestrator/elixir/lib/symphony_elixir/observability/workspace_status.ex`
- `orchestrator/elixir/lib/symphony_elixir/observability/pr_status.ex`
- `orchestrator/elixir/lib/symphony_elixir/observability/artifact_reader.ex`
- `orchestrator/elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`
- `orchestrator/elixir/lib/symphony_elixir_web/router.ex`

Tests:

- `orchestrator/elixir/test/symphony_elixir/observability_runs_api_test.exs`
- `orchestrator/elixir/test/symphony_elixir/observability_event_store_test.exs`
