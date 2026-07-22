<!--
Overlay for VS Code Copilot (examples/vscode/copilot-instructions.md).
Holds ONLY this harness's deltas; the shared body lives in core.md.
No Model Assignments block for this harness, so that token renders empty.
-->

<!-- @@HEADER@@ -->
# Agent Teams Lite — Orchestrator for VS Code Copilot

Add this to `.github/copilot-instructions.md` in your project root.

<!-- @@DELEGATION_MECHANISM@@ -->
Delegate real work to a sub-agent via Task when available, or run the matching skill phase. Keep only coordination in this thread.

<!-- @@STATE_CONVENTIONS@@ -->
Convention files under `~/.copilot/skills/_shared/` (or your configured skills path): `engram-convention.md`, `persistence-contract.md`, `openspec-convention.md`.
