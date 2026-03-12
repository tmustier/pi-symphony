# pi-symphony plan

## 1. Goal

Build a Symphony-style orchestration layer for Pi that can:

1. poll a tracker for eligible issues
2. create or reuse an isolated workspace per issue
3. launch a Pi worker session for that issue
4. let the worker implement autonomously within repo-defined policy
5. collect proof of work and surface status to operators
6. retry, reconcile, and recover safely

## 2. Core decision

### Decision

Use OpenAI Symphony's Elixir implementation as the starting point for the orchestrator, but replace the Codex execution layer with a Pi execution layer.

### Why

This gets us the fastest path to a working system because Symphony already has:

- a solid orchestrator state machine
- polling, retries, reconciliation, and concurrency control
- workspace lifecycle management
- a Linear integration shape
- an observability surface
- a repository-owned `WORKFLOW.md` contract

The main part that does **not** transfer directly is the worker runtime, because Symphony talks to Codex app-server while Pi exposes RPC mode and an SDK.

## 3. Architecture

### 3.1 Orchestrator

Keep the orchestrator as a standalone daemon, not a Pi extension.

Responsibilities:

- load and validate `WORKFLOW.md`
- poll Linear for candidate issues
- track runtime state (`running`, `claimed`, `retrying`)
- enforce concurrency limits
- create and manage per-issue workspaces
- spawn and supervise Pi workers
- stop workers when issue state changes make them ineligible
- publish logs, metrics, and operator-visible state

### 3.2 Worker runtime

Each issue runs in its own Pi worker process.

Initial plan:

- launch Pi in RPC mode as a subprocess
- send a rendered prompt based on `WORKFLOW.md` + issue data
- stream events back to the orchestrator
- capture final state, errors, and artifacts
- terminate cleanly or force-kill on timeout / reconciliation

Why Pi RPC first:

- process-level isolation
- easy restart / kill semantics
- explicit event stream
- no need to embed Pi inside the orchestrator process

### 3.3 Workspace model

Default to git worktrees instead of full repo clones.

Target behavior:

- one workspace per issue key
- deterministic pathing
- branch per issue (for example `pi-symphony/ABC-123`)
- preserved workspace across retries / continuation runs
- cleanup for terminal issues

### 3.4 Repo-owned workflow contract

Use a repo-owned `WORKFLOW.md` file inspired by Symphony.

It should define:

- tracker settings
- polling settings
- workspace settings
- hooks
- agent concurrency / retry settings
- Pi worker settings (model, thinking level, extension paths, runtime limits)
- prompt template body

### 3.5 Pi extensions inside worker sessions

We expect to add at least these extensions:

#### `workspace_guard`

Purpose:

- ensure the worker only reads/writes within its assigned workspace
- block unsafe path traversal
- optionally block destructive commands outside policy

#### `linear_graphql`

Purpose:

- expose tracker mutations to the worker without giving it raw token-management responsibility
- allow comments, state transitions, link updates, and related tracker interactions

#### `proof`

Purpose:

- export the final Pi session transcript / HTML
- capture validation outputs
- capture git metadata (branch, diff summary, commit SHA, PR URL)
- provide structured proof back to the orchestrator

## 4. What we keep vs replace from Symphony Elixir

### Keep or heavily reuse

These are the valuable parts of the upstream implementation to preserve or port closely:

- workflow loader and config parsing
- orchestrator state machine
- workspace lifecycle and safety checks
- tracker abstractions
- Linear adapter / client structure
- HTTP server and dashboard
- logging conventions

### Replace

These parts are Codex-specific and should be replaced with Pi-native equivalents:

- Codex app-server client
- Codex dynamic tool plumbing
- agent runner logic that assumes Codex session / turn protocol

### New modules we likely need

At minimum:

- `Pi.RpcClient`
- `Pi.WorkerRunner`
- `Pi.Proof`
- `Pi.EventMapper`

## 5. Proposed repo layout

```text
pi-symphony/
  docs/
    PLAN.md
  orchestrator/
    elixir/                 # initial adapted upstream codebase
  extensions/
    workspace-guard.ts
    linear-graphql.ts
    proof.ts
  examples/
    WORKFLOW.example.md
```

## 6. MVP scope

### Phase 0 — bootstrap

- create repo
- set license and baseline docs
- write implementation plan
- import / vendor the upstream Symphony Elixir code for reference or adaptation

### Phase 1 — local single-issue runner

Goal: prove Pi can replace Codex for one issue.

Deliverables:

- Pi RPC subprocess launcher
- rendered prompt from a local issue fixture
- event streaming and logging
- timeout / cancellation behavior
- proof artifact export

Success criteria:

- we can run one unattended Pi worker in an isolated workspace and collect a deterministic result bundle

### Phase 2 — orchestrator integration

Goal: wire Pi workers into the Symphony orchestration loop.

Deliverables:

- replace Codex runner with Pi runner
- map Pi worker lifecycle into orchestrator state transitions
- retries / backoff / continuation behavior
- stall detection and force-stop behavior

Success criteria:

- orchestrator can run multiple Pi workers safely with bounded concurrency

### Phase 3 — tracker loop

Goal: close the loop with Linear.

Deliverables:

- fetch candidate issues
- reconcile active runs against tracker state
- stop or continue workers based on tracker changes
- optional worker-side issue mutation tooling

Success criteria:

- Linear issues can drive autonomous Pi work end-to-end

### Phase 4 — proof of work + operator surface

Deliverables:

- HTTP dashboard or JSON API
- session export
- validation command capture
- git / PR metadata capture
- human-readable run summaries

Success criteria:

- operator can understand what happened without opening raw logs

## 7. Implementation backlog

### 7.1 Immediate next tasks

1. inspect upstream Symphony Elixir modules in detail
2. identify the exact Codex-specific boundary to swap out
3. design the Pi RPC worker contract
4. define proof artifact schema
5. draft a Pi-oriented `WORKFLOW.example.md`

### 7.2 First technical spike

Build a thin Pi RPC runner that can:

- start Pi in RPC mode
- send a prompt
- consume event stream
- detect completion / failure
- abort on timeout
- export a run summary

If this spike is solid, the rest of the architecture is validated.

## 8. Open questions

1. **Language split** — do we keep Elixir long-term, or use it only to accelerate v1?
2. **Tracker writes** — should worker-side tracker mutation use a custom Pi extension, direct Linear API calls, or existing MCP tooling?
3. **Authentication model** — what credentials live with the orchestrator vs the worker?
4. **Validation model** — how much should validation be encoded in `WORKFLOW.md` vs repo-local skills / scripts?
5. **Artifact model** — what is the minimum proof bundle required for review and handoff?
6. **PR strategy** — should v1 open PRs automatically or stop at a review-ready branch + summary?

## 9. Working principles

- keep orchestration deterministic
- keep policy in the repo
- keep workers isolated
- keep observability first-class
- prefer small, swappable boundaries over a giant integrated runtime
- optimize for something we can outsource cleanly later

## 10. Definition of a good v1

A good v1:

- runs unattended for real issues
- is safe enough to operate in a trusted environment
- is understandable by an external engineer with limited context
- has clear module boundaries between orchestration, worker runtime, tracker integration, and proof capture
- can be extended later without rewriting the entire system
