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

## What to Do

### Step 1: Detect Project Context

Read the project to understand:
- Tech stack — ANY stack. Read whatever manifest, lockfile, or build descriptor the
  project actually has. Kurama carries NO list of supported ecosystems: an unfamiliar
  stack is a normal case, never a degraded one.
- Existing conventions (linters, test frameworks, CI)
- Architecture patterns in use
- **Project commands (explicit question — NEVER inferred silently)**: the test, build,
  and single-test commands are the most project-specific values in the whole cycle and
  the ones the harness cannot know. ASK for them, in the same manner as TDD and
  `execution_mode` below. A guessed command fails opaquely — or worse, runs the wrong
  thing — and a stack absent from any table would otherwise dead-end at `sdd-verify`.
  **Pre-fill, then confirm**: consult the suggestion table in
  `skills/_shared/test-runners.md` for a likely default when a detection file is
  present, then ASK the user to confirm or correct:
  **"Test command? Build/type-check command? (blank = none)"**
  - Record the answers as `rules.verify.test_command` and `rules.verify.build_command`.
  - An empty answer is a VALID answer meaning "this project has none" — record it as
    empty; do not keep pressing and do not substitute a guess.
  - The table is a courtesy for common stacks, NOT a supported-stack list. When no row
    matches, ask with no default — that path is fully supported.
  - Also ask for the coverage gate only if the project appears to enforce one; default
    `coverage_threshold: 0` (disabled).
- **Compliance mode**: derived from the ANSWER above, not from file sniffing:
  - a test command was given → `behavioral` (a MUST scenario without a passing test is CRITICAL — the strict gate)
  - no test command → `static` (compliance may rest on static structural evidence; the cycle can close without test infrastructure)
  Offer the derived value and let the user override it.
- **TDD preference (explicit question — NEVER inferred silently)**: The optional TDD module
  now installs by default (manifest group `tdd`), but it can still be absent — someone may
  have excluded it with `--without tdd` — so activation without the module on disk would
  leave `sdd-apply`/`sdd-tasks`/`sdd-verify` pointing at a missing file.
  **Preflight — is the module installed?** Resolve `tdd/SKILL.md` across the same
  skill-resolution paths Step 4 scans (user-level `~/.claude/skills/`,
  `~/.config/opencode/skills/`, `~/.codex/skills/`, `~/.pi/agent/skills/`,
  `~/.omp/agent/skills/`, the parent directory of this skill file, and the project-level
  equivalents).
  - **If `tdd/SKILL.md` is NOT resolvable**: do NOT ask the enable question and do NOT record
    `tdd.enabled=true`. Record `tdd.enabled=false` and tell the user: *"The TDD module is
    missing (default installs include it; it was excluded with `--without tdd`) — reinstall
    with `scripts/install.sh`, then re-run `/sdd-init` to enable it."*
    Surface this in the return envelope's `risks`.
  - **If `tdd/SKILL.md` IS resolvable**: ask the user directly:
    **"Enable TDD (RED → GREEN → REFACTOR) for this project?"** This is the ONLY switch that
    activates the optional TDD module. The answer to the test-command question NEVER
    auto-enables TDD; it only shapes the suggestion:
    - a test command was given → suggest enabling ("the project already runs tests — enable TDD?")
    - no test command → offer it, but lean toward disabled
    Record the answer as `tdd.enabled` (default `false` when the user does not opt in). When
    the user enables TDD, ASK for the fast single-test invocation for a quick RED cycle →
    `tdd.single_test_command`, pre-filled from the suggestion table in
    `skills/_shared/test-runners.md` when a row matches, asked with no default otherwise.
    The full-suite `test_command` stays in `rules.verify` regardless.
- **Execution mode (explicit question — default `supervised`)**: Ask the user directly:
  **"Run SDD in `supervised` or `auto` mode?"** `supervised` (the default) stops the orchestrator
  at every human decision gate — after `propose`, on a `sdd-verify` FAIL, and before `archive` — so
  the user approves each step. `auto` lets the orchestrator continue through those gates without
  asking, halting only on `status: blocked` or a `sdd-verify` FAIL/CRITICAL (archive is never
  auto-run in either mode). Record the answer as `execution_mode` (default `supervised` when the
  user does not choose). Note for the user: `/sdd-ff` always fast-forwards its phases in `auto`
  regardless of this setting.
- **Kanban board (explicit question — same manner as TDD; default disabled)**: The optional
  Kanban module syncs a GitHub Projects (v2) board to the SDD cycle. Like TDD, install ≠
  activate and there are ZERO heuristics — an existing project or a configured `gh` NEVER
  auto-enable it.
  **Preflight — is the module installed?** The `kanban-github` skill ships in the excludable
  `optional` manifest group; resolve `kanban-github/SKILL.md` across the same skill-resolution
  paths Step 4 scans. If it is NOT resolvable (excluded with `--without optional`), do NOT ask
  the question, record `kanban.enabled=false`, and note it in `risks`.
  **If resolvable**, ask directly: **"Enable Kanban board sync (GitHub Projects) for this
  project?"** (default `false` when the user does not opt in).
  - **On "yes", first verify the `gh` prerequisite in order** — activation REQUIRES a
    configured GitHub CLI. If any check fails, print the exact fix command, record
    `kanban.enabled=false`, surface it in `risks`, and continue init (the user can re-run
    `/sdd-init` once fixed):
    1. `gh --version` (installed) → fix: `brew install gh`
    2. `gh auth status` (authenticated) → fix: `gh auth login`
    3. `gh project list --owner @me --limit 1` (the `read:project,project` scopes) → fix: `gh auth refresh -s read:project,project`
  - **When all three pass, run the onboarding** (see `skills/kanban-github/SKILL.md` → *Onboarding &
    Cached IDs* for the full detail) and CONFIRM each value with the user:
    - **assignee**: the default is `@me` (every issue/card the harness creates is assigned to
      whoever created it); `kanban.user` is an OPTIONAL override — set a specific login only when
      the project wants a fixed assignee, otherwise leave it empty for `@me`.
    - **project**: `gh project list --owner {owner}` (owner deduced from `git remote`; confirm)
      — pick the project, capture its `number`, and cache `project_id` via
      `gh project view {project_number} --owner {owner} --format json --jq '.id'`.
    - **Status field + options**: `gh project field-list {project_number} --owner {owner}
      --format json` — capture the Status single-select field `id` and each option `id`.
    - **stage mapping**: map the board's REAL options to the 5 canonical stages
      (`backlog`, `ready`, `in_progress`, `in_review`, `done`) — NEVER hardcode names; if the
      board uses other labels (e.g. `Todo`), confirm the mapping. Only these 5 stages are
      managed; any other board column (e.g. `Resources`) is ignored.
    - **merge method**: ask `merge` | `squash` | `rebase` for the final gate (default `squash`).
    - **Size field (optional)**: if the board has a Size single-select field, optionally cache
      `size_field_id` + the `sizes` map; skip without error when absent.
    Record `kanban.enabled=true` and the full `kanban` block (schema in Step 3).

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

# Optional Kanban module — GitHub Projects board sync (see skills/kanban-github/SKILL.md).
# Installed by default (manifest group `optional`); activation is opt-in per project
# and REQUIRES a configured GitHub CLI (gh). In engram mode these keys live in the
# sdd-init/{project} context artifact instead of this file.
kanban:
  enabled: false             # opt-in switch; set true only after the gh prerequisite checks pass
  user: ""                   # optional assignee override; empty => @me (the active gh account owns every harness-created issue)
  owner: ""                  # repo owner, deduced from the git remote and confirmed
  repo: ""                   # repository name
  project_number: 0          # GitHub Project (v2) number (used by item-add / field-list / view)
  project_id: ""             # cached ProjectV2 node id (PVT_...) captured at onboarding; reused by every card move
  status_field_id: ""        # node id of the board's Status single-select field (PVTSSF_...)
  merge_method: squash       # merge | squash | rebase; used at the final human OK gate (default squash, --delete-branch)
  stages:                    # canonical stage -> real board option_id (mapped from the board's Status options)
    backlog: ""
    ready: ""
    in_progress: ""
    in_review: ""
    done: ""
  size_field_id: ""          # optional: node id of the board's Size single-select field (empty => no Size field on the board)
  sizes:                     # optional: t-shirt size -> real board option_id (only when size_field_id is set)
    xs: ""
    s: ""
    m: ""
    l: ""
    xl: ""
```

The `execution_mode`, `verify`, `tdd`, and `kanban` blocks above are the canonical schema from
`skills/_shared/openspec-convention.md`. Fill `test_command`/`build_command` with the
commands the USER GAVE in Step 1 — record an empty string when the user said the project
has none, and never substitute a guess for a missing answer; leave `coverage_threshold`
at `0` unless the user named a gate. Set `compliance_mode` to the value settled in
Step 1: `behavioral` when a test command was given, `static` when it was not, unless the
user overrode it. Set `tdd.enabled` from the explicit question in Step 1 (default
`false`); when the user opts in, fill `tdd.single_test_command` with the invocation they
gave. Existing test files never flip `tdd.enabled` on their own. Set
`execution_mode` from the explicit question in Step 1 (default `supervised`).
Set `kanban.enabled` from the explicit question in Step 1 (default `false`) — record
`true` ONLY when the user opted in AND all three `gh` prerequisite checks passed; when
enabled, fill `owner`, `repo`, `project_number`, `project_id`, `status_field_id`,
`merge_method`, and each `stages.*` option id from the onboarding (leave `user` empty for
the `@me` default, or set it to a fixed assignee override; fill the optional
`size_field_id` + `sizes` only when the board has a Size field). Leave the whole
`kanban` block at its defaults (`enabled: false`, empty ids) when the user declines, the
module is absent, or a `gh` check fails. A configured `gh` never flips `kanban.enabled`
on its own.

### Step 4: Build Skill Registry

Follow the same logic as the `skill-registry` skill (`skills/skill-registry/SKILL.md`):

1. Scan user skills: glob `*/SKILL.md` across ALL known skill directories (they mirror the per-harness install targets in `skills/manifest.json`). **User-level**: `~/.claude/skills/`, `~/.config/opencode/skills/`, `~/.codex/skills/`, `~/.pi/agent/skills/`, `~/.omp/agent/skills/`, and the parent directory of this skill file (the catch-all — Kurama's own skills are co-located wherever it was installed, so this always covers the active harness target even if it is not in the explicit list). **Project-level**: `.claude/skills/`, `.config/opencode/skills/`, `.codex/skills/`, `.pi/skills/`, `.omp/skills/`, `skills/`. Skip `sdd-*`, `_shared`, `skill-registry`. Deduplicate by name (project-level wins). Read frontmatter triggers.
2. Scan project conventions: check for `agents.md`, `AGENTS.md`, `CLAUDE.md` (project-level) in the project root. If an index file is found (e.g., `agents.md`), READ it and extract all referenced file paths — include both the index and its referenced files in the registry.
3. **ALWAYS write `.kurama/skill-registry.md`** in the project root (create `.kurama/` if needed). This file is harness infrastructure, NOT an SDD project artifact, so it is written in EVERY mode. The persistence-mode gates that suppress project files (e.g. `openspec/`) never apply to `.kurama/`.
4. If engram is available, **ALSO save to engram**: `mem_save(title: "skill-registry", topic_key: "skill-registry", type: "config", project: "{project}", capture_prompt: false, content: "{registry markdown}")` (`capture_prompt: false` — automated build output, not a human decision)

See `skills/skill-registry/SKILL.md` for the full registry format and scanning details.

### Step 5: Persist Project Context and Pipeline Settings

**This step is MANDATORY — do NOT skip it.**

**Pipeline settings are part of the persisted context.** SDD phases need a single home
for the settings that steer the whole cycle:

- `artifact_store.mode`: `engram | openspec | hybrid`
- `execution_mode`: `supervised | auto` (chosen in Step 1)
- `compliance_mode`: `behavioral | static` (chosen in Step 1)
- `test_command`, `build_command`, `coverage_threshold` (detected in Step 1)
- `tdd.enabled`: `true | false` (from the explicit TDD question in Step 1 — the single switch for the optional TDD module)
- `tdd.single_test_command` (only when `tdd.enabled` is `true` — the fast single-test invocation for the RED cycle)
- `kanban.enabled`: `true | false` (from the explicit Kanban question in Step 1 — the single switch for the optional GitHub Projects board sync)
- `kanban.owner`, `kanban.repo`, `kanban.project_number`, `kanban.project_id`, `kanban.status_field_id`, `kanban.merge_method`, `kanban.stages.*` (only when `kanban.enabled` is `true` — the board wiring cached during onboarding), plus the OPTIONAL `kanban.user` (empty => `@me`) and the OPTIONAL `kanban.size_field_id` + `kanban.sizes.*` (only when the board has a Size field)

Settings home per mode:
- `openspec` / `hybrid`: `openspec/config.yaml` (written in Step 3) is the home; in
  `hybrid` the Engram context mirrors it.
- `engram`: the `sdd-init/{project-name}` context artifact is the home — it
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
- **Persistence**: {engram | openspec | hybrid}
- **Execution mode**: {supervised | auto} — {user's answer to the explicit question}
- **Compliance mode**: {behavioral | static} — {test infra detected? one-line rationale}
- **TDD**: {enabled | disabled} — {user's answer to the explicit question; single_test_command if enabled}
- **Kanban**: {enabled | disabled} — {user's answer; when enabled: project_number + stage mapping + merge_method; when a `gh` prerequisite failed: which check and the fix command}
- **Settings home**: `sdd-init/{project}` context artifact (engram) or `openspec/config.yaml` (openspec/hybrid)
- **Skill registry**: `.kurama/skill-registry.md` (+ Engram `skill-registry` when available)

Populate the envelope fields per mode:

- `artifacts`: what was written — for `openspec`/`hybrid`, `openspec/config.yaml` plus
  the created directories (and the Engram `sdd-init/{project}` observation for
  `hybrid`); for `engram`, the Engram `sdd-init/{project}` observation ID. Every mode also
  writes `.kurama/skill-registry.md`, which is harness infrastructure rather than a project
  artifact and is therefore never suppressed by a persistence mode.
- `next_recommended`: `sdd-explore` (or `sdd-new` when the user already has a change name).
- `risks`: when Engram was the resolved backend but was unavailable, note the degrade to the
  `.kurama/sdd/` filesystem fallback; when the user asked for Kanban but the module was
  absent or a `gh` prerequisite check failed, note that `kanban.enabled` was recorded
  `false` and the exact command to fix it (re-run `/sdd-init` afterward); otherwise `None`.

## Rules

- This phase runs ONCE per project. It is re-run ONLY on an explicit user request to change configuration (enable TDD/kanban, switch settings) — never launched implicitly by the orchestrator or another phase. Re-runs upsert the existing settings; they never duplicate.
- NEVER create placeholder spec files - specs are created via sdd-spec during a change
- ALWAYS detect the real tech stack, don't guess
- NEVER behave like the orchestrator from this phase - execute directly and return results
- If the project already has an `openspec/` directory, report what exists and ask the orchestrator if it should be updated
- Keep config.yaml context CONCISE - no more than 10 lines
- Return the **Section D** envelope from `skills/_shared/sdd-phase-common.md` (including `skill_resolution`) — see Step 6. It is the ONLY return contract for this phase.
