# Delta for Persistence

## REMOVED Requirements

### Requirement: `none` Artifact Store Mode

(Reason: `none` means "persist no SDD artifacts" in a workflow whose entire premise is that
specs are the source of truth. A cycle run under `none` produces nothing that survives the
session, so `sdd-archive` has nothing to merge and the main specs never advance. It exists
for completeness of the enum rather than for a user who would choose it, and it costs 76
mode-specific references across `skills/` and `docs/` — a branch in every phase's
persistence section, plus 14 in `persistence-contract.md` alone. Projects that want a
lightweight setup are served by `openspec`, which writes plain markdown into the repo.)

## MODIFIED Requirements

### Requirement: Artifact Store Modes

The artifact store mode MUST be one of `engram`, `openspec`, or `hybrid`.
(Previously: `engram | openspec | hybrid | none`.)

Every phase MUST resolve the mode the same way, and no mode MAY be selected automatically:
`openspec` and `hybrid` are always an explicit choice.

#### Scenario: [S-mode-1] The enum no longer offers none

- GIVEN any phase skill, shared contract, or doc that enumerates the artifact store modes
- WHEN the enumeration is read
- THEN it MUST list exactly `engram`, `openspec`, and `hybrid`
- AND `rg -c '`none`|\| none' skills/ docs/` MUST return zero

#### Scenario: [S-mode-2] An existing none install is migrated, not broken

- GIVEN a project whose config records the artifact store mode as `none`
- WHEN a phase resolves the mode
- THEN it MUST report the mode as unsupported and name `openspec` as the replacement
- AND it MUST NOT silently proceed writing nothing

#### Scenario: [S-mode-3] Harness state is unaffected

- GIVEN the `.kurama/` directory, which holds the skill registry and the fallback SDD state
- WHEN the `none` mode is removed
- THEN `.kurama/` MUST still be written in every remaining mode
- AND the Engram-unavailable fallback to `.kurama/sdd/` MUST be unchanged

### Requirement: Engram Unavailability Fallback

When the mode is `engram` or `hybrid` and the Engram MCP tools are unavailable, the cycle
MUST degrade to the `.kurama/sdd/` filesystem fallback with a warning to the user.
(Previously: the same behavior, but described in contrast to `none` as the silent-drop
alternative. With `none` gone, the fallback is the only degradation path and MUST be
described as such.)

#### Scenario: [S-fallback-1] A missing Engram degrades loudly

- GIVEN a project in `engram` mode
- AND the Engram MCP tools are not reachable in the session
- WHEN a phase performs the cycle-start availability probe
- THEN it MUST warn the user that Engram is unavailable
- AND it MUST write its artifact to `.kurama/sdd/` rather than skipping persistence
