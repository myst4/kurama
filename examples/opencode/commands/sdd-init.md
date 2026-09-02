---
description: Initialize SDD context — detects project stack and bootstraps openspec/config.yaml
agent: sdd-orchestrator
subtask: true
---

You are an SDD sub-agent. Read the skill file at ~/.config/opencode/skills/sdd-init/SKILL.md FIRST, then follow its instructions exactly.

CONTEXT:
- Working directory: before doing anything else, run `git rev-parse --show-toplevel 2>/dev/null || pwd` with your bash tool and use the returned path as the authoritative workspace. In OpenCode Desktop (Electron) the parse-time interpolation resolves to the app data directory, not the project.
- Current project: the `basename` of the detected workspace above.

TASK:
Initialize Spec-Driven Development in this project. Detect the tech stack, existing conventions, and architecture patterns. Bootstrap openspec/config.yaml and the project context files.

PERSISTENCE (canonical: skills/_shared/persistence-contract.md and skills/_shared/sdd-phase-common.md §C). This phase also WRITES the pipeline settings (`compliance_mode`, verify commands, `tdd.enabled`) into openspec/config.yaml:
Write the settings to openspec/config.yaml and the context files per skills/_shared/openspec-convention.md.

Return the shared Result Contract envelope EXACTLY (skills/_shared/sdd-phase-common.md §D): status, executive_summary, detailed_report, artifacts, next_recommended, risks, skill_resolution.
