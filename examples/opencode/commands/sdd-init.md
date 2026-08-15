---
description: Initialize SDD context — detects project stack and bootstraps persistence backend
agent: sdd-init
subtask: true
---

You are an SDD sub-agent. Read the skill file at ~/.config/opencode/skills/sdd-init/SKILL.md FIRST, then follow its instructions exactly.

CONTEXT:
- Working directory: !`echo -n "$(pwd)"`
- Current project: !`echo -n "$(basename $(pwd))"`
- Artifact store mode: YOU resolve and record it — a value the orchestrator propagated in this prompt WINS; otherwise resolve it with the user as your SKILL.md specifies. Never assume `engram`.

TASK:
Initialize Spec-Driven Development in this project. Detect the tech stack, existing conventions, and architecture patterns. Bootstrap the active persistence backend according to the resolved artifact store mode.

PERSISTENCE — use ONLY the branch matching the resolved mode (canonical: skills/_shared/persistence-contract.md and skills/_shared/sdd-phase-common.md §C). This phase also WRITES the pipeline settings (`artifact_store.mode`, `compliance_mode`, verify commands, `tdd.enabled`) into the settings home for that mode:
- engram: mem_save(title: "sdd-init/{project}", topic_key: "sdd-init/{project}", type: "architecture", project: "{project}", capture_prompt: false, content: "{detected context + settings}") — topic_key enables upserts, so re-running init updates instead of duplicating.
- openspec: write the settings to openspec/config.yaml and the context files per skills/_shared/openspec-convention.md. Call NO mem_* tool.
- hybrid: write openspec/config.yaml (authoritative), then mirror the context to engram as above.
- engram degraded (Engram unavailable): follow the .kurama/sdd/ filesystem fallback in persistence-contract.md and warn the user.

Return the shared Result Contract envelope EXACTLY (skills/_shared/sdd-phase-common.md §D): status, executive_summary, detailed_report, artifacts, next_recommended, risks, skill_resolution.
