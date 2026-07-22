# Engram Artifact Convention (reference documentation)

NOTE: Critical engram calls (`mem_search`, `mem_save`, `mem_get_observation`) are inlined directly in each skill's SKILL.md. This document is supplementary reference — sub-agents do NOT need to read it to function.

## Naming Rules

ALL SDD artifacts persisted to Engram MUST follow this deterministic naming:

```
title:     sdd/{change-name}/{artifact-type}
topic_key: sdd/{change-name}/{artifact-type}
type:      architecture
project:   {detected or current project name}
scope:     project
```

### Artifact Types

| Artifact Type | Produced By | Description |
|---------------|-------------|-------------|
| `explore` | sdd-explore | Exploration analysis |
| `proposal` | sdd-propose | Change proposal |
| `spec` | sdd-spec | Delta specifications (all domains concatenated) |
| `design` | sdd-design | Technical design |
| `tasks` | sdd-tasks | Task breakdown |
| `apply-progress` | sdd-apply | Implementation progress (one per batch) |
| `verify-report` | sdd-verify | Verification report |
| `archive-report` | sdd-archive | Archive closure with lineage |
| `state` | orchestrator | DAG state for recovery after compaction |

Exception: `sdd-init` uses `sdd-init/{project-name}` as both title and topic_key. In engram mode, this `sdd-init/{project}` artifact is also the home for pipeline settings (artifact store mode, `compliance_mode`, verify commands, and the future TDD flag) — there is no `config.yaml` in engram mode — and the orchestrator propagates those settings in every phase prompt.

## Main Spec Artifacts (source of truth)

The per-change `spec` artifact above holds a change's DELTA specs (all domains concatenated). The cumulative source-of-truth specifications live in SEPARATE, cross-change artifacts — one per spec domain — so they persist after a change is archived and act as the baseline for the next change:

```
title:     sdd-specs/{project}/{domain}
topic_key: sdd-specs/{project}/{domain}
type:      architecture
project:   {project}
scope:     project
```

- **One artifact per spec domain** (e.g. `sdd-specs/my-app/auth`, `sdd-specs/my-app/payments`) — NOT concatenated. This mirrors the filesystem layout `openspec/specs/{domain}/spec.md`.
- **Upsert semantics**: the stable `topic_key` means `mem_save` updates the domain's spec in place instead of duplicating. `sdd-archive` merges each change's delta into these artifacts; `sdd-spec` reads them as the baseline.
- **Frontmatter with `last_updated`**: each main-spec artifact begins with YAML frontmatter carrying `last_updated` (ISO date). In hybrid mode the filesystem copy is authoritative and Engram mirrors it; comparing `last_updated` lets a reader detect divergence (the file wins).

```markdown
---
domain: {domain}
last_updated: {ISO date}
---

# {Domain} Specification

## Purpose

{High-level description of this domain.}

## Requirements

### Requirement: {Name}

The system {MUST/SHALL/SHOULD} {behavior}.

#### Scenario: {Name}

- GIVEN {precondition}
- WHEN {action}
- THEN {outcome}
```

Baseline read (per affected domain):
```
mem_search(query: "sdd-specs/{project}/{domain}", project: "{project}") → get ID (if any)
mem_get_observation(id) → full main spec
```
On the FIRST cycle a domain's main spec legitimately may not exist yet — an absent artifact is an EMPTY BASELINE, not an error.

### State Artifact

```
mem_save(
  title: "sdd/{change-name}/state",
  topic_key: "sdd/{change-name}/state",
  type: "architecture",
  project: "{project}",
  capture_prompt: false,
  content: "change: {change-name}\nphase: {last-phase}\nartifact_store.mode: engram\nartifacts:\n  proposal: true\n  specs: true\n  design: false\n  tasks: false\ntasks_progress:\n  completed: []\n  pending: []\nlast_updated: {ISO date}"
)
```

Recovery: `mem_search("sdd/{change-name}/state")` → `mem_get_observation(id)` → parse YAML → restore state.

## Recovery Protocol (2 steps)

```
Step 1: mem_search(query: "sdd/{change-name}/{artifact-type}", project: "{project}") → truncated preview + ID
Step 2: mem_get_observation(id: {observation-id}) → complete content
```

When retrieving multiple artifacts, group all searches first, then all retrievals:

```
STEP A — SEARCH (get IDs only):
  mem_search(query: "sdd/{change-name}/proposal", ...) → save ID
  mem_search(query: "sdd/{change-name}/spec", ...) → save ID
  mem_search(query: "sdd/{change-name}/design", ...) → save ID

STEP B — RETRIEVE FULL CONTENT (mandatory):
  mem_get_observation(id: {proposal_id})
  mem_get_observation(id: {spec_id})
  mem_get_observation(id: {design_id})
```

Loading project context:
```
mem_search(query: "sdd-init/{project}", project: "{project}") → get ID
mem_get_observation(id) → full project context
```

## Writing Artifacts

Standard write:
```
mem_save(
  title: "sdd/{change-name}/{artifact-type}",
  topic_key: "sdd/{change-name}/{artifact-type}",
  type: "architecture",
  project: "{project}",
  capture_prompt: false,
  content: "{full markdown content}"
)
```

Concrete example — saving a proposal for `add-dark-mode`:
```
mem_save(
  title: "sdd/add-dark-mode/proposal",
  topic_key: "sdd/add-dark-mode/proposal",
  type: "architecture",
  project: "my-app",
  capture_prompt: false,
  content: "## Proposal\n\nAdd dark mode toggle..."
)
```

### Prompt Capture (`capture_prompt: false`)

Every SDD artifact save above carries `capture_prompt: false`. SDD artifacts (explore,
proposal, spec, design, tasks, apply-progress, verify-report, archive-report, state) and the
`sdd-init/{project}` context / `skill-registry` bundles are **automated pipeline outputs**, not
records of a human decision — a phase sub-agent generates them from upstream artifacts, so there
is no user prompt worth attaching. Setting `capture_prompt: false` keeps Engram's prompt-capture
channel reserved for genuine human/proactive saves and stops SDD phases from polluting it with the
orchestrator's internal launch text. Do NOT set it by `type`: these saves use `type: architecture`,
but a genuine human architecture decision would still capture its prompt. The flag is chosen by
provenance (automated artifact → `false`), never by type. A sub-agent that saves a real discovery
during general work leaves `capture_prompt` at its default (`true`).

Update existing artifact (when you have the observation ID):
```
mem_update(id: {observation-id}, content: "{updated full content}")
```

Use `mem_update` when you have the exact ID. Use `mem_save` with same `topic_key` for upserts.

### Browsing All Artifacts for a Change

```
mem_search(query: "sdd/{change-name}/", project: "{project}")
→ Returns all artifacts for that change
```

## Apply-Progress Continuity (read-merge-write)

The `apply-progress` artifact shares its `topic_key` (`sdd/{change-name}/apply-progress`) across
every batch of `sdd-apply`, and `topic_key` upsert is **destructive** — a plain `mem_save` REPLACES
the prior observation, it does not append. A blind write from batch 2 would therefore erase batch 1's
recorded task completions.

`sdd-apply` MUST treat this artifact as **read-merge-write**, never blind overwrite:

1. **Read first** — `mem_search("sdd/{change-name}/apply-progress")` → `mem_get_observation(id)`.
   An absent artifact means this is the first batch (empty baseline), not an error.
2. **Merge** — union the prior batch's completed/pending task states with this batch's results;
   a task marked complete in an earlier batch stays complete.
3. **Write back** — `mem_save` the merged whole under the same `topic_key` (with
   `capture_prompt: false`).

The same rule applies to the `tasks` artifact's `[x]` marks (updated via `mem_update`): read the
current marks, merge this batch's completions, and write the merged set — never regress a mark that
an earlier batch already set. See `skills/sdd-apply/SKILL.md` Step 5 for the phase-level procedure.

## Why This Convention

- Deterministic titles → recovery works by exact match
- `topic_key` → enables upserts without duplicates
- `sdd/` prefix → namespaces all SDD artifacts
- Cross-change `sdd-specs/{project}/{domain}` artifacts → the source of truth survives archival in engram mode, so `sdd-archive` can merge deltas and `sdd-spec` has a real baseline (no phantom "existing specs")
- Two-step recovery → search previews are always truncated; `mem_get_observation` is the only way to get full content
- Lineage → archive-report includes all observation IDs for complete traceability
