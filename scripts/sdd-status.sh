#!/usr/bin/env bash
# ============================================================================
# Agent Teams Lite — SDD Cycle Status
#
# Reports the state of every ACTIVE SDD cycle in a project: for each change it
# prints the last completed phase, the next phase recommended by the canonical
# DAG, the visible pipeline settings, and task progress. A --json flag emits the
# same data as a parseable object.
#
# Canonical Phase DAG (single source of truth: skills/_shared/sdd-phase-common.md)
#   explore -> propose -> (spec || design) -> tasks -> apply -> verify -> archive
#
# State is read from whichever artifact store left files on disk:
#   - openspec / hybrid : openspec/changes/<change>/state.yaml (+ artifacts)
#                         plus openspec/config.yaml for settings
#   - engram (degraded / filesystem fallback) : .atl/sdd/<change>/state.md
#                         (+ artifacts). This is the store engram uses when
#                         Engram is unavailable or a mem_save failed.
#
# LIMITATION — pure engram is NOT queryable offline. When a cycle's artifacts
# live only in Engram (Engram was available, nothing was written to disk), there
# is no engram CLI to query, so this script cannot see it. It reports on the
# on-disk openspec/ and .atl/sdd/ stores only. A cycle absent from both prints
# as "no active SDD cycles".
#
# Usage:
#   scripts/sdd-status.sh [PROJECT_PATH] [--json]
#     PROJECT_PATH  project root to inspect (default: current directory)
#     --json        emit a machine-parseable JSON object instead of text
#     -h, --help    show this help
#
# Exit codes:
#   0  success (including "no active SDD cycles")
#   1  PROJECT_PATH is not an accessible directory
#   2  usage error (unknown option / unexpected argument)
#
# Dependencies: POSIX shell utilities + git (git is not actually required by the
# current checks; jq is used for nothing here — JSON is emitted directly). No
# dependency outside a base POSIX toolchain. Bash 3.2 / BSD portable, and
# clean under shellcheck.
# ============================================================================

set -u

NL='
'

usage() {
  cat <<'EOF'
Usage: sdd-status.sh [PROJECT_PATH] [--json]

Reports the state of every active SDD cycle in a project.

Arguments:
  PROJECT_PATH   project root to inspect (default: current directory)

Options:
  --json         emit a machine-parseable JSON object instead of text
  -h, --help     show this help and exit

Reads on-disk state from openspec/changes/<change>/state.yaml (openspec/hybrid)
and .atl/sdd/<change>/state.md (engram filesystem fallback). Pure-engram cycles
with nothing written to disk are not queryable offline (no engram CLI).

Exit codes: 0 success (incl. no cycles), 1 bad path, 2 usage error.
EOF
}

# --- JSON helpers -----------------------------------------------------------
# Escape a scalar for embedding inside a JSON string (backslash, quote, and any
# stray control characters that would break the object).
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'
}
json_str() { printf '"%s"' "$(json_escape "$1")"; }
json_str_or_null() {
  if [ -n "$1" ]; then json_str "$1"; else printf 'null'; fi
}
json_bool_or_null() {
  case "$1" in
    true)  printf 'true' ;;
    false) printf 'false' ;;
    *)     printf 'null' ;;
  esac
}

# --- YAML scalar extractor (portable, no yaml parser) -----------------------
# yaml_scalar <file> <key> : first `key: value` scalar, comment / surrounding
# quotes / trailing whitespace stripped. Matches the key at any indentation
# (top-level or nested) since the keys we read (phase, compliance_mode,
# execution_mode) are unique within our config/state files.
yaml_scalar() {
  _f="$1"
  _k="$2"
  [ -f "$_f" ] || return 0
  grep -E "^[[:space:]]*${_k}:" "$_f" 2>/dev/null \
    | head -n 1 \
    | sed -E "s/^[[:space:]]*${_k}:[[:space:]]*//" \
    | sed -E 's/[[:space:]]*#.*$//' \
    | sed -e 's/^"//' -e 's/"$//' \
    | sed -E 's/[[:space:]]+$//'
}

# --- tdd.enabled extractor --------------------------------------------------
# `enabled:` is scoped to the top-level `tdd:` block so a future `enabled:` key
# elsewhere never leaks in. Prints true / false (or nothing if unset).
tdd_enabled() {
  _f="$1"
  [ -f "$_f" ] || return 0
  awk '
    /^tdd:[[:space:]]*$/            { intd = 1; next }
    /^[^[:space:]#]/               { intd = 0 }
    intd && /^[[:space:]]+enabled:/ {
      v = $0
      sub(/^[[:space:]]+enabled:[[:space:]]*/, "", v)
      sub(/[[:space:]]*#.*$/, "", v)
      gsub(/[[:space:]]/, "", v)
      print v
      exit
    }
  ' "$_f"
}

# --- artifact presence probes -----------------------------------------------
# openspec change dir holds any recognizable artifact?
os_has_artifacts() {
  _d="$1"
  [ -f "${_d}state.yaml" ]      && return 0
  [ -f "${_d}proposal.md" ]     && return 0
  [ -f "${_d}exploration.md" ]  && return 0
  [ -f "${_d}design.md" ]       && return 0
  [ -f "${_d}tasks.md" ]        && return 0
  [ -f "${_d}verify-report.md" ] && return 0
  [ -d "${_d}specs" ]           && return 0
  return 1
}
# .atl/sdd change dir holds any recognizable artifact?
atl_has_artifacts() {
  _d="$1"
  [ -f "${_d}state.md" ]           && return 0
  [ -f "${_d}explore.md" ]         && return 0
  [ -f "${_d}proposal.md" ]        && return 0
  [ -f "${_d}spec.md" ]            && return 0
  [ -f "${_d}design.md" ]          && return 0
  [ -f "${_d}tasks.md" ]           && return 0
  [ -f "${_d}apply-progress.md" ]  && return 0
  [ -f "${_d}verify-report.md" ]   && return 0
  return 1
}
# openspec spec delta present? (specs/<domain>/spec.md, or any *.md under specs/)
dir_has_spec() {
  _d="$1"
  [ -d "$_d" ] || return 1
  for _f in "$_d"/*/spec.md "$_d"/*.md; do
    [ -f "$_f" ] && return 0
  done
  return 1
}

# --- per-change processing --------------------------------------------------
# Appends a text block to TEXT_BUF and a JSON object to JSON_BUF, sets FOUND=1.
# Args: name  store_label  flavor(openspec|atl)  base_dir(trailing /)  state_file
process_change() {
  name="$1"
  store="$2"
  flavor="$3"
  base="$4"
  statef="$5"
  FOUND=1

  HAS_EXPLORE=0; HAS_PROPOSAL=0; HAS_SPEC=0; HAS_DESIGN=0; HAS_TASKS=0
  HAS_VERIFY=0; HAS_ARCHIVE=0; HAS_APPLY_PROGRESS=0
  tasks_file=""

  if [ "$flavor" = "openspec" ]; then
    [ -f "${base}exploration.md" ]  && HAS_EXPLORE=1
    [ -f "${base}proposal.md" ]     && HAS_PROPOSAL=1
    dir_has_spec "${base}specs"      && HAS_SPEC=1
    [ -f "${base}design.md" ]       && HAS_DESIGN=1
    if [ -f "${base}tasks.md" ]; then HAS_TASKS=1; tasks_file="${base}tasks.md"; fi
    [ -f "${base}verify-report.md" ] && HAS_VERIFY=1
    [ -f "${base}archive-report.md" ] && HAS_ARCHIVE=1
  else
    [ -f "${base}explore.md" ]        && HAS_EXPLORE=1
    [ -f "${base}proposal.md" ]       && HAS_PROPOSAL=1
    [ -f "${base}spec.md" ]           && HAS_SPEC=1
    [ -f "${base}design.md" ]         && HAS_DESIGN=1
    if [ -f "${base}tasks.md" ]; then HAS_TASKS=1; tasks_file="${base}tasks.md"; fi
    [ -f "${base}apply-progress.md" ] && HAS_APPLY_PROGRESS=1
    [ -f "${base}verify-report.md" ]  && HAS_VERIFY=1
    [ -f "${base}archive-report.md" ] && HAS_ARCHIVE=1
  fi

  # Task progress (checkbox count) — works for both flavors; sdd-apply marks
  # tasks.md `[x]` in every on-disk store.
  TASK_DONE=0; TASK_PENDING=0; TASK_TOTAL=0
  if [ -n "$tasks_file" ] && [ -f "$tasks_file" ]; then
    TASK_DONE=$(grep -cE '^[[:space:]]*- \[[xX]\]' "$tasks_file" 2>/dev/null)
    TASK_PENDING=$(grep -cE '^[[:space:]]*- \[[[:space:]]\]' "$tasks_file" 2>/dev/null)
    [ -n "$TASK_DONE" ]    || TASK_DONE=0
    [ -n "$TASK_PENDING" ] || TASK_PENDING=0
    TASK_TOTAL=$((TASK_DONE + TASK_PENDING))
  fi

  APPLY_COMPLETE=0
  if [ "$HAS_TASKS" = 1 ] && [ "$TASK_TOTAL" -gt 0 ] && [ "$TASK_PENDING" -eq 0 ]; then
    APPLY_COMPLETE=1
  fi

  # --- derive last / next phase from the canonical DAG ---
  NEXT_NOTE=""
  if [ "$HAS_ARCHIVE" = 1 ]; then
    LAST_PHASE="archive"; NEXT_PHASE="none"; NEXT_NOTE="cycle archived"
  elif [ "$HAS_VERIFY" = 1 ]; then
    LAST_PHASE="verify"; NEXT_PHASE="archive"
  elif [ "$HAS_TASKS" = 1 ] && [ "$APPLY_COMPLETE" = 1 ]; then
    LAST_PHASE="apply"; NEXT_PHASE="verify"
  elif [ "$HAS_TASKS" = 1 ] && { [ "$TASK_DONE" -gt 0 ] || [ "$HAS_APPLY_PROGRESS" = 1 ]; }; then
    LAST_PHASE="apply"; NEXT_PHASE="apply"; NEXT_NOTE="apply in progress"
  elif [ "$HAS_TASKS" = 1 ]; then
    LAST_PHASE="tasks"; NEXT_PHASE="apply"
  elif [ "$HAS_PROPOSAL" = 1 ]; then
    if [ "$HAS_SPEC" = 1 ] && [ "$HAS_DESIGN" = 1 ]; then
      LAST_PHASE="spec+design"; NEXT_PHASE="tasks"
    elif [ "$HAS_SPEC" = 1 ]; then
      LAST_PHASE="spec"; NEXT_PHASE="design"
    elif [ "$HAS_DESIGN" = 1 ]; then
      LAST_PHASE="design"; NEXT_PHASE="spec"
    else
      LAST_PHASE="propose"; NEXT_PHASE="spec"; NEXT_NOTE="spec and design both pending"
    fi
  elif [ "$HAS_EXPLORE" = 1 ]; then
    LAST_PHASE="explore"; NEXT_PHASE="propose"
  else
    LAST_PHASE="none"; NEXT_PHASE="explore"; NEXT_NOTE="explore optional — propose may follow"
  fi

  # --- recorded phase + settings ---
  recorded_phase=""
  [ -f "$statef" ] && recorded_phase="$(yaml_scalar "$statef" phase)"

  cm=""; em=""; td=""
  if [ "$flavor" = "openspec" ]; then
    cfg="$root/openspec/config.yaml"
    cm="$(yaml_scalar "$cfg" compliance_mode)"
    em="$(yaml_scalar "$cfg" execution_mode)"
    case "$(tdd_enabled "$cfg")" in
      true)  td="true" ;;
      false) td="false" ;;
      *)     td="" ;;
    esac
  fi

  state_rel=""
  [ -f "$statef" ] && state_rel="${statef#"$root"/}"

  # --- text block ---
  blk="$(
    printf 'Change: %s\n' "$name"
    printf '  Store:            %s\n' "$store"
    printf '  Last phase:       %s\n' "$LAST_PHASE"
    if [ -n "$NEXT_NOTE" ]; then
      printf '  Next phase:       %s  (%s)\n' "$NEXT_PHASE" "$NEXT_NOTE"
    else
      printf '  Next phase:       %s\n' "$NEXT_PHASE"
    fi
    printf '  compliance_mode:  %s\n' "${cm:-unknown}"
    printf '  execution_mode:   %s\n' "${em:-unknown}"
    printf '  tdd.enabled:      %s\n' "${td:-unknown}"
    if [ "$HAS_TASKS" = 1 ]; then
      printf '  Tasks:            %s/%s complete (%s pending)\n' "$TASK_DONE" "$TASK_TOTAL" "$TASK_PENDING"
    else
      printf '  Tasks:            (no tasks.md yet)\n'
    fi
    [ -n "$recorded_phase" ] && printf '  Recorded phase:   %s\n' "$recorded_phase"
    [ -n "$state_rel" ]      && printf '  State file:       %s\n' "$state_rel"
  )"
  TEXT_BUF="${TEXT_BUF}${blk}${NL}${NL}"

  # --- json object ---
  if [ "$HAS_TASKS" = 1 ]; then
    tasks_json="$(printf '{"total":%s,"completed":%s,"pending":%s}' \
      "$TASK_TOTAL" "$TASK_DONE" "$TASK_PENDING")"
  else
    tasks_json="null"
  fi

  item="$(printf '{"name":%s,"store":%s,"last_phase":%s,"next_phase":%s,"next_note":%s,"recorded_phase":%s,"settings":{"artifact_store":%s,"compliance_mode":%s,"execution_mode":%s,"tdd_enabled":%s},"tasks":%s,"state_file":%s}' \
    "$(json_str "$name")" \
    "$(json_str "$store")" \
    "$(json_str "$LAST_PHASE")" \
    "$(json_str "$NEXT_PHASE")" \
    "$(json_str_or_null "$NEXT_NOTE")" \
    "$(json_str_or_null "$recorded_phase")" \
    "$(json_str "$store")" \
    "$(json_str_or_null "$cm")" \
    "$(json_str_or_null "$em")" \
    "$(json_bool_or_null "$td")" \
    "$tasks_json" \
    "$(json_str_or_null "$state_rel")")"

  if [ -z "$JSON_BUF" ]; then
    JSON_BUF="$item"
  else
    JSON_BUF="${JSON_BUF},${item}"
  fi
}

# --- argument parsing -------------------------------------------------------
json=0
proj=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json)    json=1 ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; break ;;
    -*)        printf 'sdd-status: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -z "$proj" ]; then
        proj="$1"
      else
        printf 'sdd-status: unexpected argument: %s\n' "$1" >&2
        exit 2
      fi
      ;;
  esac
  shift
done
# Any remaining args after `--` : first is the project path.
if [ $# -gt 0 ] && [ -z "$proj" ]; then
  proj="$1"
fi
[ -n "$proj" ] || proj="$PWD"

if [ ! -d "$proj" ]; then
  printf 'sdd-status: not a directory: %s\n' "$proj" >&2
  exit 1
fi
root="$(cd "$proj" 2>/dev/null && pwd)" || {
  printf 'sdd-status: cannot access: %s\n' "$proj" >&2
  exit 1
}
root="${root%/}"

# --- discover active changes ------------------------------------------------
FOUND=0
TEXT_BUF=""
JSON_BUF=""

os_changes="$root/openspec/changes"
atl_root="$root/.atl/sdd"

# openspec (and hybrid) changes first — they are authoritative when a change
# exists in both stores.
if [ -d "$os_changes" ]; then
  for d in "$os_changes"/*/; do
    [ -d "$d" ] || continue
    case "$d" in
      "$os_changes"/archive/) continue ;;
    esac
    os_has_artifacts "$d" || continue
    [ -f "${d}archive-report.md" ] && continue
    name="$(basename "$d")"
    store="openspec"
    if [ -d "$atl_root/$name" ] \
      && atl_has_artifacts "$atl_root/$name/" \
      && [ ! -f "$atl_root/$name/archive-report.md" ]; then
      store="hybrid"
    fi
    process_change "$name" "$store" "openspec" "$d" "${d}state.yaml"
  done
fi

# .atl/sdd changes not already covered by an openspec entry (degraded engram).
if [ -d "$atl_root" ]; then
  for d in "$atl_root"/*/; do
    [ -d "$d" ] || continue
    [ -f "${d}archive-report.md" ] && continue
    atl_has_artifacts "$d" || continue
    name="$(basename "$d")"
    if [ -d "$os_changes/$name" ] && os_has_artifacts "$os_changes/$name/"; then
      continue
    fi
    process_change "$name" "engram (fallback)" "atl" "$d" "${d}state.md"
  done
fi

# --- emit -------------------------------------------------------------------
if [ "$json" = 1 ]; then
  printf '{"project":%s,"changes":[%s]}\n' "$(json_str "$root")" "$JSON_BUF"
  exit 0
fi

if [ "$FOUND" = 0 ]; then
  printf 'No active SDD cycles under %s\n' "$root"
  printf '(reads openspec/ and .atl/sdd/ fallback state; pure-engram cycles are not queryable offline — no engram CLI)\n'
  exit 0
fi

printf 'SDD status — %s\n\n' "$root"
printf '%s' "$TEXT_BUF"
exit 0
