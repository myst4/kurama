---
name: kanban-github
description: >
  Optional GitHub Projects board sync for the SDD cycle: the install-vs-activate
  contract, the `gh` prerequisite checks, the canonical stage mapping, work-intake
  rules, and the card-lifecycle transition commands the orchestrator runs inline.
  Trigger: When a project has `kanban.enabled: true` and the orchestrator needs the
  exact `gh` command to move an issue's card at an SDD phase boundary, or when
  `sdd-init` onboards the board.
license: MIT
metadata:
  author: kurama
  version: "1.0"
---

## Purpose

This module keeps a GitHub Projects (v2) board in sync with the SDD cycle. Each
issue the harness works on has a card; as the change moves through planning,
implementation, review, and delivery, the orchestrator moves that card through the
board's Status column. The board is **bookkeeping** — a live view of where each
change stands — never a control-flow gate (the one exception is the final merge; see
**Failure Semantics**).

This is a protocol reference, not an executable script. It documents WHICH `gh`
command runs at WHICH boundary, using the IDs `sdd-init` cached during onboarding.
The orchestrator runs these commands inline (they are "Bash for state" in the
delegation table); phase executors NEVER touch the board.

## Install ≠ Activate (same contract as TDD)

Installing this skill does NOT activate the board. It ships by default in the
manifest's `optional` group, exactly like the TDD module ships in the `tdd` group —
presence on disk is not activation.

- **Activation is per-project**, through the single switch `kanban.enabled`. There
  are **zero heuristics**: an existing GitHub Project, a configured `gh`, or this
  file being installed NEVER auto-activate the board.
- `sdd-init` asks the enable question explicitly (default `false`) — the same
  place and manner it asks the TDD question.
- The settings home mirrors the other pipeline settings:
  - `openspec` / `hybrid`: the top-level `kanban:` block in `openspec/config.yaml`.
  - `engram`: the `kanban` block in the `sdd-init/{project}` context
    artifact (there is no `config.yaml` in these modes).

## Prerequisite: a configured GitHub CLI

Activation REQUIRES a working `gh`. When the user answers "yes" to the kanban
question, `sdd-init` runs these checks **in order** and only records
`kanban.enabled: true` once all three pass:

1. **Installed** — `gh --version`.
   - On failure: *"GitHub CLI is not installed. Install it with `brew install gh`
     (macOS) or see https://cli.github.com, then re-run `/sdd-init`."*
2. **Authenticated** — `gh auth status`.
   - On failure: *"GitHub CLI is not authenticated. Run `gh auth login`, then re-run
     `/sdd-init`."*
3. **`read:project,project` scopes (read + write)** — probe with
   `gh project list --owner @me --limit 1`.
   - On a scope failure: *"Your `gh` token is missing the project scopes. Grant read
     and write with `gh auth refresh -s read:project,project`, then re-run `/sdd-init`."*

If any check fails: surface the exact command above, record `kanban.enabled: false`,
and continue init normally. The user can re-run `/sdd-init` once the prerequisite is
in place — a missing prerequisite is never fatal to initialization.

Preflight (parallel to TDD's module-presence check): because `kanban-github` lives in
the excludable `optional` group, confirm `kanban-github/SKILL.md` is resolvable across
the same skill-resolution paths `sdd-init` scans before offering activation. If the
module was excluded with `--without optional`, do not offer the question and record
`kanban.enabled: false` with a note to reinstall.

## Onboarding & Cached IDs (run by `sdd-init` on "yes")

After the `gh` checks pass, `sdd-init` discovers and confirms the board wiring, then
persists it. All later card moves reuse these cached values — no rediscovery per phase.

1. **Assignee** — the default is `@me`: every issue and card the harness creates is
   assigned to the owner of the active `gh` account (the rule is *every issue the
   harness creates is assigned to whoever created it*). `kanban.user` is an OPTIONAL
   override — leave it empty to keep `@me`; set it to a specific login only when a
   project wants a fixed assignee other than the running account.
2. **Owner / repo** — deduce the owner from the git remote
   (`git remote get-url origin`) and confirm; capture the repo name.
3. **Discover the project** — `gh project list --owner {owner}`; let the user pick
   the target project and capture its `number`.
4. **Cache the ProjectV2 node id** — capture `project_id` once, so no move re-looks it
   up (`gh project item-edit --project-id` needs the `PVT_...` node id):
   ```bash
   gh project view {project_number} --owner {owner} --format json --jq '.id'
   ```
5. **Read the real Status field and its options** —
   `gh project field-list {project_number} --owner {owner} --format json`. Locate the
   single-select **Status** field: capture its `id` (`status_field_id`) and the `id`
   of each option.
6. **Map real options → the 5 canonical stages** — `backlog`, `ready`,
   `in_progress`, `in_review`, `done`. **NEVER hardcode option names**: if the board
   uses different labels (e.g. `Todo` for Ready, `Done`/`Shipped`), confirm the
   mapping with the user. Store canonical-stage → real-option-`id`. The module
   manages **ONLY these 5 mapped stages** — any other column on the board (e.g. an
   auxiliary `Resources` column) is IGNORED: cards are never moved there.
7. **Merge method** — ask which method the final gate uses: `merge` | `squash` |
   `rebase` (default `squash`). Store as `merge_method`.
8. **Size field (optional)** — if the board has a single-select **Size** field,
   optionally capture it: `size_field_id` plus a `sizes` map (`xs`/`s`/`m`/`l`/`xl` →
   real option id) via the same `field-list` call. This is optional everywhere — if
   the board has no Size field, leave `size_field_id` empty and the whole feature is
   skipped without error; setting a size on a new issue is likewise optional.

### Persisted config block (canonical schema — byte-identical to `openspec/config.yaml`)

```yaml
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

## Work Intake (which card to pick, and when it moves to Ready)

The board reflects work; the human owns prioritization. Intake follows five rules:

- **Existing issue.** The card moves to **Ready** when work on it actually STARTS —
  not when it is merely selected or discussed.
- **A request with no issue.** The issue is BORN in **Backlog** (created + assigned by
  `skills/issue-creation`) and advances to **Ready** only when work starts.
- **No specific request.** ALWAYS take the topmost card in the **Ready** column. If
  Ready is empty, **ASK** the user what to work on — never self-select.
- **Never pull from Backlog on your own initiative.** Backlog → Ready is a
  prioritization decision that belongs to the human; the harness does not promote
  Backlog cards unprompted.
- **The branch carries the card's issue number.** Work taken from a card branches as
  `type/{issue}-{slug}` (see `skills/branch-pr` → *Branch Naming*), so `git branch` maps
  back to the board without a lookup.

## Card Lifecycle (who moves what, when)

The orchestrator owns every MOVE inline; `skills/issue-creation` owns the initial
placement. This mirrors the phase-boundary table in the orchestrator instructions.

| Event | Owner | Card lands in | Notes |
|-------|-------|---------------|-------|
| Issue created | `issue-creation` | **Backlog** + assignee | Card enters the board when the issue is filed (see `skills/issue-creation`). |
| Work on the issue starts (`/sdd-new` or `/sdd-continue` picks it up) | orchestrator | **Ready** | All planning lives here: explore → propose → spec/design → tasks. Moved when work actually starts (see Work Intake). |
| `sdd-apply` starts coding | orchestrator | **In Progress** | Moved when the apply phase begins implementation. |
| `branch-pr` opens the PR | orchestrator | **In Review** | PR body carries `Closes #{issue}` (base = default branch) or `Refs #{issue}` (base ≠ default); the PR link is also posted as an issue comment. |
| User gives the explicit final OK | orchestrator | **Done** | merge → move to Done → return to base. ALWAYS a human gate (below). |

After the PR is opened, post its link as a comment on the issue so the reasoning
trail lives on the board (`gh issue comment {issue} --body {pr-url}`). During
planning, important decisions MAY also be recorded as issue comments (optional but
recommended) so the "why" stays visible on the card.

### Closes vs Refs (keyed on the PR base)

- **Base is the repo's default branch** → the PR body uses `Closes #{issue}`, so the
  merge auto-closes the issue.
- **Base is NOT the default branch** (e.g. a stacked PR onto a feature branch) →
  `Closes` does NOT auto-close toward a non-default base, so the body uses
  `Refs #{issue}` and the agent closes the issue explicitly after the merge
  (`gh issue close {issue}`). See the final-OK order below and `skills/branch-pr`.

### Resolve the card's item id (per issue)

`gh project item-edit` needs the item's id on THIS board — a per-issue value, not a
cached global. Resolve it once per issue from the issue number:

```bash
ITEM_ID=$(gh project item-list {project_number} --owner {owner} --format json \
  --jq ".items[] | select(.content.number == {issue-number}) | .id")
```

### Move to a stage (Ready / In Progress / In Review / Done)

Every move is the same command, differing only in the target option id
(`{stages.<stage>}`). It uses the cached `{project_id}` — no per-move lookup:

```bash
gh project item-edit \
  --project-id {project_id} \
  --id "$ITEM_ID" \
  --field-id {status_field_id} \
  --single-select-option-id {stages.ready}   # or in_progress | in_review | done
```

### Final OK → merge, Done, return to base (human gate)

The user's final OK is **ALWAYS an explicit human gate** — never auto-merge, not
even in `execution_mode: auto`. Before the merge, ALL THREE preconditions must hold:

- **(a) Explicit OK for THIS PR** — never implicit, never inherited from another PR,
  never deduced from a "looks good".
- **(b) Branch rebased onto its base and re-verified** after the rebase.
- **(c) `gh pr checks {pr-number}` all pass, run IMMEDIATELY before the merge** —
  fresh evidence from the command, never a remembered green.

On that OK, run the **canonical order** (identical in `skills/branch-pr` and the
orchestrator instructions):

```bash
# 1. Merge with the configured method (default squash), deleting the branch
gh pr merge {pr-number} --{merge_method} --delete-branch

# 2. Verify the merge landed (expect: MERGED)
gh pr view {pr-number} --json state -q .state

# 3. If the body used `Refs #{issue}` (non-default base), close the issue explicitly
gh issue close {issue}

# 4. Move the card to Done
gh project item-edit --project-id {project_id} --id "$ITEM_ID" \
  --field-id {status_field_id} --single-select-option-id {stages.done}

# 5. Return to the base branch
git checkout {default-branch} && git pull
```

Derive `{default-branch}` from the remote when it is not `main`
(`git symbolic-ref --short refs/remotes/origin/HEAD` → strip the `origin/` prefix).

## Assignment Rule

Every issue and card the harness creates is assigned to whoever created it — the
default is `@me` (the active `gh` account). `kanban.user`, when set, OVERRIDES that
with a fixed login. The initial assignment happens in `skills/issue-creation`
(`gh issue edit {issue-number} --add-assignee {user-or-@me}`) at creation time; the
orchestrator does not re-assign on moves.

## Who Moves the Cards

- **Orchestrator, inline.** `gh` is "Bash for state" in the delegation table, so the
  orchestrator issues these commands directly — no sub-agent, no delegation.
- **Phase executors NEVER touch the board.** `sdd-apply`, `sdd-verify`, and the other
  phase sub-agents implement/verify; they do not run `gh project` or `gh pr` commands.
- The commands above use the IDs cached during onboarding (`project_number`, `owner`,
  `project_id`, `status_field_id`, `stages.*`, `merge_method`) plus the per-issue
  `ITEM_ID`.

## Failure Semantics

**Kanban failures never block the development cycle.** The board is bookkeeping.

- Any `gh` command in the card lifecycle that fails (`item-add`, `item-edit`,
  `issue edit --add-assignee`, `issue comment`) is recorded as a **WARNING** in the
  phase envelope's `risks` and the cycle **CONTINUES**. A board that could not be
  updated never halts a phase.
- **The single exception is `gh pr merge` at the final gate.** That is a delivery
  action, not bookkeeping: if it fails (merge conflict, failing required check,
  protected-branch rule), the orchestrator **reports it and waits for instruction** —
  it does not silently continue and does not retry blindly.

## Rules

- Activation is ONLY via `kanban.enabled: true`, recorded by `sdd-init` after the
  `gh` prerequisite checks pass — zero heuristics.
- Never hardcode board option names; always map the board's REAL Status options to
  the 5 canonical stages during onboarding, confirming with the user on mismatch. The
  module manages ONLY those 5 stages; any other column is ignored.
- Backlog → Ready is a human prioritization decision — never promote a Backlog card
  unprompted; when there is no specific request, take the top of Ready or ASK.
- The orchestrator moves cards inline; phase executors never do.
- Every harness-created issue/card is assigned to the creator (`@me` by default;
  `kanban.user` overrides).
- Work taken from a card branches as `type/{issue}-{slug}`; the branch number and the
  PR body's `Closes`/`Refs` number are the same issue.
- PR base = default branch → `Closes #{issue}`; base ≠ default → `Refs #{issue}` plus
  an explicit `gh issue close` after the merge.
- Lifecycle `gh` failures are WARNINGs that never block; only the final `gh pr merge`
  failure pauses for human instruction.
- The final OK is always an explicit human gate (even in `execution_mode: auto`), and
  requires all three preconditions — explicit per-PR OK, a rebased+re-verified branch,
  and a fresh `gh pr checks` pass — before the canonical merge → verify → (Refs close)
  → Done → checkout order.
- Do NOT run live `gh` or network commands as part of authoring or testing this
  module — it is a markdown protocol; the commands run only in a real, configured
  project during an actual SDD cycle.
