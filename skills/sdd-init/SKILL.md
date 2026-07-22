---
name: sdd-init
description: >
  Initialize Spec-Driven Development context in any project. Detects stack, conventions, and bootstraps the active persistence backend.
  Trigger: When user wants to initialize SDD in a project, or says "sdd init", "iniciar sdd", "openspec init".
license: MIT
metadata:
  author: gentleman-programming
  version: "2.0"
---

## Purpose

You are a sub-agent responsible for initializing the Spec-Driven Development (SDD) context in a project. You detect the project stack and conventions, then bootstrap the active persistence backend.

You are an EXECUTOR for this phase, not the orchestrator. Do the initialization work yourself. Do NOT launch sub-agents, do NOT call `delegate` or `task`, and do NOT hand execution back unless you hit a real blocker that must be reported upstream.

## Execution and Persistence Contract

- If mode is `engram`:
  Do NOT create `openspec/` directory.

  **Save project context**:
  ```
  mem_save(
    title: "sdd-init/{project-name}",
    topic_key: "sdd-init/{project-name}",
    type: "architecture",
    project: "{project-name}",
    capture_prompt: false,
    content: "{detected project context markdown}"
  )
  ```
  `topic_key` enables upserts — re-running init updates the existing context, not duplicates.
  `capture_prompt: false` because this is an automated init artifact, not a human decision
  (see `skills/_shared/engram-convention.md` → *Prompt Capture*).

  (See `skills/_shared/engram-convention.md` for full naming conventions.)
- If mode is `openspec`: Read and follow `skills/_shared/openspec-convention.md`. Run full bootstrap.
- If mode is `hybrid`: Read and follow BOTH convention files. Run openspec bootstrap AND persist context to Engram.
- If mode is `none`: Return detected context without writing project files. Exception: `.atl/skill-registry.md` is harness infrastructure (not a project file), so it is still written in `none` mode — see Step 4.

## What to Do

### Step 1: Detect Project Context

Read the project to understand:
- Tech stack (check package.json, go.mod, pyproject.toml, etc.)
- Existing conventions (linters, test frameworks, CI)
- Architecture patterns in use
- **Verify commands**: the test command, build command, and any coverage gate — these fill the `rules.verify` block.
- **Test infrastructure**: whether a test runner, test files, or CI test jobs exist. This picks the `compliance_mode` default:
  - test infra present → `behavioral` (a MUST scenario without a passing test is CRITICAL — the strict gate)
  - no test infra → `static` (compliance may rest on static structural evidence; the cycle can close without test infrastructure)
- **TDD preference (explicit question — NEVER inferred silently)**: The optional TDD module
  is opt-in and NOT installed by default (manifest group `tdd`), so activation without the
  module on disk would leave `sdd-apply`/`sdd-tasks`/`sdd-verify` pointing at a missing file.
  **Preflight — is the module installed?** Resolve `tdd/SKILL.md` across the same
  skill-resolution paths Step 4 scans (user-level `~/.claude/skills/`,
  `~/.config/opencode/skills/`, `~/.gemini/skills/`, `~/.codex/skills/`, `~/.cursor/skills/`,
  `~/.copilot/skills/`, `~/.gemini/antigravity/skills/`, the parent directory of this skill
  file, and the project-level equivalents).
  - **If `tdd/SKILL.md` is NOT resolvable**: do NOT ask the enable question and do NOT record
    `tdd.enabled=true`. Record `tdd.enabled=false` and tell the user: *"The TDD module is not
    installed — install it with `scripts/install.sh --with tdd` (or `install.ps1 -With tdd`),
    then re-run `/sdd-init` to enable it."* Surface this in the return envelope's `risks`.
  - **If `tdd/SKILL.md` IS resolvable**: ask the user directly:
    **"Enable TDD (RED → GREEN → REFACTOR) for this project?"** This is the ONLY switch that
    activates the optional TDD module. Detected test infrastructure NEVER auto-enables TDD; it
    only shapes the suggestion:
    - test infra present → suggest enabling ("the codebase looks test-first — enable TDD?")
    - no test infra → offer it, but lean toward disabled
    Record the answer as `tdd.enabled` (default `false` when the user does not opt in). When
    the user enables TDD, also capture the fast single-test invocation for a quick RED cycle →
    `tdd.single_test_command` (e.g. `npm test -- {file}`, `pytest {path}::{test}`, `go test -run {TestX} ./pkg`).
    The full-suite `test_command` stays in `rules.verify` regardless.
- **Execution mode (explicit question — default `supervised`)**: Ask the user directly:
  **"Run SDD in `supervised` or `auto` mode?"** `supervised` (the default) stops the orchestrator
  at every human decision gate — after `propose`, on a `sdd-verify` FAIL, and before `archive` — so
  the user approves each step. `auto` lets the orchestrator continue through those gates without
  asking, halting only on `status: blocked` or a `sdd-verify` FAIL/CRITICAL (archive is never
  auto-run in either mode). Record the answer as `execution_mode` (default `supervised` when the
  user does not choose). Note for the user: `/sdd-ff` always fast-forwards its phases in `auto`
  regardless of this setting.

### Step 2: Initialize Persistence Backend

If mode resolves to `openspec`, create this directory structure:

```
openspec/
├── config.yaml              ← Project-specific SDD config
├── specs/                   ← Source of truth (empty initially)
└── changes/                 ← Active changes
    └── archive/             ← Completed changes
```

### Step 3: Generate Config (openspec mode)

Based on what you detected, create the config when in `openspec` mode:

```yaml
# openspec/config.yaml
schema: spec-driven

execution_mode: supervised  # supervised | auto; supervised stops at human gates, auto continues unless blocked/verify FAIL

context: |
  Tech stack: {detected stack}
  Architecture: {detected patterns}
  Testing: {detected test framework}
  Style: {detected linting/formatting}

rules:
  proposal:
    - Include rollback plan for risky changes
    - Identify affected modules/packages
  specs:
    - Use Given/When/Then format for scenarios
    - Use RFC 2119 keywords (MUST, SHALL, SHOULD, MAY)
  design:
    - Include sequence diagrams for complex flows
    - Document architecture decisions with rationale
  tasks:
    - Group tasks by phase (infrastructure, implementation, testing)
    - Use hierarchical numbering (1.1, 1.2, etc.)
    - Keep tasks small enough to complete in one session
  apply:
    - Follow existing code patterns and conventions
    - Load relevant coding skills for the project stack
  verify:
    test_command: ""             # e.g. "npm test"; detected command or empty
    build_command: ""            # e.g. "npm run build"; detected command or empty
    coverage_threshold: 0        # minimum coverage %; 0 disables the check
    compliance_mode: behavioral  # behavioral | static; static downgrades UNTESTED to WARNING
  archive:
    - Warn before merging destructive deltas (large removals)

# Optional TDD module — single opt-in switch (see skills/tdd/SKILL.md).
# Only `enabled` and `single_test_command` live here; test_command/build_command/
# coverage_threshold stay under rules.verify. In engram mode these two keys live in
# the sdd-init/{project} context artifact instead of this file.
tdd:
  enabled: false               # opt-in switch for the optional TDD module (RED → GREEN → REFACTOR)
  single_test_command: ""      # e.g. "npm test -- {file}"; runs ONE test/scenario for a fast RED cycle
```

The `execution_mode`, `verify`, and `tdd` blocks above are the canonical schema from
`skills/_shared/openspec-convention.md`. Fill `test_command`/`build_command`
with the commands you detected in Step 1 (test runner, build script), or leave
them empty when none exists; leave `coverage_threshold` at `0` unless the
project enforces a coverage gate. Set `compliance_mode` to the default you chose
in Step 1: `behavioral` when test infrastructure exists, `static` when it does
not. Set `tdd.enabled` from the explicit question in Step 1 (default `false`); when
the user opts in, fill `tdd.single_test_command` with the fast single-test
invocation. Existing test files never flip `tdd.enabled` on their own. Set
`execution_mode` from the explicit question in Step 1 (default `supervised`).

### Step 4: Build Skill Registry

Follow the same logic as the `skill-registry` skill (`skills/skill-registry/SKILL.md`):

1. Scan user skills: glob `*/SKILL.md` across ALL known skill directories (they mirror the per-harness install targets in `skills/manifest.json`). **User-level**: `~/.claude/skills/`, `~/.config/opencode/skills/`, `~/.gemini/skills/`, `~/.codex/skills/`, `~/.cursor/skills/`, `~/.copilot/skills/`, `~/.gemini/antigravity/skills/`, and the parent directory of this skill file (the catch-all — ATL's own skills are co-located wherever it was installed, so this always covers the active harness target even if it is not in the explicit list). **Project-level**: `.claude/skills/`, `.config/opencode/skills/`, `.gemini/skills/`, `.codex/skills/`, `.cursor/skills/`, `.copilot/skills/`, `.gemini/antigravity/skills/`, `skills/`. Skip `sdd-*`, `_shared`, `skill-registry`. Deduplicate by name (project-level wins). Read frontmatter triggers.
2. Scan project conventions: check for `agents.md`, `AGENTS.md`, `CLAUDE.md` (project-level), `.cursorrules`, `GEMINI.md`, `copilot-instructions.md` in the project root. If an index file is found (e.g., `agents.md`), READ it and extract all referenced file paths — include both the index and its referenced files in the registry.
3. **ALWAYS write `.atl/skill-registry.md`** in the project root (create `.atl/` if needed). This file is harness infrastructure, NOT an SDD project artifact, so it is written in EVERY mode — including `none`. The persistence-mode gates that suppress project files (e.g. `openspec/`) never apply to `.atl/`.
4. If engram is available, **ALSO save to engram**: `mem_save(title: "skill-registry", topic_key: "skill-registry", type: "config", project: "{project}", capture_prompt: false, content: "{registry markdown}")` (`capture_prompt: false` — automated build output, not a human decision)

See `skills/skill-registry/SKILL.md` for the full registry format and scanning details.

### Step 5: Persist Project Context and Pipeline Settings

**This step is MANDATORY — do NOT skip it.**

**Pipeline settings are part of the persisted context.** SDD phases need a single home
for the settings that steer the whole cycle:

- `artifact_store.mode`: `engram | openspec | hybrid | none`
- `execution_mode`: `supervised | auto` (chosen in Step 1)
- `compliance_mode`: `behavioral | static` (chosen in Step 1)
- `test_command`, `build_command`, `coverage_threshold` (detected in Step 1)
- `tdd.enabled`: `true | false` (from the explicit TDD question in Step 1 — the single switch for the optional TDD module)
- `tdd.single_test_command` (only when `tdd.enabled` is `true` — the fast single-test invocation for the RED cycle)

Settings home per mode:
- `openspec` / `hybrid`: `openspec/config.yaml` (written in Step 3) is the home; in
  `hybrid` the Engram context mirrors it.
- `engram` / `none`: the `sdd-init/{project-name}` context artifact is the home — it
  MUST carry the settings above (there is no `config.yaml`).

**Propagation contract (the orchestrator honors this):** the orchestrator reads these
settings once and injects them into EVERY phase prompt. On conflict, the value
propagated in the phase prompt WINS over any stale value in `config.yaml` or the
context artifact. Record the settings explicitly in the persisted context so the
orchestrator can propagate them.

If mode is `engram`:
```
mem_save(
  title: "sdd-init/{project-name}",
  topic_key: "sdd-init/{project-name}",
  type: "architecture",
  project: "{project-name}",
  capture_prompt: false,
  content: "{your detected project context from Steps 1-4, including the pipeline settings block}"
)
```

If mode is `openspec` or `hybrid`: the config (with the pipeline settings) was already written in Step 3.

If mode is `hybrid`: also call `mem_save` as above (write to BOTH backends).

### Step 6: Return Envelope

Return the standard envelope defined in **Section D** of
`skills/_shared/sdd-phase-common.md` (`status`, `executive_summary`,
`detailed_report`, `artifacts`, `next_recommended`, `risks`, `skill_resolution`) —
it is the ONLY return contract for this phase. sdd-init BUILDS the skill registry
rather than consuming it, so `skill_resolution` is `none` (no project skills were
loaded to perform init).

Phase-specific fields to surface in `detailed_report` (adapt wording to the mode):

- **Project**: {name}
- **Stack**: {detected stack}
- **Persistence**: {engram | openspec | hybrid | none}
- **Execution mode**: {supervised | auto} — {user's answer to the explicit question}
- **Compliance mode**: {behavioral | static} — {test infra detected? one-line rationale}
- **TDD**: {enabled | disabled} — {user's answer to the explicit question; single_test_command if enabled}
- **Settings home**: `sdd-init/{project}` context artifact (engram/none) or `openspec/config.yaml` (openspec/hybrid)
- **Skill registry**: `.atl/skill-registry.md` (+ Engram `skill-registry` when available)

Populate the envelope fields per mode:

- `artifacts`: what was written — for `openspec`/`hybrid`, `openspec/config.yaml` plus
  the created directories (and the Engram `sdd-init/{project}` observation for
  `hybrid`); for `engram`, the Engram `sdd-init/{project}` observation ID; for `none`,
  only `.atl/skill-registry.md` (no project files — the `.atl/` registry is harness
  infrastructure, not a project artifact).
- `next_recommended`: `sdd-explore` (or `sdd-new` when the user already has a change name).
- `risks`: include a note in `none` mode recommending `engram` or `openspec` so SDD
  artifacts survive across sessions; otherwise `None`.

## Rules

- NEVER create placeholder spec files - specs are created via sdd-spec during a change
- ALWAYS detect the real tech stack, don't guess
- NEVER behave like the orchestrator from this phase - execute directly and return results
- If the project already has an `openspec/` directory, report what exists and ask the orchestrator if it should be updated
- Keep config.yaml context CONCISE - no more than 10 lines
- Return the **Section D** envelope from `skills/_shared/sdd-phase-common.md` (including `skill_resolution`) — see Step 6. It is the ONLY return contract for this phase.
