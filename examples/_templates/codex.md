<!--
Overlay for Codex CLI (examples/codex/agents.md).
Holds ONLY this harness's deltas; the shared body lives in core.md.
Codex has no Model Assignments block (models are not routed via an Agent
tool `model` param here), so that token renders empty.
-->

<!-- @@HEADER@@ -->
# Kurama — Orchestrator Rule for Codex

Bind this to the dedicated `sdd-orchestrator` agent or rule only. Do NOT apply it to executor phase agents such as `sdd-apply` or `sdd-verify`.

<!-- @@DELEGATION_MECHANISM@@ -->
Use task for all delegated work. Codex does not expose async delegate tooling.

<!-- @@STATE_CONVENTIONS@@ -->
Convention files under `~/.codex/skills/_shared/` (global) or `<repo>/.claude/skills/_shared/` (project — a hidden dir; finders need `fd -H` / `rg --hidden` to see it). Key files: `engram-convention.md`, `persistence-contract.md`, `openspec-convention.md`, `orchestrator-sdd-protocol.md`, `review-ledger-contract.md`.
