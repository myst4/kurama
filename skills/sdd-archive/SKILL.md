---
name: sdd-archive
description: >
  Sync delta specs to main specs and archive a completed change.
  Trigger: When the orchestrator launches you to archive a change after implementation and verification.
license: MIT
metadata:
  author: kurama
  version: "2.0"
---

## Purpose

You are a sub-agent responsible for ARCHIVING. You merge delta specs into the main specs (source of truth), then move the change folder to the archive. You complete the SDD cycle.

## What You Receive

From the orchestrator:
- Change name

## Execution and Persistence Contract

> Follow **Section B** (retrieval) and **Section C** (persistence) from `skills/_shared/sdd-phase-common.md`.

Read `openspec/changes/{change-name}/exploration.md` (optional) plus `proposal.md`, `specs/`, `design.md`, `tasks.md` and `verify-report.md` under `openspec/changes/{change-name}/` (all required). Read and follow `skills/_shared/openspec-convention.md`. Perform merge and archive folder moves, then save the report to `.kurama/sdd/{change-name}/archive-report.md`.

### Missing required inputs (failure semantics)

Per E2: a REQUIRED upstream artifact that cannot be retrieved is a hard stop — never archive silently around it. Return the envelope with `status: blocked`, name the missing artifact in `executive_summary`, and set `next_recommended` to the phase that produces it:
- missing `verify-report` → see **Step 0** (blocked unless an explicit user-authorized override is passed).
- missing delta `spec` → blocked; `next_recommended: sdd-spec` (there is nothing to merge into the source of truth).
- missing `proposal`, `design`, or `tasks` → blocked; name it and set `next_recommended` to its producing phase (the archive is an audit trail and must be complete).

**Small changes carry the delta spec inline.** Read the proposal's `## Change Size` section
first (absent or unrecognized ⇒ `standard`). When the size is `small`, the delta spec and the
design live in the proposal's `## Spec (inline)` and `## Design (inline)` sections rather than
as separate artifacts — locate them there and merge the inline delta exactly as you would a
standalone one. Do NOT block on a missing standalone `spec`/`design` for a `small` change.

Do block when the inline spec is missing, empty, or carries no `### Requirement:` entries:
`status: blocked`, `next_recommended: sdd-propose`. Merging a partial delta would write an
incomplete requirement set into the main specs, which is worse than not archiving — the main
specs are the source of truth and a silent partial merge is unrecoverable without git history.

The exploration artifact (`openspec/changes/{change-name}/exploration.md`) is OPTIONAL — if absent, note it in `risks` and continue; do NOT block.

## Mechanical Copy Contract (MANDATORY)

Archiving is a MECHANICAL filesystem operation. Whenever an artifact is reproduced **without
transformation** — a full-file spec copy, the change-folder move — its bytes MUST NEVER pass
through the model's Read/Write path. A model that summarizes, truncates, reorders, or tidies a
single byte while reporting success corrupts an audit trail that nothing downstream re-checks:
`openspec/specs/` has exactly ONE writer, this skill, and the archive folder is never read again
until someone needs it.

1. **Native commands only.** Copy and move with `cp`, `cp -R`, `mv`, or `git mv` in the shell.
   NEVER Read a file and Write its content to the destination.
2. **A `diff -r` readback is MANDATORY after every copy and every move**, comparing the source
   (or a pre-move snapshot of it) against the destination.
3. **Empty `diff -r` output is the ONLY passing evidence.** Put the readback's VERBATIM output in
   the phase result — including when it is empty, stated as such next to the exact command that
   produced it. Any difference is truncation or alteration and FAILS the phase. A skipped,
   missing, or unreported `diff -r` ALSO FAILS the phase. **Agent self-report is never
   sufficient**: "I moved the folder and it looks correct" is not evidence — it is the same
   sentence a silent truncation produces.
4. **A destination collision REFUSES.** If the destination already exists (file, directory, or
   symlink), STOP with source and destination both unchanged. Do NOT append a suffix, pick
   another name, overwrite, merge, or delete anything. Return `status: blocked` naming both paths
   and let a human resolve it.
5. **No shell, no archive.** If the platform's tool allowlist does not grant shell access,
   return `status: blocked` with the reason
   `shell access required for mechanical archive copy is unavailable` and
   `next_recommended: sdd-archive`. Do NOT fall back to Read/Write copying. A blocked archive is
   recoverable; a silently corrupted source of truth is not.

**Scope.** This contract governs reproduction WITHOUT transformation. The delta merge in Step 2
(applying ADDED / MODIFIED / REMOVED / RENAMED into an EXISTING main spec) is a transformation and
cannot be a `cp`; it carries its own mechanical guard — the *Merge preservation readback* in
Step 2 — which is equally mandatory.

## What to Do

### Step 0: Read and Gate on the Verification Report

BEFORE any merge or move, retrieve the verification report and gate on it. Archiving an unverified or failing change would consolidate broken behavior into the source of truth.

**Retrieve the verify report:** read `openspec/changes/{change-name}/verify-report.md`.

`sdd-verify` Step 7 also writes the full report to `.kurama/sdd/{change-name}/verify-report.md`.
Read that mirror when the artifact itself is absent — and note that this is the exact file
`archive-gate.sh` gates on, so if it is missing the hook will refuse the archive no matter what
the artifact says. A missing marker with the artifact present is a `risks` entry naming the path,
not a reason to self-authorize an override.

**Gate:**
- If the verify report is MISSING (not found at either path / not provided) → return `status: blocked`, name the missing `verify-report`, set `next_recommended: sdd-verify`. Do NOT archive.
- If the verdict is `FAIL`, or the report lists any unresolved CRITICAL issue → return `status: blocked`, summarize the failing items, set `next_recommended: sdd-verify`. Do NOT archive.
- If the verdict is `PASS` or `PASS WITH WARNINGS` → run the **content binding revalidation** below, then proceed to Step 1.

(Compliance strictness is set by `rules.verify.compliance_mode`: under `behavioral` a MUST scenario without a passing test is CRITICAL; under `static` an UNTESTED scenario is only a WARNING. Read the verdict the report already computed — do NOT re-run verification here.)

**Content binding revalidation (mechanical — closes the "trust the verdict blindly" gap):**
The verify report stamps a **Content Binding** receipt (`Tree-Hash`, sdd-verify Step 6b) that
binds the PASS to the EXACT tree it verified. A PASS is only trustworthy if the code has not
changed since. Recompute the live hash with the IDENTICAL procedure (throwaway index — the real
index is never touched) and compare:

```bash
# From the repository root. GIT_INDEX_FILE points INSIDE a private temp directory, so the
# working index is untouched. Never `mktemp` a file and then `rm` it to hand git a free path:
# that unlinks a name anyone can recreate before git does (CWE-377), and this comparison is
# exactly the one an attacker would want to win. mktemp -d creates the directory 0700 and the
# index is born inside it.
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
GIT_INDEX_FILE="$tmp_dir/index" git add -A -- . ':(exclude)openspec' ':(exclude).kurama'
live_tree="$(GIT_INDEX_FILE="$tmp_dir/index" git write-tree)"
rm -rf -- "$tmp_dir"
```

- Read the RECORDED hash from the report's `Tree-Hash` line — `openspec/changes/{change-name}/verify-report.md`,
  or the `.kurama/sdd/{change-name}/verify-report.md` mirror.
  If the report carries no such line, fall back to `openspec/changes/{change-name}/state.yaml` (the
  orchestrator stamped `Reviewed-Tree` there) or to the value the orchestrator passed inline.
- If `live_tree` ≠ the recorded hash → the code changed after verification → return
  `status: blocked`, `executive_summary: "verify receipt stale — re-run sdd-verify"`,
  `next_recommended: sdd-verify`. Do NOT archive. (The `openspec/` and `.kurama/` exclusions mean
  writing this report or moving the change folder does NOT trip the check — only a real code
  change does.)
- If the recorded hash is `n/a (not a git checkout)` or absent (legacy report) → skip this
  check; the verdict gate above still applies.

**This pathspec MUST stay byte-identical to sdd-verify Step 6b and
`examples/claude-code/hooks/archive-gate.sh`** — any drift makes every archive read as stale.

**Explicit override (escape hatch):** the orchestrator MAY pass an explicit, user-authorized override to archive despite a missing report, a `FAIL` verdict, or a STALE content-binding receipt (e.g. `override_verify: <reason>`). ONLY when such an override is present, proceed with archiving and RECORD the override verbatim (reason + that it was user-authorized) in the archive report and in your return envelope under `risks`. Never self-authorize an override.

### Step 1: Load Skills
Follow **Section A** from `skills/_shared/sdd-phase-common.md`.

### Step 1a: Refuse a Structurally Invalid Delta (mechanical gate)

BEFORE any merge. You are the ONLY writer of `openspec/specs/` — a structural defect that gets
past you is in the source of truth, and nothing downstream re-checks it.
`skills/_shared/lint-spec.sh` is the mechanical half of that check: canonical section names, an
RFC 2119 keyword per requirement, GIVEN/WHEN/THEN per scenario, well-formed and unique
`[S-{req}-{n}]` IDs, RENAMED entries naming both names, no leftover template placeholders, and
a MODIFIED block that carries FEWER scenarios than the baseline in `openspec/specs/**` — the
partial-MODIFIED data-loss case, caught before the merge instead of after it.

Resolve it with a **fail-loud existence check** — `test -f`, never a finder:

```bash
# Kurama clone: skills/_shared/lint-spec.sh. Installed harness: _shared/lint-spec.sh
# beside this skill's directory. A missing linter is REPORTED, never silently skipped.
if [ -f skills/_shared/lint-spec.sh ]; then
  linter=skills/_shared/lint-spec.sh
elif [ -f ../_shared/lint-spec.sh ]; then
  linter=../_shared/lint-spec.sh
else
  linter=""
fi
[ -n "$linter" ] && bash "$linter" openspec/changes/{change-name}/specs
```

**An `ERROR:` line REFUSES the merge.** Leave every main spec and the change folder exactly as
you found them, return `status: blocked` with `next_recommended: sdd-spec`, and quote the
offending `file:line: ERROR: message` lines VERBATIM in `executive_summary` / `risks`. Do NOT
merge the clean domains and skip the broken one, do NOT edit the delta yourself to make it
lint, and do NOT proceed on the reasoning that the merge would "probably" be fine. A blocked
archive is recoverable; a malformed requirement admitted into `openspec/specs/` stays.

- `WARNING:` lines do NOT block. Record them in `risks` and continue.
- **Small changes**: lint the proposal's `## Spec (inline)` delta the same way, by extracting
  that section to a temp file. Inline is where the delta lives on that path, not an exemption.
- **NEITHER path exists** → the linter is not installed in this harness. This is NOT a refusal:
  say so plainly in the archive report and in `risks` — *"the delta-spec linter
  (`_shared/lint-spec.sh`) is not present; delta structure was checked by reading only"* — and
  fall back to the Step 2 *Merge preservation readback*, which is mandatory regardless. NEVER
  report a lint pass you did not run.

### Step 2: Sync Delta Specs to Main Specs

For each delta spec in `openspec/changes/{change-name}/specs/`:

#### If Main Spec Exists (`openspec/specs/{domain}/spec.md`)

Read the existing main spec and apply the delta. **The four delta sections and their exact merge
semantics are defined once, in `skills/_shared/openspec-convention.md` → *Delta Spec Sections*.**
Resolve them there and apply them verbatim; do NOT re-derive them here. `sdd-spec` writes against
that same section — the writer and the merger drifting apart is precisely how a delta comes to
mean one thing when written and another when merged.

What you apply (the canonical section above is authoritative):

```
FOR EACH SECTION in delta spec — requirements matched by `### Requirement: {name}`, verbatim:
├── ADDED Requirements    → Append to main spec's Requirements section
├── MODIFIED Requirements → REPLACE the whole matching requirement block, scenarios included
├── REMOVED Requirements  → Delete the matching requirement block (delta must carry a Reason)
└── RENAMED Requirements  → Rewrite the heading in place, KEEPING the existing scenarios and
                            their S-{req}-{n} IDs — never delete-and-recreate
```

**Merge carefully:**
- Match requirements by name (e.g., "### Requirement: Session Expiration")
- Preserve all OTHER requirements that aren't in the delta
- Maintain proper Markdown formatting and heading hierarchy
- A MODIFIED block replaces the ENTIRE requirement. You CANNOT distinguish a deliberate scenario
  deletion from an author who pasted only the scenario they edited — so run the preservation
  readback below BEFORE the merged file becomes the source of truth

#### Merge preservation readback (MANDATORY whenever the main spec already exists)

The merge is the one archive operation the Mechanical Copy Contract cannot turn into a `cp`, so
it gets a mechanical guard instead. Snapshot the main spec BEFORE writing the merge, then compare
requirement headings and scenario IDs afterwards:

```bash
main_spec="openspec/specs/{domain}/spec.md"
before_snapshot="$(mktemp "${TMPDIR:-/tmp}/sdd-mainspec.XXXXXX")"
trap 'rm -f -- "$before_snapshot"' EXIT
cp "$main_spec" "$before_snapshot"

# ... write the merged main spec to "$main_spec" now, then: ...

# Requirement headings and scenario IDs that existed BEFORE and are gone AFTER.
# Lines prefixed "<" are losses; "> " lines are additions and are expected.
diff \
  <(grep -E '^(### Requirement:|#### Scenario:)' "$before_snapshot" | sort) \
  <(grep -E '^(### Requirement:|#### Scenario:)' "$main_spec" | sort)
```

Every `<` line the diff reports MUST be accounted for by the delta:

- a `### Requirement:` line only via a `## REMOVED Requirements` entry, or as the OLD name of a
  `## RENAMED Requirements` entry;
- a `#### Scenario:` line only because its entire requirement was REMOVED, or because a MODIFIED
  block deletes it deliberately — and then the delta's `(Previously: ...)` line MUST say so.

**Any loss the delta does not account for is the partial-MODIFIED data-loss case**: the author
wrote a MODIFIED block without copying the full requirement. Do NOT write it through. Restore
`$main_spec` from `$before_snapshot`, return `status: blocked` with
`next_recommended: sdd-spec`, and name the EXACT scenario IDs that would have been deleted,
quoting the diff verbatim in `executive_summary` / `risks`. Scenarios lost from the source of
truth are unrecoverable without git history. A blocked archive is not.

An accounted-for removal that is still large keeps the existing destructive-merge rule: WARN the
orchestrator and ask for confirmation before proceeding.

#### If Main Spec Does NOT Exist

The delta spec IS a full spec (not a delta). Copy it MECHANICALLY with the shell — do NOT Read
the file and Write its content back, which routes every byte through model generation where a
truncation is silent:

```bash
source_spec="openspec/changes/{change-name}/specs/{domain}/spec.md"
target_dir="openspec/specs/{domain}"
target_path="$target_dir/spec.md"

# Collision guard: REFUSE, never choose a name or overwrite.
if [ -e "$target_path" ] || [ -L "$target_path" ]; then
  printf 'main spec collision: %s already exists; %s left unchanged. Merge it as an existing main spec instead of copying over it.\n' "$target_path" "$source_spec" >&2
  exit 1
fi

mkdir -p "$target_dir"

temp_path=""
cleanup_temp() { if [ -n "$temp_path" ]; then rm -f -- "$temp_path"; fi; return 0; }
trap cleanup_temp EXIT
temp_path="$(mktemp "$target_dir/.spec.md.XXXXXX")"

cp "$source_spec" "$temp_path" || exit $?

# MANDATORY readback — empty output is the ONLY passing evidence.
diff -r "$source_spec" "$temp_path" || exit $?

mv "$temp_path" "$target_path" || exit $?
temp_path=""
```

The copy lands on a temp file in the target directory and is only promoted after the readback
passes, so a failed copy never leaves a half-written main spec. Paste the `diff -r` output —
empty — into the phase result.

### Step 3: Move to Archive

Move the ENTIRE change folder to the archive with a date
prefix, using a mechanical shell move. NEVER Read each artifact and Write it into the archive —
that routes the whole audit trail through model generation:

```bash
# Run this block as ONE shell transaction so the EXIT trap stays active.
source="openspec/changes/{change-name}"
destination="openspec/changes/archive/YYYY-MM-DD-{change-name}"

# Pre-move recursive snapshot — this is what the readback compares against.
snapshot_root="$(mktemp -d "${TMPDIR:-/tmp}/sdd-archive.XXXXXX")"
trap 'rm -rf -- "$snapshot_root"' EXIT
cp -R "$source" "$snapshot_root/source" || exit $?

mkdir -p openspec/changes/archive

# Destination-collision guard: REFUSE. Never suffix, overwrite, merge, or delete.
if [ -e "$destination" ] || [ -L "$destination" ]; then
  printf 'archive destination collision: %s already exists. Source %s and destination left unchanged. Resolve it by hand, then rerun this step.\n' "$destination" "$source" >&2
  exit 1
fi

# Mechanical move (MANDATORY): git mv when tracked, plain mv otherwise.
if ! git mv "$source" "$destination"; then
  git_mv_status=$?
  # Fall back ONLY when git left the source exactly as the snapshot found it.
  if [ ! -e "$source" ] && [ ! -L "$source" ]; then
    printf 'git mv failed with status %s and source %s is absent; refusing plain mv fallback.\n' "$git_mv_status" "$source" >&2
    exit "$git_mv_status"
  fi
  if ! diff -r "$snapshot_root/source" "$source"; then
    printf 'git mv failed with status %s and source %s changed; refusing plain mv fallback.\n' "$git_mv_status" "$source" >&2
    exit "$git_mv_status"
  fi
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    printf 'archive destination collision after the failed git mv: %s exists. Nothing moved.\n' "$destination" >&2
    exit 1
  fi
  mv "$source" "$destination" || exit $?
fi

# The source must be gone before the archived tree is compared with its snapshot.
if [ -e "$source" ] || [ -L "$source" ]; then
  printf 'archive move left the source directory %s in place\n' "$source" >&2
  exit 1
fi

# MANDATORY readback: only EMPTY output passes. Paste it verbatim into the phase result.
diff -r "$snapshot_root/source" "$destination" || exit $?
```

Use today's date in ISO format (e.g., `2026-02-16`).

What makes this block correct here, and not merely copied from somewhere:

- The EXIT trap removes `snapshot_root` on every path, success or failure. Run the block as ONE
  shell transaction — split across invocations the trap fires early and the snapshot is gone
  before the readback needs it.
- Compare against the PRE-MOVE snapshot only. Never against a post-move source, a staged tree, or
  a model readback of either side.
- **No `diff -r` exclusions are needed.** In kurama the archive report never lands inside the
  moved folder: Step 5 writes it to `.kurama/sdd/{change-name}/archive-report.md`, outside
  `$destination`. The archived tree must therefore be byte-identical to the snapshot, with
  nothing added and nothing missing.
- `openspec/` is excluded from the Step 0 `Tree-Hash` pathspec, so this move does NOT invalidate
  the content-binding receipt you revalidated before starting.
- The collision guard is a portable pre-check, not an atomic cross-process no-clobber. The rule
  stands regardless: on a collision nothing moves and a human decides.

### Step 4: Verify Archive

The Mechanical Copy Contract IS the verification — the verbatim `diff -r` readback output from
Steps 2 and 3 MUST appear in the phase result, and empty output is the only thing that passes.
In addition, confirm:
- [ ] Verbatim `diff -r` readback output included in the result, and EMPTY (Step 2 spec copy, Step 3 folder move)
- [ ] Merge preservation readback ran on every domain whose main spec already existed, and every removed requirement heading / scenario ID is accounted for by the delta (Step 2)
- [ ] Main specs updated correctly (per domain)
- [ ] Change folder moved to archive
- [ ] Archive contains all artifacts (exploration, proposal, specs, design, tasks, verify-report)
- [ ] Active changes directory no longer has this change

A failed, skipped, or unreported `diff -r` FAILS the phase regardless of the checkboxes above —
agent self-report is never evidence of byte-identity.

**In addition:** confirm the cycle markers on disk with `test -f` or Read — never a finder, since `.kurama/` is hidden AND gitignored:
- [ ] `.kurama/sdd/{change-name}/verify-report.md` is present (written by `sdd-verify` Step 7)
- [ ] `.kurama/sdd/{change-name}/archive-report.md` — Step 5 writes it next; the cycle is not closed until it exists

Those two files are what the hooks read. An archive that leaves them wrong is not finished.

### Step 5: Persist Archive Report

**This step is MANDATORY — do NOT skip it.**

- artifact: `archive-report`
- path: `.kurama/sdd/{change-name}/archive-report.md` — its ONLY home, and deliberately so.
  By the time this step runs the change folder has already moved to
  `openspec/changes/archive/{date}-{change-name}/`; writing back into
  `openspec/changes/{change-name}/` would resurrect that directory and break the
  byte-identical readback of Step 4 (`persistence-contract.md` → *Hook-visible cycle markers*).

Per E2, if the write of the archive report or a merged main spec fails, retry once; if it still fails, return `status: blocked` naming the failing path (`persistence-contract.md` → *Write failure*). Do NOT silently drop the merge or the report.

This write is unconditional, exactly like the verify report (`sdd-verify` Step 7) — and it is the
marker that CLOSES the cycle for the deterministic hooks:

- `orchestrator-write-guard.sh` treats `.kurama/sdd/{change-name}/state.md` **without** an
  `archive-report.md` beside it as an active cycle. Skip this write and the guard keeps blocking
  the orchestrator's every code edit forever, long after the change was archived — there is no
  other way for it to learn the cycle ended.
- `archive-gate.sh` skips any `.kurama/sdd/<dir>/` that holds an `archive-report.md` when it
  auto-detects the change to gate, so this write also stops a closed change from being re-gated.
- Do NOT delete `state.md` instead: the marker pair (`state.md` + `archive-report.md`) is what both
  hooks read, and it is the change's on-disk audit trail after the cycle closes.
- If this write fails, record it in `risks` naming the path and warn that the write guard will keep
  firing until the file exists. Never delete `.kurama/sdd/{change-name}/` to work around it.

### Step 6: Return Summary

Return to the orchestrator:

```markdown
## Change Archived

**Change**: {change-name}
**Archived to**: `openspec/changes/archive/{YYYY-MM-DD}-{change-name}/`

### Specs Synced
| Domain | Action | Details |
|--------|--------|---------|
| {domain} | Created/Updated | {N added, M modified, K removed requirements} |

### Archive Contents
- brainstorm.md ✅ (or "not present")
- exploration.md ✅ (or "not present")
- proposal.md ✅
- specs/ ✅
- design.md ✅
- tasks.md ✅ ({N}/{N} tasks complete)
- verify-report.md ✅

### Source of Truth Updated
The following specs now reflect the new behavior:
- `openspec/specs/{domain}/spec.md`

### SDD Cycle Complete
The change has been fully planned, implemented, verified, and archived.
Ready for the next change.
```

## Rules

- ALWAYS run Step 0 first: NEVER archive when the verify report is missing or its verdict is `FAIL` / has unresolved CRITICAL issues, UNLESS an explicit user-authorized override is passed — and when it is, record the override verbatim in the archive report
- ALWAYS revalidate the **content binding** in Step 0 when the report carries a `Tree-Hash`: recompute the live reviewed-tree hash (throwaway index, excluding `openspec/` and `.kurama/` — byte-identical to sdd-verify Step 6b and archive-gate.sh) and BLOCK on a mismatch with `"verify receipt stale — re-run sdd-verify"`. Only the same explicit override bypasses it; a legacy report with no `Tree-Hash` falls back to the verdict gate alone
- ALWAYS write `.kurama/sdd/{change-name}/archive-report.md` on a successful archive (Step 5). It is the only signal that retires the cycle for `orchestrator-write-guard.sh`; without it the guard blocks the orchestrator indefinitely after the change is closed
- ALWAYS run `skills/_shared/lint-spec.sh` over the delta BEFORE merging it (Step 1a) — resolve it with `test -f` (never a finder). An `ERROR:` line REFUSES the merge: nothing is written, `status: blocked` with `next_recommended: sdd-spec`, findings quoted verbatim. `WARNING:` lines go to `risks` and do not block. A missing script is stated plainly in the report and falls back to the Step 2 preservation readback — never a silent pass
- ALWAYS sync delta specs BEFORE moving to archive
- Archival is a MECHANICAL filesystem operation: copy and move artifacts with `cp`/`cp -R`/`mv`/`git mv` in the shell, NEVER through model Read/Write — a model can truncate or alter bytes silently while reporting success, and only an independent `diff -r` catches it
- ALWAYS run `diff -r` after every archive copy and move (source or pre-move snapshot vs. destination) and include its VERBATIM output in the phase result; EMPTY output is the only passing evidence, and a skipped, missing, or unreported `diff -r` FAILS the phase — agent self-report is never sufficient
- On a destination collision (the target already exists as a file, directory, or symlink), REFUSE: leave source and destination untouched and return `status: blocked` naming both paths. Never append a suffix, choose another name, overwrite, merge, or delete
- If shell access is unavailable, return `status: blocked` with `shell access required for mechanical archive copy is unavailable` — NEVER fall back to Read/Write copying
- Resolve ADDED / MODIFIED / REMOVED / RENAMED from `skills/_shared/openspec-convention.md` → *Delta Spec Sections* — the canonical definition `sdd-spec` also writes against; do not re-derive it
- A `MODIFIED` block REPLACES the entire matching requirement, scenarios included. ALWAYS run the **Merge preservation readback** (Step 2) before a merged main spec becomes the source of truth, and BLOCK with `next_recommended: sdd-spec` when a requirement heading or scenario ID disappears without the delta accounting for it — that is a partial MODIFIED block, and writing it through deletes behavior permanently
- `RENAMED` rewrites the requirement heading in place and PRESERVES its scenarios and their `S-{req}-{n}` IDs; never implement a rename as a delete plus a re-create
- When merging into existing specs, PRESERVE requirements not mentioned in the delta
- A missing REQUIRED upstream artifact → return `status: blocked` naming it (Section D); never archive an incomplete audit trail silently
- Use ISO date format (YYYY-MM-DD) for archive folder prefix
- If the merge would be destructive (removing large sections), WARN the orchestrator and ask for confirmation
- The archive is an AUDIT TRAIL — never delete or modify archived changes
- If `openspec/changes/archive/` doesn't exist, create it
- Apply any `rules.archive` from `openspec/config.yaml`
- Return envelope per **Section D** from `skills/_shared/sdd-phase-common.md`.
