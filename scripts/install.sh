#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Agent Teams Lite — Install Script
# Copies skills to your AI coding assistant's skill directory
# Cross-platform: macOS, Linux, Windows (Git Bash / WSL)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SKILLS_SRC="$REPO_DIR/skills"
MANIFEST_FILE="$SKILLS_SRC/manifest.json"
VERSION_FILE="$REPO_DIR/VERSION"

# Name of the per-target install manifest (records version + installed files so
# upgrades can detect leftovers and uninstall.sh can remove exactly what we wrote).
INSTALL_MANIFEST_NAME=".atl-install-manifest.json"

# Skill-group selection. Groups come from skills/manifest.json; sdd-core is
# mandatory, quality + review + optional are on by default and opt-out via
# --without, and tdd is opt-in only (off by default, enabled with --with tdd).
# The surrounding single spaces let membership be tested with a case glob.
ACTIVE_GROUPS=" sdd-core quality review optional "
REQUIRED_GROUPS=" sdd-core "

# Every group name the flags accept (default-on ones plus opt-in ones). Kept in
# sync with skills/manifest.json "groups"; drives validation + the rebuild loop.
KNOWN_GROUPS="sdd-core quality review optional tdd"

# Populated from the manifest once flags are parsed (see compute_active_skills).
ACTIVE_SKILLS=()

# ============================================================================
# OS Detection
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

os_label() {
    case "$OS" in
        macos)   echo "macOS" ;;
        linux)   echo "Linux" ;;
        wsl)     echo "WSL" ;;
        windows) echo "Windows (Git Bash)" ;;
        *)       echo "Unknown" ;;
    esac
}

# ============================================================================
# Color support
# ============================================================================

setup_colors() {
    if [[ "$OS" == "windows" ]] && [[ -z "${WT_SESSION:-}" ]] && [[ -z "${TERM_PROGRAM:-}" ]]; then
        # Plain CMD without Windows Terminal — no ANSI support
        RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
    else
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        CYAN='\033[0;36m'
        BOLD='\033[1m'
        NC='\033[0m'
    fi
}

# ============================================================================
# Path Resolution
# ============================================================================

get_tool_path() {
    local tool="$1"
    case "$tool" in
        claude-code)
            case "$OS" in
                windows)  echo "$USERPROFILE/.claude/skills" ;;
                wsl)      echo "$HOME/.claude/skills" ;;
                *)        echo "$HOME/.claude/skills" ;;
            esac
            ;;
        opencode)
            case "$OS" in
                windows)  echo "$USERPROFILE/.config/opencode/skills" ;;
                macos)    echo "$HOME/.config/opencode/skills" ;;
                *)        echo "$HOME/.config/opencode/skills" ;;
            esac
            ;;
        opencode-commands)
            case "$OS" in
                windows)  echo "$USERPROFILE/.config/opencode/commands" ;;
                macos)    echo "$HOME/.config/opencode/commands" ;;
                *)        echo "$HOME/.config/opencode/commands" ;;
            esac
            ;;
        gemini-cli)
            case "$OS" in
                windows)  echo "$USERPROFILE/.gemini/skills" ;;
                wsl)      echo "$HOME/.gemini/skills" ;;
                *)        echo "$HOME/.gemini/skills" ;;
            esac
            ;;
        codex)
            case "$OS" in
                windows)  echo "$USERPROFILE/.codex/skills" ;;
                wsl)      echo "$HOME/.codex/skills" ;;
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
                wsl)      echo "$HOME/.cursor/skills" ;;
                *)        echo "$HOME/.cursor/skills" ;;
            esac
            ;;
        project-local) echo "./skills" ;;
    esac
}

# ============================================================================
# Helpers
# ============================================================================

make_writable() {
    if [[ "$OS" != "windows" ]]; then
        chmod u+w "$1" 2>/dev/null || true
    fi
}

print_header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║      Agent Teams Lite — Installer        ║${NC}"
    echo -e "${CYAN}${BOLD}║   Spec-Driven Development for AI Agents  ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Detected:${NC} $(os_label)"
    echo ""
}

print_skill() {
    echo -e "  ${GREEN}✓${NC} $1"
}

print_warn() {
    echo -e "  ${YELLOW}!${NC} $1"
}

print_error() {
    echo -e "  ${RED}✗${NC} $1"
}

print_next_step() {
    local config_file="$1"
    local example_file="$2"
    echo -e "\n${YELLOW}Next step:${NC} Add the orchestrator to your ${BOLD}$config_file${NC}"
    echo -e "  See: ${CYAN}$example_file${NC}"
}

print_engram_note() {
    echo -e "\n${YELLOW}Recommended persistence backend:${NC} ${BOLD}Engram${NC}"
    echo -e "  ${CYAN}https://github.com/gentleman-programming/engram${NC}"
    echo -e "  If Engram is available, it will be used automatically (recommended)"
    echo -e "  If not, falls back to ${BOLD}none${NC} — enable ${BOLD}engram${NC} or ${BOLD}openspec${NC} for better results"
}

show_help() {
    echo "Usage: install.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --agent NAME     Install for a specific agent (non-interactive)"
    echo "  --path DIR       Custom install path (use with --agent custom)"
    echo "  --with GROUP     Include an optional skill group (quality, review, optional, tdd)"
    echo "  --without GROUP  Exclude an optional skill group (quality, review, optional)"
    echo "  --version        Print the Agent Teams Lite version and exit"
    echo "  -h, --help       Show this help"
    echo ""
    echo "Agents: claude-code, opencode, gemini-cli, codex, vscode, antigravity, cursor, project-local, all-global"
    echo ""
    echo "Skill groups:"
    echo "  sdd-core   Core SDD pipeline + authoring utilities (always installed)"
    echo "  quality    Adversarial review skills, e.g. judgment-day (on by default; --without quality to skip)"
    echo "  review     4R review lenses + refuter, e.g. review-risk (on by default; --without review to skip)"
    echo "  optional   Language/testing skills, e.g. go-testing (on by default; --without optional to skip)"
    echo "  tdd        Optional TDD module (RED-GREEN-REFACTOR), skills/tdd (opt-in; --with tdd to enable)"
}

# ============================================================================
# Version + manifest helpers
# ============================================================================

read_version() {
    local v="unknown"
    if [ -f "$VERSION_FILE" ]; then
        IFS= read -r v < "$VERSION_FILE" || true
        [ -n "$v" ] || v="unknown"
    fi
    printf '%s' "$v"
}

print_version() {
    printf 'agent-teams-lite %s\n' "$(read_version)"
}

# Emit "<name> <group>" for every skill declared in skills/manifest.json.
# Uses jq when available, otherwise a portable awk fallback (bash 3.2 / BSD awk)
# that parses only the "skills" array and reads name+group from the same line.
manifest_skill_lines() {
    [ -f "$MANIFEST_FILE" ] || return 1
    if command -v jq >/dev/null 2>&1; then
        jq -r '.skills[] | "\(.name) \(.group)"' "$MANIFEST_FILE"
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
    ' "$MANIFEST_FILE"
}

group_is_active() {
    case "$ACTIVE_GROUPS" in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

validate_group_name() {
    case "$1" in
        sdd-core|quality|review|optional|tdd) return 0 ;;
        *)
            print_error "Unknown skill group: $1 (valid: quality, review, optional, tdd)"
            exit 1
            ;;
    esac
}

enable_group() {
    local g="$1"
    case "$ACTIVE_GROUPS" in
        *" $g "*) return 0 ;;
    esac
    ACTIVE_GROUPS="$ACTIVE_GROUPS$g "
}

disable_group() {
    local g="$1"
    case "$REQUIRED_GROUPS" in
        *" $g "*)
            print_error "Group '$g' is required and cannot be excluded"
            exit 1
            ;;
    esac
    local rebuilt=" " tok
    for tok in $KNOWN_GROUPS; do
        case "$ACTIVE_GROUPS" in
            *" $tok "*)
                [ "$tok" = "$g" ] && continue
                rebuilt="$rebuilt$tok "
                ;;
        esac
    done
    ACTIVE_GROUPS="$rebuilt"
}

# Resolve the active skill set from the manifest + the current group selection.
compute_active_skills() {
    ACTIVE_SKILLS=()
    local name group
    while IFS=' ' read -r name group; do
        [ -n "$name" ] || continue
        if group_is_active "$group"; then
            ACTIVE_SKILLS+=("$name")
        fi
    done < <(manifest_skill_lines)

    if [ "${#ACTIVE_SKILLS[@]}" -eq 0 ]; then
        print_error "No skills selected — could not read $MANIFEST_FILE"
        exit 1
    fi
}

# Record what we installed under a target so upgrades and uninstall.sh can act on
# an exact file list. "$files" is a newline-delimited list of target-relative
# paths; blank lines are ignored.
write_install_manifest() {
    local target_dir="$1"
    local tool_name="$2"
    local files="$3"
    local manifest_path="$target_dir/$INSTALL_MANIFEST_NAME"
    local version
    version="$(read_version)"

    make_writable "$manifest_path"
    {
        printf '{\n'
        printf '  "name": "agent-teams-lite",\n'
        printf '  "version": "%s",\n' "$version"
        printf '  "tool": "%s",\n' "$tool_name"
        printf '  "files": [\n'
        printf '%s\n' "$files" | awk 'NF { list[n++] = $0 }
            END {
                for (i = 0; i < n; i++) {
                    sep = (i < n - 1) ? "," : ""
                    printf "    \"%s\"%s\n", list[i], sep
                }
            }'
        printf '  ]\n'
        printf '}\n'
    } > "$manifest_path"
}

# ============================================================================
# Install functions
# ============================================================================

validate_source() {
    local missing=0
    for skill_dir in "$SKILLS_SRC"/sdd-*/; do
        if [ ! -f "$skill_dir/SKILL.md" ]; then
            print_error "Missing: $(basename "$skill_dir")/SKILL.md"
            missing=$((missing + 1))
        fi
    done
    if [ ! -d "$SKILLS_SRC/_shared" ]; then
        print_error "Missing: _shared/ directory"
        missing=$((missing + 1))
    fi
    if [ ! -f "$MANIFEST_FILE" ]; then
        print_error "Missing: skills/manifest.json (the skill list source of truth)"
        missing=$((missing + 1))
    fi
    if [ "$missing" -gt 0 ]; then
        echo -e "\n${RED}${BOLD}Source validation failed.${NC} Is this a complete clone of the repository?"
        echo -e "  Try: ${CYAN}git clone https://github.com/Gentleman-Programming/agent-teams-lite.git${NC}\n"
        exit 1
    fi
}

install_skills() {
    local target_dir="$1"
    local tool_name="$2"

    echo -e "\n${BLUE}Installing skills for ${BOLD}$tool_name${NC}${BLUE}...${NC}"

    mkdir -p "$target_dir"

    # Newline-delimited list of target-relative paths we write (for the manifest).
    local installed_files=""

    # Copy shared convention files (_shared/)
    local shared_src="$SKILLS_SRC/_shared"
    local shared_target="$target_dir/_shared"

    if [ -d "$shared_src" ]; then
        local shared_count=0
        mkdir -p "$shared_target" 2>/dev/null || {
            make_writable "$shared_target"
        }
        for shared_file in "$shared_src"/*.md; do
            if [ -f "$shared_file" ]; then
                cp "$shared_file" "$shared_target/"
                installed_files="$installed_files
_shared/$(basename "$shared_file")"
                shared_count=$((shared_count + 1))
            fi
        done
        if [ "$shared_count" -gt 0 ]; then
            print_skill "_shared ($shared_count convention files)"
        else
            print_warn "_shared directory found but no .md files to copy"
        fi
    fi

    local count=0
    local skill_name skill_dir
    # Install the active skill set resolved from skills/manifest.json.
    for skill_name in "${ACTIVE_SKILLS[@]}"; do
        skill_dir="$SKILLS_SRC/$skill_name"
        [ -d "$skill_dir" ] || continue

        # Verify source SKILL.md exists before creating target directory
        if [ ! -f "$skill_dir/SKILL.md" ]; then
            print_warn "Skipping $skill_name (SKILL.md not found in source)"
            continue
        fi

        mkdir -p "$target_dir/$skill_name" 2>/dev/null || {
            make_writable "$target_dir/$skill_name"
        }
        if [ -f "$target_dir/$skill_name/SKILL.md" ]; then
            make_writable "$target_dir/$skill_name/SKILL.md"
        fi
        cp "$skill_dir/SKILL.md" "$target_dir/$skill_name/SKILL.md"
        installed_files="$installed_files
$skill_name/SKILL.md"
        print_skill "$skill_name"
        count=$((count + 1))
    done

    write_install_manifest "$target_dir" "$tool_name" "$installed_files"

    echo -e "\n  ${GREEN}${BOLD}$count skills installed${NC} → $target_dir"
}

install_opencode_commands() {
    local commands_src="$REPO_DIR/examples/opencode/commands"
    local commands_target
    commands_target="$(get_tool_path opencode-commands)"

    echo -e "\n${BLUE}Installing OpenCode commands...${NC}"

    mkdir -p "$commands_target"

    local count=0
    for cmd_file in "$commands_src"/sdd-*.md; do
        local cmd_name
        cmd_name=$(basename "$cmd_file")
        cp "$cmd_file" "$commands_target/$cmd_name"
        print_skill "${cmd_name%.md}"
        count=$((count + 1))
    done

    echo -e "\n  ${GREEN}${BOLD}$count commands installed${NC} → $commands_target"
}

# ============================================================================
# Agent install dispatcher
# ============================================================================

# The "~/..." strings below are human-readable display hints echoed to the user,
# not paths this script resolves, so tilde expansion is intentionally not wanted.
# shellcheck disable=SC2088
install_for_agent() {
    local agent="$1"

    case "$agent" in
        claude-code)
            install_skills "$(get_tool_path claude-code)" "Claude Code"
            print_next_step "~/.claude/CLAUDE.md" "examples/claude-code/CLAUDE.md"
            ;;
        opencode)
            install_skills "$(get_tool_path opencode)" "OpenCode"
            install_opencode_commands
            echo ""
            echo -e "${YELLOW}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${YELLOW}${BOLD}║  ACTION REQUIRED: Add the sdd-orchestrator agent config     ║${NC}"
            echo -e "${YELLOW}${BOLD}║                                                              ║${NC}"
            echo -e "${YELLOW}${BOLD}║  Copy an agent block from one of:                            ║${NC}"
            echo -e "${YELLOW}${BOLD}║    examples/opencode/opencode.single.json  (default)         ║${NC}"
            echo -e "${YELLOW}${BOLD}║    examples/opencode/opencode.multi.json   (per-phase)       ║${NC}"
            echo -e "${YELLOW}${BOLD}║  Into your:                                                  ║${NC}"
            echo -e "${YELLOW}${BOLD}║    ~/.config/opencode/opencode.json                          ║${NC}"
            echo -e "${YELLOW}${BOLD}║                                                              ║${NC}"
            echo -e "${YELLOW}${BOLD}║  Without this, /sdd-* commands will not find the agent.      ║${NC}"
            echo -e "${YELLOW}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
            ;;
        gemini-cli)
            install_skills "$(get_tool_path gemini-cli)" "Gemini CLI"
            print_next_step "~/.gemini/GEMINI.md" "examples/gemini-cli/GEMINI.md"
            ;;
        codex)
            install_skills "$(get_tool_path codex)" "Codex"
            print_next_step "Codex instructions file" "examples/codex/agents.md"
            ;;
        vscode)
            install_skills "$(get_tool_path vscode)" "VS Code (Copilot)"
            print_next_step ".github/copilot-instructions.md" "examples/vscode/copilot-instructions.md"
            ;;
        antigravity)
            target="$(get_tool_path antigravity)"
            install_skills "$target" "Antigravity"
            print_next_step "~/.gemini/GEMINI.md or .agent/rules/" "examples/antigravity/sdd-orchestrator.md"
            ;;
        cursor)
            install_skills "$(get_tool_path cursor)" "Cursor"
            print_next_step ".cursor/rules/sdd-orchestrator.mdc" "examples/cursor/.cursor/rules/sdd-orchestrator.mdc"
            ;;
        project-local)
            install_skills "$(get_tool_path project-local)" "Project-local"
            echo -e "\n${YELLOW}Note:${NC} Skills installed in ${BOLD}./skills/${NC} — relative to this project"
            ;;
        all-global)
            install_skills "$(get_tool_path claude-code)" "Claude Code"
            install_skills "$(get_tool_path opencode)" "OpenCode"
            install_opencode_commands
            install_skills "$(get_tool_path gemini-cli)" "Gemini CLI"
            install_skills "$(get_tool_path codex)" "Codex"
            install_skills "$(get_tool_path cursor)" "Cursor"
            echo -e "\n${YELLOW}Next steps:${NC}"
            echo -e "  1. Add orchestrator to ${BOLD}~/.claude/CLAUDE.md${NC}"
            echo -e "  2. ${YELLOW}${BOLD}[REQUIRED]${NC} Add orchestrator agent to ${BOLD}~/.config/opencode/opencode.json${NC}"
            echo -e "     ${YELLOW}See: examples/opencode/opencode.single.json (or opencode.multi.json) — without this, /sdd-* commands won't work${NC}"
            echo -e "  3. Add orchestrator to ${BOLD}~/.gemini/GEMINI.md${NC}"
            echo -e "  4. Add orchestrator to ${BOLD}Codex instructions file${NC}"
            echo -e "  5. Add SDD rules to .cursor/rules/sdd-orchestrator.mdc"
            ;;
        custom)
            if [[ -z "${CUSTOM_PATH:-}" ]]; then
                read -rp "Enter target path: " CUSTOM_PATH
            fi
            install_skills "$CUSTOM_PATH" "Custom"
            ;;
        *)
            print_error "Unknown agent: $agent"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# ============================================================================
# Interactive menu
# ============================================================================

interactive_menu() {
    echo -e "${BOLD}Select your AI coding assistant:${NC}\n"
    echo "  1) Claude Code    ($(get_tool_path claude-code))"
    echo "  2) OpenCode       ($(get_tool_path opencode))"
    echo "  3) Gemini CLI     ($(get_tool_path gemini-cli))"
    echo "  4) Codex          ($(get_tool_path codex))"
    echo "  5) VS Code        ($(get_tool_path vscode))"
    echo "  6) Antigravity    (~/.gemini/antigravity/skills/)"
    echo "  7) Cursor         ($(get_tool_path cursor))"
    echo "  8) Project-local  ($(get_tool_path project-local))"
    echo "  9) All global     (Claude Code + OpenCode + Gemini CLI + Codex + Cursor)"
    echo "  10) Custom path"
    echo ""
    read -rp "Choice [1-10]: " choice

    case $choice in
        1)  install_for_agent "claude-code" ;;
        2)  install_for_agent "opencode" ;;
        3)  install_for_agent "gemini-cli" ;;
        4)  install_for_agent "codex" ;;
        5)  install_for_agent "vscode" ;;
        6)  install_for_agent "antigravity" ;;
        7)  install_for_agent "cursor" ;;
        8)  install_for_agent "project-local" ;;
        9)  install_for_agent "all-global" ;;
        10) install_for_agent "custom" ;;
        *)
            print_error "Invalid choice"
            exit 1
            ;;
    esac
}

# ============================================================================
# Main
# ============================================================================

# Detect OS first — needed for colors and paths
detect_os

# Setup colors based on OS + terminal capabilities
setup_colors

# Parse arguments
AGENT=""
CUSTOM_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)   AGENT="$2"; shift 2 ;;
        --path)    CUSTOM_PATH="$2"; shift 2 ;;
        --with)    validate_group_name "$2"; enable_group "$2"; shift 2 ;;
        --without) validate_group_name "$2"; disable_group "$2"; shift 2 ;;
        --version) print_version; exit 0 ;;
        -h|--help) show_help; exit 0 ;;
        *)  echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

print_header
validate_source
compute_active_skills

if [[ -n "$AGENT" ]]; then
    # Non-interactive mode
    install_for_agent "$AGENT"
else
    # Interactive mode
    interactive_menu
fi

echo -e "\n${GREEN}${BOLD}Done!${NC} Start using SDD with: ${CYAN}/sdd-init${NC} in your project\n"
print_engram_note
echo ""
