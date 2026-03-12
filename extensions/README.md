# Extensions

Planned Pi worker extensions:

- `workspace-guard` — keep worker activity confined to its assigned workspace
- `linear-graphql` — expose tracker operations to worker sessions without leaking raw auth handling into prompts
- `proof` — collect structured proof-of-work artifacts from worker runs

These are intentionally separate from the orchestrator so the worker runtime stays modular and easier to outsource later.
