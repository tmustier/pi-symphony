# proof

Pi worker extension for writing structured proof-of-work artifacts during unattended runs.

## Artifact contract

When a Pi session file is available, the extension writes under the same session directory:

- `proof/events.jsonl` — sanitized event stream for `session_start`, `turn_end`, `tool_execution_end`, and `agent_end`
- `proof/summary.json` — final summary with:
  - workspace root
  - session file
  - started / finished timestamps
  - event counts
  - tool counts
  - final assistant text

If no Pi session file exists, artifacts fall back to:

- `<workspace>/.pi-symphony-proof/`

## Files

- `index.ts` — Pi extension entrypoint
- `recorder.ts` — pure artifact path / serialization helpers
- `recorder.test.ts` — Vitest coverage for artifact generation
