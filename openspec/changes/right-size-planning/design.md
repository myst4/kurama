# Design — right-size-planning

## Technical Approach

Four parts land together. Only part 1 changes how the workflow behaves; parts 2–4 correct,
restructure, and subtract. They are sequenced so each lands on a green suite: the mechanical
subtraction (4) goes last, because it touches every phase and would otherwise create noise
in the diffs of the parts that carry real design.

The whole change is Markdown and bash. There is no runtime to refactor — the phase contracts
ARE the product, so "implementation" means editing contracts precisely and proving the
installer suite still passes.

## Architecture Decisions

### AD-1: Size is classified by `propose`, not by a new phase

**Decision.** `sdd-propose` classifies and records the size in `proposal.md`.

**Rationale.** Phases are executors and MUST NOT delegate (`sdd-phase-common.md`). A
dedicated sizing phase would either break that boundary or cost an extra orchestrator
round-trip for one boolean. `propose` already reads the context needed to judge blast radius
and already writes an artifact — the classification rides along at zero additional cost.

**Rejected:** the orchestrator classifying. It would have to read the change context itself,
duplicating what `propose` does, and the orchestrator is deliberately kept thin.

### AD-2: `small` collapses artifacts into the proposal; it never skips them

**Decision.** For `small`, `proposal.md` carries `## Spec (inline)` and `## Design (inline)`
in the same format the standalone artifacts use.

**Rationale.** The exploration proved skipping deadlocks: `sdd-tasks` requires spec + design,
and `sdd-archive` blocks without a delta spec because it has nothing to merge into the main
specs. The saving that is actually available is not the *information* — it is the two
sub-agent round-trips and the two gates. Collapsing captures that saving and leaves the
source of truth intact.

**Consequence, stated plainly.** An inline section written in one pass gets less scrutiny
than a dedicated phase with a fresh context window. That is the real trade. It is why the
`small` criteria are narrow and why ambiguity resolves to `standard`.

### AD-3: Absent size means `standard`

**Decision.** A missing or unrecognized `## Change Size` is read as `standard`.

**Rationale.** Every in-flight change created before this lands has no size recorded. Failing
on absence would block them; defaulting to `small` would silently downgrade their rigor. The
long path is the safe default, and it makes the feature purely additive for existing work.

### AD-4: `none` is removed rather than deprecated

**Decision.** Delete the mode outright; a phase resolving `none` reports it as unsupported
and names `openspec`.

**Rationale.** A deprecation window would keep all 76 references alive plus add warning
paths — more surface, not less, for a mode whose entire behavior is "do nothing". Reporting
unsupported at resolution time is one branch that dies as soon as projects migrate.

### AD-5: The verify split is structural, not behavioral

**Decision.** Reorganize `sdd-verify` into an evidence section and a verdict section, with
the compliance matrix promoted to the top of the verdict section. No classification logic
changes.

**Rationale.** The skill is 2.4× the average phase size because it holds two jobs. Splitting
them makes `compliance_mode` — the switch that changes what a result *means* — visible
without reading four execution steps first. The spec pins this with scenarios asserting
verdict equivalence, so the restructure cannot quietly alter an outcome.

### AD-6: Per-phase agent files are source, not generated (corrected during apply)

**Correction.** This design originally stated that the `sdd-design` description should be
fixed in `examples/_templates/` and regenerated. That is wrong.

`scripts/build-examples.sh` generates only the **orchestrator prompt** for each harness
(`examples/claude-code/CLAUDE.md`, `examples/pi/AGENTS.md`, `examples/codex/agents.md`, …)
from `examples/_templates/{core,<harness>}.md`. The per-phase agent files under
`examples/claude-code/agents/` and `examples/pi/agents/` are **hand-maintained source** and
have no template.

**Consequence.** The description is corrected directly in both agent files. The
"never hand-edit generated files" rule still holds — it just does not apply to these two,
and the rule's real boundary is now recorded here so the next change does not re-derive it.

## Data Flow

Standard path (unchanged):

```
propose ──> proposal.md ──┬──> sdd-spec  ──> specs/{domain}/spec.md ──┐
                          └──> sdd-design ──> design.md ─────────────┴──> tasks ──> apply ──> verify ──> archive
                                                                                                          │
                                                          specs/{domain}/spec.md ─────────────────────────┘
                                                                    merged into openspec/specs/
```

Small path (new):

```
propose ──> proposal.md
             ├── ## Spec (inline)   ─────────────┐
             ├── ## Design (inline) ─────────────┤
             └── ## Change Size: small           │
                          │                      │
                          └──> tasks ──> apply ──> verify ──> archive
                                                                │
                              ## Spec (inline) ─────────────────┘
                                        merged into openspec/specs/
```

The archive merge reads the same shape in both paths — a delta spec with ADDED / MODIFIED /
REMOVED sections. Only its location differs: a file in `specs/{domain}/` versus a section
inside `proposal.md`.

## File Changes

| File | Change | Description |
|------|--------|-------------|
| `skills/sdd-propose/SKILL.md` | Modify | Add the classification step, the five criteria, and the inline spec/design section templates |
| `skills/sdd-tasks/SKILL.md` | Modify | Accept inline spec/design from `proposal.md` when size is `small`; keep the required-artifact block for `standard` |
| `skills/sdd-archive/SKILL.md` | Modify | Locate the delta spec inline when size is `small`; block on a missing or empty inline spec |
| `skills/sdd-new/SKILL.md` | Modify | Sequence phases from the recorded size |
| `skills/sdd-ff/SKILL.md` | Modify | Same, for the fast-forward path |
| `skills/sdd-continue/SKILL.md` | Modify | Resolve the next phase using the recorded size |
| `skills/_shared/sdd-phase-common.md` | Modify | Document the small path beside the canonical DAG; absent size ⇒ standard |
| `skills/_shared/openspec-convention.md` | Modify | Config schema: drop `none`; document the size field |
| `skills/_shared/persistence-contract.md` | Modify | Remove `none` (14 refs); restate the Engram fallback as the only degradation path |
| `skills/_shared/engram-convention.md` | Modify | Remove `none` references |
| `skills/sdd-{init,explore,spec,design,apply,verify}/SKILL.md` | Modify | Remove the `none` branch from each persistence section |
| `examples/claude-code/agents/sdd-design.md`, `examples/pi/agents/sdd-design.md` | Modify | Specs are optional context, not a hard dependency. **These are hand-maintained source files, not generated** — see AD-6 |
| `examples/<harness>/{CLAUDE,AGENTS,GEMINI}.md` etc. | Regenerate | Orchestrator prompts only — the output of `scripts/build-examples.sh`, never hand-edited |
| `scripts/install_test.sh` | Modify | Tests for the size field, the collapsed path, and the absent-`none` assertion |
| `docs/persistence.md`, `docs/architecture.md`, `docs/migration.md`, `docs/smoke-test.md` | Modify | Drop `none`; document the size-aware path and the migration |
| `docs/changelog.md` | Modify | Unreleased entry, breaking change called out |

## Interfaces / Contracts

The proposal gains one required section and, for `small`, two more:

```markdown
## Change Size

**`small`** | **`standard`** — {which criteria were evaluated and how each resolved}
```

```markdown
## Spec (inline)          <- small only; same body as a standalone delta spec
# Delta for {Domain}
## ADDED Requirements
### Requirement: {name}
#### Scenario: [S-{req}-1] {name}
- GIVEN / WHEN / THEN

## Design (inline)        <- small only
### Architecture Decisions
### File Changes
```

Config schema (`openspec/config.yaml`) — the mode enum narrows:

```yaml
# artifact store mode: engram | openspec | hybrid      (none removed)
```

## Testing Strategy

| Layer | What to Test | Approach |
|-------|-------------|----------|
| Structural | No `none` remains as a mode | `rg -c '\`none\`\|\| none' skills/ docs/` returns 0, asserted in `install_test.sh` |
| Structural | Skill frontmatter and packaging stay valid | `scripts/validate_skills.sh` |
| Structural | The `sdd-design` description matches its SKILL.md | grep both, assert agreement |
| Integration | Generated harness configs carry the corrected description | `scripts/build-examples.sh` then assert on `examples/<harness>/` |
| Integration | The installer lifecycle is untouched | full `scripts/install_test.sh` (132 today) stays green at every step |
| Lint | No new shellcheck findings | `shellcheck scripts/*.sh`, baseline 8 notes |
| Manual | A `small` change completes a real cycle | walk `docs/smoke-test.md` with a small change and confirm 3 artifacts, not 6 |

The behavioral scenarios (S-collapse-*, S-verify-*) describe orchestration performed by a
model reading contracts. They are verified by walking the smoke test, not by a unit test —
`compliance_mode: behavioral` will mark them UNTESTED until that walk is recorded, which is
the correct signal.

## Migration / Rollout

**Parts 1–3 require no migration.** They are additive or internal: an in-flight change with
no recorded size falls back to `standard` (AD-3), and the verify split preserves verdicts by
construction.

**Part 4 is breaking.** A project whose config records `artifact_store.mode: none` must move
to `openspec`:

1. Set the mode to `openspec` in `openspec/config.yaml` (or in the `sdd-init/{project}`
   settings artifact for Engram-backed projects).
2. Re-run `/sdd-init` to regenerate the config against the current schema.
3. Nothing to move: `none` never wrote artifacts, so there is no data to migrate — only the
   setting changes.

`docs/migration.md` carries this note. The changelog entry marks the change breaking.

## Open Questions

- [ ] Should the size classification be overridable by the user at the proposal gate
      (e.g. "this looks small, force standard")? Deferred: `execution_mode: supervised`
      already stops at that gate, where a human can reject the proposal and ask for the
      long path. Revisit if it proves too coarse in practice.
- [ ] Does `sdd-verify` warrant an actual file split (two SKILL.md files) rather than an
      internal reorganization? Deferred to `apply`: reorganize first, measure the result,
      and split only if the skill is still oversized. A file split would change the skill
      registry and every launch prompt that names it.
