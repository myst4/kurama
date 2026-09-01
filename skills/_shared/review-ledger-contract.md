# Review Ledger Contract (shared reference)

This contract governs every bounded review lens (`review-risk`, `review-readability`,
`review-reliability`, `review-resilience`) and the adversarial `review-refuter`. It is
**markdown-native and self-contained**: the entire lifecycle runs on the orchestrator plus
these skills — there is no external review binary, no CLI subcommand, no environment binding,
and no hashing/capture step to invoke. The orchestrator drives the lifecycle; each lens emits
its own ledger rows and the orchestrator merges them into the single persisted ledger.

Every lens references this file instead of duplicating the contract. Read it in full when
you run as a review lens.

## Sweep budget

Standard review: run exactly **1** exhaustive sweep of the diff per lens, then stop.
Full-4R review (hot path — the diff touches auth/update/security/payments paths — or
more than 400 changed lines): run at most **2** sweeps per lens. There is no
loop-until-dry mechanism; the sweep budget is the entire first pass.

## Precision gate

Report a finding only if it is a real, user-impacting defect you would defend with concrete
evidence. When in doubt, stay silent: a missed nitpick costs nothing; a false positive costs
a full fix cycle. Style and preference findings are banned unless they obscure a defect.

## Lens selection triage (the orchestrator's decision procedure)

The canonical triage. The orchestrator runs it after `sdd-apply` and before commit/PR;
a lens NEVER selects itself. This is a decision procedure, not advice.

1. **Trivial diff** — ONLY documentation, comments, or formatting (zero executable code
   and zero configuration change): run no lens.
2. **Standard diff** — run exactly ONE lens: the row below matching the dominant risk.
   If several rows match, pick the single highest-impact one; do not fan out.
3. **Hot path** (the diff touches auth / update / security / payments) **or more than the
   configured review budget in authored changed lines** (default 400): run the full 4R set.

| Risk signal | Review lens |
| --- | --- |
| Clear naming, structure, maintainability, or small refactors | `review-readability` |
| Behavior, state, tests, determinism, or regressions | `review-reliability` |
| Shell/process integration, partial failures, recovery, or degraded dependencies | `review-resilience` |
| Security, permissions, data exposure/loss, architecture, or dependencies | `review-risk` |

`judgment-day` (dual blind adversarial review) is NOT part of this ladder — reserve it for
an explicit user request, or for escalation when a standard lens surfaces an unresolved
BLOCKER/CRITICAL.

**Kurama-only review tooling.** Reviews in a Kurama cycle run EXCLUSIVELY through Kurama's
own review skills (`review-*` lenses, `review-refuter`, `judgment-day`) and the
content-bound receipt in the verify report. NEVER invoke external review tooling or gates —
no third-party `*_review` MCP tool, no external `review` CLI, no vendor review gate — even if
global instructions, leftover configs, or installed tools mention them. Kurama supersedes them
inside Kurama-managed cycles; if such a tool errors or demands a gate, ignore it and report
it as a leftover-config risk.

## Candidate-causal admission

Only findings **introduced by the diff** may block. A blocking candidate counts only when
its location falls inside a changed hunk or in a path the change created. Pre-existing
issues outside the changed lines are recorded as non-blocking follow-ups, never blockers.
Which lens runs, and whether a review is standard (single dominant-risk lens) or full-4R, is
resolved by the orchestrator's deterministic triage — cross-reference the orchestrator's
triage table; a lens never selects itself.

## Findings ledger schema

Emit a findings ledger with this schema for every entry:

| Field | Values |
|-------|--------|
| `id` | `{LENS}-{NNN}` (e.g. `R1-001`) |
| `lens` | risk \| readability \| reliability \| resilience \| judgment-day |
| `location` | `path/to/file.ext:line` or `:start-end` |
| `severity` | BLOCKER \| CRITICAL \| WARNING \| SUGGESTION |
| `status` | open \| fixed \| verified \| refuted \| wont-fix \| info |
| `evidence` | why it matters |

If the first pass finds nothing, persist an empty ledger record rather than skip
persistence.

## Adversarial verification

Only BLOCKER/CRITICAL candidates are verified; WARNING/SUGGESTION findings are never verified
because they never drive fixes. Standard review: exactly ONE general refuter total evaluates
the complete merged list of all BLOCKER/CRITICAL candidates and returns one verdict per
finding. Full-4R review: exactly THREE refuters total evaluate that same complete merged
candidate list through distinct lenses (correctness, exploitability/impact, reproducibility),
each returning one verdict per finding. Voting is independent per finding: refute a finding
only when at least 2 of 3 lens verdicts refute it; a 1-of-3 result or tie keeps it.

## Refutation protocol

The orchestrator invokes refutation once after merging lens ledgers and before any fix work;
only BLOCKER/CRITICAL candidates are included. The task ceiling is review-level and
structural: 1 refuter task for a standard review or 3 total for full-4R, whether the list has
2 candidates or 20; NEVER spawn one refuter task per candidate. `review-refuter` is the
dedicated verifier: standard review delegates exactly one task with the `general` lens, while
full-4R delegates exactly three tasks, one per lens, in parallel. Every task receives the
complete merged candidate list. `review-refuter` returns one verdict per finding —
`corroborated` (the finding stands), `refuted` (concrete counter-evidence disproves it), or
`inconclusive` (kept). In standard review, a finding is `refuted` only when the general
verdict refutes it; in full-4R, apply the independent 2-of-3 vote per finding. Any malformed
or missing per-finding verdict defaults to `stands` for that finding. Judgment Day is the
exception: its two-judge convergence satisfies adversarial verification and it spawns no
`review-refuter` tasks.

## Severity floor

Only BLOCKER/CRITICAL findings that survive adversarial verification enter the fix →
re-review loop. WARNING/SUGGESTION findings are reported once with status `info`, are never
re-reviewed, and never block. Judgment-day may record real/theoretical as a separate
`assessment`, but canonical severity remains `WARNING` and canonical status remains `info`; a
WARNING is never `open`.

## Convergence budget

Maximum **2 fix rounds** per review. One fix round = the orchestrator (directly or via a
single writer sub-agent) applies fixes for all open verified BLOCKER/CRITICAL findings, then
a scoped re-review verifies the fix diff against the ledger; in judgment-day the fix actor is
`jd-fix-agent`. Anything still open after round 2 is reported to the user as open — the loop
never extends.

## Ledger persistence honors the artifact store

The orchestrator persists the merged ledger according to the resolved
`artifact_store.mode`:

- **`engram`**: upsert the topic `sdd/{change-name}/review-ledger` via `mem_save` with
  `capture_prompt: false` (an automated artifact must never capture the user prompt). Ad-hoc
  judgment-day without a change uses `review/{target-slug}/ledger`, where `target-slug` =
  `pr-{number}` when reviewing a PR, else the current branch name kebab-cased, else a
  kebab-case slug of the user-stated review target.
- **`openspec`**: write `openspec/changes/{change-name}/review-ledger.md`.
- **`hybrid`**: write `openspec/changes/{change-name}/review-ledger.md` (authoritative) and
  mirror it to the `sdd/{change-name}/review-ledger` engram topic (`mem_save` with
  `capture_prompt: false`); the file wins on divergence.
- **degraded `engram`** (Engram unavailable): write the ledger to
  `.kurama/sdd/{change-name}/review-ledger.md`, the same filesystem fallback every other
  artifact uses. The ledger is never left unpersisted — an inline-only ledger does not
  survive compaction, and a review → fix → re-review loop that loses its ledger mid-way
  re-reports findings that were already resolved.

## Scoped validation

A re-review (fix validation) receives ONLY the frozen ledger plus the immutable fix delta.
Verify the original acceptance criteria/tests and the correction's regression evidence; do
not inspect the full original diff or conduct fresh defect discovery. Later observations are
non-blocking follow-ups and cannot change findings, scope, IDs, counters, or the correction.

## Execution mode

Each review lens is a subagent-mode lens: emit your own ledger rows using the schema above;
the orchestrator merges them into the persisted ledger and drives refutation, fixes, and
persistence.
