# Troubleshooting

Common issues encountered running symphony and how to resolve them.

## Issues stuck in `blocked` / `tool_unavailable`

**Symptom**: Issues show `tool_unavailable` in workpad or orchestrator logs.

**Cause**: The orchestrator can't run `gh` for PR lifecycle gates. Workers create PRs fine, but the orchestrator's reconciliation reports `tool_unavailable`.

**Fix**: Check that `gh auth status` works in the shell where symphony was launched. If the issue is already done but stuck, manually move it to "In Review" in Linear.

## No new agents dispatching despite free slots

**Symptom**: `max_concurrent_agents` not reached, but no new workers spawn.

**Cause**: Usually `blockedBy` relationships. If Linear issues have blockers in non-terminal states (including In Progress, In Review), dispatch is blocked.

**Fix**:
1. Check for blocking relationships in Linear
2. Remove `blockedBy` links that shouldn't be there
3. Or wait for the blocking issue to reach a terminal state

## Merge conflicts on sibling PRs

**Symptom**: After merging some PRs, remaining PRs show merge conflicts.

**Cause**: Parallel workers touched the same files. The first PRs to merge make the rest conflict.

**Fix**:
- Rebase conflicted branches onto updated main: `git rebase main`
- Or resolve conflicts manually and force-push
- For future runs: reduce `max_concurrent_agents` or use `blockedBy` for issues touching the same files

## Workers timing out

**Symptom**: Workers killed by timeout without completing.

**Cause**: `codex.turn_timeout_ms` or `pi.response_timeout_ms` too short for the work.

**Fix**:
- Increase `codex.turn_timeout_ms` (default 3600000 = 1 hour)
- Increase `pi.response_timeout_ms` (default 60000 = 1 minute)
- Break large issues into smaller ones

## `LINEAR_API_KEY` not found

**Symptom**: Symphony fails at startup with auth errors.

**Cause**: The env var is in `.env.local` but not exported to the shell where the escript runs.

**Fix**:
```bash
export LINEAR_API_KEY=lin_api_...
# or
set -a && source .env.local && set +a
```

## Dashboard not loading

**Symptom**: http://127.0.0.1:4040/ returns connection refused.

**Fix**:
1. Check the process is running: `ps aux | grep symphony`
2. Check the port: `lsof -i :4040`
3. Check logs for startup errors
4. Verify `server.port` and `server.host` in WORKFLOW.md

## Workpad metadata corrupted

**Symptom**: Orchestrator logs show metadata recovery or issues cycle unexpectedly.

**Cause**: Workpad YAML block was manually edited or partially overwritten.

**Fix**: Symphony auto-recovers by setting `phase: blocked` with `waiting.reason: metadata_recovery_required`. Check the workpad comment in Linear, fix the YAML block, and remove the blocked state.

## Kill switch

To emergency-stop symphony:

- **Per-issue**: add the `no-symphony-automation` label (or whatever `rollout.kill_switch_label` is set to) to the Linear issue
- **All issues**: create the sentinel file specified in `rollout.kill_switch_file` (default: `/tmp/pi-symphony.pause`)
  ```bash
  touch /tmp/pi-symphony.pause   # stop
  rm /tmp/pi-symphony.pause      # resume
  ```
- **Hard stop**: `kill $(cat /path/to/symphony.pid)`
