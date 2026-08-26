<!--
Overlay for omp (examples/omp/AGENTS.md).
Holds ONLY this harness's deltas; the shared body lives in core.md.

omp is NOT Pi with a different name. It is a separate binary (`omp`) with its own
config root (`~/.omp/agent/`), and the two layouts are incompatible:

  | concern     | Pi                      | omp                          |
  |-------------|-------------------------|------------------------------|
  | skills      | ~/.pi/agent/skills/     | ~/.omp/agent/skills/         |
  | context     | ~/.pi/agent/AGENTS.md   | ~/.omp/agent/AGENTS.md       |
  | subagents   | ~/.pi/agent/agents/     | ~/.omp/agent/agents/         |
  | sticky rules| (none)                  | ~/.omp/agent/RULES.md        |

Verified against omp's own docs (omp://skills.md, omp://context-files.md,
omp://task-agent-discovery.md) on omp v17.1.3:

- SKILLS: discovery is non-recursive at `<skills-root>/<name>/SKILL.md`, which is
  exactly Kurama's layout. The `native` provider (priority 100) reads
  `~/.omp/agent/skills` and requires `description` frontmatter — validate_skills.sh
  already enforces that on every skill, so the set installs unmodified.
- CONTEXT: the `native` provider has the highest priority (100), so
  `~/.omp/agent/AGENTS.md` shadows every other user-level context file. Project
  scope uses the nearest non-empty `<ancestor>/.omp/AGENTS.md`, with walk-up to the
  repo root — better than a standalone AGENTS.md, which the low-priority
  `agents-md` provider (10) would supply.
- SUBAGENTS: this is the load-bearing difference. omp DELIBERATELY skips
  cross-harness agent roots — `.claude/agents`, `.codex/agents`, `.gemini/agents`
  are filtered out because their frontmatter is not the omp task-agent contract
  (TASK_AGENT_CONFIG_SOURCE = ".omp"). Pi-format agents are therefore invisible to
  omp. Kurama ships a dedicated omp set under examples/omp/agents/ so the phases
  get real isolated contexts instead of degrading to inline.
- RULES.md: omp's sticky-rule primitive, re-attached near the current turn so it
  survives long conversations. Pi has no equivalent. The orchestrator's three
  hard invariants live there (see examples/omp/RULES.md) because they are exactly
  the rules that must not decay as the transcript grows.

Model routing: omp resolves a subagent's model from `task.agentModelOverrides`,
then the agent's frontmatter `model`, then the parent session model. There is no
orchestrator-passed model parameter, so MODEL_ASSIGNMENTS is omitted and renders
empty (same as pi/codex).
-->

<!-- @@HEADER@@ -->
# Kurama — Orchestrator Instructions for omp

This is a context file omp discovers at startup. `setup.sh --agent omp` writes it to `~/.omp/agent/AGENTS.md` (global) or `<repo>/.omp/AGENTS.md` (project scope), between the standard BEGIN/END:kurama markers. The `native` provider has omp's highest discovery priority, so this file shadows every other user-level context convention.

Bind it to the coordinator role only — it must NOT apply to executor phase agents such as `sdd-apply` or `sdd-verify`. Those run as omp task agents from `~/.omp/agent/agents/`, each with its own system prompt.

<!-- @@DELEGATION_MECHANISM@@ -->
Delegate with the `task` tool, naming the phase agent: `task(agent: "sdd-apply", …)`. Kurama installs one omp task agent per SDD phase plus the review layer into `~/.omp/agent/agents/` (or `<repo>/.omp/agents/` in project scope), so every phase runs in a genuinely fresh context with its own tool allowlist — the read-only review lenses are enforced read-only by their `tools:` frontmatter.

Batch independent slices into ONE `task` call with multiple items; that is a real parallel wave. `spec` and `design` are the canonical pair. Sequential phases go in separate calls.

Two omp specifics that change how you delegate:

- **`hub` is available for coordination.** A phase that needs a decision from you mid-run can message you instead of failing; you can also `hub wait` when genuinely blocked. Prefer a `blocked` envelope for contract violations — `hub` is for questions, not for routing around the phase contract.
- **Recursion depth is capped.** At `task.maxRecursionDepth` the `task` tool is removed from child sessions, so a phase agent cannot spawn further agents even if its definition allowed it. This matches the Kurama rule that phases are EXECUTORS and never delegate; the harness enforces mechanically what the contract states.

<!-- @@NATIVE_NOTES@@ -->
### omp assets

`setup.sh --agent omp` installs three things:

| Asset | Global | Project scope |
|---|---|---|
| Skills | `~/.omp/agent/skills/` | `<repo>/.omp/skills/` |
| This orchestrator prompt | `~/.omp/agent/AGENTS.md` | `<repo>/.omp/AGENTS.md` |
| Native task agents | `~/.omp/agent/agents/` | `<repo>/.omp/agents/` |

If `PI_CODING_AGENT_DIR` is set, it relocates the user base and every path above moves with it.

**The agent set is omp-specific and not interchangeable.** omp filters out `.claude/agents`, `.codex/agents`, and `.gemini/agents` on purpose — their frontmatter is not omp's task-agent contract. Installing Kurama's Claude or Pi agents would leave them silently invisible, and the cycle would degrade to inline execution with no context isolation.

**Skills reach the model as metadata plus on-demand content.** omp puts each skill's name and description in the system prompt and loads the body only when read through `skill://<name>`. So the `_shared` convention files a phase needs are pulled at the moment they apply — `skill://sdd-apply` for a phase, and any `skill://<name>/<relative-path>` asset inside a skill directory.

The shipped agents carry no `model` in their frontmatter: each one inherits the session's default model, so the setup works unchanged on any provider omp runs against. To route specific phases to specific models, add `model` to an agent's frontmatter locally or set `task.agentModelOverrides` — there is no orchestrator-passed `model` parameter, which is why there is no Model Assignments block below.

**`/skill:<name>` commands** are available when `skills.enableSkillCommands` is on, which gives the user a direct way to invoke a phase skill's text. That is a user entry point, not a delegation mechanism: it injects skill text into THIS thread rather than opening a fresh context, so it never substitutes for a `task` delegation.

<!-- @@STATE_CONVENTIONS@@ -->
Convention files are reachable as skill-relative URLs — `skill://sdd-apply`, and for the shared contracts read them from the installed `_shared` directory: `~/.omp/agent/skills/_shared/` (global) or `<repo>/.omp/skills/_shared/` (project) — both hidden dirs; finders need `fd -H` / `rg --hidden` to see them. Key files: `sdd-phase-common.md`, `persistence-contract.md`, `openspec-convention.md`, `orchestrator-sdd-protocol.md`, `review-ledger-contract.md`.
