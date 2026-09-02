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
Codex has no `task` tool and no sub-agents: skills load inline as instructions, and this file is the only orchestrator. Read the table above as context hygiene — a "delegate" row means run that work as a separate, self-contained step, never as a tool call to an agent that does not exist here.

<!-- @@NATIVE_NOTES@@ -->
### Codex execution model (Hard Stop Rule carve-out)

Codex ships no sub-agent mechanism, so on this harness step 2 of the Hard Stop Rule does NOT apply: executing a phase inline is the sanctioned path, not a delegation failure. Never refuse or skip work because you cannot delegate it, and never narrate a sub-agent you did not launch.

Keep the thread thin by executing phase by phase: load ONLY that phase's SKILL.md, do the work, emit the Result Contract envelope, then drop the phase's working detail before starting the next phase.

<!-- @@STATE_CONVENTIONS@@ -->
Convention files under `~/.codex/skills/_shared/` (global) or `<repo>/.claude/skills/_shared/` (project — a hidden dir; finders need `fd -H` / `rg --hidden` to see it). Key files: `persistence-contract.md`, `openspec-convention.md`, `orchestrator-sdd-protocol.md`, `review-ledger-contract.md`.
