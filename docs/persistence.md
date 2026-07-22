# Persistence Modes

Agent Teams Lite supports multiple storage backends for **SDD artifacts**
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
| `none` | No persistence. Results returned inline only. |

## Default resolution and Engram degradation

The orchestrator MUST check Engram availability by attempting one cheap Engram
call at the start of the cycle — it never assumes:

1. Engram reachable → default resolves to `engram`.
2. Engram unreachable → default **degrades to the `.atl/sdd/` filesystem
   fallback**, with an explicit warning to the user. It never degrades
   silently to `none`.
3. `openspec` and `hybrid` are NEVER chosen automatically — only when the user
   or orchestrator explicitly requests them.
4. `none` is reached only by explicit choice, or when the `.atl/sdd/` fallback
   itself is unavailable too.

A separate rule covers a `mem_save` that fails mid-cycle, as opposed to Engram
being unreachable at cycle start: one retry, then a fallback file written under
`.atl/sdd/{change-name}/`, reported as a concern in the phase's return
envelope. A single failed save no longer breaks the pipeline.

## Where pipeline settings are configured

Every cycle needs a single home for the settings that steer it: the resolved
`artifact_store` mode, `compliance_mode`, the verify commands
(`test_command` / `build_command` / `coverage_threshold`), and — later — the
`tdd` flag. The home is mode-dependent:

| Mode | Settings home |
|------|----------------|
| `openspec` / `hybrid` | `openspec/config.yaml`, written by `sdd-init` — `compliance_mode` and the verify commands live under `rules.verify`; in `hybrid` the Engram context mirrors it. See [openspec-convention.md](../skills/_shared/openspec-convention.md). |
| `engram` / `none` | The `sdd-init/{project}` context artifact in Engram — there is no `config.yaml` in these modes, so it carries the settings itself. |

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

## `.atl/` — harness state directory

`.atl/` is written in every mode, including `none` — it is harness
infrastructure, not an SDD project artifact:

- `.atl/skill-registry.md` — the scanned skill + convention registry (see
  [docs/sub-agents.md](sub-agents.md)).
- `.atl/sdd/{change-name}/` — the Engram fallback store, used when Engram is
  unreachable at cycle start (whole-cycle degradation, see above) or when a
  mid-cycle `mem_save` fails after one retry (single-artifact fallback write,
  reported as a concern in the phase's return envelope).

## OpenSpec File Structure

> **Not the upstream OpenSpec CLI.** This is ATL's own file convention (see
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
