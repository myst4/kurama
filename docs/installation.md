# Installation Guide

For the automated setup, run:
```bash
./scripts/setup.sh --all
```

For manual installation or specific tools, see below.

## Table of Contents
- [Install scope: global vs. project (trial a repo)](#install-scope-global-vs-project-trial-a-repo)
- [Engram (optional persistence engine)](#engram-optional-persistence-engine)
- [Claude Code](#claude-code)
- [OpenCode](#opencode)
- [Gemini CLI](#gemini-cli)
- [Codex](#codex)
- [VS Code Copilot](#vs-code-copilot)
- [Antigravity](#antigravity)
- [Cursor](#cursor)
- [Pi](#pi)
- [Other Tools](#other-tools)
- [Maintenance: update, doctor, uninstall](#maintenance-update-doctor-uninstall)
- [Smoke test](#smoke-test)
- [Editing the Generated Example Orchestrators](#editing-the-generated-example-orchestrators)

---

The recommended way to install is the **setup script** — it handles everything (skills + orchestrator prompts) in one step:

```bash
./scripts/setup.sh        # Interactive: detects agents, asks which to set up
./scripts/setup.sh --all  # Auto-detect + install all (no prompts)
```

Windows PowerShell:
```powershell
.\scripts\setup.ps1       # Interactive
.\scripts\setup.ps1 -All  # Auto-detect + install all
```

The setup script:
- Detects installed agents via PATH (`claude`, `opencode`, `gemini`, `cursor`, `code`, `codex`, `pi`)
- Copies skills to the correct directory (user-level by default; per-repo with `--scope project`)
- Configures orchestrator prompts with idempotent markers (safe to re-run)
- Installs native subagents where the harness supports them — **17 Claude Code
  agents** into `~/.claude/agents/`, and **17 Pi agents** into
  `~/.pi/agent/agents/` (see the per-harness sections)
- For **Claude Code, always installs the deterministic hooks** (both scopes, no
  prompt — see [Hooks below](#hooks-installed-automatically))
- Handles OpenCode's special case (commands + JSON config merge)
- For OpenCode: asks single vs multi-model mode (or use `--opencode-mode`)
- Asks **once** whether to use [Engram](#engram-optional-persistence-engine) as
  the persistence engine (or use `--with-engram` / `--without-engram`)

Two flags control **where** it installs:

| Flag | Meaning |
|------|---------|
| `--scope global` | (default) install to the per-user agent config dirs (`~/.claude`, `~/.pi`, …). |
| `--scope project` | install **everything into one git repo** to trial Kurama there — skills, native agents, hooks, and the orchestrator merge all land under the repo (see [Install scope](#install-scope-global-vs-project-trial-a-repo)). |
| `--path <repo>` | the target repo for `--scope project` (default: current directory). |

The default skill set installs **25 skills**, including two optional modules that
ship on disk but stay inert until you opt in per project: the TDD module
(`skills/tdd`) and the GitHub Projects Kanban module (`skills/kanban-github`). Pass
`--without tdd` to exclude the TDD module (24 skills), or `--without optional` to
exclude the `optional` group — `go-testing` **and** `kanban-github` (23 skills).
Installing a module never activates it — activation is a separate explicit
per-project switch (see [docs/tdd.md](tdd.md) and [docs/kanban-github.md](kanban-github.md)).

> **`gh` prerequisite (only to activate the Kanban module).** The optional Kanban
> board sync requires a configured GitHub CLI — `gh` installed, authenticated, and
> holding the `read:project,project` scopes (read + write). It is needed **only if you
> enable `kanban` for a project**; the module installs and every other skill works
> without `gh`. `sdd-init` verifies `gh --version`, `gh auth status`, and
> `gh project list --owner @me` when you opt in, and prints the exact fix
> (`brew install gh` / `gh auth login` / `gh auth refresh -s read:project,project`) if
> a check fails. See [docs/kanban-github.md](kanban-github.md).

> **For external installers** (e.g. [gentle-ai](https://github.com/gentleman-programming/gentleman-ai-installer)): use `--non-interactive` flag.

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
| Others | `<repo>/.claude/skills/` | — | `<repo>/CLAUDE.md` (best-effort) | — | `<repo>/.kurama-install-manifest.json` |

The install **receipt** (`.kurama-install-manifest.json`) lands at the **repo
root** for project scope (in the skills dir for global scope), and records the
scope, version, every installed file, the touched `settings.json`, any Pi
packages, and any Engram MCP registrations — so `uninstall.sh`, `update.sh`,
and `doctor.sh` (all of which accept the same `--scope`/`--path`) operate on
exactly what was installed. `setup.ps1` mirrors this with `-Scope project`
`-Path <repo>`.

---

## Engram (optional persistence engine)

By default Kurama persists SDD artifacts to its built-in **markdown fallback**
(`openspec/` / `.kurama/`) — no external dependency. Optionally, it can use
[Engram](https://github.com/Gentleman-Programming/engram) as a persistent memory
engine that survives compaction and cross-session recovery.

`setup.sh` asks **once per run** — `Use Engram as the persistence engine? [y/N]`
— or you can decide non-interactively with `--with-engram` / `--without-engram`
(non-interactive default is **no**). `setup.ps1` mirrors this with
`-WithEngram` / `-WithoutEngram`.

**With yes**, setup does two things:

1. **Ensures the `engram` binary.** If it is not on `PATH`: on macOS with
   Homebrew it offers (with explicit consent) to run
   `brew tap Gentleman-Programming/homebrew-tap && brew install engram`;
   otherwise it prints the
   [releases guide](https://github.com/Gentleman-Programming/engram/releases)
   and continues without blocking (the MCP registration still lands and
   activates once the binary is present). This is the only place setup runs a
   network command, and only after you say yes.
2. **Registers the Engram MCP server into the client being configured.** The
   exact config file and JSON shape differ per client (replicating gentle-ai's
   shapes). JSON edits go through **jq** with a backup and an atomic write; if
   `jq` is missing it prints guided manual steps and **never** `sed`-edits JSON.
   Codex uses TOML (`[mcp_servers.engram]`, block-upserted).

| Client | Config file (global) | Config file (project scope) | Key / shape |
|--------|----------------------|-----------------------------|-------------|
| Claude Code | `~/.claude.json` | `<repo>/.mcp.json` | `mcpServers.engram = { command, args: ["mcp","--tools=agent"] }` |
| OpenCode | `~/.config/opencode/opencode.json` | `<repo>/opencode.json` | `mcp.engram = { command: [cmd,"mcp","--tools=agent"], type: "local" }` |
| Cursor | `~/.cursor/mcp.json` | `<repo>/.cursor/mcp.json` | `mcpServers.engram` |
| Gemini CLI | `~/.gemini/settings.json` | `<repo>/.gemini/settings.json` | `mcpServers.engram` |
| VS Code | `~/Library/Application Support/Code/User/mcp.json` (macOS; `~/.config/Code/User/mcp.json` Linux; `%APPDATA%\Code\User\mcp.json` Windows) | `<repo>/.vscode/mcp.json` | `servers.engram` (VS Code uses `servers`, not `mcpServers`) |
| Codex | `~/.codex/config.toml` | *(skipped — Codex has a single global MCP config; run with global scope)* | `[mcp_servers.engram]` (TOML) |
| Pi | *(nothing extra)* | *(nothing extra)* | Engram on Pi is provided by the [Pi package stack](#optional-pi-package-stack) (`gentle-engram`) — no separate MCP registration |

**With no**, nothing Engram-related is written; the harness stays on the
markdown fallback (`openspec/` / `.kurama/`), and the setup summary says so.
Every file Engram registration touches is recorded in the install receipt
(`engram_mcp[]`), so `doctor.sh` can report them and `uninstall.sh` can **remove
the `engram` server** from each one — jq for JSON (or the same block strip for
Codex's TOML), backup + atomic, leaving every other MCP server and key intact.

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
cp -r skills/_shared skills/sdd-* skills/skill-registry skills/judgment-day skills/go-testing skills/skill-creator skills/branch-pr skills/issue-creation ~/.claude/skills/
```

**2. Add orchestrator to `~/.claude/CLAUDE.md`:**

Append the contents of [`examples/claude-code/CLAUDE.md`](../examples/claude-code/CLAUDE.md) to your existing `CLAUDE.md`.

The example is intentionally lean to avoid token bloat in always-loaded system prompts. Critical engram calls are inlined in each skill file. This keeps your existing assistant identity and adds SDD as an orchestration overlay.

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
`description`, `tools`, `model`) drives model routing and the read-only tool
boundary; see [docs/sub-agents.md](sub-agents.md#native-claude-code-subagents-installed-automatically)
for the full roster and the model/tools table.

Installing the agents changes nothing about how skills or the orchestrator
behave — a project that removes them keeps working exactly as before, with the
orchestrator resolving models and skills itself per the Model Assignments table
in [`examples/claude-code/CLAUDE.md`](../examples/claude-code/CLAUDE.md).

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

---

## OpenCode

> **Automatic:** `./scripts/setup.sh --agent opencode` handles all steps below.

OpenCode ships two real modes, and they differ in agent structure, not just model config:

| | `opencode.single.json` | `opencode.multi.json` |
|---|---|---|
| **Agent structure** | Orchestrator agent only — every SDD phase runs as a subtask of the orchestrator | Orchestrator + one dedicated `sdd-<phase>` agent per SDD phase |
| **Use case** | Ready to use as-is, one model for everything | Per-phase model customization |
| **Models** | Orchestrator's model only; subtasks inherit it | Add `"model"` fields to each phase agent |
| **delegate tool** | ✅ Included | ✅ Included |

Executor slash commands (`sdd-init`, `sdd-explore`, `sdd-apply`, `sdd-verify`, `sdd-archive`) route to `agent: sdd-<phase>` — never to `sdd-orchestrator` — so each phase runs in the agent (and, in multi mode, the model) configured for it. The three workflow commands (`sdd-new`, `sdd-continue`, `sdd-ff`) stay routed to `sdd-orchestrator`, since they coordinate multiple phases rather than executing one.

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

Both modes install the `background-agents` plugin (`examples/opencode/plugins/background-agents.ts`), which enables async sub-agent delegation. Use `delegate` to run sub-agents in the background (non-blocking) while the orchestrator continues other work; use `task` to block until the sub-agent completes.

The setup script preserves your model choices across updates — re-running `setup.sh` will update agent prompts and tools but keep any `model` fields you configured.

<details>
<summary>Manual installation</summary>

**1. Copy skills and commands:**

```bash
cp -r skills/_shared skills/sdd-* skills/skill-registry skills/judgment-day skills/go-testing skills/skill-creator skills/branch-pr skills/issue-creation ~/.config/opencode/skills/
cp examples/opencode/commands/sdd-*.md ~/.config/opencode/commands/
cp examples/opencode/AGENTS.md ~/.config/opencode/AGENTS.md
```

**2. Add orchestrator agent to `~/.config/opencode/opencode.json`:**

Merge the `agent` block from the config template into your existing config:
- Single mode: [`examples/opencode/opencode.single.json`](../examples/opencode/opencode.single.json)
- Multi mode: [`examples/opencode/opencode.multi.json`](../examples/opencode/opencode.multi.json)

The OpenCode examples now reference `~/.config/opencode/AGENTS.md` via `"prompt": "{file:./AGENTS.md}"`, so copy that file too.

The `agent:` field in the five executor commands (`sdd-init.md`, `sdd-explore.md`, `sdd-apply.md`, `sdd-verify.md`, `sdd-archive.md`) must point to the corresponding `sdd-<phase>` agent, not `sdd-orchestrator` — this applies in both modes, since single mode's `sdd-<phase>` entries are subtask wrappers around the orchestrator rather than dedicated agents. The other three commands in `examples/opencode/commands/` (`sdd-new.md`, `sdd-continue.md`, `sdd-ff.md`) are workflow commands that coordinate multiple phases; leave their `agent:` field as `sdd-orchestrator`.

</details>

**How to use in OpenCode:**
- Start OpenCode in your project: `opencode .`
- Use the agent picker (Tab) and choose `sdd-orchestrator`
- Run SDD commands: `/sdd-init`, `/sdd-new <name>`, `/sdd-apply`, etc.
- Switch back to your normal agent (Tab) for day-to-day coding

---

## Gemini CLI

> **Automatic:** `./scripts/setup.sh --agent gemini-cli` handles all steps below.

<details>
<summary>Manual installation</summary>

**1. Copy skills:**

```bash
cp -r skills/_shared skills/sdd-* skills/skill-registry skills/judgment-day skills/go-testing skills/skill-creator skills/branch-pr skills/issue-creation ~/.gemini/skills/
```

**2. Add orchestrator to `~/.gemini/GEMINI.md`:**

Append the contents of [`examples/gemini-cli/GEMINI.md`](../examples/gemini-cli/GEMINI.md) to your Gemini system prompt file (create it if it doesn't exist).

Make sure `GEMINI_SYSTEM_MD=1` is set in `~/.gemini/.env` so Gemini loads the system prompt.

</details>

**Verify:** Open Gemini CLI and type `/sdd-init`.

> **Note:** Gemini CLI doesn't have a native Task tool for sub-agent delegation. The skills work as inline instructions. For the best sub-agent experience, use Claude Code or OpenCode.

**Alternative: Gemini CLI extension.** This repo ships a
[`gemini-extension.json`](../gemini-extension.json) manifest referencing the
orchestrator context (`GEMINI.md`) and the skills directory, so Gemini's
native extension installer can set both up in one step instead of the manual
copy above:

```
gemini extensions install https://github.com/myst4/kurama
```

---

## Codex

> **Automatic:** `./scripts/setup.sh --agent codex` handles all steps below.

<details>
<summary>Manual installation</summary>

**1. Copy skills:**

```bash
cp -r skills/_shared skills/sdd-* skills/skill-registry skills/judgment-day skills/go-testing skills/skill-creator skills/branch-pr skills/issue-creation ~/.codex/skills/
```

**2. Add orchestrator instructions:**

Append the contents of [`examples/codex/agents.md`](../examples/codex/agents.md) to `~/.codex/agents.md` (or your `model_instructions_file` if configured).

</details>

**Verify:** Open Codex and type `/sdd-init`.

> **Note:** Like Gemini CLI, Codex runs skills inline rather than as true sub-agents. The planning phases still work well; implementation batching is handled by the orchestrator instructions.

**Project-level convention (documented, not installed by default).** Codex CLI
also scans a project-level `.agents/skills/` directory in addition to the
user-level `~/.codex/skills` the installer targets above. If you want the
skills scoped to one repository instead of installed globally, copy them into
that project's `.agents/skills/` yourself:

```bash
mkdir -p .agents/skills
cp -r skills/_shared skills/sdd-* skills/skill-registry skills/judgment-day skills/go-testing skills/skill-creator skills/branch-pr skills/issue-creation .agents/skills/
```

`setup.sh`/`install.sh` do not write to `.agents/skills/` — `~/.codex/skills`
remains the supported installer target; this is a manual, project-local
alternative.

---

## VS Code (Copilot)

> **Automatic:** `./scripts/setup.sh --agent vscode` handles all steps below.

<details>
<summary>Manual installation</summary>

**1. Copy skills:**

```bash
cp -r skills/_shared skills/sdd-* skills/skill-registry skills/judgment-day skills/go-testing skills/skill-creator skills/branch-pr skills/issue-creation ~/.copilot/skills/
```

**2. Add orchestrator instructions:**

Create a VS Code `.instructions.md` file in the User prompts folder with the orchestrator from [`examples/vscode/copilot-instructions.md`](../examples/vscode/copilot-instructions.md).

Prompt file paths:
- macOS: `~/Library/Application Support/Code/User/prompts/kurama.instructions.md`
- Linux: `~/.config/Code/User/prompts/kurama.instructions.md`
- Windows: `%APPDATA%\Code\User\prompts\kurama.instructions.md`

</details>

**Verify:** Open VS Code, open the Chat panel (Ctrl+Cmd+I / Ctrl+Alt+I), and type `/sdd-init`.

> **Note:** VS Code Copilot supports agent mode with tool use. For true sub-agent delegation with fresh context windows, use Claude Code or OpenCode.

---

## Antigravity

[Antigravity](https://antigravity.google) is Google's AI-first IDE with native skill support. Not yet supported by the setup script — manual installation required.

**1. Copy skills:**

```bash
# Global (available across all projects)
cp -r skills/_shared skills/sdd-* skills/skill-registry skills/judgment-day skills/go-testing skills/skill-creator skills/branch-pr skills/issue-creation ~/.gemini/antigravity/skills/

# Workspace-specific (per project)
mkdir -p .agent/skills
cp -r skills/_shared skills/sdd-* skills/skill-registry skills/judgment-day skills/go-testing skills/skill-creator skills/branch-pr skills/issue-creation .agent/skills/
```

**2. Add orchestrator instructions:**

Add the SDD orchestrator as a global rule in `~/.gemini/GEMINI.md`, or create a workspace rule in `.agent/rules/sdd-orchestrator.md`.

See [`examples/antigravity/sdd-orchestrator.md`](../examples/antigravity/sdd-orchestrator.md) for the rule content.

**3. Verify:**

Open Antigravity and type `/sdd-init` in the agent panel.

> **Note:** Antigravity uses `.agent/skills/` and `.agent/rules/` for workspace config, and `~/.gemini/antigravity/skills/` for global. It does NOT use `.vscode/` paths.

---

## Cursor

> **Automatic:** `./scripts/setup.sh --agent cursor` copies the skills and
> writes a global rule to `~/.cursor/rules/kurama.mdc`, sourced
> verbatim from the generated
> `examples/cursor/.cursor/rules/sdd-orchestrator.mdc` (frontmatter-scoped
> `.mdc` format; the legacy `.cursorrules` file has been removed).

<details>
<summary>Manual installation</summary>

**1. Copy skills:**

```bash
# Global
cp -r skills/_shared skills/sdd-* skills/skill-registry skills/judgment-day skills/go-testing skills/skill-creator skills/branch-pr skills/issue-creation ~/.cursor/skills/

# Or per-project
cp -r skills/_shared skills/sdd-* skills/skill-registry skills/judgment-day skills/go-testing skills/skill-creator skills/branch-pr skills/issue-creation ./your-project/skills/
```

**2. Add the orchestrator rule:**

Cursor's supported rule format is `.cursor/rules/*.mdc` (glob-scoped, with
activation modes) — the older `.cursorrules` file is deprecated and no longer
shipped. Copy
[`examples/cursor/.cursor/rules/sdd-orchestrator.mdc`](../examples/cursor/.cursor/rules/sdd-orchestrator.mdc)
into your project's `.cursor/rules/` directory for a per-project rule, or into
`~/.cursor/rules/` for a global one (`setup.sh` does the global copy for you,
verbatim, as `kurama.mdc`).

</details>

**Note:** Cursor doesn't have a Task tool for true sub-agent delegation. The skills still work — Cursor reads them as instructions — but the orchestrator runs inline. For the best sub-agent experience, use Claude Code or OpenCode.

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

> **Note:** Pi routes models per-agent, so no orchestrator-level model table is
> injected. Like Gemini CLI and Codex, Pi reads the skills as inline instructions
> rather than spawning true fresh-context sub-agents.

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
- `model` is `provider/model-id` — `anthropic/claude-sonnet-4-5` for the 4R
  lenses (and the lighter SDD phases), `anthropic/claude-opus-4-8` for the
  refuter, both judges, the fix agent, and the `sdd-design`/`sdd-apply` phases —
  with an `effort` hint where applicable.
- The body **is** the complete system prompt (Pi's lean subagent mode
  auto-loads no skill or context file). Each agent instructs itself to `read`
  its Kurama skill, resolving the path relative to the project in order —
  `skills/…` → `.pi/skills/…` → `~/.pi/agent/skills/…` → `.claude/skills/…` —
  then follow it and return that skill's envelope. The agent never duplicates
  the skill body; the skill remains the single source of truth.

Per-agent model/effort in each file are **defaults**. Override them without
editing the files via `model_profiles` in `.pi/subagents.json` (project) or
`~/.pi/agent/subagents.json` (global) — see the `subagents-configuration` skill
shipped with the `pi-subagents` extension. Kurama does **not** write
`subagents.json`; it is documented here as the recommended override surface.

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
reports what installed and what did not. `setup.ps1` mirrors this on Windows.

The packages install in this **exact order**, at **pinned** versions:

| # | Command | Package (what it adds) |
|---|---------|------------------------|
| 1 | `pi install npm:gentle-engram@0.1.10` | `gentle-engram` — persistent memory shared across sessions, compactions, and MCP agents |
| 2 | `pi install npm:pi-mcp-adapter@2.11.0` | `pi-mcp-adapter` — MCP (Model Context Protocol) adapter extension |
| 3 | `npm exec --yes --package gentle-engram@0.1.10 -- pi-engram init` | one-time `pi-engram` initialization (uses the `gentle-engram` pin) |
| 4 | `pi install npm:pi-subagents-j0k3r@1.4.1` | `pi-subagents-j0k3r` — markdown-defined subagents, delegated task tools, history, model profiles |
| 5 | `pi install npm:@juicesharp/rpiv-ask-user-question@2.0.0` | `@juicesharp/rpiv-ask-user-question` — structured ask-user questionnaire with typed options |
| 6 | `pi install npm:pi-web-access@0.13.0` | `pi-web-access` — web search, URL fetch, repo cloning, PDF/YouTube extraction |
| 7 | `pi install npm:@juicesharp/rpiv-todo@2.0.0` | `@juicesharp/rpiv-todo` — live todo overlay that survives `/reload` and compaction |
| 8 | `pi install npm:pi-btw@0.4.1` | `pi-btw` — parallel side conversations via `/btw` |

That is **7 `pi install` packages plus the one-time `pi-engram init`** (step 3, which
reuses `gentle-engram` rather than being an eighth package). The pins are **hardcoded**
in `setup.sh` (and mirrored in `setup.ps1`); to refresh one, run
`npm view <package> version` and update the pin in the script.

> **`gentle-pi` is deliberately excluded.** The stack **never** installs `gentle-pi`.
> `gentle-pi` is a rival, batteries-included Pi harness that ships its own orchestrator
> and skill wiring — the same orchestration surface Kurama's Pi setup already owns.
> Installing it alongside this setup would create a **direct conflict** over that
> surface (two competing orchestrators fighting for `~/.pi/agent/AGENTS.md` and the
> agent runtime). Kurama therefore installs only the individual runtime packages above
> and never the competing harness. If you specifically want the `gentle-pi` experience,
> use it on its own, not layered on top of Kurama's Pi install.

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
package stack.

```bash
./scripts/update.sh                              # re-sync every global receipt
./scripts/update.sh --agent claude-code          # one global agent
./scripts/update.sh --scope project --path /repo # a project-scope install
./scripts/update.sh --agent pi --dry-run         # report drift, change nothing
```

**`doctor.sh` — read-only health check.** Touches nothing; prints a green/red
line per check and exits non-zero on any hard failure. It verifies: the receipt
and each recorded file exist (missing = fail) and match the repo source
(drift = warning), the installed version vs the repo `VERSION`, balanced
orchestrator markers, the Claude Code hooks (scripts + the `settings.json`
block), the recorded Engram MCP registrations, and the environment tooling
(`gh` present + authenticated + project scope, `pi` + the package stack via
`pi list`, `engram` present + responding).

```bash
./scripts/doctor.sh                              # every global agent with a receipt
./scripts/doctor.sh --agent claude-code
./scripts/doctor.sh --scope project --path /repo
```

**`uninstall.sh` — remove exactly what was installed.** Removes every file the
receipt recorded (skills, agents, hooks), **surgically strips** the Kurama
`hooks/kurama/` block from `settings.json` (jq, with a backup) while leaving
your other hooks intact, prunes only emptied directories, and — for Pi — can
**offer to revert the Pi packages** Kurama installed (`--with-pi-packages` /
`--without-pi-packages`; interactive default is no). `--dry-run` shows what
would be removed.

```bash
./scripts/uninstall.sh --agent claude-code
./scripts/uninstall.sh --scope project --path /repo   # clean removal from a trial repo
./scripts/uninstall.sh --agent pi --with-pi-packages  # also revert the Pi package stack
```

> `setup.ps1` mirrors `-Scope`/`-Path`, the always-on hooks, and Engram on
> Windows. The maintenance scripts (`update.sh`/`doctor.sh`/`uninstall.sh`) and
> the test shims are **bash-only** — the PowerShell parity gap is unchanged from
> earlier phases.

---

## Smoke test

Before trusting an install end-to-end, run the manual smoke test: a ~15-minute
walk through the full SDD cycle (`init → new → ff → apply → verify → archive`) in
a throwaway toy project, once per persistence mode. It lists exactly what to
verify at each gate. See [docs/smoke-test.md](smoke-test.md).

---

## Editing the Generated Example Orchestrators

The eight per-harness orchestrator files under `examples/` — `claude-code/CLAUDE.md`,
`codex/agents.md`, `gemini-cli/GEMINI.md`, `opencode/AGENTS.md`,
`antigravity/sdd-orchestrator.md`, `vscode/copilot-instructions.md`,
`cursor/.cursor/rules/sdd-orchestrator.mdc`, and `pi/AGENTS.md` — are **generated**, not
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
