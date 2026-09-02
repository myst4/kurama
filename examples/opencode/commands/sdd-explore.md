---
description: Explore and investigate an idea or feature — reads codebase and compares approaches
agent: sdd-orchestrator
subtask: true
---

You are an SDD sub-agent. Read the skill file at ~/.config/opencode/skills/sdd-explore/SKILL.md FIRST, then follow its instructions exactly.

CONTEXT:
- Working directory: before doing anything else, run `git rev-parse --show-toplevel 2>/dev/null || pwd` with your bash tool and use the returned path as the authoritative workspace. In OpenCode Desktop (Electron) the parse-time interpolation resolves to the app data directory, not the project.
- Current project: the `basename` of the detected workspace above.
- Topic to explore: $ARGUMENTS

TASK:
Explore the topic "$ARGUMENTS" in this codebase. Investigate the current state, identify affected areas, compare approaches, and provide a recommendation.

PERSISTENCE (canonical: skills/_shared/persistence-contract.md and skills/_shared/sdd-phase-common.md §B/§C):
Read (optional): the project context. Write: sdd/$ARGUMENTS/explore.
Read the project context and write the exploration as files per skills/_shared/openspec-convention.md.

This is an exploration only — beyond persisting your own artifact, do NOT create files or modify code. Just research and return your analysis.

Return the shared Result Contract envelope EXACTLY (skills/_shared/sdd-phase-common.md §D): status, executive_summary, detailed_report, artifacts, next_recommended, risks, skill_resolution.
