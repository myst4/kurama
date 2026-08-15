# Migration Guide

Guidance for existing installations and projects moving through the ongoing
stabilization work (Phases 1-8). For what changed and when, see
[docs/changelog.md](changelog.md). For the persistence contract itself, see
[docs/persistence.md](persistence.md).

## Breaking change: Windows is no longer supported

Kurama runs on **macOS and Linux**. `scripts/setup.ps1` and `scripts/install.ps1`
are gone.

**Why it changed.** The PowerShell scripts were a second implementation of the
installer kept in parity by hand, and it had already drifted — `setup.ps1` never
supported `omp`. The rest of the lifecycle (`update.sh`, `doctor.sh`,
`uninstall.sh`, the test suite) was always bash-only, so a Windows install had no
maintenance path: nothing to update it, check it, or remove it cleanly.

**What you will see.** `.\scripts\setup.ps1` no longer exists. The bash scripts no
longer resolve `USERPROFILE`/`APPDATA` or detect Git Bash / MSYS / Cygwin.

**If you are on Windows**, use **WSL** and run the bash scripts there — they
install to the WSL-side `$HOME`, which is where an agent running inside WSL looks.
This is the same thing the old `wsl` branch did, minus the Git-Bash path. A native
Windows install is no longer supported.

## Breaking change: Gemini CLI, Cursor, VS Code Copilot and Antigravity are no longer supported

The supported harnesses are now **Claude Code, OpenCode, Codex, Pi, and omp**.

**Why it changed.** Kurama's premise is delegation to sub-agents with isolated,
fresh context windows. Of the four dropped hosts, none provides that primitive —
the orchestrator ran inline on all of them, which is the context-flywheel the
harness exists to break. Each still cost six edit points across the two setup
scripts plus its own template, generated example, tests, and docs; Cursor also
forced the prompt writer's only special case (a verbatim `.mdc` copy that
`uninstall.sh` could not surgically strip).

**What you will see.** `setup.sh --agent gemini-cli|cursor|vscode|antigravity`
now exits with `Unknown option`. `--all` no longer detects the `gemini`, `cursor`
or `code` binaries. `gemini-extension.json` and the corresponding `examples/`
directories are gone, so `gemini extensions install` no longer works.

**If you have an existing install on one of these**, nothing is deleted from your
machine — but it is no longer managed. `update.sh` fails loudly on those receipts
instead of re-syncing (their slug no longer resolves), and `uninstall.sh --all`
no longer visits their paths. To clean up, remove the skills directory
(`~/.gemini/skills`, `~/.cursor/skills`, `~/.copilot/skills`,
`~/.gemini/antigravity/skills`) and strip the `BEGIN:kurama … END:kurama` block
from the corresponding prompt file by hand. Cursor's rule file
(`~/.cursor/rules/kurama.mdc`) is entirely Kurama's and can be deleted outright.

**If you want to keep using one of them**, the skills are plain Markdown in the
open [Agent Skills](https://agentskills.io) format — copy `skills/` wherever that
host reads skills and paste `examples/_templates/core.md` as your orchestrator
prompt. That is the manual path the installer used to automate.

## Breaking change: project commands are asked, not detected

`sdd-init` now ASKS for the project's test command, build command, and (when TDD is
enabled) single-test command, instead of inferring them from a closed table of
ecosystems.

**Why it changed.** The table covered 8 ecosystems and sat on the PRIMARY resolution
path, so any stack outside it dead-ended: `sdd-verify` found no runner and, in
`behavioral` mode, turned every MUST scenario into UNTESTED → CRITICAL. A harness that
claims to be stack-agnostic cannot carry a supported-language allowlist on its critical
path. The inversion also restores consistency — `tdd.enabled`, `execution_mode`, and
`kanban.enabled` were already explicit questions; the most project-specific value of
all was the one being guessed.

**What you will see.** `/sdd-init` asks for the commands, pre-filled with a suggestion
when a familiar detection file is present. An empty answer is valid and means "this
project has none" — it is recorded as empty, not re-guessed.

**If a phase reports a missing command**, the fix is always the same: re-run
`/sdd-init`, or set `rules.verify.test_command` / `rules.verify.build_command` (and
`tdd.single_test_command`) directly. No phase guesses a command anymore — a guessed
command fails opaquely or, worse, runs the wrong thing.

**Existing projects need no action.** A config that already has these keys keeps
working unchanged; the propagated-value precedence is untouched.

## `go-testing` moved to the opt-in `lang` group

The default install is now **24 skills** instead of 25. `go-testing` moved to a new
`lang` manifest group that is **OFF by default**.

**Why it moved.** It was the only language-specific skill shipped to every user of
every language. The skill registry is already the agnostic extension point for
per-language patterns, so the special case bought nothing and contradicted the
stack-agnostic claim.

**Nothing was deleted.** The skill file is unchanged and still ships in the repo.

**If you rely on it**, add `--with lang`:

```bash
./scripts/install.sh --agent claude-code --with lang
```

```powershell
.\scripts\install.ps1 -Agent claude-code -With lang
```

Otherwise place your own language skills anywhere the skill registry scans, and they
reach sub-agents as compact rules the same way.

## Breaking change: the `none` artifact-store mode was removed

The artifact-store enum is now `engram | openspec | hybrid`. `none` — persist no
SDD artifacts, return them inline — no longer exists.

**Why it went.** The whole point of the workflow is that specs are the source of
truth, and `none` produced nothing that survived the session. `sdd-archive` had no
delta spec to merge, so the main specs never advanced: a cycle could complete and
leave the source of truth exactly where it started. The mode also cost a branch in
every phase's persistence section, for a setting no project benefited from choosing.

**If your project used it**, you will see the mode reported as unsupported rather
than silently writing nothing. To migrate:

1. Set the mode to `openspec` in `openspec/config.yaml` (or in the
   `sdd-init/{project}` settings artifact for Engram-backed projects).
2. Re-run `/sdd-init` to regenerate the config against the current schema.

**There is no data to move.** `none` never wrote artifacts, so nothing exists to
migrate — only the setting changes. Everything a past `none` cycle produced was
already inline in a conversation and is not recoverable by this or any other route.

**Unrelated to this change**: `.kurama/` is harness infrastructure and was never
gated by the persistence mode. The skill registry and the `.kurama/sdd/` fallback
(used when Engram is the intended backend but is unreachable) behave exactly as
before.

## Phase 1 — Breaking change: verify commands moved to `rules.verify.*`

Older `openspec/config.yaml` files defined `test_command`, `build_command`,
and `coverage_threshold` as keys mixed into the `rules.apply` list — a
sequence of guidance strings with mapping keys spliced into the same node,
which is invalid YAML. Both `sdd-apply` and `sdd-verify` now read these three
keys exclusively from `rules.verify`, a mapping:

```yaml
# BEFORE (invalid — a sequence node cannot also carry mapping keys)
rules:
  apply:
    - Follow existing code patterns and conventions
    tdd: false
    test_command: "npm test"

# AFTER (current schema)
rules:
  apply:
    - Follow existing code patterns and conventions
  verify:
    test_command: "npm test"
    build_command: "npm run build"
    coverage_threshold: 0
```

**Action required**: if your project's `openspec/config.yaml` predates this
change, move `test_command`, `build_command`, and `coverage_threshold` from
`rules.apply` into a new `rules.verify` mapping. `rules.apply` stays a plain
list of behavioral-guidance strings — do not add command keys back to it.

### How to detect an old config

```bash
rg -n "test_command|build_command|coverage_threshold" openspec/config.yaml
```

Open the match: if it's indented under `apply:` (or your YAML parser rejects
the file, or a linter reports something like "bad indentation of a mapping
entry"), you're on the old schema. If it's under a `verify:` mapping, you're
already current.

## Phase 2 changes

### `rules.verify.compliance_mode` (new key)

Controls how strictly `sdd-verify` and `sdd-archive` gate on untested
requirements:

- `behavioral` (default when the project has test infrastructure) — a MUST
  scenario with no passing test is CRITICAL; the cycle cannot close on it.
- `static` (default when no test infrastructure is detected) — an untested
  MUST is a WARNING, not a blocker; compliance can rest on static evidence and
  the cycle can close without a test suite.

`sdd-init` detects test infrastructure and picks the default for you. No
action is required for existing projects — `sdd-verify` reads a value
propagated by the orchestrator first, falls back to `rules.verify.compliance_mode`
in `openspec/config.yaml`, and defaults to `behavioral` if neither is set; a
missing key is not an error. `sdd-archive` also gained a real Step 0
that reads the verify report before archiving: a missing report, or a `FAIL`
verdict, blocks the archive unless the user explicitly overrides it (an
override is recorded in the archive report).

### Main specs persist as artifacts in `engram` mode

Previously, `engram` mode never merged delta specs into a main spec on
archive — there was no artifact type for it, so the merge silently never
happened. Main specs now persist as Engram artifacts (`topic_key:
sdd-specs/{project}/{domain}`), and `sdd-archive` merges into them the same
way `openspec`/`hybrid` merge into `openspec/specs/{domain}/spec.md`.
`sdd-spec` reads the Engram main-spec artifact as its baseline for new
changes.

**Action required**: none going forward. Changes archived in `engram` mode
*before* this update have no main-spec artifact to build on — their deltas
were never merged anywhere. If you need that history, re-derive it from each
change's archived `spec` artifact (`sdd/{change-name}/spec`) rather than
expecting a pre-existing main spec.

### `.kurama/sdd/` fallback store **and cycle markers** (new)

`.kurama/` — already used for `.kurama/skill-registry.md` — gains a second role.
`.kurama/sdd/{change-name}/` is the filesystem fallback for SDD artifacts when
Engram is unreachable at the start of a cycle (the orchestrator checks with
one cheap Engram call and degrades the whole cycle to this fallback, with a
warning), or when a single `mem_save` fails mid-cycle in `engram` mode (one
retry, then a fallback file written under this path, reported as a concern in
the phase's return envelope).

The same directory is **also** the home of three **cycle markers** written on
**every** cycle in **every** mode, `engram` included — `state.md` (orchestrator,
after each phase transition), `verify-report.md` (`sdd-verify`) and
`archive-report.md` (`sdd-archive`, on success). These are not a degradation
signal: the deterministic Claude Code hooks read only the filesystem and cannot
query Engram, so without them the archive gate blocks every legitimate archive
and the write guard never fires. See
[persistence-contract.md](../skills/_shared/persistence-contract.md) →
*Hook-visible cycle markers* and [docs/hooks.md](hooks.md).

No action required, but two expectations change. First, `.kurama/sdd/` now
appears on every cycle, not only when Engram is unavailable or fails — a
directory there does **not** mean something degraded. Second, it never contends
with `openspec`/`hybrid` project files: `.kurama/` is gitignored harness state,
exempt from the persistence-mode gates, and excluded from the verify→archive
content-binding hash, so the markers cannot make a verify receipt read as stale.

### Return envelope unification

Per-skill "Return Summary" sections used to describe slightly different field
sets. Section D of `skills/_shared/sdd-phase-common.md` is now the only return
contract — every phase, including `sdd-init`, returns `status`,
`executive_summary`, `detailed_report` (optional), `artifacts`,
`next_recommended`, `risks`, and `skill_resolution`. Per-skill sections are
one-line pointers to it.

**Action required**: if you built tooling that parses a specific skill's old
return format, update it to expect the uniform envelope described in
[docs/architecture.md](architecture.md#sub-agent-result-contract).

### Manifest-driven install and uninstall

`skills/manifest.json` now declares every skill (group: `sdd-core`, `quality`,
or `optional`) with its per-harness install targets, and `VERSION` at the repo
root is the version source of truth. `setup.sh`/`install.sh` read the manifest
instead of a hardcoded list, and record an install manifest (installed files +
version) under each install target so `scripts/uninstall.sh` can remove
exactly what was installed.

Two behavior changes to note:

- `go-testing` and `judgment-day` move from unconditionally installed to
  group-flagged — install them explicitly (opt-in) or exclude them (opt-out)
  per your installer's flag; check `--help` on your installed version.
- Installations done with a pre-manifest installer have no install manifest on
  disk, so `scripts/uninstall.sh` cannot target them.

**Action required**: re-run `setup.sh`/`install.sh` once against the current
version so an install manifest is recorded before relying on `uninstall.sh`.

## Phase 3 — Optional TDD module

### New `tdd:` config block (opt-in)

A top-level `tdd:` block was added to the canonical `openspec/config.yaml`
schema (a sibling of `rules:`), holding exactly two keys: `enabled` (bool) and
`single_test_command` (string). In `engram` mode the same two keys
live in the `sdd-init/{project}` context artifact instead of a config file.
See [skills/tdd/SKILL.md](../skills/tdd/SKILL.md) and
[docs/tdd.md](tdd.md) for the full cycle contract and activation precedence.

**Action required**: none. TDD activates ONLY when `tdd.enabled` is
explicitly set `true` — existing test files in a project are never an
activation signal, and installing `skills/tdd` on disk does not activate it
either. Projects that don't set the flag are unaffected.

### `tdd` skill group (opt-in, not installed by default)

> **Superseded by Phase 8 (below).** As of Phase 8 the `tdd` module is **installed
> by default** (`default: true`), so the `--with tdd` opt-in described here is no
> longer needed — a plain `setup.sh`/`install.sh` already lands it. This section is
> kept for historical context; pass `--without tdd` to exclude the module now.
> Activation stays opt-in in both phases (installing the module never turns TDD on).

`skills/manifest.json` gained a `tdd` group (`default: false`) holding
`skills/tdd`. At the time, it was installed explicitly with the group flag on the
`install.sh` / `install.ps1` installers:

```bash
./scripts/install.sh --with tdd        # bash / macOS / Linux / WSL / Git Bash
```

```powershell
.\scripts\install.ps1 -With tdd        # Windows PowerShell
```

At the time, the module stayed excluded from a default install alongside the
always-on `sdd-core` and the default-on `quality`/`optional` groups; `setup.sh`/`setup.ps1`
installed the **default set** with TDD excluded, and there was no `--with` flag on the
`setup` scripts, so `install.sh --with tdd` / `install.ps1 -With tdd` was the only way
to add the module. (Phase 8 folded `tdd` into the default set, so this exclusion no
longer applies — see the Phase 8 section below.)

**Action required**: none under the current (Phase 8) default — `tdd` installs without
a flag. The historical `--with tdd` command still works but is now redundant; pass
`--without tdd` to keep the module off disk.

### RED/GREEN/REFACTOR subtask expansion

When TDD resolves active, `sdd-tasks` expands each behavior task into `n.x`
RED / `n.y` GREEN / `n.z` REFACTOR subtasks referencing the spec's
`S-{requirement-slug}-{n}` scenario ID (e.g. `S-auth-1`), and `sdd-verify`
audits scenario → test traceability and RED
evidence as a WARNING ("test-after detected") — never CRITICAL, since the
module is opt-in and honest, not punitive.

**Action required**: none for existing changes; this only applies to changes
planned after TDD is enabled for the project.

## Phase 4 — Multi-harness modernization

### Generated example orchestrators (new editing workflow)

The seven per-harness orchestrator files under `examples/` are now
**generated** from `examples/_templates/core.md` (the shared orchestrator
body, including the TDD section and the canonical 6-field Result Contract)
plus one `{harness}.md` overlay per harness holding only that harness's
deltas. `scripts/build-examples.sh` assembles core + overlay into each
output file; every generated file opens with a `GENERATED FILE — edit
examples/_templates/, then run scripts/build-examples.sh` marker in its own
comment syntax. A `pr-check.yml` job runs the build and fails the PR on any
resulting `git diff`. See
[docs/installation.md](installation.md#editing-the-generated-example-orchestrators).

**Action required**: stop hand-editing files under `examples/<harness>/` —
edit the matching file(s) under `examples/_templates/` and re-run
`scripts/build-examples.sh`. A direct edit to a generated file is silently
overwritten the next time the build runs, and now also caught by CI.

### New packaging artifacts

- `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` — install
  Kurama as a Claude Code plugin (`/plugin marketplace add ...`) instead of
  copying files by hand; the plugin version is read from the repo's
  `VERSION` file.
- `gemini-extension.json` — a Gemini CLI extension manifest referencing
  `GEMINI.md` and the skills directory, installable with
  `gemini extensions install`.
- Codex's project-level `.agents/skills/` convention is now documented (see
  [docs/installation.md](installation.md#codex)) as an alternative to the
  user-level `~/.codex/skills` the installer still targets by default — it
  is documentation only; no installer writes there automatically.

**Action required**: none — these are additive install paths alongside
`setup.sh`/`install.sh`, which remain fully supported.

### Meta-skills promoted to standalone skills

`sdd-new`, `sdd-continue`, and `sdd-ff` — previously orchestrator-only
"meta-commands" documented inline in each example prompt — are now real
skills on disk (`skills/sdd-new/SKILL.md`, `skills/sdd-continue/SKILL.md`,
`skills/sdd-ff/SKILL.md`). They are registered in the required `sdd-core`
group in `skills/manifest.json` (now 16 `sdd-core` / 19 total skills), so a
default `setup.sh`/`install.sh` run copies all three automatically — no manual
copy step is needed.

**Action required**: none. Their packaging changed (standalone skills instead
of orchestrator-prompt text), but their behavior is unchanged and the default
installers already include them (a default install lands 18 skills; the three
meta-skills are part of that set).

### Hooks (opt-in, Claude Code only)

`examples/claude-code/hooks/` ships an optional `hooks.json` plus portable
bash scripts implementing two deterministic gates: a `PreToolUse` guard that
blocks the orchestrator's own `Edit`/`Write` to repo files while an SDD cycle
is active (delegation must still happen; `.kurama/` and `openspec/` artifact
paths are exempt), and an archive gate that mechanically refuses
`sdd-archive` when the persisted state lacks a verify `PASS` — mirroring
`sdd-archive`'s own Step 0 check, but enforced deterministically instead of
by prose alone. See docs/hooks.md for the rationale.

**Action required**: none — hooks are opt-in and not installed by default;
copy `examples/claude-code/hooks/` yourself if you want the gates enforced
mechanically.

> **Superseded by Phase 10b (below).** As of Phase 10b the Claude Code hooks
> **are** installed automatically by `setup.sh --agent claude-code` (both
> scopes, no prompt). The "copy them yourself / not installed by default" note
> above is historical; re-run `setup.sh --agent claude-code` to land them. See
> the Phase 10b section.

## Phase 5 — Delivery guard, execution mode, TDD triangulation

### `execution_mode` (new top-level config key)

A top-level `execution_mode` key was added to the canonical `openspec/config.yaml`
schema (a sibling of `schema:` and `rules:`), with two values:

- `supervised` (default) — the orchestrator stops at the human gates (post-propose, a
  verify `FAIL`, and pre-archive) and asks for a decision before continuing.
- `auto` — the orchestrator advances automatically, halting only on `status: blocked`
  or a verify `FAIL`.

Resolution mirrors `compliance_mode` and `tdd`: a value the orchestrator explicitly
propagates wins, else `execution_mode` in `openspec/config.yaml` (openspec/hybrid) or
the `sdd-init/{project}` settings bundle (engram), else the default `supervised`.
`sdd-init` asks for the mode at initialization and persists it; `sdd-new`/`sdd-continue`
condition their human gates on it; `/sdd-ff` always runs in `auto` regardless of the
configured value. The schema line is kept byte-identical between `openspec-convention.md`
and the `sdd-init` Step 3 template.

**Action required**: none. A missing `execution_mode` key defaults to `supervised` (the
previous stop-at-every-gate behavior); set it to `auto` to let the pipeline auto-advance
between dependency-ready phases.

### Review Workload Guard + Delivery Strategy in `skills/branch-pr`

`skills/branch-pr` gained a **Review Workload Guard** that measures a change against its
base before a PR is assembled (`git diff --stat`/`--numstat` against `origin/<base>`) and
partitions the work into a stacked chain of PRs when it crosses ~400 authored changed
lines, or touches >8 files across >3 top-level modules. A **Delivery Strategy** table
(small → single direct PR; large → stacked chain; risky domain — auth/payments/data/
security — at any size → risk flag + mandatory rollback note) and a **Chain Strategy**
(one branch per unit, each PR standalone, base = previous PR) accompany it. The
orchestrator example template's delegation guide now routes delivery through this guard.

**Action required**: none. This is guidance for how PRs are sized and delivered; it does
not change any config or existing PR.

### Optional TRIANGULATE sub-step in the TDD cycle

The TDD cycle gained an **optional** `TRIANGULATE` sub-step between GREEN and REFACTOR:
when a behavior has a real edge/boundary (empty input, zero/limit, off-by-one, error
path), add a second test for the same scenario before refactoring; a failing boundary
test loops back to GREEN. The cycle name is unchanged (still RED → GREEN → REFACTOR), the
step is never required, and `sdd-verify` never flags its absence.

**Action required**: none. Triangulation is optional and only relevant when the opt-in
TDD module is enabled.

## Phase 6 — Review layer, content-bound receipts, resolver inversion, Pi

### New `review` skill group (default-on)

`skills/manifest.json` gained a `review` group (`default: true`) holding five new
read-only review lenses: `review-risk` (R1), `review-readability` (R2),
`review-reliability` (R3), `review-resilience` (R4), and `review-refuter`. They ship
**installed by default** alongside `sdd-core`, `quality`, and `optional`; at the time
this landed, a default install was **23 skills** (was 18) with `--with tdd` at **24**
(superseded by Phase 8: `tdd` now installs by default — 24 default, `--without tdd` 23). Opt out with
`--without review` (bash `install.sh`/`setup.sh`, PowerShell `install.ps1`/`setup.ps1`).

The orchestrator selects lenses by deterministic triage — trivial diff → no lens;
standard diff → exactly one dominant-risk lens; hot path (auth/update/security/payments)
or >400 authored lines → the full 4R sweep. Only findings **introduced** by the diff can
block, and only `BLOCKER`/`CRITICAL` gate. See
[docs/sub-agents.md](sub-agents.md#review-lenses-4r--refuter) and the shared
[`skills/_shared/review-ledger-contract.md`](../skills/_shared/review-ledger-contract.md).

**Action required**: none. Re-run `setup.sh`/`install.sh` once to land the new lenses
(or pass `--without review` to keep the previous 18-skill set).

### Content-bound verify receipt (verify + archive)

`sdd-verify` now records a **Content Binding** section in its report: a reviewed-tree
hash computed over a throwaway git index (`GIT_INDEX_FILE=$(mktemp)` + `git add -A` +
`git write-tree`, excluding `openspec/` and `.kurama/`) — the real index is never touched —
plus the changed-file list. `sdd-archive` Step 0 and the optional
`examples/claude-code/hooks/archive-gate.sh` **re-derive the hash and block on mismatch**
("verify receipt stale — re-run sdd-verify"). `KURAMA_ARCHIVE_OVERRIDE=1` still bypasses the
gate and is recorded in the archive report. This closes the previously declared gap where
the archive gate trusted the verdict without verifying the tree (see
[docs/hooks.md](hooks.md)). In a non-git project the binding degrades gracefully to
verdict-only.

**Action required**: none. If you archive a change after editing code post-verify, re-run
`sdd-verify` so the receipt matches the tree.

### Skill-resolver default inverted (registry index + read the SKILL.md)

`skills/_shared/skill-resolver.md` inverted its default: the orchestrator now passes the
**registry index and the exact `SKILL.md` path** so the sub-agent reads the full skill,
and compact-rules injection became an **opt-in** low-token optimization used only when the
context budget demands it. The previous prohibition on sub-agents reading `SKILL.md` was
removed.

**Action required**: none. Existing registries keep working; compact rules still exist and
are injected when the budget requires.

### `capture_prompt: false` on automated SDD artifact saves

Every `mem_save` template for **automated** SDD artifacts (state, proposal/spec/design/
tasks/apply/verify/archive reports, skill registry, project context) now carries
`capture_prompt: false` — the user's prompt is never captured for machine-generated
artifacts. Genuine human/discovery saves keep the default (`true`). The rationale is
documented as a canonical note in
[`skills/_shared/engram-convention.md`](../skills/_shared/engram-convention.md); the rule
is chosen by **provenance** (automated artifact → `false`), not by `type`.

**Action required**: none — Engram versions without the field simply ignore it.

### `apply-progress` read-merge-write continuity

`sdd-apply` now **reads the existing apply-progress artifact, merges task states, and
writes back** — the shared `topic_key` upsert is destructive, so a blind overwrite could
drop completed-task history across resumed cycles. Documented in
[`skills/_shared/engram-convention.md`](../skills/_shared/engram-convention.md).

**Action required**: none.

### Pi is the 8th supported harness

Kurama adds **Pi** as an eighth harness. Its orchestrator is generated from
`examples/_templates/core.md` + a new `examples/_templates/pi.md` overlay into
`examples/pi/AGENTS.md` (project-root `AGENTS.md` convention; global alternative
`~/.pi/agent/AGENTS.md`). Pure Markdown, no `gentle-pi` npm dependency; Pi routes
models per-agent, so no orchestrator-level model table is injected.

**Action required**: none. If you use Pi, copy `examples/pi/AGENTS.md` into your project
per [docs/installation.md](installation.md).

### `scripts/sdd-status.sh` (new, offline)

A dependency-light (`bash 3.2` / POSIX, no `jq`) status inspector: `scripts/sdd-status.sh
[project]` lists active SDD cycles with store, last/next phase (derived from the canonical
DAG), visible settings, and task progress; `--json` emits a parseable object. Reads
`openspec/` and the `.kurama/sdd/` cycle markers from disk. Because those markers are
written in **every** mode (see *`.kurama/sdd/` fallback store and cycle markers* above),
`engram` cycles are listed too; only a cycle started before the markers existed, and not
advanced since, leaves nothing on disk and stays invisible offline.

**Action required**: none — it is a read-only diagnostic.

## Phase 8 — Pi installer wiring, TDD installed by default

### `tdd` module is now installed by default (supersedes the Phase 3 default)

Phase 3 shipped the `tdd` group as opt-in-install (`default: false`, added with
`--with tdd`). Phase 8 flips it to **installed by default** (`default: true` in
`skills/manifest.json`, `required: false`). `setup.sh`/`setup.ps1` and
`install.sh`/`install.ps1` now include the module in the default set; a default
install lands **24 skills** (was 23), and `--without tdd` lands **23**. The old
`--with tdd` opt-in is no longer needed for a default install.

**Activation is unchanged.** Installing the module has never activated TDD, and
that still holds: `tdd.enabled` starts `false` everywhere, `sdd-init` asks the
explicit enable question, and existing test files never flip it on. The rationale
is that **a project can start without tests and add them later** — the module
ships available on disk, and each project opts into the RED → GREEN → REFACTOR
cycle on its own terms (see [docs/tdd.md](tdd.md)).

**Action required**: none functionally. Re-run `setup.sh`/`install.sh` once to land
the module in the default set (or pass `--without tdd` to keep it off disk). No
config migration — a project's `tdd.enabled` value is untouched, and projects that
never opted in stay inactive.

### Remediation-message wording (sdd-init / sdd-tasks / sdd-apply / sdd-verify)

The four skills still guard against the module being absent while TDD is enabled
(it can happen only when someone installed with `--without tdd`), but their
"module missing" messages now say to **reinstall with `scripts/install.sh`**
(the default install includes it) instead of the old `--with tdd`. The guard logic
and flag precedence are unchanged — only the message text was updated.

**Action required**: none.

### Pi wired into the installers

Pi — added as the eighth harness in Phase 6 (project-root `AGENTS.md` convention;
global alternative `~/.pi/agent/AGENTS.md`) — is now detected and wired by
`setup.sh`/`setup.ps1` and `install.sh`/`install.ps1` (`--agent pi`), and Pi is a
target in `skills/manifest.json`. The orchestrator is the generated
`examples/pi/AGENTS.md`; the Kurama block uses the standard idempotent
`<!-- BEGIN:kurama -->` / `<!-- END:kurama -->` markers. See
[docs/installation.md](installation.md#pi).

**Action required**: none. If you use Pi, run `setup.sh --agent pi` (or follow the
manual steps in the installation guide) to wire the orchestrator.

## Phase 9 — Optional GitHub Projects kanban module

### New `kanban-github` skill in the default set (install ≠ activate)

Phase 9 adds an optional GitHub Projects (v2) board-sync module,
[`skills/kanban-github`](../skills/kanban-github/SKILL.md), to the `optional` manifest group. A
default install now lands **25 skills** (was 24); `--without tdd` lands **24**, and
`--without optional` now drops **two** skills (`go-testing` **and** `kanban-github`) for
**23**. Installing the module never activates the board — activation is opt-in per
project through the explicit `kanban.enabled` flag, exactly like the TDD switch.

**Action required**: none functionally. Re-run `setup.sh`/`install.sh` once to land
the module in the default set (or pass `--without optional` to keep the `optional`
group off disk). No config migration — projects that never opt in are unaffected,
and the board stays inactive until `kanban.enabled: true` is set.

### Activating the board requires a configured `gh`

When you enable kanban for a project, `sdd-init` requires a working GitHub CLI and
verifies it in order — `gh --version`, `gh auth status`, and the `read:project,project`
scopes (`gh project list --owner @me`). A failing check is never fatal: `sdd-init` prints
the exact fix (`brew install gh` / `gh auth login` / `gh auth refresh -s read:project,project`),
records `kanban.enabled: false`, and continues init. You can re-run `/sdd-init` once
the prerequisite is in place. The `gh` requirement applies **only** to activating
kanban — every other skill works without it.

### New `kanban` config block (opt-in, defaults inert)

Enabling the board persists a top-level `kanban:` block (in `openspec/config.yaml`
for openspec/hybrid, or the `sdd-init/{project}` context artifact for engram)
holding the board wiring `sdd-init` caches during onboarding: `enabled`, the OPTIONAL
`user` (empty => `@me`), `owner`, `repo`, `project_number`, the cached `project_id`
(`PVT_...`), `status_field_id`, `merge_method`, the `stages` map (canonical stage →
real board option id), and the OPTIONAL `size_field_id` + `sizes` map. The schema is
byte-identical across `openspec-convention.md`, the `sdd-init` template, and
`skills/kanban-github/SKILL.md`.

**Action required**: none. The block only appears when you opt in; absent, the board
is simply off. The 5-stage lifecycle (Backlog → Ready → In Progress → In Review →
Done), the assignment rule, the WARNING-on-failure semantics, and the human merge
gate are documented in [docs/kanban-github.md](kanban-github.md).

## Phase 10a — Native agents full install, Pi package stack

### Claude Code now installs all 17 native subagents (was 9, manual/optional)

Through Phase 4, `examples/claude-code/agents/` shipped **9** declarative subagents
(one per SDD phase) and installing them was **optional and manual** — setup wired only
skills + the orchestrator. Phase 10a adds **8 review-layer agents** to that directory —
the four 4R lenses (`review-risk`, `review-readability`, `review-reliability`,
`review-resilience`), the `review-refuter`, the two Judgment Day judges (`jd-judge-a`,
`jd-judge-b`), and the `jd-fix-agent` — bringing it to **17**, and makes
`setup.sh`/`setup.ps1 --agent claude-code` **install all 17 automatically** into
`~/.claude/agents/`. The install backs up any pre-existing same-named file (timestamped,
via the shared `make_backup`), copies atomically, and records **every** installed agent
in the target's `.kurama-install-manifest.json` receipt so `scripts/uninstall.sh` can
remove exactly what setup added.

Each new agent is **thin**: frontmatter (`name`, `description` with a Trigger, `tools`,
`model`) plus a body that loads and follows its Kurama skill and returns that skill's
envelope — it never duplicates the skill body. Tools/model routing: the 4R lenses run
`tools: Read, Grep, Glob` + `model: sonnet`; `review-refuter`, `jd-judge-a`, and
`jd-judge-b` run `Read, Grep, Glob` + `model: opus`; `jd-fix-agent` runs
`Read, Edit, Write, Glob, Grep, Bash` + `model: opus`. The four lenses, the refuter, and
the judges are **read-only enforced by the `tools:` list** (no `Edit`/`Write`, no
`Task`). The 9 SDD phase agents are unchanged.

**Action required**: none functionally. Re-run `setup.sh --agent claude-code` once to
land the 17 agents in `~/.claude/agents/` (existing same-named files are backed up
first). Removing the agents is safe — the orchestrator falls back to resolving models
and skills itself. **Hooks are still not installed by setup** (that decision is
unchanged) — wire `examples/claude-code/hooks/` yourself if you want the deterministic
gates.

> **Superseded by Phase 10b (below).** As of Phase 10b the Claude Code hooks **are**
> installed automatically (both scopes, no prompt). The "wire them yourself" note above
> is historical; re-run `setup.sh --agent claude-code` to land them. See the Phase 10b
> section.

### Optional Pi package stack (opt-in, consent-gated)

`setup.sh`/`setup.ps1 --agent pi` can now install a curated stack of Pi runtime
packages in addition to the skills + orchestrator. It is **opt-in**: an interactive
prompt asks first, and non-interactive runs choose with `--with-pi-packages` /
`--without-pi-packages`. With a **yes**, it installs, in order, at pinned versions:
`gentle-engram@0.1.10`, `pi-mcp-adapter@2.11.0`, then a one-time `pi-engram init`
(`npm exec --yes --package gentle-engram@0.1.10 -- pi-engram init`),
`pi-subagents-j0k3r@1.4.1`, `@juicesharp/rpiv-ask-user-question@2.0.0`,
`pi-web-access@0.13.0`, `@juicesharp/rpiv-todo@2.0.0`, and `pi-btw@0.4.1` — that is
**7 packages plus the init step**. Failures never abort setup: a missing `pi` on `PATH`
skips the whole step, an individual `pi install` failure warns and continues, and a
final summary reports what installed. Pins are hardcoded in the scripts (refresh with
`npm view <package> version`). See [docs/installation.md](installation.md#optional-pi-package-stack).

**`gentle-pi` is deliberately excluded** and never installed by the stack — it is a
rival, batteries-included Pi harness whose own orchestrator/skill wiring directly
conflicts with Kurama's Pi setup over the same orchestration surface.

**Action required**: none. The stack is opt-in; a plain `setup.sh --agent pi` still only
wires skills + the orchestrator unless you opt in. Requires `pi` on `PATH`; the packages
land in your Pi environment, not in this repo.

## Phase 10b — Project scope, always-on hooks, Pi agents, Engram, update/doctor

Phase 10b is the surface-completion pass: it adds a per-repo install scope, makes
the Claude Code hooks part of the default install, ships the native agents on Pi,
lets Engram be wired as the persistence engine, and adds `update.sh`/`doctor.sh`.
No skill counts change. Everything is additive except the hooks default (below).

### `--scope project` / `--path <repo>` (new install scope)

`setup.sh` (and `uninstall.sh`/`update.sh`/`doctor.sh`) gained `--scope
global|project` (default `global`, the unchanged behavior) and `--path <repo>`.
`--scope project` installs **everything into one git repo** — skills to
`<repo>/.claude/skills/` (or `<repo>/.pi/skills/`), native agents to
`<repo>/.claude/agents/` (or `<repo>/.pi/agents/`), the orchestrator merged into
the repo's `CLAUDE.md`/`AGENTS.md`, the Claude hooks into
`<repo>/.claude/hooks/kurama/` + `<repo>/.claude/settings.json`, and the install
receipt at the **repo root** — so you can trial Kurama in one project without
touching your global config, then remove it cleanly. `--path` applies only with
`--scope project`, defaults to the current directory, and is validated (must
exist, be a git repo, and never be the Kurama repo itself; a non-repo aborts in
non-interactive mode). `setup.ps1` mirrors this with `-Scope project -Path`.

**Action required**: none. Global scope is the default and byte-compatible with
prior installs; project scope is strictly opt-in via the new flags.

### Claude Code hooks are now installed by default (behavior change)

Through Phase 10a, `setup.sh --agent claude-code` did **not** install the hooks —
they were an explicit opt-in you wired yourself. **Phase 10b installs them
automatically**, in both scopes, with no prompt: the two scripts
(`orchestrator-write-guard.sh`, `archive-gate.sh`) are copied to the target's
`hooks/kurama/` directory and a `PreToolUse` block is merged into the matching
`settings.json` (`Edit|Write|MultiEdit` → write-guard; `Task|Skill` →
archive-gate). The merge is idempotent (removes prior kurama entries before
re-adding), prefers `jq` with a backup + atomic write, and prints guided manual
steps rather than `sed`-editing JSON when `jq` is absent. Every command string
contains `hooks/kurama/` so `uninstall.sh` strips exactly Kurama's entries.

**Action required**: re-run `setup.sh --agent claude-code` once to land the hooks
(your existing `settings.json` is backed up first, and only Kurama's block is
added). If you had previously wired `examples/claude-code/hooks/` by hand, the
idempotent merge de-duplicates rather than double-adding. To review what the
gates enforce, see [docs/hooks.md](hooks.md).

### Native Pi subagents installed automatically

`setup.sh --agent pi` now installs the **17 native agents** (the same roster as
Claude Code — 9 SDD phases + 8 review-layer agents) in **Pi's** format into
`~/.pi/agent/agents/` (global) or `<repo>/.pi/agents/` (project), recorded in the
receipt. Pi's format uses a YAML `tools` list of Pi tool names (`[read]` for the
read-only lenses/refuter/judges, `[read, bash]` for `jd-fix-agent`), a
`provider/model-id` `model` (`anthropic/claude-sonnet-4-5` lenses /
`anthropic/claude-opus-4-8` refuter+judges+fix+design+apply), and a lean body
that reads its Kurama skill via the `read` tool. See
[docs/sub-agents.md](sub-agents.md#native-pi-subagents-installed-automatically).

**Action required**: none. Re-run `setup.sh --agent pi` to land the agents
(existing same-named files are backed up first). Override models without editing
the files via `model_profiles` in `.pi/subagents.json` — Kurama never writes it.

### Engram optional persistence engine

`setup.sh` now asks **once** — `Use Engram as the persistence engine? [y/N]`, or
`--with-engram` / `--without-engram` (non-interactive default **no**). With yes it
ensures the `engram` binary (macOS/Homebrew offers `brew tap
Gentleman-Programming/homebrew-tap && brew install engram` with consent; otherwise
prints the releases guide and continues) and registers the Engram MCP server into
the client being configured, replicating gentle-ai's per-client shapes (`mcpServers`
for Claude/Cursor/Gemini, `mcp` for OpenCode, `servers` for VS Code, TOML
`[mcp_servers.engram]` for Codex; Pi gets it from the package stack). JSON edits go
through `jq` with a backup + atomic write and degrade to printed guidance when `jq`
is missing. With no, the harness keeps its built-in markdown persistence
(`openspec/` / `.kurama/`). All registrations are recorded in the receipt
(`engram_mcp[]`). See
[docs/installation.md](installation.md#engram-optional-persistence-engine).

**Action required**: none — Engram is opt-in. Existing projects keep the markdown
persistence unless you pass `--with-engram` (or answer yes).

### `update.sh` and `doctor.sh` (new maintenance scripts)

- **`update.sh`** re-syncs an existing install from the current repo checkout. It
  does **not** `git pull` (you pull first); it reads each receipt, re-runs the
  idempotent installer for that recorded target + scope, re-stamps the version,
  and reports which recorded files changed. Flags: `--agent`, `--scope`, `--path`,
  `--dry-run`. It never re-installs the Pi package stack.
- **`doctor.sh`** is a read-only health check: receipt + recorded files present
  (missing = fail) and matching the repo source (drift = warning), installed vs
  repo version, balanced orchestrator markers, Claude hooks present, recorded
  Engram MCP registrations, and environment tooling (`gh`/`pi`/`engram`). Green/red
  per item, non-zero exit on any hard failure. Flags: `--agent`, `--scope`,
  `--path`.

`uninstall.sh` also gained `--scope`/`--path` and a Pi-package revert offer
(`--with-pi-packages` / `--without-pi-packages`), and now strips the
`hooks/kurama/` block from `settings.json` surgically.

**Action required**: none — both new scripts are opt-in tooling. Note that
`update.sh`/`doctor.sh`/`uninstall.sh` are **bash-only**; the PowerShell parity gap
is unchanged.

## Detecting an old install/clone

- No `VERSION` file at the repo root → your clone predates Phase 2
  versioning.
- No `skills/manifest.json` → your clone predates manifest-driven install; the
  installers still work off the hardcoded skill list.
- No install manifest under your install target (see per-harness paths in
  [docs/installation.md](installation.md)) → `scripts/uninstall.sh` has
  nothing to work from until you re-run setup/install.
