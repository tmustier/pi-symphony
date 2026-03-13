# workspace-guard

Pi worker extension that keeps unattended runs inside the assigned workspace.

## Current protections

- blocks `read`, `write`, and `edit` when `path` resolves outside `process.cwd()`
- blocks `bash` when it references obvious escape paths such as:
  - `../...`
  - absolute paths outside the workspace
  - `~/...`

## Notes

- This is a practical guardrail, not a full shell sandbox.
- It is intentionally conservative for unattended workers: explicit absolute paths are treated as suspicious unless they remain inside the workspace.
- The orchestrator should still keep Pi's own sandbox / workspace policy enabled where available.

## Files

- `index.ts` — Pi extension entrypoint
- `policy.ts` — pure path/command policy helpers
- `policy.test.ts` — Vitest coverage for allow/block decisions
