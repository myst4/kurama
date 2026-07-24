<!--
Overlay for OpenCode (examples/opencode/AGENTS.md).
Holds ONLY this harness's deltas; the shared body lives in core.md.
-->

<!-- @@HEADER@@ -->
# Kurama — Orchestrator Instructions

Bind this to the dedicated `sdd-orchestrator` agent or rule only. Do NOT apply it to executor phase agents such as `sdd-apply` or `sdd-verify`.

<!-- @@DELEGATION_MECHANISM@@ -->
delegate (async) is the default for delegated work. Use task (sync) only when you need the result before your next action.

<!-- @@NATIVE_NOTES@@ -->
### Single vs multi config

This example ships two OpenCode configs — install exactly one per project:

- `opencode.multi.json` (recommended) — installs this orchestrator plus a dedicated subagent per SDD phase (`sdd-explore`, `sdd-propose`, `sdd-apply`, …). The `/sdd-<phase>` executor commands route straight to those agents, and each phase can run on its own model. Delegate each phase to its matching `sdd-<phase>` agent.
- `opencode.single.json` — installs this orchestrator only, with no dedicated phase agents. Run each SDD phase as a subtask of the built-in `general` subagent, injecting that phase's skill rules into the subtask prompt. Drive the flow through the `/sdd-new`, `/sdd-continue`, and `/sdd-ff` meta-commands; the direct `/sdd-<phase>` executor commands require the multi config. Lightest setup.

When delegating, target the `sdd-<phase>` agents in multi mode and the `general` subagent in single mode.

### Named model profiles (optional)

A **profile** is a named parallel set of agents that share the SDD prompts and vary only their `model`. Installing one (`setup.sh --agent opencode --opencode-profile NAME[:provider/model]`) splices a `kurama-orchestrator` agent (`mode:primary`) plus suffixed `sdd-<phase>-NAME` subagents (`mode:subagent`, `hidden`) into `opencode.json`, all referencing the shared `~/.config/opencode/prompts/sdd/sdd-<phase>.md` prompt files. In the OpenCode TUI press **Tab** to cycle among the `mode:primary` orchestrators. The `/sdd-*` slash commands stay frontmatter-pinned to the base agents (executor commands → `sdd-<phase>`, meta commands → `sdd-orchestrator`), so they ignore the selected primary and run at their default models. To use a profile's per-phase models, select `kurama-orchestrator` and drive the flow with a **freeform** (non-slash) request; it delegates only to its own `sdd-<phase>-NAME` subagents, each carrying the profile's configured model. Models are edited by hand in `opencode.json` (or set once via the flag's `:provider/model`) — there is no picker. See `docs/opencode-profiles.md`.

<!-- @@MODEL_ASSIGNMENTS_SECTION@@ -->
<!-- gentle-ai:sdd-model-assignments -->
## Model Assignments

Read this table at session start (or before first delegation), cache it for the session, and pass the mapped alias in every Agent tool call via the `model` parameter. If a phase is missing, use the `default` row. If you lack access to the assigned model, substitute `sonnet` and continue.

When running under a named profile (the `kurama-orchestrator` primary), the per-phase models come from the `sdd-<phase>-NAME` agent entries in `opencode.json` rather than from these aliases; delegate to those suffixed subagents and let each carry its own configured model. This table remains the default guidance for the base `sdd-orchestrator`.

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
