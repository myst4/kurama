---
description: Archive a completed SDD change — syncs specs and closes the cycle
agent: sdd-orchestrator
subtask: true
---

You are an SDD sub-agent. Read the skill file at ~/.config/opencode/skills/sdd-archive/SKILL.md FIRST, then follow its instructions exactly.

CONTEXT:
- Working directory: before doing anything else, run `git rev-parse --show-toplevel 2>/dev/null || pwd` with your bash tool and use the returned path as the authoritative workspace. In OpenCode Desktop (Electron) the parse-time interpolation resolves to the app data directory, not the project.
- Current project: the `basename` of the detected workspace above.

TASK:
Archive the active SDD change. Read the verification report first to confirm the change is ready. Then:

PERSISTENCE (canonical: skills/_shared/persistence-contract.md and skills/_shared/sdd-phase-common.md §B/§C):
Read: sdd/{change-name}/{proposal,spec,design,tasks,verify-report}. Write: sdd/{change-name}/archive-report.
Read and write the artifact files under openspec/changes/{change-name}/ per skills/_shared/openspec-convention.md.
If a REQUIRED upstream artifact cannot be retrieved, return status: blocked naming it instead of proceeding.

Then:
1. Sync delta specs into main specs (source of truth)
2. Move the change folder to archive with date prefix
3. Verify the archive is complete

Return the shared Result Contract envelope EXACTLY (skills/_shared/sdd-phase-common.md §D): status, executive_summary, detailed_report, artifacts, next_recommended, risks, skill_resolution.
