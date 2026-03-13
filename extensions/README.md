# Extensions

Worker extensions currently implemented for unattended Pi runs:

- `workspace-guard` — blocks obvious workspace escapes for built-in file tools and suspicious `bash` path references
- `proof` — writes worker-side proof artifacts (`proof/events.jsonl`, `proof/summary.json`) next to the Pi session file when available
- `linear-graphql` — restores the imported Symphony `linear_graphql` tool using orchestrator-provided Linear auth

## Loading strategy

Workers should run with ambient extension discovery disabled and load only an explicit bundle:

```bash
pi --mode rpc --session-dir <dir> --no-extensions --no-themes \
  --extension <absolute-path-to-workspace-guard> \
  --extension <absolute-path-to-proof> \
  --extension <absolute-path-to-linear-graphql>
```

In `pi-symphony`, the Elixir runtime resolves configured extension paths relative to `WORKFLOW.md`, expands them to absolute paths, and passes them explicitly to Pi.

For tracker operations, the runtime also injects worker environment variables derived from tracker config so credentials stay out of prompts.
