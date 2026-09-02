# Persistence Contract (shared across all SDD skills)

> **Scope — this contract governs SDD ARTIFACTS, not implementation code.** Everything below about "writing" or "project files" refers to *SDD artifacts* (exploration, brainstorm, proposal, spec, design, tasks, apply-progress, verify-report, archive-report). It does NOT restrict the implementation code that `sdd-apply` writes. Writing source files, tests, and required configuration is **ALWAYS allowed and REQUIRED** — producing that code is the entire point of the apply phase.

## The one store, and the one state directory

There is exactly ONE artifact store and it is the filesystem:

| What | Where | Committed? | Who reads it |
|------|-------|-----------|--------------|
| **Artifacts** — exploration, brainstorm ledger, proposal, spec, design, tasks, verify report, archive report | `openspec/` (paths in `openspec-convention.md`) | Yes — they are the deliverable | Downstream phases, humans, code review |
| **Cycle state** — `state.md`, the cycle markers, the skill registry | `.kurama/` | No — gitignored, machine-local | The orchestrator, `scripts/sdd-status.sh`, the deterministic hooks |

That split is the whole contract. Artifacts are the repo's memory of *what was decided*; `.kurama/` is the harness's memory of *where this cycle is*. Never write an artifact into `.kurama/`, and never move cycle state into `openspec/`.

**No modes.** There is no `artifact_store.mode` setting. Files under `openspec/` are the only artifact store; every phase reads and writes them the same way in every project. A config that still carries `artifact_store.mode` is handled by `sdd-new`/`sdd-continue` — one line, then the cycle proceeds normally.

## Behavior

- **Read** — retrieve upstream artifacts from the paths in `openspec-convention.md`.
- **Write** — the phase writes its artifact file during its main step. There is no separate persistence step afterwards.
- **Write failure** — a filesystem write failure is a genuine blocker; there is no second store. Return `status: blocked` naming the failing path.

### Retrieval failure semantics

An upstream artifact "cannot be retrieved" when its file is absent or unreadable.

- **REQUIRED artifact missing** → do NOT silently proceed. Return `status: blocked`, name the missing artifact in `executive_summary`, and set `next_recommended` to the phase that produces it (per the Canonical Phase DAG in `sdd-phase-common.md`).
- **OPTIONAL artifact missing** → proceed, and note the absence in `risks`.

## Harness State (`.kurama/`)

`.kurama/` is the **harness state directory** — gitignored infrastructure, never repo-tracked. It holds:

- `.kurama/skill-registry.md` — the compact skill registry
- `.kurama/sdd/{change-name}/` — the cycle markers below

Nothing under `.kurama/` is an artifact. It is machine-local: wiping it loses the current cycle's position, never a decision.

### Hook-visible cycle markers

The two shipped Claude Code hooks — `orchestrator-write-guard.sh` and `archive-gate.sh` — are *mechanisms*, not prose: they run outside the model and read only the filesystem, and they read it at fixed paths under `.kurama/`. Three markers are written there:

| Marker | Written by | When | Read by |
|--------|-----------|------|---------|
| `state.md` | orchestrator | after every phase transition | `orchestrator-write-guard.sh` (active-cycle detection), `scripts/sdd-status.sh` |
| `verify-report.md` | `sdd-verify` | every verify run | `archive-gate.sh` (verdict + `Tree-Hash`), `sdd-archive` Step 0 |
| `archive-report.md` | `sdd-archive` | on a successful archive | both hooks — its presence RETIRES the cycle |

Binding rules:

- **In addition, never instead.** `verify-report.md` and `archive-report.md` are ALSO written as artifacts under `openspec/changes/{change-name}/`, which stays authoritative. The `.kurama/` copy is a mechanical mirror for the hooks and for offline tooling; if the two ever disagree, the `openspec/` copy wins.
- **Full content, never a stub.** `verify-report.md` MUST be the COMPLETE report markdown: the gate parses the `### Verdict` line and the Content Binding `Tree-Hash:` line straight out of this file.
- **`archive-report.md` is mandatory on a successful archive.** It is the ONLY marker that tells the write guard the cycle is over; without it the guard keeps blocking the orchestrator long after the change was archived, and the gate keeps auto-detecting a closed change.
- Writing these markers never disturbs the verify→archive content binding: the receipt pathspec excludes `.kurama/` (see `sdd-verify` Step 6b).
- Report a failed marker write in the phase's `risks`. The marker is a mirror, so a failed write is a WARNING and the phase continues — the artifact itself is already durable under `openspec/`.

Why this is not optional: a hook cannot read anything but the filesystem, and it must find the marker without knowing which change is active. One fixed on-disk path makes both hooks work without a line of hook bash changing.

## State Persistence (Orchestrator)

The orchestrator persists DAG state after each phase transition so an SDD cycle survives compaction:

- Write `openspec/changes/{change-name}/state.yaml` — the committed, human-readable cycle state.
- Write `.kurama/sdd/{change-name}/state.md` — the machine-local cycle marker.

Recover by reading `state.yaml` (authoritative), falling back to `state.md`.

`.kurama/sdd/{change-name}/state.md` is what `orchestrator-write-guard.sh` reads to know a cycle is active. It stays until `sdd-archive` writes `.kurama/sdd/{change-name}/archive-report.md`, which retires the cycle; do NOT delete it by hand.

## Common Rules

> **Every rule below governs SDD ARTIFACTS only** — never the implementation code `sdd-apply` writes, which is always written to the project.

- Write SDD artifact files ONLY to the paths defined in `openspec-convention.md`.
- Additionally write the three `.kurama/sdd/{change-name}/` cycle markers (`state.md`, `verify-report.md`, `archive-report.md`). They are harness infrastructure, not repo-tracked artifacts, and they are the only thing the deterministic hooks can see.
- Never invent a second artifact store. If a file cannot be written, that is a blocker to report, not a reason to persist somewhere else.

## Sub-Agent Context Rules

Sub-agents launch with a fresh context and NO access to the orchestrator's instructions.

Who reads, who writes:
- Non-SDD (general task): the orchestrator passes the relevant context in the prompt; the sub-agent returns its discoveries inline in its envelope.
- SDD (phase with dependencies): the sub-agent reads upstream artifacts directly from `openspec/`; the sub-agent writes its own artifact.
- SDD (phase without dependencies, e.g. explore): nobody reads; the sub-agent writes its artifact.

Why this split:
- SDD artifacts are large; inlining them in the orchestrator prompt would consume the entire context window.
- Sub-agents always write: they have the complete detail on what happened; nuance is lost by the time results flow back to the orchestrator.

## Orchestrator Prompt Instructions for Sub-Agents

### SDD retrieval preamble (phases with upstream dependencies)

```
Read these artifacts before starting, from the paths defined in openspec-convention.md.
```

If a REQUIRED upstream artifact cannot be retrieved, the sub-agent returns `status: blocked` naming it (see `sdd-phase-common.md` Section B); an OPTIONAL one that is missing is noted in `risks`.

### SDD persistence (phases that produce an artifact)

```
PERSISTENCE: write the artifact file to the path defined in openspec-convention.md.
Do not return without writing it — downstream phases read your output from that file.
```

When the artifact is `verify-report` or `archive-report`, append: *"Additionally write the full artifact to `.kurama/sdd/{change-name}/{artifact-type}.md`. This is a cycle marker read by the deterministic hooks — a mirror of the artifact, not a substitute for it."* (see *Hook-visible cycle markers*).

## Skill Registry

The orchestrator resolves skills from the registry and injects a `## Project Standards` block in your launch prompt — by default the exact SKILL.md path(s) for you to read, or the pre-digested compact rules in the opt-in low-token mode. Sub-agents do NOT read the *registry* itself; the delegator resolves it for you. `skill-resolver.md` is authoritative for exactly what arrives and how (paths-by-default, compact-rules opt-in).

To generate/update: run the `skill-registry` skill, or run `sdd-init`.

Sub-agent skill loading: follow the canonical protocol in `skills/_shared/skill-resolver.md` (Project Standards block first, `SKILL: Load` as fallback, and its no-registry behavior). That file is the single source of truth for skill loading — do not duplicate its rules here.

## Detail Level

The orchestrator may pass `detail_level`: `concise | standard | deep`. This controls output verbosity but does NOT affect what gets persisted — always persist the full artifact.
