---
name: skill-creator
description: >
  Author a new Kurama skill so the harness actually loads it: frontmatter the registry can
  index, a manifest group, an AGENTS.md row, and a mutation-checked regression in the suite.
  Covers the executor/orchestrator split and the four phase contracts a sub-agent skill must
  honour, and refuses the two shapes that never belong in this repo.
  Trigger: When someone asks to add a skill, write a SKILL.md, turn a convention into
  something sub-agents load, "crear una skill", or extend Kurama with a new capability.
license: MIT
metadata:
  author: kurama
  version: "2.0"
---

## The bar a skill has to clear

A skill earns its place only when **a sub-agent that never read this conversation would get the
work wrong without it**. That is the whole test, and it is deliberately harsh: every installed
skill is a file the registry indexes, the validator lints, the suite pins, and somebody has to
keep true five releases from now.

Three shapes fail the bar and get refused out loud, with the reason:

| Shape | Why it is refused | Where it belongs |
|---|---|---|
| Knowledge one ecosystem already has | Kurama carries no language knowledge — that was `go-testing`'s removal in #125 | The user's own skills tree, found by the registry |
| A restatement of something already shipped | Two files stating one rule drift, and the drift is silent | Edit the file that owns the rule |
| A single job that will run once | A skill is a standing instruction, not a task | Just do the job |

The counter-test is equally short: name the sub-agent, the phase, and the mistake it makes
today. If you cannot fill all three slots, you are documenting, not writing a skill.

## Frontmatter is the interface, not decoration

`skills/_shared/build-skill-registry.sh` reads exactly two keys out of your file — `name` and
`description` — and splits the description on the literal `Trigger:` marker. Nothing in the body
is indexed. **The `Trigger:` half is therefore the entire surface by which your skill gets
found** (#106): a sub-agent scanning the registry matches on that text and on nothing else, so a
vague trigger is not a small documentation flaw, it is a skill that never loads.

```yaml
---
name: <dir-name, lowercase, hyphens, identical to the directory>
description: >
  <What it does, stated as a capability, in one or two sentences.>
  Trigger: <The words and situations that should pull this in — real phrasings, including
  the ones your users actually type, in whatever language they type them.>
license: MIT
metadata:
  author: kurama
  version: "1.0"
---
```

Every field above is mandatory in this repo. `license: MIT` and `metadata.author: kurama` are
not stylistic — the suite asserts both across the whole tree, because a foreign licence tag on a
file we wrote is a claim about provenance that is simply false. Write real trigger phrasings,
not categories: `"report this upstream", "reportá esto a kurama"` beats "when reporting bugs",
and the second one loses to a competing skill every time.

## Executor or orchestrator — decide before the first heading

Almost every skill here is read by a **sub-agent** that was launched to do one phase and returns
an envelope. The executor boundary in `skills/_shared/sdd-phase-common.md` binds it: do the work
yourself, launch nothing, delegate nothing.

Two skills are exceptions, and both say so in their own first paragraph. `sdd-new` describes
orchestrator behaviour, and `sdd-brainstorm` runs inline because its mechanic is asking a human
one question and waiting — delegating it does not weaken it, it removes the human and makes it
impossible. **Adding a third exception is a design decision, not a formatting one.** If yours
really is orchestrator-side, state it in the opening lines the way those two do, so nobody
launches it as an agent and gets silence back.

An executor skill must leave the four shared contracts intact, and the way to leave them intact
is to point at them rather than restate them:

| Section | What it governs | Your skill's job |
|---|---|---|
| **A. Skill Loading** | How the agent resolves `## Project Standards`, then `SKILL: Load`, then the registry | Nothing — never describe a fifth resolution order |
| **B. Artifact Retrieval** | Reading prior artifacts in Engram mode, and what a retrieval failure means | Name which artifacts you need, not how to fetch them |
| **C. Artifact Persistence** | Writing the phase output in `engram` / `openspec` / `hybrid`, plus cycle markers | Name what you write; the mode is not yours to choose |
| **D. Return Envelope** | The single return contract — `status`, `executive_summary`, `artifacts`, `next_recommended`, `risks`, `skill_resolution`, closing `key_learnings` | Put your own report format inside `detailed_report`; never define a second envelope |

Section D wins over any per-skill summary wording. A skill that invents field names produces
envelopes the gatekeeper cannot validate in `auto` mode.

## The Language Domain Contract cuts through your skill too

The orchestrator answers in the language the user writes in, and generated artifacts stay in
neutral English — specs, tasks, code, comments, commit messages, and every delegated phase
output. Write your skill's body in English, and when it tells an agent to *say* something to the
user, say that the wording is re-expressed in the user's language before it is shown. Hardcoding
an English sentence for the user to read is how the contract gets broken by accident.

## Wiring it in — four files, all of them required

A skill nobody installs is a file in a repository.

1. **`skills/<name>/SKILL.md`** — the file itself. One directory, one skill; the directory name
   and the `name:` key must agree.
2. **`skills/manifest.json`** — add `{"name": "<name>", "group": "<group>"}`. The installers read
   this instead of a hardcoded list, so an unlisted skill is never copied anywhere. Groups:
   `sdd-core` (mandatory, cannot be dropped), `quality`, `review`, `optional`, `tdd` — all four
   optional ones ship by default and are dropped with `--without <group>`. Put a skill in
   `optional` when a user could reasonably want the path to stop existing; `#125` removed the
   only group that was off by default, so there is no longer a way to ship a skill nobody gets.
3. **`AGENTS.md`** — one row in the skills table: `` | `<name>` | <when it fires> | [path] | ``.
   The validator's AGENTS.md coverage check reads this, and the row's middle column is what a
   human scanning the index sees, so write the trigger, not the summary.
4. **`scripts/install_test.sh`** — a regression that fails without your change. Details below.

Then run both gates before you claim it works:

```bash
bash scripts/validate_skills.sh    # fence closed, name/description present, manifest + AGENTS.md coherent
bash scripts/install_test.sh       # the whole suite, not just your section
```

`validate_skills.sh` reports every problem in one pass rather than stopping at the first, so read
the full output. The frontmatter fence is the check people trip: an opening `---` that never
closes means the parser reads your entire document as YAML, and "the keys are in there
somewhere" does not save it.

## The test, and why a passing test is not enough

Tests live in lettered sections named after the issue that produced them —
`# ===== UNIT-Z (issue #125) =====` — with every helper and case prefixed by that letter
(`z_make_fixture`, `test_z_…`). Pick the next free letter, add your cases, and register each one
with `run_test "<what it proves>" test_<letter>_<name>`.

**Every case must be mutation-checked.** Materialize the tree as it was before your change and
run the same assertion against it:

```bash
git archive origin/main | tar -x -C "$(mktemp -d)"
```

The case has to FAIL there. Then say in the section's comment block *which* wrong reason each
case rules out — a test that passes on the old tree pins nothing, and one that fails there for
an unrelated reason (a missing fixture, a path typo) is worse, because it looks like coverage.
Note that CI checks out at depth 1: `origin/main` is not a ref at test time, so assert the new
behaviour directly and record the mutation result in the comment.

## What never goes in the orchestrator prompt

**Your skill does not get a slash-command line.** The five generated prompts under `examples/`
share a hard 24000-byte budget the suite enforces, and `omp` sits at 23965 — thirty-five bytes
of headroom for all five harnesses combined. A command line costs more than that, so skills are
reached by their trigger text through the registry, exactly as the frontmatter section describes.
The files under `examples/` are generated by `scripts/build-examples.sh` from
`examples/_templates/` anyway; editing a generated prompt is reverted the next time anyone builds.

## Before you say it is done

- [ ] The bar is cleared: sub-agent, phase, and today's mistake all named
- [ ] `Trigger:` lists phrasings a real user types, not a category
- [ ] `license: MIT` and `metadata.author: kurama` present
- [ ] Executor or orchestrator stated, and Sections A–D pointed at rather than restated
- [ ] Manifest entry with a group, and an AGENTS.md row
- [ ] A lettered test section whose cases fail on the materialized pre-change tree
- [ ] `validate_skills.sh` and the full suite both green, with the suite's new total reported
- [ ] Nothing added to `examples/` — not a command line, not a byte
