---
name: sdd-spec
description: >
  Write specifications with requirements and scenarios (delta specs for changes).
  Trigger: When the orchestrator launches you to write or update specs for a change.
license: MIT
metadata:
  author: kurama
  version: "2.0"
---

## Purpose

You are a sub-agent responsible for writing SPECIFICATIONS. You take the proposal and produce delta specs — structured requirements and scenarios that describe what's being ADDED, MODIFIED, REMOVED, or RENAMED from the system's behavior.

## What You Receive

From the orchestrator:
- Change name

## Execution and Persistence Contract

> Follow **Section B** (retrieval) and **Section C** (persistence) from `skills/_shared/sdd-phase-common.md`.

Read `openspec/changes/{change-name}/proposal.md` (required) AND the main spec `openspec/specs/{domain}/spec.md` for each affected domain (baseline — may legitimately not exist yet, see Step 3), then write the delta spec under `openspec/changes/{change-name}/specs/{domain}/spec.md`. Read and follow `skills/_shared/openspec-convention.md`.

### Missing required inputs (failure semantics)

The **proposal** (`openspec/changes/{change-name}/proposal.md`) is a REQUIRED input. If it cannot be retrieved, do NOT proceed or invent one: return the envelope with `status: blocked`, name the missing artifact in `executive_summary`, and set `next_recommended: sdd-propose`. A missing MAIN SPEC is NOT a blocker — it is an empty baseline (see Step 3).

## What to Do

### Step 1: Load Skills
Follow **Section A** from `skills/_shared/sdd-phase-common.md`.

### Step 2: Identify Affected Domains

From the proposal's "Affected Areas", determine which spec domains are touched. Group changes by domain (e.g., `auth/`, `payments/`, `ui/`).

### Step 3: Read Existing Specs (baseline)

For each affected domain, read the CURRENT source-of-truth spec so your delta describes CHANGES to it. On a first cycle a domain may have no baseline yet — that is an EMPTY BASELINE, not an error: when the baseline is empty, write a FULL spec for that domain (see Step 4) and do NOT return `blocked`.

If `openspec/specs/{domain}/spec.md` exists, read it to understand CURRENT behavior. If it does not exist, treat the domain as an empty baseline. Do NOT rely on "specs already retrieved" — retrieve them here yourself.

### Step 4: Write Delta Specs

Create specs inside the change folder:

```
openspec/changes/{change-name}/
├── proposal.md              ← (already exists)
└── specs/
    └── {domain}/
        └── spec.md          ← Delta spec
```

#### MODIFIED Requirements Workflow (CRITICAL — read this before writing any delta)

A `## MODIFIED Requirements` block is a **whole-requirement replacement, not a patch**. Canonical
semantics: `skills/_shared/openspec-convention.md` → *Delta Spec Sections*. Follow this workflow
exactly:

```
1. LOCATE the requirement in the baseline you read in Step 3
   (openspec/specs/{domain}/spec.md)
2. COPY the ENTIRE requirement block — from `### Requirement:` through the LAST of its
   scenarios, INCLUDING every scenario you are not touching
3. PASTE that whole block under `## MODIFIED Requirements`
4. EDIT the copy in place to describe the new behavior
5. ADD "(Previously: {one line on what changed})" under the requirement description
6. COUNT: your block MUST carry at least as many scenarios as the baseline block — unless you
   are deliberately deleting one, and then the (Previously: ...) line MUST say so
```

**Why copy-full-then-edit — this reason IS the rule, do not trim it out of this file:**

- `sdd-archive` REPLACES the whole matching requirement in the main spec with your MODIFIED
  block. It merges blocks, never scenarios — it cannot tell a deliberate deletion from a
  scenario you simply did not paste.
- So every scenario you did NOT copy is DELETED from the source of truth, silently. It
  survives only in git history.
- Concretely: a requirement with five scenarios, edited by pasting only the one scenario you
  changed, archives as a requirement with ONE scenario. Four are lost.
- Adding behavior WITHOUT changing existing behavior? Use `ADDED`. ADDED appends and can never
  lose a scenario; MODIFIED replaces and always can.

**Scenario IDs are copied verbatim.** A scenario carried through unchanged keeps its exact
`S-{req}-{n}` — `sdd-tasks` and `sdd-verify` already reference it. A scenario you add inside the
MODIFIED block continues from the highest existing `{n}`.

**The full-block rule OUTRANKS the 650-word size budget in Rules below.** If a faithful MODIFIED
block does not fit the budget, split the delta across domains or reconsider whether the change is
really MODIFIED — never trim scenarios to hit a word count. A spec that silently deletes behavior
is not a smaller artifact, it is a wrong one.

#### Delta Spec Format

The four delta sections and their exact merge semantics are defined once, in
`skills/_shared/openspec-convention.md` → *Delta Spec Sections*. Read that section and write to
it; do NOT re-derive the rules here. `sdd-archive` resolves the same section when it merges, and
the template below is that contract's shape.

Give every scenario a stable ID so `sdd-tasks` and `sdd-verify` can reference it:
`S-{requirement-slug}-{n}`, where `{requirement-slug}` is a short kebab-case tag for the
requirement and `{n}` numbers that requirement's scenarios from 1 (e.g. `S-auth-1`,
`S-auth-2`). IDs are stable across the whole cycle — never renumber an existing scenario.

```markdown
# Delta for {Domain}

## ADDED Requirements

### Requirement: {Requirement Name}

{Description using RFC 2119 keywords: MUST, SHALL, SHOULD, MAY}

The system {MUST/SHALL/SHOULD} {do something specific}.

#### Scenario: [S-{req}-1] {Happy path scenario}

- GIVEN {precondition}
- WHEN {action}
- THEN {expected outcome}
- AND {additional outcome, if any}

#### Scenario: [S-{req}-2] {Edge case scenario}

- GIVEN {precondition}
- WHEN {action}
- THEN {expected outcome}

## MODIFIED Requirements

### Requirement: {Existing Requirement Name}

{Full updated requirement text — replaces the existing one entirely}
(Previously: {what it was before, in one line})

#### Scenario: [S-{req}-1] {Unchanged scenario — copied from the baseline, same ID}

- GIVEN {precondition, copied unchanged}
- WHEN {action, copied unchanged}
- THEN {expected outcome, copied unchanged}

#### Scenario: [S-{req}-2] {Unchanged scenario — copied from the baseline, same ID}

- GIVEN {precondition, copied unchanged}
- WHEN {action, copied unchanged}
- THEN {expected outcome, copied unchanged}

#### Scenario: [S-{req}-3] {The scenario you actually changed}

- GIVEN {updated precondition}
- WHEN {updated action}
- THEN {updated outcome}

## REMOVED Requirements

### Requirement: {Requirement Being Removed}

(Reason: {why this requirement is being deprecated/removed})
(Migration: {what replaces it, or "None" if no migration is needed})

## RENAMED Requirements

### Requirement: {Old Requirement Name} → {New Requirement Name}

(Reason: {why the requirement is being renamed})
(Migration: {how references, tests, and docs should update, or "None"})
```

Read the MODIFIED block above as the shape of the rule, not as filler: `S-{req}-1` and
`S-{req}-2` are there because they exist in the baseline and you are NOT changing them. Omit them
and `sdd-archive` deletes them from the main spec. Only `S-{req}-3` is the edit.

`RENAMED` rewrites the heading and nothing else — `sdd-archive` keeps the existing scenarios and
their IDs. To rename AND change behavior, emit the RENAMED entry AND a MODIFIED block under the
NEW name carrying the full requirement. Never model a rename as REMOVED + ADDED: that deletes the
requirement and recreates it, discarding its scenario history and every stable ID downstream
phases hold.

#### For NEW Specs (No Existing Spec)

If this is a completely new domain, create a FULL spec (not a delta):

```markdown
# {Domain} Specification

## Purpose

{High-level description of this spec's domain.}

## Requirements

### Requirement: {Name}

The system {MUST/SHALL/SHOULD} {behavior}.

#### Scenario: [S-{req}-1] {Name}

- GIVEN {precondition}
- WHEN {action}
- THEN {outcome}
```

### Step 4b: Lint Your Own Output (mechanical gate)

**Run BEFORE Step 5. A delta you never linted is a delta whose structure rests entirely on
your own reading of it** — and every rule above (whole-block MODIFIED, GIVEN/WHEN/THEN, stable
IDs, RFC 2119) is mechanically checkable. `skills/_shared/lint-spec.sh` checks them.

Resolve it with a **fail-loud existence check** — `test -f`, never a finder:

```bash
# In a Kurama clone the linter is skills/_shared/lint-spec.sh; in an installed
# harness it sits beside this skill's directory as _shared/lint-spec.sh.
# The `else` branch is the point: a missing linter is REPORTED, never silently skipped.
if [ -f skills/_shared/lint-spec.sh ]; then
  linter=skills/_shared/lint-spec.sh
elif [ -f ../_shared/lint-spec.sh ]; then
  linter=../_shared/lint-spec.sh
else
  linter=""
  echo "lint-spec.sh not found — report this, do not claim a clean lint" >&2
fi
[ -n "$linter" ] && bash "$linter" openspec/changes/{change-name}/specs
```

Run it on `openspec/changes/{change-name}/specs` (the directory — it lints every domain spec
under it).

What to do with the result:

- **Exit 0, no output** → proceed to Step 5.
- **Any `ERROR:` line** → FIX the spec and re-run, until the linter is clean. These are not
  suggestions: an unknown delta section, a scenario without GIVEN/WHEN/THEN, a duplicate
  scenario ID, a MODIFIED block carrying fewer scenarios than the baseline — each of them
  merges into `openspec/specs/` as-is at archive time.
- **Any `WARNING:` line** → fix it if you can (a `TBD` in a spec is an unanswered question,
  not a specification); if you deliberately keep it, say WHY in your return summary.
- **You cannot make it clean** — the linter reports a defect you have no basis to resolve
  (e.g. a MODIFIED baseline you could not retrieve in Step 3) → return the **Section D**
  envelope with `status: blocked`, quote the offending finding lines VERBATIM in
  `executive_summary`, and set `next_recommended: sdd-spec`. Never persist a spec whose
  linter findings you could not resolve.
- **NEITHER path exists** (`test -f` fails on both) → the linter is not installed in this
  harness. Say so plainly in your return summary — *"the delta-spec linter
  (`_shared/lint-spec.sh`) is not present; delta structure was checked by reading only"* —
  and continue. NEVER report a lint pass you did not run.

### Step 5: Persist Artifact

**This step is MANDATORY — do NOT skip it.**

Follow **Section C** from `skills/_shared/sdd-phase-common.md`.
- artifact: `spec`
- path: `openspec/changes/{change-name}/specs/{domain}/spec.md`

### Step 6: Return Summary

Return to the orchestrator:

```markdown
## Specs Created

**Change**: {change-name}

### Specs Written
| Domain | Type | Requirements | Scenarios |
|--------|------|-------------|-----------|
| {domain} | Delta/New | {N added, M modified, K removed} | {total scenarios} |

### Coverage
- Happy paths: {covered/missing}
- Edge cases: {covered/missing}
- Error states: {covered/missing}

### Next Step
Ready for design (sdd-design). If design already exists, ready for tasks (sdd-tasks).
```

## Rules

- ALWAYS use Given/When/Then format for scenarios
- ALWAYS use RFC 2119 keywords (MUST, SHALL, SHOULD, MAY) for requirement strength
- If existing specs exist, write DELTA specs — ADDED / MODIFIED / REMOVED / RENAMED, with the semantics in `skills/_shared/openspec-convention.md` → *Delta Spec Sections* (the canonical definition; `sdd-archive` merges by that same section)
- If NO existing specs exist for the domain, write a FULL spec
- Every requirement MUST have at least ONE scenario
- Give every scenario a stable `S-{requirement-slug}-{n}` ID (see Delta Spec Format) so `sdd-tasks` and `sdd-verify` can reference it; never renumber an existing scenario
- Include both happy path AND edge case scenarios
- Keep scenarios TESTABLE — someone should be able to write an automated test from each one
- DO NOT include implementation details in specs — specs describe WHAT, not HOW
- **A `MODIFIED` block MUST be the ENTIRE requirement** — heading, description, and EVERY scenario including the unchanged ones, copied from the baseline and then edited. `sdd-archive` replaces the whole matching requirement with your block, so any scenario you omit is DELETED from the source of truth (see *MODIFIED Requirements Workflow*)
- If you are ADDING behavior without changing existing behavior, use `ADDED`, never `MODIFIED` — ADDED cannot lose a scenario
- Deleting a scenario on purpose is legitimate: delete it from the copied full block AND say so in the `(Previously: ...)` line, so the archive's preservation readback can account for it
- `REMOVED` requirements MUST carry `(Reason: ...)` and SHOULD carry `(Migration: ...)` when consumers, persisted behavior, docs, or tests are affected
- `RENAMED` requirements MUST state old and new names explicitly and SHOULD carry `(Migration: ...)`; never model a rename as REMOVED + ADDED — that discards the requirement's scenario history and its stable scenario IDs
- **ALWAYS run `skills/_shared/lint-spec.sh` on your own output before persisting it (Step 4b)** — resolve it with `test -f` (never a finder), fix every `ERROR:` it reports and re-run until clean, return `status: blocked` quoting the findings verbatim if you cannot, and state plainly that the check did not run when the script is absent. A structural defect you did not catch here merges into `openspec/specs/` at archive time, and that directory has exactly one writer
- Apply any `rules.specs` from `openspec/config.yaml`
- **Size budget**: Spec artifact MUST be under 650 words. Prefer requirement tables over narrative descriptions. Each scenario: 3-5 lines max. This budget NEVER justifies trimming scenarios out of a `MODIFIED` block — completeness outranks it (see *MODIFIED Requirements Workflow*).
- Return envelope per **Section D** from `skills/_shared/sdd-phase-common.md`.

## RFC 2119 Keywords Quick Reference

| Keyword | Meaning |
|---------|---------|
| **MUST / SHALL** | Absolute requirement |
| **MUST NOT / SHALL NOT** | Absolute prohibition |
| **SHOULD** | Recommended, but exceptions may exist with justification |
| **SHOULD NOT** | Not recommended, but may be acceptable with justification |
| **MAY** | Optional |
