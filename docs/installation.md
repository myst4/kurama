# Installation Guide

For the automated setup, run:
```bash
./scripts/setup.sh --all
```

For manual installation or specific tools, see below.

## Table of Contents
- [Install scope: global vs. project (trial a repo)](#install-scope-global-vs-project-trial-a-repo)
  - [Machine-local files and your `.gitignore`](#machine-local-files-and-your-gitignore)
  - [When the repo already has its own workflow](#when-the-repo-already-has-its-own-workflow)
- [Session identity: persona and name](#session-identity-persona-and-name)
- [Claude Code](#claude-code)
- [OpenCode](#opencode)
- [Codex](#codex)
- [Pi](#pi)
- [Other Tools](#other-tools)
- [Maintenance: update, doctor, uninstall](#maintenance-update-doctor-uninstall)
- [Smoke test](#smoke-test)
- [Editing the Generated Example Orchestrators](#editing-the-generated-example-orchestrators)

---

The recommended way to install is the **setup script** — it handles everything (skills + orchestrator prompts) in one step:

```bash
./scripts/setup.sh        # Interactive gum TUI (no gum? use --all or --agent)
./scripts/setup.sh --all  # Auto-detect + install all (no prompts)
```

> **Platforms:** macOS and Linux. Every script is portable bash (3.2-compatible,
> BSD and GNU userland). There is no PowerShell installer.

> **Non-interactive callers (CI, pipes, `< /dev/null`):** a bare `./scripts/setup.sh`
> is not a fully specified run — it hands off to the gum TUI, which owns the banner
> and the prompts. With gum installed but **stdin closed**, that hand-off lands in
> gum's own failure mode rather than a Kurama error message. Always pass an explicit
> target from a script: `--all`, or `--agent NAME --non-interactive`.

The setup script:
- Detects installed agents via PATH (`claude`, `opencode`, `codex`, `pi`, `omp`)
- Copies skills to the correct directory (user-level by default; per-repo with `--scope project`)
- Configures orchestrator prompts with idempotent markers (safe to re-run)
- Installs native subagents where the harness supports them — **17 Claude Code
  agents** into `~/.claude/agents/`, and **17 Pi agents** into
  `~/.pi/agent/agents/` (see the per-harness sections)
- For **Claude Code, always installs the deterministic hooks** (both scopes, no
  prompt — see [Hooks below](#hooks-installed-automatically))
- Handles OpenCode's special case (commands + JSON config merge)
- For OpenCode: asks single vs multi-model mode (or use `--opencode-mode`)

Two flags control **where** it installs:

| Flag | Meaning |
|------|---------|
| `--scope global` | (default) install to the per-user agent config dirs (`~/.claude`, `~/.pi`, …). |
| `--scope project` | install **everything into one git repo** to trial Kurama there — skills, native agents, hooks, and the orchestrator merge all land under the repo (see [Install scope](#install-scope-global-vs-project-trial-a-repo)). |
| `--path <repo>` | the target repo for `--scope project` (default: current directory). |

`setup.sh` installs the **default skill set — 28 skills**, including two optional
modules that ship on disk but stay inert until you opt in per project: the TDD module
(`skills/tdd`) and the GitHub Projects Kanban module (`skills/kanban-github`).
Installing a module never activates it — activation is a separate explicit
per-project switch (see [docs/tdd.md](tdd.md) and [docs/kanban-github.md](kanban-github.md)).

> **Changing the skill selection is a `setup.sh` flag.** `--with`/`--without` are
> implemented by `scripts/setup.sh`; with no `--with`/`--without` it installs the
> default set. `--without tdd` excludes the TDD module (27 skills), `--without quality`
> drops `judgment-day` (27 skills), `--without optional` excludes the `optional` group —
> `kanban-github`, `sdd-learn`, `sdd-brainstorm`, `kurama-report` and
> `systemic-issue-triage` (23 skills), `--without review` drops the 4R + refuter review
> lenses AND their review-layer agents (23 skills). Every group Kurama ships is on by
> default, so `--with` only ever re-affirms one; a name outside
> `quality|review|optional|tdd` is rejected. Kurama is stack-agnostic and ships no
> language-specific knowledge at any flag. The
> flags apply to the full `setup.sh` install (skills, agents, hooks, orchestrator merge)
> — `scripts/install.sh` forwards them to `setup.sh` for backward compatibility.

> **`gh` prerequisite (only to activate the Kanban module).** The optional Kanban
> board sync requires a configured GitHub CLI — `gh` installed, authenticated, and
> holding the `read:project,project` scopes (read + write). It is needed **only if you
> enable `kanban` for a project**; the module installs and every other skill works
> without `gh`. `sdd-init` verifies `gh --version`, `gh auth status`, and
> `gh project list --owner @me` when you opt in, and prints the exact fix
> (`brew install gh` / `gh auth login` / `gh auth refresh -s read:project,project`) if
> a check fails. See [docs/kanban-github.md](kanban-github.md).

> **For external installers and CI**: use the `--non-interactive` flag.

> **`install.sh` is now a thin wrapper around `setup.sh`** (issue #38). The two used
> to be separate installers with conflicting receipts (#24); they are collapsed into
> one. `install.sh` maps its historical flags onto `setup.sh` and forwards — so
> `install.sh --agent claude-code` runs the full `setup.sh` install (skills, agents,
> hooks, orchestrator merge) and `setup.sh` (via `scripts/lib/receipt.sh`) is the sole
> receipt writer. Prefer calling `scripts/setup.sh` directly; keep re-syncing recorded
> installs with `./scripts/update.sh`.

---

## Install scope: global vs. project (trial a repo)

By default `setup.sh` installs **globally** — into the per-user config dirs
(`~/.claude`, `~/.pi`, …), available across every project. That is the right
mode once you have decided to adopt Kurama.

**To try Kurama in a single repository without touching your global config,
use project scope.** `--scope project` installs *everything* into one target
repo, so you can evaluate it in isolation and remove it cleanly afterward:

```bash
./scripts/setup.sh --agent claude-code --scope project --path /path/to/your/repo
./scripts/setup.sh --agent claude-code --scope project    # --path defaults to the current directory
```

`--path` (which **only** applies with `--scope project`, and **wins** when
given) is validated before anything is written: it must **exist**, be a **git
repository**, and must **never be the Kurama repo itself**. In non-interactive
mode a non-repo path **aborts**; interactively you are asked once before
proceeding.

Where project scope writes, per harness:

| Harness | Skills | Native agents | Orchestrator | Hooks | Receipt |
|---------|--------|---------------|--------------|-------|---------|
| Claude Code | `<repo>/.claude/skills/` | `<repo>/.claude/agents/` | `<repo>/CLAUDE.md` (marker merge) | `<repo>/.claude/hooks/kurama/` + `<repo>/.claude/settings.json` | `<repo>/.kurama-install-manifest.json` |
| Pi | `<repo>/.pi/skills/` | `<repo>/.pi/agents/` | `<repo>/AGENTS.md` (marker merge) | — | `<repo>/.kurama-install-manifest.json` |
| omp | `<repo>/.omp/skills/` | `<repo>/.omp/agents/` | `<repo>/.omp/AGENTS.md` (marker merge) + `<repo>/.omp/RULES.md` (replaced whole) | — | `<repo>/.kurama-install-manifest.json` |
| OpenCode | `<repo>/.claude/skills/` | — | `<repo>/AGENTS.md` (marker merge) | — | `<repo>/.kurama-install-manifest.json` |
| Codex | `<repo>/.claude/skills/` | — | `<repo>/CLAUDE.md` (best-effort) | — | `<repo>/.kurama-install-manifest.json` |

> **omp keeps its own root in project scope too.** Everything lands under
> `<repo>/.omp/` — including `AGENTS.md`, because omp's `native` provider reads the
> nearest `.omp/AGENTS.md` and outranks a bare repo-root `AGENTS.md`. `RULES.md` is the
> one file that is **not** marker-merged (omp has no convention for partial rule files):
> a pre-existing one is backed up and replaced whole, and recorded in the receipt.
>
> **OpenCode's dedicated flow is global-only.** In project scope OpenCode gets skills,
> a receipt, and a generic orchestrator merge into `<repo>/AGENTS.md` — but **not** the
> `/sdd-*` commands, the `opencode.json` agent block, or the single/multi mode and
> profile handling, all of which write to `~/.config/opencode/`. Install OpenCode
> globally (`--scope global`, the default) to get those.

The install **receipt** (`.kurama-install-manifest.json`) lands at the **repo
root** for project scope (in the skills dir for global scope), and records the
scope, version, every installed file, the touched `settings.json`, any Pi
packages, the `.gitignore` carrying the managed machine-local block, and — for
OpenCode — the `opencode.json` it merged agents
into plus the resolved `--opencode-mode`/`--opencode-profile`, so
`uninstall.sh`, `update.sh`, and `doctor.sh` (all of which accept the same
`--scope`/`--path`) operate on exactly what was installed.

### Machine-local files and your `.gitignore`

Project scope writes files into your repo that are **machine-local** — they
carry absolute paths and per-machine state, and committing them hands a
teammate your paths. So in project scope, and **only** when the target is a git
repository, `setup.sh` ensures a **managed block** in the repo root's
`.gitignore`:

```gitignore
# BEGIN:kurama
… one line of *why* per pattern …
.kurama/
.kurama-install-manifest.json
*.bak.[0-9]*
.claude/settings.local.json
# END:kurama
```

| Pattern | Why it is machine-local |
|---------|-------------------------|
| `.kurama/` | Harness state: the skill registry and the fallback SDD artifacts. |
| `.kurama-install-manifest.json` | The install receipt — it records absolute paths. |
| `*.bak.[0-9]*` | Timestamped backups left beside any file setup/uninstall merges into. |
| `.claude/settings.local.json` | Per-machine agent config (permissions, local paths). |
| `.atl/` | Pi runtime state — **added only when `pi` is one of the installed harnesses**, because nothing else writes it. Install Pi later and the next `setup.sh`/`update.sh` run adds the line. |

Rules the block obeys:

- **Marker-managed and idempotent.** Kurama rewrites only the lines *between*
  the markers; a rule you wrote is never touched, and a second run whose block
  is already current leaves the file **byte-identical**. Unbalanced markers are
  refused rather than repaired.
- **The file is created when absent**, and `uninstall.sh` removes exactly the
  block (deleting the file only when it holds nothing else).
- **`update.sh` ensures the block on re-sync**, so an install predating this
  gets one without a reinstall.
- **`openspec/` and `MEMORY.md` are never in it.** The specs are the source of
  truth and *must* be committed; `MEMORY.md` is a team artifact.
- **Not a git repo?** One note, skipped, exit 0 — nothing is written.

The install summary reports which of the three happened:

```
✓ .gitignore: Kurama block added (4 patterns)
✓ .gitignore: Kurama block already present (4 patterns)
! .gitignore: not a git repo — skipped
```

`doctor.sh` checks both halves: the block missing on a project install is a
**warning**, and a machine-local file that is *already tracked* by git is a
**failure** naming the file — a `.gitignore` rule does not untrack something
already committed, so it prints the `git rm --cached` fix.

### When the repo already has its own workflow

If the prompt file Kurama merges into (`CLAUDE.md`, `AGENTS.md`, …) already
carries content of its own, `setup.sh` says so at merge time — and when that
content looks like a **workflow** (a `## Workflow` / `## Process` / `## How we
work` heading, or a numbered list of 3+ steps), it names what it found:

```
! Two workflows now live in /repo/CLAUDE.md
  This project already describes how work is done here:
    - the heading "## Workflow"
    - a numbered step list (5 steps)
  Kurama's orchestrator block was added at lines 130-335 of 335. Nothing you wrote was changed.
  The project's own instructions take precedence over Kurama's block.
```

Kurama **never refuses the install and never edits your content** — the
project's own committed instructions legitimately outrank Kurama's block. The
decision is handed to `/sdd-init`, which asks one question about how the two
should coexist (SDD's specs as the source of truth, with your issue/board
bodies reflecting them — or your flow kept, with SDD invoked selectively) and
records the answer as `workflow_coexistence`. No default is chosen silently.

---

## Session identity: persona and name

Two settings shape how the orchestrator **talks to you**. Neither one changes
what it **writes**.

### `persona` — the conversational register

**This is not a "speak Spanish" switch.** The orchestrator already speaks your
language: its **Language Domain Contract** — shipped in every generated
orchestrator, from `examples/_templates/core.md` — requires every direct reply,
clarifying question and status update to be written in the language *you* write
in, while generated artifacts default to neutral English. `persona` does not
move that line and never chooses the language. It picks the **register and
vocabulary of the half that was already going out in your language.**

Kurama ships no voice of its own by default, which is why it coexists with
Claude Code's output style, a harness persona package, and whatever else already sets a tone.
The register is therefore a **setting, not a hardcode**: a top-level `persona:`
key resolved by the session preflight.

| Value | Effect |
|-------|--------|
| `neutral` | **The default — today's exact behavior.** Nothing changes for an existing install, or for anyone who does not opt in. |
| `argentino` | A shipped preset for Spanish-language conversation: voseo (`vos`, `tenés`, `fijate`, `dale`), Latin American technical vocabulary, warm and close in tone while staying technically precise. Never Peninsular Spanish. |

The presets live in `skills/_shared/personas.md`, so adding one is a file, not a
code change.

**Where it lives:** `openspec/config.yaml` — a **committed** file, deliberately,
so the whole team shares the same register rather than each machine picking its
own, alongside every other pipeline setting (see
[persistence.md](persistence.md#where-pipeline-settings-are-configured)).
`sdd-init` asks the persona question once and persists the answer there.

**Changing it later** — either way works: re-run `sdd-init`, which upserts the
setting as it does for every setting it writes, or edit the key in
`openspec/config.yaml` by hand. It is a plain config key.

**A value that matches no shipped preset degrades to `neutral`** with a one-line
note, and never fails the session. A typo in a committed file must not break the
cycle for everyone who pulls it.

**Boundary — conversation only.** Specs, proposals, designs, task lists, commit
messages and code comments keep the project's own language: the artifact half of
the Language Domain Contract is untouched. A repo whose specs are written in one
teammate's dialect is worse off, not better. This is the same rule the repo
already applies to process skills — they run inside the phases, they do not take
the phases over.

**Precedence — your machine wins.** The setting is a *project default for people
who have not chosen*, never an override of a choice a teammate made on their own
machine. Most specific first:

1. an explicit instruction in the conversation ("contestame en inglés");
2. the voice your own environment already imposes — a Claude Code output style,
   a harness persona package, whatever your harness sets;
3. Kurama's `persona:` setting from `openspec/config.yaml`;
4. `neutral`.

So: the team set `argentino`, but your harness speaks formal English — who
wins? Your harness does. `orchestrator-sdd-protocol.md` already tells the
orchestrator to match *the user's active persona*; this setting adds a default
**underneath** that rule rather than replacing it.

### Your name — resolved, never configured

The orchestrator addresses you by name when it has one. It is resolved at
session start, in this order:

1. `git config user.name`;
2. only if that is empty, `gh api user --jq '.name // .login'`;
3. if neither answers, no name is used and nothing else changes.

It is used in orchestrator conversation only, and sparingly — the greeting, the
gates, the summary at the end of a cycle. Not in artifacts, not in every message.

**Why this is deliberately not a config key.** `openspec/config.yaml` is
committed and shared, so a name written into it would greet every teammate as
whoever ran `sdd-init`. `git config user.name` is already per-machine, costs no
network call, and every contributor has it set — which makes the name per-user
by construction and keeps it out of every committed file.

---

## Claude Code

> **Automatic:** `./scripts/setup.sh --agent claude-code` handles all steps below,
> additionally installs the **17 native subagents** into `~/.claude/agents/`
> (see [Native subagents](#native-subagents-installed-automatically) at the end of
> this section), and **always installs the deterministic hooks** (see
> [Hooks (installed automatically)](#hooks-installed-automatically)).

<details>
<summary>Manual installation</summary>

**1. Copy skills:**

```bash
cp -r skills/_shared \
      skills/sdd-* skills/review-* \
      skills/skill-registry skills/skill-creator skills/branch-pr skills/issue-creation \
      skills/judgment-day skills/tdd skills/kanban-github \
      skills/kurama-report skills/systemic-issue-triage \
      ~/.claude/skills/
```

> That is the full **28-skill default set** (14 `sdd-*`, the 5 `review-*` lenses,
> `skill-registry`, `skill-creator`, `branch-pr`, `issue-creation`, `judgment-day`,
> `tdd`, `kanban-github`, `kurama-report`, `systemic-issue-triage`). Copy all of them
> unless you deliberately want a reduced set:
> omitting the `review-*` lenses leaves the orchestrator's review triage with nothing to
> select, and omitting `tdd`/`kanban-github` leaves those modules impossible to activate
> — `sdd-init` records `enabled: false` and the phases that would use them degrade with a
> WARNING rather than failing. `skills/manifest.json` is installer metadata, not a
> skill, so it stays out of the copy.

**2. Add orchestrator to `~/.claude/CLAUDE.md`:**

Append the contents of [`examples/claude-code/CLAUDE.md`](../examples/claude-code/CLAUDE.md) to your existing `CLAUDE.md`.

The example is intentionally lean to avoid token bloat in always-loaded system prompts. The critical retrieval and persistence steps are inlined in each skill file. This keeps your existing assistant identity and adds SDD as an orchestration overlay.

</details>

**Verify:** Open Claude Code and type `/sdd-init` — it should recognize the command.

**Alternative: plugin / marketplace install.** Claude Code plugins package
skills (and, going forward, agents/hooks) with versioning and one-command
install/update instead of a manual `cp -r`. This repo ships
[`.claude-plugin/plugin.json`](../.claude-plugin/plugin.json) (name
`kurama`, version read from the repo's `VERSION` file, skills path)
and a single-entry [`.claude-plugin/marketplace.json`](../.claude-plugin/marketplace.json)
example:

```
/plugin marketplace add myst4/kurama
/plugin install kurama
```

This is an alternative to `setup.sh`/`install.sh`, not a replacement — both
paths install the same skill set.

<a id="native-subagents-installed-automatically"></a>
**Native subagents (installed automatically).** `setup.sh --agent claude-code`
now installs **all 17** declarative subagent files from
[`examples/claude-code/agents/`](../examples/claude-code/agents/) into
`~/.claude/agents/` — the **9 SDD phase** agents plus the **8 review-layer**
agents (the four 4R lenses `review-risk`/`review-readability`/`review-reliability`/`review-resilience`,
the `review-refuter`, the two Judgment Day judges `jd-judge-a`/`jd-judge-b`, and
the `jd-fix-agent`). Each file is copied **atomically**; any pre-existing file
with the same name is **backed up first** (timestamped, via the shared
`make_backup`), and every installed agent is recorded in the target's
`.kurama-install-manifest.json` receipt so `scripts/uninstall.sh` can later
remove exactly what setup added. Each agent's frontmatter (`name`,
`description`, `tools`) drives the read-only tool boundary; the agents carry
**no `model` pin**, so every one inherits the session's default model (add
`model` to an agent's frontmatter locally if you want tiered routing); see
[docs/sub-agents.md](sub-agents.md#native-claude-code-subagents-installed-automatically)
for the full roster and the tools table.

Installing the agents changes nothing about how skills or the orchestrator
behave — a project that removes them keeps working exactly as before, with the
orchestrator resolving models and skills itself per the Model Assignments table
in [`skills/_shared/model-assignments.md`](../skills/_shared/model-assignments.md).

<a id="hooks-installed-automatically"></a>
**Hooks (installed automatically).** `setup.sh --agent claude-code` now
**always installs the two deterministic-gate hooks** — no prompt, in **both**
scopes (this changed in Phase 10b; earlier versions left hooks opt-in). It:

1. Copies the two scripts from `examples/claude-code/hooks/`
   (`orchestrator-write-guard.sh`, `archive-gate.sh`) into the target's
   `hooks/kurama/` directory — `~/.claude/hooks/kurama/` (global) or
   `<repo>/.claude/hooks/kurama/` (project) — atomically, and marks them
   executable.
2. Merges a `PreToolUse` block into the matching `settings.json`
   (`~/.claude/settings.json` global, `<repo>/.claude/settings.json` project):
   `Edit|Write|MultiEdit` → the write-guard, `Task|Skill` → the archive-gate.
   Project scope anchors the commands on `$CLAUDE_PROJECT_DIR`; global scope
   uses absolute paths. Every command string contains the substring
   `hooks/kurama/`, so `uninstall.sh` can strip exactly Kurama's entries and
   leave your other hooks intact.

The merge is **careful and idempotent**: it removes any prior kurama entries
before re-adding, prefers **jq** (backup + atomic write), and — when `jq` is
missing — prints the exact manual steps rather than ever `sed`-editing JSON.
Both the scripts and the touched `settings.json` are recorded in the install
receipt. See [docs/hooks.md](hooks.md) for what each gate enforces.

**Enforcement tier: enforced.** Claude Code is the harness these gates were built
for, and the only one where both run through a first-party hook contract. The same
two scripts also back the OpenCode plugin; the other three harnesses get the rules
as prose. The per-harness verdicts, and the reason behind each, are in
[docs/hooks.md](hooks.md#enforcement-tiers--what-each-harness-actually-guarantees).

---

## OpenCode

> **Automatic:** `./scripts/setup.sh --agent opencode` handles all steps below.

OpenCode ships two real modes, and they differ in agent structure, not just model config:

| | `opencode.single.json` | `opencode.multi.json` |
|---|---|---|
| **Agent structure** | **Exactly one agent** — `sdd-orchestrator`; every SDD phase runs as a `general` subtask of it | Orchestrator + one dedicated `sdd-<phase>` agent per SDD phase (10 agents) |
| **Use case** | Ready to use as-is, one model for everything | Per-phase model customization |
| **Models** | Orchestrator's model only; subtasks inherit it | Add `"model"` fields to each phase agent |
| **Delegation** | Native `task` tool, `permission.task` limited to `general` | Native `task` tool |

The five executor slash commands (`sdd-init`, `sdd-explore`, `sdd-apply`, `sdd-verify`, `sdd-archive`) carry `agent: sdd-<phase>` in their frontmatter — never `sdd-orchestrator` — so in **multi** mode each phase runs in the agent, and the model, configured for it. In **single** mode those `sdd-<phase>` agent entries do not exist (see the mode table above); the phase work happens as a `general` subtask of the one orchestrator agent. The four workflow commands (`sdd-new`, `sdd-continue`, `sdd-ff`, `sdd-status`) stay routed to `sdd-orchestrator` in both modes, since they coordinate multiple phases rather than executing one.

```bash
./scripts/setup.sh --agent opencode                        # Interactive (asks which mode)
./scripts/setup.sh --agent opencode --opencode-mode single # Use as-is with default model
./scripts/setup.sh --agent opencode --opencode-mode multi  # Template for per-agent models
```

#### Per-Agent Model Customization (multi mode)

To assign different models per phase, edit `~/.config/opencode/opencode.json` and add `"model": "provider/model-id"` to each agent:

```json
{
  "agent": {
    "sdd-orchestrator": { "mode": "primary", "model": "anthropic/claude-sonnet-4-6" },
    "sdd-explore":      { "mode": "subagent", "model": "google/gemini-2.5-flash" },
    "sdd-spec":         { "mode": "subagent", "model": "anthropic/claude-opus-4-6" },
    "sdd-design":       { "mode": "subagent", "model": "anthropic/claude-opus-4-6" },
    "sdd-apply":        { "mode": "subagent", "model": "anthropic/claude-sonnet-4-6" },
    "sdd-verify":       { "mode": "subagent", "model": "openai/o3" }
  }
}
```

The format is `"provider/model-id"` — check your available models at `~/.cache/opencode/models.json`. Common providers: `anthropic`, `openai`, `google`, `openrouter`. Agents without a `model` field inherit the default model.

Both modes run sub-agent delegation on OpenCode's native `task` tool, which blocks until the sub-agent completes.

> **Background execution.** Kurama no longer ships the `background-agents.ts` plugin — it is third-party code that was observed hanging the OpenCode TUI at startup, and OpenCode now covers the feature itself. To opt into background sub-agents, export OpenCode's own experimental switch in your shell before launching it:
>
> ```sh
> export OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS=true
> opencode
> ```

#### Kurama startup logo (opt-in)

`--with-logo` replaces OpenCode's default splash logo with the Kurama wordmark — the same art `scripts/banner.sh` prints:

```bash
./scripts/setup.sh --agent opencode --with-logo     # install it
./scripts/setup.sh --agent opencode                 # default: OpenCode's own logo, untouched
```

Setup never asks about the logo. Without `--with-logo` nothing is written to
`tui.json` and no plugin file is copied, so the default install stays clean.

Interactive setup asks for it after the profile question and defaults to **no**. It is purely cosmetic — nothing about how agents run changes. The same flag installs [Pi's startup header](#kurama-startup-logo-opt-in-1); a single `--all` run asks the question once and applies the answer to both.

This is a **TUI plugin**, not a server plugin: it is copied to `~/.config/opencode/tui-plugins/kurama-logo.tsx` and registered in the `plugin[]` array of `~/.config/opencode/tui.json`, which is a **different list** from the server plugins OpenCode loads out of `~/.config/opencode/plugins/`. The merge is idempotent (`jq`): the file is created with its `$schema` when absent, your existing entries are preserved, and re-running setup never duplicates the entry. `scripts/uninstall.sh` removes the entry and the file again.

The plugin registers the host's `home_logo` slot, which is declared `mode: "replace"` — so it substitutes the default logo rather than drawing below it. The host does **not** pick a single winner, though: if another plugin also registers `home_logo`, both logos stack. Keep one logo plugin registered at a time.

`examples/opencode/tui-plugins/kurama-logo.tsx` is a **generated file** — it is compiled from `assets/banner/wordmark.txt` by `scripts/gen-logo-plugin.mjs` (`--check` fails with exit code 3 when either committed artifact is stale). Edit the wordmark, re-run the generator, and commit the result; never hand-edit the art inside the `.tsx`.

The setup script preserves your model choices across updates — re-running `setup.sh` will update agent prompts and tools but keep any `model` fields you configured.

<details>
<summary>Manual installation</summary>

**1. Copy skills and commands:**

```bash
cp -r skills/_shared \
      skills/sdd-* skills/review-* \
      skills/skill-registry skills/skill-creator skills/branch-pr skills/issue-creation \
      skills/judgment-day skills/tdd skills/kanban-github \
      skills/kurama-report skills/systemic-issue-triage \
      ~/.config/opencode/skills/
cp examples/opencode/commands/sdd-*.md ~/.config/opencode/commands/
cp examples/opencode/AGENTS.md ~/.config/opencode/AGENTS.md
```

> Same **28-skill default set** as above (see the note in the Claude Code section).
>
> **The `AGENTS.md` copy is the one step `setup.sh` does differently.** `setup.sh`
> **marker-merges** that file: it backs up any existing `~/.config/opencode/AGENTS.md`,
> injects only the `## Kurama` section onward between `<!-- BEGIN:kurama -->` /
> `<!-- END:kurama -->`, and records it in the receipt — so `update.sh` can re-sync the
> block and `uninstall.sh` can strip exactly it. A plain `cp` writes the whole example
> over your file with no markers and no receipt, so `doctor.sh` reports
> `orchestrator present but unmarked` and neither `update.sh` nor `uninstall.sh` can
> manage it. Re-running `setup.sh --agent opencode` converts a manual copy back into a
> marker-merged, updatable block (backing your file up first).

**2. Add orchestrator agent to `~/.config/opencode/opencode.json`:**

Merge the `agent` block from the config template into your existing config:
- Single mode: [`examples/opencode/opencode.single.json`](../examples/opencode/opencode.single.json)
- Multi mode: [`examples/opencode/opencode.multi.json`](../examples/opencode/opencode.multi.json)

The OpenCode examples now reference `~/.config/opencode/AGENTS.md` via `"prompt": "{file:./AGENTS.md}"`, so copy that file too.

In **multi** mode the `agent:` field in the five executor commands (`sdd-init.md`, `sdd-explore.md`, `sdd-apply.md`, `sdd-verify.md`, `sdd-archive.md`) points to the corresponding dedicated `sdd-<phase>` agent, not `sdd-orchestrator`, so each phase runs on the model configured for it. The workflow commands in `examples/opencode/commands/` (`sdd-new.md`, `sdd-continue.md`, `sdd-ff.md`, `sdd-status.md`) coordinate multiple phases rather than executing one; leave their `agent:` field as `sdd-orchestrator`.

In **single** mode there are no `sdd-<phase>` agents to point at: `opencode.single.json` defines exactly **one** agent, `sdd-orchestrator`, and its `permission.task` block denies every named subagent except the built-in `general` one. Phases therefore run as `general` subtasks of that single orchestrator, inheriting its model. `setup.sh` copies the command files unchanged in single mode, so their `agent:` fields still read `sdd-<phase>` even though the config defines only `sdd-orchestrator`; mirror that if you install by hand, and use `--opencode-mode multi` when you want each phase to resolve to its own agent and model.

</details>

<a id="opencode-gate-plugin"></a>
**Enforcement tier: enforced.** OpenCode is the second harness where Kurama's two
deterministic gates are a *mechanism* rather than prose. The plugin
[`examples/opencode/plugins/kurama-sdd-gates.ts`](../examples/opencode/plugins/kurama-sdd-gates.ts)
subscribes to `tool.execute.before` (and `command.execute.before`, for the
slash-command route single mode uses) and **throws** to veto the call — the only
veto the hook's `Promise<void>` signature allows, and one OpenCode honours because
it awaits the hook before the tool body without catching it.

The plugin is a **thin adapter, not a second implementation**: it translates the
OpenCode event into the same JSON payload Claude Code's `PreToolUse` hooks read on
stdin, runs the *same* two scripts from `examples/claude-code/hooks/`, and turns
their exit 2 back into a thrown error. Two fields OpenCode does not put in the
event are recovered from the plugin input — `cwd` from `PluginInput.directory`,
and the subagent marker from the session's `parentID` (the task tool creates a
child session with `parentID` set, which is OpenCode's equivalent of Claude Code's
`agent_id`, so delegated writers pass exactly as they do there).

`setup.sh --agent opencode` installs all three files (`install_opencode_gates()`),
in **both** scopes — the OpenCode flow is otherwise global-only, but a repo install
that enforced nothing while the support matrix said "enforced" is the defect this
was filed as. Each path is recorded in the install receipt, so `update.sh`
re-syncs them and `uninstall.sh` removes them.

Installed layout:

```
~/.config/opencode/plugins/kurama-sdd-gates.ts        # the adapter (auto-discovered)
~/.config/opencode/kurama/hooks/orchestrator-write-guard.sh
~/.config/opencode/kurama/hooks/archive-gate.sh       # the decision logic
```

With `--scope project` the same three land under `<repo>/.opencode/plugins/` and
`<repo>/.opencode/kurama/hooks/`. `KURAMA_HOOKS_DIR` overrides the search if you
keep the scripts somewhere else. The escape hatches are unchanged and still read
from the environment: `KURAMA_ORCHESTRATOR_GUARD=0`, `KURAMA_GUARD_BYPASS=1`,
`KURAMA_ARCHIVE_OVERRIDE=1`. If the scripts are missing, the write guard warns
once and allows (matching its documented fail-open posture) while the archive gate
refuses the archive (matching its fail-closed one) — neither degrades silently.

**How to use in OpenCode:**
- Start OpenCode in your project: `opencode .`
- Use the agent picker (Tab) and choose `sdd-orchestrator`
- Run SDD commands: `/sdd-init`, `/sdd-new <name>`, `/sdd-apply`, etc.
- Switch back to your normal agent (Tab) for day-to-day coding

---

## Codex

> **Automatic:** `./scripts/setup.sh --agent codex` handles all steps below.

<details>
<summary>Manual installation</summary>

**1. Copy skills:**

```bash
cp -r skills/_shared \
      skills/sdd-* skills/review-* \
      skills/skill-registry skills/skill-creator skills/branch-pr skills/issue-creation \
      skills/judgment-day skills/tdd skills/kanban-github \
      skills/kurama-report skills/systemic-issue-triage \
      ~/.codex/skills/
```

> Same **28-skill default set** as above (see the note in the Claude Code section).

**2. Add orchestrator instructions:**

Append the contents of [`examples/codex/agents.md`](../examples/codex/agents.md) to `~/.codex/agents.md` (or your `model_instructions_file` if configured).

</details>

**Verify:** Open Codex and type `/sdd-init`.

> **Note:** Codex runs skills inline rather than as true sub-agents. The planning phases still work well; implementation batching is handled by the orchestrator instructions.

**Enforcement tier: advisory.** Kurama's two deterministic gates do **not** run on
Codex. There is no pre-tool event to hook — the Codex hooks surface in use is
`SessionStart` in `~/.codex/hooks.json`, a lifecycle event — and because skills run
inline rather than as sub-agents, the orchestrator/executor boundary the write
guard enforces is not expressible here at all. The delegate-only rule and the
no-PASS-no-archive rule are still in the orchestrator prompt, and
`archive-gate.sh <change>` still runs standalone, so the recommended backstop is a
CI step or a manual run before closing a change. See
[docs/hooks.md](hooks.md#enforcement-tiers--what-each-harness-actually-guarantees).

**Project-level convention (documented, not installed by default).** Codex CLI
also scans a project-level `.agents/skills/` directory in addition to the
user-level `~/.codex/skills` the installer targets above. If you want the
skills scoped to one repository instead of installed globally, copy them into
that project's `.agents/skills/` yourself:

```bash
mkdir -p .agents/skills
cp -r skills/_shared \
      skills/sdd-* skills/review-* \
      skills/skill-registry skills/skill-creator skills/branch-pr skills/issue-creation \
      skills/judgment-day skills/tdd skills/kanban-github \
      skills/kurama-report skills/systemic-issue-triage \
      .agents/skills/
```

`setup.sh`/`install.sh` do not write to `.agents/skills/` — `~/.codex/skills`
remains the supported installer target; this is a manual, project-local
alternative.

---

## Pi

[Pi](https://pi.dev) reads `AGENTS.md` context files as its instructions,
concatenating a global `~/.pi/agent/AGENTS.md` and a project-root `AGENTS.md`
(among parent directories). Kurama ships Pi's orchestrator as a generated file,
[`examples/pi/AGENTS.md`](../examples/pi/AGENTS.md) — pure Markdown, with no
`gentle-pi` npm dependency.

> **Automatic:** `./scripts/setup.sh --agent pi` handles Pi setup — it detects the
> `pi` binary, copies the skills into `~/.pi/agent/skills/`, installs the **17
> native Pi agents** into `~/.pi/agent/agents/` (see
> [Native Pi subagents](#native-pi-subagents-installed-automatically)), and
> merges the orchestrator into the global `~/.pi/agent/AGENTS.md`, using the
> standard idempotent `<!-- BEGIN:kurama -->` / `<!-- END:kurama -->` markers
> (`AGENTS.md` is Markdown, so the HTML-comment markers merge cleanly and re-runs
> stay safe). For a per-project rule instead of the global one, follow the manual
> step below and append the orchestrator to your project-root `AGENTS.md`
> (`--scope project` installs the agents into `<repo>/.pi/agents/` instead).

<details>
<summary>Manual installation</summary>

**1. Copy skills** into the directory Pi reads them from (`setup.sh --agent pi`
targets it for you).

**2. Add the orchestrator:**

Append the contents of [`examples/pi/AGENTS.md`](../examples/pi/AGENTS.md) to your
project-root `AGENTS.md` (create it if it doesn't exist), or to the global
`~/.pi/agent/AGENTS.md` if you want it available across every project (this is the
file `setup.sh --agent pi` / `install.sh --agent pi` write). The Kurama block is
delimited by `<!-- BEGIN:kurama -->` / `<!-- END:kurama -->`, so it stays idempotent
and re-runnable.

</details>

**Verify:** Start Pi in your project (`pi`) and type `/sdd-init`.

> **Note:** Pi has no orchestrator-passed model parameter, so no
> orchestrator-level model table is injected; the installed agents inherit the
> session's default model. Like Codex, Pi reads the skills as inline
> instructions rather than spawning true fresh-context sub-agents.

**Enforcement tier: advisory.** Pi *does* expose a veto primitive — an extension
may register `pi.on("tool_call", …)` and return `{ block: true, reason }` to refuse
a tool call before it runs — but neither of Kurama's gates ports cleanly onto it
yet. The write guard needs to tell the main thread from a delegated writer, and
Pi's `tool_call` event carries no agent identity, so the guard would block the
delegated writer too. The archive gate needs a launch to intercept, and Pi injects
skills into the prompt rather than invoking them as a tool, so no call carries the
`sdd-archive` identity. Until both are solved the rules stay prose here; run
`archive-gate.sh <change>` manually or in CI as the backstop. Reasons in full:
[docs/hooks.md](hooks.md#enforcement-tiers--what-each-harness-actually-guarantees).

<a id="native-pi-subagents-installed-automatically"></a>
### Native Pi subagents (installed automatically)

Alongside the skills and orchestrator, `setup.sh --agent pi` installs **17
Pi-format agents** — the same roster as Claude Code (the 9 SDD phases plus the 8
review-layer agents: the four 4R lenses, the refuter, the two Judgment Day
judges, and the fix agent) — into `~/.pi/agent/agents/` (global) or
`<repo>/.pi/agents/` (project scope), each recorded in the receipt.

They are written in **Pi's** agent format, which differs from Claude's:

- `tools` is a **YAML list** of Pi tool names (`read`, `grep`, `find`, `bash`,
  `write`, `edit`, `memory_search`/`memory_get`/`memory_add`/`memory_update`).
  The read-only lenses, refuter, and judges declare `tools: [read]`; the
  `jd-fix-agent` declares `[read, bash]`; the SDD phase executors carry the
  fuller phase toolset. Pi additionally blocks every `subagent_*` tool, so these
  agents structurally cannot delegate.
- There is **no `model` key** — each agent inherits the session's default
  model, so the roster works unchanged on any provider Pi runs against (a Pi
  pin would be `provider/model-id`, which ages out and breaks non-Anthropic
  sessions). An `effort` hint ships where applicable; it is not provider-bound.
- The body **is** the complete system prompt (Pi's lean subagent mode
  auto-loads no skill or context file). Each agent instructs itself to `read`
  its Kurama skill, resolving the path relative to the project in order —
  `skills/…` → `.pi/skills/…` → `~/.pi/agent/skills/…` → `.claude/skills/…` —
  then follow it and return that skill's envelope. The agent never duplicates
  the skill body; the skill remains the single source of truth.

Every agent inherits the session's default model; per-agent `effort` in each
file is a **default**. To route specific agents to specific models — or change
an `effort` — without editing the files, use `model_profiles` in
`.pi/subagents.json` (project) or `~/.pi/agent/subagents.json` (global) — see
the `subagents-configuration` skill shipped with the `pi-subagents` extension.
Kurama does **not** write `subagents.json`; it is documented here as the
recommended override surface.

### Kurama startup logo (opt-in)

The same `--with-logo` flag that replaces [OpenCode's splash logo](#kurama-startup-logo-opt-in) also gives Pi a startup header with the Kurama wordmark:

```bash
./scripts/setup.sh --agent pi --with-logo     # install it
./scripts/setup.sh --agent pi --without-logo  # no header (default)
```

Pi needs **no registry entry**: it auto-discovers every extension in `~/.pi/agent/extensions/*.ts` (global) and `.pi/extensions/*.ts` (project scope), so setup only copies `examples/pi/extensions/kurama-logo.ts` into the matching directory — `settings.json` is never touched. Copying *is* the installation, which makes it idempotent by construction; the file is recorded in the install receipt, so `scripts/uninstall.sh` removes it again and leaves your own extensions alone.

The extension hooks `session_start` and calls `ctx.ui.setHeader()`, whose contract is `render(width) => string[]` — plain strings carrying raw ANSI, so the art is pre-rendered with the same truecolor escapes `scripts/banner.sh` emits (there is no JSX here, unlike the OpenCode plugin). It returns nothing when `ctx.hasUI` is false, degrades to a one-line `✦ KURAMA ✦` on a narrow terminal, and draws nothing at all when even that does not fit.

Like the OpenCode plugin, `examples/pi/extensions/kurama-logo.ts` is a **generated file** built from `assets/banner/wordmark.txt` by `scripts/gen-logo-plugin.mjs` — both artifacts come from that one wordmark, and `--check` verifies the pair.

### Optional Pi package stack

Beyond the skills + orchestrator, `setup.sh --agent pi` can also install a curated
stack of **Pi packages** that give Pi the runtime pieces the SDD workflow leans on —
persistent memory, an MCP adapter, native subagents, an ask-user primitive, web
access, a todo overlay, and side-conversation support. This step is **opt-in and
consent-gated**: the script **asks** before installing anything, and non-interactive
runs decide with `--with-pi-packages` / `--without-pi-packages`. Failure handling is
deliberately non-fatal — if `pi` is not on `PATH` the whole step is **skipped** with a
clear message; if an individual `pi install` fails it is logged as a **warning** and
the sequence continues (a failed package never aborts setup); and a final **summary**
reports what installed and what did not.

The packages install in this **exact order**, at **pinned** versions:

| # | Command | Package (what it adds) |
|---|---------|------------------------|
| 1 | `pi install npm:pi-mcp-adapter@2.11.0` | `pi-mcp-adapter` — MCP (Model Context Protocol) adapter extension |
| 2 | `pi install npm:pi-subagents-j0k3r@1.4.1` | `pi-subagents-j0k3r` — markdown-defined subagents, delegated task tools, history, model profiles |
| 3 | `pi install npm:@juicesharp/rpiv-ask-user-question@2.0.0` | `@juicesharp/rpiv-ask-user-question` — structured ask-user questionnaire with typed options |
| 4 | `pi install npm:pi-web-access@0.13.0` | `pi-web-access` — web search, URL fetch, repo cloning, PDF/YouTube extraction |
| 5 | `pi install npm:@juicesharp/rpiv-todo@2.0.0` | `@juicesharp/rpiv-todo` — live todo overlay that survives `/reload` and compaction |
| 6 | `pi install npm:pi-btw@0.4.1` | `pi-btw` — parallel side conversations via `/btw` |

That is **6 `pi install` packages**. The pins are **hardcoded**
in `setup.sh`; to refresh one, run
`npm view <package> version` and update the pin in the script.

> **`gentle-pi` is deliberately excluded.** The stack **never** installs `gentle-pi`.
> `gentle-pi` is a third-party npm package name, as published on the
> registry — an identifier, not an endorsement.
> `gentle-pi` is a competing, batteries-included Pi harness that ships its own orchestrator
> and skill wiring — the same orchestration surface Kurama's Pi setup already owns.
> Installing it alongside this setup would create a **direct conflict** over that
> surface (two competing orchestrators fighting for `~/.pi/agent/AGENTS.md` and the
> agent runtime). Kurama therefore installs only the individual runtime packages above
> and never the competing harness. If you specifically want the `gentle-pi` experience,
> use it on its own, not layered on top of Kurama's Pi install.

---

## omp

[omp](https://github.com/can1357/oh-my-pi) is a **separate binary** from Pi, with its
own config root. It is not Pi under another name, and the two layouts are not
interchangeable:

| Concern | Pi | omp |
|---|---|---|
| Skills | `~/.pi/agent/skills/` | `~/.omp/agent/skills/` |
| Orchestrator context | `~/.pi/agent/AGENTS.md` | `~/.omp/agent/AGENTS.md` |
| Native subagents | `~/.pi/agent/agents/` | `~/.omp/agent/agents/` |
| Sticky rules | *(no equivalent)* | `~/.omp/agent/RULES.md` |

Installing with `--agent pi` when you actually run omp lands everything where omp
never looks, leaving Kurama installed and completely invisible. Use `--agent omp`.

If `PI_CODING_AGENT_DIR` is set, omp resolves its user base from it, and every Kurama
path above moves with it.

> **Automatic:** `./scripts/setup.sh --agent omp` detects the `omp` binary, copies the
> skills into `~/.omp/agent/skills/`, installs the **17 native omp task agents** into
> `~/.omp/agent/agents/`, writes the sticky `RULES.md`, and merges the orchestrator into
> `~/.omp/agent/AGENTS.md` with the standard idempotent
> `<!-- BEGIN:kurama -->` / `<!-- END:kurama -->` markers. With
> `--scope project` everything lands under `<repo>/.omp/` instead — skills, agents,
> `RULES.md`, and `AGENTS.md`.

**Enforcement tier: advisory.** Like Pi, omp honours a `tool_call` extension hook
that can return `{ block: true, reason }` — its runtime uses that same shape to
report an extension that failed or timed out — so the primitive is there. The two
gates do not port yet for the same two reasons as Pi: the event carries no agent
identity for the write guard to discriminate on, and there is no skill-invocation
call for the archive gate to intercept. The rules stay prose here; run
`archive-gate.sh <change>` manually or in CI. Reasons in full:
[docs/hooks.md](hooks.md#enforcement-tiers--what-each-harness-actually-guarantees).

### Why omp needs its own agent set

This is the one part that cannot be shared. omp **deliberately skips** cross-harness
agent roots — `.claude/agents`, `.codex/agents`, `.gemini/agents` are filtered out
because their frontmatter is not omp's task-agent contract. Kurama's Claude and Pi
agents are therefore invisible to omp, and without a dedicated set the SDD cycle
silently degrades to inline execution with no per-phase context isolation.

The omp set applies the real contract differences:

| Pi | omp | Why |
|---|---|---|
| `effort:` | `thinkingLevel:` | omp's field name |
| `find` | `glob` | omp's tool name |
| *(implicit)* | `spawns: ""` | makes "phases are executors and never delegate" mechanical instead of prose |
| *(n/a)* | `read-summarize: false` | on the read-only lenses and the fix agent — they adjudicate exact lines, and structural summaries would hide the code they must judge |

The 7 read-only review lenses carry `tools: read` alone, so omp enforces read-only from
the allowlist rather than trusting the prompt. Model routing lives in each agent's
frontmatter, overridable per agent with `task.agentModelOverrides` in
`~/.omp/agent/config.yml`.

### RULES.md — omp's sticky rules

omp loads `RULES.md` as an **always-apply rule** re-attached near the current turn, so
it keeps its hold after a long conversation has pushed the opening context far up the
transcript. Only the invariants that must not decay live there — delegate-only
orchestration, phases never delegating, and the human merge gate — while the full
orchestrator contract stays in `AGENTS.md`, where it costs context budget once.

omp reads it **only** at its native locations: `~/.omp/agent/RULES.md`, or the nearest
`<ancestor>/.omp/RULES.md` walking up to the repo root. A `RULES.md` anywhere else is
ignored.

Unlike `AGENTS.md`, this file is replaced whole rather than marker-merged — omp has no
convention for partial rule files, and marker text inside an always-apply rule would
ship to the model on every turn. A pre-existing file is backed up first and recorded in
the receipt, so `uninstall.sh` removes exactly what was installed.

<details>
<summary>Manual installation</summary>

**1. Copy skills** into `~/.omp/agent/skills/` (global) or `<repo>/.omp/skills/`
(project). omp discovers `<root>/<name>/SKILL.md` non-recursively, which is already
Kurama's layout, and its `native` provider requires `description` frontmatter — every
Kurama skill has one.

**2. Copy the agents** from [`examples/omp/agents/`](../examples/omp/agents/) into
`~/.omp/agent/agents/` (or `<repo>/.omp/agents/`).

**3. Copy the sticky rules** from [`examples/omp/RULES.md`](../examples/omp/RULES.md) to
`~/.omp/agent/RULES.md` (or `<repo>/.omp/RULES.md`).

**4. Add the orchestrator:** append
[`examples/omp/AGENTS.md`](../examples/omp/AGENTS.md) to `~/.omp/agent/AGENTS.md`, or to
`<repo>/.omp/AGENTS.md` for one project. omp's `native` provider has the highest
discovery priority, so this file shadows every other user-level context convention.

</details>

---

## Other Tools

The skills are pure Markdown. Any AI assistant that can read files can use them.

**1. Copy skills** to wherever your tool reads instructions from.

**2. Add orchestrator instructions** to your tool's system prompt or rules file.

**3. Adapt the sub-agent pattern:**
- If your tool has a Task/sub-agent mechanism → use the pattern from `examples/claude-code/CLAUDE.md`
- If not → the orchestrator reads the skills inline (still works, just uses more context)

---

## Maintenance: update, doctor, uninstall

All three maintenance scripts are **receipt-driven** — they read the
`.kurama-install-manifest.json` that setup wrote — and they accept the same
`--scope global|project` / `--path <repo>` selectors, so they operate on exactly
what was installed (global agent dirs by default, or a trial repo).

**`update.sh` — re-sync from the current checkout.** After you `git pull` the
Kurama repo (the script never pulls or mutates your clone), `update.sh`
re-runs the idempotent installer for every recorded target and reports which
recorded files changed plus the version stamp before → after. It re-syncs
skills, native agents, hooks, and the orchestrator merge, and stamps the new
version — user-created files are never touched, and it never re-installs the Pi
package stack. For OpenCode it re-passes the recorded mode and profile; a receipt
written before those were recorded (or by `install.sh`) is **refused** with the
exact `setup.sh` command to make it re-syncable again, because guessing the mode
would delete every `sdd-*` agent a multi-mode or profile install added.

```bash
./scripts/update.sh                              # re-sync every global receipt
./scripts/update.sh --agent claude-code          # one global agent
./scripts/update.sh --scope project --path /repo # a project-scope install
./scripts/update.sh --agent pi --dry-run         # report drift, change nothing
```

Because `update.sh` re-syncs from **whatever checkout it runs from** and never pulls,
the same command is also the rollback path: `git checkout <tag> && ./scripts/update.sh`.
See [Rolling back to an earlier version](migration.md#rolling-back-to-an-earlier-version).

**`doctor.sh` — read-only health check.** Touches nothing; prints a green/red
line per check and exits non-zero on any hard failure. It verifies: the receipt
and each recorded file exist (missing = fail) and match the repo source
(drift = warning), the installed version vs the repo `VERSION`, balanced
orchestrator markers, the Claude Code hooks (scripts + the `settings.json`
block), and the environment tooling
(`gh` present + authenticated + project scope, `pi` + the package stack via
`pi list`).

For **project scope** it adds two findings that a receipt alone cannot answer:

- **Machine-local files** — the managed `.gitignore` block missing is a warning;
  a machine-local file **already tracked** by git is a failure naming the file,
  with the `git rm --cached` fix (see
  [Machine-local files and your `.gitignore`](#machine-local-files-and-your-gitignore)).
- **Installed, never initialized** — a receipt with no `openspec/config.yaml`
  means `sdd-init` never ran: the install is
  structurally complete and functionally inert, because no phase has an
  `execution_mode` or `tdd` setting to read. Reported as
  *"installed, never initialized; run `/sdd-init`"* — a **warning**, since it is
  also what every correct install looks like in the minute before you run it.

```bash
./scripts/doctor.sh                              # every global agent with a receipt
./scripts/doctor.sh --agent claude-code
./scripts/doctor.sh --scope project --path /repo
```

**`uninstall.sh` — remove exactly what was installed.** Removes every file the
receipt recorded (skills, agents, hooks), **surgically strips** the Kurama
`hooks/kurama/` block from `settings.json` (jq, with a backup) while leaving
your other hooks intact, strips the managed machine-local block from
`.gitignore` (deleting the file only if it held nothing else), prunes only
emptied directories, and — for Pi — can
**offer to revert the Pi packages** Kurama installed (`--with-pi-packages` /
`--without-pi-packages`; interactive default is no). `--dry-run` shows what
would be removed.

```bash
./scripts/uninstall.sh --agent claude-code
./scripts/uninstall.sh --scope project --path /repo   # clean removal from a trial repo
./scripts/uninstall.sh --agent pi --with-pi-packages  # also revert the Pi package stack
```

> Every script in the lifecycle — setup, install, update, doctor, uninstall, and
> the test shims — is portable bash. There is no second implementation to keep in
> parity.

---

## Smoke test

Before trusting an install end-to-end, run the manual smoke test: a ~15-minute
walk through the full SDD cycle (`init → new → ff → apply → verify → archive`) in
a throwaway toy project, once per persistence mode. It lists exactly what to
verify at each gate. See [docs/smoke-test.md](smoke-test.md).

---

## Editing the Generated Example Orchestrators

The five per-harness orchestrator files under `examples/` — `claude-code/CLAUDE.md`,
`codex/agents.md`, `opencode/AGENTS.md`, `pi/AGENTS.md`, and
`omp/AGENTS.md` — are **generated**, not
hand-written. `examples/_templates/core.md` holds the shared orchestrator
body (delegation rules, the TDD section, the canonical Result Contract), and
one `{harness}.md` overlay per harness holds only that harness's deltas.
`scripts/build-examples.sh` (portable bash 3.2/BSD) assembles core + overlay
into each output file. Every generated file opens with a comment (in that
file's own comment syntax) reading:

```
GENERATED FILE — edit examples/_templates/, then run scripts/build-examples.sh
```

**Do not hand-edit files under `examples/<harness>/`** for content that lives
in the template — edit `examples/_templates/core.md` (shared behavior) or the
matching `examples/_templates/{harness}.md` overlay (harness-specific
deltas), then run:

```bash
./scripts/build-examples.sh
```

A `pr-check.yml` job runs the same build and fails the PR if `git diff` shows
any drift, so a stale hand-edit is caught in CI even if you forget to
regenerate locally.
