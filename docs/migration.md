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

## `go-testing` moved to the opt-in `lang` group

The default install carries **one skill fewer**: `go-testing` moved to a new
`lang` manifest group that is **OFF by default**.

**Why it moved.** It was the only language-specific skill shipped to every user of
every language. The skill registry is already the agnostic extension point for
per-language patterns, so the special case bought nothing and contradicted the
stack-agnostic claim.

**Nothing was deleted.** The skill file is unchanged and still ships in the repo.

**If you rely on it**, add `--with lang`:

```bash
./scripts/install.sh --agent claude-code --with lang
```

```powershell
.\scripts\install.ps1 -Agent claude-code -With lang
```

Otherwise place your own language skills anywhere the skill registry scans, and they
reach sub-agents as compact rules the same way.

## Breaking change: the `none` artifact-store mode was removed

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
