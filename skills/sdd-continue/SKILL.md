---
name: sdd-continue
description: >
  Resume an in-progress SDD change: recover persisted state and run the next dependency-ready phase.
  This is a user-invocable ORCHESTRATOR entry point — invoke it as `/sdd-continue [change-name]`.
  Trigger: When the user says "sdd continue", "continue the change", "continuar", "resume SDD",
  "what's next", or asks to pick up an existing change after a pause or compaction.
license: MIT
metadata:
  author: kurama
  version: "1.0"
---

## What This Skill Is

`sdd-continue` is a **meta-skill**: it describes **orchestrator** behavior, not executor behavior. It
is the deliberate exception to the executor rule — the same role the OpenCode meta-command
`examples/opencode/commands/sdd-continue.md` fills by routing to the `sdd-orchestrator` agent. When it
runs, YOU are the coordinator: you recover state, decide the next phase, delegate it to a phase
sub-agent (or the matching native agent under `examples/claude-code/agents/`), and synthesize the
result. Do NOT do phase work inline.

It is user-invocable as `/sdd-continue [change-name]`. `[change-name]` is optional — omit it to resume
the single active change; supply it to disambiguate when several are in flight.

## Orchestration Flow

### 1. Recover state (per the persistence contract)

Recover the DAG state for the change using the **State Persistence** section in
`skills/_shared/persistence-contract.md`:

- Read `openspec/changes/{change-name}/state.yaml` — the authoritative, committed cycle state.
- Fall back to `.kurama/sdd/{change-name}/state.md`, the machine-local cycle marker the write
  guard reads. Check it with `test -f` or Read — never a finder; `.kurama/` is hidden AND
  gitignored.

When you advance the DAG, write both.

Also read the pipeline settings (`execution_mode`, `compliance_mode`, `tdd.enabled`,
`tdd.single_test_command`) once and propagate them into every sub-agent prompt
(propagated value wins).

**Stale `artifact_store.mode`.** If `openspec/config.yaml` still carries an `artifact_store.mode`
key with ANY value, print exactly one line and continue — never
block, never rewrite the user's config:

> `artifact_store.mode` is unsupported since 6.3.0; artifacts are files under `openspec/`. Move
> `.kurama/sdd/<change>/*.md` to `openspec/changes/<change>/` if you want the old ones. `execution_mode` (`supervised` | `auto`, default `supervised`) decides
whether the gate in step 4 stops for the user or auto-advances.

### 2. Determine the next dependency-ready phase

Using the recovered state and which artifacts already exist, compute the next phase from the **Canonical
Phase DAG** in `skills/_shared/sdd-phase-common.md`:

```
explore → propose → (spec ‖ design) → tasks → apply → verify → archive
```

When both `spec` and `design` are outstanding and their upstream (`propose`) is ready, they MAY be
launched in parallel (`spec ‖ design`); `tasks` is the reconciliation point.

**Check the proposal's `## Change Size` before computing the next phase.** For a `small`
change the spec and design were collapsed into the proposal, so `spec` and `design` are NOT
outstanding — the next dependency-ready phase after `propose` is `tasks`. Treat an absent or
unrecognized size as `standard`, which is what every change created before this existed will
have; never fail on the missing section.

### 3. Delegate the next phase

Delegate the phase sub-agent(s). Pass required upstream artifacts by reference (path); the
sub-agent reads the files itself. Inject the pipeline settings and any auto-resolved
Project Standards.

### 4. Present and gate

Present the phase result (its **Section D** `executive_summary` and `next_recommended`). What happens
next depends on `execution_mode`:

- **`supervised` (default)**: Ask the user whether to proceed to the following phase and STOP.
  `sdd-continue` advances ONE dependency step per invocation — use `/sdd-ff` to batch planning phases.
- **`auto`**: Do NOT stop to ask — auto-advance through the dependency-ready phases in the same
  invocation, halting only on a `status: blocked` return, a `sdd-verify` FAIL/CRITICAL, or before
  `archive` (which is never auto-run in any mode). Present ONE combined summary at the end.

## Rules

- You are the ORCHESTRATOR here. Delegate the next phase; never execute it inline.
- Always recover state from the store that matches the resolved mode before deciding the next phase.
- Honor `execution_mode`: in `supervised` (default) advance exactly one dependency-ready step (or one
  parallel `spec ‖ design` pair) per invocation, then stop and ask; in `auto` auto-advance the
  dependency-ready phases, halting only on `status: blocked`, a verify FAIL/CRITICAL, or before
  `archive` (never auto-run in any mode).
- Pass upstream artifacts by reference, not by inlining their content.
- If a required upstream artifact is missing, the delegated phase returns `status: blocked` naming it —
  surface that and recommend the phase that produces it.
- Reap the phase agent as soon as you have synthesized its envelope — the delegation is not complete
  until the agent is shut down, and the only reason to keep one alive is a follow-up message you name
  when you decide it (`skills/_shared/skill-resolver.md` → *Step 5*).
