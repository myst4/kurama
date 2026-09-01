#!/usr/bin/env bash
# ============================================================================
# Kurama — Delta Spec Structural Linter
#
# Run: bash skills/_shared/lint-spec.sh <spec.md | change-dir> [more...]
#
# `scripts/validate_skills.sh` validates the structure of SKILLS. Nothing
# validated the structure of CHANGE ARTIFACTS — so a delta spec with a partial
# MODIFIED block, a scenario without GIVEN/WHEN/THEN, a requirement with no
# RFC 2119 keyword, or a dangling RENAMED reached `sdd-archive`, which merges it
# into `openspec/specs/` — the declared source of truth, with `sdd-archive` as
# its ONLY writer. Everything about spec structure was a model judgement. This
# script is the mechanical half.
#
# The canonical semantics it enforces live in ONE place and are NOT restated
# here: `skills/_shared/openspec-convention.md` -> *Delta Spec Sections*. The
# template that produces the shape lives in `skills/sdd-spec/SKILL.md`.
#
# Portability: bash 3.2 + BSD/GNU userland, grep/awk/sed/find only. No jq, no
# rg/fd, no bash-4 constructs (no mapfile, no ${var,,}, no associative arrays).
# LC_ALL=C is forced so every awk/grep in here has identical byte semantics
# whatever the caller locale is.
#
# Checks (each names its canonical reference in the finding it emits):
#   1. Top-level delta sections are ONLY ADDED/MODIFIED/REMOVED/RENAMED
#      Requirements.                                                  [ERROR]
#   2. Every requirement states at least one RFC 2119 keyword.         [ERROR]
#   3. Every ADDED/MODIFIED (and full-spec) requirement carries at
#      least one `#### Scenario:`.                                     [ERROR]
#   4. Every scenario carries GIVEN, WHEN and THEN lines.              [ERROR]
#   5. A scenario ID, when present, matches [S-{req}-{n}] and is
#      unique in the file.                                             [ERROR]
#   6. A MODIFIED requirement never carries FEWER scenarios than the
#      same requirement currently has in openspec/specs/** (the #80
#      silent-deletion case, made mechanical).                         [ERROR]
#   7. A RENAMED entry names BOTH the old and the new requirement.     [ERROR]
#   8. Unfilled `{template braces}` are gone.                          [ERROR]
#   9. No TBD / TODO / XXX left behind.                              [WARNING]
#  10. A REMOVED entry carries a `(Reason: ...)`.                      [ERROR]
#
# Output: one finding per line, `file:line: LEVEL: message`, on stdout.
# Exit:   0 = clean (no output at all)
#         1 = findings (ERROR and/or WARNING)
#         2 = usage error (bad flag, missing path, nothing lintable)
# ============================================================================

set -u
LC_ALL=C
export LC_ALL

TAB=$(printf '\t')

PROG=$(basename "$0")

usage() {
    printf '%s\n' \
        "Usage: $PROG [--specs <main-specs-dir>] <spec.md | change-dir> [more...]" \
        "" \
        "Lints Kurama delta specs and full specs for structural defects." \
        "" \
        "Arguments:" \
        "  <spec.md>      lint exactly that file." \
        "  <change-dir>   lint every *.md under it that lives in a specs/" \
        "                 directory or is named spec.md (the openspec" \
        "                 convention: {change}/specs/{domain}/spec.md)." \
        "" \
        "Options:" \
        "  --specs DIR    main-spec tree used for the MODIFIED whole-block" \
        "                 check. Default: the nearest openspec/specs found by" \
        "                 walking up from the first target. Without one, the" \
        "                 MODIFIED scenario-count check is skipped." \
        "  -h, --help     print this help." \
        "" \
        "Exit: 0 clean, 1 findings, 2 usage." \
        "" \
        "Canonical rules: skills/_shared/openspec-convention.md -> Delta Spec Sections"
}

die_usage() {
    printf '%s: %s\n' "$PROG" "$1" >&2
    printf '%s\n' "Run \"$PROG --help\" for usage." >&2
    exit 2
}

MAIN_SPECS=""
SPECS_EXPLICIT=0

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
TARGET_LIST=$(mktemp "${TMPDIR:-/tmp}/lint-spec-targets.XXXXXX") || exit 2
FINDINGS=$(mktemp "${TMPDIR:-/tmp}/lint-spec-findings.XXXXXX") || exit 2
SCRATCH=$(mktemp "${TMPDIR:-/tmp}/lint-spec-scratch.XXXXXX") || exit 2
trap 'rm -f -- "$TARGET_LIST" "$FINDINGS" "$SCRATCH"' EXIT

positional=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --specs)
            [ "$#" -ge 2 ] || die_usage "--specs needs a directory"
            MAIN_SPECS="$2"
            SPECS_EXPLICIT=1
            [ -d "$MAIN_SPECS" ] || die_usage "--specs: not a directory: $MAIN_SPECS"
            shift 2
            ;;
        --specs=*)
            MAIN_SPECS="${1#--specs=}"
            SPECS_EXPLICIT=1
            [ -d "$MAIN_SPECS" ] || die_usage "--specs: not a directory: $MAIN_SPECS"
            shift
            ;;
        --)
            shift
            while [ "$#" -gt 0 ]; do
                printf '%s\n' "$1" >> "$TARGET_LIST"
                positional=$((positional + 1))
                shift
            done
            ;;
        -*)
            die_usage "unknown option: $1"
            ;;
        *)
            printf '%s\n' "$1" >> "$TARGET_LIST"
            positional=$((positional + 1))
            shift
            ;;
    esac
done

[ "$positional" -gt 0 ] || die_usage "no spec file or change directory given"

# ----------------------------------------------------------------------------
# Target expansion
#
# A file argument is linted verbatim. A directory argument is expanded to the
# *.md files under it that the openspec convention places specs in — anything
# inside a specs/ directory, or any file named spec.md. Deliberately NARROW: a
# proposal.md carries `## Spec (inline)` on the `small` path and would otherwise
# be linted as a delta spec, where its own `## Design (inline)` heading is not a
# delta section and every finding would be noise.
# ----------------------------------------------------------------------------
expand_targets() {
    _t="$1"
    if [ -f "$_t" ]; then
        printf '%s\n' "$_t"
        return 0
    fi
    if [ -d "$_t" ]; then
        find "$_t" -type f -name '*.md' 2>/dev/null | sort | while IFS= read -r _f; do
            case "$_f" in
                */specs/*) printf '%s\n' "$_f" ;;
                */spec.md) printf '%s\n' "$_f" ;;
                spec.md)   printf '%s\n' "$_f" ;;
            esac
        done
        return 0
    fi
    return 1
}

: > "$SCRATCH"
while IFS= read -r target; do
    [ -n "$target" ] || continue
    if [ ! -e "$target" ]; then
        die_usage "no such file or directory: $target"
    fi
    expand_targets "$target" >> "$SCRATCH"
done < "$TARGET_LIST"
mv -- "$SCRATCH" "$TARGET_LIST"
SCRATCH=$(mktemp "${TMPDIR:-/tmp}/lint-spec-scratch.XXXXXX") || exit 2

if [ ! -s "$TARGET_LIST" ]; then
    die_usage "no spec files found (a directory argument lints *.md under specs/ or named spec.md)"
fi

# ----------------------------------------------------------------------------
# Main-spec tree resolution (for the MODIFIED whole-block check)
#
# Walk up from the first target until a directory holding openspec/specs is
# found. Absent tree => the check is skipped, never faked: the issue this closes
# is data loss, and a guessed baseline would invent losses or hide them.
# ----------------------------------------------------------------------------
resolve_main_specs() {
    _d="$1"
    _d=$(cd "$_d" 2>/dev/null && pwd) || return 1
    while [ -n "$_d" ] && [ "$_d" != "/" ]; do
        if [ -d "$_d/openspec/specs" ]; then
            printf '%s\n' "$_d/openspec/specs"
            return 0
        fi
        _d=$(dirname "$_d")
    done
    if [ -d "/openspec/specs" ]; then
        printf '%s\n' "/openspec/specs"
        return 0
    fi
    return 1
}

if [ "$SPECS_EXPLICIT" -eq 0 ]; then
    first_target=$(head -n 1 "$TARGET_LIST")
    MAIN_SPECS=$(resolve_main_specs "$(dirname "$first_target")") || MAIN_SPECS=""
fi

# Count the scenarios the requirement named $1 currently has in the main-spec
# tree. Prints "<count><TAB><file>" for the first main spec that carries it, and
# nothing when the tree is absent or the requirement is new.
main_spec_scenarios() {
    _want="$1"
    [ -n "$MAIN_SPECS" ] || return 0
    [ -d "$MAIN_SPECS" ] || return 0
    find "$MAIN_SPECS" -type f -name '*.md' 2>/dev/null | sort | while IFS= read -r _f; do
        _n=$(awk -v want="$_want" '
            /^[ \t]*(```|~~~)/ { fence = 1 - fence; next }
            fence { next }
            /^###[ \t]/ {
                t = $0
                sub(/^###[ \t]+/, "", t)
                sub(/[ \t]+$/, "", t)
                inreq = 0
                if (t ~ /^Requirement:/) {
                    sub(/^Requirement:[ \t]*/, "", t)
                    if (t == want) inreq = 1
                }
                next
            }
            /^##[ \t]/ { inreq = 0; next }
            /^#[ \t]/  { inreq = 0; next }
            inreq && /^####[ \t]/ { n++ }
            END { print n + 0 }
        ' "$_f")
        if [ "${_n:-0}" -gt 0 ]; then
            printf '%s\t%s\n' "$_n" "$_f"
            break
        fi
    done | head -n 1
}

# ----------------------------------------------------------------------------
# The structural pass
#
# One awk program per file. It emits sortable records:
#     <line>\t<seq>\t<LEVEL>\t<message>
# LEVEL is ERROR or WARNING for a real finding, or @MOD for a MODIFIED
# requirement census (`<scenario-count> <requirement name>`) that only the shell
# can resolve, because it needs the main-spec tree.
# ----------------------------------------------------------------------------
structural_pass() {
    awk '
        function emit(ln, level, msg) {
            seq++
            printf "%d\t%d\t%s\t%s\n", ln, seq, level, msg
        }

        function close_scenario(   miss) {
            if (!scn_open) return
            miss = ""
            if (!scn_given) miss = miss " GIVEN"
            if (!scn_when)  miss = miss " WHEN"
            if (!scn_then)  miss = miss " THEN"
            if (miss != "") {
                sub(/^ /, "", miss)
                gsub(/ /, ", ", miss)
                emit(scn_line, "ERROR", "scenario \"" scn_title "\" is missing " miss " - every scenario MUST carry GIVEN / WHEN / THEN (skills/sdd-spec/SKILL.md -> Delta Spec Format)")
            }
            scn_open = 0
        }

        function close_requirement() {
            if (!req_open) return
            if (req_sec == "ADDED" || req_sec == "MODIFIED" || req_sec == "FULL") {
                if (req_scen == 0)
                    emit(req_line, "ERROR", "requirement \"" req_name "\" carries no \"#### Scenario:\" block - every requirement MUST have at least one (skills/sdd-spec/SKILL.md -> Rules)")
                if (!req_kw)
                    emit(req_line, "ERROR", "requirement \"" req_name "\" states no RFC 2119 keyword (MUST / SHALL / SHOULD / MAY) in its description (skills/sdd-spec/SKILL.md -> RFC 2119 Keywords Quick Reference)")
            }
            if (req_sec == "MODIFIED")
                emit(req_line, "@MOD", req_scen " " req_name)
            if (req_sec == "REMOVED" && !req_reason)
                emit(req_line, "ERROR", "REMOVED requirement \"" req_name "\" carries no \"(Reason: ...)\" line - the delta MUST carry one, and the requirement it explains is about to be deleted from the source of truth (skills/_shared/openspec-convention.md -> Delta Spec Sections)")
            req_open = 0
        }

        function check_renamed(ln, nm,   s, p, old, nw) {
            s = nm
            gsub(/→|->/, "\001", s)
            p = index(s, "\001")
            if (p == 0) {
                emit(ln, "ERROR", "RENAMED requirement \"" nm "\" names only one requirement - the heading MUST be \"### Requirement: {Old Name} -> {New Name}\" with BOTH names explicit (skills/_shared/openspec-convention.md -> Delta Spec Sections)")
                return
            }
            old = substr(s, 1, p - 1)
            nw  = substr(s, p + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", old)
            gsub(/^[ \t]+|[ \t]+$/, "", nw)
            gsub(/\001/, "", nw)
            gsub(/^[ \t]+|[ \t]+$/, "", nw)
            if (old == "" || nw == "")
                emit(ln, "ERROR", "RENAMED requirement heading \"" nm "\" leaves the old or the new name empty - both MUST be explicit (skills/_shared/openspec-convention.md -> Delta Spec Sections)")
        }

        function check_scenario_id(ln, title,   id, p) {
            if (substr(title, 1, 1) != "[") return
            p = index(title, "]")
            if (p == 0) {
                emit(ln, "ERROR", "scenario ID bracket is never closed in \"" title "\" - the convention is [S-{requirement-slug}-{n}]")
                return
            }
            id = substr(title, 2, p - 2)
            if (id !~ /^S-[A-Za-z0-9]+(-[A-Za-z0-9]+)*-[0-9]+$/) {
                emit(ln, "ERROR", "malformed scenario ID \"[" id "]\" - the convention is [S-{requirement-slug}-{n}], e.g. [S-auth-1] (skills/sdd-spec/SKILL.md -> Delta Spec Format)")
                return
            }
            if (id in seen_id) {
                emit(ln, "ERROR", "duplicate scenario ID \"[" id "]\" - already used on line " seen_id[id] "; IDs are stable and unique for the life of the requirement (skills/_shared/openspec-convention.md -> Scenario IDs across a delta)")
                return
            }
            seen_id[id] = ln
        }

        BEGIN { sec = "FULL" }

        /^[ \t]*(```|~~~)/ { fence = 1 - fence; next }
        fence { next }

        {
            if (match($0, /\{[^{}]*\}/))
                emit(NR, "ERROR", "unfilled template placeholder " substr($0, RSTART, RLENGTH) " - the delta template braces were never replaced with real content")
            if ($0 ~ /(^|[^A-Za-z])(TBD|TODO|XXX)([^A-Za-z]|$)/)
                emit(NR, "WARNING", "placeholder marker (TBD / TODO / XXX) left in the spec - a spec that ships an open question is not a specification")
        }

        /^####[ \t]/ {
            close_scenario()
            t = $0
            sub(/^####[ \t]+/, "", t)
            sub(/[ \t]+$/, "", t)
            if (t !~ /^Scenario:/) { next }
            sub(/^Scenario:[ \t]*/, "", t)
            scn_open = 1
            scn_line = NR
            scn_title = t
            scn_given = 0; scn_when = 0; scn_then = 0
            if (req_open) { req_scen++; req_in_desc = 0 }
            check_scenario_id(NR, t)
            next
        }

        /^###[ \t]/ {
            close_scenario()
            close_requirement()
            t = $0
            sub(/^###[ \t]+/, "", t)
            sub(/[ \t]+$/, "", t)
            if (t !~ /^Requirement:/) { next }
            sub(/^Requirement:[ \t]*/, "", t)
            req_open = 1
            req_line = NR
            req_name = t
            req_sec = sec
            req_scen = 0
            req_kw = 0
            req_reason = 0
            req_in_desc = 1
            if (req_sec == "RENAMED") check_renamed(NR, t)
            next
        }

        /^##[ \t]/ {
            close_scenario()
            close_requirement()
            t = $0
            sub(/^##[ \t]+/, "", t)
            sub(/[ \t]+$/, "", t)
            if (t ~ /^(ADDED|MODIFIED|REMOVED|RENAMED) Requirements$/) {
                sec = t
                sub(/ Requirements$/, "", sec)
                has_delta = 1
            } else if (t ~ /^[A-Za-z]+ Requirements$/) {
                emit(NR, "ERROR", "unknown delta section \"## " t "\" - the canonical set is ADDED / MODIFIED / REMOVED / RENAMED Requirements (skills/_shared/openspec-convention.md -> Delta Spec Sections)")
                sec = "UNKNOWN"
            } else {
                sec = "FULL"
                pending_n++
                pending_line[pending_n] = NR
                pending_text[pending_n] = t
            }
            next
        }

        /^#[ \t]/ {
            close_scenario()
            close_requirement()
            sec = "FULL"
            next
        }

        {
            if (scn_open) {
                if ($0 ~ /^[ \t]*([-*+][ \t]+)?[*_]{0,2}GIVEN([^A-Za-z]|$)/) scn_given = 1
                if ($0 ~ /^[ \t]*([-*+][ \t]+)?[*_]{0,2}WHEN([^A-Za-z]|$)/)  scn_when  = 1
                if ($0 ~ /^[ \t]*([-*+][ \t]+)?[*_]{0,2}THEN([^A-Za-z]|$)/)  scn_then  = 1
            }
            if (req_open) {
                if (req_in_desc && $0 ~ /(^|[^A-Za-z])(MUST|SHALL|SHOULD|MAY|REQUIRED|RECOMMENDED|OPTIONAL)([^A-Za-z]|$)/) req_kw = 1
                if ($0 ~ /\(Reason:/) req_reason = 1
            }
        }

        END {
            close_scenario()
            close_requirement()
            # A non-canonical `## ` heading is only wrong in a file that IS a
            # delta spec; a full spec legitimately carries ## Purpose and
            # ## Requirements. Which one this file is, is only known at EOF.
            if (has_delta) {
                for (i = 1; i <= pending_n; i++)
                    emit(pending_line[i], "ERROR", "unknown top-level section \"## " pending_text[i] "\" in a delta spec - only ADDED / MODIFIED / REMOVED / RENAMED Requirements are allowed (skills/_shared/openspec-convention.md -> Delta Spec Sections)")
            }
        }
    ' "$1"
}

# ----------------------------------------------------------------------------
# Per-file driver: structural pass, then resolve the @MOD census against the
# main-spec tree, then print every finding in file:line order.
# ----------------------------------------------------------------------------
lint_file() {
    _file="$1"
    : > "$SCRATCH"
    structural_pass "$_file" > "$FINDINGS"

    while IFS="$TAB" read -r _ln _seq _level _msg; do
        [ -n "${_ln:-}" ] || continue
        if [ "$_level" = "@MOD" ]; then
            _cnt=${_msg%% *}
            _name=${_msg#* }
            _base=$(main_spec_scenarios "$_name")
            [ -n "$_base" ] || continue
            _basecnt=${_base%%"$TAB"*}
            _basefile=${_base#*"$TAB"}
            if [ "$_cnt" -lt "$_basecnt" ]; then
                printf '%s\t%s\tERROR\t%s\n' "$_ln" "$_seq" \
                    "MODIFIED requirement \"$_name\" carries $_cnt scenario(s); the main spec $_basefile currently has $_basecnt. A MODIFIED block REPLACES the whole requirement, so $((_basecnt - _cnt)) scenario(s) would be DELETED from the source of truth - copy the full block before editing it (skills/_shared/openspec-convention.md -> Why MODIFIED is a whole-block replacement)" \
                    >> "$SCRATCH"
            fi
        else
            printf '%s\t%s\t%s\t%s\n' "$_ln" "$_seq" "$_level" "$_msg" >> "$SCRATCH"
        fi
    done < "$FINDINGS"

    [ -s "$SCRATCH" ] || return 0
    sort -t"$TAB" -k1,1n -k2,2n "$SCRATCH" \
        | awk -F"$TAB" -v f="$_file" '{ printf "%s:%s: %s: %s\n", f, $1, $3, $4 }'
    return 0
}

found=0
while IFS= read -r spec_file; do
    [ -n "$spec_file" ] || continue
    out=$(lint_file "$spec_file")
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
        found=1
    fi
done < "$TARGET_LIST"

[ "$found" -eq 0 ] || exit 1
exit 0
