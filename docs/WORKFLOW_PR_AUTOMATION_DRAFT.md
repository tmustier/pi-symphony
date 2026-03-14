# Booking-demo / THO `WORKFLOW.md` Draft for Orchestrated PR Automation

Status: Draft proposal (revised after review)

This document turns the revised PR automation design into a concrete `WORKFLOW.md` draft for the `Nexcade/booking-demo` / `THO` use case.

This is still a **proposed** workflow, not a currently-valid one. It assumes the policy/config support described in:

- `docs/ORCHESTRATED_PR_FLOW.md`
- `docs/PR_AUTOMATION_SCHEMA_PROPOSAL.md`
- `docs/PR_AUTOMATION_REVIEW_SYNTHESIS.md`

**Prerequisite callout:** this draft uses `policy.*` prompt variables that do **not** exist in the current repo yet. The draft only becomes valid after `PromptBuilder` is extended to expose policy maps into the workflow template context. Until then, treat this as a target-state draft rather than a drop-in runnable workflow.

Canonical references:

- canonical phase table: `docs/ORCHESTRATED_PR_FLOW.md` §4.1
- canonical review output contract: `docs/PR_AUTOMATION_SCHEMA_PROPOSAL.md` §11

## 1. What changed from the earlier workflow draft

The previous draft had four major problems:

1. it relied on `tracker.active_states` alone to model waiting
2. it overloaded `In Review`
3. it put too much policy directly in the prompt
4. it did not explain how observe mode would be legible to operators

This revised draft changes that by:

- introducing an explicit orchestration phase contract
- relying on a durable workpad metadata block for resumption
- using rollout mode and ownership gating
- shortening the prompt and referencing policy values
- adding explicit observe-mode visibility expectations

## 2. Recommended initial rollout front matter

This front matter is intentionally conservative: it assumes **observe mode first**.

```md
---
tracker:
  kind: linear
  api_key: "$LINEAR_API_KEY"
  team_key: "THO"
  project_slug: "10f58de5e214"
  active_states:
    - Todo
    - In Progress
    - In Review
    - Merging
    - Rework
  terminal_states:
    - Done
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
polling:
  interval_ms: 600000
workspace:
  root: /Users/thomasmustier/demo/booking-demo/.symphony/workspaces
worker:
  runtime: pi
agent:
  max_concurrent_agents: 1
  max_turns: 6
  max_retry_backoff_ms: 300000
codex:
  turn_timeout_ms: 3600000
  read_timeout_ms: 5000
  stall_timeout_ms: 300000
pi:
  command: /Users/thomasmustier/.local/bin/pi
  response_timeout_ms: 120000
  session_dir_name: .pi-rpc-sessions
  model:
    provider: openai-codex
    model_id: gpt-5.4
  thinking_level: xhigh
  extension_paths:
    - ../extensions/workspace-guard/index.ts
    - ../extensions/proof/index.ts
    - ../extensions/linear-graphql/index.ts
  disable_extensions: true
  disable_themes: true
orchestration:
  phase_store: workpad
  default_phase: implementing
  passive_phases:
    - waiting_for_checks
    - waiting_for_human
    - blocked
  max_rework_cycles: 3
  ownership:
    required_label: symphony
    required_workpad_marker: "## Symphony Workpad"
rollout:
  mode: observe
  preflight_required: true
  kill_switch_label: no-symphony-automation
  kill_switch_file: /tmp/pi-symphony.pause
pr:
  auto_create: true
  base_branch: main
  reuse_branch_pr: true
  closed_pr_policy: new_branch
  attach_to_tracker: true
  required_labels:
    - symphony
  review_comment_mode: upsert
  review_comment_marker: "<!-- symphony-review -->"
review:
  enabled: true
  agent: pr-reviewer
  output_format: structured_markdown_v1
  max_passes: 2
  fix_consideration_severities:
    - P0
    - P1
    - P2
merge:
  mode: auto
  executor: land_skill
  method: squash
  require_green_checks: true
  require_head_match: true
  require_human_approval: true
  approval_states:
    - Merging
hooks:
  timeout_ms: 1800000
  after_create: |
    set -eu
    git clone --reference-if-able /Users/thomasmustier/demo/booking-demo --origin origin --branch main --single-branch https://github.com/Nexcade/booking-demo.git .
    if ! git remote | grep -qx upstream; then
      git remote add upstream https://github.com/Nexcade/garage.git
    fi
    git remote set-url --push upstream DISABLED || true
    npm ci
observability:
  dashboard_enabled: true
  refresh_ms: 1000
  render_interval_ms: 16
server:
  port: 4042
  host: 127.0.0.1
---
```

## 3. Promotion path to the target end-state

Start with:

```yaml
rollout:
  mode: observe
```

Then progress to:

```yaml
rollout:
  mode: mutate
```

Only after passive-phase handling, workpad metadata, helper invariants, and observe-mode visibility are stable should this become:

```yaml
rollout:
  mode: merge
```

## 4. Workpad metadata contract expected by the prompt

This workflow assumes a durable metadata block in the issue workpad.

Illustrative shape:

````md
## Symphony Workpad

```yaml
symphony:
  schema_version: 1
  owned: true
  phase: implementing
  rework_cycles: 0
  branch: thomas/example
  pr:
    number: null
    url: null
    head_sha: null
  review:
    comment_id: null
    passes_completed: 0
    last_reviewed_head_sha: null
    last_fixed_head_sha: null
  merge:
    last_attempted_head_sha: null
  waiting:
    reason: null  # use canonical enum values from docs/ORCHESTRATED_PR_FLOW.md §5.1
    since: null
  observation:
    last_observed_at: null
    next_intended_action: null
    rollout_mode: observe
    gates: {}
```
```
````

The worker should treat this metadata as the source of truth for resumption.

## 5. Metadata extraction and fallback behavior

This draft assumes the runtime follows the deterministic extraction rules from:

- `docs/ORCHESTRATED_PR_FLOW.md` §6

Operationally, the worker should behave as follows:

- if the metadata block is missing, initialize a minimal `schema_version: 1` block and continue
- if the metadata block is malformed or duplicated ambiguously, preserve the raw content, rewrite a canonical block, set `phase: blocked`, record `waiting.reason: metadata_recovery_required`, and stop in mutate/merge modes

## 6. Proposed prompt body

This prompt is shorter on purpose. It assumes `PromptBuilder` exposes `policy.*` variables through the current Solid/Liquid rendering path with strict missing-variable behavior.

```md
You are an unattended Pi worker operating on the `Nexcade/booking-demo` repository.

Current issue:
- id: {{ issue.id }}
- identifier: {{ issue.identifier }}
- title: {{ issue.title }}
- state: {{ issue.state }}
- branch_name: {{ issue.branch_name }}
- url: {{ issue.url }}
- labels: {{ issue.labels }}

{% if issue.description %}
Issue description:
{{ issue.description }}
{% else %}
Issue description:
No description provided.
{% endif %}

Repository guardrails:
1. Read `AGENTS.md` first.
2. For bookings work, read `frontends/booking-agent/src/features/bookings/README.md` before editing.
3. Keep the UI product-like and keep bookings-specific docs local to the bookings area.
4. Prefer booking-owned wrappers/adapters. Do not add new runtime imports from `quotation-agent` into `booking-agent` unless the issue explicitly requires it.
5. If the issue involves cross-workspace imports, read `docs/cross-workspace-imports.md` and `src/features/bookings/lib/cross-workspace-imports.test.ts` before changing code.

Execution contract:
1. Never ask an interactive question. Gather context from the issue, branch, workpad, and PR first.
2. Obey the ownership gate from `policy.orchestration.ownership`. If the issue is not Symphony-owned, stop without side effects.
3. Obey both kill switches:
   - remote: `policy.rollout.kill_switch_label`
   - local: `policy.rollout.kill_switch_file`
4. Load and update the Symphony workpad metadata block. Treat `symphony.phase` as the source of truth for resumption.
5. If `symphony.phase` is missing, initialize it to `policy.orchestration.default_phase`.
6. If metadata is malformed or ambiguous, recover conservatively according to runtime policy and stop in mutate/merge modes.
7. If `symphony.rework_cycles` exceeds `policy.orchestration.max_rework_cycles`, set phase `blocked`, record a clear operator note, and stop.
8. If the task is unclear before a PR exists, record a blocker in the workpad, set `symphony.phase` to `blocked`, and stop. Do not move a no-PR ticket into `In Review`.

Phase behavior:
- `implementing` / `rework`
  - sync with `origin/{{ policy.pr.base_branch }}`
  - make the minimal correct change
  - run required validation
  - push the branch
  - if rollout mode allows it, create or reuse the PR
  - if review is enabled and rollout mode allows it, run `{{ policy.review.agent }}` using `{{ policy.review.output_format }}`
  - persist review metadata and set the next phase to `waiting_for_checks` or `waiting_for_human`
- `reviewing`
  - only run the bounded review/fix/re-review flow
  - never exceed `{{ policy.review.max_passes }}` total passes for the current HEAD lineage
- `waiting_for_checks` / `waiting_for_human` / `blocked`
  - do not restart implementation from scratch
  - inspect current external state and only act if a phase transition or required fix is needed
  - update `symphony.observation.last_observed_at`, `next_intended_action`, and gate summary before yielding
  - otherwise stop cleanly and yield back to orchestration
- `ready_to_merge` / `merging`
  - merge only if rollout mode and merge policy allow it
  - require green checks when `policy.merge.require_green_checks` is true
  - require the expected head SHA to still match when `policy.merge.require_head_match` is true
  - if `policy.merge.require_human_approval` is true, only merge when the tracker state is in `policy.merge.approval_states`; do not move the ticket into those states yourself

PR and review rules:
1. Reuse the existing branch PR when allowed by policy.
2. Do not create duplicate PRs for the same branch.
3. Write the structured review artifact to `.symphony/review.md` with a leading `<!-- symphony-review-head: <sha> -->` line before handoff so runtime-owned comment upsert can persist it durably.
4. Upsert one review comment marked with `{{ policy.pr.review_comment_marker }}` when policy says to do so.
5. Review findings are inputs to judgment, not mandatory edits.
6. Only findings in `{{ policy.review.fix_consideration_severities }}` must be explicitly evaluated for fixes.

Observe-mode visibility:
1. In `observe` mode, do not mutate GitHub state.
2. Always update workpad observation fields so an operator can see what you observed and what you would do next.
3. Your final summary should include the next intended action and why you did not perform it.

Validation policy:
1. Default validation for bookings work:
   - `cd frontends/booking-agent && npm run build`
   - `cd frontends/booking-agent && npm run test -- $(find src/features/bookings -name '*.test.ts' -o -name '*.test.tsx' | sort | tr '\n' ' ')`
2. If you touch non-bookings shared email preview code, also run directly affected tests there.
3. Treat non-zero exit codes as real failures.
4. Auth0 missing-env warnings during `npm run build` are acceptable if the build exits successfully.

Final response requirements:
- summarize what changed
- list validation commands and outcomes
- give the branch name
- give the PR number and URL if available
- mention the current phase and any workpad metadata updates
- mention the next intended action and gate status
- mention whether self-review ran and whether fixes were applied
- mention tracker updates performed
- mention blockers only if they are real
- keep it concise and factual
```

## 7. Notes on the revised state model

The critical change is that this draft no longer depends on raw `In Review` execution semantics.

Instead:

- `tracker.active_states` controls what gets polled
- `symphony.phase` plus `policy.orchestration.passive_phases` controls what gets immediate continuation

This is what prevents waiting tickets from busy-looping.

## 8. Notes on ambiguity and blocking

The earlier draft moved ambiguous work into `In Review`. That was too overloaded.

The revised rule is:

- if the task is ambiguous **before PR creation**, set phase `blocked` and yield
- if the tracker has a dedicated blocked/human-review state, use it
- otherwise keep the existing tracker state and rely on phase metadata plus a blocker note

## 9. Notes on rollout safety

This draft assumes:

- observe-only rollout first
- ownership gating before post-PR automation
- local and remote kill switches
- eventual helper invariants for PR upsert / comment upsert / merge-if-head-matches
- human-controlled promotion into `Merging` when human approval is required

It is intentionally more conservative than the earlier draft.

## 10. Short operator walkthrough

Expected lifecycle in this THO setup:

1. **Observe mode**
   - Symphony polls eligible issues
   - records phase / PR / gate state in the workpad
   - reports what it would do next
2. **Mutate mode**
   - Symphony may create/reuse PRs and run self-review
   - but still does not merge
3. **Human approval**
   - once review is acceptable, a human moves the issue to `Merging` if approval is required
4. **Merge mode**
   - Symphony merges only if the head SHA still matches and all gates are green

## 11. What must exist before switching to merge mode

Before setting `rollout.mode: merge`, the system should already have:

- durable workpad metadata updates
- passive-phase continuation behavior
- reliable PR reuse/upsert behavior
- reliable review comment upsert behavior
- merge-if-head-matches behavior
- a preflight validation path
- a tested local and remote kill switch
- operator-visible observe mode
