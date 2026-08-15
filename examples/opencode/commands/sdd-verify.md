---
description: Validate implementation matches specs, design, and tasks
agent: sdd-verify
subtask: true
---

You are an SDD sub-agent. Read the skill file at ~/.config/opencode/skills/sdd-verify/SKILL.md FIRST, then follow its instructions exactly.

CONTEXT:
- Working directory: !`echo -n "$(pwd)"`
- Current project: !`echo -n "$(basename $(pwd))"`
- Artifact store mode: resolve it — a value the orchestrator propagated in this prompt WINS; otherwise read `artifact_store.mode` from `openspec/config.yaml` or the `sdd-init/{project}` settings bundle. Never assume `engram`.

TASK:
Verify the active SDD change. Read the proposal, specs, design, and tasks artifacts. Then:

PERSISTENCE — use ONLY the branch matching the resolved mode (canonical: skills/_shared/persistence-contract.md and skills/_shared/sdd-phase-common.md §B/§C):
Read: sdd/{change-name}/spec, sdd/{change-name}/design, sdd/{change-name}/tasks. Write: sdd/{change-name}/verify-report.
- engram: mem_search returns 300-char PREVIEWS, not full content — you MUST call mem_get_observation(id) for EVERY artifact.
    mem_search(query: "sdd/{change-name}/{spec|design|tasks}", project: "{project}") → save each ID
    mem_get_observation(id: {saved_id}) → full content (REQUIRED)
    mem_save(title: "sdd/{change-name}/verify-report", topic_key: "sdd/{change-name}/verify-report", type: "architecture", project: "{project}", capture_prompt: false, content: "{verification report}")
- openspec: read and write the artifact files under openspec/changes/{change-name}/ per skills/_shared/openspec-convention.md. Call NO mem_* tool.
- hybrid: read the files first (authoritative), then mirror the same save to engram as above.
- engram degraded (Engram unavailable): read and write .kurama/sdd/{change-name}/{artifact-type}.md.
If a REQUIRED upstream artifact cannot be retrieved, return status: blocked naming it instead of proceeding.

Then:
1. Check completeness — are all tasks done?
2. Check correctness — does code match specs?
3. Check coherence — were design decisions followed?
4. Run tests and build (real execution)
5. Build the spec compliance matrix

Return the shared Result Contract envelope EXACTLY (skills/_shared/sdd-phase-common.md §D): status, executive_summary, detailed_report (the verification report), artifacts, next_recommended, risks, skill_resolution.
