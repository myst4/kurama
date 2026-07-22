# Migration Guide

Guidance for existing installations and projects moving through the ongoing
stabilization work (Phases 1-4). For what changed and when, see
[docs/changelog.md](changelog.md). For the persistence contract itself, see
[docs/persistence.md](persistence.md).

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

### `.atl/sdd/` fallback store (new)

`.atl/` — already used for `.atl/skill-registry.md` — gains a second role:
`.atl/sdd/{change-name}/` is the filesystem fallback for SDD artifacts when
Engram is unreachable at the start of a cycle (the orchestrator checks with
one cheap Engram call and degrades the whole cycle to this fallback, with a
warning), or when a single `mem_save` fails mid-cycle in `engram` mode (one
retry, then a fallback file written under this path, reported as a concern in
the phase's return envelope).

No action required — this only activates when Engram is unavailable or fails;
it never contends with `openspec`/`hybrid` project files.

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
`single_test_command` (string). In `engram`/`none` mode the same two keys
live in the `sdd-init/{project}` context artifact instead of a config file.
See [skills/tdd/SKILL.md](../skills/tdd/SKILL.md) and
[docs/tdd.md](tdd.md) for the full cycle contract and activation precedence.

**Action required**: none. TDD activates ONLY when `tdd.enabled` is
explicitly set `true` — existing test files in a project are never an
activation signal, and installing `skills/tdd` on disk does not activate it
either. Projects that don't set the flag are unaffected.

### `tdd` skill group (opt-in, not installed by default)

`skills/manifest.json` gained a `tdd` group (`default: false`) holding
`skills/tdd`. Install it explicitly with the group flag on the `install.sh` /
`install.ps1` installers:

```bash
./scripts/install.sh --with tdd        # bash / macOS / Linux / WSL / Git Bash
```

```powershell
.\scripts\install.ps1 -With tdd        # Windows PowerShell
```

The module stays excluded from a default install alongside the always-on
`sdd-core` and the default-on `quality`/`optional` groups. `setup.sh`/`setup.ps1`
install the **default set** (the 18 default-on skills, TDD excluded); there is no
`--with` flag on the `setup` scripts — use `install.sh --with tdd` /
`install.ps1 -With tdd` to add the module.

**Action required**: run `install.sh --with tdd` / `install.ps1 -With tdd` if you
want the module on disk; otherwise no action is needed.

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
  ATL as a Claude Code plugin (`/plugin marketplace add ...`) instead of
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
is active (delegation must still happen; `.atl/` and `openspec/` artifact
paths are exempt), and an archive gate that mechanically refuses
`sdd-archive` when the persisted state lacks a verify `PASS` — mirroring
`sdd-archive`'s own Step 0 check, but enforced deterministically instead of
by prose alone. See docs/hooks.md for the rationale.

**Action required**: none — hooks are opt-in and not installed by default;
copy `examples/claude-code/hooks/` yourself if you want the gates enforced
mechanically.

## Detecting an old install/clone

- No `VERSION` file at the repo root → your clone predates Phase 2
  versioning.
- No `skills/manifest.json` → your clone predates manifest-driven install; the
  installers still work off the hardcoded skill list.
- No install manifest under your install target (see per-harness paths in
  [docs/installation.md](installation.md)) → `scripts/uninstall.sh` has
  nothing to work from until you re-run setup/install.
