# Symphony Pre-Flight Checklist

Run through this before launching a Symphony run to avoid the issues we hit on the first run (2026-03-15).

## 1. Linear issues are ready

- [ ] Target issues are in **Todo** (not Backlog — Symphony skips Backlog)
- [ ] All target issues have the **`symphony`** label (required by ownership gate)
- [ ] **Review `blockedBy` relationships** — Symphony strictly respects them
  - `todo_issue_blocked_by_non_terminal?` prevents dispatch of any Todo issue whose blocker is in a non-terminal state (including In Progress, In Review, etc.)
  - If issue A blocks B, B will not dispatch until A reaches a terminal state (Done, Closed, Cancelled)
  - If A gets stuck on any lifecycle gate, B is deadlocked
  - Remove `blockedBy` links between issues that should run in parallel
  - Only keep `blockedBy` if you genuinely need serial execution AND are confident the blocker will reach terminal state
- [ ] Issues have clear descriptions with acceptance criteria

## 2. Workflow config is correct

- [ ] `tracker.project_slug` matches the Linear project
- [ ] `pr.repo_slug` matches the GitHub repo (`Owner/repo`)
- [ ] `hooks.after_create` clones the right repo
- [ ] `agent.max_concurrent_agents` is set (sum across instances = your desired total)
- [ ] `pi.model` and `pi.thinking_level` are what you want
- [ ] `review.enabled` can be `true` — the PR resolution fallback to `settings.pr.repo_slug` should prevent `tool_unavailable` cascades
  - If review still causes `tool_unavailable`, check that `pr.repo_slug` is set correctly and `gh` is authenticated
- [ ] `workspace.root` directories exist: `mkdir -p ~/code/symphony-workspaces/{project}`

## 3. Environment

- [ ] `LINEAR_API_KEY` is exported (not just in `.env.local` — the escript subprocess needs it)
  ```bash
  # Preferred: retrieve from macOS Keychain
  export LINEAR_API_KEY=$(security find-generic-password -a "pi-symphony" -s "LINEAR_API_KEY" -w)
  
  # First-time setup: store in Keychain
  # security add-generic-password -a "pi-symphony" -s "LINEAR_API_KEY" -w "lin_api_..." -U
  ```
- [ ] `gh` CLI is authenticated: `gh auth status`
- [ ] `pi` is available: `which pi && pi --version`
- [ ] Symphony escript is built:
  ```bash
  cd orchestrator/elixir && mise exec -- mix build
  ```

## 4. Launch

```bash
cd /path/to/pi-symphony/orchestrator/elixir
export LINEAR_API_KEY=lin_api_...

# Instance 1
nohup mise exec -- ./bin/symphony \
  /path/to/workflows/booking-demo.md \
  --port 4040 \
  --logs-root ~/code/symphony-workspaces/logs/booking-demo \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  > ~/code/symphony-workspaces/logs/booking-demo/stdout.log 2>&1 &
echo $! > ~/code/symphony-workspaces/booking-demo.pid

# Instance 2 (different port!)
nohup mise exec -- ./bin/symphony \
  /path/to/workflows/website.md \
  --port 4041 \
  --logs-root ~/code/symphony-workspaces/logs/website \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  > ~/code/symphony-workspaces/logs/website/stdout.log 2>&1 &
echo $! > ~/code/symphony-workspaces/website.pid
```

## 5. Verify within 2 minutes

- [ ] Check API: `curl -s http://127.0.0.1:4040/api/v1/state | python3 -m json.tool | head -20`
- [ ] Tracked issues appear with `dispatch_allowed: true` and `ownership.allowed: true`
- [ ] Running agents appear within 1-2 poll cycles (30s default)
- [ ] Check logs for errors: `tail -20 ~/code/symphony-workspaces/logs/*/log/symphony.log.1`

## 6. Monitor

- Dashboard: http://127.0.0.1:4040/ and http://127.0.0.1:4041/
- API: `curl -s http://127.0.0.1:{port}/api/v1/state`
- Logs: `tail -f ~/code/symphony-workspaces/logs/*/log/symphony.log.1`
- Force refresh: `curl -s -X POST http://127.0.0.1:{port}/api/v1/refresh`

## 7. Known issues to watch for

### Issues stuck in `blocked` / `tool_unavailable`
The orchestrator can't run `gh` for its PR lifecycle gates. Workers create PRs fine, but the orchestrator's reconciliation reports `tool_unavailable`. **Workaround**: manually move completed issues to "In Review" in Linear.

### No new agents dispatching despite free slots
Check for `blockedBy` relationships. Even after restart, if Linear issues have blockers in non-terminal states, dispatch is blocked. **Workaround**: remove blocking relationships via Linear API.

### Merge conflicts on sibling PRs
When parallel workers touch the same files, the first PRs to merge cause conflicts in the rest. **Workaround**: resolve conflicts manually and force-push, or rebase branches onto updated main. See [pi-symphony#37](https://github.com/tmustier/pi-symphony/issues/37).

## 8. Shutdown

```bash
kill $(cat ~/code/symphony-workspaces/booking-demo.pid)
kill $(cat ~/code/symphony-workspaces/website.pid)
```

## 9. After the run

- [ ] Move all issues with merged PRs to **Done** in Linear
- [ ] Move issues with open PRs to **In Review** in Linear
- [ ] Check for merge conflicts: `gh pr list --repo Owner/repo --json mergeable`
- [ ] Kill stale Symphony processes
- [ ] Optionally clean up workspaces: `rm -rf ~/code/symphony-workspaces/{project}/THO-*`
