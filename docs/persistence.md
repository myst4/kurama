# Persistence

Kurama has **one artifact store**: files under `openspec/`. This never restricts
implementation code — `sdd-apply` always writes source, tests, and required
configuration to the project. For quick start, see the
[main README](../README.md).

## The three stores

Everything Kurama persists falls into exactly three places, and the boundary
between them is the whole design:

| Store | Scope | Holds |
|-------|-------|-------|
| `openspec/` | **committed** | the SDD artifacts of each change — exploration, brainstorm ledger, proposal, spec, design, tasks, verify/archive reports, and the main specs |
| `.kurama/` | machine-local, gitignored | harness state: the SDD cycle markers |
| **`MEMORY.md`** | **committed** | durable team knowledge about the project |

**Artifacts are committed; cycle state is not.** An artifact records *what was
decided* and belongs in the repo, where a teammate and a code reviewer can read
it. Cycle state records *where this cycle is* and belongs on the machine running
it — wiping `.kurama/` loses your place, never a decision.

> **Removed in 6.3.0.** Kurama used to offer three artifact-store modes behind an
> `artifact_store.mode` key. They are gone: there is one store and no setting. A
> config that still carries the key is inert — `sdd-new` / `sdd-continue` print one
> line and continue. See
> [migration.md](migration.md#630--the-artifact-store-collapses-to-files).

## Where pipeline settings are configured

Every cycle needs a single home for the settings that steer it: `compliance_mode`,
the verify commands (`test_command` / `build_command` / `coverage_threshold`), and
the `tdd` flag. That home is **`openspec/config.yaml`**, written by `sdd-init` and
committed with the project — `compliance_mode` and the verify commands live under
`rules.verify`. See
[openspec-convention.md](../skills/_shared/openspec-convention.md).

The orchestrator reads the settings home once per session, then propagates every
setting in **every phase prompt**. On conflict — a stale `config.yaml` vs. a
freshly propagated prompt value — **the propagated prompt value wins**.

```yaml
# openspec/config.yaml (excerpt) — rules.verify is the settings home for
# compliance_mode and the verify commands
rules:
  verify:
    test_command: "npm test"
    build_command: "npm run build"
    coverage_threshold: 0
    compliance_mode: behavioral   # behavioral | static
```

The same file also carries `persona:` — a **top-level** key, not part of
`rules.verify`, because it steers the conversation rather than the pipeline. See
[installation.md](installation.md#session-identity-persona-and-name).

## `.kurama/` — harness state directory

`.kurama/` is machine-local harness infrastructure, never a committed artifact:

- `.kurama/sdd/{change-name}/` — the three cycle markers (`state.md`,
  `verify-report.md`, `archive-report.md`) the deterministic hooks read. The
  hooks run outside the model and read only the filesystem, at these fixed
  paths; see
  [persistence-contract.md](../skills/_shared/persistence-contract.md) →
  *Hook-visible cycle markers* and [docs/hooks.md](hooks.md). The two report
  markers are mirrors — the authoritative copies are the artifacts under
  `openspec/changes/{change-name}/`.

Nothing under `.kurama/` is an artifact, and no artifact is ever written there.

## `MEMORY.md` — durable team knowledge

`MEMORY.md` lives at the repo root and is **committed**, like everything else
the team versions. It holds the accumulated knowledge about *this* project that
the repo does not already record, and it is written by the `sdd-learn` skill —
automatically at cycle close, invoked by the orchestrator right after
`sdd-archive` (the moment the cycle's learnings are freshest and complete), and
on demand whenever you ask for it mid-session.

The **first `sdd-learn` write creates the file**; `sdd-init` does not, because an
empty `MEMORY.md` committed into a repo that never uses the feature is noise.

**`MEMORY.md` is the team's, not yours.** It travels through git, so every
teammate reads the same file. Whatever personal memory tool a developer runs on
their own machine is theirs to manage — Kurama does not install one, does not
configure one, and does not write to one.

**Where the raw material comes from.** Every SDD phase closes its return
envelope with a `## Key Learnings` section — 1-5 gotchas, edge cases or
non-obvious decisions found during that phase, omitted entirely when there
were none (see
[sdd-phase-common.md](../skills/_shared/sdd-phase-common.md) → Section D).
`sdd-learn` reads that section as the freshest input when it curates `MEMORY.md`
at cycle close — still subject to the admission test below, so a learning is a
candidate for the team's file, never an automatic entry in it.

**What goes in it** — non-obvious discoveries, gotchas and failure modes,
conventions the team established, decisions together with the rationale behind
them, and the reason a surprising piece of code is the way it is. **What does
not** — anything git history, the specs, or the code already say.

The admission test for an entry is one question: **would a teammate waste an
hour rediscovering this?** If the answer is no, it does not go in — `sdd-learn`
refuses to write an entry it cannot justify against that test.

**Curation rules.** This file is read at session start, so every line it grows
is a context tax paid on every session, by everyone. Unbounded growth is the
failure mode:

- one entry per learning — the entry format itself (fields, dating, which change
  it names) is fixed by the skill, not restated here, so the two cannot drift:
  see [`skills/sdd-learn/SKILL.md`](../skills/sdd-learn/SKILL.md);
- a new entry that supersedes an old one **replaces** it — entries do not stack;
- an entry that later proves wrong is **deleted**, not annotated.

## OpenSpec File Structure

> **Not the upstream OpenSpec CLI.** This is Kurama's own file convention (see
> [openspec-convention.md](../skills/_shared/openspec-convention.md)) — a
> different schema, not interchangeable with the
> [Fission-AI/OpenSpec](https://github.com/Fission-AI/OpenSpec) tool; the
> `openspec` directory name is kept for continuity only.

A change produces a self-contained folder:

```
openspec/
├── config.yaml                        ← Project context (stack, conventions, rules — incl. the rules.verify.* settings home)
├── specs/                             ← Source of truth: how the system works TODAY
│   ├── auth/spec.md
│   ├── export/spec.md
│   └── ui/spec.md
└── changes/
    ├── add-csv-export/                ← Active change
    │   ├── proposal.md                ← WHY + SCOPE + APPROACH
    │   ├── specs/                     ← Delta specs (ADDED/MODIFIED/REMOVED)
    │   │   └── export/spec.md
    │   ├── design.md                  ← HOW (architecture decisions)
    │   └── tasks.md                   ← WHAT (implementation checklist)
    └── archive/                       ← Completed changes (audit trail)
        └── 2026-02-16-fix-auth/
```
