# Companion Skills (optional)

Kurama ships a complete SDD pipeline, but it does not live in a vacuum. When other
Agent-Skills-format skills are installed alongside it, the
[skill registry](../skills/skill-registry/SKILL.md) discovers them automatically and
the orchestrator can pair them into the SDD phases.
**[superpowers](https://github.com/obra/superpowers)** — a set of **14 process
skills** for AI coding agents — is the reference companion. Every pairing below is
**optional by design**: Kurama never takes a hard dependency on superpowers (or any
external skill), and the pipeline runs identically when they are absent.

The reverse also holds, and the orchestrator prompt enforces it ("SDD owns the work
lifecycle", in the SDD Session Protocol): when Kurama is installed, external process
skills run **inside** SDD phases, never as replacement pipelines. superpowers' own
rules state that CLAUDE.md/AGENTS.md instructions take precedence over its skills —
the orchestrator prompt is that instruction, so a natural-language feature request
enters `/sdd-new` even when a session-level skill advertises itself as mandatory
for any creative work.

## Zero-config discovery

There is nothing to wire up. superpowers installs as ordinary `*/SKILL.md` files in a
user-level skills directory (e.g. `~/.claude/skills/`), which is exactly where
[`skill-registry`](../skills/skill-registry/SKILL.md) already scans. If superpowers is
installed, the registry indexes its process skills into `.kurama/skill-registry.md` on
the next build, and the orchestrator resolves them by trigger like any other skill —
**no manifest edits, no config flags, no per-project setup**. If it is not installed,
the registry simply finds nothing and the phases behave exactly as before.

## Recommended pairings

Each row is a suggestion the orchestrator MAY act on when the matching skill is
present. None is required; none changes phase control flow.

| superpowers skill | Kurama touchpoint | What it adds |
|-------------------|-------------------|--------------|
| `brainstorming` | `sdd-explore` / `sdd-propose` | A product/spec refinement round before the exploration or proposal is written — surfaces intent and requirements through structured questions. |
| `systematic-debugging` | `sdd-apply` and `sdd-verify`-FAIL fix loops | Root-cause investigation before any fix — no patch lands until the failure is understood. |
| `verification-before-completion` | `sdd-verify` / `sdd-archive` gates | Reinforces the completion gates with fresh, captured evidence before a change is declared done or archived. |
| `receiving-code-review` | 4R review lenses and `judgment-day` | A rigorous way to process review findings — verify each point technically instead of performative agreement — when consuming lens or judge output. |

## TDD compatibility

`superpowers:test-driven-development` and Kurama's optional [`tdd` module](tdd.md)
**share the same RED → GREEN → REFACTOR cycle** — they are compatible, not competing.
If both are installed you can drive the cycle with either; Kurama's module adds what an
SDD pipeline needs on top: **scenario→test traceability** (every MUST scenario maps to a
test) and **audited RED evidence** (`sdd-verify` checks the captured failing-test
output). Use superpowers' skill for the discipline, Kurama's module for the traceability
and the audit — or just one. Neither depends on the other.

## Nothing is a hard dependency

This is the whole point: companion skills are **additive and optional**. Kurama's value
— the spec-first DAG, context-isolated sub-agents, delta specs, and the review lenses —
is complete on its own. Installing superpowers layers extra process rigor onto the
phases that benefit most; removing it takes nothing away. There is no version pin, no
required install, and no phase that fails because a companion skill is missing.
