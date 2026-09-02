---
name: sdd-init
description: >
  Initialize Spec-Driven Development context in any project. Detects stack and conventions, then bootstraps the openspec/ tree.
  Trigger: When user wants to initialize SDD in a project, or says "sdd init", "iniciar sdd", "openspec init".
license: MIT
metadata:
  author: kurama
  version: "2.0"
---

## Purpose

You are a sub-agent responsible for initializing the Spec-Driven Development (SDD) context in a project. You detect the project stack and conventions, then bootstrap the `openspec/` tree.

You are an EXECUTOR for this phase, not the orchestrator. Do the initialization work yourself. Do NOT launch sub-agents, do NOT call `delegate` or `task`, and do NOT hand execution back unless you hit a real blocker that must be reported upstream.

## Execution and Persistence Contract

Artifacts are files under `openspec/` — there is no store to choose and nothing to ask.
Read and follow `skills/_shared/openspec-convention.md`, and run the full bootstrap.

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
  **Preflight — is the module installed?** Check for `tdd/SKILL.md` as a SIBLING of this
  skill file: `../tdd/SKILL.md` relative to the directory this `SKILL.md` lives in. The
  same setup run installs both into the same skills directory, so the sibling is the
  authoritative answer in one hop — and it cannot be satisfied by some other harness's
  copy of a skill named `tdd`.
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
- **Persona (explicit question — default `neutral`)**: Ask the user directly:
  **"Conversation persona: `neutral` or `argentino`?"** The persona shapes the
  orchestrator's CONVERSATION ONLY — specs, proposals, designs, task lists, commit
  messages, and code comments keep the project's own language regardless of it.
  - `neutral` (the default) is today's exact behavior: a project that does not opt in
    changes in no way.
  - `argentino` is a shipped preset — voseo, Latin American technical vocabulary, warm
    and close in tone while staying technically precise.
  `skills/_shared/personas.md` is the preset REGISTRY: offer what it lists (the two above
  ship today) and record the preset name the user picked, so adding a persona stays a
  file, never a code change. Record the answer as `persona` (default `neutral` when the
  user does not choose). An explicit user instruction about language always wins over
  this setting — the persona is a default, never an override.
- **Kanban board (explicit question — same manner as TDD; default disabled)**: The optional
  Kanban module syncs a GitHub Projects (v2) board to the SDD cycle. Like TDD, install ≠
  activate and there are ZERO heuristics — an existing project or a configured `gh` NEVER
  auto-enable it.
  **Preflight — is the module installed?** The `kanban-github` skill ships in the excludable
  `optional` manifest group; check for `../kanban-github/SKILL.md` as a sibling of this skill
  file, exactly as the TDD preflight above does. If it is NOT there (excluded with
  `--without optional`), do NOT ask the question, record `kanban.enabled=false`, and note it
  in `risks`.
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
- **Pre-existing project workflow (conditional explicit question — NO default, ever)**: the
  prompt file this harness reads (`CLAUDE.md`, `AGENTS.md`, or `.omp/AGENTS.md`) may already
  describe how work is done here, committed long before Kurama arrived. `setup.sh` merges
  Kurama's orchestrator block into that same file and now says so at install time (#101) —
  but it deliberately does not decide anything: the project's own committed instructions
  legitimately outrank Kurama's block, and two pipelines claiming the same work is a
  maintainer's decision, not a merge conflict.
  **Preflight — is there a competing workflow?** Read the prompt file and consider ONLY the
  content OUTSIDE the `<!-- BEGIN:kurama -->` / `<!-- END:kurama -->` markers. A competing
  workflow is a section heading naming a process (`## Workflow`, `## Process`, `## How we
  work`, `## Development flow`, `## Pipeline`) or a numbered list of 3+ steps describing one.
  Kurama's own block never counts — it is inside the markers.
  - **If none is found**: do NOT ask. Record `workflow_coexistence: ""` and move on; there is
    nothing to reconcile.
  - **If one IS found**: ask exactly ONE question and NEVER pick a side silently:
    **"`{file}` already defines this project's own workflow. How should it and SDD coexist?"**
    - **`sdd_primary` — RECOMMENDED**: *"SDD's specs are the source of truth; the project's own
      artifacts (issue bodies, board cards, PRDs) become a reflection of the spec."* Marked
      recommended because it is the only answer under which `sdd-verify` has something to
      verify against and `sdd-archive` has something to merge into `openspec/specs/`.
    - **`project_primary`**: *"The project keeps its own flow; SDD runs only when explicitly
      invoked (`/sdd-new`, `/sdd-ff`), on the work the maintainer routes to it."*
    **Rendering.** On Claude Code use the native `AskUserQuestion` tool, with the recommended
    option first and labelled as recommended; on a harness without that primitive ask one text
    question that names which option is recommended and why. Never render the two as equals
    with no recommendation, and never resolve this by default — an unanswered question is
    recorded as unanswered, not as `sdd_primary`.
    Record the answer as `workflow_coexistence`, and the file that carries the competing
    workflow as `workflow_coexistence_source`, so a later session can see WHY the setting
    exists. Surface both in the return envelope's summary.

### Step 2: Bootstrap the `openspec/` Tree

Create this directory structure:

```
openspec/
├── config.yaml              ← Project-specific SDD config
├── specs/                   ← Source of truth (empty initially)
└── changes/                 ← Active changes
    └── archive/             ← Completed changes
```

### Step 3: Generate Config

Based on what you detected, create the config:

```yaml
# openspec/config.yaml
schema: spec-driven

execution_mode: supervised  # supervised | auto; supervised stops at human gates, auto continues unless blocked/verify FAIL

persona: neutral  # neutral | argentino; conversation tone ONLY — artifacts keep the project's language. Preset registry: skills/_shared/personas.md

# Files every phase sub-agent reads IN FULL at phase start, in this order. Repo-relative
# or ~-relative. Proposed in Step 4 and confirmed by the user; empty means the project
# declares no standards. Kurama's own skills never go here.
standards: []

# #101: how this project's OWN pre-existing workflow and SDD coexist. Written ONLY when the
# prompt file was found to carry a competing workflow and the user answered the question;
# empty means "no competing workflow found" — never "we picked the default".
workflow_coexistence: ""         # "" | sdd_primary | project_primary
workflow_coexistence_source: ""  # the prompt file that carries the project's own workflow

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
# coverage_threshold stay under rules.verify.
tdd:
  enabled: false               # opt-in switch for the optional TDD module (RED → GREEN → REFACTOR)
  single_test_command: ""      # e.g. "npm test -- {file}"; runs ONE test/scenario for a fast RED cycle

# Optional Kanban module — GitHub Projects board sync (see skills/kanban-github/SKILL.md).
# Installed by default (manifest group `optional`); activation is opt-in per project
# and REQUIRES a configured GitHub CLI (gh).
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

The `execution_mode`, `persona`, `verify`, `tdd`, and `kanban` blocks above are the canonical schema from
`skills/_shared/openspec-convention.md`. Fill `test_command`/`build_command` with the
commands the USER GAVE in Step 1 — record an empty string when the user said the project
has none, and never substitute a guess for a missing answer; leave `coverage_threshold`
at `0` unless the user named a gate. Set `compliance_mode` to the value settled in
Step 1: `behavioral` when a test command was given, `static` when it was not, unless the
user overrode it. Set `tdd.enabled` from the explicit question in Step 1 (default
`false`); when the user opts in, fill `tdd.single_test_command` with the invocation they
gave. Existing test files never flip `tdd.enabled` on their own. Set
`execution_mode` from the explicit question in Step 1 (default `supervised`), and `persona`
from its explicit question (default `neutral`) — re-running init upserts these keys in
place, it never appends a second copy.
Set `kanban.enabled` from the explicit question in Step 1 (default `false`) — record
`true` ONLY when the user opted in AND all three `gh` prerequisite checks passed; when
enabled, fill `owner`, `repo`, `project_number`, `project_id`, `status_field_id`,
`merge_method`, and each `stages.*` option id from the onboarding (leave `user` empty for
the `@me` default, or set it to a fixed assignee override; fill the optional
`size_field_id` + `sizes` only when the board has a Size field). Leave the whole
`kanban` block at its defaults (`enabled: false`, empty ids) when the user declines, the
module is absent, or a `gh` check fails. A configured `gh` never flips `kanban.enabled`
on its own.

### Step 4: Pre-fill `standards:`

`standards:` is the ordered list of files every phase sub-agent will read in full at phase
start (semantics: `skills/_shared/openspec-convention.md` → *Config File Reference*). You
propose it once, here; from then on it is the project's to edit by hand.

Build the proposal from the PROJECT'S OWN files only:

1. `CLAUDE.md` and `AGENTS.md` at the repo root — include each one that exists.
2. Every `*/SKILL.md` under the project's own skills directories (`.claude/skills/`,
   `.opencode/skills/`, `.pi/skills/`, and any other in-repo skills dir this harness uses)
   whose skill NAME is **not** listed in Kurama's `skills/manifest.json`. Kurama's own
   skills are reached by direct path and never belong in `standards:`.

**Never scan `~` or any user-level skills directory.** The developer's personal skill
collection is theirs, not this project's, and a file outside the repo reaches `standards:`
only because the user typed it in the answer to the question below.

Then ask ONCE, and only once:

> These files will be read in full by every SDD phase agent:
> {numbered list of the proposed paths, in order}
> Confirm, or give me the list you want (add companion skills by path — see
> `docs/companion-skills.md`; `~`-relative paths are allowed).

Write the confirmed list, in the order given, as the `standards:` block of
`openspec/config.yaml` in Step 3's shape. An empty answer means an empty `standards:` list —
a project that declares no standards is a valid project, and you never fill one in on the
user's behalf. Re-running init upserts this key in place; it never appends a second copy,
and it never silently drops a path the user added by hand.

Do NOT delegate this step to a sub-agent, and do NOT read the listed files yourself — you
are recording paths, not loading standards.

### Step 5: Persist Project Context and Pipeline Settings

**This step is MANDATORY — do NOT skip it.**

**Pipeline settings are part of the persisted context.** SDD phases need a single home
for the settings that steer the whole cycle:

- `execution_mode`: `supervised | auto` (chosen in Step 1)
- `persona`: `neutral | argentino` (chosen in Step 1; conversation tone only — never reaches an artifact)
- `compliance_mode`: `behavioral | static` (chosen in Step 1)
- `test_command`, `build_command`, `coverage_threshold` (detected in Step 1)
- `tdd.enabled`: `true | false` (from the explicit TDD question in Step 1 — the single switch for the optional TDD module)
- `tdd.single_test_command` (only when `tdd.enabled` is `true` — the fast single-test invocation for the RED cycle)
- `kanban.enabled`: `true | false` (from the explicit Kanban question in Step 1 — the single switch for the optional GitHub Projects board sync)
- `kanban.owner`, `kanban.repo`, `kanban.project_number`, `kanban.project_id`, `kanban.status_field_id`, `kanban.merge_method`, `kanban.stages.*` (only when `kanban.enabled` is `true` — the board wiring cached during onboarding), plus the OPTIONAL `kanban.user` (empty => `@me`) and the OPTIONAL `kanban.size_field_id` + `kanban.sizes.*` (only when the board has a Size field)

**Settings home: `openspec/config.yaml`, written in Step 3.** There is exactly one, and it
is committed with the project.

**Propagation contract (the orchestrator honors this):** the orchestrator reads these
settings once and injects them into EVERY phase prompt. On conflict, the value
propagated in the phase prompt WINS over any stale value in `config.yaml`. Record the
settings explicitly in the config so the orchestrator can propagate them.

### Step 6: Return Envelope

Return the standard envelope defined in **Section D** of
`skills/_shared/sdd-phase-common.md` (`status`, `executive_summary`,
`detailed_report`, `artifacts`, `next_recommended`, `risks`, `skill_resolution`) —
it is the ONLY return contract for this phase. sdd-init WRITES the `standards:` list
rather than consuming it, so `skill_resolution` is `none` (no project standards were
loaded to perform init).

Phase-specific fields to surface in `detailed_report`:

- **Project**: {name}
- **Stack**: {detected stack}
- **Execution mode**: {supervised | auto} — {user's answer to the explicit question}
- **Persona**: {neutral | argentino} — {user's answer to the explicit question}
- **Compliance mode**: {behavioral | static} — {test infra detected? one-line rationale}
- **TDD**: {enabled | disabled} — {user's answer to the explicit question; single_test_command if enabled}
- **Kanban**: {enabled | disabled} — {user's answer; when enabled: project_number + stage mapping + merge_method; when a `gh` prerequisite failed: which check and the fix command}
- **Settings home**: `openspec/config.yaml`
- **Standards**: {the confirmed `standards:` paths, in order — or "none declared"}

Populate the envelope fields:

- `artifacts`: what was written — `openspec/config.yaml` (including the confirmed
  `standards:` list) plus the created directories.
- `next_recommended`: `sdd-explore` (or `sdd-new` when the user already has a change name).
- `risks`: when the user asked for Kanban but the module was absent or a `gh` prerequisite
  check failed, note that `kanban.enabled` was recorded `false` and the exact command to fix
  it (re-run `/sdd-init` afterward); otherwise `None`.

## Rules

- This phase runs ONCE per project. It is re-run ONLY on an explicit user request to change configuration (enable TDD/kanban, switch settings) — never launched implicitly by the orchestrator or another phase. Re-runs upsert the existing settings; they never duplicate.
- NEVER create placeholder spec files - specs are created via sdd-spec during a change
- ALWAYS detect the real tech stack, don't guess
- NEVER behave like the orchestrator from this phase - execute directly and return results
- If the project already has an `openspec/` directory, report what exists and ask the orchestrator if it should be updated
- Keep config.yaml context CONCISE - no more than 10 lines
- Return the **Section D** envelope from `skills/_shared/sdd-phase-common.md` (including `skill_resolution`) — see Step 6. It is the ONLY return contract for this phase.
