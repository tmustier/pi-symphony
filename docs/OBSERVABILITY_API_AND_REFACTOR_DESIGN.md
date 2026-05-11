# Observability API and Refactor Design

Status: proposed

## 1. Why this exists

We want an Intern-style operator surface for pi-symphony without making Intern, the dashboard, or a web UI the orchestration source of truth.

pi-symphony should remain the unattended control plane. It should expose enough stable read APIs for an external UI to answer:

- What is running now?
- What needs human attention?
- What did the worker just do?
- Where is the workspace?
- What is the PR/check/merge state?
- How did this issue move through orchestration phases?

The current observability surface works for a prototype, but it is too snapshot-shaped and tightly coupled to the orchestrator internals.

## 2. Current state

Current API routes live in:

- `orchestrator/elixir/lib/symphony_elixir_web/router.ex`
- `orchestrator/elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`
- `orchestrator/elixir/lib/symphony_elixir_web/presenter.ex`

Existing routes:

- `GET /api/v1/state`
- `POST /api/v1/refresh`
- `GET /api/v1/:issue_identifier`
- `GET /api/v1/transcript/:issue_identifier`
- `GET /api/v1/workspaces`
- `POST /api/v1/workspaces/cleanup`

Existing snapshot source:

- `SymphonyElixir.Orchestrator.snapshot/2`
- `handle_call(:snapshot, ...)` in `orchestrator.ex`

Current gaps:

- only the latest worker event is retained in the snapshot
- no cursor-based worker timeline
- no explicit phase-transition history
- PR/check state is compressed into workpad metadata / observation gates
- `Presenter` is a single large projection module
- `Orchestrator` is doing too much: polling, dispatch, retry, merge queue, worker supervision, metrics, snapshot projection, cleanup, dashboard notification
- read-only API paths sometimes do live tracker/filesystem work

## 3. Design principles

1. **Keep orchestration headless and deterministic.** The API is an observer/client of the control plane, not the owner of lifecycle decisions.
2. **Do not make `/state` bigger forever.** Add resource-oriented endpoints and stable DTOs.
3. **Events first for timelines.** Worker logs, phase changes, retries, PR updates, and merge events should be recorded as facts and projected for APIs.
4. **Read endpoints should be cheap by default.** Live GitHub/Linear refresh must be opt-in.
5. **Stable API contracts before UI work.** Add contract tests and docs before building an Intern-like frontend.
6. **Refactor behind facades.** Preserve existing public functions while extracting smaller modules.

## 4. Proposed API surface

Keep the current `/api/v1/state` and issue endpoints for compatibility. Add run-oriented endpoints under `/api/v1/runs` first. We can introduce `/api/v2` later if/when we break schemas.

### 4.1 List runs

```http
GET /api/v1/runs?status=active,retrying,tracked&include=workspace,pr,phase,worker
```

Purpose: Mission Control overview.

Response shape:

```json
{
  "generated_at": "2026-05-11T10:15:30Z",
  "counts": {
    "active": 2,
    "retrying": 1,
    "tracked": 12,
    "needs_attention": 3,
    "merge_queued": 1
  },
  "runs": [
    {
      "issue": {
        "id": "issue-uuid",
        "identifier": "NEX-123",
        "title": "Fix checkout flow",
        "url": "https://linear.app/...",
        "state": "In Review",
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
        "session_id": "NEX-123-turn-1",
        "pid": 4242,
        "turn_count": 3,
        "last_event": "tool_execution_started",
        "last_message": "Running tests",
        "tokens": {"input": 1200, "output": 400, "total": 1600}
      },
      "workspace": {
        "path": "/tmp/symphony-workspaces/NEX-123",
        "branch": "pi-symphony/NEX-123",
        "host": null,
        "exists": true,
        "stale": false
      },
      "pr": {
        "repo_slug": "Nexcade/booking-demo",
        "number": 77,
        "url": "https://github.com/Nexcade/booking-demo/pull/77",
        "state": "OPEN",
        "head_sha": "abc123",
        "draft": false,
        "checks": {"state": "pending", "passing": 2, "pending": 1, "failing": 0, "total": 3},
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
  ]
}
```

Notes:

- `status=active` maps to current `snapshot.running`.
- `status=retrying` maps to current `snapshot.retrying`.
- `status=tracked` maps to current `snapshot.tracked`.
- `attention` is derived from phase, waiting reason, gates, kill switch, retry exhaustion, and PR/check failures.
- The list endpoint must not call `gh` or do expensive git inspection.

### 4.2 Run detail

```http
GET /api/v1/runs/:issue_identifier
```

Purpose: slot detail page.

Extends the list run object with:

```json
{
  "run": {
    "attempts": {
      "current": 2,
      "max": 5,
      "restart_count": 1,
      "retry_due_at": "2026-05-11T10:20:00Z",
      "last_error": "turn_timeout",
      "error_classification": "transient"
    },
    "proof": {
      "dir": "/.../proof",
      "events_path": "/.../proof/events.jsonl",
      "summary_path": "/.../proof/summary.json",
      "html_path": "/.../session.html"
    },
    "workpad": {
      "comment_id": "comment-uuid",
      "metadata_status": "ok",
      "phase_source": "workpad",
      "metadata": {}
    },
    "dependencies": {
      "blocked_by": [{"id": "...", "identifier": "NEX-100"}],
      "blocks": [{"id": "...", "identifier": "NEX-200"}]
    }
  }
}
```

### 4.3 Worker events

```http
GET /api/v1/runs/:issue_identifier/events?cursor=<opaque>&limit=100&type=worker,phase,lifecycle&direction=forward
```

Purpose: live activity feed and resumable polling.

Response:

```json
{
  "issue_identifier": "NEX-123",
  "events": [
    {
      "id": "evt_0000000123",
      "at": "2026-05-11T10:15:01Z",
      "type": "worker",
      "name": "tool_execution_started",
      "session_id": "NEX-123-turn-1",
      "turn": 1,
      "severity": "info",
      "summary": "bash npm test",
      "payload": {"tool": "bash", "command": "npm test"}
    }
  ],
  "page_info": {
    "next_cursor": "evt_0000000124",
    "has_next_page": true
  }
}
```

Implementation rule: use a bounded event store; do not scrape the Pi session JSONL as the primary feed.

### 4.4 Worker logs and artifacts

```http
GET /api/v1/runs/:issue_identifier/logs?kind=session|proof_events|proof_summary|stderr&offset=0&limit_bytes=65536
```

Purpose: transcript/proof panes without loading huge files.

Rules:

- only serve paths already known from run/proof metadata
- validate paths are under configured workspace root or logs root
- default `limit_bytes` = 64 KiB
- hard cap = 1 MiB
- JSONL entries should parse to objects when possible, otherwise return bounded raw line text

### 4.5 Workspace detail

```http
GET /api/v1/runs/:issue_identifier/workspace
```

Response:

```json
{
  "issue_identifier": "NEX-123",
  "workspace": {
    "path": "/tmp/symphony-workspaces/NEX-123",
    "exists": true,
    "root": "/tmp/symphony-workspaces",
    "branch": "pi-symphony/NEX-123",
    "head_sha": "abc123",
    "remote_branch_published": true,
    "dirty": false,
    "stale": false,
    "age_hours": 2.5,
    "session_dir": "/.../.pi-rpc-sessions",
    "proof_dir": "/.../proof"
  }
}
```

Detail endpoint may run `WorkspaceGit.inspect_workspace/2`; list endpoint should not.

### 4.6 PR/check status

```http
GET /api/v1/runs/:issue_identifier/pr?refresh=false
```

Purpose: PR tab, check state, merge-readiness display.

Response:

```json
{
  "issue_identifier": "NEX-123",
  "pr": {
    "repo_slug": "Nexcade/booking-demo",
    "number": 77,
    "url": "https://github.com/Nexcade/booking-demo/pull/77",
    "state": "OPEN",
    "draft": false,
    "head_sha": "abc123",
    "base_branch": "main",
    "checks": {
      "state": "pass",
      "passing": 6,
      "pending": 0,
      "failing": 0,
      "total": 6,
      "items": []
    },
    "review": {
      "decision": "APPROVED",
      "symphony_review_state": "current",
      "passes_completed": 1,
      "last_reviewed_head_sha": "abc123"
    },
    "mergeability": {
      "state": "pass",
      "mergeable": "MERGEABLE",
      "merge_state_status": "CLEAN"
    },
    "gates": {
      "pr": "open",
      "checks": "pass",
      "review": "current",
      "human_approval": "approved",
      "mergeability": "pass"
    },
    "next_intended_action": "merge_when_green",
    "last_observed_at": "2026-05-11T10:15:00Z",
    "source": "cached"
  }
}
```

`refresh=false`:

- project from cached workpad metadata and observation gates
- no GitHub calls

`refresh=true`:

- call `PullRequests.inspect_state/2`
- return `source: "live"`
- do not mutate Linear/workpad from this read endpoint
- add a timeout

### 4.7 Phase transitions

```http
GET /api/v1/runs/:issue_identifier/transitions?limit=100
```

Response:

```json
{
  "issue_identifier": "NEX-123",
  "transitions": [
    {
      "id": "tr_0000000042",
      "at": "2026-05-11T10:12:00Z",
      "from": "implementing",
      "to": "waiting_for_checks",
      "tracker_state_from": "In Progress",
      "tracker_state_to": "In Review",
      "waiting_reason": "checks_pending",
      "next_intended_action": "poll_on_next_cycle",
      "source": "poll_reconcile",
      "workpad_comment_id": "comment-uuid"
    }
  ]
}
```

Record transitions by comparing previous tracked entry to new tracked entry. Do not duplicate identical repeated polls.

### 4.8 Global events

```http
GET /api/v1/events?cursor=<opaque>&limit=100&type=worker,phase,system
```

Purpose: global activity feed across all runs.

Optional future endpoint:

```http
GET /api/v1/events/stream
```

Start with cursor-polling. Add SSE after the read model is stable.

## 5. New observability modules

Add modules under:

```text
orchestrator/elixir/lib/symphony_elixir/observability/
```

Proposed modules:

- `EventStore` — bounded GenServer/ETS event ring with cursor pagination
- `EventNormalizer` — sanitize and summarize worker updates
- `PhaseTransition` — compare tracked entries and build transition events
- `RunSnapshot` — canonical run projection from orchestrator snapshot
- `PrStatus` — cached/live PR/check/review/mergeability projection
- `WorkspaceStatus` — workspace projection and optional git inspection
- `Attention` — derive human-attention state
- `ArtifactReader` — safe bounded reading of session/proof/log files
- `Service` — public observability service facade for controllers

Phoenix side:

```text
orchestrator/elixir/lib/symphony_elixir_web/controllers/observability_runs_controller.ex
orchestrator/elixir/lib/symphony_elixir_web/controllers/observability_events_controller.ex
orchestrator/elixir/lib/symphony_elixir_web/presenters/run_json.ex
orchestrator/elixir/lib/symphony_elixir_web/presenters/event_json.ex
```

## 6. Event store design

Event shape:

```elixir
%{
  id: "evt_0000000123",
  sequence: 123,
  issue_id: "issue-uuid",
  issue_identifier: "NEX-123",
  run_id: "NEX-123:attempt-2",
  at: ~U[2026-05-11 10:15:01Z],
  type: "worker",
  name: "tool_execution_started",
  source: "pi",
  severity: "info",
  summary: "bash npm test",
  payload: %{},
  redacted?: true
}
```

Recommended categories:

- `run.started`
- `run.completed`
- `run.failed`
- `worker.session_started`
- `worker.rpc_event`
- `worker.tool_started`
- `worker.tool_completed`
- `worker.heartbeat`
- `worker.rate_limit`
- `phase.changed`
- `pr.resolved`
- `checks.updated`
- `merge.enqueued`
- `merge.completed`
- `retry.scheduled`

Retention:

- bounded in-memory ring globally and per issue
- default: 5,000 global events, 500 per issue
- optional later JSONL persistence under logs root

Important: event payloads may contain secrets or huge tool outputs. Truncate and redact by default. Raw payloads should be opt-in and still capped.

## 7. Refactor target architecture

Longer-term target:

```text
SymphonyElixir.Orchestrator
  - OTP shell and high-level coordination only

SymphonyElixir.Control.Poller
SymphonyElixir.Control.Dispatcher
SymphonyElixir.Control.Reconciler
SymphonyElixir.Control.RetryScheduler
SymphonyElixir.Control.MergeCoordinator

SymphonyElixir.Runs.Registry
SymphonyElixir.Runs.Transitions

SymphonyElixir.Observability.EventStore
SymphonyElixir.Observability.RunSnapshot
SymphonyElixir.Observability.PrStatus
SymphonyElixir.Observability.WorkspaceStatus

SymphonyElixir.Lifecycle.Bootstrap
SymphonyElixir.Lifecycle.AfterRun
SymphonyElixir.Lifecycle.PassivePrObserver
SymphonyElixir.Lifecycle.ReviewReconciler
SymphonyElixir.Lifecycle.MergeReconciler

SymphonyElixir.PullRequests.Publisher
SymphonyElixir.PullRequests.Inspector
SymphonyElixir.PullRequests.Reviewer
SymphonyElixir.PullRequests.MergeExecutor
SymphonyElixir.GitHub.Cli
```

The current public modules should remain as facades during migration:

- `SymphonyElixir.OrchestrationLifecycle`
- `SymphonyElixir.PullRequests`
- `SymphonyElixirWeb.Presenter`

## 8. Refactor sequence

### Phase 0 — Characterize

- Add tests around current `/api/v1/state`, issue payload, transcript, workspace endpoints.
- Add tests around key lifecycle transitions and PR/check/merge behavior.
- Do not move code until behavior is pinned.

### Phase 1 — New API contract and pure projectors

- Add `Observability.RunSnapshot`, `PrStatus`, `WorkspaceStatus`, `Attention`.
- Keep existing `/api/v1/state` unchanged.
- Add contract tests for `/api/v1/runs` and run detail.

### Phase 2 — Event store

- Add `Observability.EventStore` to supervision tree before the orchestrator.
- Append sanitized worker events from `handle_info({:worker_update, ...})`.
- Add `/api/v1/runs/:issue_identifier/events` and `/api/v1/events`.

### Phase 3 — Phase transition history

- Compare previous/current tracked entries on poll reconciliation.
- Emit `phase.changed` events when phase, tracker state, waiting reason, dispatch status, passive status, or next intended action changes.
- Add transitions endpoint.

### Phase 4 — Safe artifact/log APIs

- Add `ArtifactReader` with path validation and byte caps.
- Add logs endpoint.
- Keep existing transcript endpoint as a compatibility adapter.

### Phase 5 — PR/check read model

- Project cached PR status from workpad metadata and observation gates.
- Add opt-in live refresh via `PullRequests.inspect_state/2`.
- Add PR endpoint.

### Phase 6 — Backfill existing presenter

- Make `SymphonyElixirWeb.Presenter` delegate to new observability projectors where practical.
- Dashboard and legacy API continue to work.

### Phase 7 — Split large modules

Extract behind facades:

- `Orchestrator` -> control modules and run registry
- `OrchestrationLifecycle` -> lifecycle modules
- `PullRequests` -> GitHub/PR submodules
- `StatusDashboard` -> scheduler vs terminal renderer vs formatters

### Phase 8 — Optional durable event history

- Mirror event store to JSONL under logs root.
- On restart, load recent event history for completed/retrying runs.

## 9. Implementation tasks

1. Write `docs/OBSERVABILITY_API.md` with endpoint schemas.
2. Add contract tests for new run/event/log/PR endpoints.
3. Introduce observability projectors.
4. Add event store and append worker events.
5. Add run/event controllers and routes.
6. Add phase transition detection and endpoint.
7. Add safe artifact reader and logs endpoint.
8. Add cached/live PR endpoint.
9. Refactor legacy presenter to use projectors.
10. Begin module decomposition behind facades.

## 10. Risks and mitigations

| Risk | Mitigation |
|---|---|
| API starts blocking on orchestrator | Keep list/detail projection cheap; use event/read models over time |
| Live PR refresh is slow/flaky | `refresh=true` only; timeout; no live calls from list endpoint |
| Event payload leaks secrets | sanitize, truncate, raw opt-in only |
| File APIs become path traversal vector | serve only metadata-known paths under allowed roots |
| Refactor breaks orchestration | characterize first; migrate behind facades; keep tests green per phase |
| Frontend couples to unstable fields | contract tests + docs; keep legacy endpoints stable |

## 11. Recommended first milestone

Build a narrow but useful slice:

1. `GET /api/v1/runs`
2. `GET /api/v1/runs/:issue_identifier`
3. bounded `EventStore`
4. `GET /api/v1/runs/:issue_identifier/events`
5. `GET /api/v1/runs/:issue_identifier/transitions`

This gives an Intern-style Mission Control enough information to render active cards, attention states, and timelines without touching PR live refresh or artifact streaming yet.
