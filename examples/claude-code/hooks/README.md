# Claude Code Hooks — deterministic SDD gates

These hooks turn two of Agent Teams Lite's prose rules into **mechanisms** Claude
Code enforces on its own, instead of relying on the model to obey instructions:

| File | Hook | Enforces |
|------|------|----------|
| `orchestrator-write-guard.sh` | `PreToolUse` on `Edit`/`Write`/`MultiEdit` | While an SDD cycle is active, the orchestrator (main thread) must **delegate** code changes — it may not edit repository code directly. |
| `archive-gate.sh` | `PreToolUse` on `Task`/`Skill` (or run standalone) | `sdd-archive` is refused unless the persisted verification report records a **PASS** (or **PASS WITH WARNINGS**) verdict **and** its **Content Binding** receipt still matches the live tree — a mechanical mirror of `sdd-archive` Step 0. |
| `hooks.json` | — | Ready-to-merge settings snippet wiring both scripts. |

Both scripts are POSIX / bash 3.2 (BSD) portable, `shellcheck`-clean, and use `jq`
only when it is present (a `grep`/`sed` fallback runs otherwise).

## Installation

1. Copy the scripts into your project's Claude Code hooks directory and make them
   executable:

   ```sh
   mkdir -p .claude/hooks
   cp examples/claude-code/hooks/orchestrator-write-guard.sh .claude/hooks/
   cp examples/claude-code/hooks/archive-gate.sh            .claude/hooks/
   chmod +x .claude/hooks/*.sh
   ```

2. Merge the `hooks` block from `hooks.json` into your `.claude/settings.json`
   (project) or `~/.claude/settings.json` (user). If a `hooks` key already exists,
   append these entries to the matching event arrays rather than replacing them:

   ```json
   {
     "hooks": {
       "PreToolUse": [
         {
           "matcher": "Edit|Write|MultiEdit",
           "hooks": [
             { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/orchestrator-write-guard.sh" }
           ]
         },
         {
           "matcher": "Task|Skill",
           "hooks": [
             { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/archive-gate.sh" }
           ]
         }
       ]
     }
   }
   ```

   Claude Code expands `$CLAUDE_PROJECT_DIR` to the project root before running the
   command.

3. Restart the Claude Code session (or reload settings) so the hooks register.

## What each hook does

### orchestrator-write-guard.sh

A `PreToolUse` hook receives the tool call as JSON on stdin and decides via exit
code: `0` allows the call, `2` blocks it and feeds stderr back to the model.

The guard allows the write when **any** of these holds:

- **No SDD cycle is active** — normal, non-SDD work is never blocked.
- The target path is under **`.atl/`** (harness state) or **`openspec/`** (SDD
  artifacts) — the orchestrator must still be able to persist state and artifacts.
- The target path is **outside the project root** — not repository code.

It blocks (`exit 2`) only when an SDD cycle is active **and** the orchestrator is
about to write repository code directly. The message tells it to delegate (e.g.
launch `sdd-apply` via the `Task` tool).

**Active-cycle detection** (mechanical, no model involvement):

- `openspec` mode → a change directory under `openspec/changes/<name>/` (never
  `openspec/changes/archive/…`) that still holds a `state.yaml`.
- `engram` filesystem fallback → a `.atl/sdd/<name>/` directory with `state.md`
  and **no** `archive-report.md` (archiving writes that report).

An archived change (moved under `changes/archive/`, or with an `archive-report.md`)
is not active, so writes flow normally again once the cycle closes.

### archive-gate.sh

Refuses to archive a change whose verification did not pass, or whose verified tree
was edited afterward — the same gate `sdd-archive` Step 0 describes, made deterministic.

- **CLI:** `archive-gate.sh <change-name>` → exit `0` on PASS / PASS WITH WARNINGS with
  a fresh binding, exit `2` when the report is missing, the verdict is FAIL, no PASS is
  found, **or the Content Binding receipt is stale**.
- **Hook:** wired on `Task`/`Skill`, it reads the payload and only gates launches
  that reference `sdd-archive`; every other `Task`/`Skill` call passes through
  (`exit 0`). It auto-detects the change from the active change directory (or takes
  `ATL_CHANGE`).

It locates the verify report at `openspec/changes/<name>/verify-report.md` or
`.atl/sdd/<name>/verify-report.md`, reads the `### Verdict` line, and gates on it.
It fails **closed**: an unfilled template verdict or an undeterminable verdict is
treated as "not passing".

**Content binding (closes the "trust the verdict blindly" gap).** A PASS is only
meaningful for the exact code it was computed against. `sdd-verify` (Step 6b) stamps a
`Tree-Hash` in the report's **Content Binding** section — the hash of the reviewed tree,
computed over a throwaway git index (`GIT_INDEX_FILE` points at a temp file, so the real
index is never touched), excluding the `openspec/` artifact store and `.atl/` harness
state. The gate recomputes that hash with the **identical** procedure and refuses the
archive when it no longer matches — the working tree changed after verification, so the
receipt is **STALE** and `sdd-verify` must be re-run. Because the two churny paths are
excluded, writing the verify report or moving the change folder during archive does *not*
trip the check, and committing unchanged content leaves the hash identical to HEAD's tree
— only a real code change invalidates it. The check runs **only** when the report carries
a `Tree-Hash` and the tree is a git checkout; a legacy report without the line, or a
non-git tree, falls back to the verdict gate alone. It never re-runs tests and never
launches a reviewer — it reuses the same receipt.

## Environment overrides

| Variable | Effect |
|----------|--------|
| `ATL_ORCHESTRATOR_GUARD=0` | Disable the write guard entirely. |
| `ATL_GUARD_BYPASS=1` | Allow a single write past the guard (per-call escape hatch). |
| `ATL_ARCHIVE_OVERRIDE=1` | Bypass the archive gate — **both** the verify-PASS gate and the content-binding (stale-receipt) check. Mirrors `sdd-archive` Step 0's user-authorized override — the **reason must still be recorded** in the archive report; the script only opens the gate. |
| `ATL_CHANGE=<name>` | Tell the archive gate which change to check (otherwise auto-detected). |
| `CLAUDE_PROJECT_DIR` | Project root; set by Claude Code, falls back to the payload `cwd`, then `$PWD`. |

## Main-thread scope and limitations

Sub-agents launched via the `Task` tool run in their **own context**. The write
guard is intended to stop the **main-thread orchestrator** from bypassing
delegation — the delegated writer (e.g. `sdd-apply`) is exactly how code is meant
to reach disk. If a given Claude Code build also runs this `PreToolUse` hook inside
a sub-agent's context, that sub-agent would be blocked from writing code; in that
case scope the hook to the orchestrator session, or set `ATL_GUARD_BYPASS=1` /
`ATL_ORCHESTRATOR_GUARD=0` for the writer.

These hooks enforce the **letter** of the rules (don't hand-edit code mid-cycle;
don't archive without a PASS). They do not judge the **spirit** — a delegated
sub-agent can still write poor code, and a PASS verdict can still be shallow. Code
review and `sdd-verify` remain the substantive quality gates; the hooks only make
the two hard structural rules impossible to forget.

## Disabling

- Remove the relevant entry from `settings.json`, **or**
- Set `ATL_ORCHESTRATOR_GUARD=0` (write guard) in the environment, **or**
- Delete the script from `.claude/hooks/` (Claude Code then skips the missing
  command).

See [`docs/hooks.md`](../../../docs/hooks.md) for the prose-to-mechanism rationale
and per-harness applicability.
