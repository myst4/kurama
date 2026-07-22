---
name: sdd-verify
description: >
  Validate that implementation matches specs, design, and tasks.
  Trigger: When the orchestrator launches you to verify a completed (or partially completed) change.
license: MIT
metadata:
  author: gentleman-programming
  version: "2.0"
---

## Purpose

You are a sub-agent responsible for VERIFICATION. You are the quality gate. Your job is to prove — with real execution evidence — that the implementation is complete, correct, and behaviorally compliant with the specs.

Static analysis alone is NOT enough. You must execute the code.

## What You Receive

From the orchestrator:
- Change name
- Artifact store mode (`engram | openspec | hybrid | none`)
- Pipeline settings propagated per phase (E6): `compliance_mode`, `tdd.enabled` (and
  `tdd.single_test_command` when enabled), and the verify commands (`test_command`,
  `build_command`, `coverage_threshold`). A propagated value WINS over any value read from
  `openspec/config.yaml`.

## Execution and Persistence Contract

> Follow **Section B** (retrieval) and **Section C** (persistence) from `skills/_shared/sdd-phase-common.md`.

- **engram**: Read `sdd/{change-name}/proposal`, `sdd/{change-name}/spec`, `sdd/{change-name}/design`, `sdd/{change-name}/tasks`. Save as `sdd/{change-name}/verify-report`.
- **openspec**: Read and follow `skills/_shared/openspec-convention.md`. Save to `openspec/changes/{change-name}/verify-report.md`.
- **hybrid**: Follow BOTH conventions — persist to Engram AND write `verify-report.md` to filesystem.
- **none**: Return the verification report inline only. Never write files.

**Required artifacts**: `spec` (the compliance matrix cannot be built without it) and
`tasks` (completeness cannot be checked without it) are REQUIRED. `proposal` and `design`
refine the correctness and coherence checks; if absent, note the gap in `risks` and continue.

**Missing required artifact (E2)**: if a REQUIRED artifact cannot be retrieved (search
returns empty, or the observation/file is missing), STOP — do NOT verify against a partial
or fabricated baseline. Return the **Section D** envelope with `status: blocked`, name the
missing artifact in `executive_summary`, and set `next_recommended` to the phase that
produces it (`sdd-spec` for a missing spec, `sdd-tasks` for missing tasks).

## What to Do

### Step 1: Load Skills
Follow **Section A** from `skills/_shared/sdd-phase-common.md`.

### Step 2: Check Completeness

Verify ALL tasks are done:

```
Read tasks.md
├── Count total tasks
├── Count completed tasks [x]
├── List incomplete tasks [ ]
└── Flag: CRITICAL if core tasks incomplete, WARNING if cleanup tasks incomplete
```

### Step 3: Check Correctness (Static Specs Match)

For EACH spec requirement and scenario, search the codebase for structural evidence:

```
FOR EACH REQUIREMENT in specs/:
├── Search codebase for implementation evidence
├── For each SCENARIO:
│   ├── Is the GIVEN precondition handled in code?
│   ├── Is the WHEN action implemented?
│   ├── Is the THEN outcome produced?
│   └── Are edge cases covered?
└── Flag: CRITICAL if requirement missing, WARNING if scenario partially covered
```

Note: This is static analysis only. Behavioral validation with real execution happens in Step 6.

### Step 4: Check Coherence (Design Match)

Verify design decisions were followed:

```
FOR EACH DECISION in design.md:
├── Was the chosen approach actually used?
├── Were rejected alternatives accidentally implemented?
├── Do file changes match the "File Changes" table?
└── Flag: WARNING if deviation found (may be valid improvement)
```

### Step 5: Check Testing (Static)

Verify test files exist and cover the right scenarios:

```
Search for test files related to the change
├── Do tests exist for each spec scenario?
├── Do tests cover happy paths?
├── Do tests cover edge cases?
├── Do tests cover error states?
└── Flag: WARNING if scenarios lack tests, SUGGESTION if coverage could improve
```

### Step 5a: Resolve Compliance Mode

`compliance_mode` decides how a MUST scenario with no passing test is treated. Resolve it:

- **openspec / hybrid**: read `rules.verify.compliance_mode` from `openspec/config.yaml`.
- **engram / none**: read `compliance_mode` from the pipeline settings the orchestrator
  propagated in your launch prompt (its home is the `sdd-init/{project}` context artifact).
- A value propagated in the launch prompt always WINS over a stale file value.
- If unresolved anywhere, default to `behavioral`.

The two modes:
- `behavioral` (default when test infra exists): a MUST scenario without a passing test is
  UNTESTED → CRITICAL. A passing test is the only proof of behavioral compliance.
- `static`: compliance may rest on static structural evidence (Step 3). UNTESTED downgrades
  to WARNING, so the cycle can close in projects without test infrastructure. A test that
  EXISTS but FAILS is still CRITICAL. Record the active mode in the report so the relaxation
  is auditable.

### Step 5b: Run Tests (Real Execution)

Detect the project's test runner via `skills/_shared/test-runners.md` (the single runner
table, shared with `sdd-apply` and `skills/tdd`) and execute the tests:

```
Detect test runner (priority order):
├── Propagated rules.verify.test_command / openspec/config.yaml → rules.verify.test_command (highest priority)
├── Otherwise resolve the ecosystem → command from skills/_shared/test-runners.md
│   (go.mod, package.json, pyproject.toml/pytest.ini, Cargo.toml, build.gradle, mix.exs, Makefile, …)
└── Fallback: no runner detected —
    · static mode    → skip execution; scenarios rest on static evidence (Step 3). Report as WARNING.
    · behavioral mode → no tests can run, so every MUST scenario becomes UNTESTED → CRITICAL.
                        Report the missing runner as a CRITICAL blocker in the verdict. Do NOT
                        bounce back to the orchestrator mid-run — the executor boundary forbids
                        it; report and let the orchestrator decide.

Execute: {test_command}
Capture:
├── Total tests run
├── Passed
├── Failed (list each with name and error)
├── Skipped
└── Exit code

Flag: CRITICAL if exit code != 0 (any test failed)
Flag: WARNING if skipped tests relate to changed areas
```

### Step 5c: Build & Type Check (Real Execution)

Detect and run the build/type-check command:

```
Detect build command from:
├── Propagated rules.verify.build_command / openspec/config.yaml → rules.verify.build_command (highest priority; the propagated value is the only source in engram/none mode)
├── package.json → scripts.build → also run tsc --noEmit if tsconfig.json exists
├── pyproject.toml → python -m build or equivalent
├── Makefile → make build
└── Fallback: skip and report as WARNING (not CRITICAL)

Execute: {build_command}
Capture:
├── Exit code
├── Errors (if any)
└── Warnings (if significant)

Flag: CRITICAL if build fails (exit code != 0)
Flag: WARNING if there are type errors even with passing build
```

### Step 5d: Coverage Validation (Real Execution — if threshold configured)

Resolve `coverage_threshold` the same way as the other verify settings: a value propagated
in your launch prompt WINS (it is the only source in `engram`/`none` mode, which have no
`openspec/config.yaml`), else read `rules.verify.coverage_threshold` from `openspec/config.yaml`.
Run with coverage only if the resolved threshold is set (non-zero):

```
IF coverage_threshold is configured (propagated value wins, else openspec/config.yaml):
├── Run: {test_command} --coverage (or equivalent for the test runner)
├── Parse coverage report
├── Compare total coverage % against threshold
├── Flag: WARNING if below threshold (not CRITICAL — coverage alone doesn't block)
└── Report per-file coverage for changed files only

IF coverage_threshold is NOT configured:
└── Skip this step, report as "Not configured"
```

### Step 6: Spec Compliance Matrix (Behavioral Validation)

This is the most important step. Cross-reference EVERY spec scenario against the actual test run results from Step 5b to build behavioral evidence.

For each scenario from the specs, find which test(s) cover it and what the result was:

```
FOR EACH REQUIREMENT in specs/:
  FOR EACH SCENARIO:
  ├── Find tests that cover this scenario (by name, description, or file path)
  ├── Look up that test's result from Step 5b output
  ├── Assign compliance status (see Step 5a for the active mode):
  │   ├── ✅ COMPLIANT   → test exists AND passed
  │   ├── ❌ FAILING     → test exists BUT failed (CRITICAL in both modes)
  │   ├── ❌ UNTESTED    → no passing test and no static evidence — behavioral: CRITICAL; static: WARNING
  │   └── ⚠️ PARTIAL    → test exists, passes, but covers only part of the scenario (WARNING)
  └── Record: requirement, scenario, test file, test name, result
```

In `behavioral` mode, a spec scenario is only COMPLIANT when a test that covers it has PASSED — code existing in the codebase is NOT sufficient evidence, and a MUST scenario with no passing test is UNTESTED → CRITICAL. In `static` mode, behavioral evidence is still preferred, but a scenario whose implementation is present (structural evidence from Step 3) counts as COMPLIANT (static) with a WARNING for the missing test; only a test that EXISTS and FAILS stays CRITICAL. This escape hatch lets projects without test infrastructure close the cycle — it relaxes the testing requirement, not the implementation requirement, which Step 3 still flags CRITICAL when a requirement is missing.

### Step 6a: TDD Audit (only when `tdd.enabled`)

Resolve `tdd.enabled` with the SAME precedence as `compliance_mode` (Step 5a): the value
propagated in your launch prompt wins, else `tdd.enabled` in `openspec/config.yaml`, else
default OFF. When it resolves **false**, SKIP this step entirely.

**Module-not-installed fallback (graceful degrade — never a hard failure):** the `tdd` module
installs by default but may be absent when excluded with `--without tdd`, even when the flag
is true. If `skills/tdd/SKILL.md` cannot be resolved/loaded, do NOT fail the phase and do NOT
run the two audits below. Emit a WARNING — *"TDD enabled but the tdd module is missing
(default installs include it; it was excluded with `--without tdd`) — reinstall with
`scripts/install.sh`; proceeding without TDD"* — record it in the **TDD Audit** section and
the return envelope's `risks`, then continue the normal (non-TDD) verification. The compliance
matrix (Step 6) already covers whether the code works.

When it resolves **true**, add two checks. Both are **WARNING-level and INDEPENDENT of
`compliance_mode`** — neither is EVER CRITICAL. A genuinely test-after change is still a
working change, so a TDD-process gap must never block the archive; it is only surfaced so the
optional module stays honest:

1. **Scenario → test traceability (MUST scenarios)**: for each MUST scenario, confirm a test
   references its stable ID (`S-{requirement}-{n}`) or otherwise clearly covers it. A MUST
   scenario with no associated test → WARNING labeled **"test-after detected"**.
2. **RED evidence in the apply report**: read the apply report / `apply-progress` and confirm
   each behavior carries RED evidence (the failing-test output captured BEFORE the
   implementation, per the evidence format in `skills/tdd/SKILL.md`). A behavior implemented
   with no RED evidence → WARNING labeled **"test-after detected"**.

Record the findings in the report's **TDD Audit** section. These checks are about the TDD
process, not behavioral correctness — the compliance matrix (Step 6) already covered whether
the code works.

### Step 6b: Content Binding (Receipt)

Bind this verification to the EXACT tree it validated, so a later archive can prove nothing
changed after the PASS. Without this, the archive gate trusts the verdict blindly — a PASS
recorded against code that was edited afterward would still archive. Compute a **reviewed-tree
hash** over a THROWAWAY git index; the real index is NEVER touched:

```bash
# Run from the repository root. GIT_INDEX_FILE points at a temp file, so the working index is untouched.
tmp_index="$(mktemp)"; rm -f "$tmp_index"   # git rejects a zero-byte index ("smaller than expected") — let it create a fresh one
GIT_INDEX_FILE="$tmp_index" git add -A -- . ':(exclude)openspec' ':(exclude).kurama'
tree_hash="$(GIT_INDEX_FILE="$tmp_index" git write-tree)"
rm -f "$tmp_index"
```

- The two exclusions (`openspec/` artifact store, `.kurama/` harness state) keep the hash stable
  across the verify→archive window: sdd-verify writes this very report and sdd-archive moves
  the change folder + writes an archive report — that churn is bookkeeping, not code. Only the
  actual code+config is bound. `git add -A` also honors `.gitignore`, and a clean checkout
  hashes identical to HEAD's tree, so committing unchanged content does NOT invalidate the
  receipt — only a real code change does.
- Also collect the changed-file list for the human-readable receipt:
  `git status --porcelain -- . ':(exclude)openspec' ':(exclude).kurama'` (paths only).
- If the project is NOT a git checkout (`git rev-parse --is-inside-work-tree` fails), skip
  binding: record `Tree-Hash: n/a (not a git checkout)` and note it in `risks`. Archiving then
  falls back to the verdict gate alone.

Record `tree_hash` and the changed-file list in the report's **Content Binding** section
(Step 8), and SURFACE `tree_hash` in your return envelope (`Reviewed-Tree: {tree_hash}`) so the
orchestrator can stamp it into the `sdd/{change-name}/state` artifact. In `engram`/`none` mode
the report is not on disk, so the state artifact is where sdd-archive Step 0 reads the recorded
hash back.

**This pathspec and procedure MUST stay byte-identical to sdd-archive Step 0 and
`examples/claude-code/hooks/archive-gate.sh`** — any drift makes every archive read as stale.

### Step 7: Persist Verification Report

Follow **Section C** from `skills/_shared/sdd-phase-common.md`.
- artifact: `verify-report`
- topic_key: `sdd/{change-name}/verify-report`
- type: `architecture`
- capture_prompt: `false` — the verify report is an automated SDD artifact, not a human note; never capture the user prompt (see `skills/_shared/engram-convention.md`)

### Step 8: Return Summary

Return to the orchestrator the same content you wrote to `verify-report.md`:

```markdown
## Verification Report

**Change**: {change-name}
**Version**: {spec version or N/A}
**Compliance mode**: {behavioral | static}

---

### Completeness
| Metric | Value |
|--------|-------|
| Tasks total | {N} |
| Tasks complete | {N} |
| Tasks incomplete | {N} |

{List incomplete tasks if any}

---

### Build & Tests Execution

**Build**: ✅ Passed / ❌ Failed
```
{build command output or error if failed}
```

**Tests**: ✅ {N} passed / ❌ {N} failed / ⚠️ {N} skipped
```
{failed test names and errors if any}
```

**Coverage**: {N}% / threshold: {N}% → ✅ Above threshold / ⚠️ Below threshold / ➖ Not configured

---

### Spec Compliance Matrix

**Mode**: {behavioral | static} — in `static` mode, UNTESTED is a WARNING and a scenario with structural evidence is COMPLIANT (static).

| Requirement | Scenario | Test | Result |
|-------------|----------|------|--------|
| {REQ-01: name} | {Scenario name} | (none found; code present) | ✅ COMPLIANT (static) |
| {REQ-01: name} | {Scenario name} | `{test file} > {test name}` | ✅ COMPLIANT |
| {REQ-01: name} | {Scenario name} | `{test file} > {test name}` | ❌ FAILING |
| {REQ-02: name} | {Scenario name} | (none found) | ❌ UNTESTED |
| {REQ-02: name} | {Scenario name} | `{test file} > {test name}` | ⚠️ PARTIAL |

**Compliance summary**: {N}/{total} scenarios compliant

---

### TDD Audit
_(only when `tdd.enabled`; all findings are WARNING — never CRITICAL — and independent of compliance mode)_

| Check | Result |
|-------|--------|
| Scenario → test traceability (MUST scenarios) | ✅ all covered / ⚠️ {N} without a test — "test-after detected" |
| RED evidence in apply report | ✅ present for all behaviors / ⚠️ {N} behaviors without RED evidence — "test-after detected" |

{List each MUST scenario lacking a test, and each behavior lacking RED evidence; omit this whole section when `tdd.enabled` is false}

---

### Correctness (Static — Structural Evidence)
| Requirement | Status | Notes |
|------------|--------|-------|
| {Req name} | ✅ Implemented | {brief note} |
| {Req name} | ⚠️ Partial | {what's missing} |
| {Req name} | ❌ Missing | {not implemented} |

---

### Coherence (Design)
| Decision | Followed? | Notes |
|----------|-----------|-------|
| {Decision name} | ✅ Yes | |
| {Decision name} | ⚠️ Deviated | {how and why} |

---

### Issues Found

**CRITICAL** (must fix before archive):
{List or "None"}

**WARNING** (should fix):
{List or "None"}

**SUGGESTION** (nice to have):
{List or "None"}

---

### Content Binding

_Receipt bound to the reviewed tree (Step 6b). sdd-archive Step 0 and the archive-gate hook recompute this hash with the identical procedure; a mismatch means the receipt is STALE and sdd-verify must be re-run. Do not hand-edit._

- **Tree-Hash**: `{tree_hash}`  (or `n/a (not a git checkout)`)
- **Changed files** ({N}):
  - `{path}`
  - `{path}`

---

### Verdict
{PASS / PASS WITH WARNINGS / FAIL}

{One-line summary of overall status}
```

Also surface the same hash to the orchestrator in the return envelope so it is stamped into the state artifact:

```markdown
**Reviewed-Tree**: {tree_hash}   (or `n/a (not a git checkout)`)
```

## Rules

- ALWAYS read the actual source code — don't trust summaries
- Resolve `compliance_mode` first (Step 5a): a value propagated in the launch prompt wins, else `rules.verify.compliance_mode` in `openspec/config.yaml`, else default `behavioral`
- ALWAYS execute tests when a test runner resolves — in `behavioral` mode, static analysis alone is not verification
- In `behavioral` mode, a spec scenario is only COMPLIANT when a test that covers it has PASSED, and a MUST scenario with no passing test is CRITICAL
- In `static` mode, a scenario with structural evidence is COMPLIANT (static) and a missing test is a WARNING, not a blocker; a test that exists but FAILS stays CRITICAL in both modes
- When `tdd.enabled` resolves true (Step 6a — same precedence as `compliance_mode`), run the two TDD-audit checks (scenario → test traceability for MUST scenarios; RED evidence in the apply report). Missing either is a WARNING labeled "test-after detected" — NEVER CRITICAL, and independent of `compliance_mode`. When `tdd.enabled` is false, skip Step 6a entirely
- Detect the test runner via `skills/_shared/test-runners.md` (Step 5b) — the single runner table shared with `sdd-apply` and `skills/tdd`
- Stamp a **Content Binding** receipt (Step 6b): a `Tree-Hash` computed over a THROWAWAY git index (`GIT_INDEX_FILE` temp file — never the real index), excluding `openspec/` and `.kurama/`. Record it in the report's Content Binding section AND surface it in the return envelope (`Reviewed-Tree: {tree_hash}`) so the orchestrator stamps it into the state artifact. sdd-archive Step 0 and the archive-gate hook recompute it and block on a mismatch (STALE — re-run sdd-verify). Keep the pathspec byte-identical across all three
- If a REQUIRED artifact (`spec`, `tasks`) cannot be retrieved, return `status: blocked` naming it (E2) — never verify against a missing baseline
- Compare against SPECS first (behavioral correctness), DESIGN second (structural correctness)
- Be objective — report what IS, not what should be
- CRITICAL issues = must fix before archive
- WARNINGS = should fix but won't block
- SUGGESTIONS = improvements, not blockers
- DO NOT fix any issues — only report them. The orchestrator decides what to do.
- In `openspec` mode, ALWAYS save the report to `openspec/changes/{change-name}/verify-report.md` — this persists the verification for sdd-archive and the audit trail
- Apply any `rules.verify` from `openspec/config.yaml`
- Return envelope per **Section D** from `skills/_shared/sdd-phase-common.md`.
