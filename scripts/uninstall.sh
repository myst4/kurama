#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Kurama — Uninstall Script
# Removes exactly what install.sh recorded in each target's install manifest
# (.kurama-install-manifest.json). User-created skills are never touched.
# Cross-platform: macOS, Linux, Windows (Git Bash / WSL). Bash 3.2 compatible.
#
# Usage:
#   ./uninstall.sh --agent claude-code               # Remove from one global agent
#   ./uninstall.sh --path /custom/skills             # Remove from an explicit dir
#   ./uninstall.sh --scope project --path /repo       # Remove a project-scope install
#   ./uninstall.sh --all                             # Remove from every known target
#   ./uninstall.sh --agent codex --dry-run           # Show what would be removed
# ============================================================================

INSTALL_MANIFEST_NAME=".kurama-install-manifest.json"

# Orchestrator marker pair — the block setup.sh merges into a shared prompt file.
# uninstall strips exactly this block on removal, leaving user content intact.
MARKER_BEGIN="<!-- BEGIN:kurama -->"
MARKER_END="<!-- END:kurama -->"

# Agents install.sh can write skills for (project-local is opt-in via --agent).
ALL_AGENTS="claude-code opencode gemini-cli codex vscode antigravity cursor pi omp"

DRY_RUN=false
SCOPE="global"       # global | project (O1: mirrors setup.sh)
TARGET_PATH=""       # repo root for project scope, or explicit dir for --path
PI_PACKAGES=""       # "", "yes", or "no" — O3 Pi package revert offer

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
        pi)
            case "$OS" in
                windows)  echo "$USERPROFILE/.pi/agent/skills" ;;
                *)        echo "$HOME/.pi/agent/skills" ;;
            esac
            ;;
        omp)
            # PI_CODING_AGENT_DIR relocates omp's user base; honor it so uninstall
            # removes from the same place setup installed to.
            if [ -n "${PI_CODING_AGENT_DIR:-}" ]; then
                echo "$PI_CODING_AGENT_DIR/skills"
            else
                case "$OS" in
                    windows)  echo "$USERPROFILE/.omp/agent/skills" ;;
                    *)        echo "$HOME/.omp/agent/skills" ;;
                esac
            fi
            ;;
        project-local) echo "./skills" ;;
        *)  echo "" ;;
    esac
}

# ============================================================================
# Manifest parsing
# ============================================================================

# Emit each string element of a named JSON array (files, settings, pi_packages)
# from an install manifest. Uses jq when available, otherwise a portable awk
# fallback that reads the one-element-per-line arrays setup.sh/install.sh write.
manifest_json_array() {
    local manifest="$1" key="$2"
    [ -f "$manifest" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$key" '(.[$k] // [])[]' "$manifest" 2>/dev/null
        return 0
    fi
    awk -v key="$key" '
        $0 ~ "\"" key "\"[[:space:]]*:[[:space:]]*\\[" { inarr = 1; next }
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

# Back-compat wrapper: the "files" array.
manifest_files() {
    manifest_json_array "$1" "files"
}

# O3: surgically strip the Kurama PreToolUse hooks block (entries whose command
# contains "hooks/kurama/") from a settings.json, leaving every other hook and
# key untouched. Backs up + writes atomically. jq only — never sed on JSON.
remove_hooks_from_settings() {
    local settings_file="$1"
    [ -f "$settings_file" ] || return 0

    if ! command -v jq >/dev/null 2>&1; then
        print_warn "jq not found — cannot strip the hooks block from $settings_file"
        print_info "Manually remove PreToolUse entries pointing at hooks/kurama/"
        return 0
    fi

    if $DRY_RUN; then
        print_info "would strip kurama hooks block from: $settings_file"
        return 0
    fi

    local cleaned
    cleaned=$(jq '
        if (.hooks.PreToolUse | type) == "array" then
            .hooks.PreToolUse = (.hooks.PreToolUse | map(select(
                (((.hooks // []) | map(.command // "") | join(" "))
                    | contains("hooks/kurama/")) | not)))
        else . end
        | if (.hooks.PreToolUse | type) == "array" and (.hooks.PreToolUse | length) == 0
            then del(.hooks.PreToolUse) else . end
        | if (.hooks | type) == "object" and (.hooks | length) == 0
            then del(.hooks) else . end
    ' "$settings_file") || { print_warn "failed to clean $settings_file"; return 0; }

    local tmp
    tmp="$(mktemp "${settings_file}.XXXXXX")"
    cp -p "$settings_file" "${settings_file}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    printf '%s\n' "$cleaned" > "$tmp"
    mv "$tmp" "$settings_file"
    print_ok "stripped kurama hooks block from settings.json"
}

# O5 (uninstall): strip the Engram MCP registration Kurama wrote into a client
# config recorded in the receipt's engram_mcp[]. JSON configs (mcpServers / mcp /
# servers keyed) are edited with jq — never sed — deleting only the "engram" entry
# and any parent object it emptied; the Codex config.toml block is removed with the
# SAME awk method setup used to write it. Backup + atomic; every other server and
# top-level key is preserved. Without jq a JSON config prints guided manual steps.
remove_engram_from_config() {
    local file="$1"
    [ -f "$file" ] || return 0

    if $DRY_RUN; then
        print_info "would strip the Engram MCP registration from: $file"
        return 0
    fi

    case "$file" in
        *.toml)
            # Codex TOML: drop the [mcp_servers.engram] block up to the next section
            # header or EOF (mirror of setup.sh register_engram_codex's strip).
            local stripped tmp
            stripped="$(awk '
                /^\[mcp_servers\.engram\]/ { skip=1; next }
                skip && /^\[/ { skip=0 }
                !skip { print }
            ' "$file")"
            tmp="$(mktemp "${file}.XXXXXX")" || { print_warn "mktemp failed for $file"; return 0; }
            cp -p "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
            printf '%s\n' "$stripped" > "$tmp"
            mv "$tmp" "$file"
            print_ok "stripped Engram MCP block from $file (codex TOML)"
            ;;
        *)
            if ! command -v jq >/dev/null 2>&1; then
                print_warn "jq not found — cannot strip the Engram MCP server from $file"
                print_info "Manually remove the \"engram\" entry under mcpServers / mcp / servers"
                return 0
            fi
            local cleaned tmp
            cleaned=$(jq '
                (if (.mcpServers | type) == "object" then .mcpServers |= del(.engram) else . end)
                | (if (.mcp | type) == "object" then .mcp |= del(.engram) else . end)
                | (if (.servers | type) == "object" then .servers |= del(.engram) else . end)
                | (if (.mcpServers | type) == "object" and (.mcpServers | length) == 0 then del(.mcpServers) else . end)
                | (if (.mcp | type) == "object" and (.mcp | length) == 0 then del(.mcp) else . end)
                | (if (.servers | type) == "object" and (.servers | length) == 0 then del(.servers) else . end)
            ' "$file") || { print_warn "failed to clean $file"; return 0; }
            tmp="$(mktemp "${file}.XXXXXX")" || { print_warn "mktemp failed for $file"; return 0; }
            cp -p "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
            printf '%s\n' "$cleaned" > "$tmp"
            mv "$tmp" "$file"
            print_ok "stripped Engram MCP registration from $file"
            ;;
    esac
}

# Strip the Kurama TUI logo plugin from an OpenCode tui.json recorded in the
# receipt's tui_plugins[]. Mirrors gentle-ai's removeTUIPlugin: drop every
# plugin[] entry pointing at tui-plugins/kurama-logo.tsx and leave the rest of
# the file — $schema, other plugins, unrelated keys — exactly as it was. Matching
# on the suffix (not the absolute path) keeps removal working when the receipt
# was written under a different HOME. jq only (never sed on JSON); backup +
# atomic. The plugin .tsx itself is recorded in files[] and removed with them.
remove_tui_plugin_from_config() {
    local file="$1"
    [ -f "$file" ] || return 0

    if ! command -v jq >/dev/null 2>&1; then
        print_warn "jq not found — cannot strip the Kurama logo entry from $file"
        print_info "Manually remove the tui-plugins/kurama-logo.tsx entry from plugin[]"
        return 0
    fi
    if ! jq -e . "$file" >/dev/null 2>&1; then
        print_warn "$file is not valid JSON — leaving it untouched"
        return 0
    fi

    # Nothing of ours registered → leave the file (and its mtime) alone.
    jq -e '[(.plugin // [])[]
        | select(if type == "string"
                 then endswith("tui-plugins/kurama-logo.tsx") else false end)]
        | length > 0' "$file" >/dev/null 2>&1 || return 0

    if $DRY_RUN; then
        print_info "would strip the Kurama logo plugin from: $file"
        return 0
    fi

    local cleaned tmp
    cleaned=$(jq '
        .plugin = ((.plugin // []) | map(select(
            (if type == "string"
             then endswith("tui-plugins/kurama-logo.tsx") else false end) | not)))
    ' "$file") || { print_warn "failed to clean $file"; return 0; }
    tmp="$(mktemp "${file}.XXXXXX")" || { print_warn "mktemp failed for $file"; return 0; }
    cp -p "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    printf '%s\n' "$cleaned" > "$tmp"
    mv "$tmp" "$file"
    print_ok "stripped the Kurama logo plugin from $file"
}

# Strip Kurama's orchestrator block (BEGIN:kurama … END:kurama) from a prompt file
# recorded in the receipt's prompts[]. Only strips when BOTH markers are present —
# an unbalanced pair is left untouched to avoid deleting user content. Everything
# outside the block is preserved; backup + atomic.
strip_markers_from_prompt() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -qF "$MARKER_BEGIN" "$file" || return 0
    if ! grep -qF "$MARKER_END" "$file"; then
        print_warn "unbalanced kurama markers in $file — leaving it untouched"
        return 0
    fi

    if $DRY_RUN; then
        print_info "would strip the kurama orchestrator block from: $file"
        return 0
    fi

    local stripped tmp
    stripped="$(awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
        $0 == b { skip=1; next }
        $0 == e { skip=0; next }
        !skip   { print }
    ' "$file")"
    tmp="$(mktemp "${file}.XXXXXX")" || { print_warn "mktemp failed for $file"; return 0; }
    cp -p "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    printf '%s\n' "$stripped" > "$tmp"
    mv "$tmp" "$file"
    print_ok "stripped kurama orchestrator block from $file"
}

# O3: offer to revert the Pi packages Kurama installed (recorded in the receipt).
# Honors --with/--without-pi-packages; otherwise asks interactively (default no,
# so a shared package set is never removed by surprise). Never touches gentle-pi
# and never removes anything not recorded.
offer_pi_uninstall() {
    local manifest="$1"
    local pkgs
    pkgs="$(manifest_json_array "$manifest" "pi_packages")"
    [ -n "$pkgs" ] || return 0

    echo -e "\n${BOLD}This install recorded these Pi packages:${NC}"
    printf '%s\n' "$pkgs" | while IFS= read -r p; do [ -n "$p" ] && echo "  - $p"; done

    case "$PI_PACKAGES" in
        yes) ;;
        no)  print_info "Leaving Pi packages installed (--without-pi-packages)"; return 0 ;;
        *)
            print_info "Uninstall these Pi packages too? (they may be shared with other tools)"
            read -rp "  Revert Pi packages? [y/N]: " ans
            [[ "${ans:-N}" =~ ^[Yy] ]] || { print_info "Leaving Pi packages installed"; return 0; }
            ;;
    esac

    if ! command -v pi >/dev/null 2>&1; then
        print_warn "pi not found in PATH — cannot revert packages (skipping)"
        return 0
    fi

    local p
    printf '%s\n' "$pkgs" | while IFS= read -r p; do
        [ -n "$p" ] || continue
        if $DRY_RUN; then
            print_info "would run: pi uninstall $p"
        else
            if pi uninstall "$p" >/dev/null 2>&1; then
                print_ok "pi uninstall $p"
            else
                print_warn "pi uninstall $p failed (continuing)"
            fi
        fi
    done
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

    # O3: strip the Kurama hooks block from every settings.json the receipt
    # recorded, then offer to revert any recorded Pi packages. Both read the
    # manifest, so they must run BEFORE it is deleted.
    local sfile settings
    settings="$(manifest_json_array "$manifest" "settings")"
    while IFS= read -r sfile; do
        [ -n "$sfile" ] || continue
        remove_hooks_from_settings "$dir/$sfile"
    done <<EOF
$settings
EOF

    # Strip the Engram MCP registration from every config the receipt recorded
    # (engram_mcp[]). Entries are relative to $dir, except the global Claude
    # ~/.claude.json which is recorded absolute — honor both.
    local efile engram_files
    engram_files="$(manifest_json_array "$manifest" "engram_mcp")"
    while IFS= read -r efile; do
        [ -n "$efile" ] || continue
        case "$efile" in
            /*) remove_engram_from_config "$efile" ;;
            *)  remove_engram_from_config "$dir/$efile" ;;
        esac
    done <<EOF
$engram_files
EOF

    # Strip the kurama orchestrator marker block from each recorded prompt file
    # (prompts[]), preserving the user's surrounding content. Same relative/absolute
    # handling as engram_mcp above.
    local pfile prompts
    prompts="$(manifest_json_array "$manifest" "prompts")"
    while IFS= read -r pfile; do
        [ -n "$pfile" ] || continue
        case "$pfile" in
            /*) strip_markers_from_prompt "$pfile" ;;
            *)  strip_markers_from_prompt "$dir/$pfile" ;;
        esac
    done <<EOF
$prompts
EOF

    # Strip the Kurama logo entry from every opencode tui.json the receipt
    # recorded (tui_plugins[]). Same relative/absolute handling as above.
    local tfile tui_files
    tui_files="$(manifest_json_array "$manifest" "tui_plugins")"
    while IFS= read -r tfile; do
        [ -n "$tfile" ] || continue
        case "$tfile" in
            /*) remove_tui_plugin_from_config "$tfile" ;;
            *)  remove_tui_plugin_from_config "$dir/$tfile" ;;
        esac
    done <<EOF
$tui_files
EOF

    # Remove the legacy background-agents.ts plugin. Older Kurama versions
    # installed it unconditionally; it is no longer shipped (it hangs the
    # OpenCode TUI), so uninstall must clear it even though no receipt lists it.
    local legacy_plugin="$HOME/.config/opencode/plugins/background-agents.ts"
    if [ -f "$legacy_plugin" ]; then
        rm -f "$legacy_plugin"
        print_ok "Removed legacy background-agents plugin: $legacy_plugin"
    fi

    offer_pi_uninstall "$manifest"

    if $DRY_RUN; then
        print_info "would remove: $INSTALL_MANIFEST_NAME"
        print_info "would prune emptied skill directories under $dir"
        echo -e "  ${BOLD}$removed file(s) would be removed${NC}"
        return 0
    fi

    rm -f "$manifest"

    # Prune every directory we emptied. All recorded files were already removed
    # above, so for each one we walk from its parent directory upward toward $dir
    # calling rmdir — which only succeeds on an empty directory, so user-created
    # skills, sibling files, and shared config are always preserved. This handles
    # both skill-relative global paths (sdd-apply/SKILL.md, ../agents/x.md) and the
    # deeper project-scope paths (.claude/skills/sdd-apply/SKILL.md,
    # .claude/hooks/kurama/x.sh) that the single-component strip could not reach.
    printf '%s\n' "$files" | awk 'NF' | while IFS= read -r rel; do
        pdir="$(dirname "$dir/$rel")"
        while [ "$pdir" != "$dir" ] && [ "$pdir" != "/" ] && [ "$pdir" != "." ]; do
            rmdir "$pdir" 2>/dev/null || break
            pdir="$(dirname "$pdir")"
        done
    done
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
    echo "  --agent NAME           Uninstall from a specific agent target"
    echo "  --scope SCOPE          'global' (default) or 'project' (mirrors setup.sh)"
    echo "  --path DIR             Explicit dir (global) or repo root (--scope project)"
    echo "  --all                  Uninstall from every known global agent target"
    echo "  --with-pi-packages     Also revert recorded Pi packages (pi uninstall)"
    echo "  --without-pi-packages  Never revert Pi packages (leave them installed)"
    echo "  --dry-run              Show what would be removed without deleting"
    echo "  -h, --help             Show this help"
    echo ""
    echo "Agents: claude-code, opencode, gemini-cli, codex, vscode, antigravity, cursor, pi, omp, project-local"
    echo ""
    echo "Only files recorded in each target's $INSTALL_MANIFEST_NAME are removed."
    echo "The recorded settings.json hooks block, the Engram MCP registration, and the"
    echo "orchestrator BEGIN:kurama block are stripped surgically; other keys/content stay."
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
        --scope)
            case "$2" in
                global|project) SCOPE="$2"; shift 2 ;;
                *) echo "Invalid scope: $2 (use 'global' or 'project')"; exit 1 ;;
            esac
            ;;
        --with-pi-packages)    PI_PACKAGES="yes"; shift ;;
        --without-pi-packages) PI_PACKAGES="no"; shift ;;
        --all)     ALL=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *)  echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if $DRY_RUN; then
    echo -e "${YELLOW}${BOLD}Dry run — no files will be deleted.${NC}"
fi

# O1: project scope removes the single repo-root receipt setup.sh wrote there.
if [[ "$SCOPE" == "project" ]]; then
    TARGET_PATH="${CUSTOM_PATH:-$PWD}"
    remove_target "$TARGET_PATH" "project (${AGENT:-repo})"
elif [[ -n "$CUSTOM_PATH" ]]; then
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
