# shellcheck shell=bash
# ============================================================================
# Kurama — shared receipt library (issue #37)
#
# The single home of the install-receipt fallback parser and the small helpers
# that setup.sh, install.sh, uninstall.sh, update.sh, doctor.sh and setup-tui.sh
# used to each carry a byte-identical copy of. Sourced by all six — every script
# resolves SCRIPT_DIR and runs from the clone, so `. "$SCRIPT_DIR/lib/receipt.sh"`
# always finds this file; each source site fails loud if it does not (a partial
# clone), never proceeding with an undefined parser.
#
# History: the one-line empty-array bug (PR #13) had to be fixed in six places at
# once because the parser was copied six times; a miss produced divergent reads
# of the SAME receipt depending on which script opened it — and uninstall.sh
# deletes files guided by that parser. This file ends that: one parser to fix.
#
# Contract: this file is SOURCED, never executed. It sets no shell options (it
# inherits the caller's `set -e`/`-u`) and defines only functions. Two functions
# read caller-owned variables at call time: read_version needs $VERSION_FILE and
# read_commit needs $REPO_DIR (every writer that calls them already defines both).
# Bash 3.2 compatible; portable awk fallback for jq-less hosts.
# ============================================================================

# ----------------------------------------------------------------------------
# Receipt parser — jq when available, portable awk otherwise. BEHAVIOR-FROZEN:
# these two functions must read a receipt byte-for-byte the way every prior copy
# did (see the empty-array note below), because uninstall.sh drives `rm` from
# what they emit.
# ----------------------------------------------------------------------------

# Read a receipt scalar field ("tool", "scope", "version", …). Matches a QUOTED
# string value only — integer fields such as receiptSchema are read by
# receipt_schema() instead.
manifest_field() {
    local manifest="$1" key="$2"
    [ -f "$manifest" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$key" '.[$k] // ""' "$manifest" 2>/dev/null
        return 0
    fi
    awk -v key="$key" '
        match($0, "\"" key "\"[[:space:]]*:[[:space:]]*\"[^\"]*\"") {
            s = substr($0, RSTART, RLENGTH)
            sub(/.*:[[:space:]]*"/, "", s); sub(/".*/, "", s); print s; exit
        }' "$manifest"
}

# Emit each string element of a named flat JSON array (files, settings, tools,
# pi_packages, …), one per line; nothing when the key is absent.
#
# Why the opening rule handles the whole array itself instead of just setting
# inarr: for a single-line "key": [] the array closes on the line that opened it,
# so setting inarr and skipping to the next line hands the closing-bracket check
# a bracket that never arrives. The parser then runs to the end of the receipt,
# printing the NEXT key's declaration line as if it were an element, followed by
# the elements that belong to that other key. uninstall.sh drives rm from files[],
# so an empty files[] would migrate .claude/settings.json out of settings[] and
# delete the file outright instead of stripping its kurama hooks block. The
# !inarr guard is the same defense one level up: without it a later "<key>"
# nested elsewhere in the receipt re-opens an array already closed.
manifest_json_array() {
    local manifest="$1" key="$2"
    [ -f "$manifest" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$key" '(.[$k] // [])[]' "$manifest" 2>/dev/null
        return 0
    fi
    awk -v key="$key" '
        !inarr && $0 ~ "\"" key "\"[[:space:]]*:[[:space:]]*\\[" {
            tail = substr($0, index($0, "[") + 1)
            if (tail ~ /\]/) {                       # array opens and closes on this line
                sub(/\].*/, "", tail)
                n = split(tail, parts, ",")
                for (i = 1; i <= n; i++) {
                    gsub(/^[[:space:]]+|[[:space:]]+$|"/, "", parts[i])
                    if (parts[i] != "") print parts[i]
                }
                next
            }
            inarr = 1; next
        }
        inarr && /\]/ { inarr = 0 }
        inarr {
            line = $0
            gsub(/^[[:space:]]+/, "", line); gsub(/[[:space:]]+$/, "", line)
            gsub(/,$/, "", line); gsub(/"/, "", line)
            if (line != "") print line
        }' "$manifest"
}

# setup.sh historically named the readers receipt_field / receipt_json_array.
# Kept as aliases so its call sites read unchanged.
receipt_field()      { manifest_field "$@"; }
receipt_json_array() { manifest_json_array "$@"; }

# Back-compat wrapper: the "files" array.
manifest_files() {
    manifest_json_array "$1" "files"
}

# ----------------------------------------------------------------------------
# receiptSchema (#37): an integer version stamped into every newly written
# receipt. Consumers gate on it; receipts that lack it are read by the frozen
# legacy shape-sniff below.
# ----------------------------------------------------------------------------

# The schema version this build stamps into receipts it writes. Bump only
# alongside a receipt shape change, and add the matching modern branch to any
# consumer that gates on it. Referenced by the writers (setup.sh/install.sh),
# which source this file — hence unused from shellcheck's single-file view.
# shellcheck disable=SC2034
RECEIPT_SCHEMA=1

# Read the integer receiptSchema field of a receipt. Returns 0 when the field is
# absent (a pre-#37 receipt), the file is missing, or the value is non-numeric —
# so callers gate with a plain `-ge`. manifest_field cannot read this: it matches
# only quoted string values, and receiptSchema is a bare JSON number.
receipt_schema() {
    local manifest="$1" v=""
    [ -f "$manifest" ] || { printf '0'; return 0; }
    if command -v jq >/dev/null 2>&1; then
        v="$(jq -r '.receiptSchema // 0' "$manifest" 2>/dev/null)"
    else
        v="$(awk '
            match($0, "\"receiptSchema\"[[:space:]]*:[[:space:]]*[0-9]+") {
                s = substr($0, RSTART, RLENGTH); sub(/.*:[[:space:]]*/, "", s); print s; exit
            }' "$manifest")"
    fi
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    printf '%s' "$v"
}

# Resolve every harness a receipt records: setup.sh writes them all into tools[];
# install.sh's minimal receipt and every pre-tools[] (v6 / legacy) receipt carry
# only the scalar "tool", which is the fallback.
_manifest_tools_read() {
    local manifest="$1" tools
    tools="$(manifest_json_array "$manifest" "tools" | awk 'NF')"
    [ -n "$tools" ] || tools="$(manifest_field "$manifest" "tool")"
    printf '%s\n' "$tools"
}

# Public entry: gated on receiptSchema. Behavior-preserving today — a modern
# install.sh receipt legitimately omits tools[] too, so both paths keep the scalar
# fallback and resolve every current receipt identically. The split isolates the
# legacy shape so the NEXT schema bump edits only the modern branch and never
# disturbs how a field-less legacy receipt is read.
manifest_tools() {
    local manifest="$1"
    if [ "$(receipt_schema "$manifest")" -ge 1 ]; then
        _manifest_tools_read "$manifest"   # modern (receiptSchema >= 1)
    else
        _manifest_tools_read "$manifest"   # frozen legacy (no receiptSchema)
    fi
}

# ----------------------------------------------------------------------------
# Small helpers formerly duplicated x2-4 across the scripts.
# ----------------------------------------------------------------------------

home_dir() { echo "$HOME"; }

# Kurama version from the repo VERSION file ("unknown" when absent/empty). Reads
# the caller's $VERSION_FILE.
read_version() {
    local v="unknown"
    if [ -f "$VERSION_FILE" ]; then
        IFS= read -r v < "$VERSION_FILE" || true
        [ -n "$v" ] || v="unknown"
    fi
    printf '%s' "$v"
}

# Short commit SHA of the Kurama repo this script runs from ('' when git is
# unavailable or HEAD is missing; the caller then omits the "commit" field so it
# never breaks a jq-less parser or a git-less host). Reads the caller's $REPO_DIR.
read_commit() {
    local c=""
    if command -v git >/dev/null 2>&1; then
        c="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    fi
    printf '%s' "$c"
}

# Portable content hash of a file ("" if missing).
hash_file() {
    [ -f "$1" ] || { printf ''; return 0; }
    if command -v shasum >/dev/null 2>&1; then shasum "$1" | awk '{print $1}';
    elif command -v sha1sum >/dev/null 2>&1; then sha1sum "$1" | awk '{print $1}';
    else cksum "$1" | awk '{print $1"-"$2}'; fi
}

# ----------------------------------------------------------------------------
# The one harness -> skills-path map (was hardcoded in 7 places). Global scope
# returns the per-user config dir (identical to the historical behavior, so
# existing installs/receipts stay byte-compatible); project scope returns the
# skills dir under a repo root passed as $3. Unknown harness -> empty string.
#   skills_path <harness> [global|project] [repo-root-for-project]
# omp honors PI_CODING_AGENT_DIR, which relocates its user base.
# ----------------------------------------------------------------------------
skills_path() {
    local harness="$1" scope="${2:-global}" root="${3:-}"
    if [ "$scope" = "project" ]; then
        case "$harness" in
            pi)  echo "$root/.pi/skills" ;;
            omp) echo "$root/.omp/skills" ;;
            *)   echo "$root/.claude/skills" ;;
        esac
        return 0
    fi
    case "$harness" in
        claude-code)  echo "$HOME/.claude/skills" ;;
        opencode)     echo "$HOME/.config/opencode/skills" ;;
        codex)        echo "$HOME/.codex/skills" ;;
        pi)           echo "$HOME/.pi/agent/skills" ;;
        omp)          echo "${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}/skills" ;;
        *)            echo "" ;;
    esac
}
