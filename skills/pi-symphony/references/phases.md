# Orchestration Phases

Symphony uses a dual-state model: **tracker state** (human-facing, in Linear) and **orchestration phase** (machine-facing, in the workpad).

## Why two layers?

Linear states are for humans. But the orchestrator needs finer-grained control — distinguishing "waiting for CI" from "waiting for human review" from "actively implementing." The orchestration phase provides this without cluttering the Linear board.

## Canonical phase table

| Phase | Class | Owner of next transition | Purpose |
|---|---|---|---|
| `implementing` | active | worker | Implementation, local validation, PR creation |
| `reviewing` | active | worker | Bounded self-review and fix loop |
| `waiting_for_checks` | passive | external systems | PR exists; waiting for CI or mergeability |
| `waiting_for_human` | passive | human | Waiting for human approval or decision |
| `rework` | active | worker | Reviewer feedback requires code changes |
| `blocked` | passive | human/operator | Missing context, auth, tooling, or metadata recovery |
| `ready_to_merge` | active | worker/runtime | All gates satisfied, merge can proceed |
| `merging` | active | worker/runtime | Merge execution underway |

**Active** phases may be retried immediately. **Passive** phases are polled but not retried.

## Tracker state mapping

Recommended Linear states and their relationship to phases:

| Linear state | Meaning | Typical phases |
|---|---|---|
| Todo | Not yet claimed | (pre-dispatch) |
| In Progress | Implementation underway | implementing, reviewing |
| In Review | PR exists, awaiting checks/review | waiting_for_checks, waiting_for_human |
| Merging | Human approved merge | ready_to_merge, merging |
| Rework | Reviewer requested changes | rework |
| Done | Merged / complete | (terminal) |

## Workpad metadata

The workpad is a Linear issue comment with a `## Symphony Workpad` heading containing a YAML metadata block. This is the durable source of truth for the orchestrator.

Key fields:

```yaml
symphony:
  schema_version: 1
  phase: implementing
  branch: pi-symphony/ISSUE-123
  pr:
    number: 42
    url: https://github.com/owner/repo/pull/42
    head_sha: abcdef1
  review:
    passes_completed: 1
    last_reviewed_head_sha: abcdef1
  merge:
    last_attempted_at: null
    last_failure_reason: null
  waiting:
    reason: checks_pending
    since: 2026-03-14T00:00:00Z
  rework_cycles: 0
```

### Waiting reasons (canonical enum)

- `checks_pending` — CI/checks not yet green
- `human_approval_required` — needs human to move issue to approval state
- `metadata_recovery_required` — workpad metadata was malformed
- `missing_context` — issue needs clarification
- `tool_unavailable` — required tool not accessible
- `mergeability_changed` — PR mergeability changed during execution
- `rework_limit_exceeded` — hit max rework cycles
- `kill_switch_active` — emergency brake engaged
- `observe_only` — rollout mode is observe

## Rollout modes

| Mode | Allowed actions |
|---|---|
| `observe` | Read issues, compute intended actions, update workpad observation fields |
| `mutate` | Everything in observe + create PRs, post reviews, push fixes |
| `merge` | Everything in mutate + auto-merge when gates satisfied |

Start with `observe`, graduate to `mutate`, then `merge` as confidence grows.
