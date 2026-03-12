# pi-symphony

Symphony-style unattended issue orchestration for Pi.

## Status

Planning / bootstrap phase.

## Current direction

We will start from the architecture and implementation shape of OpenAI's Symphony, but adapt it for Pi:

- keep a long-running orchestrator service
- keep repo-owned `WORKFLOW.md` configuration and prompt policy
- keep per-issue isolated workspaces
- replace Codex app-server workers with Pi workers running over Pi RPC
- add Pi extensions inside worker sessions for workspace safety, tracker operations, and proof-of-work capture

## Why this repo exists

The goal is to let a team manage work, not babysit individual coding sessions:

- poll an issue tracker for eligible work
- create or reuse an isolated workspace per issue
- run a Pi coding session inside that workspace
- validate the result
- publish artifacts and proof of work
- retry, reconcile, and recover safely

## Docs

- [`docs/PLAN.md`](docs/PLAN.md) — implementation plan and architecture

## Planned structure

```text
pi-symphony/
  docs/
  orchestrator/      # adapted Symphony-style daemon (likely Elixir first)
  extensions/        # Pi worker extensions
  examples/
```

## License

MIT
