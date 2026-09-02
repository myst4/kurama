# SDD Phase — Common Protocol

Boilerplate identical across all SDD phase skills. Sub-agents MUST load this alongside their phase-specific SKILL.md.

Executor boundary: every SDD phase agent is an EXECUTOR, not an orchestrator. Do the phase work yourself. Do NOT launch sub-agents, do NOT call `delegate`/`task`, and do NOT bounce work back unless the phase skill explicitly says to stop and report a blocker.

## Canonical Phase DAG (single source of truth)

This is the ONE canonical declaration of the SDD dependency graph. Every other file (phase skills, docs, conventions) MUST point here instead of restating the order:

```
explore → propose → (spec ‖ design) → tasks → apply → verify → archive
```

- `explore` has no upstream dependencies; its output is optional input to `propose`.
- `propose` depends on `explore` when an exploration exists (optional otherwise).
- `spec` and `design` both depend on `propose` and MAY run in parallel (`‖`). When parallelized, each treats the other's output as optional; `tasks` is the reconciliation point.
- `tasks` depends on `propose`, `spec`, and `design` (all required).
- `apply` depends on `tasks`.
- `verify` depends on `apply`.
- `archive` depends on a passing `verify` report.

Which specific upstream artifacts a phase treats as REQUIRED vs OPTIONAL is stated in that phase's SKILL.md; the retrieval-failure semantics for both classes live in Section B below.

### Change size and the collapsed path

The DAG above is the `standard` path and is unchanged. `sdd-propose` classifies every change
as `small` or `standard` and records it in the proposal's `## Change Size` section; for a
`small` change it writes the spec and the design as sections INSIDE the proposal, and the
orchestrator runs:

```
explore → propose → tasks → apply → verify → archive
```

This **collapses artifacts, it does not remove them**. `tasks` still requires a spec and a
design, and `archive` still requires a delta spec to merge into the main specs — they are read
from the proposal's `## Spec (inline)` and `## Design (inline)` sections instead of from
separate artifacts. Skipping them outright would deadlock at both phases.

Resolution rules, binding on every orchestrator and phase:

- An absent or unrecognized `## Change Size` means **`standard`**. Changes created before this
  section existed carry none; they MUST continue on the long path, and no phase may fail on
  the missing section.
- A `small` change MUST NOT be blocked for a missing standalone `spec` or `design`.
- A `small` change whose inline spec is missing or carries no requirements MUST be blocked with
  `next_recommended: sdd-propose` — a partial delta merged into the main specs is worse than
  no archive at all.

## Phase I/O (which artifacts each phase reads and writes)

The read/write contract per phase. The orchestrator passes artifact REFERENCES (file paths),
never content; a phase with required dependencies reads them itself via Section B.

| Phase | Reads | Writes |
|-------|-------|--------|
| `sdd-explore` | nothing | `explore` |
| `sdd-propose` | exploration (optional) | `proposal` |
| `sdd-spec` | proposal (required) | `spec` |
| `sdd-design` | proposal (required) | `design` |
| `sdd-tasks` | spec + design (required) | `tasks` |
| `sdd-apply` | tasks + spec + design | `apply-progress` |
| `sdd-verify` | spec + tasks | `verify-report` |
| `sdd-archive` | all artifacts | `archive-report` |

For a `small` change the spec and design arrive as inline sections of the proposal (see
*Change size and the collapsed path* above); the dependency is satisfied, not skipped.

## A. Project Standards

The project declares what binds you in the `standards:` list of `openspec/config.yaml` — an
ordered list of file paths, repo-relative or `~`-relative (schema and semantics:
`openspec-convention.md` → *Config File Reference*). Nothing is discovered at runtime and
nothing is matched by trigger: a file binds you because the project wrote it in that list.

1. **Read the list.** The orchestrator normally forwards it verbatim in your launch prompt as
   a `## Project Standards (files to read)` block; when it did, that block IS the list — use
   it as sent and do not re-derive it. When no such block arrived, read `standards:` from
   `openspec/config.yaml` yourself.
2. **Read every listed path IN FULL, in the listed order, before starting phase work**, and
   follow what each file says strictly. The file itself is the standard — there is no digest,
   no summary, and no second surface to prefer over it.
3. **A path you cannot read is LOUD, never a silent skip and never a block.** Add one line to
   `risks` — `standards: {path} not found` — and continue the phase. A standard the project
   declared and nobody read must be visible in the return.
4. **An absent or empty `standards:` list means the project declares no standards.** Proceed
   with your phase skill only; that is a correct run, not a degraded one.

An explicit `SKILL: Load` instruction in your launch prompt is honored the same way — read
those exact files in full. When both arrive, the `## Project Standards` block is authoritative
and a `SKILL: Load` repeating it is redundant.

## B. Artifact Retrieval

Read every upstream artifact from its file under `openspec/`. The exact paths are in
`openspec-convention.md`; the read and failure semantics are in `persistence-contract.md`.

Which upstream artifacts are required vs optional for your phase is declared in your phase
SKILL.md. When in doubt, treat a dependency drawn as a solid edge in the DAG as required and a
parallel-branch sibling (`spec ‖ design`) as optional. A missing REQUIRED artifact means
`status: blocked` naming it in `executive_summary`, with `next_recommended` set to the phase
that produces it; a missing OPTIONAL one is a note in `risks`.

## C. Artifact Persistence

Your artifact file under `openspec/` was already written during the phase's main step — that
file IS the persistence, and there is no second store. Path and shape: `openspec-convention.md`.
Write-failure handling, and the `.kurama/` cycle markers that `sdd-verify` and `sdd-archive`
also write: `persistence-contract.md`.

## D. Return Envelope

This envelope is the **ONLY** return contract for every SDD phase (including `sdd-init`). It is authoritative: where any per-skill "Return Summary" wording differs in field names or shape, **this section wins** — treat a phase's own summary format as the human-readable content that goes inside `detailed_report`, not as a second contract. Do not emit two competing return shapes.

Every phase MUST return a structured envelope to the orchestrator:

- `status`: `success`, `partial`, or `blocked`
- `executive_summary`: 1-3 sentence summary of what was done (name the missing artifact here when `status: blocked`)
- `detailed_report`: (optional) full phase output — this is where a phase's own "Return Summary" format lives; omit if already inline
- `artifacts`: list of artifact keys/paths written (include any `.kurama/sdd/` fallback path used)
- `next_recommended`: the next SDD phase to run, or "none"
- `risks`: risks discovered or fallbacks used; "None" if there are none
- `skill_resolution`: how the project's standards were loaded — `injected` (received the `## Project Standards (files to read)` block from the orchestrator), `fallback-path` (no block arrived; read `standards:` from `openspec/config.yaml`, or an explicit `SKILL: Load` path, directly), or `none` (the project declares no standards). This field is REQUIRED in every envelope.
- `key_learnings`: the envelope's CLOSING section — 1-5 gotchas, edge cases, or non-obvious decisions this phase discovered. Omitted entirely when the phase found nothing non-obvious. Shape and rules below.

Example:

```markdown
**Status**: success
**Summary**: Proposal created for `{change-name}`. Defined scope, approach, and rollback plan.
**Artifacts**: `openspec/changes/{change-name}/proposal.md`
**Next**: sdd-spec or sdd-design
**Risks**: None
**Skill Resolution**: injected — 3 standards read (CLAUDE.md, .claude/skills/api-conventions/SKILL.md, docs/testing.md)
(other values: `fallback-path`, or `none — no standards declared`)
```

### Key Learnings — the envelope's closing section

Close the final report message with a `## Key Learnings` section: a **numbered list of 1-5
items**, each a gotcha, an edge case, or a non-obvious decision this phase discovered. Whatever
memory engine the developer runs — claude-mem, something else, or none at all — harvests these
**verbatim**, with no model re-reading them, so the shape below is a contract and not style
advice:

- Each item is a **standalone factual sentence of at least 20 characters and 4 words**. Those
  two numbers are the usual extraction thresholds, not a readability preference: an item under
  either one is dropped silently, and nobody is told. Do not "simplify" them away.
- Write each item so it survives on its own — **what** was learned, **why it matters**, and
  **where** it lives (repo-relative path, module, or artifact key). The reader is a future
  session with no memory of this cycle.
- **Omit the whole section when the phase learned nothing non-obvious.** An empty or padded
  section is noise that dilutes every real learning around it. Omission is a correct return,
  never a contract violation — no phase is ever blocked for having no learnings.
- **Never restate the phase's main output.** `executive_summary` already says what was done;
  a learning is what the next person would otherwise rediscover the hard way.
- **Never write a secret, a token, or an absolute machine path.** These lines are persisted
  and re-read across sessions and machines; keep every path repo-relative.

This applies to the **final text response to the orchestrator** — not to intermediate tool
output, and not to the artifact body persisted in Section C.

```markdown
## Key Learnings
1. `sdd-verify` reads the test runner from the pipeline settings, not from the repo lockfile, so a monorepo with two runners verifies only the configured one.
2. A MODIFIED delta block must carry every scenario of the requirement it modifies; a partial block deletes the omitted scenarios at archive time (`skills/_shared/openspec-convention.md`).
```

**How this relates to team memory.** Kurama does not manage the developer's own memory tooling;
whatever engine they run — or none — reads this section passively. What Kurama *does* own is
`sdd-learn`, which curates the **team's** committed `MEMORY.md` at cycle close, and these items
are its richest raw input. It still applies its own admission test ("would a teammate waste an
hour rediscovering this?"), so a learning written here is a *candidate*, not an entry. The store
boundary is the table in `docs/persistence.md`.

Skipping the section leaves `sdd-learn` reconstructing the cycle from artifacts that, by the
rule above, deliberately do not contain it.
