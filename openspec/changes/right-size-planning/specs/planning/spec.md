# Delta for Planning

## ADDED Requirements

### Requirement: Change Size Classification

`sdd-propose` MUST classify every change as `small` or `standard` and record the
classification, with its rationale, in `proposal.md` under a `## Change Size` heading.

The classification MUST be an explicit judgement against stated criteria, never a silent
heuristic. A change MUST be classified `small` only when ALL of the following hold:

- it touches a single domain;
- it introduces no new or changed public contract (API, config schema, phase contract);
- it requires no data or configuration migration;
- it adds no new dependency;
- it does not modify a phase contract or the canonical DAG.

When any criterion fails, or when the classifier is uncertain, the change MUST be
classified `standard`.

#### Scenario: [S-size-1] A small change is classified and recorded

- GIVEN a change that adds one optional flag to a single existing script
- AND it introduces no new public contract, migration, or dependency
- WHEN `sdd-propose` runs
- THEN `proposal.md` MUST contain a `## Change Size` section stating `small`
- AND the section MUST state which criteria were evaluated

#### Scenario: [S-size-2] Ambiguity resolves to standard

- GIVEN a change whose blast radius cannot be determined from the available context
- WHEN `sdd-propose` classifies it
- THEN the recorded size MUST be `standard`
- AND the rationale MUST name the unresolved ambiguity

#### Scenario: [S-size-3] Contract changes are never small

- GIVEN a change that modifies any phase's SKILL.md contract or the canonical DAG
- WHEN `sdd-propose` classifies it
- THEN the recorded size MUST be `standard` regardless of its line count

### Requirement: Collapsed Planning Artifacts For Small Changes

When a change is classified `small`, `sdd-propose` MUST emit a `## Spec (inline)` section
and a `## Design (inline)` section inside `proposal.md`.

The inline spec MUST use the same RFC 2119 + Given/When/Then form as a standalone delta
spec, so that `sdd-archive` can merge it into the main specs unchanged. The inline design
MUST state the architectural decisions and the files affected.

Collapsing MUST NOT omit an artifact. A `small` change produces the same information as a
`standard` one; it produces it in one document instead of three.

#### Scenario: [S-collapse-1] Downstream phases accept the collapsed inputs

- GIVEN a `small` change whose `proposal.md` carries inline spec and design sections
- WHEN `sdd-tasks` runs
- THEN it MUST NOT return `blocked` for a missing spec or design
- AND it MUST produce `tasks.md` from the inline sections

#### Scenario: [S-collapse-2] The delta spec still reaches the source of truth

- GIVEN a `small` change that has passed `sdd-verify`
- WHEN `sdd-archive` runs
- THEN it MUST merge the inline delta spec into the main specs
- AND the merged result MUST be indistinguishable from a standalone delta spec merge

#### Scenario: [S-collapse-3] A malformed inline spec blocks rather than corrupting

- GIVEN a `small` change whose inline spec section is missing or has no requirements
- WHEN `sdd-archive` runs
- THEN it MUST return `blocked` naming the missing delta spec
- AND it MUST NOT merge a partial result into the main specs

### Requirement: Orchestrator Honors The Recorded Size

`sdd-new`, `sdd-ff`, and `sdd-continue` MUST read the recorded size and sequence phases
accordingly: `standard` runs `explore → propose → (spec ‖ design) → tasks`, and `small`
runs `explore → propose → tasks`, skipping the separate `sdd-spec` and `sdd-design`
delegations.

An absent or unrecognized size value MUST be treated as `standard`.

#### Scenario: [S-seq-1] A standard change sequences exactly as before

- GIVEN a change recorded as `standard`
- WHEN the orchestrator sequences the planning phases
- THEN it MUST delegate to `sdd-spec` and `sdd-design` as it does today

#### Scenario: [S-seq-2] A missing size falls back to the long path

- GIVEN a change whose `proposal.md` has no `## Change Size` section
- WHEN the orchestrator sequences the planning phases
- THEN it MUST treat the change as `standard`
- AND it MUST NOT fail or block on the missing classification

## MODIFIED Requirements

### Requirement: Design Phase Dependencies

The `sdd-design` agent description MUST state that specs are OPTIONAL context, matching
`skills/sdd-design/SKILL.md` and the canonical DAG.
(Previously: the description read "from its proposal and specs" while also stating the
phase may run in parallel with `sdd-spec` — two claims that contradict each other, since a
parallel run cannot guarantee the spec exists.)

#### Scenario: [S-design-1] The description and the skill agree

- GIVEN the `sdd-design` agent description in `examples/_templates/`
- WHEN it is compared against `skills/sdd-design/SKILL.md`
- THEN both MUST describe the spec as optional context for design
- AND the generated files under `examples/<harness>/` MUST carry the corrected wording
  after `scripts/build-examples.sh` runs
