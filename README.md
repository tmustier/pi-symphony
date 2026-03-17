# pi-symphony

Symphony-style unattended issue orchestration for Pi.

## Status

Agent: Functional — the core orchestration loop, PR automation, and merge execution are implemented. Not yet running in production.
Translation: **This will let you <s>give in to vibeslop</s> agentically engineer at a new level of abstraction.**

## What it does

- Polls a Linear board for eligible issues
- Creates an isolated workspace per issue
- Launches a Pi coding worker in RPC mode
- Lets the worker implement autonomously within repo-defined policy
- Manages the full PR lifecycle: create/reuse PRs, self-review, merge execution
- Captures proof-of-work artifacts and surfaces status through a dashboard and JSON API
- Retries, reconciles, and recovers safely

## Architecture

- **Orchestrator** (Elixir/OTP) — long-running daemon adapted from [OpenAI Symphony](https://github.com/openai/symphony)
- **Worker extensions** (TypeScript) — `workspace-guard`, `proof`, `linear-graphql`
- **Workflow contract** — repo-owned `WORKFLOW.md` with policy-driven prompt templates

## Development quick start

```bash
make setup
make check
```

See [`docs/DEV.md`](docs/DEV.md) for the full developer workflow.

## Repo shape

```text
pi-symphony/
  orchestrator/elixir/  # Elixir/OTP orchestrator (adapted from OpenAI Symphony)
  extensions/           # Pi worker extensions
  examples/             # fixtures and sample workflows
  docs/                 # architecture, developer docs, contracts
  docs/archive/         # historical migration notes
```

## Docs

- [`docs/PLAN.md`](docs/PLAN.md) — implementation plan and architecture
- [`docs/DEV.md`](docs/DEV.md) — local development workflow and quality bar
- [`docs/PI_RPC_CONTRACT.md`](docs/PI_RPC_CONTRACT.md) — Pi worker runtime contract
- [`docs/ORCHESTRATED_PR_FLOW.md`](docs/ORCHESTRATED_PR_FLOW.md) — PR automation design
- [`docs/PR_AUTOMATION_SCHEMA_PROPOSAL.md`](docs/PR_AUTOMATION_SCHEMA_PROPOSAL.md) — config and runtime contract for PR automation
- [`docs/WORKFLOW_PR_AUTOMATION_DRAFT.md`](docs/WORKFLOW_PR_AUTOMATION_DRAFT.md) — booking-demo workflow draft
- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) — vendored code attribution

## License

MIT for original project code. Vendored third-party code retains its upstream license; see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
