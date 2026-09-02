# Migration Guide

Guidance for existing installations moving between the current (6.x) and previous
(5.x) release series. For what changed and when, see
[docs/changelog.md](changelog.md); for the persistence contract itself, see
[docs/persistence.md](persistence.md). Migrations from pre-5.0.0 releases (5.0.0 was
the first stable release) have been retired from this guide — check out the old tag
and re-run setup, per "Rolling back" below.

## Rolling back to an earlier version

A bad release is recoverable with the tools already in the repo — there is no
downgrade command to learn. `update.sh` re-syncs every recorded install from **the
checkout it runs from**, and it never pulls, fetches, or otherwise mutates your clone
(it runs no network command at all). So rolling back is *checkout the old tag, then
update*:

```bash
cd /path/to/kurama
git fetch --tags
git checkout v5.0.0            # any tag or commit you want to go back to
./scripts/update.sh --dry-run  # report what would change, write nothing
./scripts/update.sh            # re-sync every global receipt from THAT checkout
./scripts/doctor.sh            # confirm receipts, markers, hooks, version
```

Both scripts take `--agent <name>` to roll back a single target and
`--scope project --path <repo>` for a per-repo install.

**What it does.** Re-copies skills, native agents, hooks, and the orchestrator
marker-merge from the checked-out tag, then re-stamps each receipt's version and
commit — so `doctor.sh` stops reporting a version mismatch and the install matches
the code you rolled back to.

**What it does not do.**

- It does not roll back your **SDD artifacts**. `openspec/` and `.kurama/` are project
  data, versioned by your project's own git history, not by Kurama's.
- It does not **delete** files a newer version added. `update.sh` re-runs the
  idempotent installer; it does not diff-and-prune. If the version you are leaving
  installed a file the older one never had — a skill that did not exist yet, an extra
  native agent — that file stays on disk. For a clean slate, run
  `./scripts/uninstall.sh` (on the *newer* checkout, so it removes exactly what the
  newer receipt records) and then `./scripts/setup.sh` from the old one.
- It does not re-install the Pi package stack, and it never touches your clone's git
  state beyond the checkout you performed yourself.

**Two guards to expect.**

- You are running the **old** `update.sh` and the **old** `setup.sh`, and each re-sync
  rewrites the receipt. Receipt fields a newer version introduced are not understood by
  the older scripts and can be dropped from the rewritten receipt; re-running the newer
  `setup.sh` restores them.
- A global **OpenCode** receipt that records no agent mode is *refused* rather than
  re-synced — guessing would reset a multi-mode or profile install to single mode and
  delete its `sdd-*` agents. Other targets still update; the message prints the exact
  `setup.sh --agent opencode --opencode-mode …` command that makes the receipt
  re-syncable.

## 6.3.0 — the artifact store collapses to files, and the skill registry becomes an explicit list

### The artifact store

Engram was an **optional** third-party persistence engine. It is gone from Kurama
entirely. Artifacts are files under `openspec/`, always — that is the only store,
and there is no setting to choose it. See
[docs/persistence.md](persistence.md).

**What disappears.**

- The `artifact_store.mode` key and its three modes (`engram`, `openspec`,
  `hybrid`). There is no enum left to set.
- The installer flags `--with-engram` / `--without-engram`. `setup.sh` now answers
  `Unknown option` — a stale flag in a script or CI job stops the install rather
  than silently doing nothing. Delete the flag.
- The Engram MCP registration setup used to write into `.mcp.json`,
  `~/.claude.json`, `opencode.json` and `~/.codex/config.toml`. Nothing is
  registered any more.
- The `gentle-engram` package in the Pi package stack, and the one-time
  `pi-engram init` step. The stack is now 6 `pi install` packages.
- The `engram` and `engram_mcp` receipt keys. New receipts do not carry them; an
  old receipt that still does is simply ignored.
- The `doctor.sh` Engram checks (binary present, MCP registered) and the Engram
  toggle in the setup TUI.
- `skills/_shared/engram-convention.md`, deleted from the repo.
- The `mem_*` entries in the shipped Claude Code sub-agent `tools:` lists.

**The one-line move for existing projects.** An `openspec/config.yaml` that still
carries `artifact_store.mode` is **inert** — nothing reads it. On the next
`sdd-new` / `sdd-continue`, the orchestrator prints one line saying the key is
unsupported since 6.3.0, that artifacts are files under `openspec/`, and that you
can move `.kurama/sdd/<change>/*.md` to `openspec/changes/<change>/` if you want
the old ones — then the cycle proceeds normally. **Nothing rewrites your config**,
and no migration tooling ships. Delete the key by hand whenever you feel like it,
or leave it.

**What stays, untouched.**

- `.kurama/sdd/{change}/state.md`, `verify-report.md` and `archive-report.md` —
  the three machine-local, gitignored cycle markers the two Claude Code hooks read.
  They are not artifacts and were never gated by the mode.
- `MEMORY.md` and the `sdd-learn` skill that curates it — the committed team
  knowledge file is unrelated to Engram and behaves exactly as before.
- The `## Key Learnings` section that closes every phase's return envelope.

**Nothing is uninstalled automatically.** If you had the Engram MCP server
registered, `scripts/uninstall.sh` no longer removes it — it only removes what the
receipt records, and new receipts record no Engram registration. To get rid of it,
**remove the `engram` MCP entry from your client config by hand** (`~/.claude.json`
or `<repo>/.mcp.json`, `~/.config/opencode/opencode.json` or
`<repo>/opencode.json`, `[mcp_servers.engram]` in `~/.codex/config.toml`). That is
the one manual step. Leaving it registered is harmless — Kurama never calls it —
but nothing will clean it up for you.

### The skill registry

The skill registry is gone: `skills/skill-registry/`,
`skills/_shared/build-skill-registry.sh`, `skills/_shared/skill-resolver.md` and
the generated `.kurama/skill-registry.md`. Nothing scans your skills directories any
more, and nothing matches triggers at delegation time.

**What replaces it: `standards:`.** `openspec/config.yaml` gains an ordered list of
file paths. Every SDD phase sub-agent reads each of them in full at phase start; the
orchestrator forwards the list verbatim as its `## Project Standards (files to read)`
block. What binds a sub-agent is what you wrote in that list, and nothing else.

```yaml
# openspec/config.yaml
standards:
  - CLAUDE.md
  - .claude/skills/api-conventions/SKILL.md
  - ~/.claude/skills/superpowers/skills/systematic-debugging/SKILL.md
```

**What to put there.** Your project's own conventions: `CLAUDE.md` / `AGENTS.md`, the
convention skills committed in the repo, and any companion skill you deliberately want
applied to every phase (paths in [docs/companion-skills.md](companion-skills.md)).
Paths are repo-relative, or `~`-relative for a file outside the repo. **Do not list
Kurama's own skills** — the orchestrator and the phase skills reach those by direct
path, exactly as before.

**What NOT to put there.** Everything the registry used to sweep up on your behalf. In
a real repo the registry held ~112 rows: 13 were Kurama's own, ~99 were the developer's
personal skills collection (marketing, design, browser QA) and **zero** were the
project's conventions. `standards:` is deliberately the opposite default — empty until
you fill it, and read in full when you do.

**The move for an existing project.** Nothing is migrated for you and nothing breaks:
a config with no `standards:` key means the project declares no standards, and the
`## Project Standards` block is simply omitted from delegations. To adopt it, either
add the key by hand or re-run `/sdd-init`, whose Step 4 proposes a list from the
project's own files — `CLAUDE.md`/`AGENTS.md` plus in-repo `*/SKILL.md` that are not
Kurama's — shows it, and asks once before writing. **It never scans `~`**: a file
outside the repo gets in only because you typed it.

**A path that cannot be read is loud, not fatal.** The phase notes
`standards: {path} not found` in its return envelope's `risks` and carries on. A typo
never blocks a cycle, and a standard nobody read never disappears silently.

**Also gone with it.** `setup.sh` and `update.sh` no longer build a registry after
installing or re-syncing; `doctor.sh` no longer checks for the builder, and its
`initialized:` grade is now `openspec/config.yaml` alone — `.kurama/` is no longer
accepted as evidence that `/sdd-init` ran. The `/skill-registry` command no longer
exists; the default skill set is **27**. In the phase return envelope,
`skill_resolution` drops the `fallback-registry` value (`injected`, `fallback-path`
and `none` remain).

## Breaking change: Windows is no longer supported

Kurama runs on **macOS and Linux**. `scripts/setup.ps1` and `scripts/install.ps1`
are gone.

**Why it changed.** The PowerShell scripts were a second implementation of the
installer kept in parity by hand, and it had already drifted — `setup.ps1` never
supported `omp`. The rest of the lifecycle (`update.sh`, `doctor.sh`,
`uninstall.sh`, the test suite) was always bash-only, so a Windows install had no
maintenance path: nothing to update it, check it, or remove it cleanly.

**What you will see.** `.\scripts\setup.ps1` no longer exists. The bash scripts no
longer resolve `USERPROFILE`/`APPDATA` or detect Git Bash / MSYS / Cygwin.

**If you are on Windows**, use **WSL** and run the bash scripts there — they
install to the WSL-side `$HOME`, which is where an agent running inside WSL looks.
This is the same thing the old `wsl` branch did, minus the Git-Bash path. A native
Windows install is no longer supported.

## Breaking change: Gemini CLI, Cursor, VS Code Copilot and Antigravity are no longer supported

The supported harnesses are now **Claude Code, OpenCode, Codex, Pi, and omp**.

**Why it changed.** Kurama's premise is delegation to sub-agents with isolated,
fresh context windows. Of the four dropped hosts, none provides that primitive —
the orchestrator ran inline on all of them, which is the context-flywheel the
harness exists to break. Each still cost six edit points across the two setup
scripts plus its own template, generated example, tests, and docs; Cursor also
forced the prompt writer's only special case (a verbatim `.mdc` copy that
`uninstall.sh` could not surgically strip).

**What you will see.** `setup.sh --agent gemini-cli|cursor|vscode|antigravity`
now exits with `Unknown option`. `--all` no longer detects the `gemini`, `cursor`
or `code` binaries. `gemini-extension.json` and the corresponding `examples/`
directories are gone, so `gemini extensions install` no longer works.

**If you have an existing install on one of these**, nothing is deleted from your
machine — but it is no longer managed. `update.sh` fails loudly on those receipts
instead of re-syncing (their slug no longer resolves), and `uninstall.sh --all`
no longer visits their paths. To clean up, remove the skills directory
(`~/.gemini/skills`, `~/.cursor/skills`, `~/.copilot/skills`,
`~/.gemini/antigravity/skills`) and strip the `BEGIN:kurama … END:kurama` block
from the corresponding prompt file by hand. Cursor's rule file
(`~/.cursor/rules/kurama.mdc`) is entirely Kurama's and can be deleted outright.

**If you want to keep using one of them**, the skills are plain Markdown in the
open [Agent Skills](https://agentskills.io) format — copy `skills/` wherever that
host reads skills and paste `examples/_templates/core.md` as your orchestrator
prompt. That is the manual path the installer used to automate.

## Breaking change: project commands are asked, not detected

`sdd-init` now ASKS for the project's test command, build command, and (when TDD is
enabled) single-test command, instead of inferring them from a closed table of
ecosystems.

**Why it changed.** The table covered 8 ecosystems and sat on the PRIMARY resolution
path, so any stack outside it dead-ended: `sdd-verify` found no runner and, in
`behavioral` mode, turned every MUST scenario into UNTESTED → CRITICAL. A harness that
claims to be stack-agnostic cannot carry a supported-language allowlist on its critical
path. The inversion also restores consistency — `tdd.enabled`, `execution_mode`, and
`kanban.enabled` were already explicit questions; the most project-specific value of
all was the one being guessed.

**What you will see.** `/sdd-init` asks for the commands, pre-filled with a suggestion
when a familiar detection file is present. An empty answer is valid and means "this
project has none" — it is recorded as empty, not re-guessed.

**If a phase reports a missing command**, the fix is always the same: re-run
`/sdd-init`, or set `rules.verify.test_command` / `rules.verify.build_command` (and
`tdd.single_test_command`) directly. No phase guesses a command anymore — a guessed
command fails opaquely or, worse, runs the wrong thing.

**Existing projects need no action.** A config that already has these keys keeps
working unchanged; the propagated-value precedence is untouched.

## Breaking change: `go-testing` is deleted and the `lang` group no longer exists

6.2.x parked the one language-specific skill in an opt-in `lang` group instead of
deciding about it. This release decides: the skill file is **deleted** from the repo
and the group that held it is gone from `skills/manifest.json`, from `setup.sh`, and
from `install.sh`. On-disk skills go **29 → 28**; the default set is unchanged at 28,
because the group was already off.

**Why.** Parking it kept the contradiction alive in a quieter place. One ecosystem
still had a skill written for it by the harness while every other ecosystem had to
supply its own, and the group's whole population was that single file. A group with
nothing in it is not an extension point — the skill registry is, and it always was.

**`--with lang` is now rejected.** It does not degrade to a no-op: an unknown group
name fails with `Unknown skill group: lang (valid: quality, review, optional, tdd)`
and stops the install. A silent no-op would let a command keep claiming it installs
Go patterns forever. If that flag is in a script or a CI job, delete the flag.

**If you were installing it on purpose**, keep your own copy: pull
`skills/go-testing/SKILL.md` from tag `v6.2.0` and drop it anywhere the skill registry
scans (`~/.claude/skills/`, or `.claude/skills/` inside the project). Sub-agents then
receive it exactly as before — the registry never cared who wrote a skill.

```bash
mkdir -p ~/.claude/skills/go-testing
git show v6.2.0:skills/go-testing/SKILL.md > ~/.claude/skills/go-testing/SKILL.md
```

A future upstream sync cannot quietly restore it: `go-testing` is now on the
**Deliberate removals stay removed** list in `.github/workflows/pr-check.yml`, which
fails any PR whose docs advertise it again.

## Breaking change: the `none` artifact-store mode was removed

> **Superseded in 6.3.0**, which removed the enum entirely — see
> [the artifact store collapses to files](#630--the-artifact-store-collapses-to-files).
> This section is kept for anyone upgrading from a 5.x install.

The artifact-store enum is now `engram | openspec | hybrid`. `none` — persist no
SDD artifacts, return them inline — no longer exists.

**Why it went.** The whole point of the workflow is that specs are the source of
truth, and `none` produced nothing that survived the session. `sdd-archive` had no
delta spec to merge, so the main specs never advanced: a cycle could complete and
leave the source of truth exactly where it started. The mode also cost a branch in
every phase's persistence section, for a setting no project benefited from choosing.

**If your project used it**, you will see the mode reported as unsupported rather
than silently writing nothing. To migrate:

1. Set the mode to `openspec` in `openspec/config.yaml` (or in the
   `sdd-init/{project}` settings artifact for Engram-backed projects).
2. Re-run `/sdd-init` to regenerate the config against the current schema.

**There is no data to move.** `none` never wrote artifacts, so nothing exists to
migrate — only the setting changes. Everything a past `none` cycle produced was
already inline in a conversation and is not recoverable by this or any other route.

**Unrelated to this change**: `.kurama/` is harness infrastructure and was never
gated by the persistence mode. The skill registry and the `.kurama/sdd/` fallback
(used when Engram is the intended backend but is unreachable) behave exactly as
before.

## Detecting an old install/clone

- No `VERSION` file at the repo root → your clone predates the 5.0.0 versioning scheme.
- No `skills/manifest.json` → your clone predates manifest-driven install; the
  installers still work off the hardcoded skill list.
- No install manifest under your install target (see per-harness paths in
  [docs/installation.md](installation.md)) → `scripts/uninstall.sh` has
  nothing to work from until you re-run setup/install.
