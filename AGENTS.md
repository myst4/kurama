# Agent Teams Lite — Agent Skills Index

When working on this project, load the relevant skill(s) BEFORE writing any code.

## How to Use

1. Check the trigger column to find skills that match your current task
2. Load the skill by reading the SKILL.md file at the listed path
3. Follow ALL patterns and rules from the loaded skill
4. Multiple skills can apply simultaneously

## Skills

| Skill | Trigger | Path |
|-------|---------|------|
| `sdd-init` | When initializing SDD in a project, or user says "sdd init". | [`skills/sdd-init/SKILL.md`](skills/sdd-init/SKILL.md) |
| `sdd-new` | When starting a new SDD change cycle, or user says "sdd new" / "start a change". | [`skills/sdd-new/SKILL.md`](skills/sdd-new/SKILL.md) |
| `sdd-continue` | When resuming an SDD change from persisted state, or user says "sdd continue". | [`skills/sdd-continue/SKILL.md`](skills/sdd-continue/SKILL.md) |
| `sdd-ff` | When fast-forwarding through the remaining SDD phases with auto-continue, or user says "sdd ff". | [`skills/sdd-ff/SKILL.md`](skills/sdd-ff/SKILL.md) |
| `sdd-explore` | When thinking through a feature, investigating the codebase, or clarifying requirements. | [`skills/sdd-explore/SKILL.md`](skills/sdd-explore/SKILL.md) |
| `sdd-propose` | When creating or updating a change proposal with intent, scope, and approach. | [`skills/sdd-propose/SKILL.md`](skills/sdd-propose/SKILL.md) |
| `sdd-spec` | When writing or updating specifications with requirements and scenarios. | [`skills/sdd-spec/SKILL.md`](skills/sdd-spec/SKILL.md) |
| `sdd-design` | When writing or updating technical design with architecture decisions. | [`skills/sdd-design/SKILL.md`](skills/sdd-design/SKILL.md) |
| `sdd-tasks` | When breaking down a change into implementation task checklist. | [`skills/sdd-tasks/SKILL.md`](skills/sdd-tasks/SKILL.md) |
| `sdd-apply` | When implementing tasks, writing actual code following specs and design. | [`skills/sdd-apply/SKILL.md`](skills/sdd-apply/SKILL.md) |
| `sdd-verify` | When validating that implementation matches specs, design, and tasks. | [`skills/sdd-verify/SKILL.md`](skills/sdd-verify/SKILL.md) |
| `sdd-archive` | When archiving a completed change after implementation and verification. | [`skills/sdd-archive/SKILL.md`](skills/sdd-archive/SKILL.md) |
| `tdd` | When a phase resolves TDD as active (`tdd.enabled`) and needs the RED-GREEN-REFACTOR cycle contract — loaded by sdd-apply, referenced by sdd-tasks and sdd-verify. | [`skills/tdd/SKILL.md`](skills/tdd/SKILL.md) |
| `skill-registry` | When creating or updating the skill registry for the project. | [`skills/skill-registry/SKILL.md`](skills/skill-registry/SKILL.md) |
| `judgment-day` | When running a dual adversarial review, or user says "judgment day". | [`skills/judgment-day/SKILL.md`](skills/judgment-day/SKILL.md) |
| `review-risk` | When the orchestrator selects the risk lens (security/permissions/data/dependencies) for a standard diff, or as one lens of a full-4R sweep. | [`skills/review-risk/SKILL.md`](skills/review-risk/SKILL.md) |
| `review-readability` | When the orchestrator selects the readability lens (naming/structure/maintainability) for a standard diff, or as one lens of a full-4R sweep. | [`skills/review-readability/SKILL.md`](skills/review-readability/SKILL.md) |
| `review-reliability` | When the orchestrator selects the reliability lens (behavior/tests/determinism/regressions) for a standard diff, or as one lens of a full-4R sweep. | [`skills/review-reliability/SKILL.md`](skills/review-reliability/SKILL.md) |
| `review-resilience` | When the orchestrator selects the resilience lens (shell/process integration, partial failures, recovery) for a standard diff, or as one lens of a full-4R sweep. | [`skills/review-resilience/SKILL.md`](skills/review-resilience/SKILL.md) |
| `review-refuter` | When the orchestrator runs adversarial verification after merging lens ledgers (one general task standard, three parallel lens tasks in 4R). | [`skills/review-refuter/SKILL.md`](skills/review-refuter/SKILL.md) |
| `go-testing` | When writing or reviewing Go tests, including Bubbletea/teatest patterns. | [`skills/go-testing/SKILL.md`](skills/go-testing/SKILL.md) |
| `skill-creator` | When creating a new skill or documenting agent instructions for AI. | [`skills/skill-creator/SKILL.md`](skills/skill-creator/SKILL.md) |
| `branch-pr` | When creating a pull request, opening a PR, or preparing changes for review. | [`skills/branch-pr/SKILL.md`](skills/branch-pr/SKILL.md) |
| `issue-creation` | When creating a GitHub issue, reporting a bug, or requesting a feature. | [`skills/issue-creation/SKILL.md`](skills/issue-creation/SKILL.md) |
