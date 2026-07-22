#!/usr/bin/env bash
# ============================================================================
# Agent Teams Lite — Archive Gate (verify-PASS gate for sdd-archive)
#
# Mechanical mirror of sdd-archive Step 0: NEVER archive a change whose
# verification report is missing or whose verdict is FAIL. Only a PASS or
# PASS WITH WARNINGS verdict lets archiving proceed. This turns the prose gate
# into a deterministic check.
#
# Two modes:
#   CLI  : archive-gate.sh <change-name>
#            exit 0 -> PASS / PASS WITH WARNINGS (archiving may proceed)
#            exit 2 -> report missing, verdict FAIL, or no PASS found
#   Hook : wire as a PreToolUse hook on Task|Skill. It reads the JSON payload on
#          stdin and only gates launches that reference "sdd-archive"; every
#          other Task/Skill call is allowed (exit 0).
#
# Override (escape hatch, mirrors sdd-archive Step 0's user-authorized override):
#   ATL_ARCHIVE_OVERRIDE=1  bypasses the gate. The override REASON must still be
#   recorded verbatim in the archive report by sdd-archive — this script only
#   opens the gate; it does not record anything.
#
# Bash 3.2 / BSD portable. shellcheck-clean. No jq dependency (used if present).
# ============================================================================

set -u

# --- read payload (present only in hook mode) -------------------------------
payload=""
if [ ! -t 0 ]; then
  payload="$(cat)"
fi

# Hook mode: a Task/Skill payload that is NOT an sdd-archive launch is none of
# our business — allow it. (CLI mode has an empty payload and skips this.)
if [ -n "$payload" ]; then
  case "$payload" in
    *sdd-archive*) : ;;
    *)             exit 0 ;;
  esac
fi

# --- override ---------------------------------------------------------------
if [ "${ATL_ARCHIVE_OVERRIDE:-0}" = "1" ]; then
  printf '%s\n' \
    "archive-gate: ATL_ARCHIVE_OVERRIDE=1 — bypassing the verify-PASS gate." \
    "sdd-archive Step 0 requires the override REASON to be recorded verbatim in the archive report and its return envelope risks." >&2
  exit 0
fi

# --- portable JSON string field extractor -----------------------------------
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

# --- portable modification time (epoch seconds; 0 if unknown) ---------------
# BSD/macOS stat exposes the mtime epoch as `-f %m`; GNU coreutils exposes it as
# `-c %Y` (GNU `%m` is the filesystem MOUNT POINT, not a time — never use it).
# On GNU, `stat -f %m FILE` misreads `-f` as --file-system and exits non-zero
# while still printing a filesystem block to stdout, so only trust the `-f`
# output when the command actually succeeded; otherwise fall back to `-c %Y`.
mtime() {
  if m="$(stat -f %m "$1" 2>/dev/null)" && [ -n "$m" ]; then
    printf '%s' "$m"
  else
    m="$(stat -c %Y "$1" 2>/dev/null)"
    printf '%s' "${m:-0}"
  fi
}

# --- resolve project root ---------------------------------------------------
project_root="${CLAUDE_PROJECT_DIR:-}"
[ -n "$project_root" ] || project_root="$(json_str cwd)"
[ -n "$project_root" ] || project_root="$PWD"
root="${project_root%/}"

# --- resolve the change name ------------------------------------------------
# Priority: explicit arg -> ATL_CHANGE env -> newest active change auto-detect.
change="${1:-${ATL_CHANGE:-}}"

if [ -z "$change" ]; then
  newest_mtime=0
  cand=""

  # A change is an archive candidate when it carries a verify-report (the thing
  # we gate on) or a live state file. Newest marker wins on ties.
  if [ -d "$root/openspec/changes" ]; then
    for d in "$root"/openspec/changes/*/; do
      [ -d "$d" ] || continue
      case "$d" in
        "$root"/openspec/changes/archive/) continue ;;
      esac
      marker=""
      [ -f "${d}verify-report.md" ] && marker="${d}verify-report.md"
      [ -z "$marker" ] && [ -f "${d}state.yaml" ] && marker="${d}state.yaml"
      [ -n "$marker" ] || continue
      m="$(mtime "$marker")"
      if [ "$m" -ge "$newest_mtime" ]; then
        newest_mtime="$m"
        cand="$(basename "$d")"
      fi
    done
  fi

  if [ -d "$root/.atl/sdd" ]; then
    for d in "$root"/.atl/sdd/*/; do
      [ -d "$d" ] || continue
      [ -f "${d}archive-report.md" ] && continue
      marker=""
      [ -f "${d}verify-report.md" ] && marker="${d}verify-report.md"
      [ -z "$marker" ] && [ -f "${d}state.md" ] && marker="${d}state.md"
      [ -n "$marker" ] || continue
      m="$(mtime "$marker")"
      if [ "$m" -ge "$newest_mtime" ]; then
        newest_mtime="$m"
        cand="$(basename "$d")"
      fi
    done
  fi

  change="$cand"
fi

# --- locate the verify report -----------------------------------------------
report=""
if [ -n "$change" ]; then
  if [ -f "$root/openspec/changes/$change/verify-report.md" ]; then
    report="$root/openspec/changes/$change/verify-report.md"
  elif [ -f "$root/.atl/sdd/$change/verify-report.md" ]; then
    report="$root/.atl/sdd/$change/verify-report.md"
  fi
fi

if [ -z "$report" ]; then
  printf '%s\n' \
    "BLOCKED by agent-teams-lite archive-gate: no verify-report found for change '${change:-<unknown>}'." \
    "sdd-archive Step 0 refuses to archive without a verification report recording a PASS verdict." \
    "Run sdd-verify first, or set ATL_ARCHIVE_OVERRIDE=1 with a reason recorded in the archive report." >&2
  exit 2
fi

# --- extract the verdict (mechanical mirror of Step 0) ----------------------
# Take the first non-empty line after the "### Verdict" heading; fall back to a
# standalone verdict line anywhere in the report.
verdict="$(awk '
  /^###[[:space:]]+Verdict/ { grab = 1; next }
  grab && /^[[:space:]]*$/  { next }
  grab                      { print; exit }
' "$report")"

if [ -z "$verdict" ]; then
  verdict="$(grep -iE '^[[:space:]]*(PASS WITH WARNINGS|PASS|FAIL)[[:space:]]*$' "$report" | head -n 1)"
fi

verdict_uc="$(printf '%s' "$verdict" | tr '[:lower:]' '[:upper:]')"

case "$verdict_uc" in
  *"{"*)
    reason="the verdict line looks like an unfilled template — the report is not finalized" ;;
  *FAIL*)
    reason="the verify verdict is FAIL (or lists unresolved CRITICAL issues)" ;;
  *PASS*)
    exit 0 ;;
  *)
    reason="no PASS verdict was found in the report" ;;
esac

printf '%s\n' \
  "BLOCKED by agent-teams-lite archive-gate: cannot archive '$change' — $reason." \
  "Report: $report" \
  "Fix the change and re-run sdd-verify to a PASS / PASS WITH WARNINGS verdict, or set ATL_ARCHIVE_OVERRIDE=1 with a reason recorded in the archive report." >&2
exit 2
