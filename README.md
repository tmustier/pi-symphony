# pi-symphony

Symphony-style unattended issue orchestration for Pi.

## Status

Bootstrap / scaffolding phase.

## Current direction

We are starting from the architecture and implementation shape of OpenAI's Symphony, but adapting it for Pi:

- keep a long-running orchestrator service
- keep repo-owned `WORKFLOW.md` configuration and prompt policy
- make orchestration policy explicit in workflow config (`orchestration`, `rollout`, `pr`, `review`, `merge`) and expose it to worker prompts
- keep a durable machine-readable Symphony workpad comment on tracker issues for phase / branch / PR / review recovery
- keep per-issue isolated workspaces
- replace Codex app-server workers with Pi workers running over Pi RPC
- add Pi extensions inside worker sessions for workspace safety, tracker operations, and proof-of-work capture
- persist self-review artifacts from the workspace into a single durable PR review comment with head-keyed review metadata

## Why this repo exists

The goal is to let a team manage work, not babysit individual coding sessions:

- poll an issue tracker for eligible work
- create or reuse an isolated workspace per issue
- run a Pi coding session inside that workspace
- validate the result
- publish artifacts and proof of work
- retry, reconcile, and recover safely

## Development quick start

```bash
make setup
make check
```

See [`docs/DEV.md`](docs/DEV.md) for the full developer workflow.

## Repo shape

```text
pi-symphony/
  orchestrator/elixir/  # vendored Symphony Elixir baseline, to be adapted
  extensions/           # Pi worker extensions
  examples/             # fixtures and sample workflows
  docs/                 # plan, developer docs, upstream notes
```

## Docs

- [`docs/PLAN.md`](docs/PLAN.md) — implementation plan and architecture
- [`docs/DEV.md`](docs/DEV.md) — local development workflow and quality bar
- [`docs/UPSTREAM.md`](docs/UPSTREAM.md) — upstream import and adaptation notes
- [`docs/MODULE_MAP.md`](docs/MODULE_MAP.md) — keep / adapt / replace migration map
- [`docs/PI_RPC_CONTRACT.md`](docs/PI_RPC_CONTRACT.md) — v1 Pi worker runtime contract
- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) — vendored code attribution

## License

MIT for original project code. Vendored third-party code retains its upstream license; see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
