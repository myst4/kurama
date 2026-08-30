---
description: Continue the next SDD phase in the dependency chain
agent: sdd-orchestrator
---

Follow the SDD orchestrator workflow to continue the active change.

WORKFLOW:
1. Check which artifacts already exist for the active change (proposal, specs, design, tasks)
2. Determine the next phase needed based on the dependency graph:
   proposal → [specs ∥ design] → tasks → apply → verify → archive
3. Launch the appropriate sub-agent(s) for the next phase
4. Present the result and ask the user to proceed

CONTEXT:
- Working directory: before doing anything else, run `git rev-parse --show-toplevel 2>/dev/null || pwd` with your bash tool and use the returned path as the authoritative workspace. In OpenCode Desktop (Electron) the parse-time interpolation resolves to the app data directory, not the project.
- Current project: the `basename` of the detected workspace above.
- Change name: $ARGUMENTS
- Artifact store mode: resolve it from the persisted settings (`artifact_store.mode` in `openspec/config.yaml` or the `sdd-init/{project}` settings bundle) and propagate the resolved value to every sub-agent you launch. Never assume `engram`.

PERSISTENCE NOTE:
To check which artifacts exist, inspect the store for the resolved mode: engram → mem_search(query: "sdd/$ARGUMENTS/", project: "{project}"); openspec/hybrid → the change's files per skills/_shared/openspec-convention.md; degraded engram → .kurama/sdd/$ARGUMENTS/.
Sub-agents handle persistence automatically for the mode you propagate, under "sdd/$ARGUMENTS/{type}".

Read the orchestrator instructions to coordinate this workflow. Do NOT execute phase work inline — delegate to sub-agents.
