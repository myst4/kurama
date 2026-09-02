---
name: branch-pr
description: >
  PR creation workflow for Kurama following the issue-first enforcement system.
  Trigger: When creating a pull request, opening a PR, or preparing changes for review.
license: MIT
metadata:
  author: kurama
  version: "2.0"
---

## When this runs

Reach for this the moment work stops being code and starts being a delivery: a branch about to
be cut, a diff about to become one or more pull requests, or a contributor asking how to open
one here. It covers the whole path from branch name to merged card.

---

## Non-negotiables

Four requirements bind every PR this repo receives, including the ones you open yourself and
every unit of a stacked chain:

1. **An approved issue is linked** — there is no exception, and "small" is not one
2. **Exactly one `type:*` label** — not zero, not two
3. **Every automated check is green** before a merge is even possible
4. **A PR with no issue linkage is rejected by GitHub Actions**, so an unlinked PR is not a
   shortcut — it is a round trip

---

## Workflow

```
1. Verify issue has `status:approved` label
2. Create branch: type/{issue}-{slug} — the issue number first (see Branch Naming below)
3. Implement changes with conventional commits
4. Run shellcheck on modified scripts
5. Run the Review Workload Guard — measure the diff against the base and pick a Delivery Strategy
6. Open PR(s) using the template — a single PR or a stacked chain per the guard's verdict
7. Add exactly one type:* label to each PR
8. Wait for automated checks to pass
```

---

## Review Workload Guard

Run this **before assembling any PR** — after implementation and shellcheck (Workflow
step 5), before `gh pr create`. It measures the change against the base branch and
decides whether the work ships as one PR or must be partitioned into a chain.

```bash
# Base branch the PR will target (usually main)
BASE=main

# 1. Human-readable overview of the change
git diff --stat "origin/$BASE"...HEAD

# 2. Authored changed lines (added + deleted)
git diff --numstat "origin/$BASE"...HEAD | awk '{n += $1 + $2} END {print "changed lines:", n}'
#    Subtract generated artifacts from this count — files produced by
#    scripts/build-examples.sh, *.golden snapshots, and vendored code are generated,
#    not authored. The guard's threshold is about AUTHORED lines.

# 3. Files changed
git diff --name-only "origin/$BASE"...HEAD | awk 'END {print "files:", NR}'

# 4. Distinct top-level modules touched
git diff --name-only "origin/$BASE"...HEAD | awk -F/ '{print $1}' | sort -u | awk 'END {print "modules:", NR}'
```

**Partition trigger** — do NOT ship a single PR when **either** holds:

- authored changed lines **> ~400**, **or**
- the change touches **> 8 files** spread across **> 3 top-level modules**.

**Verdict:**

- **Neither trigger fires** → the work can ship as a single PR. Continue to
  Delivery Strategy for the risk check.
- **Any trigger fires** → do NOT open one big PR. Partition the work into a stacked
  chain (see Chain Strategy) and apply the matching Delivery Strategy.

**Escape hatch (explicit override).** The user may deliberately choose a single large
PR even when the guard fires — but only when they ask for it **explicitly**. Record it
in the PR body as a conscious decision so the reviewer knows the guard was overridden:

```markdown
### Review Workload
> Guard fired: ~620 authored lines across 11 files / 4 modules.
> Single-PR delivery chosen explicitly by @<user> despite the guard.
> Reviewer: expect a large diff.
```

---

## Delivery Strategy

Once the guard has measured the change, pick exactly one size mode. Risk-domain
handling stacks on top of the size decision (a large auth change is both a chain
**and** risk-flagged).

| Change profile | Delivery mode |
|----------------|--------------|
| Small, low-risk — both guard triggers clear, no risky domain | **Single direct PR** (base `main`) |
| Large — either guard trigger fired | **Stacked chain of PRs** (see Chain Strategy) |
| Risky domain — touches auth, payments, data, or security — **at any size** | Chosen size mode **+ risk flag + mandatory rollback note** in the PR body |

Risky-domain PRs MUST include both blocks in the body — a risky-domain PR without a
filled-in rollback note is not ready to open:

```markdown
### ⚠️ Risk Flag
Domain: <auth | payments | data | security>
Blast radius: <what breaks if this ships wrong>

### Rollback
- Revert: `git revert <merge-commit-sha>` (or `gh pr revert <n>`)
- Data / migration undo: <concrete steps, or "none — code-only">
- Post-rollback check: <command that confirms recovery>
```

---

## Chain Strategy

When the guard says partition, split the change into independently reviewable units
and stack them.

**Rules:**

- **One branch per work unit**, named `type/{issue}-{slug}` — each unit links its own
  approved issue, so that number identifies it and the merge order lives in the `### Chain`
  block below. When a whole chain ships under ONE issue, order the units inside it:
  `type/{issue}-{n}-{slug}`, `{n}` 1-based. Must still satisfy the Branch Naming regex
  below (lowercase, `a-z0-9._-` only).
- **Each PR is standalone reviewable** — it passes on its own, links its own
  `status:approved` issue, and carries exactly one `type:*` label. All four
  non-negotiables bind every unit; a chain does not spread one issue's approval across
  three PRs.
- **base = previous PR's branch** (the first unit bases on `main`).
- **Merge order is documented** in every PR body.

```bash
# Unit 1 — bases on main, carries its own issue number (#101)
git checkout -b feat/101-token-store main
# ...implement + commit unit 1...
git push -u origin feat/101-token-store
gh pr create --base main \
  --title "feat(auth): add token store" \
  --body "Closes #101"

# Unit 2 — bases on unit 1's branch (stacked), carries issue #102
git checkout -b feat/102-refresh feat/101-token-store
# ...implement + commit unit 2...
git push -u origin feat/102-refresh
gh pr create --base feat/101-token-store \
  --title "feat(auth): add refresh flow" \
  --body "Refs #102"   # base ≠ default → Refs (see Closes vs Refs); flips to Closes on re-parent onto main
```

Document the order in every chained PR body:

```markdown
### Chain
Part 2 of 3 — merge order: PR #201 → #202 → #203 (issues #101 → #102 → #103).
Base PR: #201 (must merge first).
```

**After a base PR merges**, re-parent the next unit onto the new base and retarget
its PR:

```bash
# unit 1 merged into main → re-base unit 2 onto main
git checkout feat/102-refresh
git rebase --onto main feat/101-token-store
git push --force-with-lease
gh pr edit <unit-2-pr> --base main
# base is now the default branch → switch the body's `Refs #102` back to `Closes #102`
```

---

## Branch Naming

Branch names MUST match this regex:

```
^(feat|fix|chore|docs|style|refactor|perf|test|build|ci|revert)\/[a-z0-9._-]+$
```

**Format:** `type/description` — lowercase, no spaces, only `a-z0-9._-` in description.

**A GitHub issue is linked** — the work came from a kanban card, from
`skills/issue-creation`, or the PR will carry `Closes #N` / `Refs #N` → the branch is
**`type/{issue}-{slug}`**: the issue number first, then a short kebab slug. Always.
Without the number, `git log` and `git branch` give no way back to the ticket.

**No issue in play** → unchanged: `type/{slug}`.

**The change name already starts with that number** — SDD names an issue-linked change
`{issue}-{slug}` (`skills/_shared/openspec-convention.md` → *The `{change-name}`*) → the branch is
`type/{change-name}` as it stands: `feat/22-nodemaven-gateway-provider`, never
`feat/22-22-nodemaven-gateway-provider`.

The regex is the same for both — it already admits digits.

| Type | Issue-linked — `type/{issue}-{slug}` | No issue — `type/{slug}` |
|------|--------------------------------------|--------------------------|
| Feature | `feat/104-sdd-brainstorm-gate` | `feat/user-login` |
| Bug fix | `fix/81-recaptcha-otp-resend` | `fix/zsh-glob-error` |
| Chore | `chore/77-update-ci-actions` | `chore/update-ci-actions` |
| Docs | `docs/62-installation-guide` | `docs/installation-guide` |
| Style | `style/48-format-scripts` | `style/format-scripts` |
| Refactor | `refactor/37-extract-shared-logic` | `refactor/extract-shared-logic` |
| Performance | `perf/29-reduce-startup-time` | `perf/reduce-startup-time` |
| Test | `test/95-add-setup-coverage` | `test/add-setup-coverage` |
| Build | `build/54-update-shellcheck` | `build/update-shellcheck` |
| CI | `ci/41-add-branch-validation` | `ci/add-branch-validation` |
| Revert | `revert/88-broken-setup-change` | `revert/broken-setup-change` |

---

## What the body must carry

`.github/PULL_REQUEST_TEMPLATE.md` is the shipped shape; these six pieces are the ones a
reviewer and the validation jobs both depend on, so none of them is optional:

### 1. Linked Issue (REQUIRED)

```markdown
Closes #<issue-number>
```

Three keywords close an issue — `Closes #N`, `Fixes #N`, `Resolves #N` — and case does not
matter. Whichever you use, that issue has to already carry `status:approved`; a PR against an
unapproved issue fails validation rather than starting a discussion about the issue.

**The branch number and this line MUST agree.** A branch named `type/{issue}-{slug}`
carries the SAME `N` as its `Closes #N` / `Refs #N` — a branch numbered for one issue and
a body linking another is a broken trail. Fix the branch, not the body.

**Closes vs Refs — keyed on the PR base:**

- **Base is the repo's default branch** → use a closing keyword (`Closes #N`); the merge
  auto-closes the issue.
- **Base is NOT the default branch** (e.g. a stacked PR onto a feature branch) → a closing
  keyword does NOT auto-close toward a non-default base, so use `Refs #N` instead and close
  the issue explicitly after the merge (`gh issue close #N`, step 3 of the Post-approval
  flow). When the PR is later re-parented onto the default branch (see *Chained PRs*),
  switch the body back to `Closes #N`.

### 2. PR Type (REQUIRED)

Tick a single checkbox in the template, then apply the label that goes with it — the checkbox
is for the reader, the label is what the job reads:

| Checkbox | Label to add |
|----------|-------------|
| Bug fix | `type:bug` |
| New feature | `type:feature` |
| Documentation only | `type:docs` |
| Code refactoring | `type:refactor` |
| Maintenance/tooling | `type:chore` |
| Breaking change | `type:breaking-change` |

### 3. Summary

Between one and three bullets saying what this PR changes. Not why it was assigned, not what
the issue said — what landed.

### 4. Changes Table

```markdown
| File | Change |
|------|--------|
| `path/to/file` | What changed |
```

### 5. Test Plan

```markdown
- [x] Scripts run without errors: `shellcheck scripts/*.sh`
- [x] Manually tested the affected functionality
- [x] Skills load correctly in target agent
```

### 6. Contributor Checklist

Every box in the template's checklist is ticked before the PR opens — an unticked box is a
claim you have not made, and a reviewer reads it that way:
- an approved issue is linked above
- exactly **one** `type:*` label is on the PR
- `shellcheck` was run over every modified script
- the skills were loaded in at least one agent
- docs were updated wherever behavior changed
- the commits are conventional
- no commit carries a `Co-Authored-By` trailer

---

## What CI blocks on

| Check | Job name | What it verifies |
|-------|----------|-----------------|
| PR Validation | `Check Issue Reference` | Body contains `Closes/Fixes/Resolves #N` |
| PR Validation | `Check Issue Has status:approved` | Linked issue has `status:approved` |
| PR Validation | `Check PR Has type:* Label` | PR has exactly one `type:*` label |
| CI | `Shellcheck` | Shell scripts pass `shellcheck` |

---

## Kanban Board Sync (optional)

Applies only when the project has `kanban.enabled: true` (see the **Kanban Module** in
the orchestrator instructions and `skills/kanban-github/SKILL.md`). With kanban inactive none
of this runs and PR behavior is unchanged.

- **Issue link.** The PR body's linked-issue line (already REQUIRED under *PR Body Format →
  Linked Issue*, in the body section above) is what the board relies on: `Closes #{issue}` when the base is the default
  branch (auto-links and auto-closes on merge), or `Refs #{issue}` when the base is not the
  default branch (the agent closes the issue explicitly after the merge — see Post-approval
  flow step 3).
- **On PR open → In Review.** Once `gh pr create` succeeds, the card advances to **In
  Review**. The orchestrator runs this move inline as `gh` state — it owns every board
  transition; the PR/phase sub-agent never touches the board. A failed move is a WARNING
  in the envelope's `risks` and never blocks.
- **Post the PR link on the issue.** After the PR is open, comment its URL on the issue so
  the trail lives on the board (`gh issue comment {issue} --body {pr-url}`); a failed comment
  is a WARNING, never a blocker. During planning, important decisions MAY also be recorded as
  issue comments (optional but recommended).

---

## Post-approval flow

Runs after the PR is open and reviewed, **with or without kanban**. The trigger is the
user's **explicit OK** on the PR — this is ALWAYS a human gate. Never auto-merge, not even
in `execution_mode: auto`.

**Hard preconditions — ALL THREE must hold before the merge:**

- **(a) Explicit OK for THIS PR** — never implicit, never inherited from another PR, never
  deduced from a "looks good".
- **(b) Branch rebased onto its base and re-verified** after the rebase.
- **(c) `gh pr checks <pr-number>` all pass, run IMMEDIATELY before the merge** — fresh
  evidence from the command, never a remembered green.

**Canonical order (identical in `skills/kanban-github/SKILL.md` and the orchestrator
instructions):**

1. **Merge with the configured method and delete the branch.** The method is
   `kanban.merge_method` when kanban is active (default `squash`); without kanban, default
   to `squash` unless the user picked `merge` or `rebase`.
   ```bash
   gh pr merge <pr-number> --squash --delete-branch   # --squash | --merge | --rebase per the configured method
   ```
2. **Verify the merge landed** before proceeding:
   ```bash
   gh pr view <pr-number> --json state -q .state       # expect: MERGED
   ```
   If the merge command FAILS, STOP — report it and wait for the user's instruction. This
   is a delivery action, not bookkeeping, so it is the one board-adjacent step allowed to
   halt the flow (the failures-never-block rule does not cover it).
3. **If the body used `Refs #{issue}` (non-default base), close the issue explicitly:**
   ```bash
   gh issue close <issue-number>                        # no-op for Closes-based PRs (auto-closed on merge)
   ```
4. **Kanban only — move the card to Done.** With `kanban.enabled`, advance the card to
   **Done** (orchestrator, inline `gh`, per `skills/kanban-github/SKILL.md`). A failed move
   is a WARNING in `risks`, never a blocker.
5. **Return to the base branch:**
   ```bash
   git checkout <default-branch> && git pull
   ```

---

## Commit message format

Every commit message has to satisfy this regex:

```
^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([a-z0-9\._-]+\))?!?: .+
```

**Format:** `type(scope): description` or `type: description`

- `type` — required, one of: `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `revert`, `style`, `test`
- `(scope)` — optional, lowercase with `a-z0-9._-`
- `!` — optional, indicates breaking change
- `description` — required, starts after `: `

Each type maps to exactly one PR label:

| Commit type | PR label |
|-------------|----------|
| `feat` | `type:feature` |
| `fix` | `type:bug` |
| `docs` | `type:docs` |
| `refactor` | `type:refactor` |
| `chore` | `type:chore` |
| `style` | `type:chore` |
| `perf` | `type:feature` |
| `test` | `type:chore` |
| `build` | `type:chore` |
| `ci` | `type:chore` |
| `revert` | `type:bug` |
| `feat!` / `fix!` | `type:breaking-change` |

Examples:
```
feat(scripts): add Codex support to setup.sh
fix(skills): correct progress merge order in sdd-apply
docs(readme): update multi-model configuration guide
refactor(skills): extract shared persistence logic
chore(ci): add shellcheck to PR validation workflow
perf(scripts): reduce setup.sh execution time
style(skills): fix markdown formatting
test(scripts): add setup.sh integration tests
ci(workflows): add branch name validation
revert: undo broken setup change
feat!: redesign skill loading system
```

---

## Commands

```bash
# Create branch — issue number first when an issue is linked
git checkout -b feat/42-my-feature main

# Run shellcheck before pushing
shellcheck scripts/*.sh

# Push and create PR — the branch number and the closing keyword must agree
git push -u origin feat/42-my-feature
gh pr create --title "feat(scope): description" --body "Closes #42"

# Add type label to PR
gh pr edit <pr-number> --add-label "type:feature"
```
