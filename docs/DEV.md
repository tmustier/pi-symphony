# Development

## Tooling strategy

This repo is intentionally mixed-language:

- **Elixir / OTP** for the long-running orchestrator
- **TypeScript** for Pi extensions and related utilities

We pin the runtime with `mise` so local development and CI use the same versions.

## Prerequisites

1. Install [`mise`](https://mise.jdx.dev/)
2. Install Git and GitHub CLI
3. From the repo root, run:

```bash
make setup
```

That will:

- install pinned tool versions
- install TypeScript dependencies
- install Elixir dependencies for `orchestrator/elixir`
- install git hooks via Lefthook

## Local secrets

Keep tracker credentials out of git.

Recommended order:

1. **Best:** inject `LINEAR_API_KEY` from a secret manager at launch time (for example 1Password, macOS Keychain, or your deployment secret store).
2. **Acceptable for local development:** use a repo-local `.env.local` file, which is already gitignored.

Example `.env.local`:

```bash
LINEAR_API_KEY=lin_api_...
```

Load it only into your current shell before starting the orchestrator:

```bash
set -a
source .env.local
set +a
```

Then keep the workflow itself secret-free:

```yaml
tracker:
  api_key: "$LINEAR_API_KEY"
  team_key: "THO"
```

Prefer `tracker.team_key` as the primary safety boundary. Add `tracker.project_slug` only when you want to narrow further inside that team.

## Common commands

```bash
make fmt          # format Elixir + TypeScript
make lint         # credo + biome
make typecheck    # TypeScript strict typecheck
make test         # TypeScript + Elixir tests
make check        # full local quality gate
pnpm run spike:rpc -- --fixture examples/fixture-issue.json
```

Language-specific commands:

```bash
make fmt-ts
make lint-ts
make test-ts

make fmt-elixir
make lint-elixir
make test-elixir
```

## Quality bar

### Elixir

We aim for a strong, explicit quality bar:

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix credo --strict`
- `mix dialyzer --format dialyxir`
- `mix test`

Elixir does not provide strict compile-time typing in the same sense as TypeScript. Our substitute is:

- precise `@spec` coverage on module boundaries
- disciplined typespecs
- Dialyzer in CI and local full checks

### TypeScript

TypeScript is strict by default here:

- `tsc --noEmit`
- Biome for formatting + linting
- Vitest for tests

## Hooks and CI

### Pre-commit hooks

We use **Lefthook** for fast local checks:

- Biome on staged TS/JS/JSON files
- TypeScript typecheck when TS files change
- Elixir format + compile checks when Elixir files change

Keep hooks fast. Heavier checks belong in `make check` and CI.

### CI

GitHub Actions is the authoritative gate.

Current CI runs separate jobs for:

- TypeScript lint + typecheck + tests
- Elixir format + compile + credo + dialyzer + tests

## Example workflow for adopters

A Pi-oriented sample workflow lives at:

- `examples/WORKFLOW.example.md`

Copy it into a target repo as `WORKFLOW.md`, then adjust:

- tracker/project settings
- workspace root
- polling/concurrency
- prompt instructions
- relative `pi.extension_paths`

## Validation / hardening when Elixir toolchain is available

The full local validation path is:

```bash
make check-ts
make check-elixir
make check
```

Recommended order:

1. `make setup`
2. `make check-ts`
3. `make check-elixir`
4. exercise a real `WORKFLOW.md` against the Pi runtime path
5. only then declare the runtime fully hardened

## Parallelization guidance

When parallelizing work on this repo:

- split by clear seams, not by shared files
- prefer one agent per bounded surface (for example: worker extensions, presenter/dashboard, tests)
- record the task boundary, integration plan, and cleanup steps in `.ralph/pi-symphony-v1.md`
- merge short-lived parallel work quickly and remove temporary scaffolding immediately after integration

## Upstream baseline

`orchestrator/elixir` starts as a vendored snapshot of OpenAI Symphony's Elixir implementation and will be adapted over time.

See:

- `docs/PLAN.md`
- `docs/archive/UPSTREAM.md`
- `THIRD_PARTY_NOTICES.md`
