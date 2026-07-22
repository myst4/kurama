---
name: sdd-new
description: >
  Start a new SDD change: run exploration, then create a proposal, and gate before planning
  continues. This is a user-invocable ORCHESTRATOR entry point — invoke it as `/sdd-new <change-name>`.
  Trigger: When the user says "sdd new", "start a change", "nuevo cambio", "new SDD change",
  or asks to begin working on a named feature/fix through SDD.
license: MIT
metadata:
  author: gentleman-programming
  version: "1.0"
---

## What This Skill Is

`sdd-new` is a **meta-skill**: unlike the SDD phase skills (`sdd-explore`, `sdd-apply`, …), which
are EXECUTORS, this skill describes **orchestrator** behavior. It is the deliberate exception to the
executor rule — the same role the OpenCode meta-command `examples/opencode/commands/sdd-new.md` fills
by routing to the `sdd-orchestrator` agent. When this skill runs, YOU are the coordinator: you
delegate the real work to phase sub-agents (or the native `sdd-explore` / `sdd-propose` agents under
`examples/claude-code/agents/`) and synthesize their results. Do NOT do phase work inline.

It is user-invocable as `/sdd-new <change-name>`. `<change-name>` names the change and becomes the
`{change-name}` in every artifact topic key (`sdd/{change-name}/...`).

## Orchestration Flow

### 1. Init check

Confirm SDD is initialized for this project — a `sdd-init/{project}` context artifact (engram/none)
or `openspec/config.yaml` (openspec/hybrid) exists. Use the Recovery Rule from
`skills/_shared/persistence-contract.md` to look it up. If nothing is found, delegate `sdd-init`
first (it detects the stack, asks the explicit TDD question, and persists the pipeline settings) and
present its summary before continuing.

Read the pipeline settings (`artifact_store.mode`, `compliance_mode`, `tdd.enabled`,
`tdd.single_test_command`) ONCE and propagate them into every sub-agent prompt — a propagated value
always wins over any stale value in `config.yaml` or the context artifact.

### 2. Explore

Delegate `sdd-explore` for `<change-name>` to investigate the codebase and compare approaches. Inject
the resolved mode and any auto-resolved Project Standards. Present the exploration summary to the user.

### 3. Propose

Delegate `sdd-propose` to turn the exploration into a proposal (intent, scope, approach, rollback).
Pass the proposal's upstream (`sdd/{change-name}/explore`) by reference — the sub-agent reads it from
the backend; do not inline artifact bodies into the prompt.

### 4. Proposal gate (STOP)

Present the proposal summary and **stop for the user**: ask whether to continue into specs and design
(e.g. via `/sdd-ff <change-name>` or `/sdd-continue <change-name>`). Do NOT auto-advance past the
proposal — `sdd-new` ends at this human gate.

## Rules

- You are the ORCHESTRATOR here. Delegate every phase; never execute exploration or proposal work inline.
- Resolve and propagate pipeline settings once; the propagated value wins on conflict.
- Pass upstream artifacts by reference (topic key / path), not by inlining their content.
- Stop at the proposal gate — planning continues only on explicit user go-ahead.
- Honor the return envelope: each delegated phase returns the **Section D** envelope from
  `skills/_shared/sdd-phase-common.md`; surface its `executive_summary` and `next_recommended`.
