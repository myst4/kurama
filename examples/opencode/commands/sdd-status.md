---
description: Report the state of every active SDD cycle in this project
agent: sdd-orchestrator
---

Report the current state of Spec-Driven Development in this project. Do NOT execute phase work — this is a read-only status report.

CONTEXT:
- Working directory: !`echo -n "$(pwd)"`
- Current project: !`echo -n "$(basename $(pwd))"`
- Artifact store mode: engram

HOW TO GATHER STATE (prefer the first that is available):

1. If the Kurama repo ships `scripts/sdd-status.sh`, run it against this project for a canonical report:
   `scripts/sdd-status.sh "$(pwd)" --json`
   It reads the on-disk cycle markers (`openspec/changes/<change>/state.yaml` and
   `.kurama/sdd/<change>/state.md`, which EVERY artifact-store mode writes) and
   prints, per change, the last completed phase, the next phase in the canonical
   DAG, the pipeline settings, and task progress.

2. Otherwise inspect the stores directly:
   - `openspec/changes/*/state.yaml` (+ `openspec/config.yaml` for settings), or
   - `.kurama/sdd/*/state.md` — the cycle marker written in EVERY mode, engram
     included. Its presence is NOT evidence that Engram degraded; it is how the
     deterministic hooks and this report see a cycle at all. Check it with
     `test -f`, never a finder: `.kurama/` is hidden AND gitignored. Or
   - query Engram for cycles saved under topic_key `sdd/<change>/*`.

CANONICAL PHASE DAG (source of truth: skills/_shared/sdd-phase-common.md):
  explore -> propose -> (spec || design) -> tasks -> apply -> verify -> archive

REPORT (in the user's language):
For each active change report: name, last completed phase, next recommended phase,
and task progress. If no cycle is found in any on-disk store, say there are no
active SDD cycles — and do NOT explain that away as "engram cycles are invisible
offline", because they are not: every mode leaves a marker. The only cycle with
nothing on disk is one started before the markers existed; running its next phase
re-writes the marker.
