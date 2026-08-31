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
SDD") — RESOLVE the Preflight block of three values.

**Resolving does NOT mean asking:**

- **Silent path (the normal case)**: read the persisted settings (`openspec/config.yaml`
  or the `sdd-init/{project}` settings bundle). If ALL THREE values resolve from there,
  DO NOT ask anything — print a one-line status in the user's language (e.g.
  "Preflight: supervisado · openspec · 400 — decime si querés cambiar algo
  esta sesión") and start working. `sdd-init` already asked these once; re-asking
  answered questions is friction, not safety.
- **Ask ONLY the missing pieces**: if some values have no persisted answer (project
  never initialized, or a setting absent), ask ONLY those, in one grouped prompt.
- **Explicit override**: if the user asks to change the setup ("preflight", "cambiá el
  ritmo", "usá auto"), ask or apply just that change for the session.
- **Artifact store is PROJECT-level, not session-level**: once `sdd-init` set it, never
  re-offer it in a preflight. Switching stores mid-project fragments artifacts — only
  change it on an explicit user request, with that warning.

The three values (when something does need asking):

1. **Pace** — Interactive or Automatic. This IS `execution_mode`: Interactive →
   `supervised`, Automatic → `auto`. Same value as *Execution Mode* in the orchestrator
   prompt, not a parallel concept.
2. **Artifact store** — OpenSpec, Engram, or Both (`hybrid`). Offer only file-safe
   choices when Engram is not callable.
3. **Review budget** — maximum authored changed lines before stopping for
   reviewer-burden approval (default `400`), feeding the Review Workload Guard.

**Delivery is NOT a preflight value.** How work is partitioned into PRs is decided at PR
time by the **Review Workload Guard** and **Delivery Strategy** in `skills/branch-pr`,
from a `git diff` measurement against the base — a measurement of the real change, not a
session setting chosen before the change exists. Do not resolve, ask for, or forward a
delivery/chaining value here: nothing downstream reads one.

**Rendering.** On Claude Code, use the native `AskUserQuestion` tool with all three
groups in ONE call so they render as a single interactive prompt — never three separate
calls, never the menu pasted as chat text. On harnesses without that primitive, ask ONE
grouped text question covering the same three groups. Match the user's conversation
language and the resolved persona (*Session identity* below) for the labels: this UI is
orchestrator conversation, not a technical artifact. Never show internal codes or canonical values in the UI; map the
chosen labels to canonical values internally after the prompt returns.

**Precedence.** A value the user chose THIS session (grouped prompt or explicit
override) wins over the persisted one, for this session only. Persisted settings SATISFY
the preflight on their own — that is the point of `sdd-init`. Cache the resolved block
for the session and forward the three values in every phase prompt.

### Session identity (resolved, never asked)

**The two identity values are resolved at SESSION START, not here.** The orchestrator prompt
(*Session Identity*) carries the resolution instruction itself, because the first use of both —
the greeting — happens before any cycle exists, and a session that never runs SDD never loads
this file. This section is the full rules for values already in hand; it is not the trigger.

Neither is a fourth preflight question: they NEVER enter the grouped prompt, never block, and
never gate a phase. An unresolved one degrades silently — `neutral`, or no name at all. The
rule above stands unchanged: when the three values resolve from the persisted settings, the
session starts without asking anything, whatever these two resolve to.

**`persona`** — the key is read from the SAME settings home the three values come from
(`openspec/config.yaml`, or the `sdd-init/{project}` settings bundle in engram mode).

- **Absent → `neutral`, and `neutral` means DO NOTHING.** Do not read
  `skills/_shared/personas.md`, do not mention personas, do not add a persona line to the
  status print, do not adopt any voice. A session whose settings carry no `persona` key
  behaves EXACTLY as it did before the key existed — that equivalence is the contract.
- **`persona: neutral` written explicitly** → identical to absent. Same no-op path, same
  output; the explicit value buys nothing but documentation.
- **A known preset** → read `skills/_shared/personas.md` and follow that preset's section,
  including its two boundaries. Read the file ONLY in this case.
- **An unknown value** → fall back to `neutral` and say so once, in one line ("`persona: X`
  is not in `_shared/personas.md` — continuing on neutral"). Never fail the preflight, never
  ask the user to fix it, never guess the nearest preset. The config is committed: a typo in
  it must not break the session for the whole team.
- **It is a default, not an override.** A voice the user's own environment already imposes —
  a Claude Code output style, `gentle-pi`, a project `AGENTS.md` — outranks this setting, and
  an explicit instruction in the conversation outranks both. Full ladder: `personas.md` →
  *Never an override*.
- The settings home is the only source: no per-harness default persona, no inference from
  the language the user happens to write in, no persona in `.kurama/`.
- A persona never selects the LANGUAGE of a reply — the orchestrator's Language Domain
  Contract does, and the user's latest message decides. The persona shapes register and
  vocabulary inside that language, on the user-facing half only.

**The user's name** — resolved ONCE at session start, stopping at the first non-empty answer.
The ladder in full, since the prompt carries only its steps:

1. `git config user.name`
2. `gh api user --jq '.name // .login'` — ONLY when step 1 came back empty. It is a network
   call: never run it first, never run it when step 1 answered, never let it block the
   session if it hangs or `gh` is unauthenticated (treat that as empty).
3. Nothing. No name is a NORMAL outcome, not a failure: address the user without one, and
   never ask them for it.

**Why it is not a config key.** `openspec/config.yaml` is committed and shared. A name
written there greets all three teammates as whoever ran `sdd-init`. `git config user.name` is
already per-machine, per-user, costs no network call, and every contributor has it set.
Never write the resolved name into a committed file — not `openspec/`, not an artifact, not a
commit message.

**Use it sparingly**: the greeting, a human gate, the summary at the end of a cycle. Not in
every message, not inside an artifact. A name in every turn reads as a tic, not as attention.

**Neither value is forwarded into phase prompts.** They are cached for the session like the
three values, but phases exist to produce artifacts, and artifacts are outside a persona's
scope (`personas.md` → *Conversation only*).

### Artifact existence checks (fail-loud)

Preflight resolves by reading artifacts — `openspec/config.yaml`, the `sdd-init/{project}`
bundle, the `_shared/` contracts. **"Absent" and "unreadable" are different findings and must
never collapse into the same conclusion.** A missing artifact means the project was never
initialized; a failed read means the CHECK is broken. Treating the second as the first
degrades the whole pipeline silently: it re-asks answered questions, or worse, runs a phase
with defaults the user never chose.

- **Check existence with fail-loud primitives only** — `test -f <path>` / `test -d <path>`,
  or the harness's own Read tool, which errors visibly when it cannot read. A failed read
  command is evidence of a BROKEN CHECK, NOT of a missing file.
- **Banned probes.** Anything that suppresses stderr or substitutes its own verdict for the
  command's — `bat X 2>/dev/null || echo missing`, any `cmd 2>/dev/null` inside a
  conditional — and any content finder used as an existence check. `fd` and `rg` skip
  dot-directories unless told to include hidden files (`fd -H`, `rg --hidden`; note that
  `rg -H` is `--with-filename`, NOT hidden), and every harness config root is one:
  `.claude/`, `.codex/`, `.pi/`, `.omp/`, `.kurama/`, plus opencode's `~/.config/opencode/`
  (not itself a dot-dir, but reached through one). `.kurama/` is worse: it is gitignored, so
  both finders skip it EVEN WITH hidden flags unless also given `--no-ignore` (`rg -u`,
  `fd -I`). Existence is `test -f` or Read — never a finder.
- **Project-shape inconsistency is BLOCKING.** When the project's own shape implies an
  artifact must exist — `openspec/changes/` present ⇒ `openspec/config.yaml` exists; this
  orchestrator prompt is installed ⇒ the `_shared/` contracts exist — and the check reports
  it missing, that is an INCONSISTENCY, not an uninitialized project. STOP: re-verify with a
  SECOND, different method (`test -f` after a failed Read, or the reverse), and report both
  results to the user in their language. Never fall through to "not initialized", never
  proceed on defaults, and never let a phase launch on the unverified reading.

## Cycle State Marker (write it in EVERY mode)

After EVERY phase transition, write/update `.kurama/sdd/{change-name}/state.md`. This is
YOUR write — no phase skill does it for you, and no mode exempts you from it: `engram`,
`openspec`, and `hybrid` all write this file *in addition to* the mode's own state
persistence (`persistence-contract.md` → *Hook-visible cycle markers* and *State
Persistence (Orchestrator)*).

It is not bookkeeping. `orchestrator-write-guard.sh` runs outside the model and can read
only the filesystem — it cannot query Engram — so this file is the ONLY thing that tells
it a cycle is active. Skip it in `engram` mode and the guard silently never engages.

- Content mirrors the state artifact: `change`, `phase` (the phase just completed),
  `artifact_store.mode`, `artifacts`, `tasks_progress`, `last_updated`
  (`engram-convention.md` → the `sdd/{change-name}/state` artifact).
- It is also the recovery floor after a compaction, and what `scripts/sdd-status.sh`
  reads to report the cycle.
- It stays until `sdd-archive` writes `.kurama/sdd/{change-name}/archive-report.md`,
  which RETIRES the cycle. Never delete it by hand.
- A failed marker write goes in the phase's `risks`; where `.kurama/sdd/` is only the
  mirror that is a WARNING and the cycle continues.

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
  openspec: read the file) using the fail-loud primitives of *Artifact existence checks*
  above. A read that ERRORS is a broken check, not a missing artifact: re-verify with a
  second method before ruling. A phase that claims success but produced no retrievable
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
