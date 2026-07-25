# Proposal — right-size-planning

## Intent

Make the cost of an SDD cycle scale with the size of the change, and remove three pieces
of weight the workflow has not earned. Today the smallest change pays the same ceremony as
the largest: six artifacts, seven phases, one flat floor. The goal is a workflow that stays
rigorous where rigor pays and gets out of the way where it does not — measured by whether it
is still being followed in month three, not by how complete it looks on paper.

## Scope

### In Scope

1. **Size-aware planning path.** `sdd-propose` classifies every change as `small` or
   `standard` and records it. For `small`, the proposal carries a combined lightweight
   spec + design section, and the orchestrator skips the separate `sdd-spec` and
   `sdd-design` phases. `sdd-tasks` and `sdd-archive` still receive the artifacts they
   require — they are collapsed into the proposal, never omitted.
2. **`sdd-design` agent description fix.** Correct the live contradiction in
   `examples/_templates/` (and rebuild) so the description matches the SKILL.md: specs are
   optional context for design, not a hard dependency.
3. **Split `sdd-verify`.** Separate evidence-gathering (steps 1–5d) from verdict-rendering
   (steps 6–8 + report). The compliance matrix, where `compliance_mode` changes meaning,
   stops being buried behind four execution steps.
4. **Remove the `none` persistence mode.** Delete the mode and its branch from every phase,
   shared contract, and doc. **Breaking.**

### Out of Scope

- Merging or removing any phase from the DAG. The graph is unchanged; only which phases run
  for a `small` change changes.
- Collapsing the `hybrid` or `engram` modes. Only `none` goes.
- Changing gates. `apply` stays a human gate in every mode; `archive` is never auto-run.
- Reducing the harness matrix. All 8 stay supported.
- Any change to the installer lifecycle (receipts, update, doctor, uninstall).

## Approach

**Classification lives in `propose`, not in a new phase.** Phases are executors and may not
delegate, so a "sizing phase" would either violate that boundary or add an orchestrator
round-trip. `propose` already reads the proposal context and already writes an artifact;
it is the natural place. The classification is an explicit judgement recorded in the
proposal, with stated criteria — never a silent heuristic, matching how `tdd.enabled` and
`compliance_mode` already work.

**`small` collapses artifacts, it does not skip them.** The exploration established that
skipping deadlocks: `sdd-tasks` requires spec + design, and `sdd-archive` blocks without a
delta spec because there is nothing to merge into the source of truth. For a `small` change
the proposal carries a `## Spec (inline)` section in the same RFC 2119 + Given/When/Then
form and a `## Design (inline)` section, and the orchestrator passes the proposal where the
separate artifacts would have gone.

**Default is `standard`.** Ambiguity resolves to the longer path. A change is `small` only
when it meets every criterion: one domain, no new or changed public contract, no data or
config migration, no new dependency, and no change to a phase contract or the DAG. Anything
that touches the workflow's own contract is `standard` by definition — including this change.

**`none` removal is mechanical but wide:** 76 mode-specific references across `skills/` and
`docs/`. Every phase's persistence section loses one branch; `persistence-contract.md` loses
the most (14). Existing installs with `artifact_store.mode: none` must be migrated.

## Affected Areas

| Area | Change |
|---|---|
| `skills/sdd-propose/SKILL.md` | classification step, criteria, inline spec/design sections |
| `skills/sdd-new/`, `sdd-ff/`, `sdd-continue/` | honor the recorded size when sequencing phases |
| `skills/sdd-tasks/SKILL.md` | accept inline spec/design from the proposal |
| `skills/sdd-archive/SKILL.md` | accept an inline delta spec for the main-spec merge |
| `skills/sdd-verify/SKILL.md` | split evidence-gathering from verdict-rendering |
| `skills/_shared/sdd-phase-common.md` | document the size-aware path alongside the DAG |
| `skills/_shared/persistence-contract.md` | remove `none` (14 refs) |
| `skills/_shared/openspec-convention.md` | config schema: size key, `none` removal |
| all 9 phase skills | remove the `none` branch |
| `examples/_templates/` + rebuild | `sdd-design` description fix |
| `docs/` | persistence, architecture, migration, smoke-test |
| `scripts/install_test.sh` | tests for the new path and the schema change |

## Risks

- **Contract change on a public 5.0.0.** Four parts land at once (the user's call, after
  being offered the split). The blast radius is the whole phase set; a mistake in the
  collapsed-artifact handoff would surface as a `blocked` at `tasks` or `archive`.
- **`small` becomes the default in practice.** If the criteria are loose or the classifier
  is generous, everything becomes `small` and the rigor is gone. Mitigation: every criterion
  must hold, ambiguity resolves to `standard`, and the classification with its rationale is
  recorded in the proposal where a human can see it.
- **Inline artifacts are weaker than separate ones.** A combined section written in one pass
  gets less scrutiny than a dedicated phase with its own agent and fresh context. This is the
  real trade being made, and it is why `small` is narrowly defined.
- **`none` removal breaks existing installs** that use it. Migration note required.
- **The main specs are the thing at risk.** Anything that weakens the delta spec weakens what
  `archive` merges into the source of truth. Every part of this change must preserve a
  well-formed delta spec.

## Rollback Plan

Each part is independently revertable and they are ordered so that reverting a later one does
not disturb an earlier one:

1. Parts 1–3 are additive or internal: reverting the commit restores prior behavior with no
   migration. A project that recorded `size: small` on an in-flight change falls back to the
   standard path on the next phase, since the classification is only read, never required.
2. Part 4 (`none` removal) is the only one with a data path. Revert restores the mode and its
   branches; projects migrated off `none` keep working, since the modes they moved to are
   unchanged.

If the collapsed path misbehaves in practice, `small` can be disabled globally by setting the
config default without reverting any code — the classifier records the size, the orchestrator
decides what to do with it.

## Dependencies

- None external. No new tooling, no new skills, no manifest changes.
- Requires `scripts/build-examples.sh` after the template edit (part 2).
- `scripts/install_test.sh` must stay green at every step (currently 132).

## Success Criteria

1. A `small` change completes a full cycle producing 3 artifacts instead of 6, with
   `sdd-tasks` and `sdd-archive` both succeeding on the collapsed inputs.
2. A `standard` change behaves exactly as it does today — byte-identical phase sequencing.
3. An ambiguous change classifies as `standard`, and the proposal states why.
4. `rg -c '\`none\`|\| none' skills/ docs/` returns zero.
5. `sdd-verify`'s compliance matrix is reachable without reading the execution steps.
   ~~and the skill is materially shorter than 431 lines~~ — **withdrawn during apply.** This
   conflated two goals: visibility and brevity. Making the seam visible costs orientation
   prose; making the skill shorter requires moving content out, which is the file split the
   design deferred. Measured result: 431 → 459 lines, reachability achieved. Brevity is not a
   criterion this change can honestly claim, and hitting it by deleting the orientation would
   defeat the point.
6. The `sdd-design` description and its SKILL.md agree on spec being optional.
7. `bash scripts/install_test.sh` green, `shellcheck scripts/*.sh` with no new findings,
   `bash scripts/build-examples.sh` idempotent.

## Change Size

**`standard`** — by its own criteria. This change modifies phase contracts and the DAG's
documented path, which is the disqualifying condition. It runs the full pipeline.
