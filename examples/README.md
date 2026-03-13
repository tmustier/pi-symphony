# Examples

This directory holds runnable examples, fixtures, and sample `WORKFLOW.md` files as the Pi worker contract stabilizes.

Current contents:

- `fixture-issue.json` — minimal issue payload for the Pi RPC spike runner
- `WORKFLOW.example.md` — example Pi-oriented workflow config for adopters

## Using `WORKFLOW.example.md`

The example file is meant to be copied to a repo root as `WORKFLOW.md` and then adjusted for the target project.

Typical flow:

1. Copy `examples/WORKFLOW.example.md` to `<repo>/WORKFLOW.md`
2. Set required env vars:
   - `LINEAR_API_KEY`
   - `PI_SYMPHONY_WORKSPACE_ROOT`
3. Set `tracker.team_key` in the copied workflow to the Linear team you want to scope to
4. Optionally set `tracker.project_slug` / `LINEAR_PROJECT_SLUG` if you want an extra project-level boundary inside that team
5. Choose the Pi worker model and thinking level under `pi.model` / `pi.thinking_level`
6. Adjust polling / concurrency / prompt instructions for that repo
7. Start the orchestrator

## Important path note

`pi.extension_paths` in the example use paths relative to the example file itself:

- `../extensions/workspace-guard/index.ts`
- `../extensions/proof/index.ts`
- `../extensions/linear-graphql/index.ts`

If you move the workflow file to a different directory, update those relative paths accordingly.
