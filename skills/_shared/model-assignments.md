# Model Assignments — optional tiered routing

Reference for routing SDD phases to different model tiers. This file is NOT part
of the orchestrator prompt and is NOT read during a normal session: load it only
when someone has decided they want tiered routing and needs the recommended
split plus the way to apply it on their harness.

## The default is passive

By default, pass NO `model` parameter when delegating: every sub-agent inherits the model this session is configured to run, whatever the provider. This table is opt-in guidance for tiered routing — apply it only when the user has opted in through their own configuration, and never let it override a model the user configured.

Nothing below is an instruction to the orchestrator. It is a recommendation to a
human (or to an orchestrator acting on a human's explicit opt-in) about which
tier suits which phase.

## Recommended split

| Phase | Default Model | Reason |
|-------|---------------|--------|
| orchestrator | opus | Coordinates, makes decisions |
| sdd-explore | sonnet | Reads code, structural - not architectural |
| sdd-propose | sonnet | Structured proposal writing (architecture is decided in design) |
| sdd-spec | sonnet | Structured writing |
| sdd-design | opus | Architecture decisions |
| sdd-tasks | sonnet | Mechanical breakdown |
| sdd-apply | opus | Implementation quality is the product |
| sdd-verify | sonnet | Validation against spec |
| sdd-archive | sonnet | Merge fidelity over speed |
| default | sonnet | Non-SDD general delegation |

`opus` and `sonnet` name reasoning tiers, not pinned model ids — read them as
"the strongest model this session can reach" and "the fast general-purpose
model", and map them onto whatever the configured provider actually offers.
Models rotate and pins rot; that is why nothing in the shipped setup carries one.

## Applying it, per harness

**Claude Code** — the shipped subagents in `examples/claude-code/agents/`
(installed to `.claude/agents/`) carry no model pin. Add `model` to an agent's
frontmatter locally to give that phase a tier.

**OpenCode** — set `model` on the `sdd-<phase>` agent entries in
`opencode.json`, or install a named profile
(`setup.sh --agent opencode --opencode-profile NAME[:provider/model]`).

When running under a named profile (the `kurama-orchestrator` primary), the per-phase models come from the `sdd-<phase>-NAME` agent entries in `opencode.json` rather than from these aliases; delegate to those suffixed subagents and let each carry its own configured model. This table remains the default guidance for the base `sdd-orchestrator`.

**pi, omp and codex** — these harnesses route no model through the orchestrator
at all, and their orchestrator prompts say so. Apply the split through each
one's own local mechanism (agent frontmatter, `model_profiles` in
`.pi/subagents.json`, `task.agentModelOverrides`), never by passing a `model`
parameter from the orchestrator.
