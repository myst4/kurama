# OpenSpec File Convention (shared across all SDD skills)

> **Not the upstream OpenSpec CLI.** This file defines Kurama's own project-local
> convention for `openspec/` — a different config schema and directory layout
> than the upstream [Fission-AI/OpenSpec](https://github.com/Fission-AI/OpenSpec)
> tool (no `config.yaml`/`state.yaml` there; different commands, different
> archive layout). The two are not interchangeable, and Kurama does not depend on
> or invoke the upstream CLI. The `openspec` mode name is kept for continuity
> with existing installs, not for compatibility with the upstream project.

## Directory Structure

```
openspec/
├── config.yaml              <- Project-specific SDD config
├── specs/                   <- Source of truth (main specs)
│   └── {domain}/
│       └── spec.md
└── changes/                 <- Active changes
    ├── archive/             <- Completed changes (YYYY-MM-DD-{change-name}/)
    └── {change-name}/       <- Active change folder
        ├── state.yaml       <- DAG state (survives compaction)
        ├── brainstorm.md    <- (optional) decision ledger from the sdd-new brainstorm gate
        ├── exploration.md   <- (optional) from sdd-explore
        ├── proposal.md      <- from sdd-propose (carries ## Change Size; for a `small`
        │                       change also ## Spec (inline) and ## Design (inline), and
        │                       the two files below are not produced)
        ├── specs/           <- from sdd-spec
        │   └── {domain}/
        │       └── spec.md  <- Delta spec
        ├── design.md        <- from sdd-design
        ├── tasks.md         <- from sdd-tasks (updated by sdd-apply)
        └── verify-report.md <- from sdd-verify
```

## Artifact File Paths

| Skill | Creates / Reads | Path |
|-------|----------------|------|
| orchestrator | Creates/Updates | `openspec/changes/{change-name}/state.yaml` |
| sdd-init | Creates | `openspec/config.yaml`, `openspec/specs/`, `openspec/changes/`, `openspec/changes/archive/` |
| sdd-brainstorm | Creates (optional) | `openspec/changes/{change-name}/brainstorm.md` (decision ledger; written INLINE by the orchestrator at the `sdd-new` brainstorm gate) |
| sdd-explore | Creates (optional) | `openspec/changes/{change-name}/exploration.md` |
| sdd-propose | Creates | `openspec/changes/{change-name}/proposal.md` (carries `## Change Size`; for `small`, also `## Spec (inline)` and `## Design (inline)`) |
| sdd-spec | Creates | `openspec/changes/{change-name}/specs/{domain}/spec.md` (`standard` only) |
| sdd-design | Creates | `openspec/changes/{change-name}/design.md` (`standard` only) |
| sdd-tasks | Creates | `openspec/changes/{change-name}/tasks.md` |
| sdd-apply | Updates | `openspec/changes/{change-name}/tasks.md` (marks `[x]`) |
| sdd-verify | Creates | `openspec/changes/{change-name}/verify-report.md` |
| sdd-archive | Moves | `openspec/changes/{change-name}/` → `openspec/changes/archive/YYYY-MM-DD-{change-name}/` |
| sdd-archive | Updates | `openspec/specs/{domain}/spec.md` (merges deltas into main specs) |

## Reading Artifacts

```
Brainstorm: openspec/changes/{change-name}/brainstorm.md
Proposal:   openspec/changes/{change-name}/proposal.md
Specs:      openspec/changes/{change-name}/specs/  (all domain subdirectories)
Design:     openspec/changes/{change-name}/design.md
Tasks:      openspec/changes/{change-name}/tasks.md
Verify:     openspec/changes/{change-name}/verify-report.md
Config:     openspec/config.yaml
Main specs: openspec/specs/{domain}/spec.md
```

## Writing Rules

- Always create the change directory before writing artifacts
- If a file already exists, READ it first and UPDATE it (don't overwrite blindly)
- If the change directory already exists with artifacts, the change is being CONTINUED
- Use `openspec/config.yaml` `rules` section for project-specific constraints per phase

## Delta Spec Sections (canonical)

**This section is the single source of truth for delta semantics.** `sdd-spec` (the writer),
`sdd-propose` (which writes the `## Spec (inline)` delta on the `small` path), and `sdd-archive`
(the merger) all resolve ADDED / MODIFIED / REMOVED / RENAMED here. They MUST link to this
section instead of restating it: a delta that means one thing when written and another when
merged is exactly how scenarios disappear, and the merge is what writes `openspec/specs/` —
the declared source of truth, with `sdd-archive` as its only writer.

A delta spec MAY contain any of these four sections:

```markdown
## ADDED Requirements
## MODIFIED Requirements
## REMOVED Requirements
## RENAMED Requirements
```

Requirements are matched between the delta and the main spec **by heading text** —
`### Requirement: {name}`, compared verbatim. Any requirement the delta does not name is
PRESERVED untouched by the merge.

| Section | What the delta MUST carry | What the merge does to the main spec |
|---------|---------------------------|--------------------------------------|
| `ADDED` | The complete new requirement and all of its scenarios | Appends it to the main spec's Requirements section |
| `MODIFIED` | The **ENTIRE** requirement block — heading, description, and **every scenario, including the ones that did not change** | REPLACES the whole matching requirement block with the delta's block |
| `REMOVED` | The heading plus `(Reason: ...)`, and `(Migration: ...)` when consumers, persisted behavior, docs, or tests are affected | Deletes the matching requirement block |
| `RENAMED` | `### Requirement: {Old Name} → {New Name}` with both names explicit, plus `(Reason: ...)` and `(Migration: ...)` | Rewrites the heading in place and KEEPS the existing scenarios untouched |

### Why MODIFIED is a whole-block replacement

`MODIFIED` does not merge scenario by scenario. The merger cannot distinguish "this scenario was
deleted on purpose" from "the author only pasted the scenario they were editing" — both arrive as
a requirement block with fewer scenarios than the baseline. It resolves that ambiguity the only
way that is safe to automate: the delta's block wins in full.

The consequence is the rule. A five-scenario requirement whose author changes one scenario and
writes only that scenario archives as a one-scenario requirement: the other four are deleted from
the source of truth, silently, recoverable only from git history — and in `engram` mode, not
recoverable at all. That is why the writer MUST copy the full block before editing it
(`sdd-spec` → *MODIFIED Requirements Workflow*) and why the merger MUST NOT write through a
MODIFIED block that drops scenarios the delta does not account for (`sdd-archive` → Step 2,
*Merge preservation readback*).

Two corollaries follow directly:

- **Adding behavior without changing existing behavior → use `ADDED`, never `MODIFIED`.** ADDED
  appends and cannot lose a scenario; MODIFIED replaces and always can.
- **Deleting a scenario on purpose → delete it from the copied full block, and say so** in the
  requirement's `(Previously: ...)` line. The delta is then a truthful statement of the
  requirement's new complete shape, and the archive's preservation readback is satisfied.

### Scenario IDs across a delta

Scenario IDs (`S-{requirement-slug}-{n}`, defined in `sdd-spec`) are STABLE for the life of the
requirement — `sdd-tasks` and `sdd-verify` reference them:

- A scenario carried through a MODIFIED block unchanged keeps its EXACT id. Never renumber it.
- A scenario added inside a MODIFIED block continues that requirement's numbering from the
  highest existing `{n}`, even when lower numbers are now unused.
- `RENAMED` changes the requirement heading only. Existing scenario ids keep their old
  `{requirement-slug}`; renumbering them would break every reference that already points at them.

### Renames are RENAMED, not REMOVED + ADDED

Modelling a rename as a REMOVED block plus an ADDED block deletes the requirement and recreates
it, which discards its scenario history and every stable id downstream phases hold. Use
`RENAMED`. To rename AND change behavior in one cycle, emit a `RENAMED` entry plus a `MODIFIED`
block under the NEW name carrying the full requirement.

## Config File Reference

The `rules` block is a single canonical schema. The guidance phases (`proposal`,
`specs`, `design`, `tasks`, `apply`, `archive`) are lists of instructions. The
`verify` phase is a mapping that holds the run configuration: `test_command`,
`build_command`, and `coverage_threshold` are the ONLY home for these commands.
`sdd-verify` reads them (it runs the full suite, build, and coverage gate);
`sdd-apply` does NOT run the full suite — in TDD mode it uses
`tdd.single_test_command` for the fast RED cycle. Do not add command keys under
`rules.apply`.

`compliance_mode` (`behavioral` | `static`) controls how `sdd-verify` treats a MUST
scenario that has no passing test. `behavioral` (the default when test infrastructure
exists) flags such a scenario CRITICAL — a passing test is the only proof of behavioral
compliance. `static` downgrades it to WARNING and lets compliance rest on static
structural evidence, so a cycle can close in projects without test infrastructure; a
test that exists but FAILS is still CRITICAL in both modes. `sdd-init` picks the default
by detecting test infra. This key is the settings home for `openspec`/`hybrid` mode; in
`engram` mode the same setting lives in the `sdd-init/{project}` context artifact, and
the orchestrator propagates it (with the other pipeline settings) into every phase
prompt, where a propagated value wins over a stale file value.

`execution_mode` (`supervised` | `auto`) controls whether the orchestrator halts at the human
decision gates. `supervised` (the default) makes the orchestrator STOP and ask for a decision at
each human gate — after `propose`, on a `sdd-verify` FAIL, and before `archive`. `auto` lets the
orchestrator continue through those gates without asking, halting ONLY when a phase returns
`status: blocked` or `sdd-verify` reports FAIL/CRITICAL (archive is still never auto-run — it
always needs an explicit go-ahead). `sdd-init` asks for the mode at initialization (default
`supervised`). This top-level key is the settings home for `openspec`/`hybrid` mode; in `engram`
mode the same setting lives in the `sdd-init/{project}` context artifact, and the orchestrator
propagates it (with the other pipeline settings) into every phase prompt, where a propagated value
wins over a stale file value (same precedence as `compliance_mode` and `tdd`). `sdd-ff` always
fast-forwards its phases in `auto` regardless of this setting — fast-forwarding IS the auto behavior.

The top-level `tdd` block is the single switch for the OPTIONAL TDD module. It holds
EXACTLY two keys: `enabled` (bool) and `single_test_command` (string). `enabled` is the
ONLY activator of the RED → GREEN → REFACTOR workflow — there are NO silent heuristics
(existing test files never auto-enable it; at most `sdd-init` raises an interactive
suggestion). `single_test_command` is the fast invocation that runs ONE test/scenario to
keep the RED cycle quick; the full-suite `test_command`, `build_command`, and
`coverage_threshold` stay in `rules.verify` (they are needed with TDD disabled too — the
`tdd` block NEVER absorbs them). This block is the settings home for `openspec`/`hybrid`
mode; in `engram` mode the same `tdd.enabled` / `tdd.single_test_command` settings live in
the `sdd-init/{project}` context artifact, and the orchestrator propagates them into every
phase prompt, where a propagated value wins over a stale file value (same precedence as
`compliance_mode`). `sdd-tasks`, `sdd-apply`, and `sdd-verify` all resolve `tdd.enabled`
this way, so planning, implementation, and audit always agree on one mode. See
`skills/tdd/SKILL.md` for the cycle contract and `skills/_shared/test-runners.md` for the
runner table.

The top-level `kanban` block is the single switch for the OPTIONAL Kanban module — a
GitHub Projects (v2) board synced to the SDD cycle. `enabled` is the ONLY activator (no
heuristics: an existing project, a configured `gh`, or the skill being installed never
auto-activate it), and activation additionally REQUIRES a configured GitHub CLI —
`sdd-init` verifies `gh` is installed, authenticated, and holds the `read:project,project`
scopes (read + write) before recording `enabled: true`. The remaining keys are the board
wiring cached during onboarding: `user` (an OPTIONAL assignee override — empty means `@me`,
so every harness-created issue is assigned to whoever created it), `owner`, `repo`,
`project_number`, `project_id` (the cached ProjectV2 node id, `PVT_...`, captured at
onboarding and reused by every card move), `status_field_id` (the board's Status
single-select field), `merge_method` (`merge` | `squash` | `rebase`, used at the final
merge gate), `stages` (each canonical stage — `backlog`, `ready`, `in_progress`,
`in_review`, `done` — mapped to the board's REAL Status option id; option names are never
hardcoded, and only these 5 stages are managed — any other board column is ignored), and
the OPTIONAL `size_field_id` + `sizes` map (captured only when the board has a Size field).
This block is the settings home for `openspec`/`hybrid` mode; in `engram` mode the same
`kanban` keys live in the `sdd-init/{project}` context artifact. The orchestrator reads
them once per session and moves each issue's card inline at every phase boundary (`gh` is
"Bash for state"); phase executors never touch the board. Kanban `gh` failures are
WARNINGs that never block the cycle — the board is bookkeeping — except the final
`gh pr merge`, which pauses for human instruction. See `skills/kanban-github/SKILL.md` for
the transition commands and lifecycle contract.

```yaml
# openspec/config.yaml
schema: spec-driven

execution_mode: supervised  # supervised | auto; supervised stops at human gates, auto continues unless blocked/verify FAIL

persona: neutral  # neutral | argentino; conversation tone ONLY — artifacts keep the project's language. Preset registry: skills/_shared/personas.md

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

## Archive Structure

When archiving, the change folder moves to:
```
openspec/changes/archive/YYYY-MM-DD-{change-name}/
```

Use today's date in ISO format. The archive is an AUDIT TRAIL — never delete or modify archived changes.
