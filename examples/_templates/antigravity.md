<!--
Overlay for Antigravity (examples/antigravity/sdd-orchestrator.md).
Holds ONLY this harness's deltas; the shared body lives in core.md.
-->

<!-- @@HEADER@@ -->
# Agent Teams Lite — Orchestrator Instructions

Bind this to the dedicated `sdd-orchestrator` agent or rule only. Do NOT apply it to executor phase agents such as `sdd-apply` or `sdd-verify`.

<!-- @@DELEGATION_MECHANISM@@ -->
delegate (async) is the default for delegated work. Use task (sync) only when you need the result before your next action.

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
