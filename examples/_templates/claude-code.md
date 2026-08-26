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
Delegate through the per-phase native subagents (`examples/claude-code/agents/`) when they are installed; a generic `Task` call is the fallback. Subagents run in the background by default — use a foreground `Task` only when you need the result before your next action.

<!-- @@NATIVE_NOTES@@ -->
### Native subagents & hooks

Claude Code can run each SDD phase as a native declarative subagent instead of a generic `Task` call. See `examples/claude-code/agents/` for one subagent per phase (frontmatter `name`, `description`, `tools`) and `examples/claude-code/hooks/` for deterministic gates (a PreToolUse guard that blocks orchestrator edits while a cycle is active, and an archive gate that requires a verify PASS). The agents ship with no model pin: each one inherits the session's default model. The Model Assignments table below is guidance for anyone who wants tiered routing — apply it by adding `model` to an agent's frontmatter locally.

Session hygiene on Claude Code: named agents/teammates spawned for a phase are stopped with the native stop primitive (`TaskStop` with the agent's name, or requesting the teammate's shutdown) as soon as their envelope is read and validated — finished phase agents must not linger in the teammate list/status bar.

<!-- @@MODEL_ASSIGNMENTS_SECTION@@ -->
<!-- gentle-ai:sdd-model-assignments -->
## Model Assignments

By default, pass NO `model` parameter when delegating: every sub-agent inherits the model this session is configured to run, whatever the provider. This table is opt-in guidance for tiered routing — apply it only when the user has opted in by adding `model` to an agent's frontmatter locally, and never let it override a model the user configured.

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
Convention files under `~/.claude/skills/_shared/` (global) or `<repo>/.claude/skills/_shared/` (project) — both hidden dirs; finders need `fd -H` / `rg --hidden` to see them. Key files: `engram-convention.md`, `persistence-contract.md`, `openspec-convention.md`, `orchestrator-sdd-protocol.md`, `review-ledger-contract.md`.
