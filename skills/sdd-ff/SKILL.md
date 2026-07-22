---
name: sdd-ff
description: >
  Fast-forward an SDD change through its remaining planning phases with auto-continue, stopping only at
  a blocked status or a failing gate. This is a user-invocable ORCHESTRATOR entry point — invoke it as
  `/sdd-ff <change-name>`.
  Trigger: When the user says "sdd ff", "fast-forward", "fast forward the plan", "avanza el plan",
  "run through planning", or asks to batch the remaining planning phases without stopping between each.
license: MIT
metadata:
  author: gentleman-programming
  version: "1.0"
---

## What This Skill Is

`sdd-ff` is a **meta-skill**: it describes **orchestrator** behavior, not executor behavior. It is the
deliberate exception to the executor rule — the same role the OpenCode meta-command
`examples/opencode/commands/sdd-ff.md` fills by routing to the `sdd-orchestrator` agent. When it runs,
YOU are the coordinator: you delegate each phase to a phase sub-agent (or the matching native agent
under `examples/claude-code/agents/`), auto-continue between them without asking, and present ONE
combined summary at the end. Do NOT do phase work inline.

It is user-invocable as `/sdd-ff <change-name>`.

## Orchestration Flow

### 1. Recover state and settings

Recover the change's DAG state via the **Recovery Rule** in `skills/_shared/persistence-contract.md`
(same procedure as `sdd-continue`). Read the pipeline settings (`artifact_store.mode`,
`compliance_mode`, `tdd.enabled`, `tdd.single_test_command`) ONCE and propagate them into every
sub-agent prompt — a propagated value always wins over any stale value in `config.yaml` or the context
artifact.

### 2. Fast-forward the remaining PLANNING phases (default scope)

Run the remaining planning phases from the **Canonical Phase DAG** in
`skills/_shared/sdd-phase-common.md`, resuming from the current state:

```
propose → (spec ‖ design) → tasks
```

Auto-continue between phases — do NOT stop for user approval between planning phases. `spec` and
`design` MAY run in parallel; `tasks` reconciles them. Pass each phase's required upstream by reference
(topic key / path); sub-agents read from the backend. This preserves the established `sdd-ff` scope:
fast-forward planning up to (but not into) implementation.

### 3. Stop conditions (the only reasons to halt)

Halt the fast-forward and hand back to the user when ANY of these fire:

- A delegated phase returns **`status: blocked`** (e.g. a required upstream artifact is missing) —
  surface it and recommend the phase that produces the missing input.
- The **implementation boundary** is reached: after `tasks`, `sdd-ff` stops by default and hands off for
  review before `/sdd-apply`. Implementing code unreviewed is a deliberate human gate.
- A phase reports a **FAIL / CRITICAL** verdict (relevant if the user explicitly extends the run through
  `apply → verify`, see below).

If the user explicitly asks to fast-forward implementation too, continue `apply → verify` with the same
auto-continue behavior, still halting at the first `status: blocked` or a verify FAIL/CRITICAL.
**Never auto-run `archive`** — archiving is destructive (it merges deltas into the source of truth) and
always requires an explicit, separately gated go-ahead with a passing verify report.

### 4. Combined summary

Present ONE combined summary after all fast-forwarded phases complete (not between each), listing what
each phase produced (its **Section D** `executive_summary`) and the recommended next action.

## Rules

- You are the ORCHESTRATOR here. Delegate every phase; never execute planning work inline.
- Auto-continue between planning phases; the whole point of `sdd-ff` is to skip inter-phase gates.
- Default scope is planning (propose → spec → design → tasks); stop at the implementation boundary.
- Stop immediately on any `status: blocked` or FAIL/CRITICAL verdict.
- Never auto-archive; archive is an explicit, verify-gated, potentially destructive step.
- Resolve and propagate pipeline settings once; the propagated value wins on conflict.
- Present a single combined summary at the end, not a summary per phase.
