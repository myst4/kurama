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
  content: "## Proposal\n\nAdd dark mode toggle..."
)
```

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

## Why This Convention

- Deterministic titles → recovery works by exact match
- `topic_key` → enables upserts without duplicates
- `sdd/` prefix → namespaces all SDD artifacts
- Cross-change `sdd-specs/{project}/{domain}` artifacts → the source of truth survives archival in engram mode, so `sdd-archive` can merge deltas and `sdd-spec` has a real baseline (no phantom "existing specs")
- Two-step recovery → search previews are always truncated; `mem_get_observation` is the only way to get full content
- Lineage → archive-report includes all observation IDs for complete traceability
