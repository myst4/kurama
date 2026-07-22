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
- Artifact store mode (`engram | openspec | hybrid | none`)
- Pipeline settings propagated per phase, including `tdd.enabled` (and
  `tdd.single_test_command` when enabled). A propagated value WINS over any value read
  from `openspec/config.yaml` (same precedence as `compliance_mode`).

## Execution and Persistence Contract

> Follow **Section B** (retrieval) and **Section C** (persistence) from `skills/_shared/sdd-phase-common.md`.

> **The mode governs SDD artifacts only — never your implementation code.** In EVERY mode, including `engram` and `none`, you MUST write the actual source code, tests, and required configuration for the assigned tasks. The rules below apply to SDD artifacts (progress records and task-completion marks), not to the code you produce — writing that code is the entire purpose of this phase.

> If a required artifact cannot be found, follow the missing-artifact handling in **Section B** — return a `blocked` envelope naming the missing artifact rather than proceeding without it.

- **engram**: Read `sdd/{change-name}/proposal`, `sdd/{change-name}/spec`, `sdd/{change-name}/design`, `sdd/{change-name}/tasks` (all required — keep tasks ID for updates), AND read the existing `sdd/{change-name}/apply-progress` FIRST when present (optional — an absent artifact means this is the first batch). Mark tasks complete via `mem_update(id: {tasks-observation-id}, content: "...")`. Save progress as `sdd/{change-name}/apply-progress` using **read-merge-write**, never a blind overwrite (see Step 5).
- **openspec**: Read and follow `skills/_shared/openspec-convention.md`. Update `tasks.md` with `[x]` marks.
- **hybrid**: Follow BOTH conventions — persist progress to Engram (`mem_update` for tasks) AND update `tasks.md` with `[x]` marks on filesystem.
- **none**: Return progress inline only — do not write SDD artifact files (proposal/spec/design/tasks/apply-progress). The implementation code itself is still written to the project as normal; `none` governs SDD artifacts, never the code you produce.

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
   for `openspec`/`hybrid`, or the `sdd-init/{project}` context artifact for `engram`/`none`) —
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
is opt-in and may be absent even when the flag is true. If `skills/tdd/SKILL.md` cannot be
resolved/loaded, do NOT fail the phase. Emit a WARNING —
*"TDD enabled but the tdd module is not installed — run `scripts/install.sh --with tdd`;
proceeding without TDD"* — surface it in the return envelope's `risks`, then fall back to
**Step 3b (Standard Workflow)** for this batch. Do not fabricate RED/GREEN/REFACTOR evidence
you cannot produce without the module.

Detect the test runner via `skills/_shared/test-runners.md` (the single runner table). Use
`tdd.single_test_command` (or the runner's single-test invocation from that table) to run
ONLY the relevant test for a fast RED cycle — never the whole suite. If any per-language
coding skills are installed (e.g. `go-testing`, `pytest`, `vitest`), follow their patterns
for writing the tests.

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

### Step 4: Mark Tasks Complete

Update `tasks.md` — change `- [ ]` to `- [x]` for completed tasks:

```markdown
## Phase 1: Foundation

- [x] 1.1 Create `internal/auth/middleware.go` with JWT validation
- [x] 1.2 Add `AuthConfig` struct to `internal/config/config.go`
- [ ] 1.3 Add auth routes to `internal/server/server.go`  ← still pending
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
   A task an earlier batch marked complete STAYS complete.
3. **Write back** — persist the merged whole under the same `topic_key`.

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
- NEVER blind-overwrite `apply-progress` — read the existing artifact FIRST, merge this batch's task states into it, and write the merged whole (read-merge-write); a `topic_key` upsert replaces, it does not append, so a blind save erases earlier batches' completions
- Skill loading is handled in Step 1 — follow any loaded skills strictly when writing code
- Apply any `rules.apply` from `openspec/config.yaml`
- Resolve `tdd.enabled` first (Step 3): propagated value wins, else `tdd.enabled` in `openspec/config.yaml`, else default off. NEVER infer TDD from existing test files or from a `tdd/SKILL.md` being installed
- When `tdd.enabled` is true, follow `skills/tdd/SKILL.md` for the RED → GREEN → REFACTOR cycle — never skip RED (writing the failing test first)
- Detect the test runner via `skills/_shared/test-runners.md`; run ONLY the relevant test (via `tdd.single_test_command` or the runner's single-test invocation), not the entire suite, for speed
