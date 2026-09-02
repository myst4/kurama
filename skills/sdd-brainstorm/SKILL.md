---
name: sdd-brainstorm
description: >
  Turn a vague request into a decision ledger and one recommended approach, through an
  interview that explores the codebase before it asks the human anything the repo can answer.
  Asks ONE question per turn with a marked recommendation, and records a decision nobody made
  as `deferred` instead of inventing it. Runs INLINE in the orchestrator.
  Trigger: When the user says "brainstorm", "grill me", "stress-test this plan",
  "hagamos brainstorming", "no sé bien qué quiero", or when the `sdd-new` brainstorm gate
  classifies a request as vague and the user chooses to brainstorm.
license: MIT
metadata:
  author: kurama
  version: "1.0"
---

## What This Skill Is

`sdd-brainstorm` is a **meta-skill**: like `sdd-new`, and unlike every SDD phase skill, it
describes **orchestrator** behavior. It is the second deliberate exception to the executor rule,
for a harder reason than `sdd-new`'s — this skill is **dialogue**. Its core mechanic is asking
one question and waiting for a human to answer it. A sub-agent has no human on the other side,
so delegating this skill does not degrade it, it makes it impossible. **Run it inline. Never
launch it as a sub-agent, and never let a phase agent run it.**

It is reached two ways: from the brainstorm gate in `sdd-new` (step 1.5), or by natural trigger
mid-session. Either way its output is the same and it goes to the same place — the SDD pipeline.

*Classifying the request out loud, the one-way ratchet, the decomposition-first check and the
shape of an anti-rationalization red-flags table are adapted from superpowers' `brainstorming`
skill (MIT, Jesse Vincent). Everything else here is Kurama's own.*

## What It Produces, and What It Must Never Produce

**Produces:** one artifact — the **decision ledger** — plus a recommended approach stated in the
conversation. That is the whole output.

**Never produces**, whatever the conversation seems to justify:

- code, of any size, including "just a sketch";
- a spec, a proposal, a design, or a task list — those are `sdd-spec`, `sdd-propose`,
  `sdd-design` and `sdd-tasks`, and writing them here creates a second source of truth beside
  `openspec/`;
- a design document under `docs/` or any parallel spec tree;
- an invocation of any implementation skill.

**SDD owns the work lifecycle.** The next step after this skill is always the SDD pipeline —
explore → propose. There is no other exit.

## The Hard Gate

Nothing is written except the ledger until the user has approved a direction. The ceremony
scales with the request; the gate never does. A two-sentence recommendation still gets its yes
before anything downstream runs.

## Step 0 — Explore before you ask

**Never ask the human what the repo can answer.** This is the rule that separates this skill
from an interview form, and it comes BEFORE the first product question, not after it.

- **Light context (default).** Read 1–3 files to orient — the entry point, the module the
  request names, the existing flow. That is the delegation table's read-to-decide allowance, so
  it stays inline.
- **When orienting needs 4+ files**, delegate `sdd-explore` as a **standalone** exploration (no
  change name, report-only — it must NOT write `exploration.md`, or it collides with the phase
  exploration that runs later). Say you are doing it, wait for the report, then start asking.
- **Mid-interview, the same rule holds.** If the next question is answerable from the code,
  answer it yourself and record the row as `resolved` with the file and line as its source. A
  question the code answers spends the user's turn and teaches them nothing.

**What exploration can never answer**, and therefore what the questions are for: intent,
priority, what "done" means, which trade-off the user prefers, and what is deliberately out of
scope. Everything else, go read.

## Step 1 — Classify, out loud

Say the classification and the reason in one line, so the user can override it:

| Reading | SDD shape | Means |
|---|---|---|
| **spike** | standalone `sdd-explore` | a feasibility question whose output is an answer, not code you keep |
| **bounded** | `small` | a scoped change to a flow that already exists in this repo and can be read |
| **architectural** | `standard` | a new subsystem, a changed interface others depend on, or a restructure |

Two rules bind it. **In doubt, take the heavier reading.** And the **ratchet is one-way**:
complexity discovered mid-interview upgrades the classification — stop, say so, append the
upgrade and its trigger to the ledger. Nothing ever downgrades mid-interview.

Familiarity is not boundedness. `bounded` measures what is in the repo, not what you recognize.

## Step 2 — Decomposition check

**This runs before any refining question**, and it is checked, never assumed.

If the request spans independent subsystems ("a platform with billing, chat and analytics"),
do not spend questions on the details of something that needs splitting first. Present the
pieces, how they relate, and the order you would build them; ask which one this cycle takes.

The pieces not taken are recorded in the ledger as named follow-ups — they are deferred work,
not dropped work. Each gets its own cycle later.

If it is genuinely one subsystem, write `single subsystem — no split` in the ledger and move on.
An unchecked box is not a checked one.

## Step 3 — The interview

### How to ask

- **One question per turn. Then STOP and wait.** Never stack two questions, never ask a second
  before the first is answered, never ask and answer in the same message, and never continue on
  an answer you assumed rather than heard.
- **Options ONLY at a real fork.** When the question is a choice between approaches that carry
  trade-offs, give **2–4 concrete options** — the answers a person would realistically give,
  never a bare yes/no — and mark exactly one **(recommended)** with a one-line reason. When the
  question is genuinely open — *"what does done look like here?"*, *"what hurts about it today?"*
  — **ask it open.** Manufacturing a menu for an open question narrows the answer to whatever
  you happened to think of, which is the opposite of what an open question is for. A menu is not
  a sign of rigor; a recommendation at a real fork is.
- **Use the harness's native question primitive when the question has options** so they render
  as a real prompt: on Claude Code the `AskUserQuestion` tool, on OpenCode the `question` tool.
  On a harness with no such primitive, a lettered list (A/B/C) in chat. An open question is
  plain prose. Either shape stops and waits identically — never paste a question and keep
  talking.
- **Verify a premise before you build on it.** A request that asserts something about the
  codebase — *"the cache is invalidated on write"*, *"this endpoint has no auth"* — is a claim,
  not a given. Check it against the code first and say what you found. Agreeing with a wrong
  premise does not cost one question, it costs the whole round, because every question after it
  rests on it.
- **Offer alternatives whenever a real one exists.** If two approaches are both defensible, that
  is a fork and it gets its options and its trade-offs. If there is only one sane path, say so
  and move on — inventing a second to look balanced is the same failure as manufacturing a menu.
- **Match the user's language** for the question and the option labels — this is orchestrator
  conversation. The ledger is a technical artifact and stays in neutral English. That split is
  the Language Domain Contract; do not collapse it in either direction.
- **Acknowledge in 1–2 sentences, then ask the next one.** No recaps between questions.

### In what order

Walk the decision tree in dependency order: **do not ask B until A is settled**, because A's
answer usually changes what B's options even are. Asking "which cache backend?" before "does
this need to survive a restart?" wastes both turns.

The dimensions are adaptive, not a script. What usually needs settling, roughly in this order:
the objective, the observable success criterion, the scope boundary (what is explicitly out),
the hard constraints, the failure mode that would matter most, and the trade-off preference
when two approaches are both defensible.

**YAGNI applies to the questions too.** A dimension the change does not touch is not a branch;
do not open it to look thorough.

### How many

**Aim for three or four.** That is what a properly explored vague request actually needs, and it
is the shape a good brainstorm has. The governing rule is not a count, it is this: **every
question must resolve a named branch of the ledger — if you cannot name the branch it resolves,
do not ask it.**

Explore-before-ask is what makes three or four enough. Every question the repo could have
answered is a question you never had to spend.

Padding a round toward the cap below is the same failure as stopping early: both spend the
human's attention on something other than the fork.

### After each answer

Update the ledger before asking the next question. The ledger is the state of this
conversation — if it is not in the ledger, it did not happen.

## The Decision Ledger

Every branch carries one of four states. They are the whole point of this skill:

| State | Meaning | Rule |
|---|---|---|
| `resolved` | the user decided it, or the code answered it | record the answer AND its source |
| `open` | raised, not answered yet | may not survive into the terminal state — resolve it or defer it |
| `contradicted` | two answers conflict | record BOTH, in order; the next question is which one holds |
| `deferred` | nobody decided, and we are proceeding anyway | MUST carry a reason and the consequence if the guess is wrong |

`contradicted` is a state, not a tiebreak: a later answer does not silently overwrite an
earlier one. `deferred` is the anti-invention device — it is where a decision goes when nobody
made it, and it is the alternative to filling the blank in yourself.

### Shape

Write it exactly like this, in neutral English:

```markdown
# Brainstorm: {Change Title}

## Request

{the user's original wording, verbatim and unedited — including the issue body when the
request named an issue}

## Classification

{spike | bounded | architectural} → {standalone explore | small | standard} — {one-line reason}

{each ratchet upgrade appended as its own line: what was discovered, and the new reading}

## Decomposition

{`single subsystem — no split`, or: the pieces, how they relate, the order, which one this
cycle takes, and each piece NOT taken as a named follow-up}

## Decisions

| # | Branch | State | Answer | Source |
|---|--------|-------|--------|--------|
| D1 | {the question, one line} | resolved | {what was decided} | user · {ISO date} |
| D2 | {the question, one line} | resolved | {what the code says} | code · `path/to/file:120` |
| D3 | {the question, one line} | contradicted | {first answer} → {second answer} | user · {ISO date} |
| D4 | {the question, one line} | deferred | not decided — {reason}; if wrong: {consequence} | — |
| D5 | {the question, one line} | open | — | — |

## Assumptions

- A1 — {statement} · acting on it because {why} · breaks if {what would falsify it}

## Constraints

- C1 — {statement} · source: {user | code `path` | external}

## Success Criteria

- {criterion} · observed by {how you would check it}
- `assumed:` {criterion} — nobody confirmed this; carried into the proposal's open questions

## Recommended Approach

{2–3 sentences. The recommendation only. The alternatives and their trade-offs stay in the
conversation and reach `sdd-explore` as the topic to investigate — this is not a design.}

## Readiness

{ready | ready-with-deferrals | blocked} — {the sentence from the readiness test}
```

### Ledger rules

- **IDs are stable.** Never renumber. A decision that changes keeps its ID and changes state.
- **Never delete a row.** A branch that turns out irrelevant becomes `deferred`, with that as
  its reason. A deleted row is a decision that silently stopped existing.
- **Never invent a value to fill a field.** An empty answer with state `deferred` is correct;
  a plausible answer with state `resolved` is the failure this artifact exists to prevent.
- **Neutral English**, whatever language the interview was conducted in.

## The Readiness Test

This skill stops on a test, not on exhaustion. **Interviewing relentlessly is a failure mode,
not a virtue** — it burns the user's attention on branches that do not change the first
approach.

The interview is over when EVERY branch is one of:

1. **resolved** — decided by the user or answered by the code;
2. **deferred** — with a stated reason and the consequence if the guess is wrong;
3. **blocked on information that does not exist in this conversation** — name exactly what is
   missing and who or what has it (a teammate, a production metric, a vendor's docs).

Then say which of the three ended it, in one line, and write it into `## Readiness`. If any
branch is still `open`, the interview is NOT over — resolve it, or make deferring it an
explicit choice.

### The round cap — a hard stop at seven

**After roughly seven questions in one round, STOP. Do not ask an eighth.** Show the ledger as it
stands — every branch with its state, and the still-`open` ones named, so the choice is
informed — and ask ONE question:

> Seven decisions in: {N} resolved, {M} still open ({name them}). → **Proceed to explore →
> propose with the rest deferred (recommended when nothing open blocks the first approach)** /
> Keep going, another round.

If the user chooses to continue, the next round runs under exactly the same rule: up to seven,
then the same stop, with the ledger shown again.

**Why the cap is a stop and not a suggestion.** A round that never pauses is grill-me's failure
mode — it interviews relentlessly, and the human loses the shape of the conversation and cannot
tell how much is left. Seven is the pause where the ledger is shown and the human steers.

**Seven is the ceiling for a tangled request, never the target.** An ordinary vague issue should
reach the readiness test around the third or fourth answer and stop there. A round that hits
seven is a signal the request is genuinely knotted — or that questions were asked which resolved
no branch.

Running out of ideas is not readiness. A branch you did not think to ask about is `open`; if
you end the round anyway, it is `deferred` with *not explored* as its reason.

## Persistence

The ledger is one file, mechanical, and fully specified by the time it is written — the
delegation table's atomic-write allowance, so it is written **inline**.

**Where**, by artifact store mode:

- **engram** — `mem_save` with title and `topic_key` both `sdd/{change-name}/brainstorm`,
  `type: architecture`, `scope: project`. The stable key upserts, so re-writing the ledger
  updates it in place instead of stacking copies.
- **openspec** — `openspec/changes/{change-name}/brainstorm.md`. Create the change directory
  first if it does not exist.
- **hybrid** — both. The file is authoritative; Engram mirrors it.

**When**: once at the terminal state, and once at each round cap the user chooses to continue
past — a checkpoint, so a compaction mid-interview does not cost the round. Not per answer:
between those points the working ledger lives in the conversation.

**Change name.** The ledger's key needs one. Reached from `sdd-new`, it is already given.
Reached by natural trigger, propose a kebab-case slug from the request and confirm it in the
same turn as the terminal state, before the write — never burn an early question on naming.
When the round is issue-linked — a kanban card, or a request that named an issue (`#N`, a
GitHub URL) — that name is **`{issue}-{slug}`**: `22-nodemaven-gateway-provider`. The ledger's
key is the first artifact keyed by it, and every artifact after it inherits the same string, so
the number has to be there before the write. Prefix a slug the user gave rather than replacing
it. **No issue in play** → the plain `{slug}`, unchanged.

## Handing Off

The terminal state is: the ledger persisted, and the recommended approach stated. Then control
returns to the orchestrator, which continues `sdd-new` at Explore. **This skill does not invoke
the next phase itself.**

The ledger travels **by reference** — the topic key or the path, never its body pasted into a
sub-agent prompt.

- `sdd-explore` receives it as OPTIONAL upstream context: the resolved decisions are the frame
  for the investigation, and the deferred ones are things worth looking into before asking again.
- `sdd-propose` maps `resolved` decisions into intent and scope, and `deferred` ones into risks
  and open questions — named as deferred, never quietly promoted to resolved.

An absent ledger is normal — a clear request never had one — and never blocks a downstream
phase.

## When the Request Came From an Issue

Most vague requests arrive as an issue on a board — that is where the `sdd-new` brainstorm gate
read the body from before it classified anything. When this round started there, **offer** one
thing at the terminal state, after the ledger is final and never before:

> The ledger is done. Want me to post a short **Decisions** comment on #{N}? It names what was
> resolved, what stayed deferred, and the change name. → **Post it (recommended)** / Skip

**It is an offer, it is approval-gated, and it is never automatic — `auto` included.** Commenting
on a tracker is an outward-facing write to something other people read; it needs an explicit yes
every time.

On a yes, post it with `gh issue comment {N}` and keep it short: the change name, each resolved
decision as one line, each deferred one named **as deferred** with its reason, and nothing else.
No ledger dump, no approach write-up, no spec content.

**The direction of truth is fixed and it only goes one way.** The issue is the ticket; the
`openspec/` artifacts (or their Engram equivalents) are the truth. The comment is a POINTER from
the ticket to the artifact, so a teammate reading the board knows a decision round happened and
where it lives. The spec is never updated to match a comment, and a comment is never an input to
a later phase.

## Red Flags

| Thought | Reality |
|---------|---------|
| "I'll fill in a success criterion, it's obvious" | That is exactly the invented criterion the ledger exists to prevent. Nobody decided it → `deferred`, and it reaches the proposal as an open question. |
| "The request is vague, so I'll ask what they want" | Explore first. A question asked with no context is one the human has to answer twice, and the second time is your fault. |
| "Their answer was close enough — I'll record it as resolved" | Close enough is `open`. Record what they actually said, and make the difference the next question. |
| "They contradicted themselves; the later answer obviously wins" | `contradicted` is a state, not a tiebreak. Both answers go in the row, and which one holds is a question, not an inference. |
| "It's one feature, decomposition doesn't apply" | Decomposition is checked, not assumed. Write `single subsystem — no split` and move on; an unchecked box is not a checked one. |
| "Seven questions and it's still fuzzy — one more round will do it" | The cap is a stop, not a suggestion. Present the ledger and let the user choose the round. |
| "The direction is clear now, I'll start the spec while it's fresh" | The gate is the approval, not the clarity. The only thing this skill writes is the ledger. |
| "We designed something good — it should be written down properly" | It is: in the ledger, then in `proposal.md`. A design doc here is a second source of truth beside `openspec/`, which is the collision this skill was built to avoid. |
| "They said 'whatever you think' — that settles it" | That settles WHO decides, not WHAT. Record your call as an assumption, with what breaks if it is wrong. |
| "This is too small to need a ledger" | Small means a three-row ledger, not no ledger. What scales with the request is the artifact, never the gate. |
| "It's an open question, but a menu looks more rigorous" | A menu answers for them. Options belong to forks with trade-offs; an open question is asked open, or you only ever learn what you already thought of. |
| "They said the write path invalidates the cache, so I'll build on that" | A premise is a claim. Check it in the code before the next question rests on it — agreeing with a wrong one costs the whole round, not one question. |
| "Four questions in and it's resolved — I should dig deeper to be thorough" | Three or four IS the shape when exploration did its job. Asking a fifth that resolves no branch is padding, and the cap is a ceiling, not a target. |
| "I'll just add a Decisions comment on the issue, it's helpful" | Writing to a tracker other people read is outward-facing. Offer it, get the yes, then post — in `auto` too. |

## Rules

- Run INLINE. Never delegate this skill; never let a phase agent run it.
- One question per turn, then STOP and wait. Never ask a second before the first is answered,
  and never continue on an answer you assumed rather than heard.
- Options (2–4, exactly one marked **(recommended)**) ONLY at a real fork with trade-offs. A
  genuinely open question is asked open — never manufacture a menu.
- Offer alternatives with their trade-offs whenever a real alternative exists; never invent one
  to look balanced.
- Never accept a premise about the codebase without checking it against the code first.
- Never ask what the repo can answer — explore first, and mid-interview too.
- Aim for 3–4 questions. Every question must name the ledger branch it resolves; if it resolves
  none, do not ask it. **Seven is the hard stop for one round** — show the ledger and ask.
- A decision nobody made is `deferred` with a reason, never filled in.
- Questions in the user's language; the ledger in neutral English.
- Never write code, a spec, a proposal, a design, a task list, or any document other than the
  ledger; never invoke an implementation skill.
- Stop on the readiness test; at the round cap, stop and ask instead of continuing.
- A **Decisions** comment on the originating issue is OFFERED and approval-gated, never
  automatic — the issue points at the spec, never the reverse.
- The ledger travels downstream by reference, never inlined.
