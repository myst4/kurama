#!/usr/bin/env bash
# ============================================================================
# Kurama — Archive Gate (verify-PASS gate for sdd-archive)
#
# Mechanical mirror of sdd-archive Step 0: NEVER archive a change whose
# verification report is missing, whose verdict is FAIL, or whose Content Binding
# receipt is STALE. Only a PASS / PASS WITH WARNINGS verdict WHOSE recorded tree
# hash still matches the live working tree lets archiving proceed. This turns the
# prose gate into a deterministic check.
#
# Two independent checks (both mechanical mirrors of sdd-archive Step 0):
#   1. Verdict gate     — the persisted report must record PASS / PASS WITH WARNINGS.
#   2. Content binding  — the "Tree-Hash:" line sdd-verify stamped in the report's
#                         Content Binding section must still match the current tree.
#                         Recomputed the SAME way sdd-verify records it (throwaway
#                         index; the real index is never touched). A mismatch means
#                         the tree changed after verification -> STALE -> re-verify.
#                         Enforced only when the report carries the line AND the live
#                         hash is computable (a git checkout); a legacy report without
#                         it, or a non-git tree, falls back to the verdict gate alone.
#
# Two modes:
#   CLI  : archive-gate.sh <change-name>
#            exit 0 -> PASS / PASS WITH WARNINGS and binding fresh (archive may proceed)
#            exit 2 -> report missing, verdict FAIL, no PASS found, or receipt STALE
#   Hook : wire as a PreToolUse hook on Task|Skill. It reads the JSON payload on
#          stdin and only gates launches that reference "sdd-archive"; every
#          other Task/Skill call is allowed (exit 0).
#
# Override (escape hatch, mirrors sdd-archive Step 0's user-authorized override):
#   KURAMA_ARCHIVE_OVERRIDE=1  bypasses BOTH the verdict gate and the content-binding
#   check. The override REASON must still be recorded verbatim in the archive report
#   by sdd-archive — this script only opens the gate; it does not record anything.
#
# Bash 3.2 / BSD portable. shellcheck-clean. No jq dependency (used if present).
# ============================================================================

set -u

# --- read payload (present only in hook mode) -------------------------------
payload=""
if [ ! -t 0 ]; then
  payload="$(cat)"
fi

# --- portable JSON string field extractors ----------------------------------
# json_root_str <field>  : the string value of a ROOT-level <field> and nothing
#                          else. cwd is a root field of the hooks contract, and the
#                          two extraction halves must not disagree about which one
#                          they mean: an unanchored jq (`.. | objects`) walks the
#                          payload depth-first while a textual scan walks it in
#                          serialization order, so a tool_input carrying its own
#                          "cwd" (several tools take one) sends them to two
#                          different project roots — and the gate then hunts for the
#                          verify report under the wrong one.
# json_input_str <field> : the string value of a <field> that is a DIRECT key of
#                          the payload's `tool_input` object — where the launch
#                          IDENTITY the gate keys on lives.
#
# json_scoped_str below is kept byte-identical to orchestrator-write-guard.sh's
# copy — the two hooks must read the payload the same way.
json_scoped_str() {
  field="$1"
  # "" -> the field is a key of the ROOT object. Otherwise the name of a ROOT key
  # whose OBJECT value is searched instead (one level down, and only there).
  scope="$2"
  [ -n "$payload" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    if [ -z "$scope" ]; then
      printf '%s' "$payload" \
        | jq -r --arg f "$field" '.[$f]? | strings' 2>/dev/null \
        | head -n 1
    else
      printf '%s' "$payload" \
        | jq -r --arg f "$field" --arg s "$scope" '.[$s]? | objects | .[$f]? | strings' 2>/dev/null \
        | head -n 1
    fi
    return 0
  fi
  if [ -z "$scope" ]; then want=1; else want=2; fi
  # No jq: split the payload on the quote character and walk the pieces — the scan
  # a character loop would do, at C speed (this hook runs on EVERY tool call and a
  # Write payload can be megabytes). Pieces OUTSIDE strings carry the brace/bracket
  # depth; pieces inside them carry none, so nothing within a string — a nested key,
  # or file CONTENT that spells one out — can move it. "<field>" is accepted only at
  # the target depth (`want`: 1 for a root key, 2 for a key of the `scope` object)
  # and, when scoped, only while that object is open — so a same-named key in ANOTHER
  # root object, in a nested object, or in an array element is never returned no
  # matter where it sits in the KEY ORDER. Only a string value is returned: null, a
  # number or an object reads as absent, exactly as the jq branch above returns it.
  # A quote preceded by an odd number of backslashes is escaped and does not end its
  # string. Escape sequences inside the value are NOT expanded — the fields read this
  # way are a token and a path. `keep` also accumulates ROOT-level strings while
  # scoped, because that is where the scope key itself is recognized. awk seeds every
  # variable to 0/"" on first use, so no BEGIN block is needed.
  printf '%s' "$payload" | awk -v field="$field" -v scope="$scope" -v want="$want" '
    {
      n = split($0, seg, "\"")
      for (k = 1; k <= n; k++) {
        s = seg[k]
        inscope_ok = (scope == "" || inscope)
        keep = (depth == want && inscope_ok) || (scope != "" && depth == 1)
        if (instr) {
          if (keep) { str = str s }
        } else {
          if (spend == 2) {                      # scope key matched: ":" then "{"
            if (s ~ /^[ \t\r\n]*:[ \t\r\n]*\{[ \t\r\n]*$/) { inscope = 1; spend = 0 }
            else if (s !~ /^[ \t\r\n]*$/)                  { spend = 0 }
          }
          if (pend == 2) {                       # key matched: a colon must follow
            if (s ~ /^[ \t\r\n]*:[ \t\r\n]*$/) { pend = 1 }
            else if (s !~ /^[ \t\r\n]*$/)      { pend = 0 }
          } else if (pend == 1 && s !~ /^[ \t\r\n]*$/) { pend = 0 }
          t = s; depth += gsub(/[[{]/, "", t)
          t = s; depth -= gsub(/[]}]/, "", t)
          if (depth <= 1) { inscope = 0 }        # the scope object closed again
        }
        if (k == n) { break }                    # no quote closes the last piece
        if (instr && match(s, /\\+$/) && RLENGTH % 2 == 1) {
          if (keep) { str = str "\"" }           # escaped quote: the string goes on
          continue
        }
        if (instr) {
          instr = 0
          if (pend == 1) { printf "%s", str; exit 0 }
          pend  = (depth == want && inscope_ok && str == field) ? 2 : 0
          spend = (scope != "" && depth == 1 && str == scope) ? 2 : 0
        } else {
          instr = 1; str = ""
        }
      }
    }
  '
}

json_root_str() {
  json_scoped_str "$1" ""
}

json_input_str() {
  json_scoped_str "$1" "tool_input"
}

# --- hook mode: does this tool call LAUNCH sdd-archive? ---------------------
# The gate is wired on Task|Skill, which fires for EVERY delegation in the session.
# It used to decide with a raw substring test over the whole payload, so any call
# that merely MENTIONED the phase — a prompt quoting the SDD phase list out of
# CLAUDE.md, an agent instruction naming the pipeline — entered the gate and, on a
# repo with nothing to archive, was blocked outright with a message describing a
# situation the caller was not in ("no verify-report found for change '<unknown>'").
#
# What makes a call an archive launch is the INVOKED IDENTITY, never prose:
#   Skill tool : tool_input.skill          (`/sdd-archive`)
#   Task tool  : tool_input.subagent_type  (the shipped `sdd-archive` agent)
#                tool_input.description    (the short label of a generic launch)
# Free-form text — `prompt`, `args`, `content` — is deliberately NOT consulted: it
# is the model's own prose, which is exactly what must not decide a gate. A launch
# that carries no identity at all is still gated by sdd-archive's prose Step 0 and
# by the CLI mode of this same script.
#
# (CLI mode has an empty payload and skips this entirely.)
launch_is_sdd_archive() {
  lsa_field=""
  for lsa_field in skill subagent_type description; do
    case "$(json_input_str "$lsa_field")" in
      *sdd-archive*) return 0 ;;
    esac
  done
  return 1
}

if [ -n "$payload" ]; then
  launch_is_sdd_archive || exit 0
fi

# --- override ---------------------------------------------------------------
# Deliberately AFTER the launch test: the notice below goes to stderr and the
# model reads it, so it must be printed for an archive launch the override let
# through — not for every unrelated Task/Skill call in the session.
if [ "${KURAMA_ARCHIVE_OVERRIDE:-0}" = "1" ]; then
  printf '%s\n' \
    "archive-gate: KURAMA_ARCHIVE_OVERRIDE=1 — bypassing the verify-PASS gate and the content-binding check." \
    "sdd-archive Step 0 requires the override REASON to be recorded verbatim in the archive report and its return envelope risks." >&2
  exit 0
fi

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

# --- content-binding tree hash (mechanical mirror of sdd-verify Content Binding) --
# Recompute the reviewed-tree hash the SAME way sdd-verify records it: stage every
# change (tracked, untracked, deletions) into a THROWAWAY index and write the
# resulting tree object. GIT_INDEX_FILE points at a temp file, so the real index is
# NEVER touched. Two exclusions keep the hash stable across the verify->archive
# window: the SDD artifact store (openspec/) and harness state (.kurama/) legitimately
# churn — sdd-verify writes its own report, sdd-archive moves the change folder and
# writes an archive report — so they are excluded from the pathspec, leaving only the
# actual code+config bound. `git add -A` also honors .gitignore, so a clean checkout
# hashes identical to HEAD's tree: committing unchanged content does NOT invalidate
# the receipt; only an actual code change does. Echoes the hex tree hash, or nothing
# (non-zero) when it cannot be computed (e.g. not a git checkout).
#
# This pathspec MUST stay byte-identical to the one in skills/sdd-verify/SKILL.md
# (Content Binding) and skills/sdd-archive/SKILL.md (Step 0), or every archive would
# read as stale.
compute_tree_hash() {
  th_root="$1"
  git -C "$th_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  # git rejects a zero-byte index file ("index file smaller than expected"), so the
  # index has to be a path that does NOT exist yet — which is why this used to
  # `mktemp` a file and immediately `rm` it. Deleting a mktemp path and reusing the
  # NAME throws away the exclusive-creation guarantee that made mktemp safe (CWE-377):
  # any local user who learns the name can create it in the window before git does.
  # A private 0700 directory keeps the guarantee AND the empty path: "$th_dir/index"
  # has never existed, and nobody else can create it. The observable damage was not a
  # redirected write — git reads the index first and locks with O_EXCL — but a
  # SUPPRESSED check: git failed, compute_tree_hash returned nothing, the content
  # binding degraded to "not computable", and a stale receipt archived.
  th_dir="$(mktemp -d 2>/dev/null)" || return 1
  trap 'rm -rf "$th_dir"' EXIT HUP INT TERM
  th_index="$th_dir/index"
  GIT_INDEX_FILE="$th_index" git -C "$th_root" add -A -- . ':(exclude)openspec' ':(exclude).kurama' >/dev/null 2>&1
  th_hash="$(GIT_INDEX_FILE="$th_index" git -C "$th_root" write-tree 2>/dev/null)"
  rm -rf "$th_dir"
  trap - EXIT HUP INT TERM
  [ -n "$th_hash" ] || return 1
  printf '%s' "$th_hash"
}

# --- resolve project root ---------------------------------------------------
project_root="${CLAUDE_PROJECT_DIR:-}"
[ -n "$project_root" ] || project_root="$(json_root_str cwd)"
[ -n "$project_root" ] || project_root="$PWD"
root="${project_root%/}"

# --- resolve the change name ------------------------------------------------
# Priority: explicit arg -> KURAMA_CHANGE env -> newest active change auto-detect.
change="${1:-${KURAMA_CHANGE:-}}"

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

  if [ -d "$root/.kurama/sdd" ]; then
    for d in "$root"/.kurama/sdd/*/; do
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
  elif [ -f "$root/.kurama/sdd/$change/verify-report.md" ]; then
    report="$root/.kurama/sdd/$change/verify-report.md"
  fi
fi

if [ -z "$report" ]; then
  printf '%s\n' \
    "BLOCKED by kurama archive-gate: no verify-report found for change '${change:-<unknown>}'." \
    "sdd-archive Step 0 refuses to archive without a verification report recording a PASS verdict." >&2
  # An empty change name is its own diagnosis: the gate found no change directory at
  # all under this root. Say so, instead of leaving '<unknown>' to be read as a
  # missing report for a change that does exist.
  if [ -z "$change" ]; then
    printf '%s\n' \
      "No change could be resolved: neither openspec/changes/<name>/ nor .kurama/sdd/<name>/ holds one under '$root'." \
      "Name it with KURAMA_CHANGE=<name> (or archive-gate.sh <name>) if a change does exist elsewhere." >&2
  fi
  printf '%s\n' \
    "Run sdd-verify first, or set KURAMA_ARCHIVE_OVERRIDE=1 with a reason recorded in the archive report." >&2
  exit 2
fi

# --- content binding: reject a stale receipt (mechanical mirror of Step 0) --
# sdd-verify stamps a "Tree-Hash:" line in the report's Content Binding section,
# binding the PASS verdict to the exact tree it verified. If the working tree has
# changed since (any edit after verification), the receipt is STALE and the PASS can
# no longer be trusted. Enforced only when the report actually carries the line AND
# the live hash is computable; a legacy report without it, or a non-git checkout,
# falls back to the verdict gate alone (documented in docs/hooks.md).
recorded_tree="$(awk 'tolower($0) ~ /tree-hash/ && match($0, /[0-9a-f]{40,64}/) { print substr($0, RSTART, RLENGTH); exit }' "$report")"
if [ -n "$recorded_tree" ]; then
  git_root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$git_root" ] || git_root="$root"
  live_tree="$(compute_tree_hash "$git_root")"
  if [ -n "$live_tree" ] && [ "$live_tree" != "$recorded_tree" ]; then
    printf '%s\n' \
      "BLOCKED by kurama archive-gate: verify receipt stale — re-run sdd-verify." \
      "The working tree changed after sdd-verify bound its Content Binding receipt for '$change'." \
      "  recorded Tree-Hash: $recorded_tree" \
      "  live Tree-Hash:     $live_tree" \
      "Report: $report" \
      "Re-run sdd-verify to re-bind the receipt to the current tree, or set KURAMA_ARCHIVE_OVERRIDE=1 with a reason recorded in the archive report." >&2
    exit 2
  fi
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
  "BLOCKED by kurama archive-gate: cannot archive '$change' — $reason." \
  "Report: $report" \
  "Fix the change and re-run sdd-verify to a PASS / PASS WITH WARNINGS verdict, or set KURAMA_ARCHIVE_OVERRIDE=1 with a reason recorded in the archive report." >&2
exit 2
