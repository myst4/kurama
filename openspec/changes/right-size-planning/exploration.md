# Exploration — right-size-planning

Investigation behind a four-part change to the SDD workflow contract. Findings are
recorded with the evidence that produced them; nothing here is inferred.

## Question

The workflow has a flat floor: the smallest possible change pays the same ceremony as
the largest. Six artifacts (exploration, proposal, spec, design, tasks, verify-report)
are produced before and around code, regardless of size. Is there a shorter path that
does not break the contract, and what else is carrying weight it has not earned?

## Finding 1 — there is no notion of change size anywhere

Searched `small change`, `trivial`, `skip phase`, `change size`, `lightweight`, `minor`
across all nine phase skills and `skills/_shared/`. **Zero matches.** The only existing
lever is `sdd-ff`, and its own description is explicit: it skips *inter-phase gates*,
not phases. Every artifact is still produced.

## Finding 2 — spec and design cannot simply be skipped

The obvious shortcut (S-sized change → `propose → tasks → apply → verify`) **deadlocks**:

| consumer | declares | evidence |
|---|---|---|
| `sdd-tasks` | proposal + spec + design all **required** | `skills/sdd-tasks/SKILL.md:31` |
| `sdd-archive` | missing delta spec → `blocked`, `next_recommended: sdd-spec` | `skills/sdd-archive/SKILL.md:35` |

`sdd-archive` merges the delta spec into the cross-change main specs — the source of
truth. Without a spec there is nothing to merge, and the main specs silently drift away
from the code. So the shortcut is not "skip the phases"; it is **collapse the artifacts**:
`propose` emits a lightweight combined spec+design section for small changes, and the
downstream consumers still receive what they require.

## Finding 3 — spec is already optional for design (and the agent description contradicts it)

The parallel branch `(spec ‖ design)` is real and already declares the relationship:

- `skills/sdd-design/SKILL.md:28` — proposal (required), spec (**optional**)
- `skills/_shared/sdd-phase-common.md:17` — "each treats the other's output as optional;
  `tasks` is the reconciliation point"

But the native agent description says something else:

- `examples/claude-code/agents/sdd-design.md:3` — "produce the design document … from its
  proposal **and specs**. May run in parallel with sdd-spec."

Both halves sit in one sentence and contradict each other: if it runs in parallel with
`sdd-spec`, the specs may not exist yet. The SKILL.md marks the dependency optional; the
agent description does not. A reader who trusts the description will treat a missing spec
as a blocker.

## Finding 4 — the `none` mode is a wide, low-value branch

`none` means "persist no SDD artifacts", in a workflow whose premise is that specs are the
source of truth. Its cost is not one enum value:

- **76 mode-specific references** (backticked `none` or `| none`) across `skills/` and `docs/`
- concentrated in `_shared/persistence-contract.md` (14), `sdd-init` (8), `sdd-archive` (5),
  `docs/persistence.md` (5), `docs/smoke-test.md` (5)
- every phase skill carries a `none` branch in its persistence section

The persistence layer overall is the heaviest part of the shared core: `persistence-contract.md`
(239) + `openspec-convention.md` (221) + `engram-convention.md` (203) = **663 of 1101 lines
in `skills/_shared/`** — 60% of the shared core describing where files go.

## Finding 5 — sdd-verify does two jobs

431 lines, **2.4× the ~180-line average** of the other phase skills. Its step list splits
cleanly along a seam:

| steps | job |
|---|---|
| 1–5d | gather evidence: completeness, static spec match, design coherence, run tests/build/coverage |
| 6–6b | judge and bind: compliance matrix, TDD audit, content-binding receipt |
| 7–8, Verification Report | render and persist the report |

Evidence-gathering and verdict-rendering are separable concerns; the compliance matrix is
where `compliance_mode` (behavioral/static) changes meaning, and it is buried behind four
execution steps.

## Constraints discovered

- `sdd-ff` always fast-forwards in `auto` regardless of `execution_mode`; `apply` stays a
  human gate in every mode; `archive` is never auto-run.
- Phases are EXECUTORS: they may not delegate. Only `sdd-new`/`sdd-continue`/`sdd-ff`
  orchestrate. Any size decision must therefore be made by a phase that already runs
  (`propose`) or by the orchestrator — not by a new delegating phase.
- Generated harness configs under `examples/<harness>/` are built from
  `examples/_templates/` by `scripts/build-examples.sh` and must never be hand-edited.
- The repo ships a public 5.0.0. Anything that changes an existing install's config schema
  or phase contract is a breaking change and must be called out as such.

## Recommendation carried into the proposal

Four parts, ordered by value: (1) the size-aware planning path, which is the only one that
changes the workflow's floor; (2) the `sdd-design` description fix, which is a one-line
correction of a live contradiction; (3) splitting `sdd-verify`; (4) removing `none`, the
only breaking piece.
