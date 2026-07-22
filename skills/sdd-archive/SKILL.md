---
name: sdd-archive
description: >
  Sync delta specs to main specs and archive a completed change.
  Trigger: When the orchestrator launches you to archive a change after implementation and verification.
license: MIT
metadata:
  author: gentleman-programming
  version: "2.0"
---

## Purpose

You are a sub-agent responsible for ARCHIVING. You merge delta specs into the main specs (source of truth), then move the change folder to the archive. You complete the SDD cycle.

## What You Receive

From the orchestrator:
- Change name
- Artifact store mode (`engram | openspec | hybrid | none`)

## Execution and Persistence Contract

> Follow **Section B** (retrieval) and **Section C** (persistence) from `skills/_shared/sdd-phase-common.md`.

- **engram**: Read `sdd/{change-name}/explore` (optional), `sdd/{change-name}/proposal`, `sdd/{change-name}/spec`, `sdd/{change-name}/design`, `sdd/{change-name}/tasks`, `sdd/{change-name}/verify-report` (all required). Merge the delta `spec` into the cross-change main specs `sdd-specs/{project}/{domain}` (Step 2). Record all observation IDs in the archive report for traceability. Save as `sdd/{change-name}/archive-report`.
- **openspec**: Read and follow `skills/_shared/openspec-convention.md`. Perform merge and archive folder moves.
- **hybrid**: Follow BOTH conventions — persist archive report to Engram (with observation IDs), upsert the merged main specs to `sdd-specs/{project}/{domain}` AND perform filesystem merge + archive folder moves.
- **none**: Return closure summary only. Do not perform archive file operations.

### Missing required inputs (failure semantics)

Per E2: a REQUIRED upstream artifact that cannot be retrieved is a hard stop — never archive silently around it. Return the envelope with `status: blocked`, name the missing artifact in `executive_summary`, and set `next_recommended` to the phase that produces it:
- missing `verify-report` → see **Step 0** (blocked unless an explicit user-authorized override is passed).
- missing delta `spec` → blocked; `next_recommended: sdd-spec` (there is nothing to merge into the source of truth).
- missing `proposal`, `design`, or `tasks` → blocked; name it and set `next_recommended` to its producing phase (the archive is an audit trail and must be complete).

The exploration artifact (`explore` in engram, `exploration.md` in openspec) is OPTIONAL — if absent, note it in `risks` and continue; do NOT block.

## What to Do

### Step 0: Read and Gate on the Verification Report

BEFORE any merge or move, retrieve the verification report and gate on it. Archiving an unverified or failing change would consolidate broken behavior into the source of truth.

**Retrieve the verify report:**
- **engram**: `mem_search("sdd/{change-name}/verify-report")` → `mem_get_observation(id)`.
- **openspec**: read `openspec/changes/{change-name}/verify-report.md`.
- **hybrid**: read file-first (`openspec/changes/{change-name}/verify-report.md`), fall back to Engram if absent.
- **none**: the orchestrator passes the verify verdict inline in your prompt.

**Gate:**
- If the verify report is MISSING (not found in any store / not provided) → return `status: blocked`, name the missing `verify-report`, set `next_recommended: sdd-verify`. Do NOT archive.
- If the verdict is `FAIL`, or the report lists any unresolved CRITICAL issue → return `status: blocked`, summarize the failing items, set `next_recommended: sdd-verify`. Do NOT archive.
- If the verdict is `PASS` or `PASS WITH WARNINGS` → run the **content binding revalidation** below, then proceed to Step 1.

(Compliance strictness is set by `rules.verify.compliance_mode`: under `behavioral` a MUST scenario without a passing test is CRITICAL; under `static` an UNTESTED scenario is only a WARNING. Read the verdict the report already computed — do NOT re-run verification here.)

**Content binding revalidation (mechanical — closes the "trust the verdict blindly" gap):**
The verify report stamps a **Content Binding** receipt (`Tree-Hash`, sdd-verify Step 6b) that
binds the PASS to the EXACT tree it verified. A PASS is only trustworthy if the code has not
changed since. Recompute the live hash with the IDENTICAL procedure (throwaway index — the real
index is never touched) and compare:

```bash
# From the repository root. GIT_INDEX_FILE is a temp file, so the working index is untouched.
tmp_index="$(mktemp)"; rm -f "$tmp_index"   # git rejects a zero-byte index — let it create a fresh one
GIT_INDEX_FILE="$tmp_index" git add -A -- . ':(exclude)openspec' ':(exclude).atl'
live_tree="$(GIT_INDEX_FILE="$tmp_index" git write-tree)"
rm -f "$tmp_index"
```

- Read the RECORDED hash from the report's `Tree-Hash` line (openspec/hybrid). In `engram`/`none`
  mode the report is not on disk — read it from the `sdd/{change-name}/state` artifact (the
  orchestrator stamped `Reviewed-Tree` there) or from the value the orchestrator passed inline.
- If `live_tree` ≠ the recorded hash → the code changed after verification → return
  `status: blocked`, `executive_summary: "verify receipt stale — re-run sdd-verify"`,
  `next_recommended: sdd-verify`. Do NOT archive. (The `openspec/` and `.atl/` exclusions mean
  writing this report or moving the change folder does NOT trip the check — only a real code
  change does.)
- If the recorded hash is `n/a (not a git checkout)` or absent (legacy report) → skip this
  check; the verdict gate above still applies.

**This pathspec MUST stay byte-identical to sdd-verify Step 6b and
`examples/claude-code/hooks/archive-gate.sh`** — any drift makes every archive read as stale.

**Explicit override (escape hatch):** the orchestrator MAY pass an explicit, user-authorized override to archive despite a missing report, a `FAIL` verdict, or a STALE content-binding receipt (e.g. `override_verify: <reason>`). ONLY when such an override is present, proceed with archiving and RECORD the override verbatim (reason + that it was user-authorized) in the archive report and in your return envelope under `risks`. Never self-authorize an override.

### Step 1: Load Skills
Follow **Section A** from `skills/_shared/sdd-phase-common.md`.

### Step 2: Sync Delta Specs to Main Specs

**IF mode is `none`:** Skip — no persisted specs to sync (report the merge summary inline).

**IF mode is `engram`:** Merge the change's delta into the cross-change MAIN SPEC artifacts `sdd-specs/{project}/{domain}` (one per domain) — the engram equivalent of the filesystem merge below. This is what makes specs a living source of truth in engram mode; do NOT skip it. The delta `spec` artifact (`sdd/{change-name}/spec`) concatenates all domains under domain headers (`# Delta for {Domain}`). Split it by domain and, FOR EACH domain:

1. Retrieve the current main spec: `mem_search("sdd-specs/{project}/{domain}")` → `mem_get_observation(id)`.
2. Apply the delta with the SAME semantics as the filesystem merge below:
   - ADDED → append to the main spec's Requirements section
   - MODIFIED → replace the matching requirement (match by `### Requirement: {name}`)
   - REMOVED → delete the matching requirement
   - PRESERVE every requirement the delta does NOT mention
   - If NO main spec exists yet for the domain, the delta IS the full spec — use it directly as the new main spec (first-cycle baseline).
3. Refresh the frontmatter `last_updated` to today (ISO), then upsert:
   `mem_save(title/topic_key: "sdd-specs/{project}/{domain}", type: "architecture", project: "{project}", capture_prompt: false, content: {merged spec})`. The stable `topic_key` upserts in place, and `capture_prompt: false` keeps this automated main-spec upsert from capturing the user prompt (see `skills/_shared/engram-convention.md`).

Then continue to Step 3 (the archive report records the observation IDs for traceability).

**IF mode is `openspec` or `hybrid`:** For each delta spec in `openspec/changes/{change-name}/specs/`:

#### If Main Spec Exists (`openspec/specs/{domain}/spec.md`)

Read the existing main spec and apply the delta:

```
FOR EACH SECTION in delta spec:
├── ADDED Requirements → Append to main spec's Requirements section
├── MODIFIED Requirements → Replace the matching requirement in main spec
└── REMOVED Requirements → Delete the matching requirement from main spec
```

**Merge carefully:**
- Match requirements by name (e.g., "### Requirement: Session Expiration")
- Preserve all OTHER requirements that aren't in the delta
- Maintain proper Markdown formatting and heading hierarchy

#### If Main Spec Does NOT Exist

The delta spec IS a full spec (not a delta). Copy it directly:

```bash
# Copy new spec to main specs
openspec/changes/{change-name}/specs/{domain}/spec.md
  → openspec/specs/{domain}/spec.md
```

#### Hybrid: mirror the merged spec to Engram

**IF mode is `hybrid`:** after each domain's filesystem merge, ALSO upsert the merged main spec to its Engram artifact `sdd-specs/{project}/{domain}` (refresh the frontmatter `last_updated`). The filesystem copy is authoritative; Engram mirrors it. If the two diverge, the FILE wins — reconcile from the file and note it in `risks`.

### Step 3: Move to Archive

**IF mode is `engram`:** Skip — there are no `openspec/` directories to move. The archive report in Engram serves as the audit trail.

**IF mode is `none`:** Skip — no filesystem operations.

**IF mode is `openspec` or `hybrid`:** Move the entire change folder to archive with date prefix:

```
openspec/changes/{change-name}/
  → openspec/changes/archive/YYYY-MM-DD-{change-name}/
```

Use today's date in ISO format (e.g., `2026-02-16`).

### Step 4: Verify Archive

**IF mode is `openspec` or `hybrid`:** Confirm:
- [ ] Main specs updated correctly (per domain)
- [ ] Change folder moved to archive
- [ ] Archive contains all artifacts (exploration, proposal, specs, design, tasks, verify-report)
- [ ] Active changes directory no longer has this change

**IF mode is `engram`:** Confirm each affected `sdd-specs/{project}/{domain}` main spec was upserted, and all artifact observation IDs — including `explore` (if present) and `verify-report` — are recorded in the archive report.

**IF mode is `none`:** Skip verification — no persisted artifacts.

### Step 5: Persist Archive Report

**This step is MANDATORY — do NOT skip it.**

Follow **Section C** from `skills/_shared/sdd-phase-common.md`.
- artifact: `archive-report`
- topic_key: `sdd/{change-name}/archive-report`
- type: `architecture`
- capture_prompt: `false` — the archive report is an automated SDD artifact; never capture the user prompt (see `skills/_shared/engram-convention.md`)

Per E2, if `mem_save` of the archive report or a merged main spec fails, retry once; if it still fails, write a filesystem fallback copy under `.atl/sdd/{change-name}/` and report it as a concern in `risks`. Do NOT silently drop the merge or the report.

### Step 6: Return Summary

Return to the orchestrator:

```markdown
## Change Archived

**Change**: {change-name}
**Archived to**: `openspec/changes/archive/{YYYY-MM-DD}-{change-name}/` (openspec/hybrid) | Engram archive report (engram) | inline (none)

### Specs Synced
| Domain | Action | Details |
|--------|--------|---------|
| {domain} | Created/Updated | {N added, M modified, K removed requirements} |

### Archive Contents
- exploration.md ✅ (or "not present")
- proposal.md ✅
- specs/ ✅
- design.md ✅
- tasks.md ✅ ({N}/{N} tasks complete)
- verify-report.md ✅

### Source of Truth Updated
The following specs now reflect the new behavior:
- `openspec/specs/{domain}/spec.md` (openspec/hybrid)
- Engram main spec `sdd-specs/{project}/{domain}` (engram/hybrid)

### SDD Cycle Complete
The change has been fully planned, implemented, verified, and archived.
Ready for the next change.
```

## Rules

- ALWAYS run Step 0 first: NEVER archive when the verify report is missing or its verdict is `FAIL` / has unresolved CRITICAL issues, UNLESS an explicit user-authorized override is passed — and when it is, record the override verbatim in the archive report
- ALWAYS revalidate the **content binding** in Step 0 when the report carries a `Tree-Hash`: recompute the live reviewed-tree hash (throwaway index, excluding `openspec/` and `.atl/` — byte-identical to sdd-verify Step 6b and archive-gate.sh) and BLOCK on a mismatch with `"verify receipt stale — re-run sdd-verify"`. Only the same explicit override bypasses it; a legacy report with no `Tree-Hash` falls back to the verdict gate alone
- ALWAYS sync delta specs BEFORE moving to archive
- In engram mode, main specs ARE the `sdd-specs/{project}/{domain}` artifacts — merge deltas there exactly as openspec merges into `openspec/specs/{domain}/spec.md`; never skip the merge
- When merging into existing specs, PRESERVE requirements not mentioned in the delta
- A missing REQUIRED upstream artifact → return `status: blocked` naming it (Section D); never archive an incomplete audit trail silently
- Use ISO date format (YYYY-MM-DD) for archive folder prefix
- If the merge would be destructive (removing large sections), WARN the orchestrator and ask for confirmation
- The archive is an AUDIT TRAIL — never delete or modify archived changes
- If `openspec/changes/archive/` doesn't exist, create it
- Apply any `rules.archive` from `openspec/config.yaml`
- Return envelope per **Section D** from `skills/_shared/sdd-phase-common.md`.
