# shellcheck shell=bash
# ============================================================================
# Kurama — shared receipt library (issue #37)
#
# The single home of the install-receipt fallback parser, the small helpers that
# setup.sh, install.sh, uninstall.sh, update.sh, doctor.sh and setup-tui.sh used
# to each carry a byte-identical copy of, and — since #105 — the managed
# .gitignore block four of them write, read, verify and remove (one pattern list,
# one marker pair, one parser). Sourced by all six — every script
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
# receipt so a FUTURE shape change can be selected on the field instead of
# re-sniffing shapes. No consumer needs to gate on it today (the current and
# legacy shapes read identically — see manifest_tools), so the field is written
# and readable but not yet branched on. When the receipt shape next changes, add
# the schema-gated modern branch THEN — receipt_schema() already reads the field.
# ----------------------------------------------------------------------------

# The schema version this build stamps into receipts it writes. Bump only
# alongside a receipt shape change. Referenced by the writers (setup.sh/install.sh),
# which source this file — hence unused from shellcheck's single-file view.
# shellcheck disable=SC2034
RECEIPT_SCHEMA=1

# Read the integer receiptSchema field of a receipt. Returns 0 when the field is
# absent (a pre-#37 receipt), the file is missing, or the value is non-numeric —
# so a future caller can gate with a plain `-ge`. manifest_field cannot read this:
# it matches only quoted string values, and receiptSchema is a bare JSON number.
# Both branches must answer IDENTICALLY on every input, including the ones no
# writer produces — jq being installed is not supposed to change what a receipt
# means. It did, in both directions (#65): for a STRING `"receiptSchema": "1"`
# jq read 1 while awk's bare-integer regex found nothing and read 0; for a
# FRACTIONAL `1.0` jq printed "1.0", which the digits-only case below rejected to
# 0, while awk's `[0-9]+` matched the leading "1" and read 1. The canonical answer
# for anything that is not a bare JSON integer is 0 — the same answer a pre-#37
# receipt with no field at all gives — because the field exists to be gated with
# `-ge`, and a value this build cannot read must never claim to be a schema it
# does not understand.
#
# jq side: reject non-numbers up front, so a quoted "1" is a string and reads 0.
# awk side: require the integer to END at the value (a comma, a closing brace, or
# end of line), so "1.0" no longer matches on its leading digit. The writer emits
# `"receiptSchema": 1,` — a delimiter is always there — and the end-of-line
# alternative covers a hand-written receipt with the field last.
receipt_schema() {
    local manifest="$1" v=""
    [ -f "$manifest" ] || { printf '0'; return 0; }
    if command -v jq >/dev/null 2>&1; then
        v="$(jq -r 'if (.receiptSchema | type) == "number" then (.receiptSchema | tostring) else "0" end' "$manifest" 2>/dev/null)"
    else
        v="$(awk '
            match($0, "\"receiptSchema\"[[:space:]]*:[[:space:]]*[0-9]+[[:space:]]*([,}]|$)") {
                s = substr($0, RSTART, RLENGTH)
                sub(/.*:[[:space:]]*/, "", s); sub(/[^0-9].*/, "", s); print s; exit
            }' "$manifest")"
    fi
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    printf '%s' "$v"
}

# Resolve every harness a receipt records. setup.sh writes them all into tools[];
# install.sh's minimal receipt and every pre-tools[] (v6 / legacy) receipt carry
# only the scalar "tool", which is the fallback. ONE frozen path for all shapes:
# a modern install.sh receipt legitimately omits tools[] too, so there is no
# schema-dependent decision to make today. A receiptSchema>=1 modern branch is
# added HERE when the shape next changes — not before, so a field-less legacy
# receipt is never read by anything but this single, genuinely frozen body.
manifest_tools() {
    local manifest="$1" tools
    tools="$(manifest_json_array "$manifest" "tools" | awk 'NF')"
    [ -n "$tools" ] || tools="$(manifest_field "$manifest" "tool")"
    printf '%s\n' "$tools"
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

# ----------------------------------------------------------------------------
# The machine-local .gitignore block (issue #105)
#
# Kurama writes files INTO a target repo in project scope and, until #105, never
# said which of them are machine-local. Six docs asserted ".kurama/ is gitignored"
# as fact with no producer, and a field install committed the receipt (absolute
# paths) alongside two machine-specific MCP configs. The list below is Kurama's
# OWN .gitignore, which docs/changelog.md already calls "what Kurama writes into
# a target repo" — dogfooded here, never applied to the repos it installs into.
#
# Managed by MARKERS, exactly like the orchestrator block in a prompt file: the
# writer only ever rewrites the lines between them, so a line the user wrote is
# never touched, and uninstall removes exactly the block it put there.
#
# NOT in this block, deliberately:
#   * openspec/  — the specs ARE the source of truth and must be committed.
#                  Ignoring them is the failure that killed the `none` mode.
#   * MEMORY.md  — a team artifact, shared on purpose.
# A test asserts both stay absent; do not "helpfully" add either.
# ----------------------------------------------------------------------------

GITIGNORE_MARKER_BEGIN="# BEGIN:kurama"
GITIGNORE_MARKER_END="# END:kurama"

# Emit the block BODY (everything strictly between the markers) for a repo whose
# installed harnesses are the newline list in $1. Each pattern carries the
# one-line "why" from Kurama's own .gitignore: a bare pattern list dropped into
# somebody else's repo is unreviewable.
#
# .atl/ is Pi runtime state and is emitted ONLY when `pi` is one of the installed
# harnesses. Decision (#105 filed this as open): the block describes what THIS
# install actually writes, so a repo that never installed Pi gets no rule for a
# directory nothing here creates. It is additive — installing Pi later re-runs
# setup, the block is re-ensured, and the line appears then.
kurama_gitignore_body() {
    local tools="$1"
    printf '%s\n' "# Machine-local files Kurama writes into this repo. Managed block — Kurama"
    printf '%s\n' "# rewrites ONLY the lines between the markers; keep your own rules outside"
    printf '%s\n' "# them. scripts/uninstall.sh removes exactly this block."
    printf '%s\n' "# Kurama harness state (skill registry, fallback SDD artifacts). openspec/ is"
    printf '%s\n' "# deliberately NOT ignored — the specs are the source of truth and are meant"
    printf '%s\n' "# to be version-controlled with the repo."
    printf '%s\n' ".kurama/"
    printf '%s\n' "# Install receipt: records exactly what was installed. Machine-local, and it"
    printf '%s\n' "# carries absolute paths."
    printf '%s\n' ".kurama-install-manifest.json"
    printf '%s\n' "# Timestamped backups setup.sh/uninstall.sh leave beside any file they merge"
    printf '%s\n' "# into (prompt files, settings.json, MCP configs)."
    printf '%s\n' "*.bak.[0-9]*"
    printf '%s\n' "# Per-machine agent config. The harness dirs themselves may be committed when a"
    printf '%s\n' "# repo ships its own agents/hooks, but the local settings never are."
    printf '%s\n' ".claude/settings.local.json"
    if printf '%s\n' "$tools" | grep -Fxq -- pi; then
        printf '%s\n' "# Local Pi runtime state."
        printf '%s\n' ".atl/"
    fi
}

# Count the PATTERNS (non-comment, non-blank lines) the block carries, for the
# "(N patterns)" line the install summary reports.
kurama_gitignore_pattern_count() {
    kurama_gitignore_body "$1" | awk '!/^[[:space:]]*#/ && NF { n++ } END { print n + 0 }'
}

# Ensure the managed block in the .gitignore at $1, for the installed harnesses
# in $2. Prints ONE status word and returns 0 in every case:
#
#   created     the file did not exist and now holds the block
#   added       the file existed without the block; the block was appended
#   updated     the block existed with different content and was rewritten
#   present     the block was already byte-identical — the file was NOT touched
#   unbalanced  BEGIN without END (or vice versa): refused, file untouched
#   failed      the write itself failed (unwritable dir, full disk)
#
# `present` is what makes a second install byte-identical: an unchanged block is
# never rewritten, so the file keeps its inode, its mtime and every byte.
kurama_gitignore_ensure() {
    local file="$1" tools="$2"
    local body tmp has_begin=0 has_end=0

    body="$(kurama_gitignore_body "$tools")"

    if [ ! -f "$file" ]; then
        if {
            printf '%s\n' "$GITIGNORE_MARKER_BEGIN"
            printf '%s\n' "$body"
            printf '%s\n' "$GITIGNORE_MARKER_END"
        } > "$file" 2>/dev/null; then
            printf 'created'
        else
            printf 'failed'
        fi
        return 0
    fi

    grep -qF "$GITIGNORE_MARKER_BEGIN" "$file" 2>/dev/null && has_begin=1
    grep -qF "$GITIGNORE_MARKER_END" "$file" 2>/dev/null && has_end=1

    if [ "$has_begin" -ne "$has_end" ]; then
        # The same refusal validate_markers makes for a prompt file: a lone BEGIN
        # would make the awk rewrite below swallow everything after it.
        printf 'unbalanced'
        return 0
    fi

    if [ "$has_begin" -eq 1 ]; then
        local current
        current="$(awk -v b="$GITIGNORE_MARKER_BEGIN" -v e="$GITIGNORE_MARKER_END" '
            $0 == b { f = 1; next }
            $0 == e { f = 0; next }
            f       { print }
        ' "$file")"
        if [ "$current" = "$body" ]; then
            printf 'present'
            return 0
        fi
        local bodyfile updated
        bodyfile="$(mktemp)" || { printf 'failed'; return 0; }
        printf '%s\n' "$body" > "$bodyfile"
        if ! updated="$(awk -v b="$GITIGNORE_MARKER_BEGIN" -v e="$GITIGNORE_MARKER_END" -v cfile="$bodyfile" '
            $0 == b { print; while ((getline line < cfile) > 0) print line; close(cfile); skip = 1; next }
            $0 == e { print; skip = 0; next }
            !skip   { print }
        ' "$file")"; then
            rm -f "$bodyfile"
            printf 'failed'
            return 0
        fi
        rm -f "$bodyfile"
        tmp="$(mktemp "${file}.XXXXXX")" || { printf 'failed'; return 0; }
        if printf '%s\n' "$updated" > "$tmp" && mv "$tmp" "$file"; then
            printf 'updated'
        else
            rm -f "$tmp"
            printf 'failed'
        fi
        return 0
    fi

    # No block yet. Append one, separated by a blank line from whatever the repo
    # already ignores — and never rewrite a single existing line.
    tmp="$(mktemp "${file}.XXXXXX")" || { printf 'failed'; return 0; }
    if {
        cat "$file"
        # A file that does not end in a newline would otherwise glue its last
        # pattern onto our separator.
        if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then printf '\n'; fi
        printf '\n'
        printf '%s\n' "$GITIGNORE_MARKER_BEGIN"
        printf '%s\n' "$body"
        printf '%s\n' "$GITIGNORE_MARKER_END"
    } > "$tmp" 2>/dev/null && mv "$tmp" "$file"; then
        printf 'added'
    else
        rm -f "$tmp"
        printf 'failed'
    fi
    return 0
}

# Remove the managed block from the .gitignore at $1, leaving every other line
# byte-identical. A file left holding nothing but whitespace is deleted: the only
# way to reach that state is a .gitignore Kurama created itself.
# Prints one status word: stripped | absent | unbalanced | removed-file | failed.
kurama_gitignore_strip() {
    local file="$1"
    [ -f "$file" ] || { printf 'absent'; return 0; }
    grep -qF "$GITIGNORE_MARKER_BEGIN" "$file" 2>/dev/null || { printf 'absent'; return 0; }
    if ! grep -qF "$GITIGNORE_MARKER_END" "$file" 2>/dev/null; then
        printf 'unbalanced'
        return 0
    fi

    local stripped tmp
    stripped="$(awk -v b="$GITIGNORE_MARKER_BEGIN" -v e="$GITIGNORE_MARKER_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip   { print }
    ' "$file")"
    # Drop the trailing blank the append introduced, so install → uninstall
    # returns the file to what it was instead of growing a blank line per cycle.
    stripped="$(printf '%s\n' "$stripped" | awk '
        { lines[n++] = $0 }
        END {
            last = n - 1
            while (last >= 0 && lines[last] ~ /^[[:space:]]*$/) last--
            for (i = 0; i <= last; i++) print lines[i]
        }')"

    case "$stripped" in
        *[![:space:]]*) ;;
        *)
            if rm -f "$file"; then printf 'removed-file'; else printf 'failed'; fi
            return 0
            ;;
    esac

    tmp="$(mktemp "${file}.XXXXXX")" || { printf 'failed'; return 0; }
    if printf '%s\n' "$stripped" > "$tmp" && mv "$tmp" "$file"; then
        printf 'stripped'
    else
        rm -f "$tmp"
        printf 'failed'
    fi
    return 0
}

# The .gitignore files a receipt records the managed block in. Reads through the
# ONE array parser (jq when present, awk otherwise), so a jq-less host resolves
# the same list uninstall drives its strip from.
manifest_gitignore() {
    manifest_json_array "$1" "gitignore"
}
