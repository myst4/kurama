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
| **TDD Module** | `tdd/SKILL.md` | Optional RED-GREEN-REFACTOR cycle contract; loaded by `sdd-apply` when TDD resolves active, referenced by `sdd-tasks` and `sdd-verify`. Opt-in `tdd` manifest group, not installed by default |
| **Skill Registry** | `skill-registry/SKILL.md` | Scans user skills + project conventions, writes `.atl/skill-registry.md` |
| **Judgment Day** | `judgment-day/SKILL.md` | Runs dual adversarial review with two blind judges and a fix loop |
| **Go Testing** | `go-testing/SKILL.md` | Shared conventions for Go tests, including Bubbletea and teatest patterns |
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

Every sub-agent returns a structured envelope (`status`, `executive_summary`, `detailed_report`, `artifacts`, `next_recommended`, `risks`, `skill_resolution`) to the orchestrator. The canonical field list, description, and example live in [`skills/_shared/sdd-phase-common.md`](../skills/_shared/sdd-phase-common.md), Section D — see it there instead of duplicating it here.

### Sub-Agent Context Protocol

Sub-agents start with a **fresh context**. The canonical injection and fallback protocol — how the orchestrator resolves the registry, matches skills, injects compact rules as `## Project Standards (auto-resolved)`, and how sub-agents report `skill_resolution` back — lives in [`skills/_shared/skill-resolver.md`](../skills/_shared/skill-resolver.md); this section only summarizes it: if no `## Project Standards` block arrives, sub-agents fall back to registry lookup or explicit `SKILL: Load` paths.

Sub-agents are also instructed to save discoveries, decisions, and bug fixes to engram automatically (non-SDD sub-agents) or via the mandatory persist step (SDD phases).

---

## Shared Conventions

`skills/_shared/` contains seven files. `sdd-phase-common.md` is loaded directly by all 8 SDD phase skills (explore through archive) — it is the most load-bearing shared file in the system. Critical engram calls (`mem_search`, `mem_save`, `mem_get_observation`) are also **inlined directly in each skill** so sub-agents don't need to follow multi-hop file references.

| File | Purpose |
|------|---------|
| `sdd-phase-common.md` | Sections A-D: skill loading, artifact retrieval, persistence, and the return envelope. Loaded directly by every SDD phase skill. |
| `persistence-contract.md` | Mode resolution rules, sub-agent context protocol, skill registry loading protocol |
| `engram-convention.md` | Supplementary reference for deterministic naming (`sdd/{change-name}/{artifact-type}`) and two-step recovery. Critical calls are inlined in skills. |
| `openspec-convention.md` | Filesystem paths for each artifact, directory structure, config.yaml reference, and archive layout. **Not** the upstream OpenSpec CLI format — see the note at the top of that file. |
| `skill-resolver.md` | **Canonical** protocol for delegators to inject compact rules from the skill registry |
| `review-ledger-contract.md` | **Canonical** shared contract for the 4R review lenses + refuter: sweep budget, precision gate, candidate-causal admission, findings-ledger schema, adversarial verification, severity floor, and artifact-store-aware persistence. |
| `test-runners.md` | Per-runner detect → full-suite + single-test command table, used by the optional TDD module (`skills/tdd/SKILL.md`) |

**Why inline + shared:**
- **Sub-agents fail multi-hop chains** — A 3-hop read chain (skill → convention file → actual instructions) breaks non-Claude models. Inlining the critical calls eliminates this.
- **Deterministic recovery** — Engram artifact naming follows a strict `sdd/{change}/{type}` convention with `topic_key`, so any skill can reliably find artifacts created by other skills.
- **Consistent mode behavior** — All skills resolve `engram | openspec | hybrid | none` the same way. `openspec` and `hybrid` are never chosen automatically.

---

## Review Lenses (4R + refuter)

The post-implementation review layer is a set of **read-only** sub-agent lenses the
orchestrator runs after `sdd-apply`. Each lens is a `SKILL.md` declaring `tools: Read,
Grep, Glob` — it finds defects and never edits, runs, or delegates.

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
or inline in `none` mode).

---

## Skill Registry

Sub-agents start with a **fresh context** — they do not know what user skills exist (React, TDD, Playwright, etc.). The skill registry solves this, and the orchestrator uses it to inject compact rules before each delegation.

**How the registry gets built:**
1. `/sdd-init` or `/skill-registry` scans your installed skills and project conventions
2. Writes `.atl/skill-registry.md` in the project root (mode-independent, always created)
3. If engram is available, also saves to engram (cross-session bonus)

Once the registry exists, resolving it and injecting compact rules into each delegation follows the canonical protocol in [`skills/_shared/skill-resolver.md`](../skills/_shared/skill-resolver.md) — see that file for the full resolution order, injection format, fallback chain, and the `skill_resolution` feedback loop.

**Preferred path:** the orchestrator pre-resolves compact rules. Sub-agent self-loading is only a compatibility fallback.

**What it contains:**
- User skills table: trigger → skill name → path (e.g., "React components" → `react-19` → `~/.claude/skills/react-19/SKILL.md`)
- Compact rules blocks: short, pre-digested instructions that delegators paste directly into sub-agent prompts
- Project conventions found: `agents.md`, `CLAUDE.md`, `.cursorrules`, etc.

**When to update:** Run `/skill-registry` after installing or removing skills.

---

## Per-Agent Model Routing

`opencode.multi.json` gives each `sdd-<phase>` agent its own entry in `opencode.json`, and any of them can carry a `model` field to select which model it should use. When the orchestrator delegates via `delegate(prompt, agent)` or `Task`, the background-agents plugin passes the `model` through to `session.prompt()`, so the sub-agent runs on its configured model.

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

**Alternative: `@agent-name` text mentions.** OpenCode also supports routing via `@agent-name` mentions in the orchestrator's output, which triggers native agent routing. This is an alternative to `delegate()` but is NOT required — `delegate()` handles model routing correctly.

---

## Native Claude Code Subagents (optional)

Claude Code supports declarative subagents defined as Markdown files with
frontmatter, as an alternative to the generic
`Task(subagent_type: 'general', prompt: 'Read skill...')` pattern the
orchestrator uses by default. This repo ships one such definition per SDD
phase in [`examples/claude-code/agents/`](../examples/claude-code/agents/):
`sdd-init.md`, `sdd-explore.md`, `sdd-propose.md`, `sdd-spec.md`,
`sdd-design.md`, `sdd-tasks.md`, `sdd-apply.md`, `sdd-verify.md`,
`sdd-archive.md`.

Each file's frontmatter declares `name`, `description`, `tools`, and `model`;
the body instructs the subagent to load its phase's `SKILL.md` before acting.
Model routing mirrors the Model Assignments table already used for generic
delegation, but is declarative instead of a table the orchestrator has to
read and cache every session:

| Phase | Model |
|-------|-------|
| `sdd-design` | `opus` |
| `sdd-apply` | `opus` |
| All others (`sdd-init`, `sdd-explore`, `sdd-propose`, `sdd-spec`, `sdd-tasks`, `sdd-verify`, `sdd-archive`) | `sonnet` |

This is an alternative to, not a replacement for, the generic Task-tool
pattern above — installing `examples/claude-code/agents/` is optional. A
project that skips it keeps working exactly as before, with the orchestrator
resolving skills and models itself per the Model Assignments table in
[`examples/claude-code/CLAUDE.md`](../examples/claude-code/CLAUDE.md).

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
- Agent-teams mode is Claude-Code-specific and experimental; ATL does not
  depend on it, ship it enabled, or gate any phase behind it.
- When a user enables it in their own Claude Code configuration, the same
  `examples/claude-code/agents/sdd-spec.md` / `sdd-design.md` definitions and
  the two judge roles in `judgment-day/SKILL.md` can be reused as teammate
  definitions — no separate agent-teams-specific files are shipped.

ATL's "Level 2" position — delegate-only lead, DAG-based phases, parallel
`spec ∥ design`, no shared task queue or peer-to-peer messaging — described in
[docs/architecture.md](architecture.md) is unaffected: agent-teams mode is an
optional accelerator for two already-parallel points in the DAG, not a
redefinition of the orchestration model.
