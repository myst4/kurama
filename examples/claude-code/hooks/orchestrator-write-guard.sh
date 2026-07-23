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

# --- portable JSON string field extractor -----------------------------------
# json_str <field> : prints the first matching string value found in $payload.
# Prefers jq; falls back to a grep/sed scan when jq is unavailable.
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

# --- subagent pass-through ---------------------------------------------------
# PreToolUse hooks fire for EVERY tool call in the session, including tool
# calls made inside subagents. The hook stdin carries `agent_id`/`agent_type`
# ONLY in subagent context (documented Claude Code hooks contract) — absent on
# the main thread. Delegated workers (sdd-apply, fix agents, review fixers)
# are the INTENDED writers, so any subagent call passes; this guard exists to
# stop the MAIN-thread orchestrator from writing code inline.
#
# HARDENED extraction: agent_id is read at the JSON ROOT only — never from
# anywhere in the payload — so file CONTENT containing "agent_id" (e.g. a Write
# of this very script) can never spoof the check. jq anchors to the root key;
# the no-jq fallback searches only the payload prefix BEFORE "tool_input"
# (agent metadata lives at the root; user-controlled content lives inside
# tool_input).
#
# ASSUMPTION (fail-open by design): if a future Claude Code build adds
# agent_id to MAIN-thread payloads, this guard neutralizes silently.
# Re-verify the hooks contract on Claude Code upgrades.
agent_id=""
if [ -n "$payload" ]; then
  if command -v jq >/dev/null 2>&1; then
    agent_id="$(printf '%s' "$payload" | jq -r '.agent_id // empty' 2>/dev/null)"
  else
    agent_id="$(printf '%s' "$payload" \
      | tr -d '\n' \
      | sed 's/"tool_input".*//' \
      | grep -o '"agent_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -n 1)"
  fi
fi
if [ -n "$agent_id" ]; then
  exit 0
fi

# --- resolve project root ---------------------------------------------------
project_root="${CLAUDE_PROJECT_DIR:-}"
[ -n "$project_root" ] || project_root="$(json_str cwd)"
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
