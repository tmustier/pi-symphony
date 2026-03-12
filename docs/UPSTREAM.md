# Upstream baseline

## Source

The initial Elixir orchestrator baseline in `orchestrator/elixir` was imported from:

- Repo: `https://github.com/openai/symphony`
- Path: `elixir/`
- Snapshot commit: `ff65c7c729c03d4daa550bd30290fc5291f60c67`

## Why we imported it

We want to move quickly by reusing the parts Symphony already solved well:

- orchestrator state machine
- workflow loading and config parsing
- workspace lifecycle
- tracker integration shape
- observability and dashboard structure

## What we expect to replace

The imported code is **not** the final architecture.

The main replacement boundary is the Codex-specific worker runtime:

- Codex app-server client
- Codex dynamic tool plumbing
- agent runner behavior that assumes Codex session / turn semantics

These pieces will be replaced with Pi-native equivalents built around Pi RPC workers and Pi extensions.

## Working rule

When adapting upstream code:

1. preserve useful orchestration behavior where it remains correct
2. replace Codex-specific assumptions with explicit Pi worker contracts
3. keep changes well-documented so external contributors can understand what was retained vs replaced
4. preserve upstream attribution and licensing information
