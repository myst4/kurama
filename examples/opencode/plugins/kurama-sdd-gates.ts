// kurama-sdd-gates — the two deterministic SDD gates, on OpenCode.
//
// This is a THIN ADAPTER, not a second implementation. The decision logic for
// both gates lives in exactly one place — the bash scripts under
// examples/claude-code/hooks/ — and this file only:
//
//   1. translates an OpenCode `tool.execute.before` / `command.execute.before`
//      event into the Claude Code PreToolUse payload those scripts already read
//      on stdin, and
//   2. turns their exit code back into an OpenCode veto.
//
// Keeping one implementation is the whole point: a TypeScript re-write of the
// active-cycle detection, the path exemptions, the verdict parser and the
// Content Binding tree hash would drift from the bash originals silently, and
// the two harnesses would then enforce two different contracts under one name.
//
// ── Why a veto is possible here at all (verified against the shipped runtime,
//    not the docs — see docs/hooks.md "Enforcement tiers") ───────────────────
//
// `@opencode-ai/plugin` declares the pre-tool hook as
//
//     "tool.execute.before"?: (input: { tool, sessionID, callID },
//                              output: { args }) => Promise<void>
//
// The return type is `void`, so a returned value can never deny — THROWING is
// the only veto. And it works: OpenCode's tool wrapper awaits the trigger
// before the tool body,
//
//     yield* i.trigger("tool.execute.before", {...}, {args:b});
//     let h = yield* u.execute(b, H);
//
// and `Plugin.trigger` runs each hook with no try/catch of its own — unlike the
// `dispose` hook right beside it, which explicitly swallows errors. A rejected
// hook promise therefore aborts the tool call before it executes.
//
// ── The two payload fields OpenCode does NOT hand us ────────────────────────
//
// The event carries no `cwd` and no agent identity, which are exactly the two
// root fields the bash gates read. Both are recovered from the plugin input:
//
//   cwd       -> PluginInput.directory (the project root OpenCode resolved).
//   agent_id  -> a task-tool subagent runs in a CHILD session: the task tool
//                creates it with `parentID: <caller sessionID>`. So a session
//                whose `parentID` is set is the OpenCode analogue of Claude
//                Code's `agent_id`, and it is resolved through the plugin
//                client (`client.session.get`) and cached per session id.
//
// The root-anchoring hardening the bash guard carries still holds, and for a
// stronger reason: this adapter BUILDS the JSON itself, so `cwd` and `agent_id`
// are at the root by construction and anything model-controlled stays nested
// under `tool_input`, where neither extractor will honour it.

import { spawn } from "node:child_process"
import { existsSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

// ---------------------------------------------------------------------------
// Locating the gate scripts
// ---------------------------------------------------------------------------
// The scripts are installed alongside the plugin (see docs/installation.md).
// KURAMA_HOOKS_DIR overrides the search for tests and unusual layouts.
//
// TODO(setup): `setup_opencode()` in scripts/setup.sh does not install this file
// yet — issue #106 owns that script, so the step is sequenced separately. It is
// three copies with no config merge (OpenCode auto-discovers the plugins
// directory, which is how the retired plugin was found and how upstream installs
// its own), each recorded in RECEIPT_FILES so uninstall.sh removes them:
//
//   global  ~/.config/opencode/plugins/kurama-sdd-gates.ts
//           ~/.config/opencode/kurama/hooks/orchestrator-write-guard.sh   (chmod +x)
//           ~/.config/opencode/kurama/hooks/archive-gate.sh               (chmod +x)
//   project <repo>/.opencode/plugins/  and  <repo>/.opencode/kurama/hooks/
//
// Sources: examples/opencode/plugins/kurama-sdd-gates.ts and the two scripts in
// examples/claude-code/hooks/. Until that lands, install by hand — the layout is
// documented in docs/installation.md under "Enforcement tier: enforced".
const HOOK_DIR_CANDIDATES = (directory: string): string[] => {
  const explicit = process.env.KURAMA_HOOKS_DIR
  if (explicit) return [explicit]
  return [
    join(directory, ".opencode", "kurama", "hooks"),
    join(homedir(), ".config", "opencode", "kurama", "hooks"),
  ]
}

const WRITE_GUARD = "orchestrator-write-guard.sh"
const ARCHIVE_GATE = "archive-gate.sh"

const resolveHook = (directory: string, name: string): string | undefined => {
  for (const dir of HOOK_DIR_CANDIDATES(directory)) {
    const candidate = join(dir, name)
    if (existsSync(candidate)) return candidate
  }
  return undefined
}

// One warning per missing script per session: a gate that cannot run must say
// so out loud (silent non-enforcement is the failure mode these gates exist to
// remove), but it must not scream on every single tool call.
const warned = new Set<string>()
const warnOnce = (key: string, message: string): void => {
  if (warned.has(key)) return
  warned.add(key)
  console.error(`kurama-sdd-gates: ${message}`)
}

// ---------------------------------------------------------------------------
// Running a gate
// ---------------------------------------------------------------------------
// Same contract as Claude Code: JSON on stdin, exit 0 allows, exit 2 blocks and
// stderr is the message fed back to the model.
type GateResult = { blocked: boolean; message: string }

const runGate = (script: string, payload: unknown): Promise<GateResult> =>
  new Promise((resolve) => {
    const child = spawn("bash", [script], { stdio: ["pipe", "pipe", "pipe"] })
    let stderr = ""
    child.stderr.on("data", (chunk) => {
      stderr += String(chunk)
    })
    child.on("error", (error) => {
      // The gate could not be executed at all (no bash, bad permissions).
      resolve({ blocked: false, message: `could not run ${script}: ${error.message}` })
    })
    child.on("close", (code) => {
      resolve({ blocked: code === 2, message: stderr.trim() })
    })
    child.stdin.on("error", () => {})
    child.stdin.end(JSON.stringify(payload))
  })

// ---------------------------------------------------------------------------
// Subagent detection
// ---------------------------------------------------------------------------
// A delegated writer is the INTENDED author of repository code, exactly as on
// Claude Code — only MAIN-thread writes are gated. Session parentage never
// changes, so it is resolved once per session id and cached.
const parentage = new Map<string, boolean>()

const isSubagentSession = async (client: any, sessionID: string): Promise<boolean> => {
  const cached = parentage.get(sessionID)
  if (cached !== undefined) return cached
  try {
    const response = await client.session.get({ path: { id: sessionID } })
    const session = response?.data ?? response
    const result = typeof session?.parentID === "string" && session.parentID.length > 0
    parentage.set(sessionID, result)
    return result
  } catch (error) {
    // Fail OPEN, loudly. The bash guard is fail-open by documented assumption
    // too, and the alternative here is worse: treating an unresolvable session
    // as the main thread blocks the delegated writer — a gate that fails on the
    // happy path is a gate the model learns to switch off.
    warnOnce(
      `session:${sessionID}`,
      `could not resolve session ${sessionID} (${String(error)}); allowing the write guard through`,
    )
    return true
  }
}

// ---------------------------------------------------------------------------
// Payload construction
// ---------------------------------------------------------------------------
// Only the fields the scripts actually read are sent.
//
// The write guard reads `file_path` from anywhere in the payload and `cwd` /
// `agent_id` at the ROOT. Deliberately omitted: the file CONTENT. The guard
// never reads it, an OpenCode write payload can be megabytes, and shipping it
// would hand the payload a second place to spell "agent_id" for no gain.
const WRITE_TOOLS = new Set(["write", "edit", "patch", "multiedit"])

// OpenCode's write/edit tools carry `filePath`; the runtime itself still falls
// back to a legacy `filepath`, so both are accepted, plus the plain `path` a
// custom tool may use.
const filePathOf = (args: any): string | undefined => {
  for (const key of ["filePath", "filepath", "file_path", "path"]) {
    const value = args?.[key]
    if (typeof value === "string" && value.length > 0) return value
  }
  return undefined
}

const writePayload = (opts: {
  sessionID: string
  directory: string
  tool: string
  filePath: string
  subagent: boolean
}) => ({
  session_id: opts.sessionID,
  ...(opts.subagent ? { agent_id: opts.sessionID } : {}),
  cwd: opts.directory,
  hook_event_name: "PreToolUse",
  tool_name: opts.tool,
  tool_input: { file_path: opts.filePath },
})

// The archive gate decides for itself whether a launch is an sdd-archive one,
// and it reads exactly three fields, scoped to `tool_input`:
//
//   skill          — the Skill-tool spelling (`/sdd-archive`)
//   subagent_type  — the Task-tool spelling (the shipped `sdd-archive` agent)
//   description    — the short label of a generic launch
//
// Free-form text (`prompt`, `args`, `content`) is deliberately NOT consulted by
// the gate, because it is the model's own prose. This adapter therefore forwards
// those three fields and nothing else, and never pre-judges the launch itself:
// every `task` call is handed to the gate, which allows the non-archive ones.
const ARCHIVE_IDENTITY_KEYS = ["skill", "subagent_type", "description"]

const archivePayload = (opts: {
  sessionID: string
  directory: string
  tool: string
  identity: Record<string, string>
}) => ({
  session_id: opts.sessionID,
  cwd: opts.directory,
  hook_event_name: "PreToolUse",
  tool_name: opts.tool,
  tool_input: opts.identity,
})

const identityOf = (args: any): Record<string, string> => {
  const identity: Record<string, string> = {}
  for (const key of ARCHIVE_IDENTITY_KEYS) {
    const value = args?.[key]
    if (typeof value === "string" && value.length > 0) identity[key] = value
  }
  return identity
}

// ---------------------------------------------------------------------------
// The plugin
// ---------------------------------------------------------------------------
export const KuramaSddGates = async ({ client, directory }: any) => {
  const guardScript = resolveHook(directory, WRITE_GUARD)
  const gateScript = resolveHook(directory, ARCHIVE_GATE)

  // Degraded path only: the gate script is not installed, so its decision cannot
  // be asked for. Every other code path delegates the "is this an archive
  // launch?" question to the script — this is the one place a substring test
  // lives, and it exists so an unreachable gate still fails CLOSED on what looks
  // like an archive, instead of blocking every unrelated task launch.
  const missingGate = (identity: Record<string, string>): void => {
    warnOnce(
      "missing-archive-gate",
      `${ARCHIVE_GATE} is not installed. Re-run setup.sh --agent opencode.`,
    )
    if (!JSON.stringify(identity).includes("sdd-archive")) return
    throw new Error(
      "BLOCKED by kurama archive-gate: the gate script is not installed, so the verify-PASS gate cannot run. " +
        "Re-run setup.sh --agent opencode, or set KURAMA_ARCHIVE_OVERRIDE=1 with a reason recorded in the archive report.",
    )
  }

  return {
    "tool.execute.before": async (input: any, output: any) => {
      const tool = String(input?.tool ?? "")

      // ---- archive gate: a delegated phase launch ------------------------
      if (tool === "task") {
        const identity = identityOf(output?.args)
        if (!gateScript) {
          missingGate(identity)
          return
        }
        const result = await runGate(
          gateScript,
          archivePayload({ sessionID: String(input.sessionID), directory, tool: "Task", identity }),
        )
        if (result.blocked) throw new Error(result.message)
        return
      }

      // ---- write guard: a direct edit of repository code -----------------
      if (!WRITE_TOOLS.has(tool)) return
      const filePath = filePathOf(output?.args)
      if (!filePath) return
      if (!guardScript) {
        // Fails OPEN, matching the guard's own posture — but never silently.
        warnOnce(
          "missing-write-guard",
          `${WRITE_GUARD} is not installed; the delegate-only rule is PROSE ONLY in this session. Re-run setup.sh --agent opencode.`,
        )
        return
      }
      const sessionID = String(input.sessionID)
      if (await isSubagentSession(client, sessionID)) return
      const result = await runGate(
        guardScript,
        writePayload({ sessionID, directory, tool, filePath, subagent: false }),
      )
      if (result.blocked) throw new Error(result.message)
    },

    // Single-mode OpenCode runs the phases as slash commands rather than task
    // launches, so the archive gate has to watch that door too. A command name
    // is the Skill-tool spelling of an invoked identity, so it is forwarded as
    // `skill` — the exact field the gate reads for `/sdd-archive`.
    "command.execute.before": async (input: any) => {
      const identity = { skill: String(input?.command ?? "") }
      if (!gateScript) {
        missingGate(identity)
        return
      }
      const result = await runGate(
        gateScript,
        archivePayload({ sessionID: String(input.sessionID), directory, tool: "Skill", identity }),
      )
      if (result.blocked) throw new Error(result.message)
    },
  }
}

export default KuramaSddGates
