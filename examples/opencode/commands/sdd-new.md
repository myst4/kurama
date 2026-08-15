---
description: Start a new SDD change — runs exploration then creates a proposal
agent: sdd-orchestrator
---

Follow the SDD orchestrator workflow for starting a new change named "$ARGUMENTS".

WORKFLOW:
1. Launch sdd-explore sub-agent to investigate the codebase for this change
2. Present the exploration summary to the user
3. Launch sdd-propose sub-agent to create a proposal based on the exploration
4. Present the proposal summary and ask the user if they want to continue with specs and design

CONTEXT:
- Working directory: !`echo -n "$(pwd)"`
- Current project: !`echo -n "$(basename $(pwd))"`
- Change name: $ARGUMENTS
- Artifact store mode: resolve it from the persisted settings (`artifact_store.mode` in `openspec/config.yaml` or the `sdd-init/{project}` settings bundle) and propagate the resolved value to every sub-agent you launch. Never assume `engram`.

PERSISTENCE NOTE:
Sub-agents handle persistence automatically for the mode you propagate — each phase saves its artifact under "sdd/$ARGUMENTS/{type}" (engram topic_key, or the equivalent openspec path per skills/_shared/openspec-convention.md).

Read the orchestrator instructions to coordinate this workflow. Do NOT execute phase work inline — delegate to sub-agents.
