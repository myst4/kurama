---
name: tdd
description: >
  Language-agnostic Test-Driven Development module: the RED → GREEN → REFACTOR
  contract, anti-patterns, and the per-task evidence format for the apply report.
  Trigger: When a phase resolves TDD as active (tdd flag true) and needs the cycle
  contract — loaded by sdd-apply to implement, and referenced by sdd-tasks and sdd-verify.
license: MIT
metadata:
  author: gentleman-programming
  version: "1.0"
---

## What This Module Is

The canonical, language-agnostic core of the optional TDD module. It owns ONE
copy of the RED → GREEN → REFACTOR protocol, the anti-patterns, and the per-task
evidence format. `sdd-apply`, `sdd-tasks`, and `sdd-verify` point here instead of
carrying their own copies, so the cycle never drifts across phases.

This module is opt-in and OFF by default. It only governs a change when TDD is
resolved active (see **Activation** below). Per-runner commands live in
`skills/_shared/test-runners.md`; per-language test *patterns* (e.g.
`go-testing`) reach sub-agents as compact rules through the skill registry — this
core never depends on a specific language.

## Activation (single switch — zero silent heuristics)

TDD activates ONLY through an explicit `tdd` flag. There is NO heuristic that
turns it on: existing test files in a codebase are NOT an activation signal, and
the mere presence of this `tdd/SKILL.md` on disk is NOT an activation signal
either. (Historically `sdd-apply` listed "tdd/SKILL.md exists" as a detection
trigger for a file the framework never shipped — this module ships the file AND
removes that behavior: installation ≠ activation.)

**Resolution precedence (highest to lowest):**

1. The `tdd: true|false` flag the orchestrator propagates in the phase launch
   prompt. This is the already-resolved value and WINS over any value a phase
   reads on its own — the same rule that governs `compliance_mode`.
2. The explicit project setting the orchestrator resolves it from:
   - `openspec` / `hybrid`: the top-level `tdd:` block in `openspec/config.yaml`
     (`tdd.enabled`).
   - `engram` / `none`: the `tdd` flag in the `sdd-init/{project}` context
     artifact (there is no `config.yaml` in these modes).
3. An interactive suggestion during `sdd-init` ONLY — e.g. "codebase looks
   test-first — enable TDD?". A test-first-looking codebase may trigger this
   suggestion and NOTHING more; it never auto-activates.
4. Default: **disabled** (standard workflow — write code, then verify).

The `tdd:` config block holds ONLY these two keys. The full-suite `test_command`,
`build_command`, and `coverage_threshold` stay under `rules.verify` (they are
needed with TDD off too) — the `tdd:` block never absorbs them:

```yaml
# openspec/config.yaml (top-level, sibling of `rules:`)
tdd:
  enabled: false
  single_test_command: ""   # how to run ONE test (see test-runners.md); "" → detect
```

Because `sdd-tasks` and `sdd-apply` read the SAME resolved flag, a RED subtask
planned in `tasks.md` is always the one `apply` executes — traceability holds.

## The Cycle Contract

One behavior per cycle. A "behavior" is a single spec scenario (Given/When/Then).
Do NOT batch multiple scenarios into one cycle.

```
FOR EACH behavior (spec scenario S-{requirement-slug}-{n}, e.g. S-auth-1):

  1. RED — write ONE failing test first
     ├── Encode the scenario's expected behavior as a test (not the implementation shape).
     ├── Run ONLY that test/suite (test-runners.md → single-test command) — for speed.
     ├── Confirm it FAILS for the RIGHT reason (assertion/missing behavior, not a
     │   compile error or typo).
     └── CAPTURE the failing output. RED evidence is MANDATORY. A test that passes
         on its first run is NOT RED — the behavior already exists or the test is
         wrong; fix the test, do not proceed.

  2. GREEN — minimal implementation
     ├── Write the LEAST code that makes the failing test pass.
     ├── Run the same test — confirm it PASSES.
     └── Do NOT add functionality the test does not demand ("you aren't gonna need it").

  3. REFACTOR — clean up under a green bar
     ├── Improve naming, structure, duplication; match project conventions.
     ├── Re-run the test(s) — confirm they STILL PASS after every change.
     └── REFACTOR only with green tests. If tests are red, you are debugging, not
         refactoring — go back to GREEN.
```

Never skip RED. Never write implementation before a failing test exists for the
behavior it satisfies.

## Anti-Patterns (reject these)

| Anti-pattern | Why it fails | Correct form |
|--------------|--------------|--------------|
| **Disguised test-after** | Writing the code, then a test that passes on first run and labeling it RED. There is no failing-output evidence. | Write the test first; capture the genuine failure before any implementation. |
| **RED that passes immediately** | The "failing" test never failed — it proves nothing about the new behavior. | If it passes on first run, the behavior exists or the test is wrong. Fix the test; do not proceed. |
| **Implementation-coupled tests** | Tests asserting internal calls, private structure, or exact code shape break on every refactor and lock in the implementation. | Assert observable behavior from the scenario's Then — inputs/outputs, effects, contracts. |
| **Batch RED** | Writing all tests upfront, then all code, collapses the cycle into test-first-once and loses the per-behavior feedback and minimal-GREEN discipline. | One scenario per cycle: RED → GREEN → REFACTOR, then the next scenario. |

## Per-Task Evidence Format (canonical)

This is the ONE canonical shape for TDD evidence in the apply report. `sdd-apply`
populates it (it moved here from that skill's Step 6); `sdd-verify` audits it.
Include one row per task, each referencing its spec scenario ID:

```markdown
### Tests (TDD)

| Task | Scenario | Test File | RED (failing output captured) | GREEN (passing) | REFACTOR |
|------|----------|-----------|-------------------------------|-----------------|----------|
| 2.1 | S-auth-1 | `path/to/x_test.ext` | ✅ asserted-fail before impl | ✅ pass | ✅ no behavior change |
| 2.2 | S-auth-2 | `path/to/y_test.ext` | ✅ asserted-fail before impl | ✅ pass | ➖ none needed |
```

RED evidence is the load-bearing column: a row without captured failing output is
test-after, not TDD, and `sdd-verify` flags it as a WARNING ("test-after
detected") — never CRITICAL, because the module is opt-in and honest, not
punitive.

## Running Tests

- Resolve commands via `skills/_shared/test-runners.md` — the ONE runner table.
- During the cycle, run ONLY the relevant single test/suite (the table's
  single-test column), never the whole suite — RED speed is what keeps the cycle
  tight.
- `tdd.single_test_command` (config/context), when set, overrides the detected
  single-test default; the full-suite `rules.verify.test_command` is for
  `sdd-verify`, not for per-cycle RED.

## Rules

- TDD is active ONLY when the resolved `tdd` flag is true — never infer it from
  existing tests or from this file being installed.
- One scenario per cycle; RED before any implementation; GREEN minimal; REFACTOR
  only under green.
- RED evidence (captured failing output) is mandatory per task — it is the proof
  the test is meaningful.
- Assert behavior from the spec scenario, not implementation internals.
- Reference the spec scenario ID (`S-{requirement-slug}-{n}`, e.g. `S-auth-1`, the
  canonical form `sdd-spec` assigns) in every RED subtask and every evidence row —
  this is the scenario → test traceability `sdd-verify` audits.
- Per-language patterns come from the skill registry (compact rules), not from
  this core — keep this module language-agnostic.
