# Architecture

Deep dive into how Agent Teams Lite is structured. For quick start, see the [main README](../README.md).

---

## Where Agent Teams Lite Fits

Agent Teams Lite sits between basic sub-agent patterns and full Agent Teams runtimes:

```mermaid
graph TB
    subgraph "Level 1 — Basic Subagents"
        L1_Lead["Lead Agent"]
        L1_Sub1["Sub-agent 1"]
        L1_Sub2["Sub-agent 2"]
        L1_Lead -->|"fire & forget"| L1_Sub1
        L1_Lead -->|"fire & forget"| L1_Sub2
    end

    subgraph "Level 2 — Agent Teams Lite ⭐"
        L2_Orch["Orchestrator<br/>(delegate-only)"]
        L2_Explore["Explorer"]
        L2_Propose["Proposer"]
        L2_Spec["Spec Writer"]
        L2_Design["Designer"]
        L2_Tasks["Task Planner"]
        L2_Apply["Implementer"]
        L2_Verify["Verifier"]
        L2_Archive["Archiver"]

        L2_Orch -->|"DAG phase"| L2_Explore
        L2_Orch -->|"DAG phase"| L2_Propose
        L2_Orch -->|"parallel"| L2_Spec
        L2_Orch -->|"parallel"| L2_Design
        L2_Orch -->|"DAG phase"| L2_Tasks
        L2_Orch -->|"batched"| L2_Apply
        L2_Orch -->|"DAG phase"| L2_Verify
        L2_Orch -->|"DAG phase"| L2_Archive

        L2_Store[("Pluggable Store<br/>engram | openspec | hybrid | none")]
        L2_Registry[("Skill Registry<br/>auto-discover coding skills<br/>+ project conventions")]
        L2_Spec -.->|"persist"| L2_Store
        L2_Design -.->|"persist"| L2_Store
        L2_Apply -.->|"persist"| L2_Store
        L2_Orch -.->|"resolves once"| L2_Registry
        L2_Orch -.->|"pre-resolved paths"| L2_Explore
        L2_Orch -.->|"pre-resolved paths"| L2_Apply
        L2_Orch -.->|"pre-resolved paths"| L2_Verify
    end

    subgraph "Level 3 — Full Agent Teams"
        L3_Orch["Orchestrator"]
        L3_A1["Agent A"]
        L3_A2["Agent B"]
        L3_A3["Agent C"]
        L3_Queue[("Shared Task Queue<br/>claim / heartbeat")]

        L3_Orch -->|"manage"| L3_Queue
        L3_A1 <-->|"claim & report"| L3_Queue
        L3_A2 <-->|"claim & report"| L3_Queue
        L3_A3 <-->|"claim & report"| L3_Queue
        L3_A1 <-.->|"peer comms"| L3_A2
        L3_A2 <-.->|"peer comms"| L3_A3
    end

    style L2_Orch fill:#4CAF50,color:#fff,stroke:#333
    style L2_Store fill:#2196F3,color:#fff,stroke:#333
    style L2_Registry fill:#9C27B0,color:#fff,stroke:#333
    style L3_Queue fill:#FF9800,color:#fff,stroke:#333
```

---

## Capability Comparison

| Capability | Basic Subagents | Agent Teams Lite | Full Agent Teams |
|---|:---:|:---:|:---:|
| Delegate-only lead | — | ✅ | ✅ |
| DAG-based phase orchestration | — | ✅ | ✅ |
| Parallel phases (spec ∥ design) | — | ✅ | ✅ |
| Structured result envelope | — | ✅ | ✅ |
| Pluggable artifact store | — | ✅ | ✅ |
| **Skill auto-discovery** | — | ✅ | ✅ |
| Shared task queue with claim/heartbeat | — | — | ✅ |
| Teammate ↔ teammate communication | — | — | ✅ |
| Dynamic work stealing | — | — | ✅ |

---

## System Architecture

```
┌──────────────────────────────────────────────────────────┐
│  ORCHESTRATOR (coordinator — never does real work)         │
│                                                           │
│  Responsibilities:                                        │
│  • Delegate ALL tasks to sub-agents (not just SDD)        │
│  • Launch sub-agents via Task tool                        │
│  • Show summaries to user                                 │
│  • Ask for approval between phases                        │
│  • Track state: which artifacts exist, what's next        │
│  • Suggest SDD for substantial features/refactors         │
│                                                           │
│  Context usage: MINIMAL (only state + summaries)          │
└──────────────┬───────────────────────────────────────────┘
               │
               │ Task(subagent_type: 'general', prompt: 'Read skill...')
               │
    ┌──────────┴──────────────────────────────────────────┐
    │                                                      │
    ▼          ▼          ▼         ▼         ▼           ▼
┌────────┐┌────────┐┌────────┐┌────────┐┌────────┐┌────────┐
│EXPLORE ││PROPOSE ││  SPEC  ││ DESIGN ││ TASKS  ││ APPLY  │ ...
│        ││        ││        ││        ││        ││        │
│ Fresh  ││ Fresh  ││ Fresh  ││ Fresh  ││ Fresh  ││ Fresh  │
│context ││context ││context ││context ││context ││context │
└───┬────┘└───┬────┘└───┬────┘└───┬────┘└───┬────┘└───┬────┘
    │         │         │         │         │         │
    └─────────┴─────────┴────┬────┴─────────┴─────────┘
                             │
               (receive pre-resolved compact rules
                from the orchestrator's launch prompt)
                             │
                 ┌───────────▼───────────┐      ┌────────────────────┐
                 │    SUB-AGENT USES     │      │   SKILL REGISTRY   │
                 │   skills as directed  │      │                    │
                 │ • React, TDD, etc.   │      │ • Your coding      │
                 │ • Project conventions │      │   skills + paths   │
                 └───────────────────────┘      │ • Project conven- │
                                                │   tions (agents.md)│
                           ORCHESTRATOR ────────▶ resolves once/session
                                                └────────────────────┘
```

---

## The Dependency Graph

The canonical phase DAG — `explore → propose → (spec ∥ design) → tasks → apply
→ verify → archive` — is declared once in
[`skills/_shared/sdd-phase-common.md`](../skills/_shared/sdd-phase-common.md).
See it there instead of duplicating the graph here; the "Where Agent Teams Lite
Fits" diagram above renders the same flow visually.

---

## Sub-Agent Result Contract

Every sub-agent returns a structured envelope (`status`, `executive_summary`, `detailed_report`, `artifacts`, `next_recommended`, `risks`, `skill_resolution`) to the orchestrator. The canonical field list, description, and example live in [`skills/_shared/sdd-phase-common.md`](../skills/_shared/sdd-phase-common.md), Section D — see it there instead of duplicating it here.

---

## Project Structure

```
agent-teams-lite/
├── README.md                          ← Project overview and quick start
├── LICENSE
├── VERSION                            ← Version source of truth; installers and skills/manifest.json reference it
├── gemini-extension.json              ← Gemini CLI extension manifest (GEMINI.md + skills/); alternative to manual copy
├── .claude-plugin/                    ← Claude Code plugin packaging (alternative to manual copy)
│   ├── plugin.json                    ← name/version (from VERSION)/description/skills path
│   └── marketplace.json               ← Single-entry marketplace example for `/plugin marketplace add`
├── skills/                            ← 19 skill files + shared conventions
│   ├── manifest.json                  ← Declares every skill (group: sdd-core | quality | optional | tdd) + per-harness install targets; installers read this instead of a hardcoded list
│   ├── _shared/                       ← Shared conventions (referenced by all skills)
│   │   ├── sdd-phase-common.md        ← Most load-bearing shared file: Sections A-D (skill loading, retrieval, persistence, envelope), loaded by all 8 SDD phase skills
│   │   ├── persistence-contract.md    ← Mode resolution, sub-agent context protocol, skill loading
│   │   ├── engram-convention.md       ← Supplementary: deterministic naming & recovery
│   │   ├── openspec-convention.md     ← File paths, directory structure, config reference — ATL's own convention, NOT the upstream OpenSpec CLI format
│   │   ├── skill-resolver.md          ← Canonical orchestrator protocol for compact-rule injection
│   │   └── test-runners.md            ← Per-runner detect → full-suite + single-test command table, used by the optional TDD module
│   ├── sdd-init/SKILL.md             ← Bootstraps project + builds skill registry
│   ├── sdd-new/SKILL.md              ← Meta-skill: starts a new SDD change (exploration + proposal)
│   ├── sdd-continue/SKILL.md         ← Meta-skill: resumes a change from persisted state
│   ├── sdd-ff/SKILL.md               ← Meta-skill: fast-forwards remaining phases with auto-continue
│   ├── sdd-explore/SKILL.md
│   ├── sdd-propose/SKILL.md
│   ├── sdd-spec/SKILL.md
│   ├── sdd-design/SKILL.md
│   ├── sdd-tasks/SKILL.md
│   ├── sdd-apply/SKILL.md            ← v2.0: TDD workflow support
│   ├── sdd-verify/SKILL.md           ← v2.0: Real test execution + spec compliance matrix
│   ├── sdd-archive/SKILL.md
│   ├── skill-registry/SKILL.md       ← Scans skills + conventions, writes .atl/skill-registry.md
│   ├── judgment-day/SKILL.md         ← Dual blind review + fix loop
│   ├── go-testing/SKILL.md           ← Shared Go test patterns
│   ├── skill-creator/SKILL.md        ← Creates new skills from templates
│   ├── tdd/SKILL.md                  ← Optional RED-GREEN-REFACTOR module (opt-in `tdd` group, not installed by default)
│   ├── issue-creation/SKILL.md       ← GitHub issue creation workflow
│   └── branch-pr/SKILL.md            ← Branch + pull request workflow
├── docs/                              ← Deep-dive documentation
│   ├── architecture.md               ← This file: system design and structure
│   ├── changelog.md                  ← Release history
│   ├── concepts.md                   ← Delta specs, RFC 2119 keywords, archive cycle
│   ├── installation.md               ← Per-tool setup (automated + manual + plugin/extension)
│   ├── migration.md                  ← Breaking-change and upgrade guide across phases
│   ├── persistence.md                ← Artifact store modes and OpenSpec file structure
│   ├── sub-agents.md                 ← SDD phase sub-agent reference, native subagents, and agent-teams mode
│   ├── tdd.md                        ← Optional TDD module: activation, cycle, verify audits
│   ├── hooks.md                      ← Optional Claude Code hooks: prose-to-mechanism quality gates
│   └── token-economics.md            ← Token cost analysis and delegation savings
├── examples/                          ← Config examples per tool — generated from _templates/, see below
│   ├── _templates/                    ← SSOT: core.md (shared orchestrator body) + one {harness}.md overlay per harness; scripts/build-examples.sh assembles both into every file below
│   ├── claude-code/
│   │   ├── CLAUDE.md                  ← GENERATED — edit _templates/, then run scripts/build-examples.sh
│   │   ├── agents/                    ← Native subagents, one per SDD phase (model: opus for sdd-design/sdd-apply, sonnet for the rest)
│   │   └── hooks/                     ← Optional PreToolUse + archive-gate hooks (hooks.json + scripts + README); opt-in, not installed by default
│   ├── opencode/
│   │   ├── AGENTS.md                  ← OpenCode orchestrator prompt referenced by config
│   │   ├── opencode.single.json       ← Orchestrator agent only; phases run as subtasks
│   │   ├── opencode.multi.json        ← Orchestrator + dedicated sdd-<phase> agents, model customizable per phase
│   │   ├── commands/sdd-*.md          ← Slash commands for OpenCode
│   │   └── plugins/background-agents.ts ← Async background delegation plugin (both modes)
│   ├── gemini-cli/GEMINI.md
│   ├── codex/agents.md
│   ├── vscode/copilot-instructions.md
│   ├── antigravity/sdd-orchestrator.md
│   └── cursor/.cursor/rules/sdd-orchestrator.mdc
└── scripts/
    ├── setup.sh                       ← Full setup: detect + install + configure (Unix)
    ├── setup.ps1                      ← Full setup: detect + install + configure (Windows)
    ├── install.sh                     ← Skills-only installer (Unix); reads skills/manifest.json
    ├── install.ps1                    ← Skills-only installer (Windows); reads skills/manifest.json
    ├── install_test.sh                ← Regression test suite for install.sh
    ├── uninstall.sh                   ← Removes exactly what an install manifest recorded
    └── build-examples.sh              ← Assembles examples/_templates/ into every examples/* orchestrator file (portable bash 3.2/BSD)

# Generated in target projects (not in this repo):
.atl/
├── skill-registry.md                  ← Auto-generated skill catalog for sub-agents
└── sdd/{change-name}/                 ← Engram fallback store (unavailable-at-start or mid-cycle mem_save failure)
```
