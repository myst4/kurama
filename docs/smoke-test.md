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
- **Write-guard (Claude Code hooks installed) — Pass B and Pass C only**: the
  orchestrator did **not** hand-edit code from the main thread — it delegated to
  `sdd-apply`. To prove the guard bites, ask the orchestrator to edit `index.js`
  directly mid-cycle; the `orchestrator-write-guard.sh` `PreToolUse` hook should
  block it (`exit 2`) and tell it to delegate. Writes under `.kurama/` and
  `openspec/` stay allowed.
  - **Scope**: the guard recognizes an active cycle **only from an on-disk cycle
    marker** — `openspec/changes/<change>/state.yaml` (Pass B) or
    `.kurama/sdd/<change>/state.md` (Pass C degraded). In **Pass A (pure engram)**
    the orchestrator persists DAG state to Engram via `mem_save`, so **no
    filesystem cycle marker exists**; the hook reads "no active cycle" and **allows
    the edit (`exit 0`)**. This is expected, not a bug — run the write-guard proof
    in Pass B or Pass C, where the marker is on disk.

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

---

## Negative checks — prove the gates actually gate

Run these once (Pass B is easiest to inspect on disk). They confirm the
deterministic gates fail *closed*.

> These call `archive-gate.sh` by its **installed** path — the hook lives outside
> your toy project, so a repo-relative `examples/...` path does **not** resolve from
> inside `kurama-smoke`. Use whichever your pass installed: `~/.claude/hooks/kurama/`
> for a **global** install, `.claude/hooks/kurama/` for a **project** install (see
> [installation.md](installation.md)). The examples below use the global path — swap
> in `.claude/hooks/kurama/archive-gate.sh` for a project install. The script
> auto-detects the project root from `$PWD`, so run it from **inside `kurama-smoke`**
> and it gates the toy project. (To exercise the repo source directly instead, call
> it by an absolute path: `<kurama-repo>/examples/claude-code/hooks/archive-gate.sh`.)

1. **Archive without a PASS is refused.** Before Step 6, try `/sdd-archive add-sum`
   (or run the hook CLI directly). It must block, naming the missing verify report:
   ```bash
   ~/.claude/hooks/kurama/archive-gate.sh add-sum   # exit 2, "no verify report / not passing"
   ```

2. **Stale receipt is refused.** After a PASS in Step 6, edit a source file, then
   attempt archive. The live tree hash no longer matches the receipt, so the gate
   blocks with `verify receipt stale — re-run sdd-verify`:
   ```bash
   echo '// touch' >> index.js
   ~/.claude/hooks/kurama/archive-gate.sh add-sum   # exit 2, STALE
   ```
   Re-running `/sdd-verify` re-stamps the hash and unblocks archive. (Writing the
   verify report or moving the change folder does **not** trip this — only real
   code changes do, because `openspec/` and `.kurama/` are excluded from the hash.)

3. **Override is explicit and recorded.** `KURAMA_ARCHIVE_OVERRIDE=1` opens both the
   verdict and stale-receipt gates — confirm it only bypasses the mechanism and that
   `sdd-archive` still records the override reason in the archive report. Never
   self-authorize this.

4. **A `small` change with an empty inline spec is refused.** Classify a change `small`
   but leave `## Spec (inline)` with no `### Requirement:` under it, then attempt archive.
   It must block with `next_recommended: sdd-propose` — a partial delta merged into the
   source of truth is worse than no archive at all.

5. **A proposal with no `## Change Size` runs the long path.** Every change created before
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
