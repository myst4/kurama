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
`execution_mode`, `compliance_mode`, `tdd.enabled`, `tdd.single_test_command`) ONCE and propagate them
into every sub-agent prompt — a propagated value always wins over any stale value in `config.yaml` or
the context artifact.

`sdd-ff` IMPLIES `execution_mode: auto` for every phase it fast-forwards, regardless of the configured
value — fast-forwarding IS the auto behavior. Propagate `auto` (not the stored `execution_mode`) so the
downstream phases and gates agree this run is unattended. The universal stop conditions in step 3 still
apply.

### 2. Fast-forward the remaining PLANNING phases (default scope)

Run the remaining planning phases from the **Canonical Phase DAG** in
`skills/_shared/sdd-phase-common.md`, resuming from the current state:

```
standard:  propose → (spec ‖ design) → tasks
small:     propose → tasks
```

**Announce the gate you are skipping.** `sdd-ff` starts at `propose`: it never explores and it
never brainstorms. That is the point of the fast path — a user typing `/sdd-ff` is saying *I know
what I want* — but it must be an EXPLICIT bypass, never an accidental one. Before delegating
`sdd-propose`, check for an `explore` artifact and a `brainstorm` ledger (`sdd/{change-name}/explore`
and `sdd/{change-name}/brainstorm`, or `exploration.md` / `brainstorm.md` in openspec/hybrid). When
NEITHER exists, print exactly one line and continue:

> No exploration or brainstorm exists for `{change-name}` — fast-forwarding straight to proposal.
> Use `/sdd-new {change-name}` if you want the gate.

It is a **notice, not a question**: it never stops the run and never asks, so `auto` is unaffected.
When either artifact exists, say nothing — the gate already happened.

**Read the proposal's `## Change Size` before sequencing.** For `small`, `sdd-propose` already
wrote the spec and design as sections inside the proposal, so the separate `sdd-spec` and
`sdd-design` delegations are skipped — `tasks` reads them inline. An absent or unrecognized
size means `standard`: never guess `small`, and never fail on the missing section (changes
created before this existed have none).

Auto-continue between phases — do NOT stop for user approval between planning phases. On the
`standard` path `spec` and `design` MAY run in parallel; `tasks` reconciles them. Pass each phase's required upstream by reference
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
- `sdd-ff` always runs in `auto`: it fast-forwards regardless of the configured `execution_mode` and
  propagates `auto` downstream — the stop conditions below (blocked, FAIL/CRITICAL, implementation
  boundary, never auto-archive) are what bound the run, not a `supervised` setting.
- Default scope is planning (propose → spec → design → tasks); stop at the implementation boundary.
- Stop immediately on any `status: blocked` or FAIL/CRITICAL verdict.
- Never auto-archive; archive is an explicit, verify-gated, potentially destructive step.
- Resolve and propagate pipeline settings once; the propagated value wins on conflict.
- Present a single combined summary at the end, not a summary per phase.
