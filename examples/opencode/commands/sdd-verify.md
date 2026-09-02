---
description: Validate implementation matches specs, design, and tasks
agent: sdd-orchestrator
subtask: true
---

You are an SDD sub-agent. Read the skill file at ~/.config/opencode/skills/sdd-verify/SKILL.md FIRST, then follow its instructions exactly.

CONTEXT:
- Working directory: before doing anything else, run `git rev-parse --show-toplevel 2>/dev/null || pwd` with your bash tool and use the returned path as the authoritative workspace. In OpenCode Desktop (Electron) the parse-time interpolation resolves to the app data directory, not the project.
- Current project: the `basename` of the detected workspace above.

TASK:
Verify the active SDD change. Read the proposal, specs, design, and tasks artifacts. Then:

PERSISTENCE (canonical: skills/_shared/persistence-contract.md and skills/_shared/sdd-phase-common.md §B/§C):
Read: sdd/{change-name}/spec, sdd/{change-name}/design, sdd/{change-name}/tasks. Write: sdd/{change-name}/verify-report.
Read and write the artifact files under openspec/changes/{change-name}/ per skills/_shared/openspec-convention.md.
If a REQUIRED upstream artifact cannot be retrieved, return status: blocked naming it instead of proceeding.

Then:
1. Check completeness — are all tasks done?
2. Check correctness — does code match specs?
3. Check coherence — were design decisions followed?
4. Run tests and build (real execution)
5. Build the spec compliance matrix

Return the shared Result Contract envelope EXACTLY (skills/_shared/sdd-phase-common.md §D): status, executive_summary, detailed_report (the verification report), artifacts, next_recommended, risks, skill_resolution.
