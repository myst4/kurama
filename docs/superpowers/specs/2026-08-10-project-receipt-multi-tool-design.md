# Project-scope receipt records every installed harness

Date: 2026-08-10
Status: approved, ready for implementation

## Problem

In `SCOPE=project`, `scoped_receipt_dir()` (`scripts/setup.sh:338`) returns `$TARGET_PATH`
for every agent, so all harnesses installed into one repo share a single receipt at
`<repo>/.kurama-install-manifest.json`. That is deliberate — `scripts/setup.sh:268` states
the intent: "The install receipt lives in RECEIPT_DIR: ... the repo root for project (O1),
so uninstall/update/doctor find one receipt."

But `finalize_receipt()` (`scripts/setup.sh:511-548`) writes that file with `>` and records
a single `"tool"`. Installing a second harness into the same repo silently discards
everything the first one recorded.

Reproduced on a scratch repo at v6.0.0:

```
setup.sh --agent claude-code --scope project --path $T   → "tool": "claude-code"
setup.sh --agent opencode    --scope project --path $T   → "tool": "opencode"
```

After the second install the repo still contains `CLAUDE.md` carrying a `BEGIN:kurama`
block, but `prompts[]` lists only `AGENTS.md`. Consequences:

- `uninstall.sh` never strips the kurama block from `CLAUDE.md` — it only walks the arrays.
- `update.sh` re-syncs one tool (`resync_target`, `scripts/update.sh:269-281`), so the other
  harness's files silently drift.
- `doctor.sh` reports the repo as a single-tool install.

Global scope is unaffected: every harness has its own skills directory
(`~/.claude/skills`, `~/.config/opencode/skills`, `~/.codex/skills`, `~/.pi/agent/skills`,
`$(omp_agent_base)/skills`), so each already gets its own receipt and the merge path never
triggers.

The trigger for fixing this now is the TUI. `scripts/setup-tui.sh` loops
`for a in $chosen` with one shared `--scope project --path`, so it is the first thing that
routinely produces multi-harness project installs — and the planned detect-and-update
pre-flight would read this receipt to decide what is installed.

## Design

### Receipt format

`finalize_receipt()` merges into an existing receipt instead of truncating it.

- New field `"tools": [...]` — the union of the tools already recorded and the one being
  installed, deduplicated, insertion-ordered.
- `"tool"` is kept, still the most recently installed harness. Receipts written by v6 and by
  the legacy `install.sh` (`scripts/install.sh:299-326`) keep parsing unchanged; consumers
  fall back to `[tool]` when `tools[]` is absent.
- `files`, `settings`, `pi_packages`, `engram_mcp`, `prompts`, `tui_plugins` become the
  deduplicated union of the previous receipt and the current install.
- Entries inherited from the previous receipt are carried over **only if the path still
  exists on disk**. Paths are resolved the same way the readers resolve them: absolute
  entries as-is, relative entries against `RECEIPT_DIR`. `pi_packages[]` holds
  `npm:pkg@ver` specs rather than paths and is unioned without an existence check.
- `version` and `commit` are always re-stamped from the current repo.

The existence filter is what keeps the union honest. Without it a receipt accumulates
entries forever and `check_receipt_files` (`scripts/doctor.sh:239-255`) reports them as
`MISSING`, which is a hard `bad`. With it, a receipt that accumulated junk repairs itself on
the next `setup.sh` run — no migration and no format version needed.

Files removed from a newer Kurama release are not a false-positive source: `setup.sh` copies
files in and never deletes ones that vanished from the source tree, so their entries stay
backed by a real file on disk. A file the user deleted by hand does disappear from the
receipt on the next install — but `doctor` flags that against the current install's own
freshly recorded list, which is the behavior that matters.

### Reader changes

`scripts/setup.sh` currently only writes manifests. It gains a flat JSON array reader,
copied from `manifest_json_array` (`scripts/doctor.sh:184-197`). The repo has no shared
library — `update.sh:43`, `doctor.sh:91` and `uninstall.sh:65` each carry a "mirrors
setup.sh so paths resolve identically" comment and a copy of the helpers. A fourth copy
follows that convention rather than fighting it; extracting a shared lib is a separate
concern and out of scope here.

> **Superseded (issue #37).** That separate concern was taken up: the copies were
> consolidated into **`scripts/lib/receipt.sh`**, which every script sources and guards
> at startup. The paragraph above describes the repo as it stood when this spec was
> approved — there is no fourth copy to add today, only the one definition.

`scripts/update.sh` — `resync_target()` reads `tools[]` (falling back to `[tool]`) and runs
one `bash "$SETUP_SCRIPT" --agent <slug>` per recorded tool instead of one overall. The
pre-sync hash snapshot, the changed-file report and the `.bak` pruning stay as they are and
cover the union of files. A tool whose slug fails `tool_to_slug` aborts that target, as
today.

`scripts/doctor.sh` — the target header reports every tool in `tools[]`.

In `check_receipt_files`, drift resolution currently calls `resolve_source "$rel" "$tool"`
with one tool. It tries each tool in the receipt. An earlier draft of this spec said "accepts
the first that resolves to an existing source file"; that rule is wrong and was corrected
during implementation. `examples/claude-code/agents/sdd-spec.md` and
`examples/pi/agents/sdd-spec.md` both exist and share a basename, so for a receipt recording
`["claude-code","pi"]` the first-existing rule misattributes the `.pi/agents/` file to
claude-code's source and reports a soft drift on a file that is perfectly in sync — a false
red in exactly the multi-harness install this change exists to support. The rule is therefore
content-preferred: accept the candidate the installed file actually matches, and fall back to
the first existing candidate so a genuinely drifted file still resolves and is still
reported. This weakens only one case — a file hand-edited into a byte-identical copy of
another recorded harness's source.

`check_markers` and `check_hooks` are widened the same way, for the same reason the header is.
`check_markers` resolved one prompt path from the single `tool`, so a claude-code + opencode
repo checked `AGENTS.md` and never looked at `CLAUDE.md`, which carries a `BEGIN:kurama` block
of its own. It now checks the prompt of every recorded tool, deduplicated by **resolved path**
rather than by tool: in project scope claude-code and codex both map to `CLAUDE.md` and
pi/opencode/omp collapse similarly, so a per-tool loop would print the same verdict twice for
the same file. The balanced-marker logic itself — the fix from PR #7 — is unchanged.
`check_hooks` early-returned unless the single `tool` was claude-code, so the same repo never
checked the hooks claude-code had actually installed; it now runs whenever `claude-code`
appears anywhere in the recorded list.

Measured on a two-harness project repo, `doctor.sh` at HEAD prints
`Diagnosing opencode (project)`, verifies markers in `AGENTS.md` only, skips the hooks check
entirely, and still reports "All checks passed — healthy" — a clean bill of health issued
without inspecting half the install.

`scripts/uninstall.sh` — no logic change. It already consumes the flat arrays, which now
arrive complete. This is exactly where the bug bites today.

### Testing

A new case in `scripts/install_test.sh` reproduces the scenario above: install two harnesses
into one project-scope repo, then assert that

- `tools[]` contains both slugs,
- `prompts[]` contains both `CLAUDE.md` and `AGENTS.md`,
- a subsequent `uninstall.sh --scope project` leaves no `BEGIN:kurama` block behind in
  either prompt file.

## Out of scope

- The TUI detect-and-update pre-flight — separate change, built on top of this one.
- Extracting the duplicated manifest/path helpers into a shared library.
- Any change to global-scope receipts or to the legacy `install.sh` writer.
