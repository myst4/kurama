---
name: sdd-new
description: >
  Start a new SDD change: run exploration, then create a proposal, and gate before planning
  continues. This is a user-invocable ORCHESTRATOR entry point — invoke it as `/sdd-new <change-name>`.
  Trigger: When the user says "sdd new", "start a change", "nuevo cambio", "new SDD change",
  or asks to begin working on a named feature/fix through SDD.
license: MIT
metadata:
  author: kurama
  version: "1.0"
---

## What This Skill Is

`sdd-new` is a **meta-skill**: unlike the SDD phase skills (`sdd-explore`, `sdd-apply`, …), which
are EXECUTORS, this skill describes **orchestrator** behavior. It is the deliberate exception to the
executor rule — the same role the OpenCode meta-command `examples/opencode/commands/sdd-new.md` fills
by routing to the `sdd-orchestrator` agent. When this skill runs, YOU are the coordinator: you
delegate the real work to phase sub-agents (or the native `sdd-explore` / `sdd-propose` agents under
`examples/claude-code/agents/`) and synthesize their results. Do NOT do phase work inline.

It is user-invocable as `/sdd-new <change-name>`. `<change-name>` names the change and becomes the
`{change-name}` in every artifact path (`openspec/changes/{change-name}/...`). When the cycle is
issue-linked, that name carries the issue number — `{issue}-{slug}`, resolved at step 1.5.

## Orchestration Flow

### 1. Init check

Confirm SDD is initialized for this project — `openspec/config.yaml` exists. Check it with
`test -f` or Read, never a finder. If nothing is found, delegate `sdd-init` first (it detects the
stack, asks the explicit TDD question, and persists the pipeline settings) and present its summary
before continuing.

Read the pipeline settings (`execution_mode`, `compliance_mode`, `tdd.enabled`,
`tdd.single_test_command`) ONCE and propagate them into every sub-agent prompt — a propagated
value always wins over any stale value in `config.yaml`. `execution_mode` (`supervised` | `auto`,
default `supervised`) decides how the proposal gate below behaves.

**Stale `artifact_store.mode`.** If the config still carries an `artifact_store.mode` key with ANY value,
print exactly one line and continue — never block, never
rewrite the user's config:

> `artifact_store.mode` is unsupported since 6.3.0; artifacts are files under `openspec/`. Move
> `.kurama/sdd/<change>/*.md` to `openspec/changes/<change>/` if you want the old ones.

Then proceed with the cycle as normal.

### 1.5. Brainstorm gate

Before you delegate anything, decide how specified the request actually is — and let the user
override that call. This is the first human gate of the cycle, and it exists because a proposal
written from an ambiguous request is a well-formatted guess.

**Read the source first.** When the request names an issue (`#N`, a GitHub URL, "hagamos este
issue"), read its body with `gh issue view <N> --comments` before classifying — that is where
vague requests come from, and classifying the one-line ask instead of the issue is the same as
not classifying at all. `gh` is Bash for state, so this stays inline.

**Name the change from the issue.** When the cycle is issue-linked — the kanban module attached a
card, or the request named an issue (`#N`, a GitHub URL, "hagamos este issue") — the change name is
**`{issue}-{slug}`**: the number first, then the kebab slug (`22-nodemaven-gateway-provider`). That
name keys everything downstream — `openspec/changes/{change-name}/`, `.kurama/sdd/{change-name}/`,
the phase envelopes and `state.md` — so a name without the number
leaves every artifact untraceable to its ticket. If the user passed an unnumbered `<change-name>`
explicitly, **prefix their slug**; never replace it with one of your own. **No issue in play** →
unchanged: the plain `{slug}`. Announce the resolved name in ONE line before you delegate anything.
The rule binds at creation: an existing change created without a number keeps resolving under the
name it already has — never rename or re-derive one.

**Assess** the request — from the issue body, the natural-language ask, or the args — against
four questions:

1. Does it state a success criterion — something observable that says it is done?
2. Does it name the flow, module, or files it changes?
3. Does it touch ONE subsystem, or several independent ones?
4. Does its own wording leave a fork open ("faster", "cleaner", "algo así")?

Two or more misses → **vague**. Otherwise **clear**.

**Announce the classification in ONE line with its reason**, then ask ONE question with the
recommendation marked — the native question primitive per the Preflight's *Rendering* rule
(`AskUserQuestion` on Claude Code, `question` on OpenCode), two options plus its free text:

> This reads as **vague** — no success criterion, and "make it faster" could mean three
> different things. → **Brainstorm first (recommended)** / Go straight to explore → propose

For a **clear** request, present the mirror image with *Go straight to explore → propose*
recommended.

**By `execution_mode`:**

- **`supervised`** (default): always ask, both readings.
- **`auto`**: a **vague** request STOPS here and asks anyway — ambiguity has to resolve BEFORE
  artifacts are written, so this is a human gate like the implementation boundary, not a
  supervised-only prompt. A **clear** request passes through with a one-line note; do not ask.

If the user chooses to brainstorm, follow `skills/sdd-brainstorm/SKILL.md` **INLINE** — it is
dialogue, and a sub-agent has no human on the other side. It returns a decision ledger persisted
at `openspec/changes/{change-name}/brainstorm.md`. `sdd-brainstorm` ships in the `optional` group: if it does not resolve, say so
in one line and continue to Explore — never block the cycle on an optional module.

### 2. Explore

**First, check whether the exploration already happened.** `sdd-brainstorm` may have delegated a
full `sdd-explore` mid-round to answer a question the code could answer, and that run produced a
real artifact. Look for `openspec/changes/{change-name}/exploration.md` before delegating
anything:

- **Artifact present** — do NOT run a second exploration. Either pass it by reference and go
  straight to step 2.5, or delegate ONE refinement pass that receives both the existing exploration
  and the ledger and is told what is still unanswered. Two full explorations of the same change
  cost twice and produce two approach tables that can disagree.
- **No artifact** — delegate `sdd-explore` normally. Light inline reads during the brainstorm round
  (1–3 files) produce no artifact and require nothing here.

Delegate `sdd-explore` for `<change-name>` to investigate the codebase and compare approaches. Inject
the pipeline settings and any auto-resolved Project Standards. When step 1.5 produced a ledger, pass
it by reference (`openspec/changes/{change-name}/brainstorm.md`) as OPTIONAL upstream context —
never inline its body.
Present the exploration summary to the user.

### 2.5. Approach gate

`sdd-explore` returns 2–3 approaches with a recommendation. Do NOT delegate `sdd-propose` in the
same breath as the exploration summary: present the approaches with their trade-offs and the
recommendation marked, and ask ONE question — which one. This applies to clear requests too. The
approach is a decision, and a sub-agent picking it unobserved is exactly the gate this step holds.

In **`auto`**: take the recommendation and say which one in one line; do not ask.

### 3. Propose

Delegate `sdd-propose` to turn the exploration into a proposal (intent, scope, approach, rollback).
Pass the proposal's upstream (`openspec/changes/{change-name}/exploration.md`, and
`brainstorm.md` when a ledger exists) by reference — the sub-agent reads the files; do not inline
artifact bodies into the prompt. Name the approach chosen at step 2.5 in the prompt.

### 4. Proposal gate

This is the post-propose human gate; its behavior depends on `execution_mode`:

- **`supervised` (default)**: Present the proposal summary and **stop for the user** — ask whether to
  continue into specs and design (e.g. via `/sdd-ff <change-name>` or `/sdd-continue <change-name>`).
  Do NOT auto-advance past the proposal; `sdd-new` ends at this human gate.
- **`auto`**: Do NOT stop at the proposal gate. Auto-continue into the planning phases exactly as
  `/sdd-ff` does — `(spec ‖ design) → tasks` for a `standard` change, or straight to `tasks` for a
  `small` one — with no inter-phase prompts, halting only on a `status: blocked` return or when the
  implementation boundary is reached (after `tasks`, before `/sdd-apply`, which stays a human gate
  even in `auto`). Present ONE combined summary at the end.

Read the proposal's `## Change Size` section before sequencing the planning phases.
An absent or unrecognized size means `standard`.
For `small`, the spec and design already live inside the proposal, so their separate
delegations are skipped.

## Rules

- You are the ORCHESTRATOR here. Delegate every phase; never execute exploration or proposal work inline.
  The ONE exception is `sdd-brainstorm` at step 1.5: it is dialogue, so it runs inline like this skill.
- Classify the request at the brainstorm gate BEFORE exploring, and read the issue body first when the
  request names an issue. In `supervised` always ask; in `auto` a **vague** request still stops there
  and a **clear** one passes through.
- Name an issue-linked change `{issue}-{slug}` at step 1.5 and say so in one line — prefix a slug the
  user passed rather than replacing it. No issue in play leaves the name unchanged, and an existing
  unnumbered change is never renamed to satisfy this.
- Never delegate `sdd-propose` in the same breath as the exploration summary — the approach pick is a
  stop in `supervised`; in `auto` take the recommendation and say so.
- Never explore twice. If the brainstorm round already produced an `explore` artifact, reuse it or
  delegate a refinement pass — never a second full exploration of the same change.
- Resolve and propagate pipeline settings once; the propagated value wins on conflict.
- Pass upstream artifacts by reference (path), not by inlining their content.
- Honor `execution_mode` at the proposal gate: in `supervised` (default) stop and wait for explicit
  user go-ahead; in `auto` fast-forward into planning (`spec ‖ design → tasks`), stopping at the
  implementation boundary. The implementation boundary and archive stay gated in both modes, and so
  does the brainstorm gate for a request classified vague.
- Honor the return envelope: each delegated phase returns the **Section D** envelope from
  `skills/_shared/sdd-phase-common.md`; surface its `executive_summary` and `next_recommended`.
- Pass the brainstorm ledger downstream by reference when one exists; an absent ledger is normal and
  never blocks a phase.
- Reap each phase agent as soon as you have synthesized its envelope — the delegation is not
  complete until the agent is shut down, and the only reason to keep one alive is a follow-up
  message you name when you decide it (`skills/_shared/skill-resolver.md` → *Step 5*).
