# Design: dynamic model validation to prevent workers using deprecated models

**Issue:** [SYM-27](https://linear.app/issue/SYM-27)
**Status:** Proposed
**Related:** [SYM-20](https://linear.app/issue/SYM-20) (permanent error classification), [SYM-22](https://linear.app/issue/SYM-22) (per-issue model routing)

## Problem

Workers and agents frequently use deprecated model names sourced from their LLM
training data. For example, a worker might invoke a subagent with
`claude-sonnet-4-20250514` instead of the current `claude-sonnet-4-6`. This
causes `Model not found` errors that — prior to SYM-20 — retried indefinitely.

There are two distinct failure surfaces:

1. **WORKFLOW.md `pi.model.model_id` is wrong.** The orchestrator's own configured
   model is deprecated or misspelled. This fails on *every* dispatch.

2. **Worker subagent calls use stale model names.** The worker's LLM picks model
   names from training data when spawning subagents. This fails mid-turn,
   wastes tokens, and may exhaust retry budgets.

The static model table embedded in the default prompt template (`config.ex
@default_prompt_template`) mitigates surface (2) but introduces its own
staleness problem: when models are added or retired, the table must be manually
updated in source code.

## Current state

| Layer | Mechanism | Limitation |
|---|---|---|
| Prompt template | Static markdown table of current/deprecated models | Goes stale with the source code |
| Preflight task | `mix symphony.preflight` checks model against a hardcoded `@deprecated_models` map | Incomplete coverage; no live validation |
| Worker runtime | `RpcClient.configure_turn` calls `set_model` — Pi rejects unknown models with an RPC error | Error surfaces only after workspace setup, session start, etc. |
| Error classification (SYM-20) | Permanent errors stop retries | Catches the symptom, not the cause |

## Approach evaluation

### A. Pre-flight model validation (orchestrator startup)

At startup (or during `mix symphony.preflight`), run `pi --list-models`,
parse the output, and verify that `pi.model.model_id` exists in the returned
list.

**Implementation sketch:**

```elixir
defmodule SymphonyElixir.Pi.ModelRegistry do
  @spec list_available_models() :: {:ok, list(model_entry())} | {:error, term()}
  def list_available_models do
    {output, 0} = System.cmd("pi", ["--list-models"])
    parse_model_table(output)
  end

  @spec validate_configured_model(Schema.t()) :: :ok | {:error, {:unknown_model, String.t()}}
  def validate_configured_model(settings) do
    with {:ok, models} <- list_available_models() do
      configured = "#{settings.pi.model.provider}/#{settings.pi.model.model_id}"
      if Enum.any?(models, &(&1.qualified_name == configured)),
        do: :ok,
        else: {:error, {:unknown_model, configured}}
    end
  end
end
```

**Pros:**

- Catches config typos before any worker is dispatched
- Zero token cost — validation happens once at startup
- Integrates cleanly with existing `mix symphony.preflight` infrastructure
- `pi --list-models` is a stable, documented Pi CLI interface

**Cons:**

- Only validates the orchestrator's own configured model
- Does not help workers that hardcode model names in subagent calls
- Adds a startup dependency on the `pi` binary being available and functional

**Verdict:** Necessary but insufficient on its own.

### B. Dynamic model list injection into worker prompt

At dispatch time, run `pi --list-models`, format the result, and inject it
into the worker prompt — replacing the static table in `@default_prompt_template`.

**Implementation sketch:**

The `PromptBuilder` already uses Solid templates. Add a new template variable
`{{ available_models }}` (or replace the static model section entirely):

```elixir
# In PromptBuilder.build_prompt/2
models_section = ModelRegistry.format_models_for_prompt()
# Inject into template variables alongside issue, policy, etc.
```

**Token budget impact:**

The output of `pi --list-models` is ~4 KB of text. At roughly 1 token per 4
characters, that's ~1,000 tokens. The existing static model table in the
default prompt is ~800 tokens. The incremental cost of switching from static
to dynamic is therefore **~200 additional tokens per dispatch** — negligible
against the 200K–1M context windows of current models.

However, the full model list contains many entries workers should never use
(legacy dated models, third-party provider variants). A filtered view — showing
only recommended models — would be smaller and more actionable.

**Pros:**

- Always reflects the actual runtime model availability
- Eliminates the static table maintenance burden
- Workers see models that genuinely exist, not a curated list that may diverge
- Directly addresses the subagent model selection problem

**Cons:**

- ~1,000 tokens per prompt (minor; can be reduced with filtering)
- Requires `pi --list-models` to succeed at dispatch time (if it fails, fall back
  to the static table or last-known-good list)
- Workers may still ignore the injected list — prompt injection is advisory, not
  enforced

**Verdict:** High value. Directly solves the most common failure mode (subagent
model selection from training data).

### C. Model alias resolution in the orchestrator

Maintain a `models.yml` in the repo mapping logical names (e.g., `best`,
`fast`, `light`) to current model IDs. The orchestrator resolves aliases at
config parse time.

```yaml
# models.yml
aliases:
  best: anthropic/claude-opus-4-6
  fast: anthropic/claude-sonnet-4-6
  light: anthropic/claude-haiku-4-5
  codex: openai-codex/gpt-5.4
```

```yaml
# WORKFLOW.md
pi:
  model:
    alias: best  # resolved to anthropic/claude-opus-4-6
```

**Pros:**

- Single file to update when models rotate
- Logical names are more stable than model IDs
- Could be consumed by workers too (if injected into prompt)

**Cons:**

- Still a static file that goes stale — just moves the maintenance target
- Adds a new config surface (`models.yml`) that all pi-symphony users must learn
- Does not help with subagent calls (workers still need to know actual model IDs)
- Alias indirection makes debugging harder ("which model is `best` today?")
- Overlaps with per-issue model routing (SYM-22) which already needs config-level
  model selection

**Verdict:** Low value relative to complexity. The maintenance problem it claims
to solve (updating model IDs) shifts rather than disappears. Per-issue model
routing (SYM-22) is a better place to introduce config-level model abstraction.

### D. Combination: pre-flight validation + dynamic prompt injection (A + B)

Validate at startup (approach A). Inject at dispatch time (approach B).

**Pros:**

- Covers both failure surfaces: config errors (A) and subagent model selection (B)
- Each component is simple; the combination is additive, not multiplicatively complex

**Cons:**

- Two calls to `pi --list-models` (once at startup, once per dispatch) — mitigated
  by caching with a TTL

**Verdict:** Best coverage with manageable complexity.

## Recommendation

**Implement approach D (A + B) with a shared caching layer.**

### Architecture

```
┌──────────────────────────────────────────────────────┐
│                  ModelRegistry                       │
│                                                      │
│  list_available_models/0 → cached pi --list-models   │
│  validate_model/1        → check model exists        │
│  format_for_prompt/0     → filtered markdown table   │
│  invalidate_cache/0      → force refresh             │
│                                                      │
│  Cache: ETS or process dictionary                    │
│  TTL: 5 minutes (configurable)                       │
│  Fallback: static table on CLI failure               │
└────────────┬─────────────────────┬───────────────────┘
             │                     │
    ┌────────▼────────┐   ┌────────▼────────┐
    │   Preflight /   │   │  PromptBuilder  │
    │   Startup       │   │  (dispatch)     │
    │                 │   │                 │
    │  validate that  │   │  inject dynamic │
    │  pi.model.id    │   │  model list     │
    │  exists in      │   │  into worker    │
    │  registry       │   │  prompt         │
    └─────────────────┘   └─────────────────┘
```

### Module: `SymphonyElixir.Pi.ModelRegistry`

New module in `orchestrator/elixir/lib/symphony_elixir/pi/model_registry.ex`.

Responsibilities:

1. **Fetch models** — shell out to `pi --list-models`, parse the tabular output
2. **Cache** — store parsed results with a configurable TTL (default 5 min)
3. **Validate** — check a `provider/model_id` pair against the cached list
4. **Format for prompt** — produce a filtered, compact markdown table for prompt
   injection (exclude legacy dated variants, show only the latest per family)
5. **Graceful degradation** — if `pi --list-models` fails, log a warning and fall
   back to the static table currently in `@default_prompt_template`

### Integration points

#### 1. Preflight validation (startup)

In `Mix.Tasks.Symphony.Preflight`, replace the static `@deprecated_models` map
check with a live `ModelRegistry.validate_model/1` call:

```elixir
defp check_model_config do
  case {Config.settings(), ModelRegistry.list_available_models()} do
    {{:ok, settings}, {:ok, models}} ->
      ModelRegistry.validate_configured_model(settings, models)

    {{:ok, settings}, {:error, _}} ->
      # Fallback to static deprecation check
      check_model_static(settings)

    {{:error, _}, _} ->
      {:warn, "Model", "cannot check — workflow config is invalid"}
  end
end
```

When the model is not found, produce a structured error:

```
❌ Model: anthropic/claude-sonnet-4-20250514 not found in pi --list-models output.
   Did you mean: anthropic/claude-sonnet-4-6?
   Run `pi --list-models` to see all available models.
```

#### 2. Prompt injection (dispatch time)

In `PromptBuilder.build_prompt/2`, replace the static model table with a
dynamically generated one from `ModelRegistry.format_for_prompt/0`.

The default prompt template changes from a hardcoded table to a template
variable:

```
## Available models

{{ available_models }}

### Rules
- When invoking subagents: pick from the table above
- NEVER specify a model from memory — always refer to this list
```

The `PromptBuilder` populates `available_models` at render time:

```elixir
defp build_template_variables(issue, settings, opts) do
  %{
    "issue" => issue_prompt_map(issue, settings),
    "policy" => Config.prompt_policy(),
    "attempt" => Keyword.get(opts, :attempt),
    "available_models" => ModelRegistry.format_for_prompt()
  }
end
```

#### 3. Orchestrator startup validation (optional hardening)

Add a model validation step to `Orchestrator.init/1` that fails the GenServer
startup if the configured model is not available. This catches errors even when
operators skip preflight:

```elixir
def init(_opts) do
  config = Config.settings!()

  case ModelRegistry.validate_configured_model(config) do
    :ok -> :ok
    {:error, {:unknown_model, model}} ->
      raise "Configured model #{model} not found. Run `pi --list-models`."
  end
  # ... rest of init
end
```

### Output filtering for prompt injection

The full `pi --list-models` output contains ~50 models. For prompt injection,
filter to a curated "recommended" subset:

1. **Exclude dated variants** — if both `claude-opus-4-6` and
   `claude-opus-4-5-20251101` exist, only show `claude-opus-4-6`
2. **Exclude legacy generations** — `claude-3-*` models when `claude-*-4-*` exist
3. **Group by use case** — "best for complex work", "fast", "lightweight"
4. **Include provider prefix** — workers need `anthropic/claude-opus-4-6` format

This keeps the injected table to ~10–15 rows (~300 tokens), smaller than the
current static table.

### Caching strategy

```elixir
defmodule SymphonyElixir.Pi.ModelRegistry do
  @cache_table :pi_model_registry
  @default_ttl_ms 300_000  # 5 minutes

  @spec list_available_models() :: {:ok, list(model_entry())} | {:error, term()}
  def list_available_models do
    case read_cache() do
      {:ok, models} -> {:ok, models}
      :miss -> fetch_and_cache()
    end
  end

  defp fetch_and_cache do
    case run_pi_list_models() do
      {:ok, models} ->
        write_cache(models)
        {:ok, models}
      {:error, _} = error ->
        error
    end
  end
end
```

ETS is preferred over process dictionary because the model list must be
accessible from multiple processes (preflight mix task, orchestrator GenServer,
prompt builder calls from worker Task processes).

### Interaction with SYM-22 (per-issue model routing)

SYM-22 adds per-issue model routing — dispatching different issues to different
models based on labels or issue metadata. The model validation design must
support this:

- **ModelRegistry.validate_model/1** must accept any `provider/model_id`, not
  just the single configured one. When SYM-22 adds model routing rules, each
  routed model should be validated at startup.

- **Prompt injection** remains useful regardless of per-issue routing: the
  worker still needs to know which models exist for subagent calls, independent
  of which model *it* is running on.

- **Config validation** — SYM-22 will likely add a `model_routing` config
  section to WORKFLOW.md. The preflight check should validate all models
  referenced in routing rules, not just `pi.model.model_id`.

The `ModelRegistry` module is designed as a shared service that both the
current single-model config and future per-issue routing can consume.

### Interaction with SYM-20 (permanent error classification)

SYM-20 classifies permanent errors (including `Model not found`) to stop
retrying. Model validation is complementary:

- **SYM-20** catches model errors *after* they happen and stops retries
- **SYM-27** prevents model errors *before* they happen

With both in place, the defense-in-depth story is:

1. Preflight/startup catches config-level model errors → operator fixes config
2. Dynamic prompt injection steers workers away from deprecated models → fewer
   subagent failures
3. SYM-20 error classification catches any remaining model errors → blocks
   instead of infinite retry

### Failure modes and graceful degradation

| Scenario | Behavior |
|---|---|
| `pi` binary not in PATH | Preflight: fail with clear message. Prompt: use static fallback table. |
| `pi --list-models` returns non-zero exit | Log warning. Use cached result if available, static fallback otherwise. |
| `pi --list-models` output format changes | Parse failure. Log warning. Use static fallback. |
| Configured model not in list | Preflight: hard fail with suggestion. Startup: hard fail. |
| Cache TTL expires during long run | Next `list_available_models()` call refreshes transparently. |

### Migration path

1. **Phase 1:** Add `ModelRegistry` module with fetch, parse, cache, validate.
   Wire into preflight (`mix symphony.preflight`). No prompt changes yet.

2. **Phase 2:** Wire `format_for_prompt/0` into `PromptBuilder`. Replace static
   model table in `@default_prompt_template` with `{{ available_models }}`.

3. **Phase 3:** Add startup validation to `Orchestrator.init/1`. Add model
   validation for SYM-22 routing rules when that feature ships.

### Risks and mitigations

| Risk | Mitigation |
|---|---|
| `pi --list-models` output format is not a stable API | Parse defensively. Fall back to static table on any parse error. Pin to known format; update parser if Pi changes. |
| Adding startup dependency on Pi binary | Preflight already requires Pi. Startup validation can be opt-in via `rollout.preflight_required`. |
| Workers ignore the injected model list | Expected — prompt injection is advisory. SYM-20 error classification is the safety net. |
| Token overhead of model list injection | ~300 tokens after filtering — smaller than current static table. Net token reduction. |

## Decision

Implement **approach D** (pre-flight validation + dynamic prompt injection)
with a shared `ModelRegistry` caching module, in three phases as described
above.
