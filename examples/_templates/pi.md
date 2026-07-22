<!--
Overlay for Pi (examples/pi/AGENTS.md).
Holds ONLY this harness's deltas; the shared body lives in core.md.

Context-file convention (verified against the upstream Pi coding agent —
earendil-works/pi, badlogic/pi-mono, pi.dev): Pi loads `AGENTS.md` context files
at startup and concatenates three locations — the global `~/.pi/agent/AGENTS.md`,
parent directories, and the project-root `AGENTS.md`. gentle-ai's Pi integration
(docs/pi.md) layers the Gentleman harness on top as npm packages (`gentle-pi`,
`gentle-engram`, …) that own persona, model routing, SDD agents, and memory
wiring under `.pi/agents/*.md`. Kurama is markdown-pure and deliberately does NOT
depend on `gentle-pi`. The portable, package-free home for this orchestrator rule
is therefore an `AGENTS.md` context file: the project-root `AGENTS.md` for
per-project scope, or the global `~/.pi/agent/AGENTS.md` for all sessions — which
is what `setup.sh --agent pi` and `install.sh --agent pi` write, via the standard
BEGIN/END:kurama markers. `~/.pi/agent/APPEND_SYSTEM.md` is a separate mechanism
for terse global system rules appended to Pi's deliberately small (<1000-token)
system prompt, not the right place for a large orchestrator doc.

Pi routes models per-agent (each Pi agent carries its own model in frontmatter),
not via an orchestrator-passed Agent `model` param, so the MODEL_ASSIGNMENTS
token is omitted and renders empty (like codex/gemini-cli).
-->

<!-- @@HEADER@@ -->
# Kurama — Orchestrator Instructions for Pi

Add this to an `AGENTS.md` context file that Pi loads at startup: the project-root `AGENTS.md` for a single project, or the global `~/.pi/agent/AGENTS.md` for every session (this is where `setup.sh --agent pi` / `install.sh --agent pi` place it). Bind it to the coordinator role only — do NOT apply it to executor phase agents such as `sdd-apply` or `sdd-verify`.

<!-- @@DELEGATION_MECHANISM@@ -->
Delegate real work to a Pi sub-agent (`.pi/agents/` or `.pi/subagents/`) via Pi's native sub-agent mechanism. When no dedicated per-phase agent is installed, run the matching SDD skill phase as a subtask of a general agent, injecting that phase's skill rules into the subtask prompt. Keep only coordination in this thread. Pi does not guarantee async delegation, so treat delegated work as blocking unless your Pi setup exposes a non-blocking sub-agent primitive.

<!-- @@NATIVE_NOTES@@ -->
### Pi assets & markdown-pure setup

This example is markdown-only — it does not install the `gentle-pi` npm stack, and it does not require Engram (any persistence backend from the Artifact Store Policy works). Install the SDD skills into Pi's skills directory (`~/.pi/agent/skills/` globally, or `.pi/skills/` per project) and, optionally, add one Pi agent per SDD phase under `.pi/agents/` so `/sdd-<phase>` routes straight to it; without per-phase agents, drive the flow through the `/sdd-new`, `/sdd-continue`, and `/sdd-ff` meta-commands and run each phase as a subtask.

Model routing lives in each Pi agent's own frontmatter (or, under `gentle-pi`, the `/gentleman:models` modal), not in an orchestrator-passed `model` parameter — which is why there is no Model Assignments block below. Use the reasoning-effort shape recommended for each phase (fast/cheap for explore, propose, archive; stronger reasoning for spec, design, tasks; strong coding for apply; independent fresh context for verify/review) when assigning per-agent models.

<!-- @@STATE_CONVENTIONS@@ -->
Convention files under `~/.pi/agent/skills/_shared/` (global) or `.pi/skills/_shared/` (workspace): `engram-convention.md`, `persistence-contract.md`, `openspec-convention.md`.
