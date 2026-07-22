# Hooks — from prose to mechanism

Agent Teams Lite is a set of Markdown instructions. Most of its guarantees are
*prose*: "the orchestrator delegates, it does not edit code"; "never archive a
change that failed verification". Prose depends on the model reading it, keeping it
in context, and choosing to obey it. Under compaction, a long session, or an eager
model, prose can be forgotten.

**Hooks convert the two hardest structural rules into mechanisms.** A hook is a
deterministic script the harness runs at a defined moment; its exit code decides
whether an action proceeds. The model cannot forget a hook, cannot argue with it,
and cannot be talked out of it. Where the official Claude Code skills guidance says
"use hooks to enforce behavior deterministically", this is that layer for SDD.

The shipped hooks live in
[`examples/claude-code/hooks/`](../examples/claude-code/hooks/) with a
[README](../examples/claude-code/hooks/README.md) covering installation and the
exact settings snippet.

## The two gates

### 1. Orchestrator write guard (delegate-only)

The orchestrator is a coordinator. The delegation rules in every orchestrator
example say it must hand code changes to sub-agents. The write guard makes that
structural: a `PreToolUse` hook on `Edit`/`Write`/`MultiEdit` blocks the
**main-thread** orchestrator from writing repository code **while an SDD cycle is
active**, and only then. It exempts the paths the orchestrator legitimately writes
— `.atl/` (harness state) and `openspec/` (SDD artifacts) — and it is invisible
during ordinary non-SDD work, because it fires only when active-cycle state exists.

"Active cycle" is detected from persisted state, not from the model's belief:
an `openspec/changes/<name>/state.yaml` outside `archive/`, or a
`.atl/sdd/<name>/state.md` without an `archive-report.md`. The moment a change is
archived, the guard steps aside.

### 2. Archive gate (no PASS, no archive)

`sdd-archive` Step 0 says: never archive a change whose verification report is
missing or whose verdict is `FAIL`. That is the single most consequential gate in
the pipeline — archiving merges delta specs into the source of truth, so archiving
broken work corrupts the baseline. The archive gate mirrors Step 0 mechanically: it
reads the persisted `verify-report.md`, extracts the `### Verdict`, and refuses the
archive unless the verdict is `PASS` or `PASS WITH WARNINGS`. It fails **closed** —
a missing report or an unfilled template verdict counts as "not passing".

**Content binding — the "trust the verdict blindly" gap is now closed.** A verdict
gate on its own has a hole: it trusts the `PASS` without checking whether the code is
still the code that earned it. Nothing stopped someone from passing verification and
then editing a file before archiving — the stale `PASS` would sail through. The gap is
now closed by binding the receipt to the tree. `sdd-verify` (Step 6b) stamps a
`Tree-Hash` in the report's **Content Binding** section: the hash of the reviewed tree,
computed over a *throwaway* git index (`GIT_INDEX_FILE` points at a temp file, so the
real index is never touched) with the `openspec/` artifact store and `.atl/` harness
state excluded. Step 0 of `sdd-archive` — and the `archive-gate.sh` hook — recompute
that hash with the **identical** procedure and refuse the archive when it no longer
matches: the tree changed after verification, so the receipt is **STALE** and
`sdd-verify` must be re-run. The two exclusions are what make this stable rather than
noisy: writing the verify report and moving the change folder during archive are
bookkeeping, not code, so they never trip the check, and committing unchanged content
leaves the hash identical to HEAD's tree. The recomputation reuses the *same* receipt —
it never re-runs tests and never launches a reviewer. It applies whenever the report
carries a `Tree-Hash` on a git checkout; a legacy report without the line, or a non-git
tree, falls back to the verdict gate alone.

The documented escape hatch is preserved exactly as the skill defines it:
`ATL_ARCHIVE_OVERRIDE=1` opens the gate — **both** the verify-PASS check and the
content-binding (stale-receipt) check — but the override reason must still be recorded
verbatim in the archive report. The script opens the gate; it never records the
justification for you.

## Why mechanism *and* prose

The hooks do **not** replace the skills — they backstop two of them. The skill text
still explains *why* to delegate and *why* verification gates the archive; the hook
guarantees the *what* even if the *why* fell out of context. This mirrors how the
harness treats persistence: the contract is prose, but `.atl/` fallback files are
the mechanism that survives compaction.

Keep the split in mind when reasoning about coverage:

- Hooks enforce the **letter**: structural, binary, cheap to check
  (is a write to code happening mid-cycle? does the verdict say PASS?).
- Reviews and `sdd-verify` enforce the **spirit**: is the code correct, is the
  design sound, is the PASS verdict backed by real behavioral evidence? No hook can
  answer those; that is the reviewer's and the verifier's job.

A delegated sub-agent can still write weak code, and a shallow test suite can still
produce a PASS. The hooks close the two failure modes that are *purely structural*
— the orchestrator taking a shortcut, and an unverified archive — and leave the
judgement calls to the parts of the system designed to make them.

## Per-harness applicability

Hooks are a platform capability, so how far these gates reach depends on the harness.

| Harness | Native hook support | How the gates apply |
|---------|---------------------|---------------------|
| **Claude Code** | Yes — `PreToolUse` (and other events) via `settings.json`. | Ships here. Wire `hooks.json`; both gates run automatically. |
| **Gemini CLI** | Yes — hooks via extensions. | Port the two scripts as extension hooks on the equivalent pre-tool event; the script logic is harness-agnostic (it reads a JSON payload and gates by exit code). |
| **OpenCode** | Partial — plugin lifecycle, not a generic pre-tool gate. | The delegate-only rule is already structural (the orchestrator agent has no write tools in `opencode.single.json`); the archive gate can run as `archive-gate.sh <change>` from a command wrapper. |
| **Codex CLI / VS Code Copilot / Cursor / Antigravity** | No general-purpose tool-gate hook today. | Run the gates **manually / in CI**: `archive-gate.sh <change>` before closing a change, and the write guard's spirit stays prose (the orchestrator instructions). |

Because the scripts gate purely by **stdin JSON in, exit code out**, they are not
Claude-Code-specific: any harness that can run a command before a tool call, or any
CI step, can reuse them unchanged. On harnesses without a native pre-tool hook, the
same rules remain enforced the original way — by the orchestrator instructions and
by human/CI review — which is the fallback the whole framework is designed around.

## Limits worth stating plainly

- **Main-thread scope.** The write guard targets the orchestrator's own tool calls.
  Sub-agents run in their own context; blocking their writes would defeat the point
  (they are how code gets written). See
  [`examples/claude-code/hooks/README.md`](../examples/claude-code/hooks/README.md)
  for the `ATL_GUARD_BYPASS` / `ATL_ORCHESTRATOR_GUARD` escape hatches if a build
  propagates the hook into sub-agent contexts.
- **Verdict parsing plus tree binding, not re-verification.** The archive gate now
  verifies that the *tree* is unchanged since verification (the content binding above),
  which closes the "edited after PASS" hole. What it still does not do is re-run the
  tests: it trusts that the persisted verdict correctly describes *that* tree. If the
  verify report reached a wrong conclusion about code that has not since changed, the
  gate is wrong with it — which is why `sdd-verify` must produce the verdict from real
  execution. Binding proves *what* was reviewed; only `sdd-verify` proves it *works*.
- **Structural only.** Neither hook inspects code quality. They are guardrails, not
  reviewers.
