<div align="center">

# Kurama

**A lightweight, multi-harness Spec-Driven Development framework for AI coding agents.**

28 pure-Markdown skills · 5 supported harnesses · no build step, no runtime

</div>

---

## What it is

Kurama turns any capable AI coding assistant into a disciplined
**Spec-Driven Development (SDD)** team. It ships as **28 portable Markdown skills**
(all installed by default — the `tdd` module and the five-skill `optional` group are
included but removable with `setup.sh --without tdd` / `setup.sh --without optional`;
module selection is a `setup.sh` flag, and with no `--with`/`--without` it installs the
default set)
plus a set of shared convention files, and a thin
*delegate-only orchestrator* prompt. The orchestrator never writes code itself — it coordinates a pipeline of
focused sub-agents, each running in a **fresh context window**, that explore,
specify, design, implement, and verify a change.

Everything is plain Markdown following the open
[Agent Skills](https://agentskills.io) format, so the same skill set installs
across **5 harnesses**: Claude Code, OpenCode, omp, Codex, and Pi. There is no
binary to install and nothing to
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
a file-backed artifact store, and automatic skill discovery — without a shared task
queue or peer-to-peer messaging you have to operate.

## Quick start

```bash
git clone https://github.com/myst4/kurama.git
cd kurama
```

**Recommended — one step (skills + orchestrator).** `setup.sh` detects your
installed agents, copies the skills to the right user-level directory, and wires
the orchestrator prompt with idempotent markers (safe to re-run):

```bash
./scripts/setup.sh          # interactive gum TUI (no gum? use --all or --agent below)
./scripts/setup.sh --all    # non-interactive — set up every detected agent
```

**One specific agent.** Pass `--agent` to skip detection —
`claude-code`, `opencode`, `omp`, `pi`, or `codex`:

```bash
./scripts/setup.sh --agent omp          # skills + orchestrator + 17 task agents + RULES.md
./scripts/setup.sh --agent claude-code  # skills + orchestrator + 17 agents + hooks
```

> **Running omp?** Use `--agent omp`, not `--agent pi`. They are different binaries with
> different config roots, and `--agent pi` would install where omp never looks — the
> failure is silent. See [omp](docs/installation.md#omp).

**Trial it in one repo.** To evaluate Kurama in a single project without touching
your global config, add `--scope project --path <repo>` — skills, native agents,
hooks, and the orchestrator merge all land inside that repo, with one receipt at
its root that `uninstall.sh` can remove cleanly:

```bash
./scripts/setup.sh --agent claude-code --scope project --path /path/to/your/repo
```

**Persistence.** Artifacts persist as markdown files under `openspec/`, with
machine-local cycle state under `.kurama/`. See
[docs/persistence.md](docs/persistence.md).

**Skills only.** If you want to install just the skills and wire the orchestrator
yourself, use the installer scripts and then append the orchestrator prompt from
`examples/<your-agent>/` as printed in the "Next step" notice:

```bash
./scripts/setup.sh          # interactive gum TUI, or (no gum): --agent <name> / --all
```

`scripts/install.sh` still works as a thin compatibility wrapper — it maps its old
flags onto `setup.sh` and forwards (issue #38), so there is now one install path
with all capabilities and a single receipt writer. Prefer calling `setup.sh`
directly.

Then, inside your project:

```text
/sdd-init                   # detect stack + conventions, bootstrap SDD
/sdd-new <change-name>      # explore, then create a proposal
/sdd-continue               # advance to the next phase in the chain
```

Full per-harness instructions (paths, orchestrator files, OpenCode single vs
multi mode) live in [docs/installation.md](docs/installation.md).

**Keeping an install current.** After pulling a new Kurama version, re-sync every
recorded install with `./scripts/update.sh` (add `--scope project --path <repo>`
for a per-repo install). `./scripts/doctor.sh` health-checks an install
(receipts vs disk, `gh` scopes, Pi stack, markers, hooks), and
`./scripts/uninstall.sh` removes exactly what the install receipt recorded —
skills, agents, hooks, and MCP registrations included.

## The skills

All 28 default skills, grouped by role. Every one is a single `SKILL.md` that any
file-reading agent can load. The optional `tdd` and `kanban-github` modules ship
installed and can be excluded with `setup.sh --without tdd` /
`setup.sh --without optional`; installing either never activates it — both stay
separate per-project switches.

> **Module selection is a `setup.sh` flag.** `--with`/`--without` are implemented by
> `scripts/setup.sh`. With no `--with`/`--without` it installs the **default** skill
> set; pass them for a non-default selection (e.g. `setup.sh --without review` for a
> full setup without the review lenses). `scripts/install.sh` forwards these flags to
> `setup.sh` for backward compatibility.

**No language knowledge is installed, at all.** Kurama is stack-agnostic: it knows
the shape of the workflow, never the values of a specific ecosystem. It ships zero
per-language pattern skills; your own language skills reach sub-agents through the
[skill registry](#the-skills) without touching the harness. The project's test and
build commands are **asked at `/sdd-init`** and recorded in config — never guessed from
a list of supported stacks, so any ecosystem works, including one Kurama has never
heard of.

### Orchestration entry points

| Skill | Role |
|-------|------|
| `sdd-new` | Start a new SDD change: run the brainstorm gate, then exploration, then create a proposal for a fresh change name. |
| `sdd-brainstorm` | Turn a vague request into a decision ledger before exploration starts. Reached from `sdd-new`'s gate, or on request. |
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
| `sdd-learn` | Capture a finished cycle's durable learnings into the committed `MEMORY.md`. |

### Shared conventions & tooling

| Skill | Role |
|-------|------|
| `skill-registry` | Rebuild the project skill index by running `_shared/build-skill-registry.sh`. |
| `skill-creator` | Author a new Kurama skill and wire it into the registry, the manifest and the suite. |

### Quality & delivery

| Skill | Role |
|-------|------|
| `judgment-day` | Parallel adversarial review — two blind judges, synthesize, fix, re-judge. |
| `branch-pr` | PR creation workflow following the issue-first enforcement system. |
| `issue-creation` | GitHub issue workflow for bugs and feature requests. |
| `systemic-issue-triage` | Partition a batch of issues by root cause before any code is written — one fix per root, never one per issue. |
| `kurama-report` | Report a failure in Kurama itself upstream: searches first, sanitizes, and always asks before filing. |

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
| `tdd` | Language-agnostic RED → GREEN → REFACTOR contract, anti-patterns, and per-task evidence format. Installed by default; remove the module with `setup.sh --without tdd`. Installing it never activates TDD — that is a separate explicit per-project switch (see [docs/tdd.md](docs/tdd.md)). |

### Kanban module (installed by default, activation opt-in)

| Skill | Role |
|-------|------|
| `kanban-github` | Optional GitHub Projects (v2) board sync: each issue the harness works on is a card the orchestrator moves through Backlog → Ready → In Progress → In Review → Done as the SDD cycle crosses phase boundaries. Installed by default (manifest group `optional`; remove with `setup.sh --without optional`). Installing it never activates the board — activation is opt-in per project via `kanban.enabled`, and **requires a configured GitHub CLI (`gh`)** to turn on. Failed board updates are WARNINGs that never block the cycle. See [docs/kanban-github.md](docs/kanban-github.md). |

Shared behavior the SDD skills rely on lives in
[`skills/_shared/`](skills/_shared/) — the persistence contract, the OpenSpec
convention, the phase-common return envelope, and the skill resolver.

## Artifact store

**SDD artifacts** (exploration, proposal, spec, design, tasks, reports) are
human-readable files under `openspec/`, version-controlled with the repo. Cycle
state lives machine-locally under `.kurama/`. Neither restricts the
implementation code, which `sdd-apply` always writes to the project.
**Persistence is never skipped.** See
[docs/persistence.md](docs/persistence.md).

## Supported harnesses

The same skills install everywhere; sub-agent support depends on what each host
exposes. "Full" means true sub-agents with isolated, fresh context windows.
**Enforcement** is a separate axis — see the tier column below.

| Harness | Sub-agent support | Gate enforcement | Setup |
|---------|:-----------------:|:----------------:|-------|
| Claude Code | Full (Task tool, fresh-context sub-agents) | **Enforced** (`PreToolUse` hooks) | `setup.sh --agent claude-code` |
| OpenCode | Full (native phase agents via the built-in `task` tool, which blocks) | **Enforced** (`tool.execute.before` plugin) | `setup.sh --agent opencode` |
| Codex | Inline (skills load as instructions) | Advisory (no pre-tool event) | `setup.sh --agent codex` |
| Pi | Inline (skills load as instructions) | Advisory (no agent identity in the event) | `setup.sh --agent pi` (global `~/.pi/agent/AGENTS.md`; see installation guide) |
| omp | Full (native task agents, isolated per-phase contexts) | Advisory (no agent identity in the event) | `setup.sh --agent omp` (global `~/.omp/agent/`; see installation guide) |

> **What "Gate enforcement" means.** Kurama's two hardest structural rules —
> *the orchestrator delegates, it never edits code mid-cycle*, and *never archive
> a change that did not pass verification* — exist as prose in every orchestrator
> prompt, and as deterministic gates on some harnesses. **Enforced** means a
> mechanism refuses the tool call: the model cannot forget it or argue with it.
> **Advisory** means only the prose stands, and prose can fall out of context.
> This is a real difference in what an install protects you from, so it is stated
> here rather than left to be discovered. The per-harness reasons — including the
> two harnesses where a veto primitive is verified but neither gate ports cleanly
> yet — are in [docs/hooks.md](docs/hooks.md#enforcement-tiers--what-each-harness-actually-guarantees).

> **OpenCode delegation is synchronous.** Kurama no longer ships the
> `background-agents.ts` plugin, so there is no async `delegate` tool: both OpenCode
> modes delegate through the native `task` tool, which blocks until the sub-agent
> returns. For background sub-agents, export OpenCode's own experimental switch
> (`OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS=true`) before launching it — see
> [docs/sub-agents.md](docs/sub-agents.md).

Harness-specific extras land through the same setup command. On **Claude Code**,
`setup.sh --agent claude-code` also installs all **17 native subagents** (the 9 SDD
phases plus 8 review-layer agents — the 4R lenses, refuter, two Judgment Day judges,
and the fix agent) into `~/.claude/agents/`, each with its own `tools`/`model`
frontmatter (the read-only lenses are enforced read-only by that `tools` list), and
**always installs the two deterministic hooks** (a write-guard and an archive-gate,
merged into `settings.json`). On **OpenCode**, the same two gates run through
`plugins/kurama-sdd-gates.ts` — a thin adapter that hands the OpenCode
`tool.execute.before` event to the *same* two scripts, so both harnesses enforce
one implementation rather than two that drift. On **Pi**, `setup.sh --agent pi` installs the **same
17 agents** in Pi's format into `~/.pi/agent/agents/`, and can optionally add a
curated, consent-gated stack of Pi runtime packages (persistent memory, MCP adapter,
native subagents, ask-user, web access, todo, side-conversations) at pinned versions
— it never installs the `gentle-pi` package (third-party). On **omp**, `setup.sh --agent omp`
installs the **same 17 agents** in omp's task-agent format into `~/.omp/agent/agents/`
plus a `RULES.md` sticky-rule file — omp re-attaches always-apply rules near the current
turn, so the orchestrator's hard invariants survive a long conversation. The omp agent set
is **not interchangeable** with the Claude or Pi ones: omp deliberately skips
cross-harness agent roots whose frontmatter is not its task-agent contract, so installing
the wrong format would leave the agents silently invisible and the cycle degraded to
inline. All are detailed in [docs/installation.md](docs/installation.md).

## Documentation

- [docs/installation.md](docs/installation.md) — per-harness install, paths, and orchestrator wiring.
- [docs/concepts.md](docs/concepts.md) — delta specs, RFC 2119 keywords, the archive cycle.
- [docs/architecture.md](docs/architecture.md) — orchestration model, the phase DAG, and the result contract.
- [docs/sub-agents.md](docs/sub-agents.md) — how phases run as sub-agents and share conventions.
- [docs/persistence.md](docs/persistence.md) — the three stores in depth.
- [docs/kanban-github.md](docs/kanban-github.md) — the optional GitHub Projects board sync module.
- [docs/opencode-profiles.md](docs/opencode-profiles.md) — named model profiles for the OpenCode integration.
- [docs/companion-skills.md](docs/companion-skills.md) — optional pairings with external process skills like superpowers.
- [docs/token-economics.md](docs/token-economics.md) — the cost analysis behind context isolation.
- [docs/smoke-test.md](docs/smoke-test.md) — a ~15-minute manual end-to-end walk through the SDD cycle.
- [docs/migration.md](docs/migration.md) — upgrade notes for existing installs (current + previous release series).
- [docs/changelog.md](docs/changelog.md) — release history.

## Banner

`scripts/banner.sh` prints the nine-tailed fox and the KURAMA wordmark in 24-bit
truecolor, followed by a small stats panel (branch, version, skill and agent
counts, MCP servers). `setup.sh` and `install.sh` show it automatically when they
run on a terminal; piped or CI runs get the plain text header instead.

```sh
./scripts/banner.sh            # with the fade-in animation
./scripts/banner.sh --no-anim  # skip it
```

Every probe in the script is best-effort and it always exits 0, so it is safe to
chain in front of an agent launch:

```sh
export KURAMA="$HOME/path/to/kurama"
alias kurama-claude='"$KURAMA"/scripts/banner.sh && claude'
alias kurama-opencode='"$KURAMA"/scripts/banner.sh && opencode'
alias kurama-pi='"$KURAMA"/scripts/banner.sh && pi'
```

It honors [NO_COLOR](https://no-color.org), and skips the animation on its own
when stdout is not a terminal. The fox art is generated from
`assets/banner/fox-grid.txt` by `scripts/gen-braille.mjs`; `banner.sh` only
renders what is already in `assets/banner/`.

## Contributing

Contributions are welcome. The workflow is issue-first: open an issue, get it
approved, then submit a PR that references it. See
[CONTRIBUTING.md](CONTRIBUTING.md) for branch naming, commit conventions, and the
automated PR checks.

## License

MIT — see [LICENSE](LICENSE).

