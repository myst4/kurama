---
name: issue-creation
description: >
  File a GitHub issue in the repository you are working in — the entry point of the
  kanban board and the first step of the issue-first flow. Discovers the host repo's
  own templates and labels before it writes a command, and degrades cleanly when the
  repo has neither.
  Trigger: When creating a GitHub issue, reporting a bug in THIS project, requesting a
  feature, or opening a card on the board.
  NOT for reporting a failure in Kurama itself — that is `skills/kurama-report`.
license: MIT
metadata:
  author: kurama
  version: "1.0"
---

## Scope — which repository this skill writes to

This skill files issues in **the repository you are standing in**. It never passes
`--repo`: `gh` resolves the command against the current checkout's remote, and that is
exactly the intent.

| The failure is in… | Skill |
|---|---|
| The project you are working on — its code, its build, its tests | **this skill** |
| Kurama itself — the installer, a hook, a phase envelope, a skill that contradicts itself | [`skills/kurama-report`](../kurama-report/SKILL.md) |

Getting this wrong is not cosmetic. A Kurama defect filed here lands in the team's own
backlog, where nobody can fix it; a project defect filed upstream leaks the project's
details into a public repo. Classify **before** you compose anything.

> Contributing to Kurama itself? Kurama's own issue-first rules — its approval gate and
> its label taxonomy — live in [`CONTRIBUTING.md`](../../CONTRIBUTING.md). They are that
> repository's house rules; this skill never ships them into the project you installed
> Kurama into.

---

## Workflow

```
1. Search the host repo for a duplicate
2. Discover what the host repo actually has (templates, labels)
3. Compose the issue against what it has
4. Create it with a command the repo will accept
5. If kanban.enabled → add to the board (Backlog) and assign
6. The branch that follows carries this issue's number: type/{issue}-{slug}
```

---

## 1. Search first

```bash
gh issue list --search "keyword" --state all --limit 20
```

A duplicate is a comment on the existing issue, not a new one. Say which issue you
matched and why before you decide it is not a duplicate.

---

## 2. Discover the host repo (do this before writing any `gh` command)

Nothing about this repository is assumed. Two probes, both read-only:

```bash
# Issue forms this repo ships (empty or an error = it has none)
gh api "repos/{owner}/{repo}/contents/.github/ISSUE_TEMPLATE" --jq '.[].name' 2>/dev/null

# Labels this repo actually defines
gh label list --limit 200 2>/dev/null | awk -F'\t' '{ print $1 }'
```

`{owner}/{repo}` are `gh`'s own placeholders — it substitutes the current repo, so the
line is copy-pasteable as written. In a checkout you may read the directory directly
instead of the API call.

**Why this is mandatory:** `gh issue create --label` fails the whole command when even
one named label does not exist in the repo — you do not get an issue with fewer labels,
you get no issue at all. And `--template` matches an issue form's `name:` field, so it
fails on a repo that ships no forms. Both are silent-until-you-run-it failures that a
copied command from another project reproduces every time.

---

## 3. Degrade cleanly

| What the probes found | What to run |
|---|---|
| Forms present, and you can prompt the user | `gh issue create --template "<the form's name: field>" --title "..."` — it prompts for the remaining fields |
| Forms present, non-interactive run | `--body` with the form's own headings as `###` sections, plus `--label` for the labels the form would have auto-applied (`--template` and `--body` are mutually exclusive in `gh`, and skipping the form also skips its auto-labels) |
| No forms | `--body` with the generic sections below |
| A label you wanted is absent | Drop it. Never create a label to satisfy a command, and never guess at a taxonomy the repo does not use |
| No labels at all | File with no `--label` — a labelled issue is a nicety, a filed issue is the point |

### Generic body (repo with no issue forms)

```bash
gh issue create --title "fix(scope): one-line summary" --body "
## Summary
What is broken, in one or two sentences.

## Steps to Reproduce
1. …
2. …

## Expected
What should have happened.

## Actual
What happened instead, including the exact error text.

## Environment
OS, runtime/toolchain version, and anything else needed to reproduce.
"
```

Title convention: **conventional-commit prefix + scope + imperative summary**
(`fix(auth): session cookie is dropped on redirect`). It costs nothing, and it makes the
issue title reusable as the commit subject and the PR title.

---

## 4. After it exists

- Report the issue URL back. That URL is the handle every later step uses.
- The branch that follows carries **this issue's** number: `type/{issue}-{slug}` —
  see [`skills/branch-pr`](../branch-pr/SKILL.md) → *Branch Naming*.
- The PR that follows links it (`Closes #N`, or `Refs #N` when the base is not the
  default branch).

---

## Kanban Integration (conditional)

Only when the project has **`kanban.enabled: true`** (settings from the
`sdd-init/{project}` bundle or `openspec/config.yaml`; see `skills/kanban-github/SKILL.md`).
With Kanban inactive, this section is a **no-op** — issue creation behaves exactly as
above, zero extra commands, zero behavior change.

When Kanban IS active, append **two `gh` commands** after the issue is created — add the
new issue to the configured GitHub Project (it enters at **Backlog**) and assign it. The
default assignee is `@me` (the issue goes to whoever created it); `kanban.user`, when set,
overrides it with a fixed login. Use the cached `kanban.*` values (`project_number`,
`owner`, and `user` when overriding):

```bash
# 1. Add the new issue to the configured GitHub Project → lands at Backlog
gh project item-add {project_number} --owner {owner} --url {issue-url}

# 2. Assign the issue — @me by default, or the kanban.user override
gh issue edit {issue-number} --add-assignee {user-or-@me}
```

- These are **bookkeeping**: if either command fails, record a WARNING and CONTINUE —
  a board that could not be updated never blocks issue creation (see `skills/kanban-github/SKILL.md`
  → *Failure Semantics*).
- The card enters the board at **Backlog** (the board's initial Status). If a board has no
  "set Status on add" workflow, the explicit Backlog set is the `kanban-github` skill's *issue
  created* transition, not part of this two-command step.

---

## Failure Semantics

| Situation | Behavior |
|---|---|
| `gh` missing or unauthenticated | Print the composed title and body for the user to paste, name the fix (`gh auth login`), and STOP — do not silently skip the issue |
| `gh issue create` rejects a label | Re-run without that label; report which label the repo does not define |
| Repository has issues disabled | Report it and stop. There is nothing to degrade to |
| Board command fails | WARNING, continue — the issue exists and that is what matters |
