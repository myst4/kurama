---
name: issue-creation
description: >
  Issue creation workflow for Agent Teams Lite following the issue-first enforcement system.
  Trigger: When creating a GitHub issue, reporting a bug, or requesting a feature.
license: Apache-2.0
metadata:
  author: gentleman-programming
  version: "1.0"
---

## When to Use

Use this skill when:
- Creating a GitHub issue (bug report or feature request)
- Helping a contributor file an issue
- Triaging or approving issues as a maintainer

---

## Critical Rules

1. **Blank issues are disabled** — MUST use a template (bug report or feature request)
2. **Every issue gets `status:needs-review` automatically** on creation
3. **A maintainer MUST add `status:approved`** before any PR can be opened
4. **Questions go to [Discussions](https://github.com/Gentleman-Programming/agent-teams-lite/discussions)**, not issues

---

## Workflow

```
1. Search existing issues for duplicates
2. Choose the correct template (Bug Report or Feature Request)
3. Fill in ALL required fields
4. Check pre-flight checkboxes
5. Submit → issue gets status:needs-review automatically
6. Wait for maintainer to add status:approved
7. Only then open a PR linking this issue
```

---

## Issue Templates

### Bug Report

Template: `.github/ISSUE_TEMPLATE/bug_report.yml`
Auto-labels: `bug`, `status:needs-review`

#### Required Fields

| Field | Description |
|-------|-------------|
| **Pre-flight Checks** | Checkboxes: no duplicate + understands approval workflow |
| **Bug Description** | Clear description of the bug |
| **Steps to Reproduce** | Numbered steps to reproduce |
| **Expected Behavior** | What should have happened |
| **Actual Behavior** | What happened instead (include errors/logs) |
| **Operating System** | Dropdown: macOS, Linux variants, Windows, WSL |
| **Agent / Client** | Dropdown: Claude Code, OpenCode, Gemini CLI, Cursor, Windsurf, Codex, Other |
| **Shell** | Dropdown: bash, zsh, fish, Other |

#### Optional Fields

| Field | Description |
|-------|-------------|
| **Relevant Logs** | Log output (auto-formatted as code block) |
| **Additional Context** | Screenshots, workarounds, extra info |

#### Example — Bug Report via CLI

`--template` and `--body`/`--body-file` are mutually exclusive in `gh` (the CLI rejects the combination outright), and `--template` matches the form's `name:` field — `"Bug Report"`, not the filename `bug_report.yml`. Bypassing the interactive template form with `--body` also bypasses its auto-labels, so add them explicitly with `--label`:

```bash
gh issue create \
  --title "fix(scripts): setup.sh fails on zsh with glob error" \
  --label "bug,status:needs-review" \
  --body "
### Pre-flight Checks
- [x] I have searched existing issues and this is not a duplicate
- [x] I understand this issue needs status:approved before a PR can be opened

### Bug Description
Running setup.sh on zsh throws a glob error when no matching files exist.

### Steps to Reproduce
1. Clone the repo
2. Run \`./scripts/setup.sh\` in zsh
3. See error: \`zsh: no matches found: skills/*\`

### Expected Behavior
The script should handle missing glob matches gracefully.

### Actual Behavior
Script crashes with glob error.

### Operating System
macOS

### Agent / Client
Claude Code

### Shell
zsh

### Relevant Logs
\`\`\`
zsh: no matches found: skills/*
\`\`\`
"
```

---

### Feature Request

Template: `.github/ISSUE_TEMPLATE/feature_request.yml`
Auto-labels: `enhancement`, `status:needs-review`

#### Required Fields

| Field | Description |
|-------|-------------|
| **Pre-flight Checks** | Checkboxes: no duplicate + understands approval workflow |
| **Problem Description** | The pain point this feature solves |
| **Proposed Solution** | How it should work from the user's perspective |
| **Affected Area** | Dropdown: Scripts, Skills, Examples, Documentation, CI/Workflows, Other |

#### Optional Fields

| Field | Description |
|-------|-------------|
| **Alternatives Considered** | Other approaches or workarounds |
| **Additional Context** | Mockups, examples, references |

#### Example — Feature Request via CLI

```bash
gh issue create \
  --title "feat(scripts): add Codex support to setup.sh" \
  --label "enhancement,status:needs-review" \
  --body "
### Pre-flight Checks
- [x] I have searched existing issues and this is not a duplicate
- [x] I understand this issue needs status:approved before a PR can be opened

### Problem Description
The setup script only configures Claude Code, Gemini CLI, and OpenCode. Codex users have to manually copy skills.

### Proposed Solution
Add a Codex option to setup.sh that links skills to the .codex/ directory.

Example:
\`\`\`bash
./scripts/setup.sh --agent codex
\`\`\`

### Affected Area
Scripts (setup, installation)

### Alternatives Considered
Manually symlinking, but that defeats the purpose of the setup script.
"
```

---

## Label System

### Applied Automatically on Issue Creation

| Template | Labels added |
|----------|-------------|
| Bug Report | `bug`, `status:needs-review` |
| Feature Request | `enhancement`, `status:needs-review` |

### Applied by Maintainers

| Label | When to apply |
|-------|--------------|
| `status:approved` | Issue accepted for implementation — PRs can now be opened |
| `priority:high` | Critical bug or urgent feature |
| `priority:medium` | Important but not blocking |
| `priority:low` | Nice to have |

---

## Maintainer Approval Workflow

```
1. New issue arrives with status:needs-review
2. Review the issue — is it valid, clear, and in scope?
3. If YES → add status:approved label
4. If NO → comment with reason, close if needed
5. Contributor can now open a PR linking this issue
```

---

## Decision Tree

```
Is it a bug?                    → Use Bug Report template
Is it a new feature/improvement? → Use Feature Request template
Is it a question?               → Use Discussions, NOT issues
Is it a duplicate?              → Link to existing issue, close
```

---

## Commands

```bash
# Search existing issues before creating
gh issue list --search "keyword"

# Create bug report (interactive — --template matches the form's name, not the filename;
# it prompts for the remaining fields since --body/--body-file cannot combine with --template)
gh issue create --template "Bug Report" --title "fix(scope): description"

# Create feature request (interactive, same rule)
gh issue create --template "Feature Request" --title "feat(scope): description"

# Create bug report (non-interactive — see the "Bug Report via CLI" example above for the
# full --body block; auto-labels must be added explicitly with --label since --template is skipped)
gh issue create --title "fix(scope): description" --label "bug,status:needs-review" --body "..."

# Maintainer: approve an issue
gh issue edit <number> --add-label "status:approved"

# Maintainer: add priority
gh issue edit <number> --add-label "priority:high"
```
