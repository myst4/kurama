<!--
Overlay for OpenCode (examples/opencode/AGENTS.md).
Holds ONLY this harness's deltas; the shared body lives in core.md.
-->

<!-- @@HEADER@@ -->
# Kurama — Orchestrator Instructions

Bind this to the dedicated `sdd-orchestrator` agent or rule only. Do NOT apply it to executor phase agents such as `sdd-apply` or `sdd-verify`.

<!-- @@DELEGATION_MECHANISM@@ -->
task is the tool for delegated work — it is OpenCode's native sub-agent mechanism and needs no plugin. For background execution, start OpenCode with `OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS=true` exported in your shell.

<!-- @@NATIVE_NOTES@@ -->
### Single vs multi config

This example ships two OpenCode configs — install exactly one per project:

- `opencode.multi.json` (recommended) — installs this orchestrator plus a dedicated subagent per SDD phase (`sdd-explore`, `sdd-propose`, `sdd-apply`, …). The `/sdd-<phase>` executor commands route straight to those agents, and each phase can run on its own model. Delegate each phase to its matching `sdd-<phase>` agent.
- `opencode.single.json` — installs this orchestrator only, with no dedicated phase agents. Run each SDD phase as a subtask of the built-in `general` subagent, injecting that phase's skill rules into the subtask prompt. Drive the flow through the `/sdd-new`, `/sdd-continue`, and `/sdd-ff` meta-commands; the direct `/sdd-<phase>` executor commands require the multi config. Lightest setup.

When delegating, target the `sdd-<phase>` agents in multi mode and the `general` subagent in single mode.

OpenCode ships no review-layer agents: in BOTH modes run each review lens (`review-*`, `jd-*`) as a `general` subtask with that lens's skill rules injected. Both configs allow `general` for exactly this.

### `/sdd-status` (OpenCode only)

Read-only report of every active SDD cycle — last completed phase, next phase, task progress. It runs no phase work, and no other harness installs it: never assume it exists elsewhere.

### Named model profiles (optional)

A **profile** is a named parallel agent set that shares the SDD prompts and varies only its `model`. Installing one (`setup.sh --agent opencode --opencode-profile NAME[:provider/model]`) splices a `kurama-orchestrator` primary plus hidden `sdd-<phase>-NAME` subagents into `opencode.json`, all referencing the shared `~/.config/opencode/prompts/sdd/` prompt files. Press **Tab** in the TUI to cycle primaries. The `/sdd-*` slash commands stay frontmatter-pinned to the base agents, so they ignore the selected primary and run at their default models; to use a profile's per-phase models, select `kurama-orchestrator` and drive the flow with a **freeform** (non-slash) request; it delegates SDD phases to its own `sdd-<phase>-NAME` subagents and review lenses to `general`. Models are hand-edited in `opencode.json` (or set once via the flag's `:provider/model`) — there is no picker. See `docs/opencode-profiles.md`.

<!-- @@MODEL_ASSIGNMENTS_SECTION@@ -->
<!-- kurama:sdd-model-assignments -->
### Model Routing

By default, pass NO `model` parameter when delegating: every sub-agent inherits the model this session is configured to run, whatever the provider. Tiered per-phase routing is opt-in and lives in `skills/_shared/model-assignments.md` — read it only when the user has opted in through their own configuration (agent entries in `opencode.json`, or a named profile), and never let it override a model the user configured.
<!-- /kurama:sdd-model-assignments -->

<!-- @@STATE_CONVENTIONS@@ -->
Convention files under `~/.config/opencode/skills/_shared/` (global) or `<repo>/.claude/skills/_shared/` (project fallback — a hidden dir; finders need `fd -H` / `rg --hidden` to see it). Key files: `engram-convention.md`, `persistence-contract.md`, `openspec-convention.md`, `orchestrator-sdd-protocol.md`, `review-ledger-contract.md`.
