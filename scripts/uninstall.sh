#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Agent Teams Lite — Uninstall Script
# Removes exactly what install.sh recorded in each target's install manifest
# (.atl-install-manifest.json). User-created skills are never touched.
# Cross-platform: macOS, Linux, Windows (Git Bash / WSL). Bash 3.2 compatible.
#
# Usage:
#   ./uninstall.sh --agent claude-code      # Remove from one agent target
#   ./uninstall.sh --path /custom/skills    # Remove from an explicit directory
#   ./uninstall.sh --all                    # Remove from every known target
#   ./uninstall.sh --agent codex --dry-run  # Show what would be removed
# ============================================================================

INSTALL_MANIFEST_NAME=".atl-install-manifest.json"

# Agents install.sh can write skills for (project-local is opt-in via --agent).
ALL_AGENTS="claude-code opencode gemini-cli codex vscode antigravity cursor"

DRY_RUN=false

# ============================================================================
# OS detection (mirrors install.sh so target paths resolve identically)
# ============================================================================

detect_os() {
    case "$(uname -s)" in
        Darwin)  OS="macos" ;;
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                OS="wsl"
            else
                OS="linux"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)  OS="windows" ;;
        *)  OS="unknown" ;;
    esac
}

# ============================================================================
# Colors
# ============================================================================

setup_colors() {
    if [[ "$OS" == "windows" ]] && [[ -z "${WT_SESSION:-}" ]] && [[ -z "${TERM_PROGRAM:-}" ]]; then
        RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
    else
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        CYAN='\033[0;36m'
        BOLD='\033[1m'
        NC='\033[0m'
    fi
}

print_ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
print_warn() { echo -e "  ${YELLOW}!${NC} $1"; }
print_error(){ echo -e "  ${RED}✗${NC} $1"; }
print_info() { echo -e "  ${CYAN}→${NC} $1"; }

# ============================================================================
# Path resolution (kept in sync with install.sh get_tool_path)
# ============================================================================

get_tool_path() {
    local tool="$1"
    case "$tool" in
        claude-code)
            case "$OS" in
                windows)  echo "$USERPROFILE/.claude/skills" ;;
                *)        echo "$HOME/.claude/skills" ;;
            esac
            ;;
        opencode)
            case "$OS" in
                windows)  echo "$USERPROFILE/.config/opencode/skills" ;;
                *)        echo "$HOME/.config/opencode/skills" ;;
            esac
            ;;
        gemini-cli)
            case "$OS" in
                windows)  echo "$USERPROFILE/.gemini/skills" ;;
                *)        echo "$HOME/.gemini/skills" ;;
            esac
            ;;
        codex)
            case "$OS" in
                windows)  echo "$USERPROFILE/.codex/skills" ;;
                *)        echo "$HOME/.codex/skills" ;;
            esac
            ;;
        vscode)
            case "$OS" in
                windows)  echo "$USERPROFILE/.copilot/skills" ;;
                *)        echo "$HOME/.copilot/skills" ;;
            esac
            ;;
        antigravity)
            case "$OS" in
                windows)  echo "$USERPROFILE/.gemini/antigravity/skills" ;;
                *)        echo "$HOME/.gemini/antigravity/skills" ;;
            esac
            ;;
        cursor)
            case "$OS" in
                windows)  echo "$USERPROFILE/.cursor/skills" ;;
                *)        echo "$HOME/.cursor/skills" ;;
            esac
            ;;
        project-local) echo "./skills" ;;
        *)  echo "" ;;
    esac
}

# ============================================================================
# Manifest parsing
# ============================================================================

# Emit each target-relative path listed in an install manifest's "files" array.
# Uses jq when available, otherwise a portable awk fallback that reads the
# one-path-per-line array written by install.sh.
manifest_files() {
    local manifest="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r '.files[]' "$manifest"
        return 0
    fi
    awk '
        /"files"[[:space:]]*:[[:space:]]*\[/ { inarr = 1; next }
        inarr && /\]/ { inarr = 0 }
        inarr {
            line = $0
            gsub(/^[[:space:]]+/, "", line)
            gsub(/[[:space:]]+$/, "", line)
            gsub(/,$/, "", line)
            gsub(/"/, "", line)
            if (line != "") print line
        }
    ' "$manifest"
}

# ============================================================================
# Removal
# ============================================================================

remove_target() {
    local dir="$1"
    local label="$2"
    local manifest="$dir/$INSTALL_MANIFEST_NAME"

    if [ ! -f "$manifest" ]; then
        print_warn "$label: no install manifest at $dir (nothing recorded — skipping)"
        return 0
    fi

    echo -e "\n${BOLD}Uninstalling from $label${NC} ($dir)"

    local files
    files="$(manifest_files "$manifest")"

    local removed=0 rel target
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        target="$dir/$rel"
        if [ -e "$target" ]; then
            if $DRY_RUN; then
                print_info "would remove: $rel"
            else
                rm -f "$target"
                print_ok "removed: $rel"
            fi
            removed=$((removed + 1))
        fi
    done <<EOF
$files
EOF

    if $DRY_RUN; then
        print_info "would remove: $INSTALL_MANIFEST_NAME"
        print_info "would prune emptied skill directories under $dir"
        echo -e "  ${BOLD}$removed file(s) would be removed${NC}"
        return 0
    fi

    rm -f "$manifest"

    # Prune the directories we emptied (skill dirs + _shared), then the root —
    # rmdir only succeeds on empty dirs, so user-created skills are preserved.
    local subdirs sd
    subdirs="$(printf '%s\n' "$files" | awk 'NF { n = $0; sub(/\/.*/, "", n); print n }' | sort -u)"
    while IFS= read -r sd; do
        [ -n "$sd" ] || continue
        rmdir "$dir/$sd" 2>/dev/null || true
    done <<EOF
$subdirs
EOF
    rmdir "$dir" 2>/dev/null || true

    echo -e "  ${GREEN}${BOLD}$removed file(s) removed${NC}"
}

# ============================================================================
# Help
# ============================================================================

show_help() {
    echo "Usage: uninstall.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --agent NAME   Uninstall from a specific agent target"
    echo "  --path DIR     Uninstall from an explicit skills directory"
    echo "  --all          Uninstall from every known global agent target"
    echo "  --dry-run      Show what would be removed without deleting"
    echo "  -h, --help     Show this help"
    echo ""
    echo "Agents: claude-code, opencode, gemini-cli, codex, vscode, antigravity, cursor, project-local"
    echo ""
    echo "Only files recorded in each target's $INSTALL_MANIFEST_NAME are removed."
}

# ============================================================================
# Main
# ============================================================================

detect_os
setup_colors

AGENT=""
CUSTOM_PATH=""
ALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)   AGENT="$2"; shift 2 ;;
        --path)    CUSTOM_PATH="$2"; shift 2 ;;
        --all)     ALL=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *)  echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if $DRY_RUN; then
    echo -e "${YELLOW}${BOLD}Dry run — no files will be deleted.${NC}"
fi

if [[ -n "$CUSTOM_PATH" ]]; then
    remove_target "$CUSTOM_PATH" "custom path"
elif [[ -n "$AGENT" ]]; then
    target_dir="$(get_tool_path "$AGENT")"
    if [[ -z "$target_dir" ]]; then
        print_error "Unknown agent: $AGENT"
        show_help
        exit 1
    fi
    remove_target "$target_dir" "$AGENT"
elif $ALL; then
    for agent in $ALL_AGENTS; do
        remove_target "$(get_tool_path "$agent")" "$agent"
    done
else
    show_help
    exit 1
fi

echo -e "\n${GREEN}${BOLD}Done.${NC}"
