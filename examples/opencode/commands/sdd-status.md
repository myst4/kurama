---
description: Report the state of every active SDD cycle in this project
agent: sdd-orchestrator
---

Report the current state of Spec-Driven Development in this project. Do NOT execute phase work — this is a read-only status report.

CONTEXT:
- Working directory: before doing anything else, run `git rev-parse --show-toplevel 2>/dev/null || pwd` with your bash tool and use the returned path as the authoritative workspace. In OpenCode Desktop (Electron) the parse-time interpolation resolves to the app data directory, not the project.
- Current project: the `basename` of the detected workspace above.
- Scope: `/sdd-status` is an OpenCode-only command; no other harness installs it.

HOW TO GATHER STATE (prefer the first that is available):

1. If the Kurama repo ships `scripts/sdd-status.sh`, run it against this project for a canonical report:
   `scripts/sdd-status.sh "$(pwd)" --json`
   It reads the on-disk cycle markers (`openspec/changes/<change>/state.yaml` and
   `.kurama/sdd/<change>/state.md`) and prints, per change, the last completed
   phase, the next phase in the canonical DAG, the pipeline settings, and task
   progress.

2. Otherwise inspect the files directly:
   - `openspec/changes/*/state.yaml` (+ `openspec/config.yaml` for settings), or
   - `.kurama/sdd/*/state.md` — the cycle marker; it is how the deterministic
     hooks and this report see a cycle at all. Check it with `test -f`, never a
     finder: `.kurama/` is hidden AND gitignored.

CANONICAL PHASE DAG (source of truth: skills/_shared/sdd-phase-common.md):
  explore -> propose -> (spec || design) -> tasks -> apply -> verify -> archive

REPORT (in the user's language):
For each active change report: name, last completed phase, next recommended phase,
and task progress. If no cycle is found on disk, say there are no active SDD
cycles. Every cycle leaves a marker; the only cycle with nothing on disk is one
started before the markers existed, and running its next phase re-writes the
marker.
