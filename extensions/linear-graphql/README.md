# linear-graphql

Pi worker extension that restores the imported Symphony `linear_graphql` capability for Pi sessions.

## What it does

Registers a `linear_graphql` tool so unattended workers can execute targeted GraphQL queries and mutations against Linear without receiving raw credentials in their prompt.

## Worker contract

The extension reads configuration from process environment:

- `PI_SYMPHONY_TRACKER_KIND`
- `PI_SYMPHONY_LINEAR_ENDPOINT`
- `PI_SYMPHONY_LINEAR_API_KEY`

The Pi worker runtime is responsible for setting these values from the orchestrator's configured tracker settings.

## Files

- `index.ts` — Pi extension entrypoint
- `bridge.ts` — argument normalization, environment loading, and GraphQL transport helpers
- `bridge.test.ts` — Vitest coverage for success/error cases
