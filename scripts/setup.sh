#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Agent Teams Lite — Full Setup Script
# Detects installed agents, copies skills, and configures orchestrator prompts.
# Idempotent: safe to run multiple times (uses markers to avoid duplication).
# Cross-platform: macOS, Linux, Windows (Git Bash / WSL)
#
# Usage:
#   ./setup.sh                    # Interactive: detect + let user choose
#   ./setup.sh --all              # Auto-detect + install for all found agents
#   ./setup.sh --agent claude-code # Install for a specific agent
#   ./setup.sh --non-interactive  # Used by external installers (e.g. gentle-ai)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SKILLS_SRC="$REPO_DIR/skills"
EXAMPLES_DIR="$REPO_DIR/examples"
MANIFEST_FILE="$SKILLS_SRC/manifest.json"
VERSION_FILE="$REPO_DIR/VERSION"

# Name of the per-target install manifest — identical to install.sh so
# scripts/uninstall.sh can remove exactly what a setup.sh install wrote.
INSTALL_MANIFEST_NAME=".atl-install-manifest.json"

# setup.sh installs the DEFAULT skill set (no --with/--without flags). These are
# the default-on groups from skills/manifest.json; the opt-in `tdd` group is only
# available via install.sh --with tdd. The surrounding spaces let membership be
# tested with a case glob.
SETUP_ACTIVE_GROUPS=" sdd-core quality optional "

MARKER_BEGIN="<!-- BEGIN:agent-teams-lite -->"
MARKER_END="<!-- END:agent-teams-lite -->"

# gentle-ai-installer markers (detect to avoid duplication)
GAI_MARKER_BEGIN="<!-- gentle-ai:sdd-orchestrator -->"
GAI_MARKER_END="<!-- /gentle-ai:sdd-orchestrator -->"

# Pinned npm dependency for the OpenCode background-agents plugin.
# Version-locked and installed with --ignore-scripts to limit supply-chain risk.
UNIQUE_NAMES_GENERATOR_VERSION="4.7.1"

# Content headings that indicate orchestrator is already present
ORCHESTRATOR_HEADINGS=(
    "## Agent Teams Orchestrator"
    "## Spec-Driven Development (SDD) Orchestrator"
    "## Spec-Driven Development (SDD)"
)

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

home_dir() {
    if [[ "$OS" == "windows" ]]; then
        echo "${USERPROFILE:-$HOME}"
    else
        echo "$HOME"
    fi
}

# ============================================================================
# Colors
# ============================================================================

setup_colors() {
    if [[ "$OS" == "windows" ]] && [[ -z "${WT_SESSION:-}" ]] && [[ -z "${TERM_PROGRAM:-}" ]]; then
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

ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}!${NC} $1"; }
fail()  { echo -e "  ${RED}✗${NC} $1"; }
info()  { echo -e "  ${BLUE}→${NC} $1"; }
header() { echo -e "\n${CYAN}${BOLD}$1${NC}"; }

# ============================================================================
# Agent Detection
# ============================================================================

DETECTED_AGENTS=()

detect_agents() {
    header "Detecting installed agents..."

    check_agent "claude-code" "claude"
    check_agent "opencode"    "opencode"
    check_agent "gemini-cli"  "gemini"
    check_agent "cursor"      "cursor"
    check_agent "vscode"      "code"
    check_agent "codex"       "codex"

    echo ""
    if [[ ${#DETECTED_AGENTS[@]} -eq 0 ]]; then
        warn "No agents detected in PATH"
        info "You can still install manually with: ./install.sh"
    else
        echo -e "  ${GREEN}${BOLD}${#DETECTED_AGENTS[@]} agent(s) detected${NC}"
    fi
}

check_agent() {
    local agent_name="$1"
    local binary="$2"

    if command -v "$binary" &>/dev/null; then
        ok "$agent_name ($binary found in PATH)"
        DETECTED_AGENTS+=("$agent_name")
    fi
}

# ============================================================================
# Path Resolution
# ============================================================================

get_skills_path() {
    local agent="$1"
    local home
    home="$(home_dir)"

    case "$agent" in
        claude-code)  echo "$home/.claude/skills" ;;
        opencode)     echo "$home/.config/opencode/skills" ;;
        gemini-cli)   echo "$home/.gemini/skills" ;;
        cursor)       echo "$home/.cursor/skills" ;;
        vscode)       echo "$home/.copilot/skills" ;;
        codex)        echo "$home/.codex/skills" ;;
    esac
}

get_prompt_path() {
    local agent="$1"
    local home
    home="$(home_dir)"

    case "$agent" in
        claude-code)  echo "$home/.claude/CLAUDE.md" ;;
        opencode)     echo "$home/.config/opencode/AGENTS.md" ;;
        gemini-cli)   echo "$home/.gemini/GEMINI.md" ;;
        cursor)       echo "$home/.cursor/rules/agent-teams-lite.mdc" ;;
        vscode)
            if [[ "$OS" == "windows" ]]; then
                echo "${APPDATA:-$home/AppData/Roaming}/Code/User/prompts/agent-teams-lite.instructions.md"
            elif [[ "$OS" == "macos" ]]; then
                echo "$home/Library/Application Support/Code/User/prompts/agent-teams-lite.instructions.md"
            else
                echo "$home/.config/Code/User/prompts/agent-teams-lite.instructions.md"
            fi
            ;;
        codex)        echo "$home/.codex/agents.md" ;;
    esac
}

get_example_file() {
    local agent="$1"
    case "$agent" in
        claude-code)  echo "$EXAMPLES_DIR/claude-code/CLAUDE.md" ;;
        opencode)     echo "" ;; # OpenCode has special handling
        gemini-cli)   echo "$EXAMPLES_DIR/gemini-cli/GEMINI.md" ;;
        cursor)       echo "$EXAMPLES_DIR/cursor/.cursor/rules/sdd-orchestrator.mdc" ;;
        vscode)       echo "$EXAMPLES_DIR/vscode/copilot-instructions.md" ;;
        codex)        echo "$EXAMPLES_DIR/codex/agents.md" ;;
    esac
}

# ============================================================================
# Version + manifest helpers (kept in sync with install.sh so both installers
# resolve the SAME default skill set and write the SAME install receipt)
# ============================================================================

read_version() {
    local v="unknown"
    if [ -f "$VERSION_FILE" ]; then
        IFS= read -r v < "$VERSION_FILE" || true
        [ -n "$v" ] || v="unknown"
    fi
    printf '%s' "$v"
}

make_writable() {
    if [[ "$OS" != "windows" ]]; then
        chmod u+w "$1" 2>/dev/null || true
    fi
}

# Emit "<name> <group>" for every skill declared in skills/manifest.json. Uses jq
# when available, otherwise a portable awk fallback (bash 3.2 / BSD awk) that parses
# only the "skills" array and reads name+group from the same line. Mirrors install.sh.
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

setup_group_is_active() {
    case "$SETUP_ACTIVE_GROUPS" in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

# Record what we installed under a target so scripts/uninstall.sh can remove an
# exact file list. Byte-for-byte the same format/fields as install.sh's writer.
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
# Install Skills
# ============================================================================

install_skills() {
    local target_dir="$1"
    local agent_name="$2"

    info "Installing skills → $target_dir"
    mkdir -p "$target_dir"

    # Newline-delimited list of target-relative paths we write (for the manifest).
    local installed_files=""

    # Copy _shared
    local shared_src="$SKILLS_SRC/_shared"
    local shared_target="$target_dir/_shared"
    if [ -d "$shared_src" ]; then
        mkdir -p "$shared_target"
        local shared_file
        for shared_file in "$shared_src"/*.md; do
            [ -f "$shared_file" ] || continue
            cp "$shared_file" "$shared_target/"
            installed_files="$installed_files
_shared/$(basename "$shared_file")"
        done
        ok "_shared conventions"
    fi

    # Copy the DEFAULT skill set resolved from skills/manifest.json (single source
    # of truth, shared with install.sh) — no hardcoded skill list. Runs in the
    # current shell (process substitution) so $count/$installed_files persist.
    local count=0
    local skill_name group skill_dir
    while IFS=' ' read -r skill_name group; do
        [ -n "$skill_name" ] || continue
        setup_group_is_active "$group" || continue
        skill_dir="$SKILLS_SRC/$skill_name"
        [ -d "$skill_dir" ] || continue
        [ -f "$skill_dir/SKILL.md" ] || continue

        mkdir -p "$target_dir/$skill_name"
        if [ -f "$target_dir/$skill_name/SKILL.md" ]; then
            make_writable "$target_dir/$skill_name/SKILL.md"
        fi
        cp "$skill_dir/SKILL.md" "$target_dir/$skill_name/SKILL.md"
        installed_files="$installed_files
$skill_name/SKILL.md"
        count=$((count + 1))
    done < <(manifest_skill_lines)

    if [ "$count" -eq 0 ]; then
        fail "No skills resolved from $MANIFEST_FILE — is this a complete clone?"
        exit 1
    fi

    # Write the same install receipt install.sh writes, so uninstall.sh works for
    # setup.sh installs too.
    write_install_manifest "$target_dir" "$agent_name" "$installed_files"

    ok "$count skills installed"
}

# ============================================================================
# Safe File Operations
# Bash 3.2 compatible (macOS ships /bin/bash 3.2) — no associative arrays or
# bash-4-only syntax. These helpers protect user files from corruption.
# ============================================================================

# Write a timestamped backup before modifying a file (no-op if it is absent).
make_backup() {
    local target="$1"
    [ -f "$target" ] || return 0
    local backup
    backup="${target}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$target" "$backup"
    info "Backup written: $backup"
}

# Atomically replace a file with content read from stdin. The temp file lives in
# the SAME directory as the target (so the mv is atomic, not a cross-device copy)
# and the original file's permissions are preserved when it already exists.
atomic_replace() {
    local target="$1"
    local tmp
    tmp="$(mktemp "${target}.XXXXXX")" || { fail "Could not create temp file for $target"; exit 1; }
    if [ -f "$target" ]; then
        cp -p "$target" "$tmp" 2>/dev/null || true
    fi
    cat > "$tmp"
    mv "$tmp" "$target"
}

# Abort if a marker pair is unbalanced (BEGIN present without END, or vice
# versa). Without this guard the awk rewrite below sets skip=1 on BEGIN and never
# clears it, silently deleting everything after BEGIN when the mv overwrites.
validate_markers() {
    local file="$1" begin="$2" end="$3" label="$4"
    local has_begin=0 has_end=0
    if grep -qF "$begin" "$file"; then has_begin=1; fi
    if grep -qF "$end" "$file"; then has_end=1; fi
    if [ "$has_begin" -ne "$has_end" ]; then
        fail "Unbalanced $label markers in $file"
        if [ "$has_begin" -eq 1 ]; then
            fail "Found begin marker but missing: $end"
        else
            fail "Found end marker but missing: $begin"
        fi
        fail "Refusing to modify $file to avoid data loss. Fix the markers and re-run."
        exit 1
    fi
}

# ============================================================================
# Setup Orchestrator Prompt (idempotent with markers)
# ============================================================================

setup_orchestrator() {
    local prompt_path="$1"
    local example_file="$2"
    local agent_name="$3"

    [ -n "$example_file" ] || return 0
    [ -f "$example_file" ] || { warn "Example file not found: $example_file"; return 0; }

    local prompt_dir
    prompt_dir="$(dirname "$prompt_path")"
    mkdir -p "$prompt_dir"

    # Cursor's target is a dedicated .mdc file owned by this tool, and .mdc YAML
    # frontmatter must start at byte 0 — marker wrapping would break it. Copy the
    # generated rule verbatim (with backup) instead of marker-merging.
    if [ "$agent_name" = "cursor" ]; then
        make_backup "$prompt_path"
        atomic_replace "$prompt_path" < "$example_file"
        info "Wrote $prompt_path (verbatim .mdc copy)"
        return 0
    fi

    local content
    # Strip preamble (human-readable header) — only inject from "## Agent Teams" onward
    content=$(sed -n '/^## Agent Teams/,$p' "$example_file")

    if [ -f "$prompt_path" ]; then
        # Guard against data loss: an unbalanced marker pair (BEGIN without END
        # from a manual edit, merge conflict, or external tool) would make the awk
        # rewrite below truncate everything after BEGIN. Refuse to touch the file.
        validate_markers "$prompt_path" "$MARKER_BEGIN" "$MARKER_END" "agent-teams-lite"
        validate_markers "$prompt_path" "$GAI_MARKER_BEGIN" "$GAI_MARKER_END" "gentle-ai"

        # The injected content is multi-line. Pass it to awk via a file read with
        # getline instead of `-v content=...`: BSD awk (macOS) and mawk reject
        # literal newlines in a -v value, and -v also mangles backslashes.
        if grep -qF "$MARKER_BEGIN" "$prompt_path"; then
            # Our markers exist — replace content between them
            make_backup "$prompt_path"
            local cfile updated
            cfile="$(mktemp)"
            printf '%s\n' "$content" > "$cfile"
            if updated=$(awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" -v cfile="$cfile" '
                $0 == begin {
                    print
                    while ((getline line < cfile) > 0) print line
                    close(cfile)
                    skip=1; next
                }
                $0 == end { print; skip=0; next }
                !skip     { print }
            ' "$prompt_path"); then
                rm -f "$cfile"
                printf '%s\n' "$updated" | atomic_replace "$prompt_path"
                ok "Orchestrator updated in $prompt_path"
            else
                rm -f "$cfile"
                fail "Failed to rewrite $prompt_path (left unchanged)"; exit 1
            fi
        elif grep -qF "$GAI_MARKER_BEGIN" "$prompt_path"; then
            # gentle-ai markers exist — replace content between GAI markers with ours
            make_backup "$prompt_path"
            local cfile updated
            cfile="$(mktemp)"
            printf '%s\n' "$content" > "$cfile"
            if updated=$(awk -v gai_begin="$GAI_MARKER_BEGIN" -v gai_end="$GAI_MARKER_END" \
                -v begin="$MARKER_BEGIN" -v end="$MARKER_END" -v cfile="$cfile" '
                $0 == gai_begin {
                    print begin
                    while ((getline line < cfile) > 0) print line
                    close(cfile)
                    skip=1; next
                }
                $0 == gai_end { print end; skip=0; next }
                !skip         { print }
            ' "$prompt_path"); then
                rm -f "$cfile"
                printf '%s\n' "$updated" | atomic_replace "$prompt_path"
                ok "Orchestrator updated in $prompt_path (replaced gentle-ai section)"
            else
                rm -f "$cfile"
                fail "Failed to rewrite $prompt_path (left unchanged)"; exit 1
            fi
        else
            # Check if orchestrator content already exists (no markers)
            local already_present=false
            for heading in "${ORCHESTRATOR_HEADINGS[@]}"; do
                if grep -qF "$heading" "$prompt_path"; then
                    already_present=true
                    break
                fi
            done

            if $already_present; then
                warn "Orchestrator already present in $prompt_path (no markers found)"
                info "To enable auto-updates, wrap the SDD section with:"
                info "  $MARKER_BEGIN"
                info "  $MARKER_END"
            else
                # No existing content — append our marked section atomically
                make_backup "$prompt_path"
                {
                    cat "$prompt_path"
                    echo ""
                    echo "$MARKER_BEGIN"
                    echo "$content"
                    echo "$MARKER_END"
                } | atomic_replace "$prompt_path"
                ok "Orchestrator appended to $prompt_path"
            fi
        fi
    else
        # File doesn't exist — create with markers
        {
            echo "$MARKER_BEGIN"
            echo "$content"
            echo "$MARKER_END"
        } | atomic_replace "$prompt_path"
        ok "Orchestrator created at $prompt_path"
    fi
}

# ============================================================================
# OpenCode Special Handling
# ============================================================================

ask_opencode_mode() {
    # If already set via flag, skip
    [[ -n "$OPENCODE_MODE" ]] && return

    # Non-interactive defaults to single
    if $NON_INTERACTIVE; then
        OPENCODE_MODE="single"
        return
    fi

    echo ""
    echo -e "  ${BOLD}OpenCode agent mode:${NC}"
    echo ""
    echo "  1) Single model  — one agent handles all phases (simple, recommended)"
    echo "  2) Multi-model   — one agent per phase, each with its own model"
    echo ""
    read -rp "  Choice [1]: " mode_choice
    mode_choice="${mode_choice:-1}"

    case "$mode_choice" in
        2|multi)  OPENCODE_MODE="multi" ;;
        *)        OPENCODE_MODE="single" ;;
    esac
}

setup_opencode() {
    local home
    home="$(home_dir)"
    local commands_src="$EXAMPLES_DIR/opencode/commands"
    local commands_target="$home/.config/opencode/commands"
    local config_file="$home/.config/opencode/opencode.json"

    # Determine mode and pick the right config template
    ask_opencode_mode
    local example_config="$EXAMPLES_DIR/opencode/opencode.${OPENCODE_MODE}.json"
    info "OpenCode mode: $OPENCODE_MODE"

    # Install commands
    if [ -d "$commands_src" ]; then
        mkdir -p "$commands_target"
        local count=0
        for cmd_file in "$commands_src"/sdd-*.md; do
            [ -f "$cmd_file" ] || continue
            local cmd_name
            cmd_name=$(basename "$cmd_file" .md)

            if [[ "$OPENCODE_MODE" == "multi" ]] && grep -q "^subtask:" "$cmd_file"; then
                # Multi mode: subtask commands point to their dedicated subagent
                sed "s/^agent: sdd-orchestrator/agent: $cmd_name/" "$cmd_file" > "$commands_target/$(basename "$cmd_file")"
            else
                cp "$cmd_file" "$commands_target/"
            fi
            count=$((count + 1))
        done
        ok "$count OpenCode commands installed ($OPENCODE_MODE mode)"
    fi

    # Merge opencode.json agent config (idempotent: replaces sdd-* agents, preserves user model choices)
    if command -v jq &>/dev/null && [ -f "$example_config" ]; then
        if [ -f "$config_file" ]; then
            local example_agents
            example_agents=$(jq '.agent // {}' "$example_config")

            # Smart merge:
            # 1. Remove all existing sdd-* keys (clean slate for our agents)
            # 2. Preserve "model" field from existing sdd-* agents (user customization)
            # 3. Add new agent definitions, restoring preserved model fields
            # 4. Don't touch non-sdd agents
            local merged
            merged=$(jq --argjson new_agents "$example_agents" '
                # 1. Capture existing model fields from sdd-* agents (user customization)
                (reduce ((.agent // {}) | to_entries[] |
                    select(.key | startswith("sdd-")) | select(.value.model)) as $e
                    ({}; . + {($e.key): $e.value.model})) as $saved_models |

                # 2. Remove all sdd-* agents, keep user custom agents, add new template agents
                .agent = (
                    ((.agent // {}) | with_entries(select(.key | startswith("sdd-") | not)))
                    + $new_agents
                ) |

                # 3. Restore user model choices onto new agent definitions
                reduce ($saved_models | to_entries[]) as $m (.;
                    if .agent[$m.key] then .agent[$m.key].model = $m.value else . end
                ) |

                # 4. Clean up stale "agents" plural key
                del(.agents)
            ' "$config_file")

            make_backup "$config_file"
            printf '%s\n' "$merged" | atomic_replace "$config_file"
            ok "Agent config merged into $config_file ($OPENCODE_MODE mode)"
        else
            mkdir -p "$(dirname "$config_file")"
            cp "$example_config" "$config_file"
            ok "Config created at $config_file ($OPENCODE_MODE mode)"
        fi
    else
        if ! command -v jq &>/dev/null; then
            warn "jq not found — cannot auto-merge opencode.json"
        fi
        warn "Merge manually: copy agent block from examples/opencode/opencode.${OPENCODE_MODE}.json"
        info "Into: $config_file"
    fi

    # Install AGENTS.md prompt file for prompt references in config templates
    local agents_src="$EXAMPLES_DIR/opencode/AGENTS.md"
    local agents_target="$home/.config/opencode/AGENTS.md"
    if [ -f "$agents_src" ]; then
        mkdir -p "$(dirname "$agents_target")"
        cp "$agents_src" "$agents_target"
        ok "AGENTS.md installed -> $agents_target"
    fi

    # Install background-agents plugin
    local plugins_dir="$home/.config/opencode/plugins"
    local plugin_src="$SCRIPT_DIR/../examples/opencode/plugins/background-agents.ts"
    mkdir -p "$plugins_dir"
    if [ -f "$plugin_src" ]; then
        cp "$plugin_src" "$plugins_dir/background-agents.ts"
        ok "background-agents plugin installed → $plugins_dir"
    else
        warn "Plugin source not found: $plugin_src (skipped)"
    fi

    # Install the plugin's npm dependency. Pin the exact version and disable
    # lifecycle scripts so a compromised release cannot execute code during setup.
    # Degrade gracefully (warn, don't abort) when npm is unavailable.
    if command -v npm &>/dev/null; then
        info "Installing npm dependency: unique-names-generator@$UNIQUE_NAMES_GENERATOR_VERSION"
        (cd "$home/.config/opencode" && npm install --ignore-scripts "unique-names-generator@$UNIQUE_NAMES_GENERATOR_VERSION")
        ok "unique-names-generator@$UNIQUE_NAMES_GENERATOR_VERSION installed"
    else
        warn "npm not found — skipping unique-names-generator dependency"
        info "Install it manually: cd \"$home/.config/opencode\" && npm install --ignore-scripts unique-names-generator@$UNIQUE_NAMES_GENERATOR_VERSION"
    fi
}

# ============================================================================
# Full Setup for One Agent
# ============================================================================

setup_agent() {
    local agent="$1"
    header "Setting up $agent"

    local skills_path
    skills_path="$(get_skills_path "$agent")"
    install_skills "$skills_path" "$agent"

    local prompt_path example_file
    prompt_path="$(get_prompt_path "$agent")"
    example_file="$(get_example_file "$agent")"

    if [[ "$agent" == "opencode" ]]; then
        setup_opencode
    else
        setup_orchestrator "$prompt_path" "$example_file" "$agent"
    fi
}

# ============================================================================
# Summary
# ============================================================================

INSTALLED_AGENTS=()

show_summary() {
    header "Setup Complete"
    echo ""
    # Guard the expansion: on bash 3.2 (macOS stock) "${arr[@]}" of an empty
    # array trips `set -u` with an "unbound variable" error.
    if [ "${#INSTALLED_AGENTS[@]}" -gt 0 ]; then
        for agent in "${INSTALLED_AGENTS[@]}"; do
            local skills_path prompt_path
            skills_path="$(get_skills_path "$agent")"
            prompt_path="$(get_prompt_path "$agent")"
            echo -e "  ${GREEN}✓${NC} ${BOLD}$agent${NC}"
            echo -e "    Skills: $skills_path"
            echo -e "    Prompt: $prompt_path"
        done
    fi

    echo ""
    echo -e "${GREEN}${BOLD}Done!${NC} Start using SDD: open any project and type ${CYAN}/sdd-init${NC}"
    echo ""
    echo -e "${YELLOW}Recommended:${NC} Install ${BOLD}Engram${NC} for cross-session persistence"
    echo -e "  ${CYAN}https://github.com/gentleman-programming/engram${NC}"
    echo ""
}

# ============================================================================
# Interactive Menu
# ============================================================================

interactive_menu() {
    if [[ ${#DETECTED_AGENTS[@]} -eq 0 ]]; then
        echo ""
        warn "No agents detected. Use ./install.sh for manual installation."
        exit 0
    fi

    echo ""
    echo -e "${BOLD}Set up all detected agents? [Y/n]${NC} "
    read -r answer
    answer="${answer:-Y}"

    if [[ "$answer" =~ ^[Yy] ]]; then
        for agent in "${DETECTED_AGENTS[@]}"; do
            setup_agent "$agent"
            INSTALLED_AGENTS+=("$agent")
        done
    else
        echo ""
        echo -e "${BOLD}Select agents to set up (space-separated numbers):${NC}"
        echo ""
        local i=1
        for agent in "${DETECTED_AGENTS[@]}"; do
            echo "  $i) $agent"
            i=$((i + 1))
        done
        echo ""
        read -rp "Choice: " choices

        for choice in $choices; do
            local idx=$((choice - 1))
            if [[ $idx -ge 0 ]] && [[ $idx -lt ${#DETECTED_AGENTS[@]} ]]; then
                local agent="${DETECTED_AGENTS[$idx]}"
                setup_agent "$agent"
                INSTALLED_AGENTS+=("$agent")
            fi
        done
    fi
}

# ============================================================================
# Main
# ============================================================================

detect_os
setup_colors

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║    Agent Teams Lite — Full Setup          ║${NC}"
echo -e "${CYAN}${BOLD}║   Detect • Install • Configure            ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${NC}"

# Parse arguments
AGENT=""
ALL=false
NON_INTERACTIVE=false
OPENCODE_MODE=""  # "", "single", or "multi"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)          AGENT="$2"; shift 2 ;;
        --all)            ALL=true; shift ;;
        --non-interactive) NON_INTERACTIVE=true; ALL=true; shift ;;
        --opencode-mode)
            if [[ "$2" == "single" || "$2" == "multi" ]]; then
                OPENCODE_MODE="$2"; shift 2
            else
                echo "Invalid opencode mode: $2 (use 'single' or 'multi')"; exit 1
            fi
            ;;
        -h|--help)
            echo "Usage: setup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all               Auto-detect and install for all found agents"
            echo "  --agent NAME        Install for a specific agent"
            echo "  --opencode-mode M   OpenCode agent mode: 'single' or 'multi' (per-phase models)"
            echo "  --non-interactive   No prompts (for external installers)"
            echo "  -h, --help          Show this help"
            echo ""
            echo "Agents: claude-code, opencode, gemini-cli, cursor, vscode, codex"
            exit 0
            ;;
        *)  echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate source
for skill_dir in "$SKILLS_SRC"/sdd-*/; do
    if [ ! -f "$skill_dir/SKILL.md" ]; then
        fail "Missing: $(basename "$skill_dir")/SKILL.md"
        fail "Is this a complete clone? git clone https://github.com/Gentleman-Programming/agent-teams-lite.git"
        exit 1
    fi
done
if [ ! -f "$MANIFEST_FILE" ]; then
    fail "Missing: skills/manifest.json (the skill list source of truth)"
    fail "Is this a complete clone? git clone https://github.com/Gentleman-Programming/agent-teams-lite.git"
    exit 1
fi

if [[ -n "$AGENT" ]]; then
    # Single agent mode
    setup_agent "$AGENT"
    INSTALLED_AGENTS+=("$AGENT")
elif $ALL; then
    # Auto-detect + install all
    detect_agents
    # Guard the expansion: on bash 3.2 (macOS stock) "${arr[@]}" of an empty
    # array trips `set -u`. This is the --all/--non-interactive zero-agents path.
    if [ "${#DETECTED_AGENTS[@]}" -gt 0 ]; then
        for agent in "${DETECTED_AGENTS[@]}"; do
            setup_agent "$agent"
            INSTALLED_AGENTS+=("$agent")
        done
    fi
else
    # Interactive
    detect_agents
    interactive_menu
fi

if [[ ${#INSTALLED_AGENTS[@]} -gt 0 ]]; then
    show_summary
else
    echo ""
    warn "No agents were set up."
fi
