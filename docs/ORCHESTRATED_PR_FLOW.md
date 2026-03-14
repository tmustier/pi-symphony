# Orchestrated PR Flow for Symphony + Pi

Status: Proposed (revised after robustness and UX review)

## 1. Summary

This document explains how to adapt a one-shot slash-command workflow:

- implement the task
- open a PR
- run a `pr-reviewer` subagent
- post review findings as a PR comment
- apply agreed fixes
- re-review once
- merge when green

into a **stateful, unattended orchestration flow** for Symphony + Pi.

The central design decision is:

> Keep tracker state human-readable, but add an explicit **orchestration phase** and a durable **workpad metadata block** so the runtime can distinguish active execution from passive waiting.

That is necessary because the current Symphony runtime aggressively continues issues that remain active. A simple `active_states` tweak is not enough to model waiting for CI, waiting for human review, or blocked clarification safely.

## 2. Why the slash-command prompt cannot be copied directly

A slash command is a single interactive run. Symphony is a control plane with:

- polling
- retries
- continuation turns
- reconciliation
- long-lived issue state
- workspace reuse

That means several original instructions must be reinterpreted:

- **"Ask for clarification and stop"** becomes: gather all available context first; if still ambiguous, record a blocker in the workpad and yield.
- **"Open a PR"** becomes: find-or-reuse the branch PR, or create one according to policy.
- **"Post the review output as a PR comment"** becomes: upsert a single bot-owned review comment keyed to the PR and head SHA.
- **"Merge when green"** becomes: wait passively for checks/review events, then merge only when runtime gates are satisfied.

## 3. Revised design conclusion

The earlier proposal treated `In Review` as an active waiting state. That is not safe with the current runtime.

The revised proposal is:

1. **Tracker state** remains the human-facing lifecycle signal.
2. **Orchestration phase** becomes the machine-facing execution signal.
3. **Workpad metadata** is the durable source of truth for PR/review/merge continuity.
4. **Runtime helpers** enforce idempotent PR/comment/merge behavior before unattended merge is enabled.
5. **Rollout mode** gates what kinds of side effects are allowed at each maturity stage.
6. **Operator visibility** is explicit, especially in observe mode.

## 4. Canonical orchestration phase model

This section is the **canonical reference** for orchestration phase names. Other docs and configs should use these names verbatim rather than redefining them.

### 4.1 Canonical phase table

| Phase | Class | Typical owner of next transition | Purpose | Common next phases |
|---|---|---|---|---|
| `implementing` | active | worker | active implementation, local validation, PR creation/reuse | `reviewing`, `waiting_for_checks`, `blocked` |
| `reviewing` | active | worker | bounded self-review and accepted-fix loop | `waiting_for_checks`, `waiting_for_human`, `blocked` |
| `waiting_for_checks` | passive | external systems / worker on poll | PR exists; waiting for required checks or mergeability changes | `reviewing`, `waiting_for_human`, `ready_to_merge`, `blocked` |
| `waiting_for_human` | passive | human | waiting for human approval or explicit human decision | `rework`, `ready_to_merge`, `blocked` |
| `rework` | active | worker | actionable reviewer feedback requires code changes | `reviewing`, `waiting_for_checks`, `blocked` |
| `blocked` | passive | human/operator | missing required context/auth/tooling or metadata recovery needed | `implementing`, `reviewing`, `rework` |
| `ready_to_merge` | active | worker/runtime | all policy gates are satisfied and merge can be attempted next | `merging`, `waiting_for_human`, `blocked` |
| `merging` | active | worker/runtime | merge execution is underway | `Done`, `blocked` |

Runtime rule:

- **active** phases may be continuation-retried immediately
- **passive** phases are polled but should not be continuation-retried immediately

### 4.2 Tracker state remains human-facing

Tracker states are still valuable, but they should not be the only machine execution signal.

Recommended generic tracker states:

- `Todo`
- `In Progress`
- `In Review`
- `Merging`
- `Rework`
- `Done`
- optional dedicated blocked/human-review state

Recommended semantics:

- `Todo` — not yet claimed for execution
- `In Progress` — implementation and self-review work
- `In Review` — PR exists and the issue is waiting for checks and/or human review
- `Merging` — explicit merge lane when human approval has been granted
- `Rework` — reviewer requested changes
- `Done` — merged / complete

Important rule:

> Do **not** move a ticket with no PR into `In Review` just because the task context is ambiguous.

If the task is ambiguous before PR creation, use:

- a dedicated blocked/human-review state if available, or
- keep the existing tracker state and set orchestration phase to `blocked`

## 5. Workpad metadata contract

The workpad should include a machine-readable metadata block near the top.

Illustrative shape:

````md
## Symphony Workpad

```yaml
symphony:
  schema_version: 1
  owned: true
  phase: waiting_for_checks
  rework_cycles: 0
  branch: thomas/tho-2-example
  pr:
    number: 123
    url: https://github.com/Nexcade/booking-demo/pull/123
    head_sha: abcdef1
  review:
    comment_id: 456789
    passes_completed: 1
    last_reviewed_head_sha: abcdef1
    last_fixed_head_sha: abcdef1
  merge:
    last_attempted_head_sha: null
  waiting:
    reason: checks_pending
    since: 2026-03-14T00:00:00Z
  observation:
    last_observed_at: 2026-03-14T00:00:00Z
    next_intended_action: merge_when_green
    rollout_mode: observe
    gates:
      ownership: pass
      checks: pending
      human_approval: required
  validation:
    summary: |
      - npm run build ✅
      - booking tests ✅
```
```
````

Minimum required fields:

- `schema_version`
- `phase`
- `branch`
- PR identity and head SHA when a PR exists
- review pass state when review has run
- merge attempt state when merge has been attempted
- waiting reason when the issue is passive
- observation fields so operators can understand what the system sees and intends to do

### 5.1 Canonical `waiting.reason` enum

To keep observe mode legible, `waiting.reason` should come from a small canonical set rather than freeform prose.

Recommended initial enum:

- `checks_pending`
- `human_approval_required`
- `metadata_recovery_required`
- `missing_context`
- `missing_auth`
- `tool_unavailable`
- `mergeability_changed`
- `rework_limit_exceeded`
- `kill_switch_active`
- `observe_only`

Human-readable explanation can still go in notes/workpad text, but the machine field should stay canonical.

## 6. Workpad extraction and recovery rules

The metadata block needs a deterministic extraction and fallback strategy.

### 6.1 Extraction rules

1. Find the active issue workpad comment using the stable heading marker `## Symphony Workpad`.
2. Within that comment, parse the **first fenced `yaml` block immediately following the heading** as canonical metadata.
3. Ignore other YAML blocks elsewhere in the comment for machine purposes.
4. If the canonical block is absent, create a fresh minimal block with `schema_version: 1` and `phase` set to the configured default phase.

### 6.2 Recovery rules

If the canonical metadata block exists but is malformed or ambiguous:

1. preserve the raw broken block in the workpad under a recovery note
2. rewrite a fresh canonical metadata block with `schema_version: 1`
3. set `phase: blocked`
4. set `waiting.reason: metadata_recovery_required`
5. stop after recovery in mutate/merge modes so a human or a later clean run can verify it

Safe default:

- **missing metadata** -> initialize and continue
- **malformed or ambiguous metadata** -> recover conservatively and stop with `blocked`

This prevents silent corruption of PR/review/merge state.

## 7. Structured self-review contract

The self-review output should not remain fully freeform.

The **canonical definition** of the review output format belongs in:

- `docs/PR_AUTOMATION_SCHEMA_PROPOSAL.md`

This document only requires that:

- review pass accounting is keyed to HEAD SHA continuity
- review passes count only after review results are successfully persisted
- a new commit invalidates an old review for merge purposes
- the worker leaves the canonical structured review artifact at `.symphony/review.md` with a leading `<!-- symphony-review-head: <sha> -->` line before the runtime upserts the durable PR review comment

## 8. Merge authorization and `Merging`

Human approval must be explicit when policy requires it.

Rule:

- if merge policy requires human approval, the worker must **not** promote an issue into approval states such as `Merging` on its own
- a human reviewer/operator is responsible for moving the ticket into the configured approval state
- once the ticket is in an approved merge state, the worker may move from `ready_to_merge` to `merging` and execute the merge

This makes the human approval gate legible and avoids a hidden auto-approval path.

If merge policy does **not** require human approval, the worker may transition from `waiting_for_checks` to `ready_to_merge` once all gates are satisfied.

## 9. Runtime invariants required before unattended merge

Before auto-merge is enabled, the system should have helper behavior for at least:

- **find-or-create PR** keyed by branch
- **upsert PR review comment** keyed by comment ID and marker
- **inspect PR state** including checks, reviews, mergeability, and current head SHA
- **merge-if-head-matches** so a stale review cannot merge a newer commit by accident

Passive polling should use the PR-inspection helper to refresh live gates (`checks`, `human_approval`, `mergeability`) and may safely promote `waiting_for_checks` into `waiting_for_human` or `ready_to_merge` without reopening implementation work.

These can start as worker-facing helper tools or Pi extensions. They do not need to be orchestrator-native on day one, but they should become runtime-enforced invariants before full merge automation.

## 10. Failure recovery model

The system should define explicit behavior for partial failures.

| Scenario | Required response |
|---|---|
| PR creation fails after push | keep phase in `implementing` or `reviewing`, record pushed branch/head, retry PR publication later |
| Review comment upsert fails | do not increment review pass count yet; keep phase `reviewing` |
| New commit appears after self-review | invalidate prior review for merge purposes and rerun review on the new HEAD |
| Checks still pending | set passive phase `waiting_for_checks`; do not continuation-retry immediately |
| Mergeability changes between check and merge | abort merge, refresh PR state, and fall back to `waiting_for_checks` or `waiting_for_human` |
| Merge succeeds but tracker update fails | persist merged head in workpad and retry tracker reconciliation only |
| Tracker update succeeds but merge fails | never mark `Done` before merge confirmation; if this happens unexpectedly, reconcile by re-reading PR state and restoring a non-terminal tracker state |
| Rework oscillates repeatedly | increment `rework_cycles`; once the configured limit is exceeded, move to `blocked` with a clear operator note |

Implementation rule:

> Tracker `Done` should only happen after merge confirmation, never before.

## 11. Operator visibility contract

Observe mode is only useful if operators can clearly see what Symphony knows and what it would do next.

Minimum operator-visible fields per issue:

- tracker state
- orchestration phase
- rollout mode
- ownership gate result
- kill-switch status
- PR number and head SHA when present
- last observed timestamp
- next intended action
- reason for not acting yet (checks pending, human approval required, blocked, etc.)
- concise gate summary (checks, approval, mergeability)

Recommended surfaces:

- the workpad metadata block
- dashboard/API issue detail view
- concise final agent summary for each active run

## 12. Rollout model and safety controls

The proposal should be rolled out in three modes.

### 12.1 Observe

Allowed:
- inspect issues, branches, PRs, checks, and review state
- compute intended next actions
- update workpad and operator-visible observation fields

Not allowed:
- create PRs
- post review comments
- merge

### 12.2 Mutate

Allowed:
- create or update PRs
- run self-review
- upsert review comments
- push fixes

Not allowed:
- merge automatically

### 12.3 Merge

Allowed:
- everything in mutate mode
- merge automatically once merge policy gates are satisfied

Safety controls required for all rollout modes:

- ownership gate
- preflight validation
- remote kill switch (issue/PR label)
- local emergency brake (sentinel file or equivalent local-only stop)
- migration handling for existing `In Review` tickets

## 13. Template rendering contract

Workflow prompt examples assume:

- Liquid-style templates rendered via the current `Solid`-based `PromptBuilder`
- strict variable/filter handling
- failure on missing `policy.*` values rather than silent blanking

This matters because prompt/config drift is dangerous in unattended workflows.

## 14. What changed from the earlier draft

This revised design changes the earlier proposal in six important ways:

1. it no longer treats `tracker.active_states` as sufficient for wait semantics
2. it adds a canonical phase table
3. it adds a deterministic workpad extraction/recovery contract
4. it makes human approval into `Merging` explicit
5. it adds an operator visibility contract for observe mode
6. it requires local and remote safety brakes before auto-merge

## 15. Recommended next step

Use this architecture as the basis for the companion docs:

- `docs/PR_AUTOMATION_SCHEMA_PROPOSAL.md`
- `docs/WORKFLOW_PR_AUTOMATION_DRAFT.md`

Implementation should only begin after those docs reflect:

- phase-driven wait semantics
- durable metadata
- rollout safety
- shorter policy-driven prompts
- clear operator controls

## 16. Companion docs

- `docs/PR_AUTOMATION_REVIEW_SYNTHESIS.md`
- `docs/PR_AUTOMATION_SCHEMA_PROPOSAL.md`
- `docs/WORKFLOW_PR_AUTOMATION_DRAFT.md`
