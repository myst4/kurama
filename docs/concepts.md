# Concepts

Core concepts behind Spec-Driven Development. For quick start, see the [main README](../README.md).

## Delta Specs

Instead of rewriting entire specs, changes describe what's different:

```markdown
## ADDED Requirements

### Requirement: CSV Export
The system SHALL support exporting data to CSV format.

#### Scenario: Export all observations
- GIVEN the user has observations stored
- WHEN the user requests CSV export
- THEN a CSV file is generated with all observations
- AND column headers match the observation fields

## MODIFIED Requirements

### Requirement: Data Export
The system SHALL support multiple export formats.
(Previously: The system SHALL support JSON export.)

#### Scenario: [S-export-1] Export as JSON
- GIVEN the user has observations stored
- WHEN the user requests JSON export
- THEN a JSON file is generated with all observations

#### Scenario: [S-export-2] Choose the format
- GIVEN the user has observations stored
- WHEN the user picks a format
- THEN the export is produced in that format
```

When the change is archived, these deltas merge into the main specs automatically.

A `MODIFIED` block is a **whole-requirement replacement, not a patch**: the archive replaces the
entire matching requirement with the block above, so `S-export-1` is written out even though the
change did not touch it. Omit it and it is deleted from the source of truth. The four sections
and their exact merge semantics are defined once, in
[`skills/_shared/openspec-convention.md`](../skills/_shared/openspec-convention.md) →
*Delta Spec Sections*.

## Linting a Delta Spec

Spec structure is mechanical, so it is checked mechanically rather than by reading:

```bash
bash skills/_shared/lint-spec.sh openspec/changes/{change-name}/specs
```

`lint-spec.sh` takes a spec file or a change directory and prints one finding per line as
`file:line: LEVEL: message` — exit `0` clean, `1` findings, `2` usage. It reports as **ERROR** a
delta section outside `ADDED / MODIFIED / REMOVED / RENAMED Requirements`, a requirement with no
RFC 2119 keyword, an `ADDED`/`MODIFIED` requirement with no scenario, a scenario missing
`GIVEN` / `WHEN` / `THEN`, a malformed or duplicated `[S-{req}-{n}]` ID, a `RENAMED` entry that
names only one requirement, a leftover `{template placeholder}`, and — the case that motivated
it — a `MODIFIED` block carrying **fewer scenarios than the same requirement currently has in
`openspec/specs/`**, naming both counts, and a `REMOVED` entry with no `(Reason: ...)` — the
convention says a removal MUST carry one, and the reason is the only record of why once the
requirement itself is gone. A leftover `TBD` / `TODO` / `XXX` is a **WARNING**.

`sdd-spec` runs it on its own output before persisting, `sdd-verify` runs it as a gate (every
ERROR becomes a CRITICAL issue), and `sdd-archive` refuses to merge a delta with ERRORs. It uses
only `grep`/`awk`/`sed`/`find`, so it runs anywhere the harness does.

## RFC 2119 Keywords

Specs use standardized language for requirement strength:

| Keyword | Meaning |
|---------|---------|
| **MUST / SHALL** | Absolute requirement |
| **SHOULD** | Recommended, exceptions may exist |
| **MAY** | Optional |

## Archive Cycle

```
1. Specs describe current behavior
2. Changes propose modifications (as deltas)
3. Implementation makes changes real
4. Archive merges deltas into specs
5. Specs now describe the new behavior
6. Next change builds on updated specs
```
