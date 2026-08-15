---
description: Fast-forward all SDD planning phases — proposal through tasks
agent: sdd-orchestrator
---

Follow the SDD orchestrator workflow to fast-forward all planning phases for change "$ARGUMENTS".

WORKFLOW:
Run these sub-agents in sequence:
1. sdd-propose — create the proposal
2. sdd-spec — write specifications
3. sdd-design — create technical design
4. sdd-tasks — break down into implementation tasks

Present a combined summary after ALL phases complete (not between each one).

CONTEXT:
- Working directory: !`echo -n "$(pwd)"`
- Current project: !`echo -n "$(basename $(pwd))"`
- Change name: $ARGUMENTS
- Artifact store mode: resolve it from the persisted settings (`artifact_store.mode` in `openspec/config.yaml` or the `sdd-init/{project}` settings bundle) and propagate the resolved value to every sub-agent you launch. Never assume `engram`.

PERSISTENCE NOTE:
Sub-agents handle persistence automatically for the mode you propagate — each phase saves its artifact under "sdd/$ARGUMENTS/{type}" (engram topic_key, or the equivalent openspec path per skills/_shared/openspec-convention.md), where type is: proposal, spec, design, tasks.

Read the orchestrator instructions to coordinate this workflow. Do NOT execute phase work inline — delegate to sub-agents.
