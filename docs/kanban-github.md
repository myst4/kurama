# Kanban Module (optional)

The Kanban module keeps a **GitHub Projects (v2) board** in sync with the SDD
cycle. Every issue the harness works on has a card, and as the change moves
through planning, implementation, review, and delivery, the orchestrator moves
that card through the board's Status column. The board is **bookkeeping** — a live
view of where each change stands — never a control-flow gate (the sole exception
is the final merge; see [Failures never block the cycle](#failures-never-block-the-cycle)).

Like the [TDD module](tdd.md), the module now **installs by default** (remove it
from disk with `--without optional`), but activation is **opt-in per project** —
the board stays OFF until you explicitly enable it, and nothing infers it from an
existing project or a configured `gh`. For quick start, see the
[main README](../README.md).

**Installing the module is not activating it.** Shipping `skills/kanban-github/SKILL.md`
on disk only makes the sync *available*; every project still opts in on its own
terms, and activation additionally **requires a configured GitHub CLI (`gh`)**. The
protocol reference — which `gh` command runs at which boundary — lives in one
place: [skills/kanban-github/SKILL.md](../skills/kanban-github/SKILL.md).

## Activation — one switch, no silent heuristics, `gh` required

The board activates ONLY through an explicit `kanban.enabled` flag, and only after
the `gh` prerequisite passes. An existing GitHub Project, a configured `gh`, or the
skill being installed **never** auto-activate it — there are **zero heuristics**.
`sdd-init` asks the enable question explicitly (default `false`), in the same place
and manner it asks the TDD question.

Where the flag lives is mode-dependent — the same settings-home rule as
[compliance_mode](persistence.md#where-pipeline-settings-are-configured) and
[tdd](tdd.md#activation--one-switch-no-silent-heuristics):

| Mode | Where the `kanban` block lives |
|------|--------------------------------|
| `openspec` / `hybrid` | The top-level `kanban:` block in `openspec/config.yaml`, written by `sdd-init`. |
| `engram` | The `kanban` block in the `sdd-init/{project}` context artifact (there is no `config.yaml` in these modes). |

The orchestrator reads the block once and propagates it into every phase, exactly
as it does for `compliance_mode`, `tdd`, and `execution_mode` — the propagated
value wins on conflict.

## Prerequisite — a configured GitHub CLI

Activation REQUIRES a working `gh`. When you answer "yes" to the kanban question,
`sdd-init` runs three checks **in order** and records `kanban.enabled: true` only
once all three pass. If any check fails, it prints the exact fix command, records
`kanban.enabled: false`, and continues init normally — a missing prerequisite is
never fatal, and you can re-run `/sdd-init` once it is in place.

| # | Check | Command | Fix on failure |
|---|-------|---------|----------------|
| 1 | Installed | `gh --version` | `brew install gh` (macOS) or see <https://cli.github.com> |
| 2 | Authenticated | `gh auth status` | `gh auth login` |
| 3 | `read:project,project` scopes (read + write) | `gh project list --owner @me --limit 1` | `gh auth refresh -s read:project,project` |

There is also a module-presence preflight (parallel to TDD's): because `kanban-github`
ships in the excludable `optional` group, `sdd-init` confirms `kanban-github/SKILL.md`
resolves before offering the question. If the module was excluded with
`--without optional`, `sdd-init` does not offer activation and records
`kanban.enabled: false` with a note to reinstall.

## Onboarding — `sdd-init` caches the board wiring

After the `gh` checks pass, `sdd-init` discovers and confirms the board wiring,
then persists it. Every later card move reuses these cached values — there is no
rediscovery per phase. Each value is confirmed with you:

1. **Assignee** — the default is `@me`: every issue and card the harness creates is
   assigned to whoever created it (the active `gh` account). `kanban.user` is an
   OPTIONAL override — leave it empty for `@me`, or set a fixed login.
2. **Owner / repo** — the owner is deduced from the git remote
   (`git remote get-url origin`) and confirmed; the repo name is captured.
3. **Project** — `gh project list --owner {owner}`; you pick the target project, its
   `number` is captured, and `project_id` (the `PVT_...` node id) is cached via
   `gh project view {project_number} --owner {owner} --format json --jq '.id'`.
4. **Status field + options** — `gh project field-list {project_number} --owner
   {owner} --format json` captures the single-select **Status** field `id` and each
   option `id`.
5. **Stage mapping** — the board's REAL Status options are mapped to the 5 canonical
   stages. **Names are never hardcoded**: if your board uses different labels (e.g.
   `Todo` for Ready, `Shipped` for Done), `sdd-init` confirms the mapping with you.
   Only these 5 stages are managed — any other board column (e.g. a `Resources`
   column) is IGNORED, and cards are never moved there.
6. **Merge method** — you choose the method the final gate uses: `merge` | `squash`
   | `rebase` (default `squash`), stored as `merge_method`.
7. **Size field (optional)** — if the board has a single-select **Size** field, its
   `size_field_id` + a `sizes` map (`xs`/`s`/`m`/`l`/`xl` → option id) can be cached;
   absent, the feature is skipped without error, and setting a size is always optional.

### The persisted `kanban` block

The canonical schema is byte-identical to the block in
[openspec-convention.md](../skills/_shared/openspec-convention.md) and the `sdd-init`
Step 3 template:

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

The `PVT_...` ProjectV2 node id required by `gh project item-edit --project-id` is
**cached** as `project_id` during onboarding (captured once with `gh project view`),
so no card move re-looks it up.

## The 5 stages and what moves each card

Cards flow through five canonical stages, mapped during onboarding to your board's
real Status options. Each move is triggered by an SDD phase boundary:

| Stage | What lands the card here | Kurama trigger |
|-------|--------------------------|----------------|
| **Backlog** | Issue created + assigned (`@me` by default) | [`skills/issue-creation`](../skills/issue-creation/SKILL.md) files the issue and adds the card. |
| **Ready** | Work on the issue actually starts (`/sdd-new` or `/sdd-continue` picks it up) | All planning lives here: explore → propose → spec/design → tasks. |
| **In Progress** | `sdd-apply` starts implementing | Moved when the apply phase begins writing code. |
| **In Review** | `branch-pr` opens the PR | The PR body carries `Closes #{issue}` (base = default branch) or `Refs #{issue}` (base ≠ default); the PR link is also posted as an issue comment. |
| **Done** | The user gives the explicit final OK → merge | merge → verify → (if `Refs`) close the issue → move to Done → return to the base branch (the human gate below). |

### Work intake — which card to pick, and when it reaches Ready

The board reflects work; the human owns prioritization:

- **Existing issue** → its card reaches **Ready** only when work actually STARTS.
- **A request with no issue** → the issue is born in **Backlog** (by `issue-creation`)
  and reaches **Ready** at start.
- **No specific request** → take the topmost **Ready** card; if Ready is empty, **ASK**.
- **Never pull from Backlog on your own initiative** — Backlog → Ready is the human's
  prioritization call.

### Who moves the cards

- **The orchestrator moves every card, inline.** `gh` is "Bash for state" in the
  delegation table, so the orchestrator issues the `gh project` / `gh pr` commands
  directly — no sub-agent, no delegation.
- **Phase executors NEVER touch the board.** `sdd-apply`, `sdd-verify`, and the other
  phase sub-agents implement and verify; they do not run board commands.
- The one exception to orchestrator ownership is the **initial Backlog placement**,
  which [`skills/issue-creation`](../skills/issue-creation/SKILL.md) does at issue
  creation time (two extra `gh` commands: add the card, assign the issue — `@me` by
  default, or the `kanban.user` override).
- After the PR opens, the orchestrator posts the PR link as an issue comment
  (`gh issue comment {issue} --body {pr-url}`) so the trail lives on the board;
  planning decisions MAY also be recorded as issue comments (optional, recommended).

The exact per-transition `gh` commands (`gh project item-add`, `gh project
item-edit --project-id --id --field-id --single-select-option-id`, `gh issue edit
--add-assignee`, `gh pr merge`) live in
[skills/kanban-github/SKILL.md](../skills/kanban-github/SKILL.md).

## Assignment rule

Every issue and card the harness creates is assigned to whoever created it — `@me`
(the active `gh` account) by default, or the `kanban.user` override when set. The
assignment happens once, in `skills/issue-creation`, at creation time
(`gh issue edit {issue-number} --add-assignee {user-or-@me}`); the orchestrator does
not re-assign on moves.

## The final merge is always a human gate

The user's final OK is **ALWAYS an explicit human gate** — never auto-merge, not
even in `execution_mode: auto`. Before the merge, ALL THREE hard preconditions must
hold: (a) an explicit OK for THIS PR (never implicit, inherited, or deduced from a
"looks good"), (b) the branch rebased onto its base and re-verified, and (c)
`gh pr checks {pr}` all passing, run IMMEDIATELY before the merge (fresh evidence,
never a remembered green). On that OK the orchestrator runs the canonical order:

1. Merges with the configured method (`gh pr merge {pr} --{merge_method}
   --delete-branch`, default `squash`).
2. Verifies the merge landed (`gh pr view {pr} --json state -q .state` → `MERGED`).
3. If the body used `Refs #{issue}` (non-default base), closes the issue explicitly
   (`gh issue close {issue}`).
4. Moves the card to **Done**.
5. Returns to the base branch (`git checkout {default-branch} && git pull`).

This is the one board-adjacent step allowed to stop the flow: if the merge fails
(merge conflict, failing required check, protected-branch rule), the orchestrator
reports it and **waits for instruction** — it does not silently continue and does
not retry blindly.

## Failures never block the cycle

**Kanban is bookkeeping, so a board that cannot be updated never halts a phase.**

- Any card-lifecycle `gh` command that fails (`item-add`, `item-edit`, `issue edit
  --add-assignee`) is recorded as a **WARNING** in the phase envelope's `risks`, and
  the development cycle **CONTINUES**.
- **The single exception is `gh pr merge` at the final gate** (above): it is a
  delivery action, not bookkeeping, so its failure pauses for human instruction.

## Installation vs activation

Two independent things, easy to conflate:

- **Installing the module** puts `skills/kanban-github/SKILL.md` on disk. It ships in the
  `optional` manifest group, **installed by default** — `setup.sh`/`install.sh`
  include it in the default set. Remove it with
  `--without optional` if you never want the module on disk (this also removes the
  it is now the only member of the group — `go-testing` moved to the opt-in `lang` group).
- **Activating the board** turns board sync on for a *specific project* via the
  explicit `kanban.enabled` flag, and requires a configured `gh`. Installing the
  module never activates it; the flag starts `false` everywhere, and no project state
  ever flips it on.

```bash
./scripts/install.sh --without optional   # exclude the kanban module from disk
```

If you excluded the group earlier, reinstall **without** the flag to put the module
back — the default install includes it. To turn an active board back off, set
`kanban.enabled: false` (or answer "no" on a re-run of `/sdd-init`); the next cycle
runs with no board behavior anywhere.
