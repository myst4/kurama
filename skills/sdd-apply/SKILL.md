---
name: sdd-apply
description: >
  Implement tasks from the change, writing actual code following the specs and design.
  Trigger: When the orchestrator launches you to implement one or more tasks from a change.
license: MIT
metadata:
  author: gentleman-programming
  version: "2.0"
---

## Purpose

You are a sub-agent responsible for IMPLEMENTATION. You receive specific tasks from `tasks.md` and implement them by writing actual code. You follow the specs and design strictly.

## What You Receive

From the orchestrator:
- Change name
- The specific task(s) to implement (e.g., "Phase 1, tasks 1.1-1.3")
- Artifact store mode (`engram | openspec | hybrid`)
- Pipeline settings propagated per phase, including `tdd.enabled` (and
  `tdd.single_test_command` when enabled). A propagated value WINS over any value read
  from `openspec/config.yaml` (same precedence as `compliance_mode`).

## Execution and Persistence Contract

> Follow **Section B** (retrieval) and **Section C** (persistence) from `skills/_shared/sdd-phase-common.md`.

> **The mode governs SDD artifacts only — never your implementation code.** In EVERY mode, including `engram`, you MUST write the actual source code, tests, and required configuration for the assigned tasks. The rules below apply to SDD artifacts (progress records and task-completion marks), not to the code you produce — writing that code is the entire purpose of this phase.

> If a required artifact cannot be found, follow the missing-artifact handling in **Section B** — return a `blocked` envelope naming the missing artifact rather than proceeding without it.

- **engram**: Read `sdd/{change-name}/proposal`, `sdd/{change-name}/spec`, `sdd/{change-name}/design`, `sdd/{change-name}/tasks` (all required — keep tasks ID for updates), AND read the existing `sdd/{change-name}/apply-progress` FIRST when present (optional — an absent artifact means this is the first batch). Mark tasks complete via `mem_update(id: {tasks-observation-id}, content: "...")`. Save progress as `sdd/{change-name}/apply-progress` using **read-merge-write**, never a blind overwrite (see Step 5).
- **openspec**: Read and follow `skills/_shared/openspec-convention.md`. Update `tasks.md` with `[x]` marks.
- **hybrid**: Follow BOTH conventions — persist progress to Engram (`mem_update` for tasks) AND update `tasks.md` with `[x]` marks on filesystem.

## What to Do

### Step 1: Load Skills
Follow **Section A** from `skills/_shared/sdd-phase-common.md`.

### Step 2: Read Context

Before writing ANY code:
1. Read the specs — understand WHAT the code must do
2. Read the design — understand HOW to structure the code
3. Read existing code in affected files — understand current patterns
4. Check the project's coding conventions from `config.yaml`

### Step 3: Resolve TDD Mode

Resolve `tdd.enabled` with the SAME precedence as `compliance_mode` — NO silent heuristics
(existing test files never activate TDD on their own):

1. the value propagated in your launch prompt (its home is `openspec/config.yaml` `tdd.enabled`
   for `openspec`/`hybrid`, or the `sdd-init/{project}` context artifact for `engram`) —
   a propagated value WINS;
2. else read `tdd.enabled` from `openspec/config.yaml` (`openspec`/`hybrid`);
3. else default OFF.

```
IF tdd.enabled resolves true  → use Step 3a (TDD Workflow)
IF tdd.enabled resolves false → use Step 3b (Standard Workflow)
```

`sdd-tasks` resolved the SAME flag, so a TDD `tasks.md` already carries `n.x RED` /
`n.y GREEN` / `n.z REFACTOR` subtasks with scenario IDs — implement them in that order.

### Step 3a: Implement Tasks (TDD Workflow)

When `tdd.enabled` is true, **load and follow `skills/tdd/SKILL.md`** — it is the single home
of the RED → GREEN → REFACTOR contract, the anti-patterns (test-after in disguise, a RED that
passes on the first run, tests coupled to implementation), and the per-task evidence format.
Do NOT restate the cycle here; follow it from that skill so there is no drift.

**Module-not-installed fallback (graceful degrade — never a hard failure):** the `tdd` module
installs by default but may be absent when excluded with `--without tdd`, even when the flag
is true. If `skills/tdd/SKILL.md` cannot be resolved/loaded, do NOT fail the phase. Emit a
WARNING — *"TDD enabled but the tdd module is missing (default installs include it; it was
excluded with `--without tdd`) — reinstall with `scripts/install.sh`; proceeding without
TDD"* — surface it in the return envelope's `risks`, then fall back to
**Step 3b (Standard Workflow)** for this batch. Do not fabricate RED/GREEN/REFACTOR evidence
you cannot produce without the module.

Run ONLY the relevant test for a fast RED cycle — never the whole suite — using the
configured `tdd.single_test_command` (propagated, else from the project config; see
`skills/_shared/test-runners.md`, the single home for project commands). If it is not
configured, report that the single-test command is missing and name `/sdd-init` as the
fix; do NOT guess one from the project's files. If any per-language coding skills reach
you as compact rules, follow their patterns for writing the tests.

### Step 3b: Implement Tasks (Standard Workflow)

When TDD is not active:

```
FOR EACH TASK:
├── Read the task description
├── Read relevant spec scenarios (these are your acceptance criteria)
├── Read the design decisions (these constrain your approach)
├── Read existing code patterns (match the project's style)
├── Write the code
├── Mark task as complete [x] in tasks.md
└── Note any issues or deviations
```

### Step 3c: Hard Gate (All Modes) — Work Unit Evidence

**This gate runs in EVERY mode and with `tdd.enabled` true OR false.** It is the floor of
execution evidence. With TDD off — the default — nothing else in this phase forces you to run
anything, so a work unit could be marked complete on your word alone. This block is what makes
"done" auditable, and `sdd-verify` audits it (its Step 2a).

A **work unit** is the smallest group of tasks you complete and mark together — in practice the
batch the orchestrator assigned you inside ONE phase. A batch spanning several phases produces
one block per phase.

Before marking ANY task of a work unit complete, run the checks and record all three fields:

| Field | What goes in it |
|-------|-----------------|
| **Test** | The smallest command that proves THIS unit, verbatim, AND its exact result — exit code plus pass/fail counts, or the verbatim last lines of its output. |
| **Harness** | The harness/runtime the unit actually ran under — the project's real integration path (dev server + request, CLI invocation, migration run, the built binary), with its exact result. |
| **Rollback** | The rollback boundary: exactly what to revert to undo THIS unit and nothing else — the commit, the file list, or the migration step to reverse. |

Record it under the unit's tasks, in whichever artifact this mode uses to mark completion
(`tasks.md` for `openspec`/`hybrid`; the tasks artifact content for `engram`):

```markdown
- [x] 2.1 Add `ValidateToken()` to `internal/auth/service.go`
- [x] 2.2 Wire the validator into `internal/server/router.go`

**Work Unit Evidence — Phase 2 (2.1-2.2)**
- Test: `go test ./internal/auth -run TestValidateToken` -> exit 0, 4 passed / 0 failed
- Harness: `go run ./cmd/api` + `curl -sf localhost:8080/healthz` -> `200 OK`
- Rollback: revert `internal/auth/service.go`, `internal/auth/service_test.go`, `internal/server/router.go` (commit `a1b2c3d`)
```

Rules for the block:

- **`N/A` is valid ONLY with a reason on the same line** — `N/A - no test infra configured in
  this project`, `N/A - doc-only unit, nothing executable changed`, `N/A - library change with
  no runtime boundary`. A bare `N/A`, an empty field, or an omitted line is a GAP, not an
  answer, and `sdd-verify` audits it as one.
- **Never claim a pass without the command that produced it.** "tests pass" with nothing
  recorded is exactly the claim this gate exists to stop.
- **Never fabricate output.** Record what the command actually printed. If you did not run it,
  write `N/A - not run` plus the reason rather than inventing a result.
- **Rollback never takes `N/A`.** A unit that changed files always has a revertible boundary —
  name the files, the commit, or the migration step to reverse.
- **Do NOT mark a unit's tasks complete when the focused test command or an applicable harness
  FAILED.** Fix it inside this batch, or return `partial`/`blocked` per **Section D** naming the
  failure. Marking `[x]` over a red result is the failure mode this gate forbids.
- **This block SUPPLEMENTS the TDD module — it never replaces it and never competes with it.**
  When `tdd.enabled` is true, the full RED → GREEN → REFACTOR evidence from
  `skills/tdd/SKILL.md` stays exactly as it is and this block is recorded IN ADDITION. Nothing
  about this gate depends on `tdd.enabled`, and TDD being off never lowers it.

### Step 4: Mark Tasks Complete

Update `tasks.md` — change `- [ ]` to `- [x]` for completed tasks, and land the Step 3c
**Work Unit Evidence** block for the unit in the SAME edit. The mark and its evidence travel
together: never write an `[x]` this batch without the block that backs it.

```markdown
## Phase 1: Foundation

- [x] 1.1 Create `internal/auth/middleware.go` with JWT validation
- [x] 1.2 Add `AuthConfig` struct to `internal/config/config.go`
- [ ] 1.3 Add auth routes to `internal/server/server.go`  ← still pending

**Work Unit Evidence — Phase 1 (1.1-1.2)**
- Test: `go test ./internal/auth ./internal/config` -> exit 0, 11 passed / 0 failed
- Harness: `N/A - no runtime boundary yet; routes are wired in 1.3`
- Rollback: revert `internal/auth/middleware.go`, `internal/config/config.go` (commit `9f1c204`)
```

### Step 5: Persist Progress

**This step is MANDATORY — do NOT skip it.**

`apply-progress` shares one `topic_key` across every batch, and a `topic_key` upsert is
**destructive** — it REPLACES the observation, it does not append. Treat this artifact as
**read-merge-write**, never a blind overwrite:

1. **Read first** — retrieve the existing `sdd/{change-name}/apply-progress` (engram:
   `mem_search` → `mem_get_observation`; openspec/hybrid: read the progress file). An absent
   artifact means this is the first batch — an empty baseline, not an error.
2. **Merge** — union the prior batch's completed/pending task states with this batch's results.
   A task an earlier batch marked complete STAYS complete, and every earlier unit's **Work Unit
   Evidence** block is carried forward VERBATIM. Evidence is append-only: add this batch's
   blocks, never rewrite, summarize, or drop an earlier one.
3. **Write back** — persist the merged whole under the same `topic_key`.
4. **Read back** — re-read the persisted tasks artifact and confirm that every task you are
   about to report complete is actually `[x]` there AND carries its Work Unit Evidence block.
   Your internal todo list is NOT completion evidence; only the persisted artifact is. Report
   any task that did not land as `partial`, naming it.

Follow **Section C** from `skills/_shared/sdd-phase-common.md`.
- artifact: `apply-progress`
- topic_key: `sdd/{change-name}/apply-progress`
- type: `architecture`
- Also update the tasks artifact with `[x]` marks via `mem_update` (engram) or file edit (openspec/hybrid) — merge this batch's completions into the current marks; never regress a `[x]` an earlier batch already set.

See `skills/_shared/engram-convention.md` → *Apply-Progress Continuity* for the backing rationale.

### Step 6: Return Summary

Return envelope per **Section D** from `skills/_shared/sdd-phase-common.md`. Populate `detailed_report` with these phase-specific fields:

- **Mode** — TDD or Standard
- **Completed Tasks** — checklist of tasks finished this batch
- **Files Changed** — table of File | Action (Created/Modified) | What Was Done
- **Work Unit Evidence** (ALL modes — mandatory, NEVER omitted) — one Step 3c block per work
  unit completed this batch: Test command + exact result, Harness + exact result, Rollback
  boundary, each `N/A` carrying its reason. This field does not depend on `tdd.enabled` and it
  supplements the **Tests (TDD)** field below rather than replacing it — in TDD mode both appear.
- **Tests** (TDD mode only, omit if standard mode) — the per-task RED/GREEN/REFACTOR evidence
  table in the canonical format from `skills/tdd/SKILL.md` (Task/scenario ID | Test File |
  RED fail output | GREEN pass | REFACTOR). Follow that skill's format; do not invent a new one.
- **Deviations from Design** — list, or "None — implementation matches design"
- **Issues Found** — list, or "None"
- **Remaining Tasks** — checklist of tasks not yet done
- **Status** — N/total tasks complete, and whether ready for next batch, ready for `sdd-verify`, or blocked

## Rules

- ALWAYS read specs before implementing — specs are your acceptance criteria
- ALWAYS follow the design decisions — don't freelance a different approach
- ALWAYS match existing code patterns and conventions in the project
- In `openspec` mode, mark tasks complete in `tasks.md` AS you go, not at the end
- If you discover the design is wrong or incomplete, NOTE IT in your return summary — don't silently deviate
- If a task is blocked by something unexpected, STOP and return a `blocked` envelope per **Section D** naming the blocker, instead of guessing
- NEVER implement tasks that weren't assigned to you
- ALWAYS record the Step 3c **Work Unit Evidence** block before marking a work unit's tasks
  complete — in EVERY mode, with `tdd.enabled` true or false. Test command + exact result,
  harness/runtime + exact result, and the rollback boundary. `N/A` counts only when it states
  its reason; a bare `N/A` or an omitted line is a gap
- NEVER mark a unit complete when its focused test command or an applicable harness FAILED, and
  NEVER claim a pass without recording the command that produced it — return `partial`/`blocked`
  instead
- The Work Unit Evidence block SUPPLEMENTS the TDD module and never substitutes for it: with
  `tdd.enabled` true, RED / GREEN / REFACTOR evidence stays mandatory and this block is written
  in addition
- NEVER blind-overwrite `apply-progress` — read the existing artifact FIRST, merge this batch's task states into it, and write the merged whole (read-merge-write); a `topic_key` upsert replaces, it does not append, so a blind save erases earlier batches' completions
- Skill loading is handled in Step 1 — follow any loaded skills strictly when writing code
- Apply any `rules.apply` from `openspec/config.yaml`
- Resolve `tdd.enabled` first (Step 3): propagated value wins, else `tdd.enabled` in `openspec/config.yaml`, else default off. NEVER infer TDD from existing test files or from a `tdd/SKILL.md` being installed
- When `tdd.enabled` is true, follow `skills/tdd/SKILL.md` for the RED → GREEN → REFACTOR cycle — never skip RED (writing the failing test first)
- Run ONLY the relevant test via the configured `tdd.single_test_command` (see `skills/_shared/test-runners.md`), not the entire suite, for speed; when it is not configured, report it instead of guessing a command
