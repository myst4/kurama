# SDD Phase — Common Protocol

Boilerplate identical across all SDD phase skills. Sub-agents MUST load this alongside their phase-specific SKILL.md.

Executor boundary: every SDD phase agent is an EXECUTOR, not an orchestrator. Do the phase work yourself. Do NOT launch sub-agents, do NOT call `delegate`/`task`, and do NOT bounce work back unless the phase skill explicitly says to stop and report a blocker.

## Canonical Phase DAG (single source of truth)

This is the ONE canonical declaration of the SDD dependency graph. Every other file (phase skills, docs, conventions) MUST point here instead of restating the order:

```
explore → propose → (spec ‖ design) → tasks → apply → verify → archive
```

- `explore` has no upstream dependencies; its output is optional input to `propose`.
- `propose` depends on `explore` when an exploration exists (optional otherwise).
- `spec` and `design` both depend on `propose` and MAY run in parallel (`‖`). When parallelized, each treats the other's output as optional; `tasks` is the reconciliation point.
- `tasks` depends on `propose`, `spec`, and `design` (all required).
- `apply` depends on `tasks`.
- `verify` depends on `apply`.
- `archive` depends on a passing `verify` report.

Which specific upstream artifacts a phase treats as REQUIRED vs OPTIONAL is stated in that phase's SKILL.md; the retrieval-failure semantics for both classes live in Section B below.

### Change size and the collapsed path

The DAG above is the `standard` path and is unchanged. `sdd-propose` classifies every change
as `small` or `standard` and records it in the proposal's `## Change Size` section; for a
`small` change it writes the spec and the design as sections INSIDE the proposal, and the
orchestrator runs:

```
explore → propose → tasks → apply → verify → archive
```

This **collapses artifacts, it does not remove them**. `tasks` still requires a spec and a
design, and `archive` still requires a delta spec to merge into the main specs — they are read
from the proposal's `## Spec (inline)` and `## Design (inline)` sections instead of from
separate artifacts. Skipping them outright would deadlock at both phases.

Resolution rules, binding on every orchestrator and phase:

- An absent or unrecognized `## Change Size` means **`standard`**. Changes created before this
  section existed carry none; they MUST continue on the long path, and no phase may fail on
  the missing section.
- A `small` change MUST NOT be blocked for a missing standalone `spec` or `design`.
- A `small` change whose inline spec is missing or carries no requirements MUST be blocked with
  `next_recommended: sdd-propose` — a partial delta merged into the main specs is worse than
  no archive at all.

## Phase I/O (which artifacts each phase reads and writes)

The read/write contract per phase. The orchestrator passes artifact REFERENCES (topic keys
or file paths), never content; a phase with required dependencies retrieves them itself from
the active backend via Section B.

| Phase | Reads | Writes |
|-------|-------|--------|
| `sdd-explore` | nothing | `explore` |
| `sdd-propose` | exploration (optional) | `proposal` |
| `sdd-spec` | proposal (required) | `spec` |
| `sdd-design` | proposal (required) | `design` |
| `sdd-tasks` | spec + design (required) | `tasks` |
| `sdd-apply` | tasks + spec + design | `apply-progress` |
| `sdd-verify` | spec + tasks | `verify-report` |
| `sdd-archive` | all artifacts | `archive-report` |

For a `small` change the spec and design arrive as inline sections of the proposal (see
*Change size and the collapsed path* above); the dependency is satisfied, not skipped.

## A. Skill Loading

1. Check whether the orchestrator injected a `## Project Standards` block in your launch
   prompt. Its heading names the resolution mode the orchestrator chose
   (`skill-resolver.md` → *Step 3*); follow the mode you were sent, do not pick one:
   - **`## Project Standards (skills to load)`** — the DEFAULT shape: skill names plus exact
     `SKILL.md` paths. **READ each listed file in full** before starting work and follow it
     strictly. A full read is authoritative and complete.
   - **`## Project Standards (auto-resolved)`** — the OPT-IN low-token shape: pre-digested
     compact rules pasted inline. Apply them as given, and do NOT go read the SKILL.md files
     the orchestrator deliberately did not send. Compact rules are a lossy summary
     (`skill-resolver.md` → *Why Not Compact Rules?*), which is why they are the exception
     and not the default.
2. If no Project Standards block was provided, check for `SKILL: Load` instructions. If present, read those exact skill files in full.
3. If neither was provided, search for the skill registry as a fallback:
   a. `mem_search(query: "skill-registry", project: "{project}")` — if found, `mem_get_observation(id)` for full content
   b. Fallback: read `.kurama/skill-registry.md` from the project root. Check with `test -f` or
      your harness's Read tool — never with a finder: `.kurama/` is both hidden AND gitignored,
      so `fd`/`rg` skip it even with hidden flags. A read that ERRORED is a broken check, not a
      missing registry (`skill-resolver.md` → *Step 1*).
   c. From the registry's **skills index** (`Trigger | Skill | Path`), match triggers to your
      current task and **read the exact listed `SKILL.md` paths**. The registry's *Compact
      Rules* section is the delegator's opt-in budget surface, not your default; fall back to a
      skill's compact rules only if its listed path cannot be read, and note that in `risks`.
4. If no registry exists, proceed with your phase skill only.

NOTE: the preferred path is (1) — standards resolved by the orchestrator, which by default sends SKILL.md paths for you to read in full. Paths (2) and (3) are fallbacks for backwards compatibility. Searching the registry is SKILL LOADING, not delegation. If `## Project Standards` is present, IGNORE any `SKILL: Load` instructions — they are redundant.

## B. Artifact Retrieval (Engram Mode)

**CRITICAL**: `mem_search` returns 300-char PREVIEWS, not full content. You MUST call `mem_get_observation(id)` for EVERY artifact. **Skipping this produces wrong output.**

**Run all searches in parallel** — do NOT search sequentially.

```
mem_search(query: "sdd/{change-name}/{artifact-type}", project: "{project}") → save ID
```

Then **run all retrievals in parallel**:

```
mem_get_observation(id: {saved_id}) → full content (REQUIRED)
```

Do NOT use search previews as source material.

### Retrieval failure semantics

An upstream artifact "cannot be retrieved" when the search returns no result, or returns a result whose title does not match `sdd/{change-name}/{artifact-type}` (in `engram`/`hybrid`), or its file is absent (in `openspec`/`hybrid`).

- **REQUIRED artifact missing** → do NOT silently proceed. Return your envelope with `status: blocked`, name the missing artifact in `executive_summary`, and set `next_recommended` to the phase that produces it (per the Canonical Phase DAG above).
- **OPTIONAL artifact missing** → proceed with the phase, and note the absence in `risks` (e.g. "spec not found — proceeded from proposal only").

Which upstream artifacts are required vs optional for your phase is declared in your phase SKILL.md. When in doubt, treat a dependency drawn as a solid edge in the DAG as required and a parallel-branch sibling (`spec ‖ design`) as optional.

## C. Artifact Persistence

Every phase that produces an artifact MUST persist it — downstream phases retrieve your output from the store, so returning without persisting leaves them nothing to read. If persistence fails, follow the recovery rule below rather than dropping the artifact.

### Engram mode

```
mem_save(
  title: "sdd/{change-name}/{artifact-type}",
  topic_key: "sdd/{change-name}/{artifact-type}",
  type: "architecture",
  project: "{project}",
  capture_prompt: false,
  content: "{your full artifact markdown}"
)
```

`capture_prompt: false` is mandatory on every SDD artifact save — automated artifacts must never capture the user's prompt (see `engram-convention.md`).

`topic_key` enables upserts — saving again updates, not duplicates.

If `mem_save` fails, retry once; if it still fails, write the full artifact to the filesystem fallback at `.kurama/sdd/{change-name}/{artifact-type}.md` and report the fallback path in `risks`. See `persistence-contract.md` → *Write Failure Recovery*. A failed save is never fatal — the artifact stays recoverable.

### OpenSpec mode

File was already written during the phase's main step. No additional action needed.

### Hybrid mode

Do BOTH: write the file to the filesystem AND call `mem_save` as above. The filesystem file is authoritative and the Engram entry is a searchable mirror; stamp `last_updated` (ISO 8601) in the artifact frontmatter and follow the same failure-recovery rule if the mirror write fails. See `persistence-contract.md` → *Hybrid Mode*.

### Cycle markers — every mode, and NOT a fallback

Two artifacts are ALSO written to `.kurama/sdd/{change-name}/` unconditionally, in every mode above including `engram`: `verify-report.md` (`sdd-verify` Step 7) and `archive-report.md` (`sdd-archive` Step 5), alongside the orchestrator's `state.md`. The deterministic hooks read only the filesystem — they cannot query Engram — so these disk copies are what make the archive gate and the write guard work outside `openspec` mode. This is *in addition to* the mode's own persistence, never a replacement, and it is unrelated to the `mem_save`-failure recovery rule above: the marker is written whether or not the save succeeded. Full contract: `persistence-contract.md` → *Hook-visible cycle markers*.

## D. Return Envelope

This envelope is the **ONLY** return contract for every SDD phase (including `sdd-init`). It is authoritative: where any per-skill "Return Summary" wording differs in field names or shape, **this section wins** — treat a phase's own summary format as the human-readable content that goes inside `detailed_report`, not as a second contract. Do not emit two competing return shapes.

Every phase MUST return a structured envelope to the orchestrator:

- `status`: `success`, `partial`, or `blocked`
- `executive_summary`: 1-3 sentence summary of what was done (name the missing artifact here when `status: blocked`)
- `detailed_report`: (optional) full phase output — this is where a phase's own "Return Summary" format lives; omit if already inline
- `artifacts`: list of artifact keys/paths written (include any `.kurama/sdd/` fallback path used)
- `next_recommended`: the next SDD phase to run, or "none"
- `risks`: risks discovered, fallbacks used, or hybrid reconciliation notes; "None" if there are none
- `skill_resolution`: how skills were loaded — `injected` (received Project Standards from orchestrator), `fallback-registry` (self-loaded from registry), `fallback-path` (loaded via SKILL: Load path), or `none` (no skills loaded). This field is REQUIRED in every envelope.

Example:

```markdown
**Status**: success
**Summary**: Proposal created for `{change-name}`. Defined scope, approach, and rollback plan.
**Artifacts**: Engram `sdd/{change-name}/proposal` | `openspec/changes/{change-name}/proposal.md`
**Next**: sdd-spec or sdd-design
**Risks**: None
**Skill Resolution**: injected — 3 skills (react-19, typescript, tailwind-4)
(other values: `fallback-registry`, `fallback-path`, or `none — no registry found`)
```
