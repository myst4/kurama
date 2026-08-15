# Hooks — from prose to mechanism

Kurama is a set of Markdown instructions. Most of its guarantees are
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
— `.kurama/` (harness state) and `openspec/` (SDD artifacts) — and it is invisible
during ordinary non-SDD work, because it fires only when active-cycle state exists.

"Active cycle" is detected from persisted state, not from the model's belief:
an `openspec/changes/<name>/state.yaml` outside `archive/`, or a
`.kurama/sdd/<name>/state.md` without an `archive-report.md`. The moment a change is
archived, the guard steps aside.

Both markers are on disk in **every** artifact-store mode. `.kurama/sdd/<name>/state.md`
used to appear only when Engram was unreachable, so in the flagship configuration
(Claude Code + Engram) state lived in Engram alone, no filesystem marker existed, and this
guard silently never fired. The persistence contract now makes
`.kurama/sdd/<change>/{state,verify-report,archive-report}.md` **mode-independent cycle
markers** — harness infrastructure written in every mode, like `.kurama/skill-registry.md`
— so both hooks see the same three files whichever store the project chose. `sdd-archive`
writing `archive-report.md` is what retires the cycle; nothing else clears the guard.

### 2. Archive gate (no PASS, no archive)

`sdd-archive` Step 0 says: never archive a change whose verification report is
missing or whose verdict is `FAIL`. That is the single most consequential gate in
the pipeline — archiving merges delta specs into the source of truth, so archiving
broken work corrupts the baseline. The archive gate mirrors Step 0 mechanically: it
reads the persisted `verify-report.md`, extracts the `### Verdict`, and refuses the
archive unless the verdict is `PASS` or `PASS WITH WARNINGS`. It fails **closed** —
a missing report or an unfilled template verdict counts as "not passing".

Failing closed only works if a legitimately verified change can actually open the gate.
The gate reads two paths and no others: `openspec/changes/<change>/verify-report.md` and
`.kurama/sdd/<change>/verify-report.md`. It cannot query Engram. So `sdd-verify` writes the
**complete** report to `.kurama/sdd/<change>/verify-report.md` in **every** mode — including
`engram`, where the Engram save still happens and the disk copy is an additional mechanical
mirror. Before that rule existed, the flagship configuration had the report in Engram only,
the gate found nothing, and it blocked every legitimate archive while pointing at
`KURAMA_ARCHIVE_OVERRIDE=1` — a fail-closed gate that fails on the happy path teaches the
model to disable it. A stub or summary is not enough: the gate parses the `### Verdict` line
and the Content Binding `Tree-Hash:` line out of that exact file.

**Content binding — the "trust the verdict blindly" gap is now closed.** A verdict
gate on its own has a hole: it trusts the `PASS` without checking whether the code is
still the code that earned it. Nothing stopped someone from passing verification and
then editing a file before archiving — the stale `PASS` would sail through. The gap is
now closed by binding the receipt to the tree. `sdd-verify` (Step 6b) stamps a
`Tree-Hash` in the report's **Content Binding** section: the hash of the reviewed tree,
computed over a *throwaway* git index (`GIT_INDEX_FILE` points at a temp file, so the
real index is never touched) with the `openspec/` artifact store and `.kurama/` harness
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
`KURAMA_ARCHIVE_OVERRIDE=1` opens the gate — **both** the verify-PASS check and the
content-binding (stale-receipt) check — but the override reason must still be recorded
verbatim in the archive report. The script opens the gate; it never records the
justification for you.

## Why mechanism *and* prose

The hooks do **not** replace the skills — they backstop two of them. The skill text
still explains *why* to delegate and *why* verification gates the archive; the hook
guarantees the *what* even if the *why* fell out of context. This mirrors how the
harness treats persistence: the contract is prose, but `.kurama/` fallback files are
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
| **OpenCode** | Partial — plugin lifecycle, not a generic pre-tool gate. | The delegate-only rule stays **prose** here: the shipped `opencode.single.json` grants the orchestrator `write`, `edit` and `bash` (all `true`), so nothing mechanically stops it from editing code — only the orchestrator instructions do. The archive gate can run as `archive-gate.sh <change>` from a command wrapper. |
| **Codex CLI / Pi / omp** | No general-purpose tool-gate hook today. | Run the gates **manually / in CI**: `archive-gate.sh <change>` before closing a change, and the write guard's spirit stays prose (the orchestrator instructions). |

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
  for the `KURAMA_GUARD_BYPASS` / `KURAMA_ORCHESTRATOR_GUARD` escape hatches if a build
  propagates the hook into sub-agent contexts.
- **Verdict parsing plus tree binding, not re-verification.** The archive gate now
  verifies that the *tree* is unchanged since verification (the content binding above),
  which closes the "edited after PASS" hole. What it still does not do is re-run the
  tests: it trusts that the persisted verdict correctly describes *that* tree. If the
  verify report reached a wrong conclusion about code that has not since changed, the
  gate is wrong with it — which is why `sdd-verify` must produce the verdict from real
  execution. Binding proves *what* was reviewed; only `sdd-verify` proves it *works*.
- **The write guard only sees the file-writing tools it is wired to.** It is a
  `PreToolUse` hook on `Edit`/`Write`/`MultiEdit`, and it identifies its target through the
  payload's `file_path` field. A write performed through **`Bash`** — `cat > file`,
  `sed -i`, `tee`, `>>`, `git checkout -- .`, a script that edits files — carries no
  `file_path`, is not matched by the hook's tool filter, and passes untouched. Wiring the
  guard to `Bash` as well is not a fix: the target of an arbitrary shell command is not
  mechanically knowable, so the hook would have to either block all shell use mid-cycle or
  guess. The delegate-only rule therefore remains **prose for the `Bash` path** and mechanism
  for the editing tools. If you see the orchestrator reaching for `cat >` on repository code
  during a cycle, that is the rule being evaded, not a gap in the contract.
- **The override env vars are inside the model's reach.** `KURAMA_ARCHIVE_OVERRIDE=1`,
  `KURAMA_GUARD_BYPASS=1`, and `KURAMA_ORCHESTRATOR_GUARD=0` are read from the hook's
  environment, and an agent that can run shell commands can export them itself. They are
  escape hatches for a **human**, and the skills say never to self-authorize one — but that
  restraint is prose, exactly like the rules the hooks exist to backstop. Treat these gates as
  protection against forgetting and drift, not against a model that decides to route around
  them. If it matters for your project, keep the variables out of the agent's environment,
  or gate archives in CI where the agent cannot set them.
- **An abandoned cycle has to be retired by a human.** `archive-report.md` is written
  only by a *successful* `sdd-archive`, so a change you start and then walk away from
  leaves its `state.md` behind and the write guard goes on treating the cycle as active
  — indefinitely. The skills forbid the **model** from deleting `.kurama/sdd/<change>/`
  or its `state.md`: that prohibition exists so an agent cannot quietly clear its own
  gate, and — like the override variables above — it does not bind you. Two ways out:
  - **Finish it**: run `/sdd-verify`, then `/sdd-archive`. The normal path; it merges the
    delta spec into the source of truth and writes `archive-report.md`, which retires the
    cycle for both hooks.
  - **Drop it**: delete `.kurama/sdd/<change>/` yourself (plus
    `openspec/changes/<change>/` in `openspec`/`hybrid` mode). `.kurama/` is gitignored
    harness state, so nothing tracked is lost — but you also lose that change's artifacts,
    so prefer finishing when the work still matters.

  Either way the guard steps aside as soon as no `state.md`-without-`archive-report.md`
  pair remains. If you are not sure which change is holding the gate,
  `scripts/sdd-status.sh` lists the cycles that are currently active.
- **Structural only.** Neither hook inspects code quality. They are guardrails, not
  reviewers.
