---
name: sdd-propose
description: >
  Create a change proposal with intent, scope, and approach.
  Trigger: When the orchestrator launches you to create or update a proposal for a change.
license: MIT
metadata:
  author: gentleman-programming
  version: "2.0"
---

## Purpose

You are a sub-agent responsible for creating PROPOSALS. You take the exploration analysis (or direct user input) and produce a structured `proposal.md` document inside the change folder.

## What You Receive

From the orchestrator:
- Change name (e.g., "add-dark-mode")
- Exploration analysis (from sdd-explore) OR direct user description
- Artifact store mode (`engram | openspec | hybrid`)

## Execution and Persistence Contract

> Follow **Section B** (retrieval) and **Section C** (persistence) from `skills/_shared/sdd-phase-common.md`.

> If a required artifact cannot be found, follow the missing-artifact handling in **Section B** — return a `blocked` envelope naming the missing artifact rather than proceeding without it.

- **engram**: Read `sdd/{change-name}/explore` (optional) and `sdd-init/{project}` (optional). Save artifact as `sdd/{change-name}/proposal`.
- **openspec**: Read and follow `skills/_shared/openspec-convention.md`.
- **hybrid**: Follow BOTH conventions — persist to Engram AND write to filesystem. Retrieve dependencies from Engram (primary) with filesystem fallback.
- Never force `openspec/` creation unless user requested file-based persistence or mode is `hybrid`.

## What to Do

### Step 1: Load Skills
Follow **Section A** from `skills/_shared/sdd-phase-common.md`.

### Step 2: Create Change Directory

**IF mode is `openspec` or `hybrid`:** create the change folder structure:

```
openspec/changes/{change-name}/
└── proposal.md
```

**IF mode is `engram`:** Do NOT create any `openspec/` directories. Skip this step.

### Step 3: Read Existing Specs

**IF mode is `openspec` or `hybrid`:** If `openspec/specs/` has relevant specs, read them to understand current behavior that this change might affect.

**IF mode is `engram`:** Existing context was already retrieved from Engram in the Persistence Contract. Skip filesystem reads.

### Step 3b: Classify the Change Size

Classify the change as `small` or `standard`. This is an explicit judgement you record with
its rationale — **never a silent heuristic**, and never inferred from line counts alone.

A change is `small` ONLY when **every** criterion below holds:

1. it touches a single domain;
2. it introduces no new or changed public contract (API surface, config schema, phase contract);
3. it requires no data or configuration migration;
4. it adds no new dependency;
5. it does not modify a phase contract or the canonical DAG.

If any criterion fails, or if you cannot resolve one from the available context, the size is
`standard`. **Ambiguity always resolves to `standard`** — the long path is the safe default,
and a change that turns out smaller than expected costs two extra documents, while one that
turns out larger than expected reaches `apply` under-specified.

Anything that edits a phase's SKILL.md contract or the DAG is `standard` by criterion 5,
regardless of how few lines it touches.

**What the classification changes**: for `small`, you write the spec and the design as
sections INSIDE `proposal.md` (Step 4), and the orchestrator skips the separate `sdd-spec`
and `sdd-design` delegations. The information is collapsed, never omitted — `sdd-tasks` and
`sdd-archive` still receive everything they require, and the inline delta spec is what
`sdd-archive` merges into the main specs.

### Step 4: Write proposal.md

If the skill registry exposes a brainstorming-type skill, you MAY run it for the product-question round — optional, never required.

Every proposal ends with a `## Change Size` section. A `small` proposal additionally carries
`## Spec (inline)` and `## Design (inline)` — see the template after this one.

```markdown
# Proposal: {Change Title}

## Intent

{What problem are we solving? Why does this change need to happen?
Be specific about the user need or technical debt being addressed.}

## Scope

### In Scope
- {Concrete deliverable 1}
- {Concrete deliverable 2}
- {Concrete deliverable 3}

### Out of Scope
- {What we're explicitly NOT doing}
- {Future work that's related but deferred}

## Approach

{High-level technical approach. How will we solve this?
Reference the recommended approach from exploration if available.}

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `path/to/area` | New/Modified/Removed | {What changes} |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| {Risk description} | Low/Med/High | {How we mitigate} |

## Rollback Plan

{How to revert if something goes wrong. Be specific.}

## Dependencies

- {External dependency or prerequisite, if any}

## Success Criteria

- [ ] {How do we know this change succeeded?}
- [ ] {Measurable outcome}

## Change Size

**`small`** | **`standard`** — {state how each of the five criteria resolved; when
`standard`, name the criterion that disqualified it or the ambiguity you could not resolve}
```

#### Additional sections for a `small` change

When Step 3b classified the change as `small`, append these two sections. They replace the
separate `sdd-spec` and `sdd-design` phases, so they carry the SAME content those phases
would have produced — the same rigor in one document, not a lighter version of it.

The inline spec MUST use the standalone delta-spec format verbatim (`# Delta for {Domain}`,
`## ADDED/MODIFIED/REMOVED/RENAMED Requirements`, RFC 2119 keywords, `#### Scenario: [S-{req}-N]`
with GIVEN/WHEN/THEN). `sdd-archive` merges this section into the main specs unchanged, so a
malformed or empty spec here corrupts the source of truth — it MUST block instead.

The section semantics are defined once, canonically, in `_shared/openspec-convention.md` →
*Delta Spec Sections*. Read it before writing a `MODIFIED` block: the merge replaces the ENTIRE
matching requirement, so a block that omits unchanged scenarios deletes them from the main spec.
The `small` path takes the same rule as the standalone `sdd-spec` phase — a collapsed cycle is
not a lighter contract.

```markdown
## Spec (inline)

# Delta for {Domain}

## ADDED Requirements

### Requirement: {Requirement Name}

The system {MUST/SHALL/SHOULD} {do something specific}.

#### Scenario: [S-{req}-1] {Happy path}

- GIVEN {precondition}
- WHEN {action}
- THEN {expected outcome}

## Design (inline)

### Architecture Decisions

**{Decision}.** {What was chosen and the rationale — including what was rejected and why.}

### File Changes

| File | Change | Description |
|------|--------|-------------|
| `path/to/file.ext` | Create/Modify/Delete | {What changes and why} |

### Testing Strategy

{How each scenario above is verified.}
```

### Step 5: Persist Artifact

**This step is MANDATORY — do NOT skip it.**

Follow **Section C** from `skills/_shared/sdd-phase-common.md`.
- artifact: `proposal`
- topic_key: `sdd/{change-name}/proposal`
- type: `architecture`

### Step 6: Return Summary

Return envelope per **Section D** from `skills/_shared/sdd-phase-common.md`. Populate `detailed_report` with these phase-specific fields:

- **Intent** — one-line summary
- **Scope** — N deliverables in, M items deferred
- **Approach** — one-line approach
- **Risk Level** — Low/Medium/High

Both `sdd-spec` and `sdd-design` are valid next phases per the DAG in `skills/_shared/sdd-phase-common.md` — reflect that in `next_recommended`.

## Rules

- In `openspec` mode, ALWAYS create the `proposal.md` file
- If the change directory already exists with a proposal, READ it first and UPDATE it
- Keep the proposal CONCISE - it's a thinking tool, not a novel
- Every proposal MUST have a rollback plan
- Every proposal MUST have success criteria
- Use concrete file paths in "Affected Areas" when possible
- Apply any `rules.proposal` from `openspec/config.yaml`
- **Size budget**: Proposal artifact MUST be under 400 words. Use bullet points and tables over prose. Headers organize, not explain.
