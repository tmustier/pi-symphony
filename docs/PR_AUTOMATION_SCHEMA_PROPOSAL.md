# PR Automation Schema and Runtime Proposal

Status: Draft proposal (revised after review)

This document proposes the config and runtime contract needed to support the revised PR automation design described in:

- `docs/ORCHESTRATED_PR_FLOW.md`
- `docs/PR_AUTOMATION_REVIEW_SYNTHESIS.md`
- `docs/WORKFLOW_PR_AUTOMATION_DRAFT.md`

The focus here is practical: what needs to change in the current Symphony + Pi code layout so the workflow contract becomes implementable and safe.

## 1. Current code touchpoints

Primary modules:

- `orchestrator/elixir/lib/symphony_elixir/config/schema.ex`
- `orchestrator/elixir/lib/symphony_elixir/config.ex`
- `orchestrator/elixir/lib/symphony_elixir/workflow.ex`
- `orchestrator/elixir/lib/symphony_elixir/prompt_builder.ex`
- `orchestrator/elixir/lib/symphony_elixir/agent_runner.ex`
- `orchestrator/elixir/WORKFLOW.md`
- `examples/WORKFLOW.example.md`

Current workflow front matter supports sections such as:

- `tracker`
- `polling`
- `workspace`
- `worker`
- `agent`
- `codex`
- `pi`
- `hooks`
- `observability`
- `server`

It does **not** yet model:

- orchestration phase behavior
- rollout mode
- ownership gating
- structured self-review policy
- merge executor / approval policy
- durable workpad metadata contract
- operator visibility requirements

## 2. Revised proposal summary

The earlier proposal added only `pr` and `review`. That is not enough.

The revised schema proposal adds five policy areas:

- `orchestration`
- `rollout`
- `pr`
- `review`
- `merge`

The first implementation can still let the Pi worker perform GitHub operations via `gh` or helper tools. But the schema must be rich enough to express the workflow safely and let the runtime validate obvious misconfigurations before boot.

## 3. Canonical references

To reduce drift across docs:

- the **canonical orchestration phase table** lives in `docs/ORCHESTRATED_PR_FLOW.md` §4.1
- the **canonical review output contract** lives in this document
- the workflow draft should reference these canonical definitions rather than redefining them

## 4. Proposed workflow config surface

### 4.1 `orchestration`

Purpose:
- define machine-facing execution semantics
- distinguish passive waiting from active continuation
- define ownership gating
- define where orchestration metadata lives
- bound rework oscillation

Suggested shape:

```yaml
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
```

Suggested semantics:

- `phase_store` — durable storage location for orchestration metadata; initially `workpad`
- `default_phase` — phase assigned when no metadata exists yet
- `passive_phases` — phases that are polled but should not be continuation-retried immediately
- `max_rework_cycles` — circuit breaker for repeated rework loops on the same issue/PR lineage
- `ownership.required_label` — label required before post-PR automation acts
- `ownership.required_workpad_marker` — marker proving the issue is using Symphony’s workpad contract

Phase values must come from the canonical phase table in `docs/ORCHESTRATED_PR_FLOW.md` §4.1.

### 4.2 `rollout`

Purpose:
- gate what side effects are allowed in a given deployment stage
- provide kill-switch / preflight affordances

Suggested shape:

```yaml
rollout:
  mode: observe
  preflight_required: true
  kill_switch_label: no-symphony-automation
  kill_switch_file: /tmp/pi-symphony.pause
```

Suggested semantics:

- `mode` — `observe`, `mutate`, or `merge`
- `preflight_required` — require validation/preflight before enabling side-effectful modes
- `kill_switch_label` — if present on the issue or PR, automation must stop
- `kill_switch_file` — local sentinel file that disables mutation/merge even if remote labels are unavailable

### 4.3 `pr`

Purpose:
- govern PR publication and PR comment behavior

Suggested shape:

```yaml
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
```

Suggested semantics:

- `auto_create` — whether a PR may be created automatically after validation + push
- `base_branch` — target base branch
- `reuse_branch_pr` — whether to reuse an existing branch PR
- `closed_pr_policy` — what to do if the matching branch PR is already closed or merged (`new_branch`, `reopen`, `stop`)
- `attach_to_tracker` — whether to attach or link the PR back to the tracker issue
- `required_labels` — labels the worker should ensure are present on the PR
- `review_comment_mode` — `off`, `create`, or `upsert`
- `review_comment_marker` — marker string used to find/update the persistent review comment

### 4.4 `review`

Purpose:
- define self-review behavior and its output contract

Suggested shape:

```yaml
review:
  enabled: true
  agent: pr-reviewer
  output_format: structured_markdown_v1
  max_passes: 2
  fix_consideration_severities:
    - P0
    - P1
    - P2
```

Suggested semantics:

- `enabled` — whether self-review is enabled
- `agent` — the subagent to invoke
- `output_format` — expected review output contract
- `max_passes` — total review passes allowed for a given HEAD lineage
- `fix_consideration_severities` — severities that must be explicitly evaluated for possible fixes

Naming note:

`fix_consideration_severities` is more accurate than `blocking_severities`. These findings are not automatically merge-blocking by name alone; they are the set the worker must explicitly evaluate.

### 4.5 `merge`

Purpose:
- define merge execution behavior and safety gates

Suggested shape:

```yaml
merge:
  mode: auto
  executor: land_skill
  method: squash
  require_green_checks: true
  require_head_match: true
  require_human_approval: true
  approval_states:
    - Merging
```

Suggested semantics:

- `mode` — `disabled` or `auto`; rollout mode still caps behavior globally
- `executor` — `gh`, `land_skill`, or another supported merge path
- `method` — `merge`, `squash`, or `rebase`
- `require_green_checks` — all required checks must be green before merge
- `require_head_match` — merge may proceed only if the PR head SHA still matches the reviewed/expected SHA
- `require_human_approval` — whether merge requires a human-controlled tracker approval lane
- `approval_states` — tracker states from which merge may be executed, e.g. `Merging`

## 5. Workpad metadata contract

This is not purely workflow config, but it is part of the runtime contract and must be documented alongside the schema.

Minimum durable metadata fields:

```yaml
symphony:
  schema_version: 1
  owned: true
  phase: waiting_for_checks
  rework_cycles: 0
  branch: thomas/example
  pr:
    number: 123
    url: https://github.com/org/repo/pull/123
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
```

Runtime expectations:

1. review pass count is keyed to HEAD SHA continuity, not just issue state
2. comment upsert uses `review.comment_id` when available
3. merge uses `pr.head_sha` and `merge.last_attempted_head_sha` to avoid stale merges
4. passive waiting reasons are explicit and inspectable
5. observation fields are updated even in observe mode
6. `schema_version` must be required so future metadata migrations are explicit

### 5.1 Canonical `waiting.reason` values

`waiting.reason` should be validated against a small canonical enum, matching the architecture doc:

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

This keeps observe-mode status readable and comparable across runs.

## 6. Workpad extraction and fallback rules

The runtime should use deterministic workpad parsing.

### 6.1 Extraction

1. Find the active issue workpad comment by the stable heading marker `## Symphony Workpad`.
2. Parse the first fenced `yaml` block immediately following that heading as canonical metadata.
3. Ignore any later YAML blocks in the same comment for machine purposes.

### 6.2 Fallback

- if no metadata block exists, initialize a minimal `schema_version: 1` block and continue
- if the block is malformed or ambiguous, preserve the raw content, rewrite a canonical block, set phase `blocked`, and stop in mutate/merge modes

This is the safe default for H2-style metadata ambiguity.

## 7. `Config.Schema` changes

### 7.1 Add embedded schema modules

Add new modules alongside the existing embedded schema modules in:

- `orchestrator/elixir/lib/symphony_elixir/config/schema.ex`

Recommended modules:

- `Orchestration`
- `OrchestrationOwnership`
- `Rollout`
- `Pr`
- `Review`
- `Merge`

### 7.2 Root schema additions

Add to the top-level settings schema:

```elixir
embeds_one(:orchestration, Orchestration, on_replace: :update)
embeds_one(:rollout, Rollout, on_replace: :update)
embeds_one(:pr, Pr, on_replace: :update)
embeds_one(:review, Review, on_replace: :update)
embeds_one(:merge, Merge, on_replace: :update)
```

### 7.3 Unknown-key handling

The earlier proposal relied on `cast/4`, which risks silently ignoring misspelled keys.

For safety-critical policy, the runtime should reject unknown keys in these sections rather than silently falling back to defaults.

This is especially important for fields like:
- `review_comment_mode`
- `fix_consideration_severities`
- `require_head_match`
- `kill_switch_label`
- `kill_switch_file`
- `max_rework_cycles`

## 8. `Config.validate!()` semantics

Recommended semantic validation rules:

### 8.1 Rollout and merge

1. `rollout.mode == "observe"` must prevent merge mutations regardless of `merge.mode`
2. `rollout.mode == "mutate"` must prevent automatic merge
3. `rollout.mode == "merge"` requires `preflight_required == true` to have been satisfied out-of-band or via explicit operator action
4. if `kill_switch_file` is configured and present, mutation and merge must be disabled regardless of other settings

### 8.2 Review

5. `review.enabled` requires `review.agent`
6. `review.enabled` requires `review.output_format`
7. `review.max_passes` must be greater than `0`
8. `review.output_format` must be a known structured contract, not freeform text

### 8.3 PR

9. `pr.review_comment_mode == "upsert"` requires `pr.review_comment_marker`
10. `pr.closed_pr_policy` must be one of `new_branch`, `reopen`, `stop`
11. `pr.auto_create` should **not** be required for reuse-only workflows

### 8.4 Merge

12. `merge.executor == "land_skill"` may require additional repo-local skill validation
13. `merge.require_human_approval == true` requires non-empty `merge.approval_states`
14. `merge.approval_states` should be consistent with the tracker states used by the workflow
15. if `merge.require_human_approval == true`, worker-driven promotion into approval states must be disallowed by runtime policy

### 8.5 Orchestration

16. `orchestration.passive_phases` must be a subset of the canonical phase enum
17. `orchestration.default_phase` must be a known canonical phase
18. `orchestration.max_rework_cycles` must be greater than `0`
19. if ownership gating is configured, required fields must be present and non-empty

## 9. PromptBuilder and template rendering changes

Today `PromptBuilder.build_prompt/2` renders only:

- `attempt`
- `issue`

That is not enough for a policy-driven workflow.

### 9.1 Proposed template variables

Expose policy to the prompt:

```elixir
%{
  "attempt" => attempt,
  "issue" => issue_map,
  "policy" => %{
    "orchestration" => orchestration_map,
    "rollout" => rollout_map,
    "pr" => pr_map,
    "review" => review_map,
    "merge" => merge_map
  }
}
```

### 9.2 Rendering contract

Prompt examples assume:

- Liquid-style templates rendered through the current `Solid` path
- strict variables and strict filters
- failure on missing `policy.*` fields rather than silent blanking

This should be documented as part of the workflow contract because missing variables in unattended automation are dangerous.

## 10. Runtime behavior proposal

### 10.1 Candidate selection vs continuation

The runtime should use:

- `tracker.active_states` to decide what gets polled
- workpad `phase` plus `orchestration.passive_phases` to decide what gets immediate continuation

This is the key change required to avoid busy-looping on waiting tickets.

### 10.2 Helper operations required before unattended merge

Before full merge automation, introduce helper operations for at least:

- `find_or_create_pr`
- `upsert_review_comment`
- `inspect_pr_state`
- `merge_if_head_matches`

`inspect_pr_state` should be usable during passive polling from persisted PR metadata alone (for example by recovering repo context from the PR URL) so the runtime can refresh gate summaries and passive phase transitions without requiring a fresh worker run.

These can begin as worker-facing helper tools or Pi extensions. They do not need to be orchestrator-native immediately, but they should become runtime-enforced before unattended merge is turned on.

### 10.3 Review pass accounting

`review.max_passes` must be enforced against durable metadata, not ephemeral memory.

Recommended rule:

- a review pass counts only after its result is successfully persisted
- pass accounting is keyed to the reviewed head SHA
- if a new commit appears, the old review result is no longer sufficient for merge
- the worker writes the structured review artifact to `.symphony/review.md` with a leading `<!-- symphony-review-head: <sha> -->` line, which the runtime uses as the canonical source for durable review comment upsert

## 11. Canonical structured reviewer contract

Canonical first contract:

```yaml
output_format: structured_markdown_v1
```

Required per-finding fields:

- `id`
- `severity`
- `title`
- `summary`
- `why_it_matters`
- `suggested_fix`

This is the canonical definition; other docs should reference this section rather than redefining it.

## 12. Observe-mode visibility contract

Observe mode is only useful if operators can see what Symphony observed and what it would do next.

Minimum runtime behavior in observe mode:

- update `observation.last_observed_at`
- update `observation.next_intended_action`
- update `observation.rollout_mode`
- update concise `observation.gates`
- surface these fields in the dashboard/API when available

This is not optional; without it, observe mode is not operator-usable.

## 13. Suggested implementation order

1. add `orchestration`, `rollout`, `pr`, `review`, and `merge` schema support
2. add semantic validation and unknown-key rejection
3. expose `policy.*` to `PromptBuilder`
4. document and implement the durable workpad metadata contract
5. implement passive-phase continuation behavior
6. implement workpad extraction/recovery rules
7. add helper operations for PR/comment inspection and upsert
8. enable observe mode with dashboard/workpad visibility
9. enable mutate mode
10. only then consider merge mode

## 14. Recommended implementation boundary

The first code milestone should **not** include unattended merge.

Recommended first milestone:

- schema support
- prompt policy exposure
- workpad metadata contract
- passive-phase semantics
- observe-only rollout mode
- ownership gating
- operator visibility contract
- local and remote kill switches

Only after that is stable should the runtime add:

- comment upsert
- review pass enforcement
- merge-if-head-matches
- auto-merge
