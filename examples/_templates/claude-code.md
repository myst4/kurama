<!--
Overlay for Claude Code (examples/claude-code/CLAUDE.md).
Holds ONLY this harness's deltas; the shared body lives in core.md.
Blocks are delimited by `<!-- @@TOKEN@@ -->` lines and consumed by
scripts/build-examples.sh. Any block a harness omits renders empty.
-->

<!-- @@HEADER@@ -->
# Kurama — Orchestrator Instructions

Bind this to the dedicated `sdd-orchestrator` agent or rule only. Do NOT apply it to executor phase agents such as `sdd-apply` or `sdd-verify`.

<!-- @@DELEGATION_MECHANISM@@ -->
delegate (async) is the default for delegated work. Use task (sync) only when you need the result before your next action.

<!-- @@NATIVE_NOTES@@ -->
### Native subagents & hooks

Claude Code can run each SDD phase as a native declarative subagent instead of a generic `Task` call. See `examples/claude-code/agents/` for one subagent per phase (frontmatter `name`, `description`, `tools`, `model`) and `examples/claude-code/hooks/` for deterministic gates (a PreToolUse guard that blocks orchestrator edits while a cycle is active, and an archive gate that requires a verify PASS). When those agents are installed, model routing comes from each agent's `model` frontmatter and the Model Assignments table below is the fallback reference.

Session hygiene on Claude Code: named agents/teammates spawned for a phase are stopped with the native stop primitive (`TaskStop` with the agent's name, or requesting the teammate's shutdown) as soon as their envelope is read and validated — finished phase agents must not linger in the teammate list/status bar.

<!-- @@MODEL_ASSIGNMENTS_SECTION@@ -->
<!-- gentle-ai:sdd-model-assignments -->
## Model Assignments

Read this table at session start (or before first delegation), cache it for the session, and pass the mapped alias in every Agent tool call via the `model` parameter. If a phase is missing, use the `default` row. If you lack access to the assigned model, substitute `sonnet` and continue.

| Phase | Default Model | Reason |
|-------|---------------|--------|
| orchestrator | opus | Coordinates, makes decisions |
| sdd-explore | sonnet | Reads code, structural - not architectural |
| sdd-propose | sonnet | Structured proposal writing (architecture is decided in design) |
| sdd-spec | sonnet | Structured writing |
| sdd-design | opus | Architecture decisions |
| sdd-tasks | sonnet | Mechanical breakdown |
| sdd-apply | opus | Implementation quality is the product |
| sdd-verify | sonnet | Validation against spec |
| sdd-archive | sonnet | Merge fidelity over speed |
| default | sonnet | Non-SDD general delegation |

<!-- /gentle-ai:sdd-model-assignments -->

<!-- @@STATE_CONVENTIONS@@ -->
Convention files under the agent's global skills directory (global) or `.agent/skills/_shared/` (workspace): `engram-convention.md`, `persistence-contract.md`, `openspec-convention.md`.
