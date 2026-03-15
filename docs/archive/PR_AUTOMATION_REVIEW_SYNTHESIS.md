# PR Automation Review Synthesis and Action Plan

Status: Draft

## 1. Inputs

This synthesis is based on two review passes over the current proposal set:

Design docs reviewed:
- `docs/ORCHESTRATED_PR_FLOW.md`
- `docs/WORKFLOW_PR_AUTOMATION_DRAFT.md`
- `docs/PR_AUTOMATION_SCHEMA_PROPOSAL.md`

Review outputs:
- `tmp/reviews/robustness-review.md`
- `tmp/reviews/ux-review.md`

Reviewer lenses:
- **GPT-5.4 xhigh** — robustness, state-machine soundness, idempotency, rollout safety, config/runtime coherence
- **Claude Opus 4.6 xhigh** — UX for agents and humans/operators, with agent-friendly-design principles in scope

## 2. Executive summary

The reviews agree on the main conclusion:

> The direction is good, but the proposal is **not safe to implement as written**.

The current docs correctly identify that the slash-command flow must be adapted for orchestration, not copied directly. However, the current draft still overstates how much safety can be achieved with prompt wording and light config alone.

The most important gap is that the proposed waiting model does **not** match the current Symphony runtime.

Today, an issue that remains in an active state is aggressively continued. That means the current proposal to treat `In Review` as an active waiting state would likely create busy-loop behavior unless the runtime itself gains explicit support for wait states.

A second major theme is that critical behavior is still too prompt-driven. The docs need a stronger contract for:

- orchestration phase/state semantics
- durable per-issue metadata
- PR/comment/merge idempotency
- partial-failure recovery
- ownership gating and rollout controls

A third major theme is usability: the workflow prompt draft has become too dense and too policy-heavy, which makes it harder for both agents and humans to follow reliably.

## 3. Decision for the next iteration

We should **not** move from docs straight to implementation.

The next step should be a **doc revision pass** that tightens the architecture around:

1. runtime wait-state semantics
2. durable orchestration metadata
3. clearer phase/state modeling
4. smaller and more policy-driven worker prompts
5. rollout safety / operator controls

Only after those are specified should we start changing `Config.Schema`, `PromptBuilder`, or the booking-demo workflow.

## 4. Consolidated review themes

### 4.1 Runtime mismatch: waiting is not modeled correctly yet

This is the top technical blocker.

The current draft says Symphony can:

- move a ticket to `In Review`
- stop cleanly
- let polling resume later

But the current runtime does not behave that way for active issues. It continues them.

Implication:
- we cannot use `tracker.active_states` alone to represent both:
  - issues that should execute immediately
  - issues that should be polled but not continuation-retried

This needs an explicit runtime concept such as:
- `wait_states`
- `passive_active_states`
- or an equivalent orchestration phase/substate model

### 4.2 `In Review` is overloaded

The current docs let `In Review` mean too many different things:

- waiting for CI
- waiting for human review
- handling PR follow-up / feedback
- blocked because the task context is unclear

That creates ambiguous resume behavior and weakens operator legibility.

The next revision should either:

- restore a clearer multi-state model (`blocked`, `rework`, `waiting`, `merging`), or
- define an explicit orchestration phase/substate that disambiguates what `In Review` means at runtime

### 4.3 No durable orchestration metadata contract yet

Several important behaviors cannot be made safe without durable per-issue metadata, including:

- enforcing review pass count
- avoiding repeated review on the same HEAD SHA
- safe PR comment upsert
- safe merge retries
- knowing whether post-merge tracker updates succeeded

We need a concrete contract for persisting at least:

- PR number / URL
- review comment ID
- review pass count
- last reviewed HEAD SHA
- last fixed HEAD SHA
- last merge-attempted HEAD SHA
- current orchestration phase
- last known blocker / waiting reason

The most likely place to store this is the existing single workpad comment, but that needs to be specified explicitly.

### 4.4 Too much safety is still prompt-only

The current docs correctly argue that structured policy should live in config, but the workflow draft still relies too heavily on prose for behaviors like:

- PR reuse
- review comment upsert
- review loop bounding
- merge safety
- failure recovery

That is fragile for unattended retries.

The next revision should identify which behaviors are:

- **prompt-guided judgment**
- **config-defined policy**
- **runtime-enforced invariants**

### 4.5 Prompt density is becoming an agent-reliability problem

The UX review’s strongest point is that the proposed worker prompt is too long and scattered.

Problems caused by this:
- reduced compliance
- harder resumption behavior
- increased drift between config and prose
- harder maintenance for humans

The next revision should make the worker prompt shorter and narrower by:

- moving more values into policy/config
- referencing policy variables rather than hardcoding them
- moving recovery and orchestration semantics into a compact phase contract

### 4.6 Rollout safety is underspecified

Before any unattended merge behavior exists, we need stronger operational controls.

Missing or underdeveloped today:
- observe-only mode
- ownership gating
- kill switch
- migration plan for existing `In Review` issues
- preflight validation for repo permissions / branch protections
- dry-run validation path for operators

## 5. Prioritized action plan

## Priority 0 — revise the architecture before implementation

These are blockers for safe implementation.

### P0.1 Add explicit runtime wait-state semantics

**Why**
Current active-state behavior does not match the proposal.

**Action**
Revise the docs to introduce one of:
- `wait_states`
- `passive_active_states`
- explicit orchestration phases/substates separate from tracker states

**Deliverable**
Updated architecture doc that clearly explains:
- what gets polled
- what gets continued immediately
- what yields until external events change

### P0.2 Define a durable orchestration metadata contract

**Why**
Idempotent PR/review/merge behavior cannot be enforced without persisted metadata.

**Action**
Specify a durable state contract, likely in the workpad comment, covering:
- PR identity
- review comment identity
- review pass count
- last reviewed / fixed / merge-attempted SHAs
- orchestration phase
- waiting reason / blocker reason

**Deliverable**
A concrete section in the docs with the required metadata fields and update rules.

### P0.3 Unbundle `In Review`

**Why**
`In Review` currently represents too many incompatible situations.

**Action**
Choose one of two paths:

**Option A — richer tracker model**
- `In Progress`
- `Waiting` / `Human Review`
- `Rework`
- `Merging`
- `Done`
- `Blocked`

**Option B — keep existing tracker states, add explicit orchestration phase**
- ticket state remains human-friendly
- orchestration phase disambiguates runtime behavior

**Deliverable**
One chosen model, documented clearly.

### P0.4 Add failure-recovery design

**Why**
The reviews correctly flag partial-failure handling as a major operational gap.

**Action**
Document how the system behaves when:
- PR creation fails after push
- PR comment upsert fails after review output exists
- mergeability changes between check and merge
- merge succeeds but tracker update fails
- tracker update succeeds but merge fails
- self-review runs on a stale HEAD SHA

**Deliverable**
A failure-mode table or recovery section in the architecture docs.

## Priority 1 — make the policy model implementation-ready

These are not blockers for conceptual correctness, but should be resolved before code changes begin.

### P1.1 Expand the schema proposal beyond `pr` and `review`

**Why**
The current schema proposal is too thin for the workflow draft.

**Action**
Add explicit policy for:
- state roles / orchestration phase mapping
- merge executor (`gh`, land skill, queue, etc.)
- closed/merged PR recovery policy
- ownership gating
- observe-only / dry-run mode

**Deliverable**
Revised `PR_AUTOMATION_SCHEMA_PROPOSAL.md` with a fuller config surface.

### P1.2 Tighten semantics and naming

**Why**
Some names currently imply the wrong thing.

**Action**
Review and likely rename fields such as:
- `blocking_severities` -> something closer to `fix_consideration_severities` or `review_fix_severities`
- `max_passes` -> make clear it means total review passes, not retries in general

**Deliverable**
A clearer schema glossary with field semantics and examples.

### P1.3 Decide what must be runtime-enforced vs worker-enforced

**Why**
Prompt-only invariants are too weak for unattended PR/merge operations.

**Action**
Classify behaviors into:
- config-only
- runtime-enforced helper/invariant
- worker judgment

Likely runtime-enforced before auto-merge:
- find-or-create PR
- upsert single bot-owned review comment
- merge only if expected HEAD SHA still matches

**Deliverable**
A small enforcement matrix in the schema or architecture doc.

## Priority 2 — reduce workflow prompt complexity

### P2.1 Shorten the worker prompt

**Why**
The workflow draft is too dense for reliable agent compliance.

**Action**
Refactor the prompt around a smaller number of sections:
- repo guardrails
- phase contract
- validation policy
- final response requirements

Move policy values out of prose and into templated policy variables.

**Deliverable**
A revised workflow draft with a shorter prompt body.

### P2.2 Eliminate duplicated hardcoded policy values

**Why**
The docs currently violate their own “policy in config” principle.

**Action**
Stop hardcoding values like:
- `main`
- `symphony`
- `<!-- symphony-review -->`
- `pr-reviewer`
- `P0-P2`

Where those already exist in config.

**Deliverable**
Workflow prompt examples that reference policy values rather than restating them.

### P2.3 Reduce cross-doc duplication

**Why**
The same front matter and policy ideas are repeated across multiple docs, increasing drift risk.

**Action**
Recast the docs into a clearer structure:
- one architecture / rationale doc
- one schema / runtime contract doc
- one workflow example doc
- one review synthesis doc

Keep long YAML only in one example-oriented place.

**Deliverable**
Cleaner document boundaries and more cross-references instead of duplication.

## Priority 3 — add operator and rollout controls

### P3.1 Add ownership gating

**Why**
Without ownership gating, active post-PR automation can wake up on unrelated issues.

**Action**
Require one or more of:
- assignee gate
- label gate
- workpad marker
- issue attachment / branch linkage proving Symphony ownership

**Deliverable**
Documented ownership requirements in both workflow and rollout docs.

### P3.2 Add observe-only mode

**Why**
We need a safe path before enabling unattended merge.

**Action**
Add a rollout phase where Symphony can:
- detect existing PRs
- compute intended actions
- log or comment what it would do
- but not mutate GitHub state beyond safe read-only inspection

**Deliverable**
Observe-only phase in the rollout plan.

### P3.3 Add preflight / validation mode for operators

**Why**
Operators need a way to test workflow config and repo assumptions before enabling automation.

**Action**
Document a future `validate` / `doctor` / preflight mode that checks:
- workflow schema validity
- active-state implications
- GH auth / permissions
- branch protection / mergeability prerequisites
- required subagent availability

**Deliverable**
An operator affordance section in the schema/runtime proposal.

### P3.4 Add a kill switch

**Why**
Unattended merge needs a fast containment path.

**Action**
Define at least one simple kill-switch mechanism, such as:
- global config toggle
- workflow toggle
- label-based disablement
- issue-state-based disablement

**Deliverable**
A minimal kill-switch design in the rollout section.

## 6. Proposed doc revision sequence

The next doc pass should happen in this order:

### Step 1
Revise `docs/ORCHESTRATED_PR_FLOW.md` to:
- introduce explicit wait-state / phase semantics
- unbundle `In Review`
- add failure recovery
- add rollout safety controls

### Step 2
Revise `docs/PR_AUTOMATION_SCHEMA_PROPOSAL.md` to:
- add phase/state-role config
- add merge executor / recovery policy
- add ownership / observe-only / validate controls
- tighten naming and validation semantics

### Step 3
Revise `docs/WORKFLOW_PR_AUTOMATION_DRAFT.md` to:
- shorten the prompt substantially
- consume policy variables instead of hardcoding values
- align with the new runtime/phase model
- stop implying behavior the current runtime cannot yet support

## 7. Suggested doc outcomes after the next revision

After the next revision, the docs should answer these questions unambiguously:

1. What makes an issue eligible for polling?
2. What makes an issue continue immediately vs wait for an external event?
3. How does Symphony know a PR/issue is actually Symphony-owned?
4. Where is per-issue orchestration metadata stored?
5. How are review passes bounded across retries and resumes?
6. What exact conditions must hold before merge is attempted?
7. What happens when merge succeeds but tracker update fails, or vice versa?
8. How does an operator test the workflow safely before enabling mutation or merge?
9. How does the worker know which values come from policy vs repository prompt guidance?

## 8. Recommended implementation boundary after revision

Once the docs are revised, the first implementation slice should still be conservative.

Recommended first code milestone:

1. add schema/config support for PR/review/phase policy
2. expose policy into the prompt context
3. add observe-only behavior and ownership gating
4. add durable orchestration metadata contract
5. do **not** enable unattended merge yet

Only after that is stable should we implement:
- comment upsert
- bounded self-review enforcement
- merge-if-head-matches behavior
- full auto-merge

## 9. Short version

If we want to summarize this synthesis in one line:

> The next revision should shift the proposal from “prompt-guided idea” to “runtime-aware orchestration contract,” with explicit wait semantics, durable metadata, smaller prompts, and safer rollout controls.
