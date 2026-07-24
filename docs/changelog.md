# Changelog

## Unreleased

_Nothing yet._

## 5.0.0 — 2026-07-23

### Phase 1 — Stabilization

Cross-cutting stabilization pass: config schema, persistence contract scope, installer hardening + CI, README/identity, OpenCode examples, and docs sync.

- **Config schema (breaking)**: Rewrote the `config.yaml` reference in `openspec-convention.md` as valid, parseable YAML with a single canonical schema — `rules.verify` is now the sole home for `test_command`, `build_command`, and `coverage_threshold`; `rules.apply` holds only behavioral-guidance list items. `sdd-init` Step 3 generates this exact schema (verified byte-for-byte against the convention doc). `.kurama/` is now explicitly documented as harness infrastructure written in every mode, including `none`.
  - **Migration**: `test_command`/`build_command`/`coverage_threshold` move from `rules.apply.*` to `rules.verify.*`. Update existing `config.yaml` files accordingly.
- **Persistence contract scope**: Clarified that mode rules (`engram`/`openspec`/`hybrid`/`none`) govern SDD artifact files only, not implementation code — `persistence-contract.md` and `sdd-apply/SKILL.md` now spell out that code is always written, even in `engram`/`none` modes. `sdd-apply`'s config read switched from `rules.apply.test_command` to `rules.verify.test_command` to match the schema change.
- **Installers hardening + CI**: `setup.sh`/`setup.ps1` now abort on unbalanced markers, write timestamped backups, and apply atomic file writes; fixed macOS stock bash 3.2 empty-array bugs and pinned `unique-names-generator@4.7.1` with `--ignore-scripts`. `install.sh`/`install.ps1` no longer reference the nonexistent `examples/opencode/opencode.json` and unify the VS Code skills target to `~/.copilot/skills`. Added `scripts/validate_skills.sh` (a portable structural linter) and new marker-corruption/opencode-reference regression tests (46/46 passing); wired both into `pr-check.yml` on `ubuntu-latest` and `macos-latest`.
- **README/identity**: Replaced the deprecation-notice README with a real front door — what Kurama is, why it exists, a quick start covering both installer families, the full 15-skill table, the four artifact-store modes, the 7-harness support matrix, and a "Relationship with gentle-ai" section.
- **OpenCode examples**: Rerouted the five executor commands (`sdd-init`/`explore`/`apply`/`verify`/`archive`) from `agent: sdd-orchestrator` to their matching `sdd-<phase>` sub-agent; the three meta-commands stay on the orchestrator. Differentiated `opencode.single.json` (orchestrator only, runs phases as subtasks of the built-in `general` subagent) from `opencode.multi.json` (orchestrator + 9 dedicated `sdd-<phase>` agents); added a "Single vs multi config" section to `AGENTS.md`.
- **Docs sync**: Synced skill indexes across `AGENTS.md` and `docs/architecture.md` (added `judgment-day`, `go-testing`, `skill-creator`); replaced the duplicated Sub-Agent Result Contract with a pointer to the canonical source in `sdd-phase-common.md`; consolidated the previously triplicated skill-loading protocol behind `skill-resolver.md`; corrected `docs/installation.md`'s single vs multi config table; fixed two invalid `gh issue create` examples in `issue-creation/SKILL.md`.

### Phase 2 — SDD core coherence

Cross-cutting SDD coherence pass: specs source of truth, failure/recovery hardening, a configurable verify gate + real archive gate, Judgment Day protocol fixes + portability, manifest-driven install with `VERSION` + uninstall, envelope/DAG unification, and a docs/migration guide.

- **Specs source of truth (engram main-spec merge)**: Defined the main-spec artifact family in `engram-convention.md` — one artifact per domain at topic_key `sdd-specs/{project}/{domain}`, upserted via stable topic_key, with YAML frontmatter carrying `last_updated`. Pipeline settings in engram mode now live in the `sdd-init/{project}` context artifact. `sdd-archive` merges the concatenated delta spec into these per-domain main specs in engram mode (splitting by `# Delta for {Domain}` headers, applying ADDED/MODIFIED/REMOVED with the same preserve semantics as the filesystem merge) and mirrors the merge to Engram in hybrid mode. `sdd-spec`'s phantom-baseline bug is fixed: engram mode now retrieves the per-domain main specs itself, treating an absent artifact as an empty baseline (write a FULL spec) instead of an error; hybrid reads the baseline file-first, with the file winning on divergence.
- **Failure/recovery protocol (+.kurama/sdd/ fallback)**: `sdd-phase-common.md` now declares the canonical phase DAG once (`explore -> propose -> (spec || design) -> tasks -> apply -> verify -> archive`) as the single source of truth, and Section B defines retrieval-failure semantics: a missing required artifact returns `blocked` naming it and pointing `next_recommended` at the producing phase, while a missing optional artifact lets the phase proceed with a note in risks. `persistence-contract.md` adds a cycle-start Engram availability probe; when Engram is unavailable it now degrades to a `.kurama/sdd/` filesystem fallback with a user warning instead of silently dropping to `none`. A new Write Failure Recovery section replaces the old "the pipeline BREAKS" fatalism with mem_save retry-once then `.kurama/sdd/` fallback plus a risks concern. Hybrid mode is now filesystem-authoritative (file-first reads, file-wins on divergence with reconciliation notes, `last_updated` frontmatter), and orchestrator prompt templates are parametrized by mode so mem_save instructions only appear in engram/hybrid variants.
  - **Migration**: `.kurama/sdd/` is a new fallback state directory written automatically when Engram is unavailable — no action required, but expect artifacts there instead of Engram when the probe fails.
- **Configurable verify gate (compliance_mode) + real archive gate**: Added `rules.verify.compliance_mode` (`behavioral` | `static`) to the canonical config schema, kept byte-identical between `openspec-convention.md` and the `sdd-init` Step 3 template. `sdd-verify` resolves it (propagated prompt value wins, else `openspec/config.yaml`, else default `behavioral`): `behavioral` keeps UNTESTED as CRITICAL, while `static` downgrades UNTESTED to WARNING so a scenario with structural evidence can be COMPLIANT (static); a FAILING test stays CRITICAL either way. `sdd-init` detects test infrastructure to pick the default and persists all pipeline settings in the `sdd-init/{project}` context artifact (engram) or `config.yaml` (openspec/hybrid). `sdd-archive` gained a real Step 0 that reads the verify report first and blocks on a missing report or a FAIL/CRITICAL verdict, with a recorded orchestrator-passed override escape; the archive audit trail/checklists now include exploration and the verify report.
  - **Migration**: new `rules.verify.compliance_mode` key defaults to `behavioral` (the previous strict behavior) when unset; set it to `static` to allow closing cycles without test infrastructure.
- **Judgment Day protocol fixes + portability**: Rewrote `skills/judgment-day/SKILL.md` so approval is reachable and severity-gated — a target is APPROVED when zero CONFIRMED blocking findings (CRITICAL/WARNING) remain after refutation, SUGGESTIONs are advisory-only, and judges return findings lists (never a CLEAN/approval verdict) so the approval decision stays with the orchestrator. Added an explicit refutation branch (a single read-only Refuter batch per round adjudicating suspects/contradictions to CONFIRMED/REFUTED/UNRESOLVED) so a suspect-only round is refuted instead of spawning an empty Fix Agent or burning an iteration; refutation and the user decision gate don't count against the 2-fix-iteration cap. Added a deterministic cross-judge matching procedure (normalized file, ±3-line-or-enclosing-symbol location, normalized category+claim, ties-to-Suspect) and gave the two judges distinct complementary lenses (Judge A Correctness & Security, Judge B Regressions & Resilience). Made the flow portable across harnesses via a per-harness native sub-agent table plus a sequential fallback that preserves blindness; bumped metadata version 1.0 → 1.1.
- **Manifest-driven install with VERSION + uninstall (breaking)**: Added `VERSION` (5.0.0-dev) and `skills/manifest.json` declaring all 15 skills + `_shared` with groups (`sdd-core` mandatory; `quality` = judgment-day; `optional` = go-testing) and a per-harness target mapping. `install.sh`/`install.ps1` now derive the skill list from the manifest (jq/ConvertFrom-Json first, portable bash-3.2/BSD-awk fallback for jq-less machines), support `--version` and `--with`/`--without` group flags, and write a per-target `.kurama-install-manifest.json` recording the installed version and file list. Added `scripts/uninstall.sh`, which removes exactly the recorded files (pruning only emptied dirs, so user-added skills survive) with `--agent`/`--path`/`--all`/`--dry-run`. `validate_skills.sh` gained a manifest coherence check and `install_test.sh` gained 12 regression tests (suite now 58/58); all Phase 1 safety behaviors (`setup.sh`/`setup.ps1`/`pr-check.yml`, `make_writable`, idempotency, marker/backup/atomic-write logic) are unchanged.
  - **Migration**: installs from before this change have no `.kurama-install-manifest.json` receipt, so `scripts/uninstall.sh` has nothing recorded to remove from them — re-run `install.sh`/`install.ps1` first to generate the receipt, then uninstall will work against it going forward.
- **Envelope/DAG unification (breaking)**: `sdd-phase-common.md` Section D is now the ONLY return contract, with an explicit precedence rule (Section D wins over any per-skill Return Summary, which becomes `detailed_report` content) and required `skill_resolution`. Applied blocked-envelope semantics to both `sdd-spec` (proposal) and `sdd-archive` (verify-report/spec/proposal/design/tasks) required inputs. Swept the five owned phase skills to replace their full Return Summary templates with a one-line pointer to Section D plus a bullet list of phase-unique fields only (e.g. Intent/Scope/Approach/Risk Level for `sdd-propose`; Mode/Files Changed/Tests/Status for `sdd-apply`); generic fields (Location, standalone Next Step) were folded into Section D's `artifacts`/`next_recommended` instead of being duplicated. Each file's Execution and Persistence Contract block now points to Section B for missing-artifact handling. `sdd-design`'s ad hoc justification for treating spec as optional was replaced with a pointer to the canonical DAG; `sdd-propose` now notes both `sdd-spec` and `sdd-design` are valid next phases per that DAG.
  - **Migration**: any external tooling reading per-skill Return Summary text directly must switch to parsing the Section D envelope — the old per-skill summary formats no longer carry the return contract.
- **Docs + migration guide**: Created `docs/migration.md`, covering Phase 1's breaking `rules.apply` → `rules.verify` config move (with a grep-based detection check) and Phase 2's six changes — `rules.verify.compliance_mode`, main specs as engram artifacts, the `.kurama/sdd/` fallback store, envelope unification, manifest-driven install/uninstall, and the new `VERSION` file — each with an explicit action-required note. Rewrote `docs/persistence.md`'s mode table to state Engram-availability-driven default resolution with `.kurama/sdd/` degradation, hybrid's file-authoritative/Engram-mirror model, main specs at `sdd-specs/{project}/{domain}`, and an explicit mode-dependent "settings home" table (`openspec/config.yaml` under `rules.verify.*` for openspec/hybrid; the `sdd-init/{project}` context artifact for engram/none). Updated `docs/architecture.md` to point at `sdd-phase-common.md`'s canonical DAG instead of duplicating the dependency diagram, and added `VERSION`, `skills/manifest.json`, `scripts/uninstall.sh`, and `docs/migration.md` to the Project Structure tree.

### Phase 3 — Optional TDD module

Cross-cutting pass adding an opt-in TDD module: a standalone `skills/tdd` core contract, a shared test-runner detection table, spec/task/verify wiring behind a single `tdd.enabled` switch, manifest/installer packaging, and orchestrator-example documentation.

- **New `skills/tdd` core + shared runner table + user doc**: Extracted the RED→GREEN→REFACTOR seed previously embedded in `sdd-apply` into three standalone files. `skills/tdd/SKILL.md` is now the sole home of the cycle contract (one behavior per cycle, mandatory captured RED evidence, minimal GREEN, refactor only under green), the four anti-patterns (disguised test-after, RED that passes immediately, implementation-coupled tests, batch RED), the canonical per-task RED/GREEN/REFACTOR evidence table (moved out of `sdd-apply` Step 6, now with a scenario-ID column for traceability), and the activation precedence. `skills/_shared/test-runners.md` is the sole runner-detection table (detection file → full-suite command + single-test command for RED speed + golden/snapshot flag) covering `go.mod`, `package.json` (vitest/jest/generic), `pyproject.toml`, `Cargo.toml`, `Makefile`, gradle/maven/mix, and a fallback, with a resolution precedence (configured/propagated command wins → detect → report, never guess). Added `docs/tdd.md`, covering activation per mode, the cycle, the two `sdd-verify` audits, and the per-language plugin pattern (`go-testing` as the example).
- **Single `tdd.enabled` switch, no silent heuristics (behavior change)**: Added a real top-level `tdd:` block (`enabled` + `single_test_command`) to the canonical `config.yaml` schema in `openspec-convention.md` and `sdd-init` Step 3, byte-identical between the two and parseable as YAML; `rules.verify.test_command`/`build_command`/`coverage_threshold` are unchanged. `sdd-init` now asks an explicit "enable TDD for this project?" question and persists `tdd.enabled`/`tdd.single_test_command` in `config.yaml` (openspec/hybrid) or the `sdd-init/{project}` settings bundle (engram/none); test-infrastructure detection is demoted to a suggestion only.
  - **Behavior change**: projects with existing test files no longer get TDD behavior applied via heuristic detection — TDD is active only when `tdd.enabled` is explicitly set (propagated value wins, else config, else default off). Existing test setups are unaffected until you opt in.
- **RED/GREEN/REFACTOR task expansion**: `sdd-tasks` resolves `tdd.enabled` with the same precedence as `compliance_mode` and, when enabled, expands each behavior task into `n.x` RED / `n.y` GREEN / `n.z` REFACTOR subtasks referencing the spec scenario ID. `sdd-spec` gained a lightweight `S-{requirement}-{n}` scenario ID scheme in its templates so tasks/verify can point at scenarios.
- **`sdd-apply` delegates to `skills/tdd`**: Step 3a shrank to a pointer to `skills/tdd/SKILL.md`, deleting the inline cycle and the existing-test-files/tdd-SKILL-exists heuristics; the runner ladder is now delegated to `skills/_shared/test-runners.md` instead of being duplicated inline.
- **Verify traceability + RED-evidence WARNINGs**: `sdd-verify` gained Step 6a with two checks — scenario→test traceability for MUST scenarios, and RED evidence present in the apply report. Both are WARNING "test-after detected", never CRITICAL, and independent of `compliance_mode`.
- **`tdd` manifest group (opt-in)**: Added an opt-in `tdd` skill group (`default: false`, `required: false`) to `skills/manifest.json` holding `skills/tdd`; `sdd-core` stays required and `quality`/`optional` stay default-on opt-out. `install.sh` accepts `tdd` in `validate_group_name` and preserves an opt-in `tdd` through a later `--without` via a new `KNOWN_GROUPS` rebuild list, while leaving it out of the default `ACTIVE_GROUPS`; `install.ps1` mirrors this by adding `tdd` to the `-With`/`-Without` `ValidateSet`s. `install_test.sh` gained three regressions (default install excludes `tdd` at 15 skills; `--with tdd` installs it at 16; `--with tdd` uninstall round-trip stays clean). `validate_skills.sh` accepts `tdd` in the manifest group allowlist.
- **`go-testing` genericized**: Reframed in place as the reference implementation of a per-language testing plugin that reaches sub-agents via the skill registry, pointing at the language-agnostic `skills/tdd` core, with all Go patterns kept; removed Gentleman.Dots and nonexistent `installer/*` path references.
- **TDD section in the 6 orchestrator examples**: Added an identical "### TDD Module (optional)" section to all 6 orchestrator example files (`claude-code`, `codex`, `gemini-cli`, `opencode`, `antigravity`, `vscode`), inserted right before "### Dependency Graph" in each. The section documents the `tdd.enabled` switch (config.yaml `tdd:` block or the `sdd-init/{project}` settings bundle in engram mode; propagated value wins), the RED/GREEN/REFACTOR subtask expansion in `sdd-tasks`, `sdd-apply`'s delegation to `skills/tdd/SKILL.md`, `sdd-verify`'s scenario-traceability/RED-evidence WARNING audits, and the explicit "disabled = no TDD behavior anywhere" guarantee. `cursor/` was left untouched — stays empty until Phase 4.
  - **Migration**: TDD is fully opt-in — existing projects are unaffected until `tdd.enabled: true` is set explicitly; no config migration required.

### Phase 4 — Multi-harness modernization

Cross-cutting pass generalizing the orchestrator examples into a build pipeline, adding native Claude Code subagents and packaging, deterministic opt-in hooks, hardening the OpenCode background-agents plugin, and clarifying/updating the docs.

- **Generated orchestrator examples (`_templates` + `build-examples.sh` + CI anti-drift)**: The 7 orchestrator docs are now build outputs of a single source of truth. `examples/_templates/core.md` carries the shared body (role/delegation rules, the reconciled Hard Stop Rule, the canonical 6-field Result Contract, phase read/write tables, a byte-identical TDD section, the Sub-Agent Context Protocol, Skill Resolution Feedback, and the Recovery Rule); one overlay per harness (`claude-code`/`codex`/`gemini-cli`/`opencode`/`antigravity`/`vscode`/`cursor.md`) holds only that harness's deltas via `<!-- @@TOKEN@@ -->` blocks (`HEADER`, `DELEGATION_MECHANISM`, `NATIVE_NOTES`, `MODEL_ASSIGNMENTS_SECTION`, `STATE_CONVENTIONS`). `scripts/build-examples.sh` (portable bash 3.2/BSD-awk, shellcheck-clean) assembles core+overlay into all 7 files, including the **new** `examples/cursor/.cursor/rules/sdd-orchestrator.mdc`, collapsing blank runs from empty tokens and injecting a GENERATED marker. The build is idempotent (rebuild = zero diff), and a new `examples-drift` job in `pr-check.yml` rebuilds on CI and fails on any `examples/` diff. Fixes the vscode 5-field Result Contract drift and makes the TDD section byte-identical (verified by SHA) across all 7 generated bodies.
- **Native Claude Code subagents with model routing**: Added 9 declarative Claude Code subagents under `examples/claude-code/agents/` (`sdd-init`, `sdd-explore`, `sdd-propose`, `sdd-spec`, `sdd-design`, `sdd-tasks`, `sdd-apply`, `sdd-verify`, `sdd-archive`), each with frontmatter `name`/`description`/`tools`/`model`. Model routing: `model: opus` for `sdd-design` and `sdd-apply`, `model: sonnet` for the other seven. Each body loads its phase `SKILL.md` plus `skills/_shared/sdd-phase-common.md`, honoring the Section D return envelope and the settings/tdd propagation contract (propagated value wins).
- **Meta-skills `sdd-new`/`sdd-continue`/`sdd-ff` (default-installed)**: Added the three meta-skills as thin orchestrator entry points that explicitly declare themselves the exception to the executor rule, mirroring the OpenCode meta-commands' routing to the sdd-orchestrator: `sdd-new` drives init-check -> explore -> propose gate; `sdd-continue` recovers state per the persistence contract and resumes the next dependency-ready DAG phase; `sdd-ff` auto-continues the remaining planning phases, stopping at blocked/FAIL and the implementation boundary. All three are registered in the `sdd-core` group in `skills/manifest.json` (now 16 sdd-core / 19 total skills), so they install by default.
- **Plugin/marketplace + Gemini extension packaging**: Added `.claude-plugin/plugin.json` (valid Claude Code manifest, version `5.0.0-dev` matching `VERSION`, wiring skills + the new agents + the new hooks) and `.claude-plugin/marketplace.json` (single-entry example, source `./`). Added `gemini-extension.json` (name/version/description + `contextFileName` -> `examples/gemini-cli/GEMINI.md` + skills path) for Gemini CLI extension installs.
- **Deterministic hooks (opt-in)**: Added two Claude Code hooks under `examples/claude-code/hooks/`. `orchestrator-write-guard.sh` is a `PreToolUse` guard on `Edit|Write|MultiEdit` that allows the write when no SDD cycle is active or the target is under `.kurama/`/`openspec/` (or outside the repo), and blocks (exit 2 + stderr reason) the main-thread orchestrator's direct writes to repository code while a cycle is active; active-cycle detection is mechanical (`openspec/changes/*/state.yaml` outside `archive/`, or `.kurama/sdd/*/state.md` without `archive-report.md`). `archive-gate.sh` mechanically mirrors `sdd-archive` Step 0 — it locates the persisted `verify-report.md`, reads the `### Verdict`, and exits non-zero unless the verdict is PASS / PASS WITH WARNINGS, honoring the `KURAMA_ARCHIVE_OVERRIDE=1` escape hatch; it runs both standalone (`archive-gate.sh <change>`) and as a `Task|Skill` hook that only gates `sdd-archive` launches. `hooks.json` wires both as a ready-to-merge settings snippet; `docs/hooks.md` covers install/enforcement/disable and per-harness applicability (Claude Code native, Gemini via extensions, others manual/CI).
- **OpenCode background-agents plugin fixes**: Hardened `examples/opencode/plugins/background-agents.ts` beyond the upstream port:
  - **Timeout data loss**: `handleTimeout` deleted the child session *before* reading its partial result, so the `[TIMEOUT REACHED]` file silently lost whatever the agent had produced; the result is now captured before the session is deleted.
  - **Cross-session listing leak**: `delegation_list` returned every concurrent session's delegations because the in-memory map wasn't scoped by session; listing is now filtered to the calling session tree (matching the caller session or its root).
  - **Unbounded memory growth**: the in-memory delegation map had no eviction, so a long-running process could accumulate history without limit; terminal delegations are now pruned once more than 50 accumulate (persisted results on disk are unaffected).
  - **Stale hardcoded agent names**: the `delegate` tool's `agent` parameter description hardcoded upstream agent names (`explore`, `researcher`, `scribe`) that don't exist in this setup; the guidance is now generated from the agents actually configured in the workspace's `opencode.json`.
  - **Debug log always-on**: the plugin appended to a debug log on every operation regardless of need; logging is now opt-in via `KURAMA_BG_DEBUG=1`.
  - **Timer leak**: `generateMetadata`'s 30s safety net used a bare `Promise.race`/`setTimeout` that could leave a dangling timer; it now uses the shared `withTimeout` helper, which clears its timer on settle.
  - Also removed dead code left over from the earlier read-only-agent restriction (`parseAgentMode`, `parseAgentWriteCapability`, `isPermissionDenied`, the `PermissionEntry` type, the inlined `logWarn`) and two unused methods (`deleteDelegation`, `getRecentCompletedDelegations`).
- **OpenSpec-vs-upstream clarification**: `skills/_shared/openspec-convention.md` and `docs/persistence.md` both gained a note that Kurama's `openspec/` convention is a project-local artifact-store layout, not the upstream OpenSpec CLI format — avoiding confusion for users familiar with the separate OpenSpec tool.
- **Docs updates, including corrected token-economics**: `AGENTS.md` now indexes all 19 skills (added `tdd` + the three meta-skills). `docs/token-economics.md`'s flagged math is fixed: "exponentially" replaced with a correct quadratic characterization (with the N²/2 derivation), the fixed-overhead total and the compaction totals now derive arithmetically from their stated per-item ranges (11,329–12,545T and 30,000–220,000T / 0–4,500T respectively, shown as arithmetic), and the spurious "~1,209%" figure was replaced with a claim grounded in the doc's own crossover-point data. `docs/installation.md` gained plugin/marketplace install for Claude Code, a Gemini CLI extension section, Codex's project-level `.agents/skills` convention, a corrected Cursor section (`.cursor/rules/sdd-orchestrator.mdc` instead of the deprecated `.cursorrules`), and a new "Editing the Generated Example Orchestrators" section documenting the `_templates/` + `build-examples.sh` workflow. `docs/sub-agents.md` gained "Native Claude Code Subagents (optional)" (model routing) and "Agent Teams Mode (experimental, optional, off by default)" for judgment-day judges and spec‖design parallelism, plus consistency fixes. `docs/migration.md` and `docs/architecture.md` were updated for the new files and sections (agents, hooks, `.claude-plugin/`, `gemini-extension.json`, cursor `.mdc` path, `skills/tdd` + meta-skills).
  - **Migration**: no action required — all Phase 4 additions are new files or opt-in (hooks, meta-skills default-install alongside existing `sdd-core` skills but don't change existing behavior; the OpenCode plugin fixes are drop-in).

### Phase 5 — Delivery guard, execution mode, TDD triangulation

Cross-cutting pass adding a delivery-sizing guard to PR creation, a supervised/auto execution mode across the SDD pipeline, and an optional triangulation sub-step in the TDD cycle.

- **Review Workload Guard + Delivery Strategy (`skills/branch-pr`)**: `skills/branch-pr` gained three sections — a **Review Workload Guard** that measures the diff against the base (`git diff --stat`/`--numstat` against `origin/<base>`) before assembling a PR and partitions the work into a chain when it crosses ~400 authored changed lines or touches >8 files across >3 top-level modules (with a documented explicit-override escape hatch); a **Delivery Strategy** (small → single direct PR; large → stacked chain; risky domain — auth/payments/data/security — at any size → risk flag + mandatory rollback note); and a **Chain Strategy** (one `feat/{change}-{n}-{slug}` branch per unit, each PR standalone with its own approved issue and one `type:*` label, base = previous PR, merge order documented). The orchestrator example template's delegation guide now routes delivery through this guard.
- **`execution_mode` (supervised | auto)**: Added a top-level `execution_mode` key to the canonical `config.yaml` schema in `openspec-convention.md` and the `sdd-init` Step 3 template (byte-identical between the two). `supervised` (default) stops at the human gates (post-propose, verify FAIL, pre-archive); `auto` auto-advances, halting only on `status: blocked` or a verify FAIL. Resolution follows the same precedence as `compliance_mode`/`tdd` (propagated value wins → `openspec/config.yaml` / `sdd-init/{project}` settings bundle → default `supervised`). `sdd-init` asks the mode and persists it; `sdd-new`/`sdd-continue` condition their human gates on it; `/sdd-ff` always implies `auto` for the remaining phases. The orchestrator example template propagates `execution_mode` alongside `compliance_mode` and `tdd`.
- **Optional TRIANGULATE sub-step (TDD)**: The TDD cycle in `skills/tdd/SKILL.md` gained an optional `TRIANGULATE` step between GREEN and REFACTOR — add a second boundary/edge test for the same scenario before refactoring; a failing boundary test loops back to GREEN. The evidence table gained an optional triangulation row. The cycle name stays RED → GREEN → REFACTOR, the step is never required, and `sdd-verify` never flags its absence; the orchestrators' task-expansion contract is unchanged. `docs/tdd.md` documents the optional step.
- **Docs**: `docs/migration.md` gained a Phase 5 section (new `execution_mode` key defaulting to `supervised`, the branch-pr workload guard, and the optional triangulation sub-step, each with an action-required note); this changelog's Unreleased list gained this Phase 5 entry.
  - **Migration**: no action required — `execution_mode` defaults to `supervised` (previous behavior), the workload guard is PR-sizing guidance, and triangulation is opt-in within the already-opt-in TDD module.

### Phase 6 — Review layer, orchestration harness, content-bound receipts, Pi

Cross-cutting pass adding a bounded 4R + refuter review layer (skills + orchestrator triage), content-bound verify/archive receipts, a resolver-default inversion, a prompt-capture provenance rule, Pi as an eighth harness, and an offline SDD status inspector.

- **Review layer — 5 new skills + shared ledger contract (`review` group, default-on)**: Added `skills/review-risk` (R1), `skills/review-readability` (R2), `skills/review-reliability` (R3), `skills/review-resilience` (R4), and `skills/review-refuter` — read-only lenses (`tools: Read, Grep, Glob`) porting the per-domain Flag/Block/require-evidence rules and precision gate, plus the markdown-native `skills/_shared/review-ledger-contract.md` (sweep budget 1 standard / 2 for 4R, precision gate, candidate-causal admission, findings-ledger schema, adversarial verification with 2-of-3 voting in 4R, severity floor where only BLOCKER/CRITICAL gate and WARNING/SUGGESTION stay `info`, max 2 fix rounds, artifact-store-aware persistence). All Go-facade vocabulary (`subject_hash`, `GENTLE_AI_REVIEW_BINDING`, `gentle-ai review` commands, capture-result) is removed; the contract is self-contained.
- **Review group registration (surface)**: `skills/manifest.json` gained a `review` group (`default: true`, opt out with `--without review`) holding the five lenses; `validate_skills.sh` accepts `review` in the manifest group allowlist; `install.sh`/`install.ps1`/`setup.sh`/`setup.ps1` add `review` to the default-on group set (and to the `--with`/`--without` validators). A default install now lands **23 skills** (was 18); `--with tdd` lands **24**. `AGENTS.md`, `README.md`, and `docs/sub-agents.md` index the five lenses; `install_test.sh` count assertions move 18→23 / 19→24 / 17→22 / 16→21 / 90→115 and gain review-installed / `--without review` regressions.
- **Orchestrator review triage (G2) + preflight/gatekeeper/guards (G3/G4)**: `examples/_templates/core.md` (propagated to all harnesses by `build-examples.sh`) gained deterministic **Review Lens Selection** (trivial → no lens; standard → exactly one dominant-risk lens; hot-path or >400 authored lines → full 4R; judgment-day reserved for explicit invocation/escalation), a **Language Domain Contract**, an **SDD Session Preflight** (one grouped Pace/Artifact-store/Delivery/Review-budget round, preflight overrides config), an **SDD Entry Routing** guard, an **Automatic Mode Gatekeeper** (validate each Section D envelope before the next auto launch), and a **Sub-Agent Launch Deduplication** guard.
- **Content-bound verify receipt (G5)**: `sdd-verify` records a **Content Binding** section — a reviewed-tree hash over a throwaway git index (`GIT_INDEX_FILE=$(mktemp)` + `git add -A` + `git write-tree`, excluding `openspec/` and `.kurama/`; the real index is never touched) plus the changed-file list — and surfaces `Reviewed-Tree: {hash}` in its envelope. `sdd-archive` Step 0 and `examples/claude-code/hooks/archive-gate.sh` re-derive the hash and block on mismatch ("verify receipt stale — re-run sdd-verify"); `KURAMA_ARCHIVE_OVERRIDE=1` still bypasses. `docs/hooks.md` documents the now-closed gap where the gate trusted the verdict without verifying the tree.
- **Resolver inversion (G7) + prompt-capture provenance (G6) + apply-progress continuity (G8)**: `skills/_shared/skill-resolver.md` inverted its default to registry-index + read the exact `SKILL.md` (compact-rules injection became opt-in), removing the prohibition on sub-agents reading `SKILL.md`. Every automated-SDD-artifact `mem_save` template gained `capture_prompt: false` (chosen by provenance, not `type`), with a canonical note in `engram-convention.md`. `sdd-apply` now read-merge-writes the shared apply-progress artifact instead of blind-overwriting task state.
- **Pi (G9) — eighth harness**: Added `examples/_templates/pi.md` overlay and a `pi` entry in `build-examples.sh`, generating `examples/pi/AGENTS.md` (project-root `AGENTS.md` convention; global alternative `~/.pi/agent/AGENTS.md`). Pure Markdown, no `gentle-pi` npm dependency; models are routed per-agent so no orchestrator model table is injected. `README.md` lists Pi as the eighth supported harness.
- **`scripts/sdd-status.sh` (new)**: A dependency-light (`bash 3.2`/POSIX, no `jq`) offline inspector that lists active SDD cycles with store, last/next phase (derived from the canonical DAG), visible settings, and task progress; `--json` emits a parseable object. Reads `openspec/` and the `.kurama/sdd/` fallback from disk; pure-engram cycles with nothing on disk are intentionally not queryable offline.
  - **Migration**: re-run `setup.sh`/`install.sh` once to land the five review lenses (or pass `--without review` to keep the previous 18-skill set); re-run `sdd-verify` before archiving if code changed post-verify. All other Phase 6 additions are new skills, new orchestrator sections, opt-in gates, or read-only diagnostics — no config migration required.

### Phase 8 — Pi installer wiring, TDD installed by default

Cross-cutting pass promoting the optional TDD module to a default install (activation stays opt-in) and wiring Pi into the installer scripts, with docs and remediation-message updates to match.

- **`tdd` module installed by default (install ≠ activation)**: Flipped the `tdd` group in `skills/manifest.json` from `default: false` to `default: true` (still `required: false`, still removable with `--without tdd`). `setup.sh`/`setup.ps1` and `install.sh`/`install.ps1` include the module in the default set; a default install now lands **24 skills** (was 23), and `--without tdd` lands **23**. **Activation is unchanged** — `tdd.enabled` starts `false` everywhere, `sdd-init` still asks the explicit enable question, and existing test files never flip it on. The rationale (documented in `docs/tdd.md`) is that a project can start without tests and add them later: the module ships available on disk, and each project opts into the RED → GREEN → REFACTOR cycle on its own terms.
- **Pi wired into the installers**: Pi (the eighth harness, added in Phase 6 with the project-root `AGENTS.md` convention and the global `~/.pi/agent/AGENTS.md` alternative) is now detected and wired by `setup.sh`/`setup.ps1` and `install.sh`/`install.ps1` (`--agent pi`), with Pi as a target in `skills/manifest.json`. The orchestrator remains the generated `examples/pi/AGENTS.md`; the Kurama block uses the standard idempotent `<!-- BEGIN:kurama -->` / `<!-- END:kurama -->` markers.
- **Docs**: `README.md` updates the skill counts (24 default / 23 with `--without tdd`) and the catalog row for `tdd` ("installed by default, activation opt-in"). `docs/tdd.md` gains an **Enabling TDD later** section (how to enable TDD on an already-initialized project per mode, plus the inverse) and an **Installation vs activation** section that separates putting the module on disk from turning the cycle on. `docs/installation.md` reflects the TDD-default set, adds a **Pi** section (`setup.sh --agent pi`, `examples/pi/AGENTS.md`), and corrects the generated-orchestrator list from seven to eight files. `docs/migration.md` gains a Phase 8 section.
- **Remediation-message wording (`sdd-init`/`sdd-tasks`/`sdd-apply`/`sdd-verify`)**: The four skills still guard against the module being absent while TDD is enabled (possible only after a `--without tdd` install), but their "module missing" messages now point at **`scripts/install.sh`** (the default install includes it) instead of the old `--with tdd`. The `sdd-init` preflight guard — which refuses to record `enabled: true` until `tdd/SKILL.md` resolves — and the flag-resolution precedence are unchanged; only the message text was updated.
  - **Migration**: re-run `setup.sh`/`install.sh` once to land the `tdd` module in the default set (or pass `--without tdd` to keep it off disk); run `setup.sh --agent pi` if you use Pi. No config migration — a project's `tdd.enabled` value is untouched and activation stays opt-in.

### Phase 9 — Optional GitHub Projects kanban module

Cross-cutting pass adding an opt-in GitHub Projects (v2) board-sync module: a standalone `skills/kanban-github` protocol skill, `sdd-init` onboarding behind a `gh` prerequisite, orchestrator-owned card lifecycle across the SDD phases, issue-creation Backlog placement, and manifest/installer/docs packaging. Install ≠ activate, and the board is bookkeeping that never blocks the cycle (sole exception: the final merge).

- **New `skills/kanban-github` module + canonical config block (`optional` group, default-on)**: Added `skills/kanban-github/SKILL.md` documenting the install-vs-activate contract (activation is per-project via `kanban.enabled`, zero heuristics, same shape as TDD), the ordered `gh` prerequisite checks (`gh --version` → `gh auth status` → `gh project list --owner @me` for the `read:project,project` scopes, each with its exact fix command), the `sdd-init` onboarding (assignee defaulting to `@me` with `kanban.user` as an optional override, owner from the git remote, project via `gh project list`, `project_id` cached via `gh project view`, Status field + options via `gh project field-list`, mapping the board's REAL options to the 5 canonical stages without hardcoding names and ignoring any other column, `merge_method` default `squash`, an optional Size field), the work-intake rules (Backlog → Ready only when work starts; never self-promote from Backlog), and the per-transition card-lifecycle `gh` commands. A canonical top-level `kanban:` block (`enabled`/`user`/`owner`/`repo`/`project_number`/`project_id`/`status_field_id`/`merge_method`/`stages` plus the optional `size_field_id`/`sizes`) was added byte-identically to `skills/_shared/openspec-convention.md`, the `sdd-init` Step 3 template, and the skill; `project_id` (`PVT_...`) is cached at onboarding so no move re-looks it up.
- **Orchestrator card lifecycle + issue-creation Backlog placement (Q4/Q5/Q6)**: `examples/_templates/core.md` (propagated to all eight generated orchestrators by `build-examples.sh`) gained a **Kanban Module (optional)** section grouping the three optional modules, mapping the exact phase-boundary lifecycle — work on the issue starts → Ready; `sdd-apply` starts coding → In Progress; `branch-pr` opens the PR (`Closes #{issue}` for a default base, else `Refs #{issue}`; PR link posted as an issue comment) → In Review; explicit final OK → canonical `gh pr merge` → verify MERGED → (if `Refs`) `gh issue close` → Done → `git checkout {default-branch} && git pull`. Cards are moved INLINE by the orchestrator (`gh` is "Bash for state"); phase executors never touch the board. `skills/branch-pr` gained a **Kanban Board Sync** section (PR-open advances the card to In Review, PR link commented) and a **Post-approval flow** with the three hard preconditions (explicit per-PR OK, rebased+re-verified branch, fresh `gh pr checks`) — the explicit user OK is always a human gate, even in `execution_mode: auto`. `skills/issue-creation` adds each new issue to the board at Backlog and assigns it (`@me` by default, or the `kanban.user` override) with two extra `gh` commands, active only when `kanban.enabled`.
- **Failures never block (Q7)**: every card-lifecycle `gh` failure (`item-add`/`item-edit`/`issue edit --add-assignee`/`issue comment`) is a WARNING in the phase envelope's `risks` and the cycle CONTINUES; the sole exception is the final `gh pr merge`, which reports and awaits instruction on failure (a delivery action, not bookkeeping).
- **Surface — manifest, installers, docs (Q8)**: `skills/manifest.json` lists `kanban-github` in the `optional` group; a default install now lands **25 skills** (was 24), `--without tdd` lands **24**, and `--without optional` drops `go-testing` + `kanban-github` for **23**. `AGENTS.md` and `README.md` index the module and bump the counts (25 default / 24 with `--without tdd`); `install_test.sh` moves every count assertion 24→25 / 120→125 / all-global 24→25 and gains kanban-installed / manifest-group / `--without optional`-excludes-kanban regressions (suite now 85/85). Added `docs/kanban-github.md` (the 5 stages and the phase that triggers each move, the work-intake rules, the `sdd-init` onboarding, the `gh` prerequisite, the assignment rule, WARNING-on-failure semantics, and the human merge gate); `docs/installation.md` notes the `gh` prerequisite (activation only) and lists the module; `docs/migration.md` gains a Phase 9 section. The kanban-github skill is pure Markdown protocol — no live `gh` or network commands run during implementation or testing.
  - **Migration**: re-run `setup.sh`/`install.sh` once to land the `kanban-github` module in the default set (or pass `--without optional` to keep the `optional` group off disk). No config migration — the board is inert until you enable it per project, and activation requires a configured `gh`.

### Phase 10a — Native agents full install, Pi package stack

Cross-cutting pass completing the native-agent surface for Claude Code (the review layer joins the SDD phases as declarative subagents, all installed automatically) and adding an opt-in, consent-gated stack of Pi runtime packages to the Pi installer. No skill counts change — agents are not skills.

- **8 new review-layer agents (`examples/claude-code/agents/` 9 → 17)**: Added the four 4R lenses (`review-risk`, `review-readability`, `review-reliability`, `review-resilience`), the `review-refuter`, the two Judgment Day judges (`jd-judge-a` — Correctness & Security, `jd-judge-b` — Regressions & Resilience), and the `jd-fix-agent`. Each is a **thin** declarative subagent — frontmatter (`name`, `description` with a Trigger, `tools`, `model`) plus a body that loads and follows its Kurama skill (the `review-*/SKILL.md` + `skills/_shared/review-ledger-contract.md` for the lenses; `skills/review-refuter/SKILL.md` for the refuter; `skills/judgment-day/SKILL.md` with the role-specific prompt for the judges and fix agent) and returns that skill's envelope; the agent never duplicates the skill body. Routing (N3): the 4R lenses are `tools: Read, Grep, Glob` + `model: sonnet`; `review-refuter`/`jd-judge-a`/`jd-judge-b` are `Read, Grep, Glob` + `model: opus`; `jd-fix-agent` is `Read, Edit, Write, Glob, Grep, Bash` + `model: opus`. The four lenses, the refuter, and the judges are **read-only enforced by the `tools:` list** (no `Edit`/`Write`, no `Task`). The 9 SDD phase agents are unchanged.
- **Claude Code setup installs all 17 agents automatically (was optional/manual)**: `setup.sh`/`setup.ps1 --agent claude-code` now copies every `examples/claude-code/agents/*.md` into `~/.claude/agents/` — atomic writes, timestamped backup of any pre-existing same-named file (via the shared `make_backup`), and **all** installed agents recorded in the target's `.kurama-install-manifest.json` receipt for receipt-driven uninstall. **Hooks are still not installed by setup** (decision unchanged) — `settings.json` and `examples/claude-code/hooks/` are untouched.
- **Opt-in Pi package stack (`setup.sh --agent pi`)**: Added a consent-gated Pi-package install — an interactive prompt plus `--with-pi-packages` / `--without-pi-packages` flags for non-interactive runs. On yes it installs, in order at pinned versions: `gentle-engram@0.1.10`, `pi-mcp-adapter@2.11.0`, a one-time `pi-engram init` (`npm exec --yes --package gentle-engram@0.1.10 -- pi-engram init`), `pi-subagents-j0k3r@1.4.1`, `@juicesharp/rpiv-ask-user-question@2.0.0`, `pi-web-access@0.13.0`, `@juicesharp/rpiv-todo@2.0.0`, `pi-btw@0.4.1` — 7 packages plus the init step. Failure handling is non-fatal: a missing `pi` on `PATH` skips the step, an individual `pi install` failure warns and continues, and a final summary reports results. Pins are hardcoded in `setup.sh`/`setup.ps1` (refresh with `npm view <package> version`). **`gentle-pi` is deliberately excluded and never installed** — it is a rival Pi harness whose orchestrator/skill wiring directly conflicts with Kurama's Pi setup over the same orchestration surface.
- **Tests (no real network)**: `install_test.sh` never runs real `pi`/`npm`. The Pi-stack path is exercised with a fake `pi` (and `npm`) shim on a temp `PATH` that logs invoked arguments, asserting the exact command sequence — and that `gentle-pi` never appears. The full-agent install is exercised in a temp `HOME`, asserting all 17 agents present in `~/.claude/agents/` and recorded in the receipt. Existing suite assertions continue to pass.
- **Docs**: `docs/installation.md` updates the Claude Code section (setup installs the 17 native agents — what they are, `~/.claude/agents/`, backup/atomic/receipt) and adds an **Optional Pi package stack** subsection (the package table, pins, the prompt/flags, and the explicit `gentle-pi` exclusion with rationale). `docs/sub-agents.md` reframes "Native Claude Code Subagents" to the 17-agent roster (9 SDD + 4 lenses + refuter + 2 judges + fix agent) with the N3 model/tools table and the read-only-enforced-by-tools note. `README.md` adds a brief mention of the Claude Code full-agent install and the optional Pi stack. `docs/migration.md` gains a Phase 10a section.
  - **Migration**: re-run `setup.sh --agent claude-code` once to land the 17 agents (existing same-named files are backed up first); the Pi package stack is opt-in — a plain `setup.sh --agent pi` still wires only skills + orchestrator unless you pass `--with-pi-packages` or answer yes. No config migration, and no skill-count change.

### Phase 10b — Project scope, always-on hooks, Pi agents, Engram, update/doctor

Surface-completion pass closing out the installer: a per-repo install scope, the
Claude Code hooks folded into the default install, the native agents shipped on Pi,
Engram wired as an optional persistence engine, and new `update.sh`/`doctor.sh`
maintenance scripts. No skill counts change (agents and hooks are not skills).

- **`--scope project` / `--path <repo>` (O1)**: `setup.sh`/`setup.ps1` gained
  `--scope global|project` (default `global`, byte-compatible with prior installs)
  and `--path <repo>`. Project scope installs **everything into one git repo** —
  skills to `<repo>/.claude/skills` (Pi: `<repo>/.pi/skills`), native agents to
  `<repo>/.claude/agents` (Pi: `<repo>/.pi/agents`), the orchestrator marker-merged
  into the repo's `CLAUDE.md`/`AGENTS.md`, the Claude hooks into
  `<repo>/.claude/hooks/kurama/` + `<repo>/.claude/settings.json`, and the receipt at
  the **repo root** — so Kurama can be trialed in a single project and removed
  cleanly. `--path` applies only to project scope, defaults to cwd, wins when given,
  and is validated (exists, git repo, never the Kurama repo; non-repo aborts
  non-interactively, asks interactively). `uninstall.sh`/`update.sh`/`doctor.sh`
  accept the same `--scope`/`--path` and operate on that receipt.
- **Claude Code hooks always installed (O2, behavior change)**: `setup.sh --agent
  claude-code` now installs the two deterministic-gate hooks **unconditionally**, in
  both scopes, no prompt (through Phase 10a they were opt-in). The scripts
  (`orchestrator-write-guard.sh`, `archive-gate.sh`) land in the scoped
  `hooks/kurama/` dir and a `PreToolUse` block is merged into the matching
  `settings.json` (`Edit|Write|MultiEdit` → write-guard, `Task|Skill` → archive-gate;
  project scope anchors on `$CLAUDE_PROJECT_DIR`, global on absolute paths). The merge
  is idempotent (strips prior kurama entries first), prefers `jq` (backup + atomic),
  and prints guided manual steps rather than `sed`-editing JSON when `jq` is absent;
  every command string embeds `hooks/kurama/` for surgical removal. Both the scripts
  and the touched `settings.json` are recorded in the receipt.
- **Native Pi subagents (O4)**: added the **17 Pi-format agents** in
  `examples/pi/agents/*.md` (the same 9 SDD + 8 review-layer roster as Claude Code)
  and wired `setup.sh --agent pi` to install them to `~/.pi/agent/agents/` (global) or
  `<repo>/.pi/agents/` (project), receipt-recorded. Pi format: `tools` as a YAML list
  of Pi tool names (`[read]` for the read-only lenses/refuter/judges, `[read, bash]`
  for `jd-fix-agent`, the fuller phase set for SDD executors); `model` as
  `provider/model-id` (`anthropic/claude-sonnet-4-5` lenses + lighter phases /
  `anthropic/claude-opus-4-8` refuter, judges, fix agent, `sdd-design`, `sdd-apply`),
  with `effort` where applicable. In Pi's lean subagent mode the body **is** the whole
  system prompt: each agent `read`s its Kurama skill, resolving `skills/…` →
  `.pi/skills/…` → `~/.pi/agent/skills/…` → `.claude/skills/…`, then follows it and
  returns its envelope. A `model_profiles` override note (`.pi/subagents.json`) is
  documented; Kurama never writes that file.
- **Engram optional persistence engine (O5)**: `setup.sh` asks once — `Use Engram as
  the persistence engine? [y/N]` — or honors `--with-engram` / `--without-engram`
  (non-interactive default no). With yes it ensures the `engram` binary (macOS/Homebrew
  offers `brew tap Gentleman-Programming/homebrew-tap && brew install engram` with
  consent; otherwise prints the releases guide and continues) and registers the Engram
  MCP server into the client being configured, replicating gentle-ai's per-client
  shapes: `mcpServers.engram` (Claude `~/.claude.json` or `<repo>/.mcp.json`, Cursor
  `mcp.json`, Gemini `settings.json`), `mcp.engram` type:local array command (OpenCode),
  `servers.engram` (VS Code `mcp.json`), and TOML `[mcp_servers.engram]` (Codex
  `config.toml`, global only). Pi needs nothing extra (the package stack's
  `gentle-engram` covers it). JSON edits use `jq` + backup + atomic, degrading to
  printed guidance when `jq` is missing — never `sed` on JSON. With no, the harness
  keeps its markdown persistence (`openspec/` / `.kurama/`), noted in the summary. All
  writes recorded in the receipt (`engram_mcp[]`). `setup.ps1` mirrors `-WithEngram` /
  `-WithoutEngram`.
- **`update.sh` (O6, new)**: re-syncs an existing install from the current repo checkout
  **without** `git pull` (pull first, then update). It reads each receipt, re-runs the
  idempotent installer for exactly that recorded target + scope, re-stamps the version,
  and reports which recorded files changed (version before → after). Flags: `--agent`,
  `--scope`, `--path`, `--dry-run`; passes `--without-pi-packages` so an update never
  re-installs the stack. No `--agent` re-syncs every global receipt.
- **`doctor.sh` (O7, new)**: read-only health check — receipt + each recorded file
  present (missing = FAIL) and matching the repo source (drift = WARN), installed vs
  repo `VERSION`, balanced orchestrator markers, Claude hooks present (scripts +
  `settings.json` block), recorded Engram MCP registrations still present, and
  environment tooling (`gh` present + authenticated + project scope; `pi` + the package
  stack via `pi list`; `engram` present + responding). Green/red per item + non-zero
  exit on any hard failure. Flags: `--agent`, `--scope`, `--path`.
- **`uninstall.sh` extended (O3)**: gained `--scope`/`--path`, now strips the
  `hooks/kurama/` block from every recorded `settings.json` surgically (jq filter on the
  `hooks/kurama/` substring, backup, atomic) leaving other hooks intact, and **offers to
  revert the Pi packages** Kurama installed (`--with-pi-packages` /
  `--without-pi-packages`; interactive default no). Emptied dirs are pruned; dry-run
  preserved.
- **Tests (O9)**: `install_test.sh` covers the new surface with **zero network** — always
  via fake `pi`/`npm`/`engram`/`brew`/`claude` shims: project scope in temp HOME + repo
  (receipt at the repo root, clean project uninstall), hooks present + the `settings.json`
  block (jq shim) + removed by uninstall, Pi agents installed per scope, Engram with a fake
  binary on `PATH` (MCP registration verified by file) and `--without-engram` producing
  zero changes, `update.sh` re-sync (a modified installed skill is restored), and
  `doctor.sh` green on a healthy install / red on a broken receipt. The prior suite stays
  green.
- **Smoke test (O8) + docs (O10)**: `docs/smoke-test.md` documents a ~15-minute manual
  end-to-end pass of the SDD cycle (`init → new → ff → apply → verify → archive`) once per
  persistence mode, referenced from the README. `docs/installation.md` gains the project
  scope + `--path` mode (highlighted as the way to trial a repo), the always-on hooks, the
  Engram section with the per-client MCP table, the Pi agents, and a maintenance section
  for `update.sh`/`doctor.sh`/`uninstall.sh`; `docs/sub-agents.md` adds the Native Pi
  Subagents roster + model/tools table and corrects the now-stale "hooks not installed"
  note; `README.md` gains brief `--scope project` + Engram mentions; `docs/migration.md`
  gains this Phase 10b section.
  - **Migration**: re-run `setup.sh --agent claude-code` once to land the always-on hooks
    (existing `settings.json` is backed up; only Kurama's block is added), and
    `setup.sh --agent pi` to land the 17 Pi agents. `--scope project`, Engram, and the new
    `update.sh`/`doctor.sh` are opt-in — global scope and markdown persistence are
    unchanged defaults. The PowerShell parity gap (maintenance scripts + test shims are
    bash-only) is unchanged.

## Notable Upgrades

### v4.4.1 — Gentle-AI Parity Sync + Compact Rules Rollout

This release brings `kurama` back into parity with the latest mirrored `gentle-ai` assets.

- Added `skills/_shared/skill-resolver.md` and switched the documented happy path from `SKILL: Load` path injection to compact rules injected as `## Project Standards (auto-resolved)`.
- Added mirrored skills: `go-testing` and `skill-creator`, and updated `judgment-day` to use the same compact-rule resolution flow.
- OpenCode now ships `examples/opencode/AGENTS.md`, and both OpenCode JSON examples reference it via `"prompt": "{file:./AGENTS.md}"`.
- Setup/install scripts and regression tests now install and verify the full 15-skill set instead of an outdated subset.

### v3.3.6 — OpenCode Multi-Model Support

New **multi-model mode** for OpenCode: both `opencode.single.json` and `opencode.multi.json` include the full 10-agent setup (orchestrator + 9 sub-agents) with `delegate` tool support.

- Setup scripts ask which mode to use (single vs multi) or accept `--opencode-mode` flag.
- **single.json** — ready to use as-is; all agents inherit the default model.
- **multi.json** — same structure, serves as a template for assigning different models per agent.

### v3.3.5 — Full Setup Scripts

New `setup.sh` (Unix) and `setup.ps1` (Windows) that auto-detect agents, install skills, AND configure orchestrator prompts in one command.

- Idempotent with HTML comment markers — safe to run multiple times.
- `--non-interactive` mode for external installers like [gentle-ai](https://github.com/gentleman-programming/gentleman-ai-installer).
- OpenCode special handling: slash commands + JSON config merge.

### v3.3.1 — Skill Registry

New `skill-registry` skill for creating/updating the registry on demand.

- Orchestrator reads the skill registry once per session and injects pre-resolved compact rules into each sub-agent's launch prompt — sub-agents know about your coding skills (React, TDD, Playwright, etc.) and project conventions without needing to search themselves.
- Engram-first + `.kurama/skill-registry.md` fallback — orchestrator resolution works with or without engram.

### v3.3.0 — Mandatory Persist Steps + Knowledge Persistence

Every skill has an explicit numbered "Persist Artifact" step — models were ignoring the contract section and skipping persistence. Now it's impossible to miss.

- Non-SDD sub-agents are instructed to save discoveries, decisions, and bug fixes to engram automatically.

### v3.2.3 — Inline Engram Persistence

All 9 SDD skills now have critical engram calls (`mem_search`, `mem_save`, `mem_get_observation`) inlined directly in their numbered steps. Sub-agents no longer need to follow a 3-hop file read chain to find persistence instructions.

### v2.0 — TDD + Real Execution

- **sdd-apply v2.0** — TDD workflow support. RED-GREEN-REFACTOR cycle when enabled via config.
- **sdd-verify v2.0** — Real test execution + spec compliance matrix (PASS/FAIL/SKIP per requirement).

## Releases

- `v5.0.0` — First stable release: portable SDD pipeline across eight harnesses, manifest-driven installers with project scope and always-on Claude Code hooks, the 4R + refuter review layer, opt-in TDD and kanban modules, optional Engram persistence wiring, and `update.sh`/`doctor.sh` maintenance scripts. Install receipts now stamp the source commit.
- `v4.4.1` — Gentle-AI parity sync: compact-rule skill resolution, new mirrored skills, OpenCode `AGENTS.md`, and installers/tests updated to 15 skills.
- `v4.4.0` — Context-inflation delegation + skill resolution alignment.
- `v4.3.1` — Compact prompts + judgment-day skill.
- `v4.3.0` — Token optimization + executor boundary.
- `v4.2.1` — Self-sufficient sub-agents for skill discovery.
- `v4.2.0` — Per-agent model routing fix in `delegate()`.
- `v4.1.1` — Per-agent model routing fix.
- `v4.1.0` — Background agents plugin + unified configs + delegate-first.
- `v4.0.0` — Issue-first enforcement, token optimization, and Hard Stop Rule.
- `v3.3.6` — OpenCode multi-model support: one agent per SDD phase, each with its own model. Setup scripts auto-configure both modes.
- `v3.3.5` — Full setup scripts (`setup.sh` / `setup.ps1`): auto-detect agents + install skills + configure orchestrator prompts in one step.
- `v3.3.4` — Installer fixes: skill-registry included, correct VS Code path.
- `v3.3.3` — Multi-directory skill scanning + correct agent paths from gentle-ai.
- `v3.3.2` — Index file expansion in skill registry + README overhaul.
- `v3.3.1` — Skill registry skill, engram-first discovery, inline persistence in all skills.
