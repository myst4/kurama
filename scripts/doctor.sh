#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Kurama — Doctor / Health Check (O7)
#
# Read-only diagnosis of an install. Touches nothing; it only reads receipts,
# disk, and the environment, prints a green/red line per check, and exits
# non-zero if any hard check fails. Mirrors setup.sh path resolution so it
# inspects exactly what setup wrote.
#
# Checks:
#   - receipt present, and each recorded file exists (missing = FAIL) + drift
#     vs the current repo source (WARN)
#   - installed version (receipt) vs the repo VERSION
#   - orchestrator prompt markers balanced (BEGIN/END)
#   - Claude Code hooks present in settings.json (claude-code)
#   - gh present + authenticated + project scopes (kanban prerequisite)
#   - pi present + the Pi package stack (best-effort via `pi list`)
#   - engram present + responds (engram --version)
#   - Engram MCP registrations recorded in the receipt still exist (O5)
#
# Usage:
#   ./doctor.sh --agent claude-code
#   ./doctor.sh --scope project --path /repo
#   ./doctor.sh                       # every global agent that has a receipt
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
VERSION_FILE="$REPO_DIR/VERSION"
INSTALL_MANIFEST_NAME=".kurama-install-manifest.json"
EXAMPLES_DIR="$REPO_DIR/examples"
SKILLS_SRC="$REPO_DIR/skills"

ALL_AGENTS="claude-code opencode codex pi omp"

SCOPE="global"
AGENT=""
TARGET_PATH=""

FAILS=0
WARNS=0

# ============================================================================
# Colors
# ============================================================================

setup_colors() {
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
}
pass() { echo -e "  ${GREEN}✓${NC} $1"; }
bad()  { echo -e "  ${RED}✗${NC} $1"; FAILS=$((FAILS + 1)); }
soft() { echo -e "  ${YELLOW}!${NC} $1"; WARNS=$((WARNS + 1)); }
note() { echo -e "  ${CYAN}→${NC} $1"; }
header() { echo -e "\n${CYAN}${BOLD}$1${NC}"; }

home_dir() { echo "$HOME"; }

read_version() {
    local v="unknown"
    [ -f "$VERSION_FILE" ] && { IFS= read -r v < "$VERSION_FILE" || true; [ -n "$v" ] || v="unknown"; }
    printf '%s' "$v"
}

# Short commit SHA of the current Kurama repo checkout ('' when git is unavailable).
repo_commit() {
    local c=""
    if command -v git >/dev/null 2>&1; then
        c="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    fi
    printf '%s' "$c"
}

# Render "version (commit)", collapsing to just "version" when no commit is known.
fmt_ver_commit() {
    local v="$1" c="$2"
    if [ -n "$c" ]; then printf '%s (%s)' "$v" "$c"; else printf '%s' "$v"; fi
}

# ============================================================================
# Path + receipt helpers (mirror setup.sh)
# ============================================================================

global_skills_path() {
    local agent="$1" home; home="$(home_dir)"
    case "$agent" in
        claude-code)  echo "$home/.claude/skills" ;;
        opencode)     echo "$home/.config/opencode/skills" ;;
        codex)        echo "$home/.codex/skills" ;;
        pi)           echo "$home/.pi/agent/skills" ;;
        omp)          echo "${PI_CODING_AGENT_DIR:-$home/.omp/agent}/skills" ;;
        *)            echo "" ;;
    esac
}

# No receipt does not automatically mean "nothing installed". Kurama artifacts can
# survive on disk with the receipt gone — a hand-moved skills dir, a partial
# migration, an interrupted uninstall. That state is worse than a clean absence:
# the agents and commands are still wired and still route work, but they reference
# skill files that may no longer be there, and update.sh/uninstall.sh cannot manage
# what no receipt records. Reporting "healthy" for it is a false green, so any
# orphan found here is a failure with the exact paths to look at.
check_orphans() {
    local home found=false; home="$(home_dir)"
    local agents_dir="$home/.claude/agents" cmds_dir="$home/.claude/commands"
    local skills_dir; skills_dir="$(global_skills_path claude-code)"

    # Kurama-owned native agents (sdd-* / jd-*) wired with no receipt behind them.
    local orphan_agents=0 f base
    if [ -d "$agents_dir" ]; then
        for f in "$agents_dir"/sdd-*.md "$agents_dir"/jd-*.md; do
            [ -f "$f" ] || continue
            orphan_agents=$((orphan_agents + 1))
        done
    fi
    if [ "$orphan_agents" -gt 0 ]; then
        found=true
        bad "$orphan_agents Kurama agent(s) in $agents_dir with no install receipt"
        # The agents read their phase skill at launch; a missing skills dir means
        # every delegation silently runs without its phase instructions.
        if [ ! -d "$skills_dir/sdd-init" ]; then
            bad "  agents reference $skills_dir/sdd-*/SKILL.md — that path does not exist"
            for f in "$home"/.claude/skills-*backup*; do
                [ -d "$f" ] || continue
                bad "  skills appear to have been moved to $(basename "$f")"
                break
            done
        fi
    fi

    if [ -d "$cmds_dir" ]; then
        local orphan_cmds=0
        for f in "$cmds_dir"/sdd-*.md; do
            [ -f "$f" ] || continue
            orphan_cmds=$((orphan_cmds + 1))
        done
        if [ "$orphan_cmds" -gt 0 ]; then
            found=true
            bad "$orphan_cmds Kurama command(s) in $cmds_dir with no install receipt"
        fi
    fi

    if $found; then
        note "Re-run setup.sh to reinstall and write a receipt, or remove the stale files by hand."
    else
        note "No Kurama artifacts on disk either — nothing is installed."
    fi
}

global_prompt_path() {
    local agent="$1" home; home="$(home_dir)"
    case "$agent" in
        claude-code)  echo "$home/.claude/CLAUDE.md" ;;
        opencode)     echo "$home/.config/opencode/AGENTS.md" ;;
        codex)        echo "$home/.codex/agents.md" ;;
        pi)           echo "$home/.pi/agent/AGENTS.md" ;;
        omp)          echo "${PI_CODING_AGENT_DIR:-$home/.omp/agent}/AGENTS.md" ;;
        *)            echo "" ;;
    esac
}

manifest_field() {
    local manifest="$1" key="$2"
    [ -f "$manifest" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$key" '.[$k] // ""' "$manifest" 2>/dev/null; return 0
    fi
    awk -v key="$key" '
        match($0, "\"" key "\"[[:space:]]*:[[:space:]]*\"[^\"]*\"") {
            s = substr($0, RSTART, RLENGTH); sub(/.*:[[:space:]]*"/, "", s); sub(/".*/, "", s); print s; exit
        }' "$manifest"
}

# Emit each element of a flat receipt array — "files", "tools", … (jq or awk
# fallback). Mirrors manifest_json_array in update.sh/uninstall.sh so every
# script parses a receipt the same way.
#
# Why the opening rule handles the whole array itself instead of just setting
# inarr: for a single-line "key": [] the array closes on the line that opened it,
# so setting inarr and skipping to the next line hands the closing-bracket check
# a bracket that never arrives. The parser then runs to the end of the receipt,
# printing the NEXT key's declaration line as if it were an element, followed by
# the elements that belong to that other key. uninstall.sh drives rm from
# files[], so an empty files[] would migrate .claude/settings.json out of
# settings[] and delete the file outright instead of stripping its kurama hooks
# block. The !inarr guard is the same defense one level up: without it a later
# "<key>" nested elsewhere in the receipt re-opens an array already closed.
manifest_json_array() {
    local manifest="$1" key="$2"
    [ -f "$manifest" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$key" '(.[$k] // [])[]' "$manifest" 2>/dev/null; return 0
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
            line = $0; gsub(/^[[:space:]]+/, "", line); gsub(/[[:space:]]+$/, "", line)
            gsub(/,$/, "", line); gsub(/"/, "", line)
            if (line != "") print line
        }' "$manifest"
}

hash_file() {
    [ -f "$1" ] || { printf ''; return 0; }
    if command -v shasum >/dev/null 2>&1; then shasum "$1" | awk '{print $1}';
    elif command -v sha1sum >/dev/null 2>&1; then sha1sum "$1" | awk '{print $1}';
    else cksum "$1" | awk '{print $1"-"$2}'; fi
}

# Best-effort resolve of a recorded file's source in the repo (for drift). Prints
# the source path, or "" when it cannot be mapped (drift check is skipped then).
resolve_source() {
    local rel="$1" tool="$2" base
    base="$(basename "$rel")"
    case "$rel" in
        */hooks/kurama/*)  echo "$EXAMPLES_DIR/claude-code/hooks/$base" ;;
        */agents/*)
            if [ "$tool" = "pi" ]; then echo "$EXAMPLES_DIR/pi/agents/$base";
            elif [ "$tool" = "omp" ]; then echo "$EXAMPLES_DIR/omp/agents/$base";
            else echo "$EXAMPLES_DIR/claude-code/agents/$base"; fi ;;
        */SKILL.md|SKILL.md)
            # .../<skill>/SKILL.md → repo skills/<skill>/SKILL.md
            local skill; skill="$(basename "$(dirname "$rel")")"
            echo "$SKILLS_SRC/$skill/SKILL.md" ;;
        *_shared/*)  echo "$SKILLS_SRC/_shared/$base" ;;
        *)  echo "" ;;
    esac
}

# Every harness the receipt records. A project-scope receipt is shared by every
# harness installed into that repo, so it lists them all in "tools" and the flat
# arrays are the union across them. Receipts written by v6 and by the legacy
# install.sh have no "tools", so the effective list is the single "tool".
manifest_tools() {
    local manifest="$1" tools
    tools="$(manifest_json_array "$manifest" "tools" | awk 'NF')"
    [ -n "$tools" ] || tools="$(manifest_field "$manifest" "tool")"
    printf '%s\n' "$tools"
}

# Render a newline-separated tool list as "a, b" for a header line.
fmt_tool_list() {
    printf '%s\n' "$1" | awk 'NF { out = (out == "" ? $0 : out ", " $0) } END { print out }'
}

# resolve_source against every tool the receipt records, for a file that exists
# on disk. A project-scope receipt is shared by every harness installed into the
# repo, and resolve_source maps */agents/* per harness (pi and omp have their own
# examples dir), so no single tool can resolve the whole union.
#
# Why this prefers a content match instead of simply taking the first tool whose
# mapping exists: examples/claude-code/agents/sdd-spec.md and
# examples/pi/agents/sdd-spec.md are different files with the same basename, and
# both exist. For a receipt recording claude-code and pi, first-existing
# misattributes the .pi/agents/sdd-spec.md entry to the claude-code source, the
# hashes differ, and doctor reports a soft drift on a file that is perfectly in
# sync — a false red in exactly the multi-harness install this check was widened
# to cover. So: accept the candidate the installed file actually matches, and
# fall back to the first candidate that exists, which keeps a genuinely drifted
# file resolvable and still reported. The only case this weakens is a file
# hand-edited into a byte-identical copy of another recorded harness's source.
resolve_source_any() {
    local rel="$1" tools="$2" installed="$3" t src first="" installed_hash
    installed_hash="$(hash_file "$installed")"
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        src="$(resolve_source "$rel" "$t")"
        if [ -z "$src" ] || [ ! -f "$src" ]; then continue; fi
        [ -n "$first" ] || first="$src"
        if [ "$installed_hash" = "$(hash_file "$src")" ]; then printf '%s' "$src"; return 0; fi
    done <<TOOLS
$tools
TOOLS
    printf '%s' "$first"
}

# ============================================================================
# Checks
# ============================================================================

check_receipt_files() {
    local receipt_dir="$1" tools="$2"
    local manifest="$receipt_dir/$INSTALL_MANIFEST_NAME"
    local files rel missing=0 drift=0 total=0
    files="$(manifest_json_array "$manifest" "files")"
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        total=$((total + 1))
        if [ ! -e "$receipt_dir/$rel" ]; then
            missing=$((missing + 1))
            continue
        fi
        local src
        src="$(resolve_source_any "$rel" "$tools" "$receipt_dir/$rel")"
        if [ -n "$src" ]; then
            if [ "$(hash_file "$receipt_dir/$rel")" != "$(hash_file "$src")" ]; then
                drift=$((drift + 1))
            fi
        fi
    done <<EOF
$files
EOF

    if [ "$missing" -gt 0 ]; then
        bad "$missing of $total recorded file(s) MISSING from disk (run update.sh)"
    else
        pass "all $total recorded file(s) present"
    fi
    if [ "$drift" -gt 0 ]; then
        soft "$drift recorded file(s) differ from the repo source (drifted — run update.sh)"
    elif [ "$total" -gt 0 ]; then
        pass "no drift vs repo source"
    fi
}

check_version() {
    local manifest="$1"
    local installed repo icommit rcommit
    installed="$(manifest_field "$manifest" "version")"; [ -n "$installed" ] || installed="unknown"
    repo="$(read_version)"
    icommit="$(manifest_field "$manifest" "commit")"   # '' on a pre-5.0.0 receipt
    rcommit="$(repo_commit)"
    if [ "$installed" != "$repo" ]; then
        soft "version mismatch: installed $(fmt_ver_commit "$installed" "$icommit"), repo $(fmt_ver_commit "$repo" "$rcommit") (run update.sh)"
    elif [ -n "$icommit" ] && [ -n "$rcommit" ] && [ "$icommit" != "$rcommit" ]; then
        # V5: same version, different commit is not an error — it's an available update.
        note "update available: $installed installed at commit $icommit, repo at $rcommit (run update.sh)"
    else
        pass "version in sync: $(fmt_ver_commit "$installed" "$icommit")"
    fi
}

# The orchestrator prompt file one harness merges its block into (mirrors
# setup.sh). Several harnesses share one file: in project scope claude-code and
# codex both land in CLAUDE.md, and opencode/pi/omp all land in AGENTS.md.
prompt_path_for() {
    local tool="$1" scope="$2" receipt_dir="$3"
    if [ "$scope" = "project" ]; then
        case "$tool" in
            pi|opencode) echo "$receipt_dir/AGENTS.md" ;;
            omp)         echo "$receipt_dir/AGENTS.md" ;;
            *)           echo "$receipt_dir/CLAUDE.md" ;;
        esac
    else
        global_prompt_path "$tool"
    fi
}

# Check every prompt file the recorded harnesses merged into. A project-scope
# receipt records them all, and "tool" is only the most recent one — checking
# that alone leaves the other harness's prompt unverified (a claude-code +
# opencode repo would check AGENTS.md and never look at CLAUDE.md, which carries
# a BEGIN:kurama block of its own). Dedup is by RESOLVED PATH, not by tool, since
# the harnesses collapse onto shared files and a per-tool loop would print the
# same verdict twice for the same file.
check_markers() {
    local tools="$1" scope="$2" receipt_dir="$3"
    local t prompt seen=""
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        prompt="$(prompt_path_for "$t" "$scope" "$receipt_dir")"
        [ -n "$prompt" ] || continue
        printf '%s\n' "$seen" | grep -Fxq -- "$prompt" && continue
        seen="$seen
$prompt"
        check_markers_file "$prompt"
    done <<TOOLS
$tools
TOOLS
}

check_markers_file() {
    local prompt="$1"
    if [ ! -f "$prompt" ]; then
        soft "orchestrator prompt not found: $prompt"
        return 0
    fi
    # grep -c PRINTS "0" and EXITS 1 when there is no match, so `|| echo 0`
    # appends a second line and the variable becomes "0\n0" — `[ -eq ]` then dies
    # with "integer expression expected" and the else branch reports a bogus
    # UNBALANCED, masking the real diagnosis (the orchestrator was never merged,
    # or someone rewrote the prompt file over it). Assign on failure instead of
    # piping a fallback into the substitution.
    local b e
    b=$(grep -cF 'BEGIN:kurama' "$prompt" 2>/dev/null) || b=0
    e=$(grep -cF 'END:kurama' "$prompt" 2>/dev/null) || e=0
    if [ "$b" -eq "$e" ] && [ "$b" -ge 1 ]; then
        pass "orchestrator markers balanced ($b pair) in $prompt"
    elif [ "$b" -eq 0 ] && [ "$e" -eq 0 ]; then
        soft "no kurama markers in $prompt (orchestrator not merged?)"
    else
        bad "UNBALANCED kurama markers in $prompt (BEGIN=$b END=$e)"
    fi
}

check_hooks() {
    local tools="$1" scope="$2" receipt_dir="$3"
    # claude-code is the only harness that installs hooks, but it does not have
    # to be the receipt's most recent "tool" — in a claude-code + opencode repo
    # the hooks on disk are claude-code's while "tool" reads opencode. Check
    # whenever claude-code is anywhere in the recorded list. Legacy display names
    # ("Claude Code") deliberately do not match, exactly as before.
    printf '%s\n' "$tools" | grep -Fxq -- claude-code || return 0
    local settings hooks_dir
    if [ "$scope" = "project" ]; then
        settings="$receipt_dir/.claude/settings.json"
        hooks_dir="$receipt_dir/.claude/hooks/kurama"
    else
        settings="$(home_dir)/.claude/settings.json"
        hooks_dir="$(home_dir)/.claude/hooks/kurama"
    fi
    if [ -f "$hooks_dir/archive-gate.sh" ] && [ -f "$hooks_dir/orchestrator-write-guard.sh" ]; then
        pass "hook scripts present in $hooks_dir"
    else
        bad "hook scripts missing from $hooks_dir"
    fi
    if [ -f "$settings" ] && grep -q 'hooks/kurama/' "$settings" 2>/dev/null; then
        pass "hooks block present in settings.json"
    else
        bad "hooks block missing from $settings"
    fi
}

# O5/O7: report the Engram MCP registrations the receipt recorded. Read-only —
# each recorded config must still exist and reference an engram server. Entries
# are receipt-relative (project + most global agents) or absolute (e.g. the
# global claude ~/.claude.json and the codex config.toml sit outside the receipt
# dir). Recorded-but-missing is a soft warning (mention it; do not fail red).
check_engram_mcp() {
    local receipt_dir="$1"
    local manifest="$receipt_dir/$INSTALL_MANIFEST_NAME"
    local mode entries rel target found=0
    mode="$(manifest_field "$manifest" "engram")"
    entries="$(manifest_json_array "$manifest" "engram_mcp")"

    if [ -z "$entries" ]; then
        if [ "$mode" = "yes" ]; then
            note "Engram enabled but no MCP registration recorded (Pi-only, or jq was missing at setup)"
        else
            note "Engram not enabled — using the markdown persistence fallback"
        fi
        return 0
    fi

    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        found=$((found + 1))
        case "$rel" in
            /*) target="$rel" ;;
            *)  target="$receipt_dir/$rel" ;;
        esac
        if [ -f "$target" ] && grep -q 'engram' "$target" 2>/dev/null; then
            pass "Engram MCP registered: $rel"
        else
            soft "Engram MCP recorded but missing/empty: $rel (re-run setup --with-engram)"
        fi
    done <<EOF
$entries
EOF
}

check_tooling() {
    local scope="$1"
    header "Environment tooling"

    # gh (kanban prerequisite)
    if command -v gh >/dev/null 2>&1; then
        if gh auth status >/dev/null 2>&1; then
            if gh auth status 2>&1 | grep -qiE 'project'; then
                pass "gh: installed, authenticated, project scope present"
            else
                soft "gh: installed + authenticated, but 'project' scope not detected (kanban needs read:project,project)"
            fi
        else
            soft "gh: installed but not authenticated (kanban disabled)"
        fi
    else
        note "gh not installed (kanban module unavailable)"
    fi

    # pi + package stack (best-effort)
    if command -v pi >/dev/null 2>&1; then
        pass "pi: installed"
        if pi list >/dev/null 2>&1; then
            local plist; plist="$(pi list 2>/dev/null || true)"
            local pkg
            for pkg in gentle-engram pi-mcp-adapter pi-subagents-j0k3r rpiv-ask-user-question pi-web-access rpiv-todo pi-btw; do
                if printf '%s' "$plist" | grep -q "$pkg"; then
                    pass "  pi package: $pkg"
                else
                    note "  pi package not detected: $pkg"
                fi
            done
        else
            note "  pi list unavailable — skipping package inventory"
        fi
    else
        note "pi not installed (Pi harness unavailable)"
    fi

    # engram (persistence engine)
    if command -v engram >/dev/null 2>&1; then
        if engram --version >/dev/null 2>&1; then
            pass "engram: installed and responding ($(engram --version 2>/dev/null | head -1))"
        else
            soft "engram: installed but did not respond to --version"
        fi
    else
        note "engram not installed (markdown persistence fallback in use)"
    fi
}

diagnose_target() {
    local receipt_dir="$1"
    local manifest="$receipt_dir/$INSTALL_MANIFEST_NAME"
    local scope tools tool_label
    scope="$(manifest_field "$manifest" "scope")"; [ -n "$scope" ] || scope="global"
    # A project-scope receipt can record several harnesses; report them all.
    tools="$(manifest_tools "$manifest")"
    tool_label="$(fmt_tool_list "$tools")"

    header "Diagnosing ${tool_label:-unknown} ($scope) — $receipt_dir"
    if [ ! -f "$manifest" ]; then
        bad "no install receipt at $receipt_dir"
        return 0
    fi
    pass "receipt found: $manifest"
    check_receipt_files "$receipt_dir" "$tools"
    check_version "$manifest"
    check_markers "$tools" "$scope" "$receipt_dir"
    check_hooks "$tools" "$scope" "$receipt_dir"
    check_engram_mcp "$receipt_dir"
}

# ============================================================================
# Help + main
# ============================================================================

show_help() {
    echo "Usage: doctor.sh [OPTIONS]"
    echo ""
    echo "Read-only health check of a Kurama install. Changes nothing."
    echo ""
    echo "Options:"
    echo "  --agent NAME     Diagnose one global agent target"
    echo "  --scope SCOPE    'global' (default) or 'project'"
    echo "  --path DIR       Repo root for --scope project"
    echo "  -h, --help       Show this help"
    echo ""
    echo "Exit code is non-zero if any hard check fails."
}

setup_colors

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)   AGENT="$2"; shift 2 ;;
        --scope)
            case "$2" in
                global|project) SCOPE="$2"; shift 2 ;;
                *) echo "Invalid scope: $2 (use 'global' or 'project')"; exit 1 ;;
            esac
            ;;
        --path)    TARGET_PATH="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *)  echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

echo ""
echo -e "${CYAN}${BOLD}Kurama — Doctor${NC}"

if [ "$SCOPE" = "project" ]; then
    TARGET_PATH="${TARGET_PATH:-$PWD}"
    diagnose_target "$TARGET_PATH"
elif [ -n "$AGENT" ]; then
    dir="$(global_skills_path "$AGENT")"
    [ -n "$dir" ] || { bad "unknown agent: $AGENT"; }
    [ -n "$dir" ] && diagnose_target "$dir"
else
    any=false
    for agent in $ALL_AGENTS; do
        dir="$(global_skills_path "$agent")"
        [ -n "$dir" ] || continue
        if [ -f "$dir/$INSTALL_MANIFEST_NAME" ]; then any=true; diagnose_target "$dir"; fi
    done
    if ! $any; then
        note "No global install receipts found."
        check_orphans
    fi
fi

check_tooling "$SCOPE"

header "Summary"
if [ "$FAILS" -gt 0 ]; then
    echo -e "  ${RED}${BOLD}$FAILS failure(s), $WARNS warning(s)${NC}"
    exit 1
fi
if [ "$WARNS" -gt 0 ]; then
    echo -e "  ${YELLOW}${BOLD}Healthy with $WARNS warning(s)${NC}"
else
    echo -e "  ${GREEN}${BOLD}All checks passed — healthy${NC}"
fi
exit 0
