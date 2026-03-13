# Extensions

Worker extensions currently implemented for unattended Pi runs:

- `workspace-guard` — blocks obvious workspace escapes for built-in file tools and suspicious `bash` path references
- `proof` — writes worker-side proof artifacts (`proof/events.jsonl`, `proof/summary.json`) next to the Pi session file when available

Planned next extension:

- `linear-graphql` — expose tracker mutations to worker sessions without leaking raw auth handling into prompts

## Loading strategy

Workers should run with ambient extension discovery disabled and load only an explicit bundle:

```bash
pi --mode rpc --session-dir <dir> --no-extensions --no-themes \
  --extension <absolute-path-to-workspace-guard> \
  --extension <absolute-path-to-proof>
```

In `pi-symphony`, the Elixir runtime resolves configured extension paths relative to `WORKFLOW.md`, expands them to absolute paths, and passes them explicitly to Pi.
