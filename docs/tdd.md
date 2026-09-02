# TDD Module (optional)

Test-Driven Development in Kurama is an **optional module**. The module now
**installs by default** (remove it from disk with `install.sh --without tdd`), but activation
is **opt-in per project** — the cycle stays OFF until you explicitly enable it, and
nothing infers it from existing test files. When enabled for a project, it hooks
into three SDD phases — `sdd-tasks` plans the cycle, `sdd-apply` executes it, and
`sdd-verify` audits it — so RED → GREEN → REFACTOR is planned, run, and checked
together, or not at all. For quick start, see the [main README](../README.md).

**Installing the module is not activating it.** Shipping `skills/tdd/SKILL.md` on
disk only makes the cycle *available*; every project still opts in on its own
terms. The split is deliberate: **a project can start without tests and add them
later** — the module is there when you want it, inert until you flip the switch.
See [Enabling TDD later](#enabling-tdd-later) for the mid-stream path and
[Installation vs activation](#installation-vs-activation) for the on-disk side.

> **Work Unit Evidence is always on; this module stacks on top of it.** Independently of TDD
> and of `tdd.enabled`, `sdd-apply` must record a **Work Unit Evidence** block for every work
> unit before marking its tasks complete — the focused test/check command and its exact result,
> the harness/runtime it ran under (each `N/A` only ever with a stated reason), and the rollback
> boundary — and `sdd-verify` audits those blocks in every mode, at WARNING level and up to
> CRITICAL when a unit that touched code claims passing tests with no command. Enabling TDD
> never replaces that block: RED → GREEN → REFACTOR evidence and the scenario→test traceability
> audit are added on top of it, and their own findings stay WARNING-level. Disabling TDD removes
> the cycle, never the evidence.

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

The flag lives in the top-level `tdd:` block of `openspec/config.yaml`, written by
`sdd-init` — the same settings home as
[compliance_mode](persistence.md#where-pipeline-settings-are-configured).

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

## Enabling TDD later

TDD is a per-project switch you can flip at any time — a project that started
without it can adopt the cycle mid-stream. On an already-initialized project:

Edit `openspec/config.yaml`: set `tdd.enabled: true` and fill
`tdd.single_test_command` (the fast single-test invocation; leave empty to
auto-detect).

The **next cycle** picks up the resolved flag: `sdd-tasks` plans
RED → GREEN → REFACTOR subtasks, `sdd-apply` runs them, and `sdd-verify` audits
scenario→test traceability and RED evidence. Because the orchestrator reads the
flag once and propagates it into every phase, planning and execution always agree.

Make sure the module is on disk first. It installs by default, but if it was
excluded with `install.sh --without tdd`, reinstall before enabling — otherwise `sdd-init`
declines to record `enabled: true` and `sdd-tasks`/`sdd-apply`/`sdd-verify` degrade
gracefully with a WARNING (see [Installation vs activation](#installation-vs-activation)).

**Turning it back off** is the same switch in reverse: set `tdd.enabled: false`
(or answer "no" on a re-run of `/sdd-init`). The next cycle drops to the standard
checklist with no TDD behavior anywhere — existing tests are left untouched.

## The cycle

One behavior — a single spec scenario (Given/When/Then) — per cycle:

1. **RED** — write one failing test first, run only that test, and **capture the
   failing output**. RED evidence is mandatory. A test that passes on its first
   run is not RED.
2. **GREEN** — write the minimal code to make it pass; run the test; confirm green.
3. **TRIANGULATE** *(optional)* — when the behavior has a real edge/boundary (empty
   input, limit value, off-by-one, error path), add a second test for the **same**
   scenario before refactoring; if it exposes a gap, loop back to GREEN. Skip it when
   there is no meaningful boundary — it is never required and never renames the cycle.
4. **REFACTOR** — clean up under a green bar; re-run; confirm it stays green.

The full contract, the optional TRIANGULATE step, anti-patterns (disguised
test-after, RED that passes immediately, implementation-coupled tests, batch RED),
and the per-task evidence table (with its optional triangulation row) are in
[skills/tdd/SKILL.md](../skills/tdd/SKILL.md).

> **Companion compatibility:** `superpowers:test-driven-development` shares this RED → GREEN → REFACTOR cycle and is fully compatible — Kurama's module adds scenario→test traceability and audited RED evidence on top. Optional, never a hard dependency; see [docs/companion-skills.md](companion-skills.md).

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
as separate skills and reach sub-agents through the project's own
registry — the orchestrator injects the relevant rules into the phase prompt, so a
sub-agent gets, say, Go idioms without loading a whole skill file.

Kurama ships none of them, on purpose: a skill named after one ecosystem is a
privilege the other ecosystems never get. Write your own — `vitest-testing`,
`pytest-testing`, whatever your stack calls for — as a focused, language-scoped
patterns skill, and drop it anywhere the registry scans. The `tdd` core supplies
the cycle; your skill supplies the idioms, and the two meet in the phase prompt
without either one knowing about the other.

## Installation vs activation

Two independent things, easy to conflate:

- **Installing the module** puts `skills/tdd/SKILL.md` on disk. The `tdd` group in
  [skills/manifest.json](../skills/manifest.json) is now **installed by default** —
  `setup.sh` and `install.sh` both include it in the
  default set. Remove it with `setup.sh --without tdd` if you never want the module
  on disk — `setup.sh` owns `--with`/`--without` module selection, and `install.sh`
  forwards those flags to it. (No language-pattern plugin ships with Kurama; yours
  arrives through the project's `standards:` list instead of through a group flag.)
- **Activating TDD** turns the RED → GREEN → REFACTOR cycle on for a *specific
  project* via the explicit `tdd.enabled` flag above. Installing the module never
  activates it; the flag starts `false` everywhere, and existing test files never
  flip it on.

```bash
./scripts/setup.sh --without tdd     # exclude the module from disk
```

If you excluded the module earlier, reinstall **without** the flag to put it back —
the default install includes it. (`install.sh --without tdd` still works: it is a
compatibility wrapper that forwards the flag to `setup.sh`, the single installer.) Keeping install and
activation separate is what lets a project **start without tests and add them
later**: the module is always available on disk, and each project opts into the
cycle when it is ready (see [Enabling TDD later](#enabling-tdd-later)).
