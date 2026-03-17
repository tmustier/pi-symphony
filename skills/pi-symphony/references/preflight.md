# Symphony Pre-Flight Checklist

Run through this before every symphony launch.

## 1. Linear issues are ready

- [ ] Target issues are in **Todo** (not Backlog)
- [ ] All target issues have the **`symphony`** label
- [ ] **`blockedBy` relationships reviewed** — symphony strictly respects them
  - If issue A blocks B, B won't dispatch until A reaches a terminal state
  - If A gets stuck, B is deadlocked
  - Remove `blockedBy` links between issues that should run in parallel
  - Only keep `blockedBy` for genuinely serial work
- [ ] Issues have clear descriptions with acceptance criteria

## 2. Workflow config is correct

- [ ] `tracker.team_key` matches the Linear team
- [ ] `tracker.project_slug` matches the Linear project (if used)
- [ ] `pr.repo_slug` matches the GitHub repo (`Owner/repo`)
- [ ] `agent.max_concurrent_agents` is set appropriately
- [ ] `pi.model` and `pi.thinking_level` are what you want
- [ ] `workspace.root` directory exists
- [ ] Extension paths in `pi.extension_paths` resolve correctly relative to WORKFLOW.md

## 3. Environment

- [ ] `LINEAR_API_KEY` is exported in the shell (not just in `.env.local`)
  ```bash
  export LINEAR_API_KEY=lin_api_...
  ```
- [ ] `gh` CLI is authenticated: `gh auth status`
- [ ] `pi` is available: `which pi && pi --version`
- [ ] Symphony escript is built:
  ```bash
  cd ~/.pi/agent/git/github.com/tmustier/pi-symphony/orchestrator/elixir
  mise exec -- mix build
  ```

## 4. Launch

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

## 5. Verify within 2 minutes

- [ ] API responds: `curl -s http://127.0.0.1:4040/api/v1/state | python3 -m json.tool | head -20`
- [ ] Issues appear with `dispatch_allowed: true` and `ownership.allowed: true`
- [ ] Agents start within 1-2 poll cycles (30s default)
- [ ] Check logs: `tail -20 /path/to/logs/log/symphony.log.1`

## 6. Monitor

- Dashboard: http://127.0.0.1:4040/
- API: `curl -s http://127.0.0.1:{port}/api/v1/state`
- Force refresh: `curl -s -X POST http://127.0.0.1:{port}/api/v1/refresh`
- Logs: `tail -f /path/to/logs/log/symphony.log.1`

## 7. After the run

- [ ] Move issues with merged PRs to **Done** in Linear
- [ ] Move issues with open PRs to **In Review**
- [ ] Check merge conflicts: `gh pr list --repo owner/repo --json mergeable`
- [ ] Kill stale symphony processes
- [ ] Optionally clean workspaces
