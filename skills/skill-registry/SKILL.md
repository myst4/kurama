---
name: skill-registry
description: >
  Rebuild the project skill registry by running _shared/build-skill-registry.sh, then report the counts and save the result to engram when available.
  Trigger: When user says "update skills", "skill registry", "actualizar skills", "update registry", or after installing/removing skills.
license: MIT
metadata:
  author: kurama
  version: "2.0"
---

## Purpose

You rebuild `.kurama/skill-registry.md` — the **index** that maps every installed
skill to its `SKILL.md` path. It is the only surface a delegator resolves
`## Project Standards (skills to load)` from, so without it every sub-agent runs
blind to the project's conventions (`_shared/skill-resolver.md`).

**You do not scan anything yourself.** The scan is
`_shared/build-skill-registry.sh`, a shipped script that reads two frontmatter
fields per `SKILL.md` and writes the file in well under a second. Your job is
three steps: run it, read back what it wrote, report it.

**The registry is an index, not a summary.** It carries no per-skill digests, no
compact rules, no generated prose — the resolver passes paths and lets each
sub-agent read the full skill, because a full read is authoritative and a digest
is lossy and goes stale silently. Do not add a summary section to the file, and
do not write one into your report.

## When to Run

- After installing or removing skills
- When the user explicitly asks to update the registry
- `sdd-init` Step 4 runs the same script (it does not delegate to this skill)

`setup.sh` and `update.sh` already run it at install and re-sync time, so a fresh
install starts with a current registry.

## Step 1: Run the Script

The script ships in the `_shared/` directory next to this skill — i.e.
`../_shared/build-skill-registry.sh` relative to the directory this `SKILL.md`
lives in. Resolve that path and run it from the project root:

```bash
bash <this-skill-dir>/../_shared/build-skill-registry.sh --root "$(pwd)"
```

It prints exactly one line on success:

```
skill-registry: 42 skills (31 user, 11 project) → .kurama/skill-registry.md
```

**If the script is not there, STOP.** Do not scan the skill directories
yourself, do not write the registry by hand, and do not report success. A
missing script is a broken install, not a case to work around — a hand-built
registry would drift from the script's output the moment either changes, which
is the exact failure this replaced. Report:

```markdown
## Skill Registry — BLOCKED

**Reason**: `_shared/build-skill-registry.sh` is not installed at `{path you looked for}`.

The registry cannot be built and every delegation will resolve without project
standards until it is. Fix the install:

    ./scripts/update.sh        # re-syncs the shipped scripts
    ./scripts/doctor.sh        # confirms the builder is back

There is no fallback scan by design: one implementation, or two that disagree.
```

The script refuses to write into `/` or `$HOME`, and into any directory with no
project marker (`.git`, `.kurama/`, or a project skills directory). That refusal
is exit 0 with a message naming the reason — not a failure. If you see it, you
are in the wrong directory: `cd` to the project root and run it again.

## Step 2: Verify the Artifact Landed

Do this BEFORE reporting anything. A registry that was never written fails
silently in the worst direction: every later delegation hits the resolver's "no
registry found" branch and proceeds WITHOUT project standards, so the damage
shows up as sub-agents quietly ignoring conventions, never as an error.

1. Read back `.kurama/skill-registry.md`. Check with `test -f` or your Read tool
   — never with `fd`/`rg`, which skip `.kurama/` because it is hidden AND
   gitignored (`_shared/skill-resolver.md` → *fail-loud checks*).
2. It MUST contain a `## User Skills` table whose row count matches the number
   the script reported.
3. If the file is missing, empty, or short on rows, do NOT report success.
   Return `status: blocked` naming what is missing, and paste the script's own
   output — it is the diagnosis.

Reporting completion without this check is a protocol violation. "I finished" is
not evidence; the file on disk is.

## Step 3: Save to Engram (when available)

If the `mem_save` tool is available, also store the registry so it survives the
session:

```
mem_save(
  title: "skill-registry",
  topic_key: "skill-registry",
  type: "config",
  project: "{project}",
  capture_prompt: false,
  content: "{the registry markdown you just read back}"
)
```

`topic_key` makes it an upsert — running again updates the same observation.
`capture_prompt: false` because the registry is an automated build output, not a
human decision (`_shared/engram-convention.md` → *Prompt Capture*).

The file on disk is the guarantee; Engram is the cross-session bonus. Never skip
Step 1 because Engram already holds a copy.

## Step 4: Return Summary

```markdown
## Skill Registry Updated

**Project**: {project name}
**Location**: .kurama/skill-registry.md
**Skills**: {N} ({U} user, {P} project)
**Conventions**: {number of rows in the Project Conventions table}
**Engram**: {saved / not available}

### Next Steps
The orchestrator reads this registry once per session and passes pre-resolved
SKILL.md paths to sub-agents in their launch prompts. Run this again after
installing or removing skills.
```

Report the counts the script printed. Do not list every skill back — the table
is in the file, and re-typing it is the token cost this skill exists to remove.

## Rules

- ALWAYS run `_shared/build-skill-registry.sh`; never scan or hand-write the registry
- NEVER add a compact-rules or summary section to `.kurama/skill-registry.md`
- If the script is missing, report `blocked` and stop — there is no fallback scan
- ALWAYS verify the file landed before reporting success; a missing registry degrades silently
- ALWAYS save to engram if `mem_save` is available
- The registry is written in EVERY persistence mode — `.kurama/` is harness
  infrastructure, and the mode gates that suppress `openspec/` never apply to it
- The script owns which directories are scanned, what is excluded and how
  duplicates resolve. Changing that behaviour means changing the script, never
  this file: one implementation, or two that disagree.
