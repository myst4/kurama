# TUI detect-and-update pre-flight

Date: 2026-08-10
Status: approved, ready for implementation
Depends on: `2026-08-10-project-receipt-multi-tool-design.md` (PR #11) — the pre-flight reads
`tools[]` to name the installed harnesses.

## Problem

`scripts/setup-tui.sh` always runs the install flow. Someone who already has Kurama and wants
to update it, or to check whether the install is healthy, gets asked which harnesses to
install and at what scope — and the command it builds is a `setup.sh` line, not `update.sh`
or `doctor.sh`. The TUI is the front door and it only knows one destination.

## Design

A new pre-flight phase runs before harness selection. If it finds nothing, the script behaves
exactly as it does today.

### Where it goes

After phase 0 (`--- 0. open the screen ---`, line 91-97) and before phase 1
(`--- 1. which harnesses ---`, line 99). It needs `heading`/`hint` and gum styling, which are
defined at lines 72-89, so it cannot move above the theming block.

### What it probes

Two receipt locations, because they differ by scope and checking only one reports "not
installed" on a machine that has it:

- **global** — `<skills dir>/.kurama-install-manifest.json` for each of the five harnesses.
  The skills dirs mirror `get_skills_path()` in `scripts/setup.sh:204-216`: `~/.claude/skills`,
  `~/.config/opencode/skills`, `~/.codex/skills`, `~/.pi/agent/skills`, and
  `${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}/skills`.
- **project** — `$PWD/.kurama-install-manifest.json`.

`$PWD` is the user's repo in the intended invocation (`bash /path/to/kurama/scripts/setup-tui.sh`
from inside their project). Running it from the Kurama checkout itself finds nothing, because
`setup.sh` refuses to install into the Kurama repo — so there is no false positive there.

### What it presents

At most two targets, because that is what the maintenance scripts already accept as units:

- `global` — one target. `update.sh` and `doctor.sh` with no `--agent` already loop every
  global receipt themselves, so the TUI must not re-implement that loop.
- `project` — one target, `$PWD`.

Each is labelled with its recorded tools and version, read from the receipt: `tools[]` when
present, falling back to the scalar `tool` for v6 and legacy `install.sh` receipts.

When both exist, one `gum choose` picks the target. When only one exists, it is used without
asking.

Then a `gum choose` of four actions:

| Action | Command built |
|---|---|
| Update | `./scripts/update.sh` (+ `--scope project --path "$PWD"`) |
| Diagnose | `./scripts/doctor.sh` (+ `--scope project --path "$PWD"`) |
| Install again | falls through to phase 1, today's flow unchanged |
| Exit | `exit 0` |

Update and Diagnose render the command in the same bordered preview box the install flow uses,
gate it behind `gum confirm "Run it now?"`, and run it with `bash "$SCRIPT_DIR/<script>" "$@"`
— argv rebuilt with `set --`, never `eval`, matching phase 6 (lines 241-278). The script keeps
its contract: it builds commands, it does not install anything itself.

### Testable seam

A gum TUI cannot be driven from `install_test.sh`, but the probe is pure bash and carries the
logic most likely to be wrong — the two receipt locations and the `tools[]`/`tool` fallback.
When `KURAMA_TUI_PROBE=1` is set, the script prints one tab-separated line per detected target
(`scope`, `path`, `comma-joined tools`, `version`) and exits 0 before touching gum or the
banner. That is the only new environment variable, and it is documented next to
`KURAMA_NO_BANNER`.

This keeps the seam honest: the test exercises the same code path the TUI uses, not a copy.

## Testing

New cases in `scripts/install_test.sh`, all driving `KURAMA_TUI_PROBE=1`:

- a fresh project-scope install in a scratch repo is detected as `project` with its tools and
  version
- a v6-style receipt (`tools[]` removed) still reports its single tool
- a directory with no receipt produces no output and exit 0
- global detection finds a receipt in a sandboxed `HOME`

## Out of scope

- The global `kurama` command. Still unresolved: `setup.sh` copies skills from `$REPO_DIR`, so
  a PATH-installed command needs to know where the checkout is.
- Any change to `setup.sh`, `update.sh`, `doctor.sh` or `uninstall.sh`.
- Uninstall as a TUI action. It is destructive and `uninstall.sh` needs stdin fed for its
  confirmation; adding it to a menu deserves its own decision.
