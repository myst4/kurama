# Persistence Modes

Kurama supports multiple storage backends for **SDD artifacts**
(exploration, proposal, spec, design, tasks, apply-progress, verify-report,
archive-report, state, and main specs). This never restricts implementation
code — `sdd-apply` always writes source, tests, and required configuration to
the project, in every mode. For quick start, see the [main README](../README.md).

## Modes

| Mode | Description |
|------|-------------|
| `engram` | Default when Engram is reachable. Persistent memory across sessions; main specs also live as artifacts (see below). |
| `openspec` | File-based artifacts in `openspec/`. Never chosen automatically. |
| `hybrid` | Both engram + openspec, written simultaneously; filesystem is authoritative (see below). Never chosen automatically. |

## Default resolution and Engram degradation

The orchestrator MUST check Engram availability by attempting one cheap Engram
call at the start of the cycle — it never assumes:

1. Engram reachable → default resolves to `engram`.
2. Engram unreachable → default **degrades to the `.kurama/sdd/` filesystem
   fallback**, with an explicit warning to the user. Persistence is never
   skipped — every mode writes somewhere.
3. `openspec` and `hybrid` are NEVER chosen automatically — only when the user
   or orchestrator explicitly requests them.

A separate rule covers a `mem_save` that fails mid-cycle, as opposed to Engram
being unreachable at cycle start: one retry, then a fallback file written under
`.kurama/sdd/{change-name}/`, reported as a concern in the phase's return
envelope. A single failed save no longer breaks the pipeline.

## Where pipeline settings are configured

Every cycle needs a single home for the settings that steer it: the resolved
`artifact_store` mode, `compliance_mode`, the verify commands
(`test_command` / `build_command` / `coverage_threshold`), and — later — the
`tdd` flag. The home is mode-dependent:

| Mode | Settings home |
|------|----------------|
| `openspec` / `hybrid` | `openspec/config.yaml`, written by `sdd-init` — `compliance_mode` and the verify commands live under `rules.verify`; in `hybrid` the Engram context mirrors it. See [openspec-convention.md](../skills/_shared/openspec-convention.md). |
| `engram` | The `sdd-init/{project}` context artifact in Engram — there is no `config.yaml` in these modes, so it carries the settings itself. |

The orchestrator resolves the mode once per cycle (via the Engram
Availability Check above) and reads the settings home once per session, then
propagates every setting in **every phase prompt**. On conflict — a stale
`config.yaml`/context artifact vs. a freshly propagated prompt value — **the
propagated prompt value wins**.

```yaml
# openspec/config.yaml (excerpt) — rules.verify is the settings home for
# compliance_mode and the verify commands in openspec/hybrid mode
rules:
  verify:
    test_command: "npm test"
    build_command: "npm run build"
    coverage_threshold: 0
    compliance_mode: behavioral   # behavioral | static
```

The same home also carries `persona:` — a **top-level** key, not part of
`rules.verify`, because it steers the conversation rather than the pipeline. The
preflight resolves it alongside the artifact store. See
[installation.md](installation.md#session-identity-persona-and-name).

## Hybrid mode: authority and reconciliation

Filesystem is authoritative in `hybrid`; Engram is a searchable mirror, not a
second source of truth:

- **Reads are file-first** — check the filesystem path, and only fall back to
  Engram if the file is missing.
- **On divergence** (the two stores disagree), the file wins; the phase that
  detects it notes the reconciliation in its return envelope.
- Both writes are still attempted on every save (Engram for cross-session
  recovery/search, filesystem for the human-readable, version-controlled
  copy), but the filesystem copy is what downstream phases trust.
- Every artifact carries `last_updated` (ISO date) in its frontmatter so
  divergence can be detected.

## Main specs in Engram mode

`openspec`/`hybrid` mode merges delta specs into `openspec/specs/{domain}/spec.md`
on archive. In `engram` mode, main specs now persist the same way: each
domain's spec is an Engram artifact with `topic_key:
sdd-specs/{project}/{domain}`. `sdd-archive` merges delta specs into these
artifacts instead of skipping the merge, and `sdd-spec` reads them as the
baseline when starting a new change.

## `.kurama/` — harness state directory

`.kurama/` is written in every mode — it is harness
infrastructure, not an SDD project artifact:

- `.kurama/skill-registry.md` — the scanned skill + convention registry (see
  [docs/sub-agents.md](sub-agents.md)).
- `.kurama/sdd/{change-name}/` — the Engram fallback store, used when Engram is
  unreachable at cycle start (whole-cycle degradation, see above) or when a
  mid-cycle `mem_save` fails after one retry (single-artifact fallback write,
  reported as a concern in the phase's return envelope) — and, in **every** mode,
  the home of the three cycle markers (`state.md`, `verify-report.md`,
  `archive-report.md`) the deterministic hooks read. Those are written whichever
  store the project chose, because the hooks cannot query Engram; see
  [persistence-contract.md](../skills/_shared/persistence-contract.md) →
  *Hook-visible cycle markers* and [docs/hooks.md](hooks.md).

## `MEMORY.md` — durable team knowledge

`MEMORY.md` lives at the repo root and is **committed**, like everything else
the team versions. It holds the accumulated knowledge about *this* project that
the repo does not already record, and it is written by the `sdd-learn` skill —
automatically at cycle close, invoked by the orchestrator right after
`sdd-archive` (the moment the cycle's learnings are freshest and complete), and
on demand whenever you ask for it mid-session.

It is **independent of the persistence mode**. `artifact_store` decides where a
change's SDD artifacts go; it says nothing about where the team's knowledge
lives. `MEMORY.md` sits at the repo root and is committed in every mode,
`engram` included — "artifacts live in Engram" never means "nothing is on disk".
The **first `sdd-learn` write creates the file**; `sdd-init` does not, because an
empty `MEMORY.md` committed into a repo that never uses the feature is noise.

This is a **fourth store**, and the boundary between the four has to be
explicit or `MEMORY.md` becomes a dumping ground:

| Store | Scope | Holds |
|-------|-------|-------|
| `openspec/` | committed | the SDD artifacts of each change |
| `.kurama/` | machine-local, gitignored | harness state, registry, cycle markers |
| Engram | machine-local | cross-session recall for one developer |
| **`MEMORY.md`** | **committed** | **durable team knowledge about the project** |

The distinction that matters day to day is the last two: **Engram is yours,
`MEMORY.md` is the team's.** Engram is a machine-local memory engine — it
survives *your* compactions and *your* sessions, and a teammate who never
installs it has no access to a single line of it. `MEMORY.md` travels through
git, so a teammate without Engram loses nothing from it. That is the whole
reason it exists as a separate file rather than as more Engram artifacts.

**Where the raw material comes from.** Every SDD phase closes its return
envelope with a `## Key Learnings` section — 1-5 gotchas, edge cases or
non-obvious decisions found during that phase, omitted entirely when there
were none (see
[sdd-phase-common.md](../skills/_shared/sdd-phase-common.md) → Section D).
That one section feeds the last two stores in the table and replaces neither:
**Engram** captures it passively, for the developer who ran the cycle, while
**`sdd-learn`** reads it as the freshest input when it curates `MEMORY.md` at
cycle close — still subject to the admission test below, so a learning is a
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
> `openspec` mode name is kept for continuity only.

When `openspec` mode is enabled, a change can produce a self-contained folder:

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
