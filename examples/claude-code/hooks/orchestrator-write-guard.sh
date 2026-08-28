#!/usr/bin/env bash
# ============================================================================
# Kurama — Orchestrator Write Guard (PreToolUse hook)
#
# Enforces the orchestrator's delegate-only contract as a MECHANISM instead of
# prose. While an SDD cycle is active, it blocks the ORCHESTRATOR (main thread)
# from writing repository code directly with Edit / Write / MultiEdit — the
# orchestrator must delegate that work to a sub-agent. SDD artifact / harness
# paths (.kurama/, openspec/) are always exempt so state and artifacts can still be
# persisted. When no SDD cycle is active, every write is allowed.
#
# Contract (Claude Code PreToolUse):
#   - reads the tool payload as JSON on stdin
#   - exit 0  -> allow the tool call
#   - exit 2  -> block the tool call; stderr is fed back to the model
#
# PreToolUse hooks fire for subagent tool calls too. This guard detects
# subagent context via the `agent_id` field in the hook stdin (present ONLY
# inside subagents, per the Claude Code hooks contract) and lets every
# delegated writer (sdd-apply, fix agents) pass — only MAIN-thread writes are
# gated. See README.md for the KURAMA_GUARD_BYPASS escape hatch.
#
# Bash 3.2 / BSD portable. shellcheck-clean. No jq dependency (used if present).
# ============================================================================

set -u

# --- escape hatches ---------------------------------------------------------
# Disable the guard entirely for this session/project.
if [ "${KURAMA_ORCHESTRATOR_GUARD:-1}" = "0" ]; then
  exit 0
fi
# Per-call bypass — for a context that legitimately writes code (e.g. a
# delegated writer) but still triggers this hook on a given Claude Code build.
if [ "${KURAMA_GUARD_BYPASS:-0}" = "1" ]; then
  exit 0
fi

# --- read the hook payload from stdin ---------------------------------------
payload=""
if [ ! -t 0 ]; then
  payload="$(cat)"
fi

# --- portable JSON string field extractors ----------------------------------
# json_str <field>      : first string value for <field> found ANYWHERE in the
#                         payload — the right tool for a field that lives inside
#                         tool_input (file_path).
# json_root_str <field> : the string value of a ROOT-level <field> and nothing
#                         else — see the subagent pass-through below for why.
# Both prefer jq and fall back to a POSIX scan when jq is unavailable.
json_str() {
  field="$1"
  [ -n "$payload" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" \
      | jq -r --arg f "$field" '.. | objects | .[$f]? // empty' 2>/dev/null \
      | head -n 1
    return 0
  fi
  printf '%s' "$payload" \
    | tr -d '\n' \
    | grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -n 1 \
    | sed -e "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"//" -e 's/"$//'
}

json_root_str() {
  field="$1"
  [ -n "$payload" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" \
      | jq -r --arg f "$field" '.[$f]? | strings' 2>/dev/null \
      | head -n 1
    return 0
  fi
  # No jq: split the payload on the quote character and walk the pieces — the scan
  # a character loop would do, at C speed (this hook runs on EVERY tool call and a
  # Write payload can be megabytes). Pieces OUTSIDE strings carry the brace/bracket
  # depth; pieces inside them carry none, so nothing within a string — a nested key,
  # or file CONTENT that spells one out — can move it. "<field>" is accepted only as
  # a key of the ROOT object (depth 1), wherever it sits in the KEY ORDER, and only
  # a string value is returned: null, a number or an object reads as absent, exactly
  # as the jq branch above returns it. A quote preceded by an odd number of
  # backslashes is escaped and does not end its string. Escape sequences inside the
  # value are NOT expanded — the fields read this way are a token and a path. awk
  # seeds every variable to 0/"" on first use, so no BEGIN block is needed.
  printf '%s' "$payload" | awk -v field="$field" '
    {
      n = split($0, seg, "\"")
      for (k = 1; k <= n; k++) {
        s = seg[k]
        if (instr) {
          if (depth == 1) { str = str s }        # only a root string can ever matter
        } else {
          if (pend == 2) {                       # key matched: a colon must follow
            if (s ~ /^[ \t\r\n]*:[ \t\r\n]*$/) { pend = 1 }
            else if (s !~ /^[ \t\r\n]*$/)      { pend = 0 }
          } else if (pend == 1 && s !~ /^[ \t\r\n]*$/) { pend = 0 }
          t = s; depth += gsub(/[[{]/, "", t)
          t = s; depth -= gsub(/[]}]/, "", t)
        }
        if (k == n) { break }                    # no quote closes the last piece
        if (instr && match(s, /\\+$/) && RLENGTH % 2 == 1) {
          if (depth == 1) { str = str "\"" }     # escaped quote: the string goes on
          continue
        }
        if (instr) {
          instr = 0
          if (pend == 1) { printf "%s", str; exit 0 }
          pend = (depth == 1 && str == field) ? 2 : 0
        } else {
          instr = 1; str = ""
        }
      }
    }
  '
}

# --- subagent pass-through ---------------------------------------------------
# PreToolUse hooks fire for EVERY tool call in the session, including tool
# calls made inside subagents. The hook stdin carries `agent_id`/`agent_type`
# ONLY in subagent context (documented Claude Code hooks contract) — absent on
# the main thread. Delegated workers (sdd-apply, fix agents, review fixers)
# are the INTENDED writers, so any subagent call passes; this guard exists to
# stop the MAIN-thread orchestrator from writing code inline.
#
# HARDENED extraction: agent_id is read at the JSON ROOT only — never from
# anywhere else in the payload — so an "agent_id" carried inside tool_input (the
# user-controlled half: a nested key, or file CONTENT that spells one out) can
# never spoof the check. json_root_str enforces that on BOTH halves: jq indexes
# the root object directly, and the no-jq fallback walks the payload tracking
# brace depth and accepts the key only at depth 1.
#
# Neither half depends on KEY ORDER. JSON does not guarantee one, and the
# previous fallback got its root-anchoring by scanning only the prefix before
# "tool_input" — so a payload that serialized tool_input FIRST read as an empty
# agent_id and the guard blocked every delegated writer on a jq-less host.
#
# ASSUMPTION (fail-open by design): if a future Claude Code build adds
# agent_id to MAIN-thread payloads, this guard neutralizes silently.
# Re-verify the hooks contract on Claude Code upgrades.
agent_id="$(json_root_str agent_id)"
if [ -n "$agent_id" ]; then
  exit 0
fi

# --- resolve project root ---------------------------------------------------
# cwd is a ROOT field of the hooks contract, so it is read as one: a tool_input
# that carries its own "cwd" (several tools take one) must not redirect the root
# the exemptions below are computed against — an unanchored read there resolves
# a root the target file is not under, and the guard allows the write.
project_root="${CLAUDE_PROJECT_DIR:-}"
[ -n "$project_root" ] || project_root="$(json_root_str cwd)"
[ -n "$project_root" ] || project_root="$PWD"
root="${project_root%/}"

# --- resolve target file path -----------------------------------------------
# Edit, Write and MultiEdit all carry a single "file_path".
file_path="$(json_str file_path)"
# Nothing to guard (unknown tool shape) -> allow.
[ -n "$file_path" ] || exit 0

case "$file_path" in
  /*) abs_path="$file_path" ;;
  *)  abs_path="$root/$file_path" ;;
esac

# --- is an SDD cycle active? ------------------------------------------------
# openspec mode        : an active change dir (NOT under changes/archive/) that
#                        still holds a state.yaml.
# engram-fallback mode : a .kurama/sdd/<change>/ dir with state.md and no
#                        archive-report.md (archiving writes the report).
active_cycle_exists() {
  base="$1"
  d=""

  if [ -d "$base/openspec/changes" ]; then
    for d in "$base"/openspec/changes/*/; do
      [ -d "$d" ] || continue
      case "$d" in
        "$base"/openspec/changes/archive/) continue ;;
      esac
      [ -f "${d}state.yaml" ] && return 0
    done
  fi

  if [ -d "$base/.kurama/sdd" ]; then
    for d in "$base"/.kurama/sdd/*/; do
      [ -d "$d" ] || continue
      if [ -f "${d}state.md" ] && [ ! -f "${d}archive-report.md" ]; then
        return 0
      fi
    done
  fi

  return 1
}

# No active cycle -> normal (non-SDD) work, allow everything.
active_cycle_exists "$root" || exit 0

# --- path exemptions --------------------------------------------------------
case "$abs_path" in
  "$root"/.kurama/*)     exit 0 ;;  # harness state directory — always writable
  "$root"/openspec/*) exit 0 ;;  # SDD artifacts — always writable
  "$root"/*)          : ;;       # inside the repo — this is the guarded case
  *)                  exit 0 ;;  # outside the repo — not our concern
esac

# --- block: an active cycle + a direct write to repo code -------------------
printf '%s\n' \
  "BLOCKED by kurama orchestrator-write-guard: an SDD cycle is active and \"$file_path\" is repository code." \
  "The orchestrator is a COORDINATOR — it must DELEGATE code changes to a sub-agent (e.g. launch sdd-apply via the Task tool) instead of editing files directly." \
  "Exempt paths you may still write: .kurama/ (harness state) and openspec/ (SDD artifacts)." \
  "To override for this call only, set KURAMA_GUARD_BYPASS=1; to disable the guard, set KURAMA_ORCHESTRATOR_GUARD=0." >&2
exit 2
