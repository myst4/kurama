# Orchestrator SDD Protocol (shared reference)

The orchestrator's session-level protocol for running an SDD cycle: resolving the
session settings, routing a natural-language request into the pipeline, and gating
phases in `auto` mode.

**Load this when an SDD cycle starts, not before.** None of it applies to a session
that never invokes SDD, and the `auto` gatekeeper below applies only when
`execution_mode` resolves `auto`. The orchestrator prompt carries the trigger; this
file carries the procedure.

## SDD Session Preflight

Before ANY SDD phase runs in a session — `/sdd-new`, `/sdd-ff`, `/sdd-continue`, the
executor skills, or a natural-language equivalent ("use SDD to add X", "do it with
SDD") — RESOLVE the Preflight block of four values.

**Resolving does NOT mean asking:**

- **Silent path (the normal case)**: read the persisted settings (`openspec/config.yaml`
  or the `sdd-init/{project}` settings bundle). If ALL FOUR values resolve from there,
  DO NOT ask anything — print a one-line status in the user's language (e.g.
  "Preflight: supervisado · openspec · chained · 400 — decime si querés cambiar algo
  esta sesión") and start working. `sdd-init` already asked these once; re-asking
  answered questions is friction, not safety.
- **Ask ONLY the missing pieces**: if some values have no persisted answer (project
  never initialized, or a setting absent), ask ONLY those, in one grouped prompt.
- **Explicit override**: if the user asks to change the setup ("preflight", "cambiá el
  ritmo", "usá auto"), ask or apply just that change for the session.
- **Artifact store is PROJECT-level, not session-level**: once `sdd-init` set it, never
  re-offer it in a preflight. Switching stores mid-project fragments artifacts — only
  change it on an explicit user request, with that warning.

The four values (when something does need asking):

1. **Pace** — Interactive or Automatic. This IS `execution_mode`: Interactive →
   `supervised`, Automatic → `auto`. Same value as *Execution Mode* in the orchestrator
   prompt, not a parallel concept.
2. **Artifact store** — OpenSpec, Engram, or Both (`hybrid`). Offer only file-safe
   choices when Engram is not callable.
3. **Delivery** — Ask on risk, Single PR, Chained, or Auto-chain. Feeds the Delivery
   Strategy consumed by `skills/branch-pr` (`ask-on-risk` | `single-pr` | `chained` |
   `auto-chain`).
4. **Review budget** — maximum authored changed lines before stopping for
   reviewer-burden approval (default `400`), feeding the Review Workload Guard.

**Rendering.** On Claude Code, use the native `AskUserQuestion` tool with all four
groups in ONE call so they render as a single interactive prompt — never four separate
calls, never the menu pasted as chat text. On harnesses without that primitive, ask ONE
grouped text question covering the same four groups. Match the user's conversation
language and active persona for the labels: this UI is orchestrator conversation, not a
technical artifact. Never show internal codes or canonical values in the UI; map the
chosen labels to canonical values internally after the prompt returns.

**Precedence.** A value the user chose THIS session (grouped prompt or explicit
override) wins over the persisted one, for this session only. Persisted settings SATISFY
the preflight on their own — that is the point of `sdd-init`. Cache the resolved block
for the session and forward the four values in every phase prompt.

## SDD Entry Routing

A natural-language SDD request starts the pipeline at its ENTRY, never at a loose
executor phase. Route "build X with SDD" / "implement X with SDD" through the Preflight
above and then `/sdd-new` (explore + proposal) — never straight to `sdd-apply` just
because the user asked to implement something.

Only launch `sdd-apply` when ALL hold:

1. The Preflight block exists for this session.
2. The active change already has `spec`, `design`, and `tasks` artifacts (for a `small`
   change, the inline spec/design sections of the proposal satisfy this — see
   `sdd-phase-common.md` → *Change size and the collapsed path*).
3. The user explicitly asked to apply/continue, OR the prior planning phase completed
   and the Review Workload Guard has been cleared.

If any dependency is missing, STOP and propose `/sdd-new` or `/sdd-ff`; do not implement.

## Automatic Mode Gatekeeper

**Applies only when `execution_mode` resolves `auto`.** In `auto` the orchestrator is the
gate between phases: after every delegated phase returns and BEFORE launching the next
sub-agent, validate the result against the Section D envelope. This is autonomous
validation — it never asks the user (that is `supervised`); it surfaces only when it
catches a problem.

Checks (every phase):

- **Contract conformance** — the envelope carries `status`, `executive_summary`,
  `artifacts`, `next_recommended`, `risks`, and `skill_resolution`, and `status` is
  `success` (not `partial` or `blocked`, and no verify FAIL).
- **Artifact existence** — the declared artifact is actually retrievable from the active
  backend; read it back (engram: `mem_search` + `mem_get_observation` on the topic key;
  openspec: read the file). A phase that claims success but produced no retrievable
  artifact FAILS the gate.
- **No hallucination** — spot-check the concrete claims; every cited path, symbol, or
  command must resolve. A dangling reference FAILS the gate.
- **No drift from inputs** — the output stays within its DAG inputs: spec inside the
  proposal, design answering the proposal, tasks covering spec + design, apply
  implementing the tasks. Invented requirements or dropped scope FAIL the gate.
- **Routing coherence** — `next_recommended` follows the phase DAG and no unaddressed
  CRITICAL risk remains.

Cost-aware validation:

- **Inline** for low-risk phases (`sdd-explore`, `sdd-spec`, `sdd-tasks`,
  `sdd-archive`): run the checks yourself by reading the artifact back — no extra
  sub-agent.
- **Fresh-context phase-contract validator** for `sdd-design` and `sdd-apply`: validate
  only the phase artifact against its inputs. This is NOT adversarial implementation
  review, inspects no code diff, and opens no review lens or Judgment Day budget.
- If an inline check smells wrong (status mismatch, unresolved path, suspected drift,
  missing artifact), escalate that phase to a fresh-context validator before deciding.

**On PASS**: continue automatically — auto stays auto on the happy path.
**On FAIL**: re-run the same phase exactly once with corrective feedback naming the
specific failures found (no blanket retry), then re-gate. If it fails again, STOP the
chain and report the phase, what was caught across both attempts, and the recommended
fix. Never advance dependent phases on a failed gate — a bad artifact compounds
downstream.

This gate runs on top of the Review Workload Guard and lens selection; it never relaxes
them and never auto-marks anything reviewed in engram.
