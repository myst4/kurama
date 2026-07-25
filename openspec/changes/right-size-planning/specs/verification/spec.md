# Delta for Verification

## MODIFIED Requirements

### Requirement: Verify Phase Structure

`sdd-verify` MUST separate evidence-gathering from verdict-rendering. Evidence-gathering
(completeness, static spec match, design coherence, test/build/coverage execution) MUST be
distinct from the verdict (the spec compliance matrix, the TDD audit, and the content
binding receipt), and the compliance matrix MUST be reachable without reading the execution
steps that precede it.
(Previously: one 431-line skill — 2.4× the ~180-line average of the other phase skills —
in which the compliance matrix, where `compliance_mode` changes the meaning of a result,
sits behind four execution steps.)

The split MUST NOT change any verdict. The same inputs MUST produce the same
COMPLIANT / UNTESTED / FAILING classification as before.

#### Scenario: [S-verify-1] Verdicts are unchanged by the split

- GIVEN a change that verified as COMPLIANT before the split
- WHEN `sdd-verify` runs on the same inputs after the split
- THEN the verdict MUST be COMPLIANT
- AND the verification report MUST carry the same per-scenario classifications

#### Scenario: [S-verify-2] compliance_mode still governs UNTESTED

- GIVEN a MUST scenario with structural evidence but no passing test
- WHEN `compliance_mode` is `behavioral`
- THEN the scenario MUST be classified CRITICAL
- AND WHEN `compliance_mode` is `static`
- THEN the same scenario MUST be classified WARNING

#### Scenario: [S-verify-3] A failing test stays critical in both modes

- GIVEN a scenario whose test executes and fails
- WHEN `sdd-verify` renders the verdict under either `compliance_mode`
- THEN the scenario MUST be classified CRITICAL

#### Scenario: [S-verify-4] The archive gate still reads the report

- GIVEN a verification report produced after the split
- WHEN `sdd-archive` runs its Step 0 gate
- THEN it MUST locate the verdict in the report
- AND it MUST block on a FAIL or CRITICAL verdict as it does today
