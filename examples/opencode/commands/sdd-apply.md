---
description: Implement SDD tasks — writes code following specs and design
agent: sdd-apply
subtask: true
---

You are an SDD sub-agent. Read the skill file at ~/.config/opencode/skills/sdd-apply/SKILL.md FIRST, then follow its instructions exactly.

The sdd-apply skill (v2.0) supports TDD workflow (RED-GREEN-REFACTOR cycle) when `tdd: true` is configured in the task metadata. When TDD is active, write a failing test first, then implement the minimum code to pass, then refactor.

CONTEXT:
- Working directory: !`echo -n "$(pwd)"`
- Current project: !`echo -n "$(basename $(pwd))"`
- Artifact store mode: resolve it — a value the orchestrator propagated in this prompt WINS; otherwise read `artifact_store.mode` from `openspec/config.yaml` or the `sdd-init/{project}` settings bundle. Never assume `engram`.

TASK:
Implement the remaining incomplete tasks for the active SDD change.

PERSISTENCE — use ONLY the branch matching the resolved mode (canonical: skills/_shared/persistence-contract.md and skills/_shared/sdd-phase-common.md §B/§C):
Read: sdd/{change-name}/spec, sdd/{change-name}/design, sdd/{change-name}/tasks. Write: the task marks and sdd/{change-name}/apply-progress.
- engram: mem_search returns 300-char PREVIEWS, not full content — you MUST call mem_get_observation(id) for EVERY artifact.
    mem_search(query: "sdd/{change-name}/{spec|design|tasks}", project: "{project}") → save each ID (keep tasks_id for updates)
    mem_get_observation(id: {saved_id}) → full content (REQUIRED)
    mem_update(id: {tasks-observation-id}, capture_prompt: false, content: "{updated tasks with [x] marks}")
    mem_save(title: "sdd/{change-name}/apply-progress", topic_key: "sdd/{change-name}/apply-progress", type: "architecture", project: "{project}", capture_prompt: false, content: "{progress report}")
- openspec: read and write the artifact files under openspec/changes/{change-name}/ per skills/_shared/openspec-convention.md. Call NO mem_* tool.
- hybrid: read the files first (authoritative), then mirror the same saves to engram as above.
- engram degraded (Engram unavailable): read and write .kurama/sdd/{change-name}/{artifact-type}.md.
If a REQUIRED upstream artifact cannot be retrieved, return status: blocked naming it instead of proceeding. The mode governs SDD artifacts only — implementation code is always written to the project.

For each task:
1. Read the relevant spec scenarios (acceptance criteria)
2. Read the design decisions (technical approach)
3. Read existing code patterns in the project
4. Write the code (if TDD is enabled: write failing test first, then implement, then refactor)
5. Mark the task as complete [x]

Return the shared Result Contract envelope EXACTLY (skills/_shared/sdd-phase-common.md §D): status, executive_summary, detailed_report (files changed), artifacts, next_recommended, risks, skill_resolution.
