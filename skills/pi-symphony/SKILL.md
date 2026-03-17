---
name: pi-symphony
description: Operate pi-symphony — unattended issue orchestration that polls Linear, creates isolated workspaces, and launches Pi workers to implement issues autonomously. Use when the user asks about symphony, setting up a WORKFLOW.md, launching or monitoring symphony runs, preparing Linear issues for orchestration, checking symphony status, or anything related to autonomous/unattended issue execution. Also triggers on "orchestration", "unattended", "autonomous issues", "symphony dashboard", "symphony preflight", or "WORKFLOW.md".
---

# pi-symphony

Unattended issue orchestration for Pi. Polls a Linear board for eligible issues, creates an isolated workspace per issue, launches a Pi worker in RPC mode, and manages the full lifecycle through to PR creation, self-review, and merge.

## Install location

When installed via `pi install git:github.com/tmustier/pi-symphony`, the repo lives at:

```
~/.pi/agent/git/github.com/tmustier/pi-symphony/
```

All paths in this skill are relative to that root unless otherwise noted.

## Key concepts

- **WORKFLOW.md** — a repo-owned config file (YAML frontmatter + optional prompt template) that defines tracker settings, workspace root, agent concurrency, Pi model/thinking, PR policy, and orchestration phases. Lives in the target repo.
- **Orchestrator** — an Elixir/OTP daemon that polls Linear, manages state, spawns Pi workers, and serves a dashboard. Built from `orchestrator/elixir/`.
- **Orchestration phases** — machine-facing execution state (implementing, reviewing, waiting_for_checks, waiting_for_human, rework, blocked, ready_to_merge, merging). Separate from human-facing Linear states.
- **Workpad** — a Linear issue comment owned by symphony containing a YAML metadata block that tracks phase, branch, PR number, review state, and merge state.
- **Worker extensions** — TypeScript Pi extensions loaded into each worker: `workspace-guard` (path safety), `proof` (artifact export), `linear-graphql` (tracker mutations).
- **Proof artifacts** — session transcripts, event logs, summaries, and exported HTML captured per run.

## Linear access

Symphony needs Linear access both for the orchestrator (polling/mutations) and for the operator (checking issue status).

**Read `LOCAL.md` in this skill directory for user-specific Linear configuration.** If it does not exist, create one from `assets/local-config.template.md` and ask the user to fill in their details (Linear access method, team key, project slug).

## Setting up a target repo

1. Copy the starter template into the target repo:
   ```bash
   cp ~/.pi/agent/git/github.com/tmustier/pi-symphony/skills/pi-symphony/assets/WORKFLOW.template.md /path/to/target-repo/WORKFLOW.md
   ```

2. Edit the WORKFLOW.md frontmatter — the key fields to configure:
   - `tracker.team_key` — your Linear team prefix (e.g. "THO")
   - `tracker.project_slug` — optional, narrows to a specific Linear project
   - `workspace.root` — where symphony creates per-issue workspaces (must exist)
   - `pr.repo_slug` — GitHub `owner/repo` for PR creation
   - `pi.model` and `pi.thinking_level` — which model workers use
   - `agent.max_concurrent_agents` — how many parallel workers

3. Ensure the workspace root directory exists:
   ```bash
   mkdir -p /path/to/workspace-root
   ```

4. For full config field reference, read `references/workflow-config.md`.

## Preparing Linear issues

Before launching symphony:

- Target issues must be in **Todo** (not Backlog — symphony skips Backlog)
- All target issues need the **`symphony`** label (ownership gate)
- **Review `blockedBy` relationships carefully** — symphony strictly respects them. If issue A blocks B, B will not dispatch until A reaches a terminal state (Done, Closed, Cancelled). Remove blocking links between issues that should run in parallel.
- Issues should have clear descriptions with acceptance criteria

## Launching symphony

### Prerequisites

```bash
# 1. Build the orchestrator (one-time, or after code changes)
cd ~/.pi/agent/git/github.com/tmustier/pi-symphony/orchestrator/elixir
mise exec -- mix build

# 2. Ensure environment
export LINEAR_API_KEY=lin_api_...  # must be in shell, not just .env
gh auth status                     # GitHub CLI must be authenticated
which pi && pi --version           # Pi must be available
```

### Launch

```bash
cd ~/.pi/agent/git/github.com/tmustier/pi-symphony/orchestrator/elixir
export LINEAR_API_KEY=lin_api_...

nohup mise exec -- ./bin/symphony \
  /path/to/target-repo/WORKFLOW.md \
  --port 4040 \
  --logs-root /path/to/logs \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  > /path/to/logs/stdout.log 2>&1 &
echo $! > /path/to/symphony.pid
```

Each instance needs a unique `--port`. Use 4040, 4041, etc. for multiple concurrent runs.

### Verify (within 2 minutes)

```bash
curl -s http://127.0.0.1:4040/api/v1/state | python3 -m json.tool | head -20
```

Check that tracked issues appear with `dispatch_allowed: true`.

## Monitoring

- **Dashboard**: http://127.0.0.1:4040/ (or whichever port)
- **API**: `curl -s http://127.0.0.1:{port}/api/v1/state`
- **Force refresh**: `curl -s -X POST http://127.0.0.1:{port}/api/v1/refresh`
- **Logs**: `tail -f /path/to/logs/log/symphony.log.1`

## Shutdown

```bash
kill $(cat /path/to/symphony.pid)
```

## After a run

- Move issues with merged PRs to **Done** in Linear
- Move issues with open PRs to **In Review**
- Check for merge conflicts: `gh pr list --repo owner/repo --json mergeable`
- Clean up stale workspaces if desired

## Troubleshooting

For known issues and recovery procedures, read `references/troubleshooting.md`.

## Deeper reference

Read these only when needed:

- `references/workflow-config.md` — full WORKFLOW.md field reference
- `references/preflight.md` — complete pre-flight checklist
- `references/phases.md` — orchestration phase model, workpad contract, passive vs active semantics
- `references/troubleshooting.md` — known issues, common failures, recovery steps
