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

ALL_AGENTS="claude-code opencode gemini-cli codex vscode cursor pi"

SCOPE="global"
AGENT=""
TARGET_PATH=""

FAILS=0
WARNS=0

# ============================================================================
# OS + colors
# ============================================================================

detect_os() {
    case "$(uname -s)" in
        Darwin)  OS="macos" ;;
        Linux)   if grep -qi microsoft /proc/version 2>/dev/null; then OS="wsl"; else OS="linux"; fi ;;
        MINGW*|MSYS*|CYGWIN*)  OS="windows" ;;
        *)  OS="unknown" ;;
    esac
}
setup_colors() {
    if [[ "$OS" == "windows" ]] && [[ -z "${WT_SESSION:-}" ]] && [[ -z "${TERM_PROGRAM:-}" ]]; then
        RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
    else
        RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
        CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
    fi
}
pass() { echo -e "  ${GREEN}✓${NC} $1"; }
bad()  { echo -e "  ${RED}✗${NC} $1"; FAILS=$((FAILS + 1)); }
soft() { echo -e "  ${YELLOW}!${NC} $1"; WARNS=$((WARNS + 1)); }
note() { echo -e "  ${CYAN}→${NC} $1"; }
header() { echo -e "\n${CYAN}${BOLD}$1${NC}"; }

home_dir() { if [[ "$OS" == "windows" ]]; then echo "${USERPROFILE:-$HOME}"; else echo "$HOME"; fi; }

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
        gemini-cli)   echo "$home/.gemini/skills" ;;
        cursor)       echo "$home/.cursor/skills" ;;
        vscode)       echo "$home/.copilot/skills" ;;
        codex)        echo "$home/.codex/skills" ;;
        pi)           echo "$home/.pi/agent/skills" ;;
        *)            echo "" ;;
    esac
}

global_prompt_path() {
    local agent="$1" home; home="$(home_dir)"
    case "$agent" in
        claude-code)  echo "$home/.claude/CLAUDE.md" ;;
        opencode)     echo "$home/.config/opencode/AGENTS.md" ;;
        gemini-cli)   echo "$home/.gemini/GEMINI.md" ;;
        codex)        echo "$home/.codex/agents.md" ;;
        pi)           echo "$home/.pi/agent/AGENTS.md" ;;
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

manifest_json_array() {
    local manifest="$1" key="$2"
    [ -f "$manifest" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$key" '(.[$k] // [])[]' "$manifest" 2>/dev/null; return 0
    fi
    awk -v key="$key" '
        $0 ~ "\"" key "\"[[:space:]]*:[[:space:]]*\\[" { inarr = 1; next }
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
            else echo "$EXAMPLES_DIR/claude-code/agents/$base"; fi ;;
        */SKILL.md|SKILL.md)
            # .../<skill>/SKILL.md → repo skills/<skill>/SKILL.md
            local skill; skill="$(basename "$(dirname "$rel")")"
            echo "$SKILLS_SRC/$skill/SKILL.md" ;;
        *_shared/*)  echo "$SKILLS_SRC/_shared/$base" ;;
        *)  echo "" ;;
    esac
}

# ============================================================================
# Checks
# ============================================================================

check_receipt_files() {
    local receipt_dir="$1" tool="$2"
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
        src="$(resolve_source "$rel" "$tool")"
        if [ -n "$src" ] && [ -f "$src" ]; then
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

check_markers() {
    local tool="$1" scope="$2" receipt_dir="$3"
    local prompt
    if [ "$scope" = "project" ]; then
        case "$tool" in
            pi|opencode) prompt="$receipt_dir/AGENTS.md" ;;
            *)           prompt="$receipt_dir/CLAUDE.md" ;;
        esac
    else
        prompt="$(global_prompt_path "$tool")"
    fi
    [ -n "$prompt" ] || return 0
    if [ ! -f "$prompt" ]; then
        soft "orchestrator prompt not found: $prompt"
        return 0
    fi
    local b e
    b=$(grep -cF 'BEGIN:kurama' "$prompt" 2>/dev/null || echo 0)
    e=$(grep -cF 'END:kurama' "$prompt" 2>/dev/null || echo 0)
    if [ "$b" -eq "$e" ] && [ "$b" -ge 1 ]; then
        pass "orchestrator markers balanced ($b pair) in $prompt"
    elif [ "$b" -eq 0 ] && [ "$e" -eq 0 ]; then
        soft "no kurama markers in $prompt (orchestrator not merged?)"
    else
        bad "UNBALANCED kurama markers in $prompt (BEGIN=$b END=$e)"
    fi
}

check_hooks() {
    local tool="$1" scope="$2" receipt_dir="$3"
    [ "$tool" = "claude-code" ] || return 0
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
    local tool scope
    tool="$(manifest_field "$manifest" "tool")"
    scope="$(manifest_field "$manifest" "scope")"; [ -n "$scope" ] || scope="global"

    header "Diagnosing ${tool:-unknown} ($scope) — $receipt_dir"
    if [ ! -f "$manifest" ]; then
        bad "no install receipt at $receipt_dir"
        return 0
    fi
    pass "receipt found: $manifest"
    check_receipt_files "$receipt_dir" "$tool"
    check_version "$manifest"
    check_markers "$tool" "$scope" "$receipt_dir"
    check_hooks "$tool" "$scope" "$receipt_dir"
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

detect_os
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
    $any || note "No global install receipts found."
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
