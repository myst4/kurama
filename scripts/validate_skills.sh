#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Agent Teams Lite — Skills Structural Linter
# Run: bash scripts/validate_skills.sh
#
# A dependency-light, portable (POSIX/bash 3.2, BSD + GNU userland) linter that
# catches drift between the skills tree, the installers, and the docs. It is NOT
# a `set -e` script: every check runs to completion so ALL problems are reported
# in one pass. The exit code is derived from the failure counter at the end.
#
# Checks:
#   1. Every skills/<name>/ has a SKILL.md with `name:` and `description:`
#      frontmatter.                                                     [FATAL]
#   2. Every skill the installers reference actually exists.            [FATAL]
#   3. skills/manifest.json parses, every listed skill dir exists, and
#      every skills/<name>/ dir is listed with a valid group.           [FATAL]
#   4. Every skill directory is listed in AGENTS.md.                    [WARN]
#   5. Fenced ```yaml blocks in skills/_shared/openspec-convention.md
#      parse (requires python3 + PyYAML; soft-skips otherwise).         [FATAL]
#   6. Packaging manifests (.claude-plugin/plugin.json,
#      .claude-plugin/marketplace.json, gemini-extension.json) parse as
#      JSON (jq/python3; soft-skips if neither), and plugin.json "version"
#      equals the VERSION file.                                         [FATAL]
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SKILLS_SRC="$REPO_DIR/skills"

FAIL=0
WARN=0

pass()    { printf '  [ OK ] %s\n' "$1"; }
fail()    { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn()    { printf '  [WARN] %s\n' "$1"; WARN=$((WARN + 1)); }
info()    { printf '  [ .. ] %s\n' "$1"; }
section() { printf '\n== %s ==\n' "$1"; }

# ----------------------------------------------------------------------------
# Check 1 — SKILL.md exists with name:/description: frontmatter
# ----------------------------------------------------------------------------

check_skill_frontmatter() {
    section "SKILL.md frontmatter"
    local before=$FAIL
    local skill_dir skill_name skill_md fm

    for skill_dir in "$SKILLS_SRC"/*/; do
        skill_name="$(basename "$skill_dir")"
        [ "$skill_name" = "_shared" ] && continue

        skill_md="${skill_dir%/}/SKILL.md"
        if [ ! -f "$skill_md" ]; then
            fail "skills/$skill_name/: missing SKILL.md"
            continue
        fi

        # Extract the leading YAML frontmatter (lines strictly between the first
        # pair of `---` fences).
        fm="$(awk '
            /^---[[:space:]]*$/ { c++; if (c == 1) { f = 1; next } if (c == 2) { exit } }
            f { print }
        ' "$skill_md")"

        if [ -z "$fm" ]; then
            fail "skills/$skill_name/SKILL.md: no YAML frontmatter (--- ... ---)"
            continue
        fi
        if ! printf '%s\n' "$fm" | grep -qE '^name:'; then
            fail "skills/$skill_name/SKILL.md: frontmatter missing 'name:'"
        fi
        if ! printf '%s\n' "$fm" | grep -qE '^description:'; then
            fail "skills/$skill_name/SKILL.md: frontmatter missing 'description:'"
        fi
    done

    [ "$FAIL" -eq "$before" ] && pass "All skills have SKILL.md with name:/description: frontmatter"
}

# ----------------------------------------------------------------------------
# Check 2 — Skills referenced by the installers exist
# ----------------------------------------------------------------------------

# Emit the literal "$SKILLS_SRC"/<name>/ references from an installer script.
# Glob entries (e.g. sdd-*) are emitted verbatim and expanded by the caller.
installer_referenced_skills() {
    local script="$1"
    [ -f "$script" ] || return 0
    # The single quotes are intentional: we match the LITERAL text $SKILLS_SRC as
    # it appears in the installer source, not its expansion here.
    # shellcheck disable=SC2016
    grep -oE '"\$SKILLS_SRC"/[A-Za-z0-9_*-]+/' "$script" 2>/dev/null \
        | sed -e 's#"\$SKILLS_SRC"/##' -e 's#/$##'
}

check_installer_refs() {
    section "Installer skill references"
    local before=$FAIL
    local names name d matched

    names="$(
        {
            installer_referenced_skills "$SCRIPT_DIR/install.sh"
            installer_referenced_skills "$SCRIPT_DIR/setup.sh"
        } | sort -u
    )"

    if [ -z "$names" ]; then
        fail "Could not extract any skill references from install.sh/setup.sh (installer format changed?)"
        return
    fi

    # Heredoc (not a pipe) so the loop runs in this shell and fail() sticks.
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        case "$name" in
            *"*"*)
                # Glob pattern such as sdd-*: expand against the skills tree.
                matched=0
                for d in "$SKILLS_SRC"/$name/; do
                    [ -d "$d" ] || continue
                    matched=1
                    [ -f "${d%/}/SKILL.md" ] || fail "installer references $(basename "$d")/ but its SKILL.md is missing"
                done
                [ "$matched" -eq 1 ] || fail "installer glob '$name' matched no skill directories under skills/"
                ;;
            *)
                if [ ! -d "$SKILLS_SRC/$name" ]; then
                    fail "installer references skills/$name/ but the directory does not exist"
                elif [ ! -f "$SKILLS_SRC/$name/SKILL.md" ]; then
                    fail "installer references skills/$name/ but its SKILL.md is missing"
                fi
                ;;
        esac
    done <<EOF
$names
EOF

    [ "$FAIL" -eq "$before" ] && pass "All installer-referenced skills exist with SKILL.md"
}

# ----------------------------------------------------------------------------
# Check 3 — skills/manifest.json is coherent with the skills tree
# ----------------------------------------------------------------------------

# Emit "<name> <group>" for every skill declared in skills/manifest.json.
# jq when available, otherwise a portable awk fallback (bash 3.2 / BSD awk).
manifest_skill_lines() {
    local manifest="$1"
    [ -f "$manifest" ] || return 1
    if command -v jq >/dev/null 2>&1; then
        jq -r '.skills[] | "\(.name) \(.group)"' "$manifest" 2>/dev/null
        return 0
    fi
    awk '
        /"skills"[[:space:]]*:[[:space:]]*\[/ { inarr = 1; next }
        inarr && /\]/ { inarr = 0 }
        inarr {
            name = ""; group = ""
            if (match($0, /"name"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
                s = substr($0, RSTART, RLENGTH)
                sub(/.*"name"[[:space:]]*:[[:space:]]*"/, "", s)
                sub(/".*/, "", s)
                name = s
            }
            if (match($0, /"group"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
                g = substr($0, RSTART, RLENGTH)
                sub(/.*"group"[[:space:]]*:[[:space:]]*"/, "", g)
                sub(/".*/, "", g)
                group = g
            }
            if (name != "" && group != "") print name " " group
        }
    ' "$manifest"
}

check_manifest() {
    section "skills/manifest.json"
    local manifest="$SKILLS_SRC/manifest.json"
    local before=$FAIL

    if [ ! -f "$manifest" ]; then
        fail "skills/manifest.json is missing (installers derive the skill list from it)"
        return
    fi

    # Parses as JSON (jq preferred, python3 fallback, otherwise soft-skip).
    if command -v jq >/dev/null 2>&1; then
        if ! jq -e . "$manifest" >/dev/null 2>&1; then
            fail "skills/manifest.json is not valid JSON (jq parse failed)"
            return
        fi
    elif command -v python3 >/dev/null 2>&1; then
        if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$manifest" >/dev/null 2>&1; then
            fail "skills/manifest.json is not valid JSON (python parse failed)"
            return
        fi
    else
        info "Neither jq nor python3 available — skipping manifest JSON parse (soft skip)"
    fi

    local lines
    lines="$(manifest_skill_lines "$manifest")"
    if [ -z "$lines" ]; then
        fail "skills/manifest.json has no skills[] entries"
        return
    fi

    # Every listed skill exists with SKILL.md and a valid group.
    local name group listed=""
    while IFS=' ' read -r name group; do
        [ -n "$name" ] || continue
        listed="$listed $name"
        case "$group" in
            sdd-core|quality|review|optional|tdd) ;;
            *) fail "manifest: skill '$name' has invalid group '$group' (expected sdd-core|quality|review|optional|tdd)" ;;
        esac
        if [ ! -d "$SKILLS_SRC/$name" ]; then
            fail "manifest lists '$name' but skills/$name/ does not exist"
        elif [ ! -f "$SKILLS_SRC/$name/SKILL.md" ]; then
            fail "manifest lists '$name' but skills/$name/SKILL.md is missing"
        fi
    done <<EOF
$lines
EOF

    # Every skill directory (except _shared) is listed in the manifest.
    local skill_dir skill_name
    for skill_dir in "$SKILLS_SRC"/*/; do
        skill_name="$(basename "$skill_dir")"
        [ "$skill_name" = "_shared" ] && continue
        [ -f "${skill_dir%/}/SKILL.md" ] || continue
        case " $listed " in
            *" $skill_name "*) ;;
            *) fail "skills/$skill_name/ exists but is not listed in skills/manifest.json" ;;
        esac
    done

    [ "$FAIL" -eq "$before" ] && pass "manifest.json parses; every skill is listed once and exists with a valid group"
}

# ----------------------------------------------------------------------------
# Check 4 — Every skill directory is listed in AGENTS.md (warning-level)
# ----------------------------------------------------------------------------

check_agents_md_coverage() {
    section "AGENTS.md index coverage"
    local agents_md="$REPO_DIR/AGENTS.md"
    if [ ! -f "$agents_md" ]; then
        warn "AGENTS.md not found at repo root — skipping index coverage check"
        return
    fi

    local uncovered=0 skill_dir skill_name
    for skill_dir in "$SKILLS_SRC"/*/; do
        skill_name="$(basename "$skill_dir")"
        [ "$skill_name" = "_shared" ] && continue
        [ -f "${skill_dir%/}/SKILL.md" ] || continue
        if ! grep -qF "skills/$skill_name/" "$agents_md"; then
            warn "skills/$skill_name/ is not listed in AGENTS.md"
            uncovered=$((uncovered + 1))
        fi
    done

    [ "$uncovered" -eq 0 ] && pass "All skill directories are listed in AGENTS.md"
}

# ----------------------------------------------------------------------------
# Check 5 — YAML fenced blocks in openspec-convention.md parse
# ----------------------------------------------------------------------------

check_yaml_blocks() {
    section "openspec-convention.md YAML blocks"
    local conv="$SKILLS_SRC/_shared/openspec-convention.md"
    if [ ! -f "$conv" ]; then
        warn "openspec-convention.md not found — skipping YAML block check"
        return
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        info "python3 not available — skipping YAML block parse check (soft skip)"
        return
    fi

    local out rc
    out="$(python3 - "$conv" <<'PY'
import re
import sys

try:
    import yaml
except Exception:
    sys.exit(3)  # PyYAML unavailable -> soft skip

with open(sys.argv[1], encoding="utf-8") as fh:
    text = fh.read()

blocks = re.findall(r"```yaml[^\n]*\n(.*?)```", text, re.DOTALL)
if not blocks:
    print("NO_YAML_BLOCKS")
    sys.exit(0)

bad = 0
for i, block in enumerate(blocks, 1):
    try:
        yaml.safe_load(block)
    except Exception as exc:  # noqa: BLE001 - report any parse failure
        bad += 1
        msg = str(exc).splitlines()[0] if str(exc) else exc.__class__.__name__
        print("block %d: %s" % (i, msg))

sys.exit(2 if bad else 0)
PY
    )"
    rc=$?

    case "$rc" in
        0)
            if printf '%s' "$out" | grep -q 'NO_YAML_BLOCKS'; then
                pass "No fenced yaml blocks to validate in openspec-convention.md"
            else
                pass "All yaml blocks in openspec-convention.md parse"
            fi
            ;;
        3)
            info "PyYAML not installed — skipping YAML block parse check (soft skip)"
            ;;
        2)
            fail "Invalid YAML in openspec-convention.md:"
            [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/         /'
            ;;
        *)
            fail "YAML block check failed unexpectedly (python exit $rc)"
            [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/         /'
            ;;
    esac
}

# ----------------------------------------------------------------------------
# Check 6 — Packaging manifests parse + plugin.json version matches VERSION
# ----------------------------------------------------------------------------

# Parse a JSON file: jq preferred, python3 fallback. Prints nothing.
# Returns 0 on valid JSON, 1 on invalid, 2 when no parser is available.
json_parses() {
    local f="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -e . "$f" >/dev/null 2>&1 && return 0 || return 1
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" >/dev/null 2>&1 && return 0 || return 1
    fi
    return 2
}

# Read the top-level "version" string from a JSON file (jq/python3). Empty on failure.
json_version() {
    local f="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r '.version // empty' "$f" 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$f" 2>/dev/null
    fi
}

check_packaging_manifests() {
    section "Packaging manifests"
    local before=$FAIL
    local plugin="$REPO_DIR/.claude-plugin/plugin.json"
    local marketplace="$REPO_DIR/.claude-plugin/marketplace.json"
    local gemini="$REPO_DIR/gemini-extension.json"
    local version_file="$REPO_DIR/VERSION"
    local no_parser=0 f rc

    for f in "$plugin" "$marketplace" "$gemini"; do
        local label
        label="$(basename "$f")"
        if [ ! -f "$f" ]; then
            fail "$label is missing (packaging manifest expected)"
            continue
        fi
        json_parses "$f"; rc=$?
        case "$rc" in
            0) ;;  # valid; reported collectively below
            1) fail "$label is not valid JSON" ;;
            2) no_parser=1 ;;
        esac
    done

    if [ "$no_parser" -eq 1 ]; then
        info "Neither jq nor python3 available — skipping packaging-manifest JSON parse (soft skip)"
    fi

    # plugin.json "version" must equal the VERSION file (only when a parser exists
    # and both files are present/valid).
    if [ "$no_parser" -eq 0 ] && [ -f "$plugin" ] && [ -f "$version_file" ]; then
        local expected actual
        IFS= read -r expected < "$version_file" || expected=""
        actual="$(json_version "$plugin")"
        if [ -z "$actual" ]; then
            fail "plugin.json has no top-level \"version\" field"
        elif [ "$actual" != "$expected" ]; then
            fail "plugin.json version '$actual' != VERSION file '$expected'"
        fi
    fi

    [ "$FAIL" -eq "$before" ] && pass "plugin.json/marketplace.json/gemini-extension.json parse; plugin.json version matches VERSION"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

printf '== Agent Teams Lite — Skills Linter ==\n'
printf 'Repo: %s\n' "$REPO_DIR"

check_skill_frontmatter
check_installer_refs
check_manifest
check_agents_md_coverage
check_yaml_blocks
check_packaging_manifests

section "Summary"
if [ "$FAIL" -gt 0 ]; then
    printf '  %d check(s) FAILED, %d warning(s).\n' "$FAIL" "$WARN"
    exit 1
fi
if [ "$WARN" -gt 0 ]; then
    printf '  All checks passed with %d warning(s).\n' "$WARN"
else
    printf '  All checks passed.\n'
fi
exit 0
