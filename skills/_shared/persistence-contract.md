# Persistence Contract (shared across all SDD skills)

> **Scope — these modes govern SDD ARTIFACTS, not implementation code.** Everything in this contract about "writing" or "project files" refers to *SDD artifacts* (exploration, proposal, spec, design, tasks, apply-progress, verify-report, archive-report, state). It does NOT restrict the implementation code that `sdd-apply` writes. Writing source files, tests, and required configuration is **ALWAYS allowed and REQUIRED in every mode** — including `engram` and `none` — because producing that code is the entire point of the apply phase.

## Engram Availability Check (once, at cycle start)

Before the first phase of a cycle, the orchestrator MUST determine whether Engram is reachable by attempting **one cheap Engram call** — e.g. `mem_search(query: "sdd", project: "{project}")`.

- Call returns (even with zero results) → Engram is **available**.
- Call errors, times out, or the `mem_*` tools are absent → Engram is **unavailable**.

Run this check once and propagate the result to every phase prompt. Do not re-probe on each phase.

## Mode Resolution

The orchestrator passes `artifact_store.mode` with one of: `engram | openspec | hybrid | none`.

Default resolution (when orchestrator does not explicitly set a mode):
1. If Engram is available → use `engram`
2. If Engram is unavailable → use `engram` degraded to the **`.atl/sdd/` filesystem fallback** (see *Harness State & Filesystem Fallback* below), and warn the user. **Never silently degrade to `none`** — that would drop cross-session recovery entirely.

`openspec` and `hybrid` are NEVER used by default — only when explicitly passed.

`none` is only used when the orchestrator explicitly passes it. When `none` is explicitly selected, recommend the user enable `engram` or `openspec` for persistence.

### Engram unavailable while `engram`/`hybrid` is selected

If `engram` (default or explicit) is selected but Engram is unavailable at cycle start, degrade to the `.atl/sdd/` filesystem fallback with a user warning — read and write SDD artifacts as markdown under `.atl/sdd/{change-name}/` instead of Engram. This preserves compaction recovery without creating `openspec/` in the repo. For `hybrid`, an unavailable Engram is non-fatal because the filesystem is authoritative (see *Hybrid Mode*): continue file-only and note the missing mirror as a risk.

## Behavior Per Mode

| Mode | Read from | Write to | SDD artifact files |
|------|-----------|----------|--------------------|
| `engram` | Engram | Engram | Never in the repo (code still written) |
| `openspec` | Filesystem | Filesystem | Yes |
| `hybrid` | Filesystem (authoritative), Engram mirror as fallback | Both | Yes |
| `none` | Orchestrator prompt context | Nowhere | Never (code still written) |

The `Read from` / `Write to` / `SDD artifact files` columns describe where **SDD artifacts** go — never the implementation code, which `sdd-apply` always writes to the project.

When `engram` is degraded to the `.atl/sdd/` filesystem fallback (Engram unavailable), read and write SDD artifacts as markdown under `.atl/sdd/{change-name}/` — the harness state directory, not repo-tracked `openspec/`.

### Hybrid Mode

Persists every artifact to BOTH the filesystem and Engram simultaneously:
- Filesystem (OpenSpec): the **authoritative**, human-readable, version-controllable source of truth
- Engram: a **searchable mirror** for cross-session recovery, compaction survival, and deterministic search

**Authority**: the filesystem is authoritative; Engram is only a mirror.

Write to filesystem (per `openspec-convention.md`) AND to Engram (per `engram-convention.md`) for every artifact. Stamp each artifact's frontmatter with `last_updated` (ISO 8601) in BOTH stores so divergence is detectable.

**Read behavior — file-first**: read the filesystem artifact as the source of truth. Consult the Engram mirror only when the file is absent.

**Divergence handling**: if the file and the Engram mirror disagree (e.g. a prior Engram write failed while the file write succeeded, or `last_updated` differs), **the file wins**. Re-sync Engram from the file and record the reconciliation in the phase's return envelope (`risks`).

**Write behavior**: the filesystem write is required and makes the operation durable. Attempt the Engram mirror write too; if it fails, retry once, then follow *Write Failure Recovery* and report it as a risk — because the file is authoritative, a missing mirror never halts the cycle.

Token cost warning: hybrid consumes MORE tokens per operation. Use only when you need both a version-controllable source of truth AND cross-session Engram recovery.

## Harness State & Filesystem Fallback

`.atl/` is the **harness state directory** — gitignored infrastructure, not repo-tracked SDD artifacts. Consistent with the `skill-registry` skill (which writes `.atl/skill-registry.md` in every mode), the persistence-mode gates that suppress `openspec/` never apply to `.atl/`. It holds:

- `.atl/skill-registry.md` — the compact skill registry (written in every mode)
- `.atl/sdd/{change-name}/{artifact-type}.md` — the SDD artifact **fallback store**

The `.atl/sdd/` store is used when Engram is the intended backend but is unavailable or fails:

- Engram unavailable at cycle start (degraded `engram` mode) → read/write all SDD artifacts here.
- A single `mem_save` fails mid-cycle → write that artifact here (see *Write Failure Recovery*).

Filenames mirror the Engram naming: the title/topic_key `sdd/{change-name}/{artifact-type}` maps to `.atl/sdd/{change-name}/{artifact-type}.md`, so recovery and downstream retrieval use the same identifiers regardless of backend.

## Write Failure Recovery

When a persistence write fails, recover instead of aborting:

**`engram` mode** — if `mem_save` fails:
1. **Retry once.**
2. If it still fails, **write the full artifact** to `.atl/sdd/{change-name}/{artifact-type}.md` and continue the phase.
3. **Report the fallback** in the return envelope `risks`, naming the artifact and the `.atl/sdd/` path so the orchestrator and downstream phases can locate it.

**`hybrid` mode** — the filesystem file is authoritative and is written first, so the artifact is already durable. If the Engram mirror write fails, retry once, then leave the mirror missing and record the reconciliation gap in `risks`; the next reader falls back to the file (file-first reads). No `.atl/sdd/` copy is needed because the `openspec/` file already holds the content.

**`openspec` mode** — a filesystem write failure is a genuine blocker (there is no second store). Return `status: blocked` naming the failing path.

**`none` mode** — nothing is persisted; there is no write to fail.

A persistence failure never silently drops an artifact and never halts the cycle in `engram`/`hybrid` — the artifact stays recoverable from `.atl/sdd/` or the authoritative file. The old "the pipeline BREAKS" framing is retired: missing persistence is a reported, recoverable risk, not a fatal dead end.

## State Persistence (Orchestrator)

The orchestrator persists DAG state after each phase transition to enable SDD recovery after compaction.

| Mode | Persist State | Recover State |
|------|--------------|---------------|
| `engram` | `mem_save(topic_key: "sdd/{change-name}/state")` | `mem_search("sdd/{change-name}/state")` → `mem_get_observation(id)` |
| `engram` (degraded) | Write `.atl/sdd/{change-name}/state.md` | Read `.atl/sdd/{change-name}/state.md` |
| `openspec` | Write `openspec/changes/{change-name}/state.yaml` | Read `openspec/changes/{change-name}/state.yaml` |
| `hybrid` | Both: write `state.yaml` AND `mem_save` | Filesystem first (authoritative); Engram mirror as fallback |
| `none` | Not possible — warn user | Not possible |

The `engram (degraded)` row applies whenever Engram is unavailable at cycle start (see *Engram Availability Check*): state survives compaction via `.atl/sdd/` instead of being lost to `none`.

## Common Rules

> **Every rule below governs SDD ARTIFACTS only** (exploration, proposal, spec, design, tasks, apply-progress, verify-report, archive-report, state) — never the implementation code `sdd-apply` writes. In these rules, "project files" means *SDD artifact files*. Implementation code (source, tests, required configuration) is **ALWAYS written to the project in every mode**, including `engram` and `none`; the mode only decides where the SDD artifacts live.

- `none` → do NOT create or modify any SDD artifact files; return SDD artifact content inline only (implementation code is still written to the project as normal)
- `engram` → do NOT write SDD artifact files into the repo; persist SDD artifacts to Engram and return observation IDs. If Engram is unavailable or a save fails, fall back to `.atl/sdd/` (see *Harness State & Filesystem Fallback* and *Write Failure Recovery*). Implementation code is still written to the project as normal
- `openspec` → write SDD artifact files ONLY to paths defined in `openspec-convention.md`
- `hybrid` → persist SDD artifacts to BOTH filesystem (authoritative) AND Engram (mirror); follow both conventions
- NEVER force `openspec/` creation unless orchestrator explicitly passed `openspec` or `hybrid`
- If no mode is resolvable, follow *Mode Resolution*: `engram` when Engram is available, else the `.atl/sdd/` fallback — never silently drop to `none`, and never write `openspec/` unless `openspec`/`hybrid` was explicitly passed

## Sub-Agent Context Rules

Sub-agents launch with a fresh context and NO access to the orchestrator's instructions or memory protocol.

Who reads, who writes:
- Non-SDD (general task): orchestrator searches engram, passes summary in prompt; sub-agent saves discoveries via `mem_save`
- SDD (phase with dependencies): sub-agent reads artifacts directly from backend; sub-agent saves its artifact
- SDD (phase without dependencies, e.g. explore): nobody reads; sub-agent saves its artifact

Why this split:
- Orchestrator reads for non-SDD: it knows what context is relevant; sub-agents doing their own searches waste tokens on irrelevant results
- Sub-agents read for SDD: SDD artifacts are large; inlining them in the orchestrator prompt would consume the entire context window
- Sub-agents always write: they have the complete detail on what happened; nuance is lost by the time results flow back to the orchestrator

## Orchestrator Prompt Instructions for Sub-Agents

The orchestrator injects the ONE persistence/retrieval block that matches the resolved `artifact_store.mode` (plus the degraded-Engram case). **Never inject `mem_save` instructions for `openspec` or `none`** — those modes do not call Engram; instructing a sub-agent to `mem_save` there contradicts the mode and may invoke tools that are absent. There is no single "MANDATORY for all modes" block — the wording is parametrized per mode below.

### Non-SDD (general task) — inject only when Engram is available

```
PERSISTENCE (MANDATORY):
If you make important discoveries, decisions, or fix bugs, you MUST save them to engram before returning:
  mem_save(title: "{short description}", type: "{decision|bugfix|discovery|pattern}",
           project: "{project}", content: "{What, Why, Where, Learned}")
Do NOT return without saving what you learned. This is how the team builds persistent knowledge across sessions.
```

If Engram is unavailable, omit this block (the sub-agent returns discoveries inline in its envelope instead).

### SDD retrieval preamble (phases with upstream dependencies)

Inject the variant matching the mode. In every variant: if a REQUIRED upstream artifact cannot be retrieved, the sub-agent returns `status: blocked` naming it (see `sdd-phase-common.md` Section B); an OPTIONAL one that is missing is noted in `risks`.

**`engram`:**
```
Artifact store mode: engram
Read these artifacts before starting (search returns truncated previews):
  mem_search(query: "sdd/{change-name}/{type}", project: "{project}") → get ID
  mem_get_observation(id: {id}) → full content (REQUIRED)
```

**`hybrid`:** same as `engram` but READ FILE-FIRST — read the `openspec/` artifact file as the source of truth; call `mem_get_observation` only if the file is absent. If file and mirror diverge, the file wins.

**`openspec`:**
```
Artifact store mode: openspec
Read these artifacts before starting from the paths defined in openspec-convention.md.
```

**`none`:**
```
Artifact store mode: none
Your upstream artifacts are provided inline in this prompt. Do NOT search Engram or read project files for them.
```

**degraded `engram` (Engram unavailable):** read upstream artifacts from `.atl/sdd/{change-name}/{type}.md`.

### SDD persistence (phases that produce an artifact)

Inject the variant matching the mode:

**`engram`:**
```
PERSISTENCE (engram): after completing your work, call:
  mem_save(
    title: "sdd/{change-name}/{artifact-type}",
    topic_key: "sdd/{change-name}/{artifact-type}",
    type: "architecture",
    project: "{project}",
    content: "{your full artifact markdown}"
  )
If mem_save fails, retry once; if it still fails, write the artifact to .atl/sdd/{change-name}/{artifact-type}.md
and report the fallback path in your envelope risks. Do not return without persisting the artifact somewhere the
next phase can read it.
```

**`hybrid`:**
```
PERSISTENCE (hybrid): write the artifact file per openspec-convention.md (AUTHORITATIVE) AND call mem_save
(mirror), stamping last_updated (ISO 8601) in the frontmatter of both. If the mem_save mirror write fails,
retry once, then leave it and note the reconciliation gap in risks — the file remains the source of truth.
```

**`openspec`:**
```
PERSISTENCE (openspec): write the artifact file ONLY to the path defined in openspec-convention.md.
Do NOT call mem_save — Engram is not used in this mode.
```

**`none`:**
```
PERSISTENCE (none): return the artifact content inline in your envelope only. Do NOT write any SDD artifact
files and do NOT call mem_save. (Implementation code is still written to the project as normal.)
```

**degraded `engram` (Engram unavailable):**
```
PERSISTENCE (engram fallback): Engram is unavailable this cycle. Write the artifact to
.atl/sdd/{change-name}/{artifact-type}.md and report the path in your envelope artifacts.
```

## Skill Registry

The orchestrator pre-resolves compact rules from the skill registry and injects them as `## Project Standards (auto-resolved)` in your launch prompt. Sub-agents do NOT read the registry or individual SKILL.md files — rules arrive pre-digested.

To generate/update: run the `skill-registry` skill, or run `sdd-init`.

Sub-agent skill loading: follow the canonical protocol in `skills/_shared/skill-resolver.md` (Project Standards block first, `SKILL: Load` as fallback, and its no-registry behavior). That file is the single source of truth for skill loading — do not duplicate its rules here.

## Detail Level

The orchestrator may pass `detail_level`: `concise | standard | deep`. This controls output verbosity but does NOT affect what gets persisted — always persist the full artifact.
