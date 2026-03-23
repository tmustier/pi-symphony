# Pi RPC worker contract

Status: **Implemented** — this contract is live in the current orchestrator.

This document defines the **v1 worker contract** between the long-running orchestrator and a Pi worker process.

The goal is to replace Symphony's Codex app-server boundary with the smallest Pi-native equivalent that still gives us:

- deterministic worker lifecycle
- machine-readable progress and completion signals
- timeout and cancellation behavior
- proof-of-work export hooks

## 1. Worker process model

Each issue run gets its own Pi subprocess started in **RPC mode**:

```bash
pi --mode rpc --session-dir <issue-session-dir> --no-extensions --no-themes \
  --extension <worker-extension> --extension <worker-extension>
```

Expected properties:

- one process per issue attempt
- stdio transport only
- stdout carries JSONL protocol messages
- stderr is diagnostic only and must never be parsed as protocol
- process cwd is the issue workspace
- each issue attempt gets an explicit session directory so proof artifacts can be exported deterministically
- ambient user extensions are disabled so worker behavior stays deterministic
- required worker extensions are passed explicitly, not discovered implicitly from the operator's machine
- worker extension paths should resolve relative to `WORKFLOW.md` and be expanded to absolute paths before process launch

The orchestrator owns process lifecycle:

- spawn
- send commands
- consume events
- abort on timeout / reconciliation
- kill if graceful abort fails

## 2. Framing and transport rules

Pi RPC uses strict JSONL over stdout/stdin.

Important implementation rules from Pi docs:

- split on `\n` only
- accept `\r\n` by stripping trailing `\r`
- do **not** use generic line readers that treat Unicode separators as line breaks
- buffer partial lines until newline
- parse stdout only as protocol
- capture stderr separately for diagnostics

## 3. Commands used by v1 workers

The worker runner does not need the full Pi RPC surface.

### Required startup / control commands

- `get_state`
- `set_session_name`
- `set_auto_retry`
- `set_auto_compaction`
- `prompt`
- `abort`

### Optional configured startup commands

- `set_model`
- `set_thinking_level`

### Required completion / proof commands

- `get_last_assistant_text`
- `get_session_stats`
- `export_html`

### Optional future commands

- `get_messages`
- `get_commands` (current Pi returns command provenance under `sourceInfo`; older top-level `path` / `location` fields are gone)

## 4. v1 worker lifecycle

### 4.1 Startup

1. Spawn Pi in RPC mode in the issue workspace with an explicit issue-scoped session directory.
2. Verify protocol responsiveness with `get_state`.
3. Set a readable session name such as `<issue.identifier>: <issue.title>`.
4. Disable Pi-managed retries:
   - `set_auto_retry { enabled: false }`
5. Disable Pi-managed compaction for the initial spike:
   - `set_auto_compaction { enabled: false }`
6. If configured in `WORKFLOW.md`, set the worker model:
   - `set_model { provider, modelId }`
7. If configured in `WORKFLOW.md`, set the worker thinking level:
   - `set_thinking_level { level }`

Rationale:

- the orchestrator should remain the single authority for retries
- compaction can be reintroduced later once multi-turn Pi worker behavior is stable

### 4.2 Run

1. Render the issue prompt from a fixture or `WORKFLOW.md` template.
2. Send `prompt`.
3. Stream events until `agent_end` or a terminal failure condition.

### 4.3 Completion

After `agent_end`:

1. fetch `get_last_assistant_text`
2. fetch `get_session_stats`
3. call `export_html`
4. package a run summary for the orchestrator
5. terminate the Pi process cleanly

### 4.4 Timeout / cancellation

If the worker exceeds the orchestrator timeout budget:

1. send `abort`
2. wait a short grace period for a terminal event
3. if still alive, kill the process
4. mark the run as timed out / aborted in the orchestrator-facing summary

## 5. Event handling contract

The worker runner must treat stdout messages as belonging to one of three buckets:

1. **responses**
   - `type: "response"`
   - correlated to sent commands via optional `id`

2. **agent events**
   - `agent_start`, `agent_end`, `turn_start`, `turn_end`, `message_update`, `tool_execution_*`, `auto_retry_*`, etc.
   - consumed as progress / observability signals

3. **extension UI requests**
   - `type: "extension_ui_request"`
   - special handling required for unattended operation

## 6. Unattended extension UI policy

Pi RPC supports extension UI requests, but unattended workers cannot block on human interaction.

### Dialog requests

These methods require a response and must be auto-resolved by the runner:

- `select`
- `confirm`
- `input`
- `editor`

Policy for v1:

- immediately respond with:

```json
{"type":"extension_ui_response","id":"<same>","cancelled":true}
```

Rationale:

- avoids deadlock in unattended mode
- surfaces extension misuse quickly
- keeps control with the orchestrator rather than an imaginary operator

### Fire-and-forget UI requests

These methods do not require a response:

- `notify`
- `setStatus`
- `setWidget`
- `setTitle`
- `set_editor_text`

Policy for v1:

- record them in worker diagnostics / summary
- otherwise ignore them operationally

## 7. Worker extension bundle

The initial unattended worker bundle should include:

- `workspace-guard` — blocks obvious workspace escapes on `read`, `write`, `edit`, and suspicious `bash` path references
- `proof` — writes worker-side proof artifacts next to the Pi session file when available
- `linear-graphql` — restores the imported Symphony `linear_graphql` tool for Pi workers without leaking auth into prompts

The `linear-graphql` extension expects worker environment variables derived from orchestrator config:

- `PI_SYMPHONY_TRACKER_KIND`
- `PI_SYMPHONY_LINEAR_ENDPOINT`
- `PI_SYMPHONY_LINEAR_API_KEY`

The proof extension should emit at least:

- `proof/events.jsonl` — sanitized worker-side event log
- `proof/summary.json` — summary with final assistant text and tool/event counts

The orchestrator remains responsible for higher-level proof packaging like exported HTML sessions and run summaries.

## 8. Minimal orchestrator-facing summary

A v1 worker attempt should produce at least:

- issue identifier
- workspace path
- session name
- start / end timestamps
- duration
- timeout / aborted / success state
- final assistant text
- exported HTML session path
- session stats payload
- event counts by type
- tool execution counts by tool name
- stderr diagnostics path or inline tail
- any extension UI methods seen

## 9. Mapping to imported Symphony concepts

Current Symphony modules expect Codex-shaped updates. For Pi, we should preserve the seam but change the payload shape.

Practical mapping:

- `AgentRunner` still owns one issue attempt
- `Pi.RpcClient` replaces `Codex.AppServer` transport duties
- `Pi.WorkerRunner` replaces the Codex session/turn runner behavior
- `Pi.EventMapper` converts Pi RPC events into orchestrator updates and summary deltas

## 10. Spike scope

The first spike is intentionally narrow.

It should prove:

- we can start Pi in RPC mode
- we can send a prompt derived from a fixture issue
- we can stream and classify events correctly
- we can enforce a timeout
- we can export proof artifacts (`export_html`, stats, final text)

It does **not** need to prove full orchestrator integration yet.

## 11. Open follow-ups

Questions intentionally deferred past the spike:

- whether workers should ever use `follow_up` or `steer`
- whether auto-compaction should be re-enabled for long-running multi-turn sessions
- whether the final implementation should keep a raw stdio client in Elixir only, or also keep a reusable TS harness for local debugging
- how Pi-side tracker mutation should be injected: extension, bridge, or other runtime surface
