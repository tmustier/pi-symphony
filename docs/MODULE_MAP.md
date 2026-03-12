# Migration module map

This document maps the imported Symphony Elixir modules into three buckets for the Pi migration:

- **keep mostly as-is**
- **adapt**
- **replace**

It also defines the narrowest practical Codex-specific boundary so we can swap in Pi without rewriting the whole orchestrator.

## Keep mostly as-is

These modules are already doing orchestration, config, parsing, or tracker work that is not fundamentally tied to Codex.

### Workflow and config

- `SymphonyElixir.Workflow`
- `SymphonyElixir.WorkflowStore`
- `SymphonyElixir.Config`
- `SymphonyElixir.Config.Schema`

Why keep:

- they implement the repo-owned `WORKFLOW.md` contract
- they parse and normalize runtime config
- they are already separated from the worker transport details

Expected changes:

- add Pi-specific config fields or rename the Codex section over time
- preserve backward compatibility only if it helps migration speed

### Tracker and issue models

- `SymphonyElixir.Tracker`
- `SymphonyElixir.Tracker.Memory`
- `SymphonyElixir.Linear.Adapter`
- `SymphonyElixir.Linear.Client`
- `SymphonyElixir.Linear.Issue`

Why keep:

- these model the tracker-facing side of the system, not the coding-agent protocol
- candidate issue selection, reconciliation inputs, and normalized issue data all remain useful for Pi

Expected changes:

- little or none early on
- possible future additions for worker proof / PR metadata

### Core utilities and safety

- `SymphonyElixir.PathSafety`
- `SymphonyElixir.LogFile`
- `SymphonyElixir.SSH`
- `SymphonyElixir.SpecsCheck`
- mix tasks under `lib/mix/tasks/*`

Why keep:

- these are support modules around safety, logging, or repo hygiene
- they are not inherently Codex-specific

Expected changes:

- likely only incremental adjustments

### Observability surface

- `SymphonyElixir.HttpServer`
- `SymphonyElixir.StatusDashboard`
- `SymphonyElixirWeb.*`

Why keep:

- the dashboard and HTTP surface are driven by orchestrator state, not by Codex itself
- if we preserve the state shape carefully, most of the UI can survive with modest renaming

Expected changes:

- rename Codex-flavored labels and presenter fields to Pi-neutral terms
- adapt rate-limit / token displays to Pi worker event semantics

## Adapt

These modules are structurally valuable but contain worker-runtime assumptions that must change.

### `SymphonyElixir.Orchestrator`

Why adapt instead of replace:

- the GenServer loop, retry queue, reconciliation flow, and concurrency management are core value
- most logic is tracker- and workspace-driven rather than Codex-driven

What changes:

- replace `codex_worker_update` integration with Pi worker event integration
- rename state fields like `codex_totals` and `codex_rate_limits` to worker-neutral or Pi-specific names
- keep retry / continuation logic, but feed it from Pi worker lifecycle events

### `SymphonyElixir.AgentRunner`

Why adapt instead of replace:

- it already owns the per-issue execution lifecycle
- it handles workspace creation, hooks, and continuation-turn decisions

What changes:

- remove `SymphonyElixir.Codex.AppServer` dependency
- call a Pi runner instead of `AppServer.start_session/2` and `AppServer.run_turn/4`
- keep the outer worker-attempt flow, but map events and session metadata from Pi RPC

### `SymphonyElixir.Workspace`

Why adapt instead of replace:

- workspace creation, hook execution, path validation, and cleanup remain central

What changes:

- update docs / naming from "Codex agents" to Pi workers
- possibly evolve the workspace lifecycle toward git worktrees if that becomes the chosen default
- preserve hook handling and path-safety enforcement

### Prompt and CLI surfaces

- `SymphonyElixir.PromptBuilder`
- `SymphonyElixir.CLI`

Why adapt:

- prompt construction still matters, but continuation wording should become Pi-oriented
- CLI entrypoints should describe Pi workers and Pi-specific config/runtime options

## Replace

These modules are the real Codex boundary.

### `SymphonyElixir.Codex.AppServer`

This is the primary transport/runtime adapter that must be replaced.

Why replace:

- it assumes the Codex app-server JSON-RPC protocol over stdio
- it manages Codex-specific concepts like `thread/start`, `turn/start`, approval policies, sandbox payloads, and Codex event parsing
- it emits Codex-shaped session metadata and token/rate-limit updates

Pi equivalent needed:

- start a Pi subprocess in RPC mode
- send prompts over Pi RPC
- consume Pi JSONL events
- detect completion / failure / timeout / cancellation
- translate Pi events into orchestrator updates

### `SymphonyElixir.Codex.DynamicTool`

Why replace:

- it is specifically the client-side dynamic tool interface for Codex app-server sessions
- the `linear_graphql` behavior is useful, but the transport contract is wrong for Pi

Pi equivalent needed:

- either a Pi extension exposing `linear_graphql`
- or an Elixir-side bridge that injects equivalent worker capabilities through Pi-supported mechanisms

Reusable idea:

- the `linear_graphql` request normalization and error-shaping are worth preserving conceptually, even if the module itself is replaced

## Precise Codex-specific boundary

The narrowest practical replacement seam is:

1. `AgentRunner` calls a worker-runtime adapter
2. the worker-runtime adapter launches and supervises the coding agent process
3. worker events are translated into orchestrator state updates

In the imported codebase, that seam is currently:

- `SymphonyElixir.AgentRunner`
- `SymphonyElixir.Codex.AppServer`
- `SymphonyElixir.Codex.DynamicTool`

That is the seam we should preserve.

This means we should avoid rewriting:

- tracker fetching
- retry scheduling
- workspace cleanup and hook semantics
- dashboard plumbing driven by orchestrator state

## New Pi-native modules

Minimum new modules to introduce:

- `SymphonyElixir.Pi.RpcClient`
  - low-level Pi subprocess / JSONL RPC wrapper
- `SymphonyElixir.Pi.WorkerRunner`
  - issue-scoped worker lifecycle using `Pi.RpcClient`
- `SymphonyElixir.Pi.EventMapper`
  - maps Pi RPC events into orchestrator-consumable worker updates
- `SymphonyElixir.Pi.Proof`
  - packages final artifacts and proof-of-work metadata

Likely supporting module:

- `SymphonyElixir.Pi.ToolBridge` or a Pi extension package
  - exposes tracker mutation capability such as `linear_graphql`

## Practical migration sequence

1. keep the imported orchestrator and dashboard running unchanged where possible
2. add Pi-native runtime modules alongside the existing Codex modules
3. switch `AgentRunner` behind a narrow adapter seam
4. rename Codex-specific observability fields only after Pi events are flowing
5. remove or retire Codex modules once the Pi path is stable
