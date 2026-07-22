---
name: judgment-day
description: >
  Parallel adversarial review protocol that launches two independent blind judge sub-agents
  (with distinct review lenses) to review the same target, matches and refutes their findings,
  applies fixes, and re-judges until no confirmed blocking findings remain or it escalates
  after 2 fix iterations.
  Trigger: When user says "judgment day", "judgment-day", "review adversarial", "dual review",
  "doble review", "juzgar", "que lo juzguen".
license: Apache-2.0
metadata:
  author: gentleman-programming
  version: "1.1"
---

## When to Use

- User explicitly asks for "judgment day", "judgment-day", or equivalent trigger phrases
- After significant implementations before merging
- When high-confidence review of code, features, or architecture is needed
- When a single reviewer might miss edge cases or have blind spots
- When the cost of a production bug is higher than the cost of two review rounds

## Severity & Blocking

Every finding carries one severity. Blocking is a property of severity, not of consensus:

| Severity | Blocks approval? | Enters the fix list? | Refuted when only one judge sees it? |
|----------|------------------|----------------------|--------------------------------------|
| CRITICAL | Yes | Yes (once confirmed) | Yes |
| WARNING  | Yes | Yes (once confirmed) | Yes |
| SUGGESTION | No — advisory only | No | No — listed as-is, never blocks |

**Blocking findings** = CRITICAL + WARNING. SUGGESTIONs are always reported but never gate approval, never enter the fix list, and never consume a refutation or fix iteration.

## Critical Patterns

### Pattern 0: Skill Resolution (BEFORE launching judges)

Follow the **Skill Resolver Protocol** (`_shared/skill-resolver.md`) before launching ANY sub-agent:

1. Obtain the skill registry (engram → `.atl/skill-registry.md` from the project root → skip if none)
2. Identify the target files/scope — what code will the judges review?
3. Match relevant skills from the registry's **Compact Rules** by:
   - **Code context**: file extensions/paths of the target (e.g., `.tsx` → react-19, typescript)
   - **Task context**: "review code" → framework/language skills; "create PR" → branch-pr skill
4. Build a `## Project Standards (auto-resolved)` block with the matching compact rules
5. Inject this block into BOTH Judge prompts, the Refuter prompt, AND the Fix Agent prompt (identical for all)

This ensures every sub-agent works against project-specific standards, not just generic best practices.

**If no registry exists**: warn the user ("No skill registry found — judges will review without project-specific standards. Run `skill-registry` to fix this.") and proceed with generic review only.

### Pattern 1: Parallel Blind Review (distinct lenses)

- Launch **TWO** judge sub-agents via the **host harness's native sub-agent mechanism** (see [Portability](#portability--native-sub-agent-mechanism)). Prefer parallel execution; a documented sequential fallback preserves the protocol when parallelism is unavailable.
- Each judge receives the **same target** but a **distinct primary lens** so their coverage is complementary rather than correlated:

| Judge | Primary lens | Emphasis |
|-------|--------------|----------|
| Judge A | **Correctness & Security** | logic errors, edge cases, error handling, injection, auth/permissions, secret exposure |
| Judge B | **Regressions & Resilience** | behavioral regressions, state/determinism, partial failures, integration/shell boundaries, performance, conventions |

  Both judges still cover the full checklist, but each leads with its lens. Distinct lenses maximize coverage and mean that when both independently flag the **same** issue, the match is genuinely high-confidence — not two copies of the same prompt agreeing with themselves.
- **Neither judge knows about the other** — no cross-contamination. In sequential fallback, Judge B is launched WITHOUT Judge A's output; blindness is preserved by never forwarding one judge's findings to the other.
- **Judges never approve.** They return a findings list (possibly empty). The APPROVED/ESCALATED decision belongs to the orchestrator alone. Do not ask judges to declare "CLEAN".
- NEVER do the review yourself as the orchestrator — your job is coordination only.

### Pattern 2: Finding Matching & Verdict Synthesis

The **orchestrator** (NOT a sub-agent) matches the two findings lists, then classifies each finding. Matching is deterministic — run this procedure, do not eyeball it:

**Matching key** — normalize each finding to `(file, location, claim)`:
1. **file** — repo-relative path, normalized (strip `./`, resolve `../`, unify separators).
2. **location** — the line number, bucketed to a **±3-line window**, OR the enclosing symbol/function name when a line is unavailable. Two findings match on location if their windows overlap **or** they name the same enclosing symbol.
3. **claim** — normalized category (correctness / security / performance / error-handling / naming / …) plus the core assertion in lowercase, stopword-stripped.

**Classification**:

```
Same file + matching location + same claim (both judges)   → Confirmed
Same file + matching location + opposite claims            → Contradiction
Found by exactly one judge                                  → Suspect (A only / B only)
```

**Tie-break rule**: when in doubt whether two findings are "the same", classify as **Suspect**, never silently as Confirmed. Confirmed must be earned by a real match; refutation (Pattern 3) exists precisely to adjudicate the doubtful cases. This keeps "Confirmed" statistically meaningful.

Present the classified findings as a structured verdict table (see [Output Format](#output-format)).

### Pattern 3: Refutation of Suspects & Contradictions

A **Suspect** or **Contradiction** at blocking severity (CRITICAL/WARNING) is NOT fixed on sight and does NOT spawn a Fix Agent by itself. It goes through **one read-only Refuter batch** per round:

- Launch a single **Refuter** sub-agent (read-only — it inspects code, it does not edit) with the list of blocking suspects and contradictions.
- The Refuter adjudicates each item to exactly one of:
  - `CONFIRMED` — reproduced/substantiated against the actual code → promote to the Confirmed blocking set.
  - `REFUTED` — not a real issue (false positive, already handled, out of scope) → drop it, record the reason.
  - `UNRESOLVED` — genuinely needs a human judgment call (e.g., a contradiction the Refuter cannot settle) → route to the user decision gate, never silently pass or fix.
- **SUGGESTION-level** suspects are never refuted — they are listed as advisory and dropped from the blocking pipeline.
- The Refuter batch is **one call per round** and is read-only, so it does **not** consume a fix iteration.

This is what closes the "suspect-only round" loophole: a round that produces zero Confirmed matches and only suspects goes to refutation, not to an empty Fix Agent.

### Pattern 4: Approve / Fix / Re-judge (bounded)

After matching (Pattern 2) and refutation (Pattern 3), compute the **Confirmed blocking set** = matched-Confirmed(blocking) + Refuter-`CONFIRMED`.

1. **Confirmed blocking set is empty AND no `UNRESOLVED` blocking items** → `JUDGMENT: APPROVED`. Advisory SUGGESTIONs and REFUTED items are listed for the record; they do not block.
2. **Only `UNRESOLVED` blocking items remain** (no Confirmed) → **user decision gate**. Present them; the user promotes an item to Confirmed (it enters the next Fix Agent) or discards it. Waiting on the user does **not** burn a fix iteration.
3. **Confirmed blocking set has ≥ 1 item** → delegate a **Fix Agent** with that list (never empty), then re-launch Judge A + Judge B (fresh, blind, same distinct lenses) and return to Pattern 2.
4. **Max 2 fix iterations.** If the Confirmed blocking set is still non-empty after the 2nd fix → `JUDGMENT: ESCALATED` with full history. Refutation rounds and the user decision gate are NOT fix iterations — only Fix Agent runs count against the cap.

**Approval criterion (single source of truth)**: a target is APPROVED when **zero Confirmed blocking findings remain after refutation** (and no unresolved blocking contradictions). Judges are never asked to certify cleanliness; approval is reachable because trivial SUGGESTIONs and refuted false-positives cannot hold it hostage.

---

## Decision Tree

```
User asks for "judgment day"
│
├── Target is specific files/feature/component?
│   ├── YES → continue
│   └── NO  → ask user to specify scope before proceeding
│
▼
Pattern 0: resolve skills → build "Project Standards (auto-resolved)" block
▼
Launch Judge A (Correctness & Security) + Judge B (Regressions & Resilience)
  via the harness's native sub-agent mechanism — blind, parallel preferred,
  sequential fallback allowed (Judge B never sees Judge A's output)
▼
Collect both findings lists  (judges return findings only — never an approval)
▼
Pattern 2: match findings on (file, ±3-line/symbol location, normalized claim)
  → Confirmed | Suspect (A/B) | Contradiction   (SUGGESTION never blocks; ties → Suspect)
│
├── Any BLOCKING (CRITICAL/WARNING) Suspect or Contradiction?
│   ├── YES → Pattern 3: one read-only Refuter batch
│   │         → each item becomes CONFIRMED | REFUTED | UNRESOLVED
│   └── NO  → skip refutation
▼
Confirmed blocking set = matched-Confirmed(blocking) + Refuter-CONFIRMED
│
├── Empty AND no UNRESOLVED blocking?
│   └── JUDGMENT: APPROVED ✅  (SUGGESTIONs + REFUTED listed, non-blocking)
│
├── Only UNRESOLVED blocking remains (zero Confirmed)?
│   └── User decision gate → promote to Confirmed (enters Fix Agent) or discard
│       (no fix iteration consumed while waiting)
│
└── Confirmed blocking set ≥ 1?
    └── Fix iterations remaining? (cap = 2)
        ├── YES → Delegate Fix Agent with the Confirmed blocking list (never empty)
        │         ▼
        │         Re-launch Judge A + Judge B (Round N+1, blind, same lenses)
        │         ▼
        │         back to Pattern 2 (match → refute → recompute)
        └── NO  → JUDGMENT: ESCALATED ⚠️ (report to user with full history)
```

Only **Fix Agent** runs count against the 2-iteration cap. Refutation batches and the user decision gate never consume an iteration.

---

## Portability — Native Sub-Agent Mechanism

judgment-day is harness-agnostic. It needs three primitives from the host: **launch a sub-agent with a prompt**, **run two of them without cross-contamination**, and **read each result**. Bind these to whatever the host provides:

| Host harness | Launch (parallel) | Read result | Notes |
|--------------|-------------------|-------------|-------|
| Claude Code | native `Task`/`Agent` (two in one turn) | returned inline | parallel by default |
| OpenCode | `delegate()` (async) | `delegation_read()` | see example binding below |
| Codex / Gemini CLI / Copilot / others | native sub-agent/subtask if present | inline | if no parallelism → sequential fallback |
| No sub-agent mechanism at all | sequential fallback | inline | one judge at a time |

**Sequential fallback (required when the host lacks parallel sub-agents)**:
run Judge A to completion, then Judge B, then (if needed) the Refuter. Blindness is preserved by **never** passing Judge A's findings into Judge B's prompt — the only cost is latency, not correctness. The matching, refutation, approval, and iteration-cap logic are identical regardless of parallel vs. sequential launch.

### Example binding: OpenCode

```
# Launch both judges asynchronously (parallel, blind):
handle_a = delegate(prompt = judge_prompt_A)   # Correctness & Security lens
handle_b = delegate(prompt = judge_prompt_B)   # Regressions & Resilience lens

# Collect results once both finish:
findings_a = delegation_read(handle_a)
findings_b = delegation_read(handle_b)

# Refuter (only if blocking suspects/contradictions exist):
handle_r = delegate(prompt = refuter_prompt)   # read-only
verdicts  = delegation_read(handle_r)
```

`delegate()` / `delegation_read()` are **one example binding**, not a requirement. Any harness's equivalent launch/read primitives satisfy the protocol.

---

## Sub-Agent Prompt Templates

### Judge Prompt (shared skeleton — inject a distinct lens per judge)

```
You are an adversarial code reviewer. Your ONLY job is to find problems.
You do NOT approve, certify, or bless code — you return findings only.

## Target
{describe target: files, feature, architecture, component}

## Primary Lens
{inject ONE of:
  Judge A → "Correctness & Security: prioritize logic errors, unhandled edge cases,
             error propagation, injection risks, auth/permission gaps, secret exposure."
  Judge B → "Regressions & Resilience: prioritize behavioral regressions, state and
             determinism, partial failures, integration/shell boundaries, performance,
             and adherence to project conventions."}
Lead with your primary lens, but do not ignore issues outside it.

{if compact rules were resolved in Pattern 0, inject the following block — otherwise OMIT this entire section}
## Project Standards (auto-resolved)
{paste matching compact rules blocks from the skill registry}

## Review Checklist (all judges cover these; your lens sets priority)
- Correctness: Does the code do what it claims? Are there logical errors?
- Edge cases: What inputs or states aren't handled?
- Error handling: Are errors caught, propagated, and logged properly?
- Performance: Any N+1 queries, inefficient loops, unnecessary allocations?
- Security: Any injection risks, exposed secrets, improper auth checks?
- Regressions & state: Any behavior change, non-determinism, or broken invariants?
- Naming & conventions: Does it follow the project's patterns AND the Project Standards above?
{if user provided custom criteria, add here}

## Return Format
Return a structured list of findings ONLY. No praise, no approval, no verdict.

Each finding, to make cross-judge matching deterministic:
- Severity: CRITICAL | WARNING | SUGGESTION
- File: repo-relative path/to/file.ext
- Location: line N (or enclosing symbol/function name if no single line)
- Category: correctness | security | performance | error-handling | regression | naming | other
- Claim: one sentence — what is wrong and why it matters
- Suggested fix: one-line description of the fix (intent, not code)

If you find NO issues, return an empty findings list:
FINDINGS: none

Always include at the end: **Skill Resolution**: {injected|fallback-registry|fallback-path|none} — {details}

## Instructions
Be thorough and adversarial. Assume the code has bugs until proven otherwise.
Report every issue you can substantiate. Do NOT decide whether the target passes —
that is the orchestrator's job. Do not summarize. Do not praise.
```

### Refuter Prompt (read-only adjudicator for suspects & contradictions)

```
You are a read-only refuter. You do NOT edit code. You adjudicate disputed findings
by inspecting the actual code and returning a verdict for each.

## Target
{same target description}

{if compact rules were resolved in Pattern 0, inject the following block — otherwise OMIT this entire section}
## Project Standards (auto-resolved)
{paste matching compact rules blocks from the skill registry}

## Disputed Findings (blocking severity only)
{paste the Suspect and Contradiction findings from the verdict synthesis, each with its
 file, location, category, and claim}

## For EACH disputed finding, return exactly one verdict:
- CONFIRMED  — reproduced/substantiated against the code (state the evidence: file:line + why)
- REFUTED    — not a real issue: false positive, already handled, or out of scope (state why)
- UNRESOLVED — genuinely needs a human decision (e.g., a contradiction you cannot settle) (state the open question)

## Return Format
| Finding (file:location — claim) | Verdict | Evidence / Reason |
|---------------------------------|---------|-------------------|

Do not introduce new findings. Adjudicate only the list above.

**Skill Resolution**: {injected|fallback-registry|fallback-path|none} — {details}
```

### Fix Agent Prompt

```
You are a surgical fix agent. You apply ONLY the confirmed blocking issues listed below.

## Confirmed Blocking Issues to Fix
{paste the Confirmed blocking set — matched-Confirmed plus Refuter-CONFIRMED promotions.
 This list is NEVER empty; if it were empty the orchestrator would not have launched you.}

{if compact rules were resolved in Pattern 0, inject the following block — otherwise OMIT this entire section}
## Project Standards (auto-resolved)
{paste matching compact rules blocks from the skill registry}

## Context
- Original review criteria: {paste same criteria used for judges}
- Target: {same target description}

## Instructions
- Fix ONLY the confirmed blocking issues listed above
- Do NOT refactor beyond what is strictly needed to fix each issue
- Do NOT change code that was not flagged
- Do NOT act on SUGGESTION-level or refuted findings
- After each fix, note: file changed, line changed, what was done

Return a summary:
## Fixes Applied
- [file:line] — {what was fixed}

**Skill Resolution**: {injected|fallback-registry|fallback-path|none} — {details}
```

---

## Output Format

```markdown
## Judgment Day — {target}

### Round {N} — Verdict

| Finding | Judge A (Corr/Sec) | Judge B (Reg/Res) | Severity | Classification | Refuter |
|---------|--------------------|-------------------|----------|----------------|---------|
| Missing null check in auth.go:42 | ✅ | ✅ | CRITICAL | Confirmed | — |
| Race condition in worker.go:88 | ✅ | ❌ | WARNING | Suspect (A only) | CONFIRMED |
| Naming mismatch in handler.go:15 | ❌ | ✅ | SUGGESTION | Suspect (B only) | — (advisory) |
| Error swallowed in db.go:201 | ✅ | ✅ | CRITICAL | Confirmed | — |
| Retry semantics in job.go:33 | ✅ | ❌ | WARNING | Suspect (A only) | REFUTED |

**Confirmed blocking set**: auth.go:42 (CRITICAL), db.go:201 (CRITICAL), worker.go:88 (WARNING — promoted by refutation)
**Advisory (non-blocking)**: handler.go:15 (SUGGESTION)
**Refuted / dropped**: job.go:33 (WARNING — false positive per refuter)
**Unresolved (needs human)**: none

### Fixes Applied (Round {N})
- `auth.go:42` — Added nil check before dereferencing user pointer
- `db.go:201` — Propagated error instead of silently returning nil
- `worker.go:88` — Guarded shared counter with a mutex

### Round {N+1} — Re-judgment
- Confirmed blocking set: empty → APPROVED

---

### JUDGMENT: APPROVED ✅
No confirmed blocking findings remain after refutation. Advisory SUGGESTIONs are listed
above and left to the author's discretion. The target is cleared for merge.
```

### Escalation Format (after 2 fix iterations)

```markdown
## Judgment Day — {target}

### JUDGMENT: ESCALATED ⚠️

After 2 fix iterations, the confirmed blocking set is still non-empty.
Manual review required before proceeding.

### Remaining Confirmed Blocking Issues
| Finding | Severity | Origin |
|---------|----------|--------|
| {description} | CRITICAL | Confirmed (both judges) / Refuter-CONFIRMED |

### History
- Round 1: {N} confirmed blocking (after refutation of {M} suspects)
- Fix 1: applied {list}
- Round 2: {N} confirmed blocking remain (after refutation)
- Fix 2: applied {list}
- Round 3: {N} confirmed blocking remain → escalated

Recommend: human review of the remaining confirmed blocking issues above before re-running judgment day.
```

---

## Language

- **Spanish input → Rioplatense**: "Juicio iniciado", "Los jueces están trabajando en paralelo...", "Los jueces coinciden", "Refutando hallazgos dudosos...", "Juicio terminado — Aprobado", "Escalado — necesita revisión humana"
- **English input**: "Judgment initiated", "Both judges are working in parallel...", "Both judges agree", "Refuting disputed findings...", "Judgment complete — Approved", "Escalated — requires human review"

---

## Rules

- The **orchestrator NEVER reviews code itself** — it only launches judges/refuter/fixer, matches results, and decides.
- **Judges never approve.** They return findings only; the APPROVED/ESCALATED decision is the orchestrator's, based on the Confirmed blocking set.
- **Approval criterion**: `JUDGMENT: APPROVED` iff **zero confirmed blocking findings remain after refutation** and no unresolved blocking contradictions. SUGGESTIONs never block.
- **Distinct lenses**: Judge A leads Correctness & Security, Judge B leads Regressions & Resilience — never launch two identical prompts. Complementary lenses make "Confirmed by both" statistically meaningful.
- **Deterministic matching**: classify findings by `(file, ±3-line/symbol location, normalized claim)`. On any doubt about whether two findings are the same, classify as **Suspect** — never silently Confirmed.
- **Suspect-only round → refutation, not a Fix Agent.** A round with zero Confirmed matches and only suspects goes through one read-only Refuter batch. Never delegate a Fix Agent with an empty list, and never burn a fix iteration on a no-op.
- **Refuter promotions and user promotions become Confirmed** — a suspect the Refuter or the user promotes joins the Confirmed blocking set and is eligible for the next Fix Agent.
- Judges are launched via the **host harness's native sub-agent mechanism**, blind and (preferably) parallel; use the documented **sequential fallback** when parallelism is unavailable, preserving blindness.
- The **Fix Agent is a separate delegation** — never use a judge or the refuter as the fixer.
- If user provides **custom review criteria**, include them in BOTH judge prompts (same criteria, distinct lenses preserved).
- If target scope is **unclear**, stop and ask before launching — partial reviews are useless.
- **Max 2 fix iterations.** Only Fix Agent runs count against the cap; refutation batches and the user decision gate do not. On the 3rd non-empty confirmed set, escalate with full report — do not loop forever.
- Always collect BOTH judges' findings before matching — never synthesize a partial verdict.

---

## Commands

```bash
# No CLI commands — this is a pure orchestration protocol.
# Execution happens via the host harness's native sub-agent mechanism
# (launch two blind judges → collect results → optional read-only refuter → fix agent).
# See "Portability — Native Sub-Agent Mechanism". OpenCode's delegate()/delegation_read()
# is one example binding, not a requirement; a sequential fallback covers harnesses
# without parallel sub-agents.
```
