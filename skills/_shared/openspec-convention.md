# OpenSpec File Convention (shared across all SDD skills)

> **Not the upstream OpenSpec CLI.** This file defines ATL's own project-local
> convention for `openspec/` — a different config schema and directory layout
> than the upstream [Fission-AI/OpenSpec](https://github.com/Fission-AI/OpenSpec)
> tool (no `config.yaml`/`state.yaml` there; different commands, different
> archive layout). The two are not interchangeable, and ATL does not depend on
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
        ├── exploration.md   <- (optional) from sdd-explore
        ├── proposal.md      <- from sdd-propose
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
| sdd-explore | Creates (optional) | `openspec/changes/{change-name}/exploration.md` |
| sdd-propose | Creates | `openspec/changes/{change-name}/proposal.md` |
| sdd-spec | Creates | `openspec/changes/{change-name}/specs/{domain}/spec.md` |
| sdd-design | Creates | `openspec/changes/{change-name}/design.md` |
| sdd-tasks | Creates | `openspec/changes/{change-name}/tasks.md` |
| sdd-apply | Updates | `openspec/changes/{change-name}/tasks.md` (marks `[x]`) |
| sdd-verify | Creates | `openspec/changes/{change-name}/verify-report.md` |
| sdd-archive | Moves | `openspec/changes/{change-name}/` → `openspec/changes/archive/YYYY-MM-DD-{change-name}/` |
| sdd-archive | Updates | `openspec/specs/{domain}/spec.md` (merges deltas into main specs) |

## Reading Artifacts

```
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

```yaml
# openspec/config.yaml
schema: spec-driven

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

## Archive Structure

When archiving, the change folder moves to:
```
openspec/changes/archive/YYYY-MM-DD-{change-name}/
```

Use today's date in ISO format. The archive is an AUDIT TRAIL — never delete or modify archived changes.
