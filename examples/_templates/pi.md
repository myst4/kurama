<!--
Overlay for Pi (examples/pi/AGENTS.md).
Holds ONLY this harness's deltas; the shared body lives in core.md.

Context-file convention: gentle-ai's Pi integration (docs/pi.md) installs the
Gentleman harness as npm packages (`gentle-pi`, `gentle-engram`, …) that own
persona, model routing, SDD agents, and memory wiring under `.pi/agents/*.md`
and the global `~/.pi/agent/APPEND_SYSTEM.md`. Agent Teams Lite is markdown-pure
and deliberately does NOT depend on `gentle-pi`, so there is no npm-owned system
file to append to. The portable, package-free place for this orchestrator rule
is the project-root `AGENTS.md` — a convention Pi supports natively — with the
global `~/.pi/agent/APPEND_SYSTEM.md` as the per-user alternative.

Pi routes models per-agent (each Pi agent carries its own model in frontmatter),
not via an orchestrator-passed Agent `model` param, so the MODEL_ASSIGNMENTS
token is omitted and renders empty (like codex/gemini-cli).
-->

<!-- @@HEADER@@ -->
# Agent Teams Lite — Orchestrator Instructions for Pi

Add this to `AGENTS.md` in your project root (Pi loads it as project context). Alternatively, place it in the global `~/.pi/agent/APPEND_SYSTEM.md`. Bind it to the coordinator role only — do NOT apply it to executor phase agents such as `sdd-apply` or `sdd-verify`.

<!-- @@DELEGATION_MECHANISM@@ -->
Delegate real work to a Pi sub-agent (`.pi/agents/` or `.pi/subagents/`) via Pi's native sub-agent mechanism. When no dedicated per-phase agent is installed, run the matching SDD skill phase as a subtask of a general agent, injecting that phase's skill rules into the subtask prompt. Keep only coordination in this thread. Pi does not guarantee async delegation, so treat delegated work as blocking unless your Pi setup exposes a non-blocking sub-agent primitive.

<!-- @@NATIVE_NOTES@@ -->
### Pi assets & markdown-pure setup

This example is markdown-only — it does not install the `gentle-pi` npm stack, and it does not require Engram (any persistence backend from the Artifact Store Policy works). Install the SDD skills into Pi's skills directory and, optionally, add one Pi agent per SDD phase under `.pi/agents/` so `/sdd-<phase>` routes straight to it; without per-phase agents, drive the flow through the `/sdd-new`, `/sdd-continue`, and `/sdd-ff` meta-commands and run each phase as a subtask.

Model routing lives in each Pi agent's own frontmatter (or, under `gentle-pi`, the `/gentleman:models` modal), not in an orchestrator-passed `model` parameter — which is why there is no Model Assignments block below. Use the reasoning-effort shape recommended for each phase (fast/cheap for explore, propose, archive; stronger reasoning for spec, design, tasks; strong coding for apply; independent fresh context for verify/review) when assigning per-agent models.

<!-- @@STATE_CONVENTIONS@@ -->
Convention files under `~/.pi/skills/_shared/` (global) or `.agent/skills/_shared/` (workspace): `engram-convention.md`, `persistence-contract.md`, `openspec-convention.md`.
