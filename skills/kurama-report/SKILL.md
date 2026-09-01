---
name: kurama-report
description: >
  Report a failure in KURAMA ITSELF upstream to myst4/kurama — a broken installer step, a
  hook that blocks legitimate work, a skill that contradicts itself, a phase envelope that
  does not match its contract. Searches for an existing report first, collects a sanitized
  reproduction that carries nothing from the user's project, and ALWAYS asks before filing.
  Trigger: When the user says "report this to kurama", "reportá esto a kurama", "this is a
  Kurama bug", "file this upstream", "the installer failed", "the hook blocked me", "this
  skill contradicts itself", or when a phase fails inside Kurama's own machinery rather
  than in the project's code.
  NOT for filing issues in the user's own repository — that is `skills/issue-creation`.
license: MIT
metadata:
  author: kurama
  version: "1.0"
---

## What This Skill Is

The one path by which a Kurama failure reaches the people who can fix it. Every other
issue-filing route in this harness writes into the repository the user is standing in;
this one writes into **`myst4/kurama`**, explicitly, with `--repo` on every command.

It is **approval-gated without exception**. Filing an issue in a third-party repository
from someone's machine is an outward-facing write: it is public, it is attributed to the
user's GitHub account, and it cannot be fully undone. `execution_mode: auto` does not
apply here — auto governs Kurama's own phase transitions, not writes into other people's
repositories.

---

## Gate 1 — Is this actually Kurama's failure?

Answer this before collecting anything. The classes below are Kurama's; everything else
belongs to the project and goes to [`skills/issue-creation`](../issue-creation/SKILL.md).

| Class | It is Kurama's when… | It is NOT when… |
|---|---|---|
| **Installer** | `setup.sh` / `install.sh` / `update.sh` / `uninstall.sh` / `doctor.sh` exits non-zero, writes a partial tree, or reports success over a broken install | The user's own shell, `git`, or `gh` is missing or unauthenticated — that is an environment prerequisite the script named correctly |
| **Hook** | A shipped hook blocks a write or a launch that its own documented exemptions allow, or fires on the wrong event | A hook the user wrote, or a block the hook explains and the user disagrees with |
| **Skill contract** | Two shipped skills state contradictory rules, a skill names a file or command that does not exist, or a skill's instructions cannot be executed as written | A skill's advice did not fit the project — that is a judgment disagreement, not a defect |
| **Phase envelope** | A phase's declared inputs/outputs do not match what the pipeline passes or expects, or a sub-agent result contract is unsatisfiable | The phase ran correctly and produced a result the user did not like |

Two disqualifiers that override the table:

- **Reproduce it first.** A failure you cannot reproduce is a symptom report, not a bug
  report. Say so and ask the user for the exact invocation instead of guessing.
- **Check the version.** Read the receipt (Gate 3). If the install is behind the current
  release, say which version the user is on before filing — the fix may already exist.

If it is not Kurama's, STOP and route to `skills/issue-creation`. Do not file "just in
case": a misrouted report costs a maintainer a triage cycle and tells the user nothing.

---

## Gate 2 — Search before you file

```bash
gh issue list --repo myst4/kurama --state all --limit 20 --search "<distinctive error text>"
gh issue list --repo myst4/kurama --state all --limit 20 --search "<script or skill name>"
```

Search on the **error text**, not on your description of it — the same defect is
described five different ways and emits one string.

| Result | What to do |
|---|---|
| An open issue matches | Do not file. Report its URL to the user, and offer to add a comment carrying the sanitized reproduction (same approval gate as filing) |
| A closed issue matches | Report it with its closing commit. If the user is on a version that already contains the fix, that is the finding — say so instead of filing |
| Nothing matches | Continue to Gate 3 |

---

## Gate 3 — Collect the reproduction (sanitized at collection time, not afterwards)

Sanitizing after the fact means the unredacted version existed in a draft the user may
approve without re-reading. Collect only what is allowed in the first place.

### Read the install receipt

```bash
# Global install (claude-code shown; substitute the harness's skills dir)
cat ~/.claude/skills/.kurama-install-manifest.json
# Project-scope install
cat <repo>/.claude/skills/.kurama-install-manifest.json
```

Take exactly four fields: `version`, `commit` (absent on a git-less install — say
"unknown"), `tool` (the harness slug), and `scope` (`global` or `project`). Nothing else
from the receipt travels: `files[]` and `settings[]` are full paths inside the user's
machine and repository.

### What may travel, and what may not

| Include | Never include |
|---|---|
| Kurama version + commit from the receipt | Any path outside the Kurama install — the user's repo root, project file names, `$HOME` spelled out (write `~`) |
| Harness slug (`claude-code`, `opencode`, `codex`, `pi`, `omp`) and scope | Source code, specs, or diffs from the user's project |
| OS family and shell | Tokens, keys, `.env` values, `gh` auth output, remote URLs, private org or repo names |
| The **shape** of the command, user-specific arguments replaced by placeholders — `setup.sh --agent <harness> --scope project --path <repo>` | The literal invocation with the user's real path, org, or project name in it |
| Kurama's own paths: `skills/…`, `scripts/…`, `examples/…`, `.kurama/…` | Issue titles, branch names, or card contents from the user's board |
| The exact error text emitted by a Kurama script, hook, or skill — with any absorbed user path replaced by `<path>` | Whole log files. Paste the failing lines and the few around them, nothing more |

Redaction is mechanical: every occurrence of the user's repo root becomes `<repo>`, every
`$HOME` becomes `~`, every project file name becomes `<file>`. If a line cannot be
redacted without destroying its meaning, drop the line and describe it instead.

**The privacy rule is this skill's, not the reporter's judgment.** When you are unsure
whether a fragment belongs to Kurama or to the project, it belongs to the project: leave
it out.

---

## Gate 4 — Ask the user (blocking, always)

Show the user the **complete** issue — title, every body section, and the labels — then
ask one question:

> This will open a public issue at `myst4/kurama` under your GitHub account. File it?

- Nothing is created before an explicit yes.
- "Yes" to filing is not "yes" to a body the user has not seen. Show it first, in full.
- If the user declines, hand them the composed body to file themselves and stop. A
  declined report is a completed run, not a failure.
- If the user edits the body, re-check it against the *never include* column before
  filing — an edit can reintroduce exactly what was redacted.

---

## Gate 5 — File it

The upstream repository ships an issue form at `.github/ISSUE_TEMPLATE/bug_report.yml`.
`--template` and `--body` are mutually exclusive in `gh`, and a non-interactive run needs
`--body` — so match the form's headings by hand and add the labels the form would have
applied.

```bash
gh issue create --repo myst4/kurama \
  --title "fix(<area>): one-line summary of the failure" \
  --label "bug,type:bug,status:needs-review" \
  --body "
### Pre-flight Checks
- [x] I have searched existing issues and this is not a duplicate
- [x] I understand this issue needs status:approved before a PR can be opened

### Bug Description
<what Kurama did wrong, in one or two sentences>

### Steps to Reproduce
1. <the command shape, placeholders in place of user-specific arguments>
2. …

### Expected Behavior
<what the shipped contract says should happen, citing the skill or script>

### Actual Behavior
<what happened, with the exact error text, redacted>

### Operating System
<macOS | Linux (Ubuntu/Debian) | Linux (Arch/Manjaro) | Linux (Fedora/RHEL) | Linux (Other)>

### Agent / Client
<Claude Code | OpenCode | Codex | Pi | omp | Other>

### Shell
<bash | zsh | fish | Other>

### Relevant Logs
\`\`\`
<the failing lines only, redacted>
\`\`\`

### Additional Context
Kurama version: <version> (commit <commit>)
Install scope: <global | project>
"
```

**Labels are not negotiable in one direction: never set `status:approved`.** That label
is the maintainer's signal that an issue is accepted for implementation, and it is the
precondition Kurama's own contribution flow checks before a PR may be opened. A reporter
that applies it approves their own issue and defeats the gate. File with
`status:needs-review` and let a maintainer decide.

Then report the URL back to the user. That URL is the whole deliverable — a report the
user cannot find again did not happen.

---

## Failure Semantics

| Situation | Behavior |
|---|---|
| `gh` missing or unauthenticated | Print the composed title and body and the URL `https://github.com/myst4/kurama/issues/new/choose`, name the fix (`gh auth login`), and stop |
| `gh issue create` rejects a label | Retry once with `--label "bug"` alone and say which label was rejected. Never retry by adding labels |
| The user declines | Hand over the composed body, stop, report "not filed" |
| The failure could not be reproduced | Do not file. Report what you tried and what you would need from the user |
| Anything at all fails here | The user's SDD cycle continues. Reporting a Kurama defect is never a blocker for the work in front of them |
