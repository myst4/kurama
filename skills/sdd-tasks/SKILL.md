---
name: sdd-tasks
description: >
  Break down a change into an implementation task checklist.
  Trigger: When the orchestrator launches you to create or update the task breakdown for a change.
license: MIT
metadata:
  author: kurama
  version: "2.0"
---

## Purpose

You are a sub-agent responsible for creating the TASK BREAKDOWN. You take the proposal, specs, and design, then produce a `tasks.md` with concrete, actionable implementation steps organized by phase.

## What You Receive

From the orchestrator:
- Change name
- Pipeline settings propagated per phase, including `tdd.enabled` (and
  `tdd.single_test_command` when enabled). A propagated value WINS over any value read
  from `openspec/config.yaml` (same precedence as `compliance_mode`).

## Execution and Persistence Contract

> Follow **Section B** (retrieval) and **Section C** (persistence) from `skills/_shared/sdd-phase-common.md`.

> If a required artifact cannot be found, follow the missing-artifact handling in **Section B** — return a `blocked` envelope naming the missing artifact rather than proceeding without it.

**Resolve the change size FIRST.** Read the proposal's `## Change Size` section:

- **`standard`** (also the default when the section is absent or unrecognized): spec and
  design are separate artifacts and both are REQUIRED, exactly as below.
- **`small`**: the spec and design were collapsed into the proposal by `sdd-propose`. Read
  them from its `## Spec (inline)` and `## Design (inline)` sections and treat those as the
  spec and design artifacts. Do NOT return `blocked` for a missing standalone spec or design
  — for a `small` change they were never meant to exist separately. Do return `blocked` if
  the proposal itself lacks those sections, naming `sdd-propose` as the producing phase.

Read `openspec/changes/{change-name}/proposal.md` (required), `openspec/changes/{change-name}/specs/` (required for `standard`; inline in the proposal for `small`) and `openspec/changes/{change-name}/design.md` (same), then write `openspec/changes/{change-name}/tasks.md`. Read and follow `skills/_shared/openspec-convention.md`.

## What to Do

### Step 1: Load Skills
Follow **Section A** from `skills/_shared/sdd-phase-common.md`.

### Step 2: Analyze the Design

From the design document, identify:
- All files that need to be created/modified/deleted
- The dependency order (what must come first)
- Testing requirements per component

### Step 2a: Resolve TDD Mode

Resolve `tdd.enabled` with the SAME precedence as `compliance_mode`:

1. the value propagated in your launch prompt (its home is `openspec/config.yaml` `tdd.enabled`) —
   a propagated value WINS;
2. else read `tdd.enabled` from `openspec/config.yaml`;
3. else default OFF (standard checklist).

When `tdd.enabled` is **true**, expand behavior tasks per the "TDD Task Expansion" format
below. When **false**, produce the standard checklist. `sdd-apply` resolves the SAME flag, so
planning and implementation always agree on one mode — never a silent heuristic.

**Module-not-installed fallback (graceful degrade — never a hard failure):** the `tdd` module
installs by default but may be absent when excluded with `--without tdd`, even when the flag
is true. If `skills/tdd/SKILL.md` cannot be resolved/loaded, do NOT fail the phase. Emit a
WARNING — *"TDD enabled but the tdd module is missing (default installs include it; it was
excluded with `--without tdd`) — reinstall with `scripts/install.sh`; proceeding without
TDD"* — surface it in the return envelope's `risks`, then produce the
**standard checklist** (non-TDD path) instead of the RED/GREEN/REFACTOR expansion.

### Step 3: Write tasks.md

Create the task file:

```
openspec/changes/{change-name}/
├── proposal.md
├── specs/
├── design.md
└── tasks.md               ← You create this
```

#### Task File Format

```markdown
# Tasks: {Change Title}

## Phase 1: {Phase Name} (e.g., Infrastructure / Foundation)

- [ ] 1.1 {Concrete action — what file, what change}
- [ ] 1.2 {Concrete action}
- [ ] 1.3 {Concrete action}

## Phase 2: {Phase Name} (e.g., Core Implementation)

- [ ] 2.1 {Concrete action}
- [ ] 2.2 {Concrete action}
- [ ] 2.3 {Concrete action}
- [ ] 2.4 {Concrete action}

## Phase 3: {Phase Name} (e.g., Testing / Verification)

- [ ] 3.1 {Write tests for ...}
- [ ] 3.2 {Write tests for ...}
- [ ] 3.3 {Verify integration between ...}

## Phase 4: {Phase Name} (e.g., Cleanup / Documentation)

- [ ] 4.1 {Update docs/comments}
- [ ] 4.2 {Remove temporary code}
```

**Leave the evidence slot empty.** `sdd-apply` appends a **Work Unit Evidence** block (its
Step 3c: test command + exact result, harness/runtime, rollback boundary) under each unit as it
completes it — with `tdd.enabled` true or false. Do NOT pre-fill, stub, or
placeholder those lines here: evidence is produced by execution, and a pre-written block is
exactly the unbacked claim the gate exists to prevent. The size budget below covers the PLANNED
checklist only; the evidence `sdd-apply` adds later never counts against it.

#### TDD Task Expansion (only when `tdd.enabled` — Step 2a)

When TDD is on, each behavior — one MUST scenario from the spec — expands into a
RED → GREEN → REFACTOR triplet (`n.x RED` / `n.y GREEN` / `n.z REFACTOR`), and EVERY subtask
references the scenario's stable ID (`S-{requirement}-{n}`, assigned by `sdd-spec`). This is
planning only; `skills/tdd/SKILL.md` owns the cycle contract that `sdd-apply` executes. Only
behavior tasks tied to a MUST scenario expand — infrastructure, wiring, and docs tasks stay
as normal single tasks.

```markdown
## Phase 2: Core Implementation (TDD)

- [ ] 2.1 RED (S-auth-1): write a failing test asserting {THEN outcome} for scenario S-auth-1
- [ ] 2.2 GREEN (S-auth-1): minimal code in `internal/auth/service.go` to make S-auth-1 pass
- [ ] 2.3 REFACTOR (S-auth-1): clean up `internal/auth/service.go` while S-auth-1 stays green
- [ ] 2.4 RED (S-auth-2): write a failing test for edge-case scenario S-auth-2
- [ ] 2.5 GREEN (S-auth-2): minimal code to make S-auth-2 pass
- [ ] 2.6 REFACTOR (S-auth-2): clean up while S-auth-2 stays green
```

Every MUST scenario in the spec MUST appear in a RED subtask — that is the traceability
`sdd-verify` audits (scenario → test). A behavior with no RED subtask is a planning gap.

### Task Writing Rules

Each task MUST be:

| Criteria | Example ✅ | Anti-example ❌ |
|----------|-----------|----------------|
| **Specific** | "Create `internal/auth/middleware.go` with JWT validation" | "Add auth" |
| **Actionable** | "Add `ValidateToken()` method to `AuthService`" | "Handle tokens" |
| **Verifiable** | "Test: `POST /login` returns 401 without token" | "Make sure it works" |
| **Small** | One file or one logical unit of work | "Implement the feature" |

### Phase Organization Guidelines

```
Phase 1: Foundation / Infrastructure
  └─ New types, interfaces, database changes, config
  └─ Things other tasks depend on

Phase 2: Core Implementation
  └─ Main logic, business rules, core behavior
  └─ The meat of the change

Phase 3: Integration / Wiring
  └─ Connect components, routes, UI wiring
  └─ Make everything work together

Phase 4: Testing
  └─ Unit tests, integration tests, e2e tests
  └─ Verify against spec scenarios

Phase 5: Cleanup (if needed)
  └─ Documentation, remove dead code, polish
```

### Step 4: Persist Artifact

**This step is MANDATORY — do NOT skip it.**

Follow **Section C** from `skills/_shared/sdd-phase-common.md`.
- artifact: `tasks`
- path: `openspec/changes/{change-name}/tasks.md`

### Step 5: Return Summary

Return envelope per **Section D** from `skills/_shared/sdd-phase-common.md`. Populate `detailed_report` with these phase-specific fields:

- **Breakdown** — table of Phase | Tasks | Focus, plus a Total row
- **Implementation Order** — brief description of the recommended order and why

## Rules

- ALWAYS reference concrete file paths in tasks
- Tasks MUST be ordered by dependency — Phase 1 tasks shouldn't depend on Phase 2
- Testing tasks should reference specific scenarios from the specs
- Each task should be completable in ONE session (if a task feels too big, split it)
- Use hierarchical numbering: 1.1, 1.2, 2.1, 2.2, etc.
- NEVER include vague tasks like "implement feature" or "add tests"
- Apply any `rules.tasks` from `openspec/config.yaml`
- When `tdd.enabled` resolves true (Step 2a — propagated > `config.yaml` > default off), expand every behavior task into `n.x RED` / `n.y GREEN` / `n.z REFACTOR` subtasks, each referencing the spec scenario ID (`S-{requirement}-{n}`) per the TDD Task Expansion format; when false, produce the standard checklist. Do NOT infer TDD from existing test files.
- NEVER pre-fill a Work Unit Evidence block — `sdd-apply` writes it from real execution (Step 3c). Plan the tasks; leave the evidence slot to the phase that runs the commands
- **Size budget**: Tasks artifact MUST be under 530 words. Each task: 1-2 lines max. Use checklist format, not paragraphs.
