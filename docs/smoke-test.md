# Smoke Test — Manual E2E of the SDD Cycle

A hands-on checklist that drives one full SDD cycle — `init → new → ff → apply →
verify → archive` — on a throwaway toy project, so you can prove an install (or a
change to the skills, scripts, or hooks) works end to end before shipping it.

Run it **once per persistence mode** (`engram`, `openspec`, degraded `engram`). Each
pass takes **~15 minutes**. Nothing here is automated: you type the commands into
your harness and inspect the artifacts, envelopes, and gates yourself.

> This complements `scripts/install_test.sh` (which unit-tests the installers with
> no network). The smoke test exercises the **runtime** — the orchestrator, the
> phase sub-agents, and the deterministic gates — which the installer suite cannot
> reach.

---

## When to run it

- After a fresh install on a new machine or harness (`scripts/setup.sh`).
- Before tagging a release, or on any PR that touches the SDD skills, the
  orchestrator prompt, the Claude Code hooks, or the installer/update/doctor
  scripts.
- When adding or changing a persistence backend.

## Prerequisites

- Kurama installed for your harness — see [installation.md](installation.md).
  This walkthrough uses Claude Code slash commands; the same phases exist on every
  harness (adapt the invocation to your host).
- `git` and a shell.
- **Node 18+** for the toy project below (its test runner is `node --test`, zero
  dependencies). Any project works — swap in Go, Ruby, pytest, or anything else: the test
  and build commands are **asked at `/sdd-init`**, not detected, so no stack is privileged.
  Suggested defaults for common ecosystems live in
  [`skills/_shared/test-runners.md`](../skills/_shared/test-runners.md).
- **Engram pass only**: the `engram` binary on `PATH` and its MCP registered for
  your client (see the Engram section of [installation.md](installation.md)).
- **Optional Kanban check**: `gh` installed, authenticated, and holding the
  `read:project,project` scopes, plus a GitHub Project (v2) board.

---

## The three passes

Run the cycle below once for each row. Only the **Artifact store** choice in the
preflight (Step 0) and where you look for artifacts change between passes.

| Pass | Mode | How to select it | Where SDD artifacts land |
|------|------|------------------|--------------------------|
| A | `engram` | Preflight → Artifact store = **Engram** (needs Engram reachable) | Engram observations (`sdd/<change>/<type>`) |
| B | `openspec` | Preflight → Artifact store = **OpenSpec** | Files under `openspec/` in the toy repo |
| C | degraded `engram` | Run with **Engram not reachable** (MCP unregistered / binary absent) and do not pick OpenSpec | Degraded fallback: `.kurama/sdd/<change>/*.md` |

Notes on Pass C: with Engram intended but unavailable, the contract **degrades to
the `.kurama/sdd/` filesystem fallback** — persistence is never skipped (see
[persistence.md](persistence.md)). Artifacts are markdown under
`.kurama/sdd/<change>/`. Confirm the degrade warning appears and that the artifacts
land there rather than in `openspec/`. Note that Step 1 still
writes `.kurama/skill-registry.md` in every mode — that file is harness
infrastructure, not an SDD artifact, and is written in **every** mode (see Step 1).

The same is true of three **cycle markers**, and it applies to Pass A and Pass B as much
as to Pass C: `.kurama/sdd/<change>/state.md` (orchestrator, after every phase
transition), `verify-report.md` (Step 6) and `archive-report.md` (Step 7) are written in
**every** mode. They are what the two deterministic hooks read — neither can query Engram
— so their presence is checked in the relevant steps below regardless of which pass you
are running. In Pass A they are additional to the Engram artifacts, never a replacement.

---

## Set up the toy project (once per pass)

Use a fresh directory each pass so state never leaks between modes.

```bash
mkdir kurama-smoke && cd kurama-smoke
git init -q

cat > package.json <<'JSON'
{ "name": "kurama-smoke", "version": "0.0.0", "scripts": { "test": "node --test" } }
JSON

# A trivial passing test so init detects test infrastructure (=> behavioral compliance)
cat > index.js <<'JS'
module.exports = {};
JS
cat > index.test.js <<'JS'
const test = require('node:test');
const assert = require('node:assert');
test('smoke baseline', () => { assert.strictEqual(1 + 1, 2); });
JS

git add -A && git commit -qm "chore: toy project baseline"
node --test   # sanity: should report 1 passing test
```

The change you drive through the cycle adds a `sum(a, b)` function plus its test —
small enough to finish fast, real enough that `sdd-verify` executes an actual test
run.

---

## The cycle, step by step

Each step lists the command, what should happen, and **what to verify**. The
"Where to look" pointers are keyed to the pass you are running.

### Step 0 — SDD Session Preflight

The first SDD command in a session triggers a one-time grouped prompt (on Claude
Code, the native `AskUserQuestion` with four groups). Answer:

- **Pace** → *Interactive* (`supervised`) — you want to stop at each human gate.
- **Artifact store** → per your pass (Engram / OpenSpec / inline-safe for Pass C).
- **Delivery** → *Ask on risk* (default).
- **Review budget** → *400* (default).

✅ **Verify**: the prompt renders once as a single grouped question (not four
sequential ones), and does not re-appear on later phases this session.

### Step 1 — `/sdd-init`

Reads the stack and conventions and bootstraps the backend. It asks explicit
questions — answer them:

- **Test command?** → `npm test` (it should offer this as a pre-filled default, since
  `package.json` declares a `test` script — confirm it).
- **Build/type-check command?** → *leave blank*. This toy project has no build step, and
  an empty answer is a VALID answer meaning "none" — verify it is recorded as empty
  rather than replaced with a guess like `npm run build`.
- **Enable TDD?** → *No* (keeps the cycle short; TDD has its own coverage elsewhere).
- **Execution mode?** → *supervised*.
- **Enable Kanban board sync?** → *No* (unless you are running the optional Kanban
  check below).

To prove the harness is genuinely stack-agnostic, run one pass in a project whose
ecosystem is absent from the suggestion table. `sdd-init` must ask with no pre-filled
default and the cycle must complete normally — an unfamiliar stack is a normal case, not
a degraded one.

✅ **Verify**:
- Return envelope: `status: success`, `skill_resolution: none` (init *builds* the
  registry, it loads no project skills).
- `.kurama/skill-registry.md` exists in the toy repo — **written in every mode**,
  including Pass C:
  ```bash
  cat .kurama/skill-registry.md | head
  ```
- Settings home for your pass:
  - **Pass B (openspec)**: `openspec/config.yaml` exists with a `rules.verify`
    block; `compliance_mode: behavioral` (test infra was detected).
    ```bash
    cat openspec/config.yaml
    ```
  - **Pass A (engram)**: an `sdd-init/kurama-smoke` context observation exists
    (ask the agent to `mem_search(query:"sdd-init/kurama-smoke", project:"kurama-smoke")`,
    or use the `engram` CLI). **No `openspec/` directory is created.**
  - **Pass C (degraded)**: no `openspec/`; the context lives in the fallback —
    confirm the orchestrator reported the degrade-to-`.kurama/sdd/` warning.

### Step 2 — `/sdd-new add-sum`

Orchestrator meta-command: delegates `sdd-explore` then `sdd-propose`, then **stops
at the proposal gate** (because Pace = supervised).

✅ **Verify**:
- Two artifacts produced — `explore` and `proposal` — for change `add-sum`:
  - **A**: `mem_search("sdd/add-sum/explore" …)` and `sdd/add-sum/proposal`.
  - **B**: `openspec/changes/add-sum/proposal.md` (exploration is reported inline
    or as `exploration.md`).
  - **C**: `.kurama/sdd/add-sum/proposal.md`.
- Each delegated phase returned a Section D envelope (`status`,
  `executive_summary`, `artifacts`, `next_recommended`, `risks`,
  `skill_resolution`).
- The orchestrator **stopped and asked** whether to continue — it did **not**
  auto-advance into specs/design. (In `auto` it would fast-forward; you chose
  supervised, so it must halt here.)

### Step 3 — `/sdd-ff add-sum`

Fast-forwards the remaining **planning** phases with auto-continue:
`(spec ‖ design) → tasks`. It stops at the **implementation boundary** — after
`tasks`, before `apply` — and never auto-archives.

✅ **Verify**:
- Three new artifacts exist — `spec`, `design`, `tasks`:
  - **A**: `sdd/add-sum/spec`, `sdd/add-sum/design`, `sdd/add-sum/tasks`.
  - **B**: `openspec/changes/add-sum/specs/<domain>/spec.md`,
    `.../design.md`, `.../tasks.md`.
  - **C**: `.kurama/sdd/add-sum/{spec,design,tasks}.md`.
- The spec uses Given/When/Then scenarios with RFC 2119 keywords (MUST/SHOULD).
- **One combined summary** was presented (not one per phase), and the run
  **stopped before `apply`** — implementing unreviewed code is a human gate.

### Step 4 — `/sdd-apply add-sum`

Implements the tasks as real code and marks them complete. Code is written to the
project **in every mode** — the persistence mode governs only the SDD artifacts,
never the implementation.

✅ **Verify**:
- Real source changed in the repo regardless of pass:
  ```bash
  git status --porcelain      # sum() added to index.js (or a new file) + a test
  node --test                 # the new test runs
  ```
- Tasks marked done:
  - **B**: `- [x]` marks in `openspec/changes/add-sum/tasks.md`.
  - **A/C**: the `tasks` artifact shows the boxes checked; an `apply-progress`
    artifact exists (`sdd/add-sum/apply-progress` / `.kurama/sdd/add-sum/apply-progress.md`).
- **Write-guard (Claude Code hooks installed) — all three passes**: the
  orchestrator did **not** hand-edit code from the main thread — it delegated to
  `sdd-apply`. To prove the guard bites, ask the orchestrator to edit `index.js`
  directly mid-cycle; the `orchestrator-write-guard.sh` `PreToolUse` hook should
  block it (`exit 2`) and tell it to delegate. Writes under `.kurama/` and
  `openspec/` stay allowed.
  - **Scope**: the guard recognizes an active cycle **only from an on-disk cycle
    marker** — `openspec/changes/<change>/state.yaml` (Pass B) or
    `.kurama/sdd/<change>/state.md` (Passes A and C). The orchestrator now writes
    that `state.md` in **every** mode, alongside the mode's own state write, so the
    marker exists in **Pass A (pure engram)** too and the guard fires there as well:
    ```bash
    test -f .kurama/sdd/add-sum/state.md && echo "cycle marker present"
    ```
    Use `test -f`, never `fd`/`rg` — `.kurama/` is hidden AND gitignored, so finders
    skip it even with hidden flags. If the marker is missing in Pass A, that is the
    bug this check exists to catch: the guard would read "no active cycle" and allow
    the edit (`exit 0`).

### Step 5 — post-apply review lens (part of the flow)

Per Review Lens Selection, a standard diff runs **exactly one** lens (this small,
behavior-focused change routes to `review-reliability`). A trivial docs-only diff
runs none; a hot-path or >400-line diff runs the full 4R set.

✅ **Verify**: a single lens ran (not a fan-out) and any findings are recorded with
candidate-causal admission — only `BLOCKER`/`CRITICAL` inside the changed hunks
gate; `WARNING`/`SUGGESTION` are `info`.

### Step 6 — `/sdd-verify add-sum`

The quality gate: runs the real test/build, builds the spec compliance matrix from
actual results, and stamps the **Content Binding** receipt.

✅ **Verify**:
- Tests were **executed** (not just read): the report shows `npm test` output with
  passed/failed counts.
- The report carries a compliance matrix and a **`### Verdict`** line reading
  `PASS` (or `PASS WITH WARNINGS`).
- **Content Binding receipt present**: a `Tree-Hash: <hash>` line in the report's
  Content Binding section, and `Reviewed-Tree: <hash>` surfaced in the envelope so
  the orchestrator stamps it into the `state` artifact.
  - **B**: `grep -E 'Verdict|Tree-Hash' openspec/changes/add-sum/verify-report.md`
  - **A/C**: read `sdd/add-sum/verify-report` / `.kurama/sdd/add-sum/verify-report.md`.
- **The on-disk report exists in every pass, Pass A included.** `sdd-verify` writes the
  full report to `.kurama/sdd/add-sum/verify-report.md` in every mode — in Pass A that is
  *in addition to* the Engram save, not instead of it. It is the only file
  `archive-gate.sh` can read, so this check is what proves Step 7 will not dead-end:
  ```bash
  grep -E '### Verdict|Tree-Hash' .kurama/sdd/add-sum/verify-report.md
  ```
  It must be the complete report (verdict + Content Binding), not a stub. If it is
  missing in Pass A, the archive gate will block every archive and point at
  `KURAMA_ARCHIVE_OVERRIDE=1` — do **not** take that hint; the missing file is the bug.
- The hash is computed over a **throwaway** git index (the real index is untouched)
  excluding `openspec/` and `.kurama/` — confirm your working index is unchanged:
  ```bash
  git status            # not staged by verify
  ```

### Step 7 — `/sdd-archive add-sum`

Closes the cycle: gates on the verify report, merges the delta spec into the source
of truth, and archives the change. Archive is **always** an explicit human gate —
never auto-run, even in `auto`.

✅ **Verify (happy path)**:
- The archive gate let it through because the verdict is PASS **and** the live
  reviewed-tree hash still matches the receipt.
- Source of truth updated + change archived:
  - **B**: `openspec/specs/<domain>/spec.md` now contains the merged requirement,
    and the change moved to `openspec/changes/archive/YYYY-MM-DD-add-sum/` (it is
    gone from `openspec/changes/add-sum/`):
    ```bash
    ls openspec/changes/archive/
    ls openspec/specs/
    ```
  - **A**: the cross-change main spec `sdd-specs/kurama-smoke/<domain>` was upserted
    and an `sdd/add-sum/archive-report` observation records the observation IDs.
  - **C**: the archive report is returned/written under `.kurama/sdd/add-sum/`.
- **The cycle is retired on disk, in every pass**:
  ```bash
  test -f .kurama/sdd/add-sum/archive-report.md && echo "cycle retired"
  ```
  `sdd-archive` writes this marker in every mode. It is what tells
  `orchestrator-write-guard.sh` the cycle is over — with `state.md` still there and no
  `archive-report.md` beside it, the guard would keep blocking the orchestrator's code
  edits indefinitely after the change closed. Prove it: after the archive, ask the
  orchestrator to edit `index.js` again; the write must now be **allowed** (`exit 0`).

---

## Negative checks — prove the gates actually gate

The **deterministic hook mechanics** are already pinned by `scripts/install_test.sh`
(no network, run on every PR) — do not re-verify them by hand:

- `archive-gate.sh` refusing an archive with no verify report, blocking a `FAIL`
  verdict, passing a `PASS`, blocking a **stale content-binding** receipt, and the
  `KURAMA_ARCHIVE_OVERRIDE=1` bypass — see the `test_archive_gate_*` cases.
- `orchestrator-write-guard.sh` allowing writes with no active cycle, blocking repo
  code mid-cycle, exempting `openspec/`/`.kurama/`, standing down after archive, and
  still blocking without `jq` — see the `test_write_guard_*` cases.

What the suite **cannot** reach are the two gates that live inside the SDD *skills*
and only fire in a live cycle. Verify these by hand (Pass B is easiest to inspect on
disk):

1. **A `small` change with an empty inline spec is refused.** Classify a change `small`
   but leave `## Spec (inline)` with no `### Requirement:` under it, then attempt archive.
   It must block with `next_recommended: sdd-propose` — a partial delta merged into the
   source of truth is worse than no archive at all.

2. **A proposal with no `## Change Size` runs the long path.** Every change created before
   the size field existed lacks the section. No phase may fail on it, and it must resolve
   to `standard` — never guessed as `small`, which would silently strip two planning
   phases from in-flight work.

---

## Optional — the `small` collapsed path

The cycle above walks a `standard` change: six artifacts, seven phases. A `small` change
collapses the spec and design into the proposal and runs
`explore → propose → tasks → apply → verify → archive` — **3 artifacts instead of 6**.
Worth one pass, because the collapse is where `tasks` and `archive` could deadlock.

Drive the same `add-sum` change, but at Step 2 confirm the proposal classified itself
`small`. It qualifies on all five criteria: single domain, no changed public contract, no
migration, no new dependency, no phase-contract or DAG change.

✅ **Verify**:

- The proposal carries `## Change Size` reading **`small`** with a per-criterion
  rationale, plus `## Spec (inline)` and `## Design (inline)` sections. The inline spec
  uses the standalone delta format verbatim (`# Delta for {Domain}`,
  `## ADDED Requirements`, RFC 2119, `#### Scenario: [S-{req}-N]` with GIVEN/WHEN/THEN).
- **`/sdd-ff` skips `spec` and `design`.** No standalone `spec.md` or `design.md` is
  produced, and no phase blocks for their absence:
  ```bash
  ls openspec/changes/add-sum/     # proposal.md and tasks.md only
  ```
- **`sdd-tasks` succeeded on collapsed inputs** — every scenario ID from the inline spec
  appears in `tasks.md`. This is the first place a naive "skip" implementation deadlocks.
- **`sdd-archive` merged the INLINE delta** into `openspec/specs/<domain>/spec.md`. This
  is the second deadlock point, and the one that matters most: if the inline delta does
  not reach the main specs, the cycle completed without advancing the source of truth.
  ```bash
  grep -c '^#### Scenario:' openspec/specs/arithmetic/spec.md   # scenarios merged
  ls openspec/changes/archive/*/                                # 3 artifacts + archive-report
  ```
- The archive report names the delta's source as the proposal's inline section, so the
  collapse is auditable after the fact.

A `standard` change must behave **exactly** as before — the collapsed path is additive,
and ambiguity always resolves to `standard`.

---

## Optional — Kanban board sync

Only if you enabled Kanban in Step 1 (needs a configured `gh` and a Project v2
board). The board is bookkeeping — a failed `gh` call is a WARNING, never a blocked
phase (the sole exception is the final `gh pr merge`).

✅ **Verify** the card advances at each boundary (resolve the item id per issue,
then read its Status):

```bash
gh project item-list <project_number> --owner <owner> --format json \
  --jq '.items[] | select(.content.number == <issue>) | {status: .status}'
```

| Boundary | Card should be in |
|----------|-------------------|
| Work starts (`/sdd-new` picks up the issue) | **Ready** |
| `/sdd-apply` starts coding | **In Progress** |
| `branch-pr` opens the PR (`Closes #N` on default base) | **In Review** |
| Explicit final OK → merge → verify MERGED → **Done** → return to base | **Done** |

The final OK is always a human gate, even in `auto`, and requires all three
preconditions (explicit per-PR OK, rebased+re-verified branch, fresh
`gh pr checks` pass) before the canonical merge order.

---

## What to verify at each gate — quick reference

| Phase | Artifact produced | Envelope check | Extra gate |
|-------|-------------------|----------------|-----------|
| `sdd-init` | `.kurama/skill-registry.md` (+ settings home) | `success`, `skill_resolution: none` | — |
| `sdd-new` | `explore`, `proposal` | Section D per phase; `next_recommended` | Stops at proposal gate (supervised) |
| `sdd-ff` | `spec`, `design`, `tasks` | one combined summary | Stops at implementation boundary |
| `sdd-apply` | code + `apply-progress`, tasks `[x]` | `success` | Write-guard blocks direct orchestrator edits (Pass B/C only — needs an on-disk cycle marker) |
| review lens | findings (`info`/blocker) | one lens for a standard diff | Candidate-causal: only introduced BLOCKER/CRITICAL block |
| `sdd-verify` | `verify-report` + `Tree-Hash` | `Reviewed-Tree` surfaced | Tests actually executed; `### Verdict: PASS` |
| `sdd-archive` | merged main spec + `archive-report` | `success` | Verdict PASS **and** fresh content binding |

---

## Time budget (~15 min per pass)

| Step | Est. |
|------|------|
| Toy setup | 2 min |
| init + new + ff | 5 min |
| apply + review lens | 4 min |
| verify + archive | 3 min |
| Negative checks (once) | +3 min |

---

## Cleanup

```bash
cd .. && rm -rf kurama-smoke
```

For the **engram** pass the toy's observations persist in Engram under
`project: "kurama-smoke"`; delete them via the `engram` CLI if you want a clean
store, or leave them — a fresh smoke project uses a new name each time.
