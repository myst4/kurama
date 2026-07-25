---
name: skill-registry
description: >
  Create or update the skill registry for the current project. Scans user skills and project conventions, writes .kurama/skill-registry.md, and saves to engram if available.
  Trigger: When user says "update skills", "skill registry", "actualizar skills", "update registry", or after installing/removing skills.
license: MIT
metadata:
  author: gentleman-programming
  version: "1.0"
---

## Purpose

You generate or update the **skill registry** — a catalog of all available skills with TWO surfaces per skill: an **index** (`Trigger | Skill | Path`) mapping each skill to its SKILL.md path, and **compact rules** (pre-digested, 5-15 line summaries). By default a delegator resolves via the index and passes the exact SKILL.md path so the sub-agent reads the full skill; compact rules are an opt-in low-token surface it injects instead only when the context budget is tight. The registry carries both so either path works.

This is the foundation of the **Skill Resolver Protocol** (see `_shared/skill-resolver.md`). The registry is built ONCE (expensive), then read cheaply at every delegation.

## When to Run

- After installing or removing skills
- After setting up a new project
- When the user explicitly asks to update the registry
- As part of `sdd-init` (it calls this same logic)

## What to Do

### Step 1: Scan User Skills

1. Glob for `*/SKILL.md` files across ALL known skill directories. These mirror the
   per-harness install targets in `skills/manifest.json`. Check every path below — scan
   ALL that exist, not just the first match.

   **Scan EXACTLY one level deep**: a skill is `<skills-dir>/<skill-name>/SKILL.md` and
   nothing deeper. Do NOT recurse with `**/SKILL.md`. Skill bundles often keep their source
   checkout inside the skills directory (`<skills-dir>/<bundle>/` holding `.git`,
   `package.json`, and per-skill `SKILL.md.tmpl` templates) alongside the rendered skills
   installed flat at the top level. Recursing turns one skill into two entries — the
   installed copy and its own template source — and the delegator then picks between them
   arbitrarily, sometimes landing on a source copy that was never rendered.

   **User-level (global skills):**
   - `~/.claude/skills/` — Claude Code
   - `~/.config/opencode/skills/` — OpenCode
   - `~/.gemini/skills/` — Gemini CLI
   - `~/.codex/skills/` — Codex
   - `~/.cursor/skills/` — Cursor
   - `~/.copilot/skills/` — VS Code Copilot
   - `~/.gemini/antigravity/skills/` — Antigravity
   - **The parent directory of this skill file** — the catch-all: Kurama's own skills are
     co-located wherever it was installed, so scanning the parent dir picks up the active
     harness target even if it is not in the explicit list above. The named paths are the
     known install targets; this catch-all is the mechanism that always covers the current one.

   **Project-level (workspace skills):**
   - `{project-root}/.claude/skills/` — Claude Code
   - `{project-root}/.config/opencode/skills/` — OpenCode
   - `{project-root}/.gemini/skills/` — Gemini CLI
   - `{project-root}/.codex/skills/` — Codex
   - `{project-root}/.cursor/skills/` — Cursor
   - `{project-root}/.copilot/skills/` — VS Code Copilot
   - `{project-root}/.gemini/antigravity/skills/` — Antigravity (workspace)
   - `{project-root}/skills/` — Generic (project-local)

2. **SKIP `sdd-*` and `_shared`** — those are SDD workflow skills, not coding/task skills
3. Also **SKIP `skill-registry`** — that's this skill
4. **SKIP bundle source checkouts** — a directory that holds `.git`, `package.json`, or
   `SKILL.md.tmpl` is a bundle's source, not an installed skill. Skip the directory and
   everything under it; the rendered skills it produced are already installed flat at the
   top level. Only `SKILL.md` counts — never `SKILL.md.tmpl`.
5. **Deduplicate by skill name** — if the same `name` appears in multiple locations, keep the project-level version (more specific). If both are user-level, keep the first found. Deduplicate on the frontmatter `name`, not on the path, so two paths for one skill collapse to a single row.
6. For each skill found, read the **full SKILL.md** (if a SKILL.md exceeds 200 lines, focus on the frontmatter and Critical Patterns / Rules sections only) to extract:
   - `name` field (from frontmatter)
   - `description` field → extract the trigger text (after "Trigger:" in the description)
   - **Compact rules** — the actionable patterns and constraints (see Step 1b)
7. Build a table of: Trigger | Skill Name | Full Path

### Step 1b: Generate Compact Rules

For each skill found in Step 1, generate a **compact rules block** (5-15 lines max) containing ONLY:
- Actionable rules and constraints ("do X", "never Y", "prefer Z over W")
- Key patterns with one-line examples where critical
- Breaking changes or gotchas that would cause bugs if missed

**DO NOT include**: purpose/motivation, when-to-use, full code examples, installation steps, or anything the sub-agent doesn't need to APPLY the skill.

Format per skill:
```markdown
### {skill-name}
- Rule 1
- Rule 2
- ...
```

**Example** — compact rules for a React 19 skill:
```markdown
### react-19
- No useMemo/useCallback — React Compiler handles memoization automatically
- use() hook for promises/context, replaces useEffect for data fetching
- Server Components by default, add 'use client' only for interactivity/hooks
- ref is a regular prop — no forwardRef needed
- Actions: use useActionState for form mutations, useOptimistic for optimistic UI
- Metadata: export metadata object from page/layout, no <Head> component
```

**The registry's index (skill → SKILL.md path) is the default resolution surface** — delegators pass those paths so sub-agents read the full skill. The compact rules are the opt-in low-token surface: still worth generating accurately, because when a delegator is budget-constrained they are what the sub-agent receives instead of the full file. Invest time making them accurate and concise.

### Step 2: Scan Project Conventions

1. Check the project root for convention files. Look for:
   - `agents.md` or `AGENTS.md`
   - `CLAUDE.md` (only project-level, not `~/.claude/CLAUDE.md`)
   - `.cursorrules`
   - `GEMINI.md`
   - `copilot-instructions.md`
2. **If an index file is found** (e.g., `agents.md`, `AGENTS.md`): READ its contents and extract all referenced file paths. These index files typically list project conventions with paths — extract every referenced path and include it in the registry table alongside the index file itself.
3. For non-index files (`.cursorrules`, `CLAUDE.md`, etc.): record the file directly.
4. The final table should include the index file AND all paths it references — zero extra hops for sub-agents.

### Step 3: Write the Registry

Build the registry markdown:

```markdown
# Skill Registry

**Delegator use only.** Any agent that launches sub-agents reads this registry to resolve skills: by default it passes each matching skill's SKILL.md path (the sub-agent reads the full file), and only when the context budget is tight it injects the pre-digested compact rules instead. Sub-agents do not read this registry themselves.

See `_shared/skill-resolver.md` for the full resolution protocol.

## User Skills

| Trigger | Skill | Path |
|---------|-------|------|
| {trigger from frontmatter} | {skill name} | {full path to SKILL.md} |
| ... | ... | ... |

## Compact Rules

Pre-digested rules per skill — the opt-in low-token surface. Delegators copy matching blocks into sub-agent prompts as `## Project Standards (auto-resolved)` ONLY when the context budget is tight; the default is to pass the SKILL.md path from the index above.

### {skill-name-1}
- Rule 1
- Rule 2
- ...

### {skill-name-2}
- Rule 1
- Rule 2
- ...

{repeat for each skill}

## Project Conventions

| File | Path | Notes |
|------|------|-------|
| {index file} | {path} | Index — references files below |
| {referenced file} | {extracted path} | Referenced by {index file} |
| {standalone file} | {path} | |

Read the convention files listed above for project-specific patterns and rules. All referenced paths have been extracted — no need to read index files to discover more.
```

### Step 4: Persist the Registry

**This step is MANDATORY — do NOT skip it.**

#### A. Always write the file (guaranteed availability):

Create the `.kurama/` directory in the project root if it doesn't exist, then write:

```
.kurama/skill-registry.md
```

#### B. If engram is available, also save to engram (cross-session bonus):

```
mem_save(
  title: "skill-registry",
  topic_key: "skill-registry",
  type: "config",
  project: "{project}",
  capture_prompt: false,
  content: "{registry markdown from Step 3}"
)
```

`topic_key` ensures upserts — running again updates the same observation. `capture_prompt: false`
because the registry is an automated build output, not a human decision (see
`_shared/engram-convention.md` → *Prompt Capture*).

### Step 5: Verify the Artifact Landed

Do this BEFORE reporting anything. A registry that was never written fails silently in the
worst direction: every later delegation hits the resolver's "no registry found" branch and
proceeds WITHOUT project standards, so the damage shows up as sub-agents quietly ignoring
conventions, not as an error.

1. Read back `.kurama/skill-registry.md`. It MUST exist and contain the `## User Skills`
   table with at least one row per skill you catalogued.
2. Compare the row count against the number of skills you scanned. They MUST match.
3. If the file is missing, empty, truncated, or short on rows, **do NOT report success**.
   Return `status: blocked` naming what is missing:

```markdown
## Skill Registry — BLOCKED

**Reason**: {file not written | truncated at N of M skills | unreadable}
**Scanned**: {M} skills across {K} directories
**Written**: {N} rows

Re-run `skill-registry`. If the scan is too large for one pass, split it by directory and
merge: each run appends its rows to the same file.
```

Reporting completion without this check is a protocol violation. "I finished" is not
evidence — the file on disk is.

### Step 6: Return Summary

```markdown
## Skill Registry Updated

**Project**: {project name}
**Location**: .kurama/skill-registry.md
**Engram**: {saved / not available}

### User Skills Found
| Skill | Trigger |
|-------|---------|
| {name} | {trigger} |
| ... | ... |

### Project Conventions Found
| File | Path |
|------|------|
| {file} | {path} |

### Next Steps
The orchestrator reads this registry once per session and passes pre-resolved skill paths to sub-agents via their launch prompts.
To update after installing/removing skills, run this again.
```

## Rules

- ALWAYS write `.kurama/skill-registry.md` regardless of any SDD persistence mode
- ALWAYS verify the file landed before reporting success (Step 5); a missing registry degrades silently, so never report completion you have not read back from disk
- ALWAYS save to engram if the `mem_save` tool is available
- SKIP `sdd-*`, `_shared`, and `skill-registry` directories when scanning
- SKIP bundle source checkouts (`.git` / `package.json` / `SKILL.md.tmpl` present) and scan exactly one level deep — never `**/SKILL.md`
- When a scan is too large for one pass, split it BY DIRECTORY with disjoint explicit lists and merge into the same file — never let one agent carry more than it can finish
- Read SKILL.md files (respecting the 200-line guard in Step 1) to generate accurate compact rules — this is a build-time cost, not a runtime cost
- Compact rules MUST be 5-15 lines per skill — concise, actionable, no fluff
- Include ALL convention index files found (not just the first)
- If no skills or conventions are found, write an empty registry (so sub-agents don't waste time searching)
- Add `.kurama/` to the project's `.gitignore` if it exists and `.kurama` is not already listed
