<!--
Overlay for Gemini CLI (examples/gemini-cli/GEMINI.md).
Holds ONLY this harness's deltas; the shared body lives in core.md.
No Model Assignments block for this harness, so that token renders empty.
-->

<!-- @@HEADER@@ -->
# Agent Teams Lite — Orchestrator Rule for Gemini

Bind this to the dedicated `sdd-orchestrator` agent or rule only. Do NOT apply it to executor phase agents such as `sdd-apply` or `sdd-verify`.

<!-- @@DELEGATION_MECHANISM@@ -->
delegate (async) is the default for delegated work. Use task (sync) only when you need the result before your next action.

<!-- @@STATE_CONVENTIONS@@ -->
Convention files under `~/.gemini/skills/_shared/` (global) or `.agent/skills/_shared/` (workspace): `engram-convention.md`, `persistence-contract.md`, `openspec-convention.md`.
