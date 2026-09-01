Reference documentation for the SDD phase sub-agents and skill system. For quick start, see the [main README](../README.md).

# Sub-Agents & Skill Registry

## SDD Phase Sub-Agents

Each sub-agent is a SKILL.md file — pure Markdown instructions that any AI assistant can follow. The preferred path is for the orchestrator to pre-resolve relevant skills from the registry and inject compact rules into each sub-agent prompt. Sub-agents still support registry/path fallback for backward compatibility.

| Sub-Agent | Skill File | What It Does |
|-----------|-----------|-------------|
| **Init** | `sdd-init/SKILL.md` | Detects project stack, bootstraps persistence, builds skill registry |
| **Explorer** | `sdd-explore/SKILL.md` | Reads codebase, compares approaches, identifies risks |
| **Proposer** | `sdd-propose/SKILL.md` | Creates `proposal.md` with intent, scope, rollback plan |
| **Spec Writer** | `sdd-spec/SKILL.md` | Writes delta specs (ADDED/MODIFIED/REMOVED) with Given/When/Then |
| **Designer** | `sdd-design/SKILL.md` | Creates `design.md` with architecture decisions and rationale |
| **Task Planner** | `sdd-tasks/SKILL.md` | Breaks down into phased, numbered task checklist |
| **Implementer** | `sdd-apply/SKILL.md` | Writes code following specs and design, marks tasks complete. v2.0: TDD workflow support |
| **Verifier** | `sdd-verify/SKILL.md` | Validates implementation against specs with real test execution. v2.0: spec compliance matrix |
| **Archiver** | `sdd-archive/SKILL.md` | Merges delta specs into main specs, moves to archive |
| **TDD Module** | `tdd/SKILL.md` | Optional RED-GREEN-REFACTOR cycle contract; loaded by `sdd-apply` when TDD resolves active, referenced by `sdd-tasks` and `sdd-verify`. Installed by default (`tdd` manifest group, `default: true`); activation stays opt-in per project — opt out of the module with `install.sh --without tdd` |
| **Skill Registry** | `skill-registry/SKILL.md` | Scans user skills + project conventions, writes `.kurama/skill-registry.md` |
| **Judgment Day** | `judgment-day/SKILL.md` | Runs dual adversarial review with two blind judges and a fix loop |
| **Go Testing** | `go-testing/SKILL.md` | Go test conventions, including Bubbletea and teatest patterns. `lang` group, OFF by default — opt in with `install.sh --with lang` |
| **Skill Creator** | `skill-creator/SKILL.md` | Creates new reusable skills following the project skill spec |
| **Branch + PR** | `branch-pr/SKILL.md` | Branches changes and opens pull requests with repo conventions |
| **Issue Creation** | `issue-creation/SKILL.md` | Creates GitHub issues with the repo's structured templates |

### Meta-Skills (Workflow Entry Points)

Three thin skills sit above the phase table and drive it, instead of executing
a single phase themselves. They are real, user-invocable skills (not
orchestrator-only prompt text) that ship as `skills/sdd-new/SKILL.md`,
`skills/sdd-continue/SKILL.md`, and `skills/sdd-ff/SKILL.md`. They are
registered in the required `sdd-core` group in `skills/manifest.json`, so the
manifest-driven `setup.sh`/`install.sh` install all three by default — no
manual copy step is needed:

| Meta-Skill | Skill File | What It Does |
|------------|-----------|-------------|
| **Start** | `sdd-new/SKILL.md` | Starts a new SDD change: delegates exploration and proposal for a fresh change name |
| **Resume** | `sdd-continue/SKILL.md` | Resumes an existing change from persisted state; runs the next dependency-ready phase in the DAG |
| **Fast-forward** | `sdd-ff/SKILL.md` | Auto-continues through the remaining planning phases without a per-phase approval pause |

### Sub-Agent Result Contract

Every sub-agent returns a structured envelope (`status`, `executive_summary`, `detailed_report`, `artifacts`, `next_recommended`, `risks`, `skill_resolution`) to the orchestrator, closed by a `## Key Learnings` section. The canonical field list, description, and example live in [`skills/_shared/sdd-phase-common.md`](../skills/_shared/sdd-phase-common.md), Section D — see it there instead of duplicating it here.

**Key Learnings** is that closing section: 1-5 numbered items, each a gotcha, an edge case, or a non-obvious decision the phase discovered, written as a standalone sentence (at least 20 characters and 4 words — Engram's extraction thresholds, not style advice) that names *what*, *why it matters*, and *where*. It is **omitted entirely** when the phase found nothing non-obvious, it never restates `executive_summary`, and it never carries a secret or an absolute machine path. It applies to the phase's final text response, not to intermediate tool output or to the persisted artifact body. The same section serves the two memory stores without replacing either — Engram captures it passively for one developer, and `sdd-learn` curates the team's committed `MEMORY.md` from it at cycle close; the boundary between the four stores is the table in [docs/persistence.md](persistence.md#memorymd--durable-team-knowledge).

### Sub-Agent Context Protocol

Sub-agents start with a **fresh context**. The canonical injection and fallback protocol — how the orchestrator resolves the registry, matches skills, injects compact rules as `## Project Standards (auto-resolved)`, and how sub-agents report `skill_resolution` back — lives in [`skills/_shared/skill-resolver.md`](../skills/_shared/skill-resolver.md); this section only summarizes it: if no `## Project Standards` block arrives, sub-agents fall back to registry lookup or explicit `SKILL: Load` paths.

Sub-agents are also instructed to save discoveries, decisions, and bug fixes to engram automatically (non-SDD sub-agents) or via the mandatory persist step (SDD phases).

The same contract closes the cycle it opens: once the envelope has been read, validated and synthesized, the orchestrator **reaps the sub-agent** — a delegation is not complete while a finished agent is still holding its context in the agent list. On Claude Code that is the shutdown request to the named teammate; on a harness with no termination primitive it is holding no reference to the agent and saying so. The single exception, and the way to declare it, is in [`skills/_shared/skill-resolver.md`](../skills/_shared/skill-resolver.md) → *Step 5*: keep an agent alive only while you still intend to send it a follow-up message, and name that intent when you decide it.

---

## Shared Conventions

`skills/_shared/` contains eight files. `sdd-phase-common.md` is loaded directly by all 8 SDD phase skills (explore through archive) — it is the most load-bearing shared file in the system. Critical engram calls (`mem_search`, `mem_save`, `mem_get_observation`) are also **inlined directly in each skill** so sub-agents don't need to follow multi-hop file references.

| File | Purpose |
|------|---------|
| `sdd-phase-common.md` | Sections A-D: skill loading, artifact retrieval, persistence, and the return envelope. Loaded directly by every SDD phase skill. |
| `orchestrator-sdd-protocol.md` | The orchestrator's session-level SDD procedure: the four-value session preflight, routing a natural-language request into the pipeline, and the `auto`-mode phase gate. Loaded when a cycle starts, not before — the orchestrator prompt carries the trigger, this file carries the procedure. |
| `persistence-contract.md` | Mode resolution rules, sub-agent context protocol, skill registry loading protocol |
| `engram-convention.md` | Supplementary reference for deterministic naming (`sdd/{change-name}/{artifact-type}`) and two-step recovery. Critical calls are inlined in skills. |
| `openspec-convention.md` | Filesystem paths for each artifact, directory structure, config.yaml reference, and archive layout. **Not** the upstream OpenSpec CLI format — see the note at the top of that file. |
| `skill-resolver.md` | **Canonical** protocol for delegators to inject compact rules from the skill registry |
| `review-ledger-contract.md` | **Canonical** shared contract for the 4R review lenses + refuter: sweep budget, precision gate, candidate-causal admission, findings-ledger schema, adversarial verification, severity floor, and artifact-store-aware persistence. |
| `test-runners.md` | Per-runner detect → full-suite + single-test command table, used by the optional TDD module (`skills/tdd/SKILL.md`) |

**Why inline + shared:**
- **Sub-agents fail multi-hop chains** — A 3-hop read chain (skill → convention file → actual instructions) breaks non-Claude models. Inlining the critical calls eliminates this.
- **Deterministic recovery** — Engram artifact naming follows a strict `sdd/{change}/{type}` convention with `topic_key`, so any skill can reliably find artifacts created by other skills.
- **Consistent mode behavior** — All skills resolve `engram | openspec | hybrid` the same way. `openspec` and `hybrid` are never chosen automatically.

---

## Review Lenses (4R + refuter)

The post-implementation review layer is a set of **read-only** sub-agent lenses the
orchestrator runs after `sdd-apply`. Each lens is a `SKILL.md` whose contract is
read-only — it finds defects and never edits, runs, or delegates. When the lenses run
as native Claude Code agents (installed by default, see
[Native Claude Code Subagents](#native-claude-code-subagents-installed-automatically)),
that read-only boundary is **enforced by the agent's `tools:` list**, not merely
documented — the frontmatter omits `Edit`/`Write` and `Task`, so the lens is
structurally unable to modify code or spawn sub-agents.

| Lens | Skill File | Domain |
|------|-----------|--------|
| **R1 Risk** | `review-risk/SKILL.md` | Security, privilege boundaries, data exposure, dependency risk |
| **R2 Readability** | `review-readability/SKILL.md` | Naming, complexity, intent, maintainability, review size |
| **R3 Reliability** | `review-reliability/SKILL.md` | Behavior-first tests, coverage value, edge cases, determinism, regressions |
| **R4 Resilience** | `review-resilience/SKILL.md` | Fallbacks, retry/backoff, graceful degradation, observability, rollback |
| **Refuter** | `review-refuter/SKILL.md` | Adversarial verifier — adjudicates inferential findings `corroborated`/`refuted`/`inconclusive` |

**Which lenses run is decided by the orchestrator's deterministic triage, not by the
lenses themselves** (they never self-select). See the "Review Lens Selection" section in
the generated orchestrator (`examples/_templates/core.md` → each `examples/<harness>/`
file):

- **Trivial diff** (only docs/comments/formatting) → no lens.
- **Standard diff** → exactly ONE lens, chosen by dominant risk (naming/structure →
  readability; behavior/tests/determinism → reliability; shell/partial-failure/recovery →
  resilience; security/permissions/data/deps → risk).
- **Hot path** (auth/update/security/payments) **or >400 authored lines** → the full 4R
  sweep. `judgment-day` stays reserved for explicit invocation or escalation.

All lenses share one contract, [`skills/_shared/review-ledger-contract.md`](../skills/_shared/review-ledger-contract.md):
**candidate-causal admission** (only findings introduced by the diff can block;
pre-existing findings become follow-ups), a **severity floor** (only `BLOCKER`/`CRITICAL`
gate; `WARNING`/`SUGGESTION` are recorded once as `info`), sweep budget 1 (standard) / 2
(4R), refuter verdicts with 2-of-3 voting in 4R, and max 2 fix rounds. The merged
findings ledger persists per the artifact store (engram `topic_key
sdd/{change-name}/review-ledger`, openspec `openspec/changes/{change}/review-ledger.md`,
or in the `.kurama/sdd/` fallback when Engram is unavailable).

---

## Skill Registry

Sub-agents start with a **fresh context** — they do not know what user skills exist (React, TDD, Playwright, etc.). The skill registry solves this, and the orchestrator uses it to inject compact rules before each delegation.

**How the registry gets built:**
1. `/sdd-init` or `/skill-registry` scans your installed skills and project conventions
2. Writes `.kurama/skill-registry.md` in the project root (mode-independent, always created)
3. If engram is available, also saves to engram (cross-session bonus)

Once the registry exists, resolving it and injecting compact rules into each delegation follows the canonical protocol in [`skills/_shared/skill-resolver.md`](../skills/_shared/skill-resolver.md) — see that file for the full resolution order, injection format, fallback chain, and the `skill_resolution` feedback loop.

**Preferred path:** the orchestrator pre-resolves compact rules. Sub-agent self-loading is only a compatibility fallback.

**What it contains:**
- User skills table: trigger → skill name → path (e.g., "React components" → `react-19` → `~/.claude/skills/react-19/SKILL.md`)
- Compact rules blocks: short, pre-digested instructions that delegators paste directly into sub-agent prompts
- Project conventions found: `agents.md`, `AGENTS.md`, `CLAUDE.md`, etc.

**When to update:** Run `/skill-registry` after installing or removing skills.

---

## Per-Agent Model Routing

`opencode.multi.json` gives each `sdd-<phase>` agent its own entry in `opencode.json`, and any of them can carry a `model` field to select which model it should use. When the orchestrator delegates with the native `task` tool, OpenCode runs the sub-agent under its own entry, so it uses that agent's configured model.

> **Background execution.** Kurama no longer ships the `background-agents.ts` plugin — it is third-party code that was observed hanging the OpenCode TUI at startup, and OpenCode now covers the feature itself. To opt into background sub-agents, export OpenCode's own experimental switch in your shell before launching it:
>
> ```sh
> export OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS=true
> opencode
> ```

Per-agent model routing is a **multi**-mode feature only. `opencode.single.json` defines the orchestrator agent alone — each SDD phase runs as a subtask of the orchestrator and inherits its model, since there is no separate per-phase agent to attach a `model` field to.

**Example** (`opencode.multi.json`):

```json
{
  "sdd-explore": {
    "model": "<your-provider/your-model>",
    "mode": "subagent",
    ...
  },
  "sdd-spec": {
    "model": "<your-provider/your-model>",
    "mode": "subagent",
    ...
  }
}
```

**Alternative: `@agent-name` text mentions.** OpenCode also supports routing via `@agent-name` mentions in the orchestrator's output, which triggers native agent routing. This is an alternative to `task` but is NOT required — `task` handles model routing correctly.

---

## Native Claude Code Subagents (installed automatically)

Claude Code supports declarative subagents defined as Markdown files with
frontmatter, as an alternative to the generic
`Task(subagent_type: 'general', prompt: 'Read skill...')` pattern the
orchestrator uses by default. This repo ships **17** such definitions in
[`examples/claude-code/agents/`](../examples/claude-code/agents/), and
`setup.sh --agent claude-code` installs **all of them** into `~/.claude/agents/`
(atomic copy, timestamped backup of any same-named file, every file recorded in
the target's `.kurama-install-manifest.json` receipt — see
[installation](installation.md#native-subagents-installed-automatically)).

The 17 split into the **9 SDD phase** agents and the **8 review-layer** agents:

| Group | Agents | Count |
|-------|--------|-------|
| SDD phases | `sdd-init`, `sdd-explore`, `sdd-propose`, `sdd-spec`, `sdd-design`, `sdd-tasks`, `sdd-apply`, `sdd-verify`, `sdd-archive` | 9 |
| 4R review lenses | `review-risk`, `review-readability`, `review-reliability`, `review-resilience` | 4 |
| Adversarial refuter | `review-refuter` | 1 |
| Judgment Day judges | `jd-judge-a` (Correctness & Security), `jd-judge-b` (Regressions & Resilience) | 2 |
| Judgment Day fix agent | `jd-fix-agent` | 1 |

Each file's frontmatter declares `name`, `description`, and `tools`;
the body is **thin** — it instructs the subagent to load and follow its
corresponding Kurama skill (the phase `SKILL.md` for SDD agents; the
`review-*/SKILL.md` + [`skills/_shared/review-ledger-contract.md`](../skills/_shared/review-ledger-contract.md)
for the lenses; `skills/review-refuter/SKILL.md` for the refuter;
`skills/judgment-day/SKILL.md` for the judges and fix agent) and to return the
envelope that skill defines. The agent never duplicates the skill body — the
skill remains the single source of truth.

### Model & tools routing

**Tool** routing is **declarative** (in each agent's frontmatter). **Model**
routing is deliberately not: the agents ship with **no `model` pin**, so every
one of them inherits the session's default model. Models rotate; pins rot — an
agent without a `model` key keeps working when the user's provider or model
lineup changes. To give specific agents a tiered model, add `model` to their
frontmatter locally; the Model Assignments table in
[`skills/_shared/model-assignments.md`](../skills/_shared/model-assignments.md) is the
recommended split for anyone who wants that routing. The 9 SDD agents are
unchanged from before; the 8 review-layer agents follow the tool routing below:

| Agent(s) | `tools` |
|----------|---------|
| SDD phases | (phase tools) |
| `review-risk`, `review-readability`, `review-reliability`, `review-resilience` | `Read, Grep, Glob` |
| `review-refuter` | `Read, Grep, Glob` |
| `jd-judge-a`, `jd-judge-b` | `Read, Grep, Glob` |
| `jd-fix-agent` | `Read, Edit, Write, Glob, Grep, Bash` |

**The 4R lenses, the refuter, and the two judges run read-only — and that is
enforced declaratively by their `tools:` list**, not just by convention. Each
declares only `Read, Grep, Glob`: omitting `Edit`/`Write` makes it structurally
unable to modify the code it judges, and omitting `Task` prevents it from
delegating to further sub-agents. The only review-layer agent that can write is
`jd-fix-agent` — the surgical fix step — which is why it alone carries
`Edit`/`Write`/`Bash`, and even it omits `Task`.

Removing `examples/claude-code/agents/` is safe: a project without the agent
files keeps working exactly as before, with the orchestrator resolving skills
and models itself per the Model Assignments table in
[`skills/_shared/model-assignments.md`](../skills/_shared/model-assignments.md). **The
deterministic hooks are now installed automatically** by
`setup.sh --agent claude-code` (both scopes, no prompt — this changed in Phase
10b; see [docs/installation.md](installation.md#hooks-installed-automatically)
and [docs/hooks.md](hooks.md)).

---

## Native Pi Subagents (installed automatically)

Pi supports the same declarative-subagent pattern, and `setup.sh --agent pi`
installs the **same 17-agent roster** (9 SDD phases + 8 review-layer agents) in
**Pi's** agent format into `~/.pi/agent/agents/` (global) or
`<repo>/.pi/agents/` (`--scope project`), recorded in the receipt. The files
live in [`examples/pi/agents/`](../examples/pi/agents/).

Pi's format differs from Claude's in three ways:

- **`tools` is a YAML list of Pi tool names.** Read-only lenses, the refuter,
  and the two judges declare `tools: [read]`; `jd-fix-agent` declares
  `[read, bash]`; SDD phase executors carry the fuller phase set (`read`,
  `grep`, `find`, `write`, and the `memory_*` tools that back the `engram`
  store), plus `edit` and/or `bash` only where a phase needs them. `bash` is
  granted just to the phases that shell out — `sdd-init`, `sdd-explore`,
  `sdd-apply`, `sdd-verify`, `sdd-archive` — while the pure planning/writing
  phases (`sdd-propose`, `sdd-spec`, `sdd-design`, `sdd-tasks`) omit it; in
  particular **`sdd-design` has no `bash`** (see the per-agent table below). Pi
  also blocks every `subagent_*` tool, so no agent can delegate — the read-only
  boundary is enforced structurally, exactly as the Claude lenses' omitted
  `Edit`/`Write`/`Task` enforce theirs.
- **No `model` key — the reasoning hint is `effort`.** The agents ship with no
  `model` in their frontmatter and inherit the session's default model. A Pi
  pin would have to be `provider/model-id` — versioned **and**
  provider-qualified — so it would age out of the provider's lineup and break
  outright on a non-Anthropic Pi session. What ships instead is an `effort`
  hint where applicable, which is not provider-bound.
- **The body is the whole system prompt** (lean subagent mode auto-loads no
  skill). Each agent instructs itself to `read` its Kurama skill, resolving the
  path relative to the project in order — `skills/…` → `.pi/skills/…` →
  `~/.pi/agent/skills/…` → `.claude/skills/…` — then follow it and return that
  skill's envelope. The skill stays the single source of truth.

| Agent(s) | `tools` (Pi) |
|----------|--------------|
| `sdd-apply` | phase set incl. `write`, `edit`, `bash`, `memory_*` |
| `sdd-design` | phase set incl. `write`, `edit`, `memory_*` (no `bash`) |
| Other 7 SDD phases | phase set (read/inspect + phase-specific); `bash` only on `sdd-init`/`sdd-explore`/`sdd-verify`/`sdd-archive`, not on `sdd-propose`/`sdd-spec`/`sdd-tasks` |
| `review-risk`, `review-readability`, `review-reliability`, `review-resilience` | `[read]` |
| `review-refuter`, `jd-judge-a`, `jd-judge-b` | `[read]` |
| `jd-fix-agent` | `[read, bash]` |

Every agent inherits the session's default model; per-agent `effort` in each
file is a **default**. To route specific agents to specific models — or change
an `effort` — without editing the files, use `model_profiles` in
`.pi/subagents.json` (project) or `~/.pi/agent/subagents.json` (global), per
the `subagents-configuration` skill shipped with the `pi-subagents` extension;
adding `model` (`provider/model-id`) to an agent's frontmatter locally works
too. Kurama never writes `subagents.json` — it is the recommended, documented
override surface only.

---

## Native omp Subagents (installed automatically)

`setup.sh --agent omp` installs the **same 17-agent roster** in **omp's task-agent
format** into `~/.omp/agent/agents/` (global) or `<repo>/.omp/agents/`
(`--scope project`), recorded in the receipt. The files live in
[`examples/omp/agents/`](../examples/omp/agents/).

**This set is mandatory, not a convenience.** omp deliberately skips cross-harness
agent roots: `.claude/agents`, `.codex/agents`, and `.gemini/agents` are filtered out
because their frontmatter is not omp's task-agent contract. Kurama's Claude and Pi
agents are therefore **invisible** to omp, and without this set the SDD cycle silently
degrades to inline execution with no per-phase context isolation.

omp's format differs from Pi's in four ways:

- **`thinkingLevel`, not `effort`.** Same values (`low`/`medium`/`high`), different
  field name. A stray `effort:` is ignored, so the reasoning hint would be silently lost.
- **`glob`, not `find`.** Same capability, omp's name for the tool.
- **No `memory_*` tools.** omp has no built-in mem tools: its own memory is an
  autonomous pipeline read through `memory://` with the `read` tool, and Engram — when a
  project uses it — arrives as MCP tools whose names depend on the registered server. So
  the portable allowlist is the file tools plus `read`, and the `openspec` store is the
  fully supported path with nothing extra to install.
- **`spawns: ""` on every agent.** This makes "phases are executors and never delegate"
  mechanical rather than prose. omp reinforces it a second time: at
  `task.maxRecursionDepth` the `task` tool is stripped from child sessions entirely.

The read-only lenses and `jd-fix-agent` also carry `read-summarize: false`: they
adjudicate exact lines, and omp's default structural summaries would hide the very code
they must judge.

| Agent(s) | `tools` (omp) | `thinkingLevel` |
|----------|---------------|-----------------|
| `sdd-apply` | `read`, `grep`, `glob`, `bash`, `write`, `edit` | `high` |
| `sdd-design` | `read`, `grep`, `glob`, `write`, `edit` (no `bash`) | `high` |
| Other 7 SDD phases | phase set; `bash` only on `sdd-init`/`sdd-explore`/`sdd-verify`/`sdd-archive` | `low`–`medium` |
| `review-risk`, `review-readability`, `review-reliability`, `review-resilience` | `read` | `medium`–`high` |
| `review-refuter`, `jd-judge-a`, `jd-judge-b` | `read` | `high` |
| `jd-fix-agent` | `read`, `bash` | `high` |

The agents ship with no `model` in their frontmatter and inherit the session's
default model. To route specific agents to specific models, set
`task.agentModelOverrides` in `~/.omp/agent/config.yml` (or a project
`.omp/config.yml`), use `/agents` interactively, or add `model`
(`provider/model-id`) to an agent's frontmatter locally.

**Skill loading uses `skill://`.** omp resolves skills by name, so each agent reads its
phase contract as `skill://sdd-apply` rather than guessing a filesystem path. The
`_shared` contracts are plain files, not skills, so those are read by path from
`~/.omp/agent/skills/_shared/` (or `<repo>/.omp/skills/_shared/`).

**`RULES.md` complements the agents.** omp is the only supported harness with an
always-apply rule primitive, re-attached near the current turn. Kurama installs
[`examples/omp/RULES.md`](../examples/omp/RULES.md) with the three invariants that must
not decay across a long conversation — delegate-only orchestration, phases never
delegating, and the human merge gate. See
[installation.md](installation.md#rulesmd--omps-sticky-rules).

---

## Agent Teams Mode (experimental, optional, off by default)

For two specific parallel use cases — the two blind judges in
`judgment-day/SKILL.md`, and the `spec ∥ design` phase pair in the canonical
DAG — Claude Code's experimental agent-teams mode
(`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) can run the participants as
teammates with a shared task list instead of the orchestrator sequencing two
separate delegations. This is entirely optional and OFF by default:

- The default path — the "SDD Phase Sub-Agents" table above — never requires
  agent teams, and remains the supported path across all 7 harnesses.
- Agent-teams mode is Claude-Code-specific and experimental; Kurama does not
  depend on it, ship it enabled, or gate any phase behind it.
- When a user enables it in their own Claude Code configuration, the same
  `examples/claude-code/agents/sdd-spec.md` / `sdd-design.md` definitions and
  the two judge roles in `judgment-day/SKILL.md` can be reused as teammate
  definitions — no separate agent-teams-specific files are shipped.

Kurama's "Level 2" position — delegate-only lead, DAG-based phases, parallel
`spec ∥ design`, no shared task queue or peer-to-peer messaging — described in
[docs/architecture.md](architecture.md) is unaffected: agent-teams mode is an
optional accelerator for two already-parallel points in the DAG, not a
redefinition of the orchestration model.
