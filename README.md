<div align="center">

# Kurama

**A lightweight, multi-harness Spec-Driven Development framework for AI coding agents.**

24 pure-Markdown skills · 8 supported harnesses · zero runtime, zero dependencies

</div>

---

## What it is

Kurama turns any capable AI coding assistant into a disciplined
**Spec-Driven Development (SDD)** team. It ships as **24 portable Markdown skills**
(all installed by default — the `tdd` module is included but removable with
`--without tdd`) plus a set of shared convention files, and a thin
*delegate-only orchestrator* prompt. The orchestrator never writes code itself — it coordinates a pipeline of
focused sub-agents, each running in a **fresh context window**, that explore,
specify, design, implement, and verify a change.

Everything is plain Markdown following the open
[Agent Skills](https://agentskills.io) format, so the same skill set installs
across **8 harnesses**: Claude Code, OpenCode, Gemini CLI, Codex, Cursor,
VS Code Copilot, Antigravity, and Pi. There is no binary to install and nothing to
compile — copy the skills, wire the orchestrator prompt, and run `/sdd-init`.

## Why

Modern coding agents share one hard limit: **every turn reprocesses the full
conversation history**. Reading files, running greps, and confirming edits inline
pollutes the context permanently, which forces lossy compaction, which triggers
re-reads, which grows the context again. Kurama breaks that flywheel with two ideas:

1. **Spec-first pipeline.** Work flows through an explicit DAG of phases —
   `explore → propose → spec ∥ design → tasks → apply → verify → archive` —
   where each phase produces a durable artifact the next phase consumes. Specs
   use delta requirements and RFC 2119 keywords, so a change describes only what
   is *different* and merges back into the main specs on archive.

2. **Context isolation over cleverness.** Each phase runs as a sub-agent with its
   own context. The heavy reading a phase does never lands in the orchestrator's
   window. This trades a fixed per-delegation overhead (~11,850 tokens) for
   isolation that pays for itself: past roughly **8 changed files** delegation
   wins outright, and on large features the margin exceeds 100,000 tokens. See
   [docs/token-economics.md](docs/token-economics.md) for the full analysis.

The result is an orchestration model that sits deliberately between basic
fire-and-forget sub-agents and heavyweight agent-team runtimes: a delegate-only
lead, DAG-based phases, parallel `spec ∥ design`, a structured result envelope,
a pluggable artifact store, and automatic skill discovery — without a shared task
queue or peer-to-peer messaging you have to operate.

## Quick start

```bash
git clone https://github.com/Gentleman-Programming/agent-teams-lite.git
cd kurama
```

**Recommended — one step (skills + orchestrator).** `setup.sh` detects your
installed agents, copies the skills to the right user-level directory, and wires
the orchestrator prompt with idempotent markers (safe to re-run):

```bash
./scripts/setup.sh          # interactive — asks which detected agents to set up
./scripts/setup.sh --all    # non-interactive — set up every detected agent
```

Windows PowerShell:

```powershell
.\scripts\setup.ps1         # interactive
.\scripts\setup.ps1 -All    # set up every detected agent
```

**Skills only.** If you want to install just the skills and wire the orchestrator
yourself, use the installer scripts and then append the orchestrator prompt from
`examples/<your-agent>/` as printed in the "Next step" notice:

```bash
./scripts/install.sh        # interactive menu, or: --agent <name>
```

```powershell
.\scripts\install.ps1       # Windows equivalent
```

Then, inside your project:

```text
/sdd-init                   # detect stack + conventions, bootstrap SDD
/sdd-new <change-name>      # explore, then create a proposal
/sdd-continue               # advance to the next phase in the chain
```

Full per-harness instructions (paths, orchestrator files, OpenCode single vs
multi mode) live in [docs/installation.md](docs/installation.md).

## The skills

All 24 skills, grouped by role. Every one is a single `SKILL.md` that any
file-reading agent can load. All 24 install by default; the `tdd` module ships
installed too and can be excluded with `--without tdd`. Installing it never
activates TDD — that stays a separate per-project switch.

### Orchestration entry points

| Skill | Role |
|-------|------|
| `sdd-new` | Start a new SDD change: run exploration, then create a proposal for a fresh change name. |
| `sdd-continue` | Resume an existing change from persisted state and run the next dependency-ready phase. |
| `sdd-ff` | Fast-forward through the remaining planning phases with auto-continue. |

### SDD phases

| Skill | Role |
|-------|------|
| `sdd-init` | Detect stack and conventions, bootstrap the active persistence backend. |
| `sdd-explore` | Investigate ideas and the codebase before committing to a change. |
| `sdd-propose` | Create a change proposal with intent, scope, and approach. |
| `sdd-spec` | Write delta specs — requirements and scenarios for the change. |
| `sdd-design` | Produce the technical design: architecture decisions and approach. |
| `sdd-tasks` | Break the change down into an implementation task checklist. |
| `sdd-apply` | Implement tasks as real code, following the specs and design. |
| `sdd-verify` | Validate that the implementation matches specs, design, and tasks. |
| `sdd-archive` | Merge delta specs into the main specs and archive the change. |

### Shared conventions & tooling

| Skill | Role |
|-------|------|
| `skill-registry` | Scan installed skills and project conventions into a project registry. |
| `skill-creator` | Author new Agent Skills that follow the open spec format. |

### Quality & delivery

| Skill | Role |
|-------|------|
| `judgment-day` | Parallel adversarial review — two blind judges, synthesize, fix, re-judge. |
| `go-testing` | Go testing patterns, including Bubbletea TUI testing with `teatest`. |
| `branch-pr` | PR creation workflow following the issue-first enforcement system. |
| `issue-creation` | GitHub issue workflow for bugs and feature requests. |

### Review lenses (4R + refuter)

Bounded, read-only code-review lenses the orchestrator selects by deterministic
triage: a trivial diff runs no lens, a standard diff runs exactly one dominant-risk
lens, and a hot-path or large diff runs the full 4R sweep. Only findings **introduced**
by the diff can block, and only `BLOCKER`/`CRITICAL` gate. See
[docs/sub-agents.md](docs/sub-agents.md#review-lenses-4r--refuter) and the shared
[`skills/_shared/review-ledger-contract.md`](skills/_shared/review-ledger-contract.md).

| Skill | Role |
|-------|------|
| `review-risk` | R1 — security, privilege boundaries, data exposure, dependency risk. |
| `review-readability` | R2 — naming, complexity, intent, maintainability, review size. |
| `review-reliability` | R3 — behavior-first tests, coverage value, edge cases, determinism, regressions. |
| `review-resilience` | R4 — fallbacks, retry/backoff, graceful degradation, observability, rollback. |
| `review-refuter` | Adversarial verifier — adjudicates inferential findings `corroborated`/`refuted`/`inconclusive`. |

### TDD module (installed by default, activation opt-in)

| Skill | Role |
|-------|------|
| `tdd` | Language-agnostic RED → GREEN → REFACTOR contract, anti-patterns, and per-task evidence format. Installed by default; remove the module with `--without tdd`. Installing it never activates TDD — that is a separate explicit per-project switch (see [docs/tdd.md](docs/tdd.md)). |

Shared behavior the SDD skills rely on lives in
[`skills/_shared/`](skills/_shared/) — the persistence contract, the Engram and
OpenSpec conventions, the phase-common return envelope, and the skill resolver.

## Artifact store modes

The orchestrator passes an `artifact_store.mode` to every phase. It decides where
**SDD artifacts** (exploration, proposal, spec, design, tasks, reports, state) are
kept — never the implementation code, which `sdd-apply` always writes to the
project in every mode.

| Mode | Where artifacts live |
|------|----------------------|
| `engram` | Persistent memory via [Engram](https://github.com/gentleman-programming/engram); survives compaction and cross-session recovery. Default when Engram is available. |
| `openspec` | Human-readable files under `openspec/`, version-controllable with the repo. |
| `hybrid` | Both Engram and the filesystem, written simultaneously (higher token cost). |
| `none` | Nowhere — artifacts are returned inline in the orchestrator context. Default fallback when no backend is available. |

`openspec` and `hybrid` are never selected automatically — the orchestrator must
pass them explicitly. See [docs/persistence.md](docs/persistence.md).

## Supported harnesses

The same skills install everywhere; sub-agent support depends on what each host
exposes. "Full" means true sub-agents with isolated, fresh context windows.

| Harness | Sub-agent support | Setup |
|---------|:-----------------:|-------|
| Claude Code | Full (Task tool, fresh-context sub-agents) | `setup.sh --agent claude-code` |
| OpenCode | Full (native phase agents + async `delegate`) | `setup.sh --agent opencode` |
| Gemini CLI | Inline (skills load as instructions) | `setup.sh --agent gemini-cli` |
| Codex | Inline (skills load as instructions) | `setup.sh --agent codex` |
| Cursor | Inline (skills load as instructions) | `setup.sh --agent cursor` |
| VS Code Copilot | Inline (agent mode with tool use) | `setup.sh --agent vscode` |
| Antigravity | Single-agent | Manual (see installation guide) |
| Pi | Inline (skills load as instructions) | `setup.sh --agent pi` (global `~/.pi/agent/AGENTS.md`; see installation guide) |

## Documentation

- [docs/installation.md](docs/installation.md) — per-harness install, paths, and orchestrator wiring.
- [docs/concepts.md](docs/concepts.md) — delta specs, RFC 2119 keywords, the archive cycle.
- [docs/architecture.md](docs/architecture.md) — orchestration model, the phase DAG, and the result contract.
- [docs/sub-agents.md](docs/sub-agents.md) — how phases run as sub-agents and share conventions.
- [docs/persistence.md](docs/persistence.md) — the four artifact store modes in depth.
- [docs/token-economics.md](docs/token-economics.md) — the cost analysis behind context isolation.
- [docs/changelog.md](docs/changelog.md) — release history.

## Contributing

Contributions are welcome. The workflow is issue-first: open an issue, get it
approved, then submit a PR that references it. See
[CONTRIBUTING.md](CONTRIBUTING.md) for branch naming, commit conventions, and the
automated PR checks.

## Relationship with gentle-ai

Kurama is **actively maintained** as the standalone, lightweight
multi-harness SDD framework — the pure-Markdown, zero-dependency way to install
these skills into any of the eight supported agents.

[`gentle-ai`](https://github.com/Gentleman-Programming/gentle-ai) is a separate,
higher-level distribution: a managed installer (Go binary) that bundles these
skills together with MCP configuration, persona injection, automatic updates, and
other conveniences. The two are complementary. Use this repository when you want
the skills directly, full control over what lands where, and a dependency-free
setup you can vendor into your own tooling; reach for `gentle-ai` when you want a
batteries-included, self-updating installer.

## License

MIT — see [LICENSE](LICENSE).

---

<div align="center">
  <sub>Built by <a href="https://github.com/Gentleman-Programming">Gentleman Programming</a></sub>
</div>
