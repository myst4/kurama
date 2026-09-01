# Skill Resolver — Universal Protocol

Any agent that **delegates work to sub-agents** MUST follow this protocol to resolve and inject relevant skills. This applies to the Kurama orchestrator, judgment-day, pr-review, and ANY future skill or workflow that launches sub-agents.

## Why This Exists

Sub-agents are born with NO context about what skills exist. Without skill injection, a judge reviewing a Next.js project won't know React 19 patterns, a fix agent won't follow project conventions, and a PR creator won't use the project's PR template.

## When to Apply

Before EVERY sub-agent launch that involves **reading, writing, or reviewing code**. Skip only for purely mechanical delegations (e.g., "run this test command").

And **after every return**, whatever the delegation was for: *Step 5* closes the cycle by
reaping the agent. That half has no exemption — a mechanical agent holds its context and its
slot in the agent list exactly like a code-reading one.

## The Protocol

### Step 1: Obtain the Skill Registry (once per session)

The registry carries TWO surfaces per skill: an **index** (`Trigger | Skill | Path` table) mapping each skill to its SKILL.md path, and a **Compact Rules** section with pre-digested rules (5-15 lines each). **By default you resolve via the index and pass the exact SKILL.md path** so the sub-agent reads the full skill. Compact Rules is an **opt-in, low-token optimization** (see *Why Not Compact Rules?*) — reach for it only when the context budget is tight.

Resolution order:
1. Already cached from earlier in this session? → use cache
2. `mem_search(query: "skill-registry", project: "{project}")` → `mem_get_observation(id)` for full content
3. Fallback: read `.kurama/skill-registry.md` from the project root if it exists
4. No registry found? → proceed without skills (but warn the user: "No skill registry found — sub-agents will work without project-specific standards. Run `skill-registry` to fix this.")

**"Not found" only counts after a fail-loud check.** Step 3 means `test -f .kurama/skill-registry.md` or the harness's Read tool — primitives that surface their own failure. A read command that ERRORED is evidence of a broken check, NOT of a missing registry: retry with the other method before concluding step 4. Never probe with a pattern that suppresses stderr (`… 2>/dev/null || echo missing`), and never with a finder at all: `.kurama/` is both hidden AND gitignored, so `fd`/`rg` skip it even when given hidden flags. For `.kurama/` the check is `test -f` or Read, full stop. Same rule, in full: `orchestrator-sdd-protocol.md` → *Artifact existence checks (fail-loud)*.

### Step 2: Match Relevant Skills

Match skills on TWO dimensions:

**A. Code Context** — what files will the sub-agent touch or review?

Map file patterns to skills from the registry (common examples — always defer to the registry's Trigger field as the source of truth):
- `.tsx`, `.jsx` → react skills
- `.ts` → typescript skills
- `app/**`, `pages/**` → nextjs/angular/framework skills
- `.py` → python/django skills
- `.go` → go skills
- `*.test.*`, `*.spec.*` → testing skills
- Style files → tailwind/css skills

Use the `Trigger` field in the registry's User Skills table to match. Skills whose triggers mention the relevant technology or file type are matches.

**B. Task Context** — what ACTIONS will the sub-agent perform?

| Sub-agent action | Match skills with triggers mentioning... |
|-----------------|------------------------------------------|
| Create a PR | "PR", "pull request" |
| Write/review code | The specific framework/language |
| Create Jira tickets | "Jira", "epic", "task" |
| Write Notion docs | "Notion", "RFC", "PRD" |
| Write comments | "comment" |
| Run tests | "test", "vitest", "pytest", "playwright" |

### Step 3: Inject into Sub-Agent Prompt

**Default (index + path).** From the registry's index, copy each matching skill's name and exact SKILL.md path into the sub-agent's prompt, and instruct it to READ each one before starting:

```
## Project Standards (skills to load)

Read each SKILL.md below in full before starting work; follow its rules strictly:
- {skill-name} — {path/to/SKILL.md}
- {skill-name} — {path/to/SKILL.md}
```

**Opt-in (compact rules, low-token mode).** Only when the context budget is tight, inject the pre-digested Compact Rules blocks instead of paths — trading fidelity for tokens:

```
## Project Standards (auto-resolved)

{paste compact rules blocks for each matching skill}
```

Either block goes BEFORE the sub-agent's task-specific instructions, so standards are loaded before work begins.

**Key rule**: by default pass PATHS and let the sub-agent read the full SKILL.md — a full read is authoritative and complete. Compact rules are a lossy summary; use them only as the budget optimization described in *Why Not Compact Rules?*.

### Step 4: Include Project Conventions

If the registry has a **Project Conventions** section, and the sub-agent will work on the project's code, also add:

```
## Project Conventions
Read these files for project-specific patterns:
- {path1} — {notes}
- {path2} — {notes}
```

Project conventions are short references (paths + notes), so passing them is cheap. The sub-agent reads them only if relevant to its task.

### Step 5: Reap the Sub-Agent Once You Have Synthesized Its Envelope

Launching is half the cycle; closing it is the other half. **A delegation is not complete when the
envelope arrives — it is complete when the envelope has been read, validated (gatekeeper checks
included) and synthesized, AND the agent that produced it has been shut down.**

A finished agent left alive is not free: it holds its entire context, keeps its slot in the
harness's agent/teammate list, and hands the user back the bookkeeping the orchestrator pattern
exists to absorb. An orchestrator that correctly delegates eight phases and reaps none ends the
session with eight idle agents.

- **On a harness with an explicit termination primitive** — Claude Code: the shutdown request to
  the named teammate (equivalently, the native stop tool with that agent's name) — issue it as
  soon as the envelope is synthesized, and name the agent you stopped alongside the result you
  took from it.
- **On a harness with no such primitive**, the reap is that you **hold no reference**: drop the
  handle, never message it again, and **say so** ("this harness has no stop primitive; the
  `sdd-spec` agent is finished and will not be reused"), so the user reads a closed delegation
  rather than a pending one.
- **At cycle end** — archive, a blocked stop, or the user cancelling — sweep: close every
  delegated agent still open from this session.

**The one exception: an intended follow-up by message.** Keep an agent alive ONLY while you still
intend to send *that* agent more work, because resuming it preserves the context it already built
and re-deriving that context in a fresh agent is the waste this exception exists to prevent. When
you take the exception, **name the intent at the moment you take it** — which agent, and what you
are about to send it ("keeping `sdd-design` open: the reconciliation note from `sdd-spec` goes to
it next"). "It might be useful later" is not an intent: the path for later work is a fresh agent
plus the persisted artifacts, which `sdd-phase-common.md` → *Artifact Persistence* guarantees are
already in the store.

## Why Not Compact Rules? (default is the full SKILL.md)

Passing paths and reading the full SKILL.md is the default because compact rules are **lossy by construction**:

- A 5-15 line digest cannot carry every critical pattern, edge case, or breaking-change gotcha the full SKILL.md documents — the exact details a sub-agent needs to avoid bugs are the first thing a summary drops.
- Compact rules go stale silently: they are regenerated only when someone re-runs `skill-registry`, so a digest can lag behind the SKILL.md it summarizes. Reading the file gives the sub-agent the current source of truth.
- A path costs a handful of tokens; the sub-agent reads the full skill only when its task actually touches that skill's domain. The apparent token savings of compact rules is small relative to the code the sub-agent reads anyway.

Reach for the opt-in compact-rules mode ONLY when the context budget is genuinely tight — many skills match at once, the sub-agent prompt is already large, or the harness caps prompt size. In that case the registry still carries both surfaces, so the switch is free.

## Token Budget

**Default (paths)**: a path line costs only a handful of tokens per skill; the full SKILL.md is read on demand by the sub-agent, and only for skills its task actually touches. This is the cheapest resolution for the delegator's own prompt.

**Opt-in (compact rules)**: the compact rules blocks add **50-150 tokens per skill** to the sub-agent's prompt. For a delegation matching 3-4 skills that's ~400-600 tokens — worth it only when you deliberately want the rules pre-digested to avoid on-demand reads.

If more than **5 skills** match, keep only the 5 most relevant (prioritize code context matches over task context matches).

## Compaction Safety

This protocol is compaction-safe because:
- The registry lives in engram/filesystem, not in the orchestrator's memory
- Each delegation re-reads the registry if needed (Step 1 handles cache miss)
- The resolved skills (paths by default, or compact rules in opt-in mode) are copied into each sub-agent's prompt at launch time — even if the orchestrator forgets, the sub-agents already have what they need to load standards

## Feedback Loop

Sub-agents MUST report their skill resolution status in their return envelope:

- `injected` — received a `## Project Standards` block from the orchestrator (paths to load by default, or pre-digested compact rules in opt-in mode) and loaded it (ideal path)
- `fallback-registry` — no standards received, self-loaded from the skill registry
- `fallback-path` — no standards received, resolved the SKILL.md via its registry path directly

**Orchestrator self-correction rule**: if a sub-agent reports anything other than `injected`, the orchestrator MUST:
1. Re-read the skill registry immediately (it may have been lost to compaction)
2. Ensure ALL subsequent delegations carry a `## Project Standards` block — `(skills to load)` by default, `(auto-resolved)` only when the budget forced the opt-in
3. Log a warning to the user: "Skill cache miss detected — reloaded registry for future delegations."

This prevents silent degradation where the orchestrator forgets skills after compaction and all subsequent sub-agents work without standards.

## Integration Points

- **Kurama Orchestrator**: follows this protocol for ALL delegations (SDD and non-SDD)
- **judgment-day**: follows this protocol before launching Judge A, Judge B, and Fix Agent
- **pr-review**: already has internal skill loading — should migrate to this protocol for consistency
- **Any future skill that delegates**: MUST reference this protocol
