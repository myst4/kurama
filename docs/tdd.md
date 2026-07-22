# TDD Module (optional)

Test-Driven Development in Agent Teams Lite is an **optional, opt-in module**. It
is OFF by default. When enabled for a project, it hooks into three SDD phases —
`sdd-tasks` plans the cycle, `sdd-apply` executes it, and `sdd-verify` audits it —
so RED → GREEN → REFACTOR is planned, run, and checked together, or not at all.
For quick start, see the [main README](../README.md).

The module core is language-agnostic. The RED → GREEN → REFACTOR protocol,
anti-patterns, and evidence format live in one place:
[skills/tdd/SKILL.md](../skills/tdd/SKILL.md). Per-runner commands live in
[skills/_shared/test-runners.md](../skills/_shared/test-runners.md).

## Activation — one switch, no silent heuristics

TDD activates ONLY through an explicit `tdd` flag. Existing test files in a
codebase do **not** turn it on, and installing the `tdd` skill does **not** turn it
on. A test-first-looking codebase triggers at most an interactive suggestion
during `sdd-init` ("codebase looks test-first — enable TDD?") and nothing more.
This removes the old opt-out trap where existing tests forced the whole cycle onto
test-after projects.

Where the flag lives is mode-dependent — the same settings-home rule as
[compliance_mode](persistence.md#where-pipeline-settings-are-configured):

| Mode | Where the `tdd` flag lives |
|------|-----------------------------|
| `openspec` / `hybrid` | The top-level `tdd:` block in `openspec/config.yaml`, written by `sdd-init`. |
| `engram` / `none` | The `tdd` flag in the `sdd-init/{project}` context artifact (there is no `config.yaml` in these modes). |

The orchestrator reads the flag once and propagates `tdd: true|false` into **every**
phase prompt. On conflict — a stale file value vs. a freshly propagated prompt
value — **the propagated value wins**, exactly as `compliance_mode` behaves.

The `tdd:` block holds only two keys. The full-suite `test_command`,
`build_command`, and `coverage_threshold` stay under `rules.verify` because they
are needed with TDD off too — the `tdd:` block never absorbs them:

```yaml
# openspec/config.yaml (top-level, sibling of `rules:`)
tdd:
  enabled: false
  single_test_command: ""   # how to run ONE test; "" → auto-detect (see test-runners.md)

rules:
  verify:
    test_command: "npm test"        # full suite — used by sdd-verify, unchanged by TDD
    build_command: "npm run build"
    coverage_threshold: 0
    compliance_mode: behavioral
```

`single_test_command` is the TDD-specific one: the fast way to run a single test,
which is what keeps the RED cycle tight. Leave it empty to auto-detect from
[test-runners.md](../skills/_shared/test-runners.md).

## The cycle

One behavior — a single spec scenario (Given/When/Then) — per cycle:

1. **RED** — write one failing test first, run only that test, and **capture the
   failing output**. RED evidence is mandatory. A test that passes on its first
   run is not RED.
2. **GREEN** — write the minimal code to make it pass; run the test; confirm green.
3. **REFACTOR** — clean up under a green bar; re-run; confirm it stays green.

The full contract, anti-patterns (disguised test-after, RED that passes
immediately, implementation-coupled tests, batch RED), and the per-task evidence
table are in [skills/tdd/SKILL.md](../skills/tdd/SKILL.md).

## What each phase does when TDD is on

| Phase | Behavior with `tdd: true` |
|-------|----------------------------|
| `sdd-tasks` | Expands each behavior task into subtasks `n.x RED` (failing test for scenario `S-{id}`), `n.y GREEN` (minimal implementation), `n.z REFACTOR` — each referencing the spec scenario ID. |
| `sdd-apply` | Follows the RED → GREEN → REFACTOR cycle from `skills/tdd/SKILL.md`, running single tests via `test-runners.md`, and records the per-task RED/GREEN/REFACTOR evidence table. |
| `sdd-verify` | Adds two audits (see below). |

Because `sdd-tasks` and `sdd-apply` read the SAME resolved flag, the RED subtask
that gets planned is the one that gets executed — traceability is guaranteed.

## What `sdd-verify` audits (TDD on)

With the flag active, `sdd-verify` adds two checks on top of its normal
compliance matrix:

1. **Scenario → test traceability** — every MUST scenario has an associated test.
2. **RED evidence present** — the apply report carries captured failing-test
   output per task.

The absence of either is reported as a **WARNING labeled "test-after detected" —
never CRITICAL**. The module is optional but honest: it surfaces test-after work
without blocking the cycle. These two checks are independent of `compliance_mode`
(which separately governs whether an UNTESTED MUST scenario is CRITICAL or
WARNING — see [persistence.md](persistence.md)).

## Per-language plugins

The TDD core never depends on a language. Language-specific test *patterns* ship
as separate skills and reach sub-agents as compact rules through the skill
registry — the orchestrator injects the relevant rules into the phase prompt, so a
sub-agent gets, say, Go idioms without loading a whole skill file.

[go-testing](../skills/go-testing/SKILL.md) is the reference example: table-driven
tests, golden files, `t.TempDir()`, and TUI/teatest patterns for Go. Future
plugins (e.g. `vitest-testing`, `pytest-testing`) follow the same shape — a
focused, language-scoped patterns skill in the optional install group, discovered
and compacted by the registry. The `tdd` core provides the cycle; the plugin
provides the language's idioms.

## Installation

The `tdd` skill installs via the opt-in `tdd` group in
[skills/manifest.json](../skills/manifest.json) (the language-pattern plugins like
`go-testing` live in the `optional` group). Enable it with the `install.sh` /
`install.ps1` group flag:

```bash
./scripts/install.sh --with tdd        # bash / macOS / Linux / WSL / Git Bash
```

```powershell
.\scripts\install.ps1 -With tdd        # Windows PowerShell
```

The `setup.sh`/`setup.ps1` scripts install the default set (TDD excluded) and have
no `--with` flag — use `install.sh --with tdd` / `install.ps1 -With tdd` to add the
module. Leave it out to keep the core SDD pipeline without the TDD module.
Installing the skill does not activate TDD for any project — activation is always
the explicit `tdd` flag above.
