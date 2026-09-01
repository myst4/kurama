#!/usr/bin/env bash
# ============================================================================
# Kurama — build .kurama/skill-registry.md (issue #106)
#
# The registry is the ONLY resolution surface for the `## Project Standards
# (skills to load)` block every delegation carries, so a context-isolated
# sub-agent still follows the repo's conventions (_shared/skill-resolver.md).
# It used to be built by a sub-agent: measured at 12-13 minutes and 44,954 bytes
# in a real repo, 63% of which was hand-written per-skill summaries the resolver
# already demoted to an opt-in fallback in #82.
#
# What the registry actually is: three frontmatter fields per SKILL.md. That is
# filesystem work, so this script does it — INDEX ONLY. There is deliberately no
# "Compact Rules" section and no summarisation of any kind: a delegator passes
# the PATH from the index and the sub-agent reads the full skill. Keeping the
# `| Trigger | Skill | Path |` shape and the `## Project Conventions` table means
# the fifteen consumers of this file change nothing.
#
# There is NO model-scan fallback anywhere. If this script is missing, that is a
# broken install: the skill says so and stops, and doctor.sh reports it.
#
# Portability contract (this file ships onto user machines):
#   - bash 3.2 (macOS stock). No mapfile, no ${var,,}, no associative arrays.
#   - POSIX find/grep/awk/sed/sort only. No jq, no rg, no fd.
#   - Reads nothing but SKILL.md frontmatter and the project's convention files.
#
# Usage:
#   build-skill-registry.sh [--root DIR] [--quiet] [--force]
#
#   --root DIR   project root to build for (default: $PWD)
#   --quiet      no output at all, including the root-guard refusal
#   --force      accepted and ignored — see "fingerprint cache" below
#
# Fingerprint cache (deferred, on purpose): upstream keys a no-op refresh on
# path:mtime:size:sha1. A full scan here is ~100 ms and Kurama's hooks policy
# forbids a new per-prompt hook, so the refresh points are all SDD-state or
# install events (setup.sh, update.sh, sdd-init, the skill itself). --force is
# accepted now so the flag does not become a breaking change when the cache
# lands; it is a no-op today because every run is already a full rebuild.
# ============================================================================
set -eu

SCRIPT_PATH="$0"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd)"
# The skills directory this script was installed into: <skills-dir>/_shared/.
# Scanning it is the catch-all that always covers the ACTIVE harness target even
# when it is not one of the five named user-level paths below.
INSTALLED_SKILLS_DIR="$(dirname "$SCRIPT_DIR")"

ROOT="$PWD"
QUIET=0
OUT_NAME=".kurama/skill-registry.md"
TAB="$(printf '\t')"

usage() {
    cat <<'USAGE'
build-skill-registry.sh — write .kurama/skill-registry.md (index only)

  --root DIR   project root to build the registry for (default: current dir)
  --quiet      suppress all output, including the root-guard refusal
  --force      accepted, no-op (the fingerprint cache is deferred)
  -h, --help   this message

Exit status is 0 for a successful build AND for a refused root; a non-zero
status means the registry could not be written.
USAGE
}

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$1"; }
say_err() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$1" >&2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --root)
            if [ $# -lt 2 ]; then printf '%s\n' "build-skill-registry.sh: --root needs a value" >&2; exit 2; fi
            ROOT="$2"; shift 2 ;;
        --root=*) ROOT="${1#--root=}"; shift ;;
        --quiet|-q) QUIET=1; shift ;;
        --force|-f) shift ;;   # see the fingerprint-cache note in the header
        -h|--help) usage; exit 0 ;;
        *) printf '%s\n' "build-skill-registry.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ ! -d "$ROOT" ]; then
    printf '%s\n' "build-skill-registry.sh: not a directory: $ROOT" >&2
    exit 2
fi
ROOT="$(cd "$ROOT" && pwd)"

# ----------------------------------------------------------------------------
# Root guard
#
# This script creates a directory and writes a file into whatever it is pointed
# at. Pointed at / or $HOME — which is what a cwd-relative default does the one
# time somebody runs it from the wrong shell — it would scatter .kurama/ into a
# home directory or a filesystem root. So: those two are refused outright, and
# anything else has to look like a project (a git repo, an existing .kurama/, or
# a project-level skills directory). A refusal is exit 0, never an error: the
# callers (setup, update, sdd-init) run this opportunistically and a home-dir
# install has nothing to build.
# ----------------------------------------------------------------------------
HOME_DIR="${HOME:-}"
if [ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ]; then
    HOME_DIR="$(cd "$HOME_DIR" && pwd)"
fi

refuse() {
    say_err "skill-registry: $ROOT is not a project root — skipped ($1)"
    exit 0
}

[ "$ROOT" = "/" ] && refuse "the filesystem root"
if [ -n "$HOME_DIR" ] && [ "$ROOT" = "$HOME_DIR" ]; then
    refuse "your home directory"
fi

has_project_marker() {
    [ -e "$ROOT/.git" ] && return 0
    [ -d "$ROOT/.kurama" ] && return 0
    local d
    for d in .claude/skills .config/opencode/skills .codex/skills .pi/skills .omp/skills skills; do
        [ -d "$ROOT/$d" ] && return 0
    done
    return 1
}
has_project_marker || refuse "no .git, no .kurama/ and no project skills directory"

# ----------------------------------------------------------------------------
# Scan
#
# EXACTLY one level deep: a skill is <skills-dir>/<skill>/SKILL.md and nothing
# deeper. Bundles keep their source checkout inside the skills directory, with
# per-skill templates under it; recursing turns one skill into two rows and the
# delegator then picks between them arbitrarily — sometimes landing on a source
# copy that was never rendered. `find -L` so a symlinked skill directory (or a
# symlinked skills root) still resolves.
#
# ONE awk per scan root, not one per skill: the awk reads each SKILL.md itself
# with getline, so a 100-skill machine costs a dozen processes instead of three
# hundred. Only `name` and `description` are read — nothing else in the file is
# opened for meaning, which is the whole point of the rewrite.
#
# Frontmatter handled: CRLF line endings; the YAML block scalars (`>`, `>-`,
# `|`, `|-` and their explicit-indent forms) that Kurama's own descriptions use;
# quoted plain scalars; plain multi-line folded values; and nested blocks
# (`metadata:`) whose indented keys must NOT be read as top-level ones.
#
# Emits "<name>\t<scope>\t<path>\t<trigger>", one row per skill, in scan order.
# ----------------------------------------------------------------------------
scan_root() {
    local root="$1" scope="$2"
    [ -d "$root" ] || return 0
    find -L "$root" -mindepth 2 -maxdepth 2 -name SKILL.md -type f 2>/dev/null \
        | LC_ALL=C sort \
        | awk -v scope="$scope" '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

        # A literal pipe would break the markdown table this text lands in.
        # Built by concatenation, never by a gsub replacement: "\\|" means one
        # thing to BWK awk and another to gawk/mawk, and the row shape is
        # asserted byte-for-byte by the suite.
        function esc_pipe(s,   n, parts, out, i) {
            n = split(s, parts, /\|/)
            out = parts[1]
            for (i = 2; i <= n; i++) out = out "\\" "|" parts[i]
            return out
        }

        # Reads the frontmatter of $f into the globals FM_NAME / FM_TRIGGER.
        # awk functions return one value; two globals are cheaper than encoding
        # and re-splitting a pair.
        function parse_file(f,   line, started, cur, nm, ds, k, v, t, i, trig) {
            started = 0; cur = ""; nm = ""; ds = ""
            while ((getline line < f) > 0) {
                sub(/\r$/, "", line)
                if (!started) {
                    if (line ~ /^[ \t]*$/) continue
                    # No opening --- means no frontmatter: nothing to read.
                    if (line ~ /^---[ \t]*$/) { started = 1; continue }
                    break
                }
                # The closing fence ends the frontmatter.
                if (line ~ /^(---|\.\.\.)[ \t]*$/) break
                # A blank line inside a block scalar is a paragraph break, not
                # the end of the value — keep the current key.
                if (line ~ /^[ \t]*$/) continue
                # Indented: a continuation of the current key (block scalar
                # body, or a folded plain scalar), or a nested key under one we
                # already decided to ignore.
                if (line ~ /^[ \t]/) {
                    t = trim(line)
                    if (cur == "name")             nm = (nm == "" ? t : nm " " t)
                    else if (cur == "description") ds = (ds == "" ? t : ds " " t)
                    continue
                }
                if (line ~ /^[A-Za-z0-9_.-]+[ \t]*:/) {
                    k = line; sub(/[ \t]*:.*$/, "", k)
                    v = line; sub(/^[^:]*:[ \t]*/, "", v); v = trim(v)
                    if (k != "name" && k != "description") { cur = ""; continue }
                    cur = k
                    # `>`, `>-`, `|2`, … : the value is the block indented below.
                    if (v ~ /^[>|][-+0-9]*$/) continue
                    sub(/^"/, "", v); sub(/"$/, "", v)
                    sub(/^\047/, "", v); sub(/\047$/, "", v)
                    if (k == "name") nm = (nm == "" ? v : nm " " v)
                    else             ds = (ds == "" ? v : ds " " v)
                    continue
                }
                cur = ""
            }
            close(f)

            # The table shows the TRIGGER, which the convention puts after
            # "Trigger:" inside the description. No marker: the whole
            # description is the trigger text.
            trig = ds
            i = index(ds, "Trigger:")
            if (i > 0) trig = substr(ds, i + 8)
            trig = trim(trig); gsub(/[ \t]+/, " ", trig)
            nm = trim(nm);     gsub(/[ \t]+/, " ", nm)
            FM_NAME = esc_pipe(nm)
            FM_TRIGGER = esc_pipe(trig)
        }

        {
            f = $0
            if (f == "") next
            dir = f;   sub(/\/[^\/]*$/, "", dir)
            base = dir; sub(/^.*\//, "", base)
            if (base == "_shared" || base == "skill-registry" || base ~ /^sdd-/) next
            parse_file(f)
            nm = FM_NAME
            if (nm == "") nm = base          # name falls back to the dir name
            trig = FM_TRIGGER
            if (trig == "") trig = "—"
            printf "%s\t%s\t%s\t%s\n", nm, scope, f, trig
        }
    '
}

# Deduplicate by NAME, first row wins. Project roots are scanned first, so a
# skill installed both project-level and user-level resolves to the project copy
# (more specific); two user-level copies resolve to scan order.
ROWS_RAW="$(mktemp)"
ROWS="$(mktemp)"
CONV="$(mktemp)"
trap 'rm -f "$ROWS_RAW" "$ROWS" "$CONV"' EXIT INT TERM

# Project-level (6) FIRST — they win the dedupe.
for d in .claude/skills .config/opencode/skills .codex/skills .pi/skills .omp/skills skills; do
    scan_root "$ROOT/$d" project >> "$ROWS_RAW"
done
# User-level (5 named install targets) …
if [ -n "$HOME_DIR" ]; then
    for d in .claude/skills .config/opencode/skills .codex/skills .pi/agent/skills .omp/agent/skills; do
        scan_root "$HOME_DIR/$d" user >> "$ROWS_RAW"
    done
fi
# … plus the catch-all: the skills directory this script was INSTALLED into.
# Kurama's own skills are co-located with it, so scanning that directory always
# covers the active harness target even when it is not one of the five named
# paths above. Dedupe by name makes the overlap with them free.
#
# Skipped when this copy is running out of the CLONE. setup.sh and update.sh both
# invoke the builder from the repo, where `skills/` holds SOURCES — including
# groups a default install deliberately excludes (`--without lang`). Indexing
# them would advertise skills the project does not have, at paths inside somebody
# else's checkout. `skills/manifest.json` sits beside `_shared/` in the clone and
# is never copied to an install, which is exactly the distinction.
if [ ! -f "$INSTALLED_SKILLS_DIR/manifest.json" ]; then
    scan_root "$INSTALLED_SKILLS_DIR" user >> "$ROWS_RAW"
fi

LC_ALL=C awk -F'\t' '!seen[$1]++' "$ROWS_RAW" \
    | LC_ALL=C sort -t "$TAB" -k1,1 > "$ROWS"

SKILL_COUNT="$(LC_ALL=C awk 'END { print NR + 0 }' "$ROWS")"
USER_COUNT="$(LC_ALL=C awk -F'\t' '$2 == "user" { n++ } END { print n + 0 }' "$ROWS")"
PROJ_COUNT="$(LC_ALL=C awk -F'\t' '$2 == "project" { n++ } END { print n + 0 }' "$ROWS")"

# ----------------------------------------------------------------------------
# Project conventions
#
# The index file AND every .md path it references that actually exists, so a
# sub-agent handed this table needs zero extra hops. On a case-insensitive
# filesystem AGENTS.md and agents.md are the same file — `-ef` (same inode) is
# what tells them apart, not the string.
# ----------------------------------------------------------------------------
extract_md_refs() {
    awk '
        {
            s = $0
            while (match(s, /\]\([^)]*\.md[^)]*\)/)) {
                m = substr(s, RSTART + 2, RLENGTH - 3)
                sub(/[ \t].*$/, "", m); sub(/#.*$/, "", m)
                if (m != "") print m
                s = substr(s, RSTART + RLENGTH)
            }
            s = $0
            while (match(s, /`[^`]*\.md`/)) {
                m = substr(s, RSTART + 1, RLENGTH - 2)
                sub(/#.*$/, "", m)
                if (m != "") print m
                s = substr(s, RSTART + RLENGTH)
            }
        }
    ' "$1" 2>/dev/null || true
}

conv_emitted=""
for base in AGENTS.md agents.md CLAUDE.md; do
    cfile="$ROOT/$base"
    [ -f "$cfile" ] || continue
    dup=0
    for seen_base in $conv_emitted; do
        if [ "$cfile" -ef "$ROOT/$seen_base" ]; then dup=1; break; fi
    done
    [ "$dup" -eq 1 ] && continue
    conv_emitted="$conv_emitted $base"

    case "$base" in
        AGENTS.md|agents.md)
            refs="$(extract_md_refs "$cfile" | LC_ALL=C awk '!seen[$0]++')"
            kept=""
            for ref in $refs; do
                case "$ref" in
                    /*|*://*|..*) continue ;;
                esac
                ref="${ref#./}"
                [ -f "$ROOT/$ref" ] || continue
                kept="$kept $ref"
            done
            if [ -n "$kept" ]; then
                printf '| %s | %s | Index — references the files below |\n' "$base" "$base" >> "$CONV"
                for ref in $kept; do
                    printf '| %s | %s | Referenced by %s |\n' "$(basename "$ref")" "$ref" "$base" >> "$CONV"
                done
            else
                printf '| %s | %s | |\n' "$base" "$base" >> "$CONV"
            fi
            ;;
        *)
            printf '| %s | %s | |\n' "$base" "$base" >> "$CONV"
            ;;
    esac
done
CONV_COUNT="$(LC_ALL=C awk 'END { print NR + 0 }' "$CONV")"

# ----------------------------------------------------------------------------
# Write — temp + mv, so a reader never sees a half-written registry. Several
# harness hooks can race on a refresh; a rename within the same directory is the
# only write that is atomic for all of them.
# ----------------------------------------------------------------------------
OUT="$ROOT/$OUT_NAME"
OUT_DIR="$(dirname "$OUT")"
mkdir -p "$OUT_DIR"
TMP_OUT="$OUT.tmp.$$"

{
    cat <<'HEADER'
# Skill Registry

**Delegator use only.** Any agent that launches sub-agents reads this registry to
resolve skills: it looks a skill up in the index below and passes that skill's
SKILL.md path into the sub-agent's prompt. Sub-agents do not read this registry
themselves.

**This registry is an INDEX, not a summary.** It carries no pre-digested rules,
no per-skill digests and no generated prose — only what a skill's frontmatter
already says about itself. Resolve by path and let the sub-agent read the full
SKILL.md: a full read is authoritative, a digest is lossy and goes stale
silently. See `_shared/skill-resolver.md` for the resolution protocol.

Generated by `_shared/build-skill-registry.sh`. Do not hand-edit — the next
`/skill-registry`, `/sdd-init`, install or update run overwrites it.

## User Skills

| Trigger | Skill | Path |
|---------|-------|------|
HEADER
    LC_ALL=C awk -F'\t' '{ printf "| %s | %s | %s |\n", $4, $1, $3 }' "$ROWS"
    printf '\n'
    printf '## Project Conventions\n\n'
    printf '| File | Path | Notes |\n'
    printf '|------|------|-------|\n'
    if [ "$CONV_COUNT" -gt 0 ]; then
        cat "$CONV"
        cat <<'CONV_FOUND'

Read the convention files listed above for project-specific patterns and rules.
Every path an index file references has already been extracted — there is no need
to read an index file just to discover more.
CONV_FOUND
    else
        cat <<'CONV_NONE'

No convention files found in the project root (`AGENTS.md`, `agents.md`, `CLAUDE.md`).
CONV_NONE
    fi
} > "$TMP_OUT"

mv -f "$TMP_OUT" "$OUT"

say "skill-registry: $SKILL_COUNT skills ($USER_COUNT user, $PROJ_COUNT project) → $OUT_NAME"
exit 0
