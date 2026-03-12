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

## Common commands

```bash
make fmt          # format Elixir + TypeScript
make lint         # credo + biome
make typecheck    # TypeScript strict typecheck
make test         # TypeScript + Elixir tests
make check        # full local quality gate
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

## Upstream baseline

`orchestrator/elixir` starts as a vendored snapshot of OpenAI Symphony's Elixir implementation and will be adapted over time.

See:

- `docs/PLAN.md`
- `docs/UPSTREAM.md`
- `THIRD_PARTY_NOTICES.md`
