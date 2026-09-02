# Delegation — Universal Cycle Contract

Any agent that **delegates work to sub-agents** MUST follow this contract. This applies to the
Kurama orchestrator, `judgment-day`, the review lenses, and ANY future skill or workflow that
launches sub-agents.

This is the DELEGATOR's half of the cycle. The sub-agent's half — what it reads and what it
returns — is `sdd-phase-common.md` (Sections A–D).

## Why This Exists

A delegation is a full cycle, not a launch: sub-agents are born with NO context about the
project's standards, and they do not clean themselves up when they are done. Both ends are the
delegator's job, and neither has a default that happens on its own.

## When to Apply

Before EVERY sub-agent launch that involves **reading, writing, or reviewing code**. Skip only
for purely mechanical delegations (e.g., "run this test command").

And **after every return**, whatever the delegation was for: the reap step below closes the
cycle by shutting the agent down. That half has no exemption — a mechanical agent holds its
context and its slot in the agent list exactly like a code-reading one.

## The Launch Prompt: `## Project Standards (files to read)`

The project declares its standards as the `standards:` list in `openspec/config.yaml` — an
ordered list of file paths, repo-relative or `~`-relative (schema and semantics:
`openspec-convention.md` → *Config File Reference*). Read that list ONCE per session, cache
it, and forward it **verbatim and in order** into every qualifying launch prompt:

```
## Project Standards (files to read)

Read each file below in full before starting work; follow its rules strictly:
- {path/from/standards}
- {path/from/standards}
```

The block goes BEFORE the sub-agent's task-specific instructions, so standards are loaded
before work begins.

Rules that constrain the delegator:

- **Pass PATHS, never pasted rule text.** The sub-agent reads the full file itself; a summary
  written into the prompt is lossy by construction and goes stale silently.
- **Forward the list as written.** Do not filter it by what you think the sub-agent's task
  touches, do not reorder it, and do not add files of your own. The project chose the list;
  reordering or trimming it is the delegator overruling that choice.
- **An empty or absent `standards:` list means the block is omitted.** That is a correct
  delegation, not a degraded one — say nothing and proceed.
- **A path the sub-agent cannot read comes back as a one-line `risks` note**, never silently.
  Surface it to the user once; it never blocks the phase.

Kurama's own skills are NOT resolved through `standards:` — the orchestrator and the phase
skills reach those by direct path, as they always have.

## Reap the Sub-Agent Once You Have Synthesized Its Envelope

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

## Compaction Safety

This contract is compaction-safe because the standards list lives on the filesystem, in the
project's committed `openspec/config.yaml`, not in the orchestrator's memory — a cache miss is
one re-read away — and because the paths are copied into each sub-agent's prompt at launch
time, so even if the orchestrator forgets, the sub-agents already have what they need.

## Feedback Loop

Sub-agents report how standards reached them in the `skill_resolution` field of their return
envelope (`sdd-phase-common.md` → *Section D*): `injected`, `fallback-path`, or `none`.

**Orchestrator self-correction rule**: if a sub-agent reports `fallback-path` while the project
DOES declare standards, you dropped the list (usually to compaction). Re-read `standards:` from
`openspec/config.yaml` immediately, carry the block in every subsequent delegation, and tell the
user: "Standards block missing from that launch — reloaded `standards:` for future delegations."

## Integration Points

- **Kurama Orchestrator**: follows this contract for ALL delegations (SDD and non-SDD)
- **judgment-day**: follows it before launching Judge A, Judge B, and the Fix Agent
- **Any future skill that delegates**: MUST reference this contract
