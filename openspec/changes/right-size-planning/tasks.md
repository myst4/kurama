# Tasks — right-size-planning

Ordered so every group lands on a green suite. Group 4 (the `none` removal) goes last
because it touches every phase and would otherwise bury the design-carrying diffs in noise.

Verify after each group: `bash scripts/install_test.sh` green, `shellcheck scripts/*.sh`
with no new findings (baseline 8 notes).

## 1. Description fix (smallest, independent)

- [x] 1.1 Correct the `sdd-design` agent description so specs read as OPTIONAL context,
      matching `skills/sdd-design/SKILL.md:28` and the canonical DAG. **Corrected during
      apply (AD-6)**: the per-phase agent files are hand-maintained source, not generated —
      edit `examples/claude-code/agents/sdd-design.md` and `examples/pi/agents/sdd-design.md`
      directly. `build-examples.sh` only generates the orchestrator prompts
- [x] 1.2 Run `scripts/build-examples.sh` and confirm it stays idempotent (it does not touch
      the agent files; this only proves the change did not disturb prompt generation)
- [x] 1.3 Add an install test asserting the description and the SKILL.md agree on spec
      being optional — S-design-1

## 2. Size-aware planning path (the spine)

- [x] 2.1 Add the classification step to `skills/sdd-propose/SKILL.md`: the five criteria,
      ALL-must-hold, ambiguity ⇒ `standard`, contract changes never `small` — S-size-1..3
- [x] 2.2 Add the `## Change Size` section to the proposal template with its rationale field
- [x] 2.3 Add the `## Spec (inline)` and `## Design (inline)` templates for `small`, in the
      same RFC 2119 + Given/When/Then form a standalone delta spec uses
- [x] 2.4 Teach `skills/sdd-tasks/SKILL.md` to read inline spec/design when size is `small`;
      keep the required-artifact block unchanged for `standard` — S-collapse-1
- [x] 2.5 Teach `skills/sdd-archive/SKILL.md` to locate the delta spec inline for `small`,
      and to block on a missing or empty inline spec rather than merging a partial
      result — S-collapse-2, S-collapse-3
- [x] 2.6 Sequence from the recorded size in `sdd-new`, `sdd-ff`, and `sdd-continue`;
      absent or unrecognized ⇒ `standard` — S-seq-1, S-seq-2
- [x] 2.7 Document the small path in `skills/_shared/sdd-phase-common.md` beside the
      canonical DAG, without restating the DAG itself
- [x] 2.8 Add the size field to the config schema in
      `skills/_shared/openspec-convention.md`
- [x] 2.9 Install tests: a `standard` change sequences byte-identically to today; an absent
      size falls back to `standard`

## 3. Verify split (structural, verdict-preserving)

- [x] 3.1 Reorganize `skills/sdd-verify/SKILL.md` into an evidence section (current steps
      1–5d) and a verdict section (6–6b, report), promoting the compliance matrix to the top
      of the verdict section
- [x] 3.2 Confirm no classification logic changed: `compliance_mode` still governs UNTESTED
      (behavioral ⇒ CRITICAL, static ⇒ WARNING); a failing test stays CRITICAL in both
      — S-verify-2, S-verify-3
- [x] 3.3 Confirm `sdd-archive` Step 0 still locates the verdict in the reorganized report
      — S-verify-4
- [x] 3.4 Record the resulting line count. **431 → 459 (+28).** The skill got LONGER, not
      shorter, which contradicts success criterion 5 in the proposal. Finding: that criterion
      conflated two different goals. Making the seam VISIBLE costs orientation prose (a
      Part A/B split plus the compliance_mode decision table); making the skill SHORTER
      requires moving content OUT, which is the file split the design deferred as an Open
      Question. The reachability half of the criterion is met — the compliance matrix now
      sits under an explicit "Part B — Render the Verdict" header with the mode table at the
      top. The brevity half is not, and should not be met by deleting the orientation that
      made it readable. Escalates the deferred file-split question rather than resolving it

## 4. Remove the `none` mode (breaking — last)

- [x] 4.1 Remove `none` from `skills/_shared/persistence-contract.md` (14 refs) and restate
      the Engram-unavailable fallback as the only degradation path — S-fallback-1
- [x] 4.2 Remove `none` from `skills/_shared/openspec-convention.md` and
      `skills/_shared/engram-convention.md`
- [x] 4.3 Remove the `none` branch from each phase's persistence section: `sdd-init` (8),
      `sdd-archive` (5), `sdd-apply` (4), `sdd-verify` (3), `sdd-tasks` (3), `sdd-spec` (3),
      `sdd-propose` (3), `sdd-design` (2), `sdd-explore`
- [x] 4.4 Make mode resolution report `none` as unsupported and name `openspec`, rather than
      proceeding silently — S-mode-2
- [x] 4.5 Confirm `.kurama/` is still written in every remaining mode and the
      `.kurama/sdd/` fallback is unchanged — S-mode-3
- [x] 4.6 Update `docs/persistence.md` (5), `docs/smoke-test.md` (5), `docs/architecture.md`,
      `docs/sub-agents.md`, `docs/tdd.md`, `docs/companion-skills.md`, `docs/kanban-github.md`
- [x] 4.7 Add the migration note to `docs/migration.md`: set the mode to `openspec`, re-run
      `/sdd-init`; no data to move because `none` never wrote artifacts
- [x] 4.8 Install test asserting zero mode-level `none` remains — S-mode-1
- [x] 4.9 Changelog entry under Unreleased, marked **breaking**

## 5. Close out

- [x] 5.1 `scripts/validate_skills.sh` passes
- [x] 5.2 `scripts/build-examples.sh` is idempotent (no diff on a second run)
- [x] 5.3 Full `scripts/install_test.sh` green
- [ ] 5.4 Walk `docs/smoke-test.md` with a real `small` change and record the result: 3
      artifacts instead of 6, `tasks` and `archive` both succeeding on collapsed inputs.
      This is what converts the S-collapse-* scenarios from UNTESTED to verified under
      `compliance_mode: behavioral`
