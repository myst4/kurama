---
name: systemic-issue-triage
description: >
  Partition a batch of issues by ROOT CAUSE before any code is written, so N issues that
  share one cause get ONE fix instead of N patches. Applies the over-engineering test to
  every candidate fix (a fix that adds state, a flag, or a gate is redesigned; the right
  fix usually deletes), ranks solutions by what they remove, and audits every delegated
  worker's report as a claim rather than as evidence.
  Trigger: When the user says "triage these issues", "clasificá estos issues", "attack the
  backlog", "estos N issues", "root cause", "agrupá por causa raíz", or hands over two or
  more issues at once. The `sdd-new` brainstorm gate may also route here when a single
  request bundles several issues — one cycle per ROOT, not one per issue.
  Runs INLINE in the orchestrator.
license: MIT
metadata:
  author: kurama
  version: "1.0"
---

## What This Skill Is

A gate that runs **between** a batch of issues arriving and the first line of code. It
does not write code, open PRs, or close issues; it produces a partition — issues grouped
by the cause that actually produces them — and one fix design per group.

It exists because the default behavior is the wrong one. Handed eight issues, an agent
opens eight branches, writes eight patches, and each patch adds a guard for the case its
own issue described. The system ends up with eight new mechanisms and the same shared
cause still in it, now harder to see.

**One root, one fix.** N issues never justify N patches. Two issues that share a cause
are one unit of work that closes both, with the tests that prove each closure named.

### Not for

- A single issue with an obvious, local cause. Fix it — do not open a triage.
- Deciding *whether* to do the work. That is the brainstorm gate and the approval gate.
- Closing issues. Closure needs a merged fix and a named test; this skill produces the
  plan those come from.

---

## Step 1 — Read the issues, not the titles

Titles are the reporter's guess at the cause; bodies and comments are the evidence. For
each issue, read it in full and record its **symptom** — what the reporter observed —
separately from its **stated mechanism** — what they think caused it.

> The mechanism an issue names is a hypothesis. Only the symptom is evidence.

A report is routinely correct about the failure and wrong about the line. If you write a
test against the stated mechanism and it passes on an unmodified default branch, the
reporter is right and the diagnosis is wrong: keep pushing the test toward the real
surface, and say in the triage that you did.

Verify every "already fixed" and "still broken" claim against the current default branch
**today**. A reproduction filed before a fix merged is evidence about an old build.

---

## Step 2 — Assign every issue exactly one root class

| Class | Meaning | What it takes to leave the class |
|---|---|---|
| **A — Already resolved** | The mechanism no longer exists on the default branch | Name the commit **and** a test that fails against the old shape. "Should be fixed now" is not a class-A finding |
| **B — Shares a root** | Reproduced, and an existing root already produces it | Name the root it joins. It gets no fix of its own |
| **C — New root** | Reproduced, and no existing root produces it | Opens a new root row, with its own fix design |
| **D — Not a defect** | The behavior is working as designed and the request is for different behavior | Route to `sdd-new` as a feature, or decline with the reason written down |
| **E — Unreproducible** | The symptom cannot be reproduced from what the issue says | Ask the reporter for their exact input. Never guess a mechanism to make the issue actionable |

Rules that bind the classification:

- Every issue lands in exactly one class. An issue in two classes is two issues — split it,
  and say so in the thread rather than closing half of it silently.
- **Green tests plus a real-world failure means a test was taught to agree.** Check whether
  the commit that introduced the defect also changed a fixture, a helper, or a test row so
  the broken shape stopped being asserted. Remove that row rather than adding a second test
  beside it.
- One thread carrying two failure modes closes when both are addressed, not when the louder
  one is. Comment naming both and what each is waiting on.

---

## Step 3 — The over-engineering test (blocking, before any fix is designed)

Ask five questions of the candidate fix. **Any yes rejects the design as written.**

1. Does it introduce a new **state** the system must now track?
2. Does it introduce a new **flag**, option, or config key?
3. Does it introduce a new **gate** — a block, a refusal, a precondition?
4. Does it introduce a new **verb** or command surface?
5. Does it create a **second representation** of a fact the system already stores?

A rejected design is not abandoned; it goes back one step with a different question:
*what could be deleted or relaxed so this failure stops being possible?*

> The correct fix usually **deletes**. A fix that only adds is a fix that has not found
> the cause yet — it has found a place to stand between the cause and the symptom.

Two corollaries worth naming, because they are where the temptation is strongest:

- A refusal that leaves the user with nowhere to go is a **message** defect. The fix is to
  name a runnable next command in the message — verified by running it — not to build
  machinery that handles the case.
- A wrong exit is worse than a missing one. A dead end tells the user to stop; advice that
  does not work sends them in circles blaming themselves.

---

## Step 4 — Rank the candidate solutions by what they remove

For each root, write the candidates down and rank them. Higher is better, and "better"
means *less system left afterwards*.

| Rank | Shape | Why it wins |
|---|---|---|
| 1 | **Delete the mechanism** | The whole failure class becomes impossible, and there is less to maintain than before |
| 2 | **Relax an over-strict rule** | The failure stops being a failure. Nothing new is added |
| 3 | **Fix one predicate at one site**, behind a test that fails before it | Bounded, provable, adds no surface |
| 4 | **Add a static guard** so reintroduction is a test failure | Adds a test, not a runtime mechanism |
| 5 | **New runtime surface** — a flag, a state, a gate | Last resort. Requires a written reason why 1–4 could not work |

A fix at rank 5 with no written justification is not ready to implement. Report the net
line delta per fix batch: a triage whose batches are all net-positive did not find roots,
it found places to add code.

---

## Step 5 — Audit every worker's report

Kurama delegates every phase to a sub-agent whose transcript the orchestrator never sees.
What comes back is a **claim**. It is not evidence, and it does not become evidence by
being confident, detailed, or formatted like a report.

For each worker report, before it is allowed to advance anything:

- **Re-run its verification yourself.** A report that does not name a command you can
  re-run has reported nothing. Run the command; read the output.
- **Read the diff it produced**, not the summary of the diff.
- **Break its new guard on purpose.** A guard that does not fail when you plant the shape
  it forbids is not a guard, and its passing test proves nothing.
- **Re-derive the numbers.** Counts, totals, and "all tests pass" are claims too.
- **A "fixed" claim closes nothing** until the original issue's exact scenario is
  reproduced against a fresh build and fails to reproduce.

A report you did not verify is a report you are forwarding, not accepting.

---

## Step 6 — Output

Report, in this order:

1. **Class counts** — how many issues in A, B, C, D, E.
2. **Per-issue table**: issue | class | root it belongs to | the evidence that placed it there.
3. **Per-root table**: root | issues it closes | the fix's rank from Step 4 | the tests that will prove each closure | expected net line delta.
4. **Rank-5 justifications**, one paragraph each, or the statement that there are none.
5. **Open questions for the human** — what could not be classified and what is needed to classify it.

Then hand off: **one `sdd-new` cycle per root**, carrying the issues that root closes.
Never one cycle per issue — that is the shape this skill exists to prevent.
