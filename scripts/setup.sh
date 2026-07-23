#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Kurama — Full Setup Script
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
INSTALL_MANIFEST_NAME=".kurama-install-manifest.json"

# O1: install scope. "global" writes to the per-user agent config dirs (default,
# unchanged behavior). "project" writes EVERYTHING into a target git repo so a
# user can trial Kurama in one repo without touching their global config.
SCOPE="global"      # global | project
TARGET_PATH=""      # repo root when SCOPE=project (validated; never the Kurama repo)

# O2: Claude Code hooks are ALWAYS installed for the claude-code target (both
# scopes), no prompt. Scripts land in <target>/hooks/kurama/ and a PreToolUse
# block is merged into the matching settings.json. Every hook command string
# contains the substring "hooks/kurama/" so uninstall.sh can filter the block
# out surgically. The two hook scripts ship in examples/claude-code/hooks/.
HOOKS_SRC="$EXAMPLES_DIR/claude-code/hooks"
HOOK_SCRIPTS="orchestrator-write-guard.sh archive-gate.sh"

# Receipt accumulators — filled across install_skills / install_hooks / Pi steps
# and flushed ONCE by finalize_receipt() at the end of setup_agent, so a single
# receipt records skills, agents, hooks, the touched settings.json, and any Pi
# packages installed. Paths in RECEIPT_FILES are relative to RECEIPT_DIR.
RECEIPT_DIR=""
RECEIPT_TOOL=""
RECEIPT_FILES=""
RECEIPT_SETTINGS=""      # newline list of settings.json paths (relative to RECEIPT_DIR)
RECEIPT_PI_PACKAGES=""   # newline list of "npm:pkg@ver" specs installed via pi
RECEIPT_ENGRAM_MCP=""    # O5: newline list of config files an Engram MCP server was written to
RECEIPT_PROMPTS=""       # newline list of orchestrator prompt files carrying a removable BEGIN:kurama block

# O5: Engram optional persistence engine. setup asks ONCE (or honors the
# --with-engram/--without-engram flags) whether to wire Engram as the memory
# backend. With "yes" we ensure the binary (Homebrew on macOS with consent, or a
# printed guide) and register the Engram MCP server into the client being set up,
# replicating gentle-ai's per-client server shapes. With "no" the harness keeps
# its built-in markdown persistence (openspec/.kurama) — mentioned in the summary.
ENGRAM_RELEASES_URL="https://github.com/Gentleman-Programming/engram/releases"
ENGRAM_TAP="Gentleman-Programming/homebrew-tap"
ENGRAM_BINARY_CHECKED=false   # ensure the binary probe/brew prompt runs at most once

# setup.sh installs the DEFAULT skill set (no --with/--without flags). These are
# the default-on groups from skills/manifest.json, which now include the `tdd`
# module. Installing the tdd module does NOT activate TDD — activation stays
# opt-in per project (a project can start without tests and add them later). To
# skip the module, use install.sh --without tdd. The surrounding spaces let
# membership be tested with a case glob.
SETUP_ACTIVE_GROUPS=" sdd-core quality review optional tdd "

MARKER_BEGIN="<!-- BEGIN:kurama -->"
MARKER_END="<!-- END:kurama -->"

# gentle-ai-installer markers (detect to avoid duplication)
GAI_MARKER_BEGIN="<!-- gentle-ai:sdd-orchestrator -->"
GAI_MARKER_END="<!-- /gentle-ai:sdd-orchestrator -->"

# Pinned npm dependency for the OpenCode background-agents plugin.
# Version-locked and installed with --ignore-scripts to limit supply-chain risk.
UNIQUE_NAMES_GENERATOR_VERSION="4.7.1"

# ----------------------------------------------------------------------------
# N5: Pi package stack (opt-in). setup.sh --agent pi can install a curated set
# of Pi packages that light up the same orchestrator workflow on Pi (Engram
# memory, the MCP adapter, subagents, ask-user/todo/web-access/btw helpers).
#
# Versions are PINNED. They were resolved once with `npm view <pkg> version`
# (the only network call this script makes) and hardcoded here for a
# reproducible, supply-chain-auditable install. To refresh a pin, run:
#     npm view <pkg> version
# and update the matching constant below.
#
# EXCLUSION — gentle-pi is deliberately NOT in this stack. gentle-pi is a rival
# harness that overlaps and directly conflicts with Kurama's own orchestrator
# rule and skills on Pi; installing it would fight Kurama for the same surface.
# We never install it. Do not add it here.
PI_PKG_GENTLE_ENGRAM_VERSION="0.1.10"
PI_PKG_MCP_ADAPTER_VERSION="2.11.0"
PI_PKG_SUBAGENTS_VERSION="1.4.1"
PI_PKG_ASK_USER_VERSION="2.0.0"
PI_PKG_WEB_ACCESS_VERSION="0.13.0"
PI_PKG_TODO_VERSION="2.0.0"
PI_PKG_BTW_VERSION="0.4.1"

# Content headings that indicate orchestrator is already present
ORCHESTRATOR_HEADINGS=(
    "## Kurama Orchestrator"
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
    check_agent "pi"          "pi"

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
        pi)           echo "$home/.pi/agent/skills" ;;
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
        cursor)       echo "$home/.cursor/rules/kurama.mdc" ;;
        vscode)
            if [[ "$OS" == "windows" ]]; then
                echo "${APPDATA:-$home/AppData/Roaming}/Code/User/prompts/kurama.instructions.md"
            elif [[ "$OS" == "macos" ]]; then
                echo "$home/Library/Application Support/Code/User/prompts/kurama.instructions.md"
            else
                echo "$home/.config/Code/User/prompts/kurama.instructions.md"
            fi
            ;;
        codex)        echo "$home/.codex/agents.md" ;;
        pi)           echo "$home/.pi/agent/AGENTS.md" ;;
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
        pi)           echo "$EXAMPLES_DIR/pi/AGENTS.md" ;;
    esac
}

# ============================================================================
# O1: scope-aware target resolution
#
# Every writer routes through these so global and project scopes share one code
# path. For SCOPE=global the locations are the per-user config dirs (identical to
# the historical behavior, so existing installs/receipts are byte-compatible).
# For SCOPE=project everything lands inside $TARGET_PATH (the trial repo):
#   claude-code → <repo>/.claude/{skills,agents,hooks}, <repo>/CLAUDE.md,
#                 <repo>/.claude/settings.json
#   pi          → <repo>/.pi/{skills,agents}, <repo>/AGENTS.md
#   other       → <repo>/.claude/skills, <repo>/CLAUDE.md (best-effort parity)
#
# The install receipt lives in RECEIPT_DIR: the skills dir for global (unchanged),
# or the repo root for project (O1), so uninstall/update/doctor find one receipt.
# ============================================================================

# Skills directory for the current scope.
scoped_skills_path() {
    local agent="$1"
    if [ "$SCOPE" = "project" ]; then
        case "$agent" in
            pi)  echo "$TARGET_PATH/.pi/skills" ;;
            *)   echo "$TARGET_PATH/.claude/skills" ;;
        esac
    else
        get_skills_path "$agent"
    fi
}

# Native-agents directory for the current scope (claude-code + pi only).
scoped_agents_path() {
    local agent="$1"
    if [ "$SCOPE" = "project" ]; then
        case "$agent" in
            pi)  echo "$TARGET_PATH/.pi/agents" ;;
            *)   echo "$TARGET_PATH/.claude/agents" ;;
        esac
    else
        case "$agent" in
            pi)  echo "$(home_dir)/.pi/agent/agents" ;;
            *)   echo "$(dirname "$(get_skills_path "$agent")")/agents" ;;
        esac
    fi
}

# Orchestrator prompt file for the current scope.
scoped_prompt_path() {
    local agent="$1"
    if [ "$SCOPE" = "project" ]; then
        case "$agent" in
            pi)        echo "$TARGET_PATH/AGENTS.md" ;;
            opencode)  echo "$TARGET_PATH/AGENTS.md" ;;
            *)         echo "$TARGET_PATH/CLAUDE.md" ;;
        esac
    else
        get_prompt_path "$agent"
    fi
}

# Claude Code hooks dir + settings.json for the current scope.
scoped_hooks_dir() {
    if [ "$SCOPE" = "project" ]; then
        echo "$TARGET_PATH/.claude/hooks/kurama"
    else
        echo "$(home_dir)/.claude/hooks/kurama"
    fi
}

scoped_settings_file() {
    if [ "$SCOPE" = "project" ]; then
        echo "$TARGET_PATH/.claude/settings.json"
    else
        echo "$(home_dir)/.claude/settings.json"
    fi
}

# The directory the install receipt lives in (paths are recorded relative to it).
scoped_receipt_dir() {
    local agent="$1"
    if [ "$SCOPE" = "project" ]; then
        echo "$TARGET_PATH"
    else
        scoped_skills_path "$agent"
    fi
}

# Compute a path RELATIVE to RECEIPT_DIR. Both inputs are absolute. Global uses
# the historical skill-relative form (skills nested in RECEIPT_DIR yield bare
# names, siblings yield ../…); project yields repo-relative paths.
receipt_rel() {
    local abs="$1"
    case "$abs" in
        "$RECEIPT_DIR"/*) printf '%s' "${abs#"$RECEIPT_DIR"/}" ;;
        *)
            # Sibling of RECEIPT_DIR (global agents/hooks/settings live one level
            # up from the skills dir): emit a ../-anchored path.
            local parent base
            parent="$(dirname "$RECEIPT_DIR")"
            case "$abs" in
                "$parent"/*) printf '../%s' "${abs#"$parent"/}" ;;
                *) base="$abs"; printf '%s' "$base" ;;
            esac
            ;;
    esac
}

# ============================================================================
# O1: --path validation for project scope
# ============================================================================

# Resolve a path to an absolute, symlink-free form (portable; no realpath dep).
abspath() {
    local p="$1"
    if [ -d "$p" ]; then
        (cd "$p" 2>/dev/null && pwd)
    else
        local d b
        d="$(dirname "$p")"; b="$(basename "$p")"
        printf '%s/%s' "$(cd "$d" 2>/dev/null && pwd)" "$b"
    fi
}

# Validate TARGET_PATH for project scope: must exist, be a git repo, and never be
# the Kurama clone itself. In non-interactive mode a non-repo aborts; interactive
# mode asks once before proceeding. Sets TARGET_PATH to its absolute form.
validate_project_target() {
    [ "$SCOPE" = "project" ] || return 0

    # Default to the current working directory when --path is omitted.
    [ -n "$TARGET_PATH" ] || TARGET_PATH="$PWD"

    if [ ! -d "$TARGET_PATH" ]; then
        fail "Project target does not exist: $TARGET_PATH"
        exit 1
    fi
    TARGET_PATH="$(abspath "$TARGET_PATH")"

    # Never install into the Kurama repo itself — that would pollute the source.
    local repo_abs
    repo_abs="$(abspath "$REPO_DIR")"
    if [ "$TARGET_PATH" = "$repo_abs" ]; then
        fail "Refusing to install into the Kurama repo itself: $TARGET_PATH"
        info "Point --path at the repository you want to try Kurama in."
        exit 1
    fi

    # Must be a git repository (the trial surface for hooks + orchestrator merge).
    if ! git -C "$TARGET_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        if $NON_INTERACTIVE; then
            fail "Project target is not a git repository: $TARGET_PATH"
            info "Initialize it first (git init) or pass a repo path, then re-run."
            exit 1
        fi
        warn "Project target is not a git repository: $TARGET_PATH"
        read -rp "  Install anyway? [y/N]: " ans
        [[ "${ans:-N}" =~ ^[Yy] ]] || { info "Aborted."; exit 0; }
    fi

    ok "Project scope target: $TARGET_PATH"
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

# Emit a JSON string array (one element per non-empty input line), indented under
# a given key. Portable awk (bash 3.2 / BSD). Used by finalize_receipt.
_json_array() {
    printf '%s\n' "$1" | awk 'NF { list[n++] = $0 }
        END {
            for (i = 0; i < n; i++) {
                sep = (i < n - 1) ? "," : ""
                printf "    \"%s\"%s\n", list[i], sep
            }
        }'
}

# Flush the receipt accumulators to RECEIPT_DIR/.kurama-install-manifest.json.
# Extends install.sh's format with additive fields — "scope", "settings"
# (settings.json files carrying a surgically-removable kurama hooks block),
# "pi_packages" (packages installed via `pi install`), "engram_mcp" (client
# config files an Engram MCP server was written into) and "prompts" (orchestrator
# prompt files carrying a removable BEGIN:kurama block) — so uninstall/update/
# doctor can reverse and re-sync exactly what setup wrote. Older receipts that
# lack these fields still parse (the consumers treat them as global/empty).
finalize_receipt() {
    [ -n "$RECEIPT_DIR" ] || return 0
    local manifest_path="$RECEIPT_DIR/$INSTALL_MANIFEST_NAME"
    local version
    version="$(read_version)"

    mkdir -p "$RECEIPT_DIR"
    make_writable "$manifest_path"
    {
        printf '{\n'
        printf '  "name": "kurama",\n'
        printf '  "version": "%s",\n' "$version"
        printf '  "tool": "%s",\n' "$RECEIPT_TOOL"
        printf '  "scope": "%s",\n' "$SCOPE"
        printf '  "engram": "%s",\n' "${ENGRAM:-no}"
        printf '  "files": [\n'
        _json_array "$RECEIPT_FILES"
        printf '  ],\n'
        printf '  "settings": [\n'
        _json_array "$RECEIPT_SETTINGS"
        printf '  ],\n'
        printf '  "pi_packages": [\n'
        _json_array "$RECEIPT_PI_PACKAGES"
        printf '  ],\n'
        printf '  "engram_mcp": [\n'
        _json_array "$RECEIPT_ENGRAM_MCP"
        printf '  ],\n'
        printf '  "prompts": [\n'
        _json_array "$RECEIPT_PROMPTS"
        printf '  ]\n'
        printf '}\n'
    } > "$manifest_path"
}

# ============================================================================
# Install Skills
# ============================================================================

install_skills() {
    local agent_name="$1"
    local target_dir
    target_dir="$(scoped_skills_path "$agent_name")"

    # Establish receipt context for this target up front so every writer can
    # record its files relative to RECEIPT_DIR via receipt_rel().
    RECEIPT_TOOL="$agent_name"
    RECEIPT_DIR="$(scoped_receipt_dir "$agent_name")"

    info "Installing skills → $target_dir"
    mkdir -p "$target_dir"

    # Copy _shared
    local shared_src="$SKILLS_SRC/_shared"
    local shared_target="$target_dir/_shared"
    if [ -d "$shared_src" ]; then
        mkdir -p "$shared_target"
        local shared_file
        for shared_file in "$shared_src"/*.md; do
            [ -f "$shared_file" ] || continue
            cp "$shared_file" "$shared_target/"
            RECEIPT_FILES="$RECEIPT_FILES
$(receipt_rel "$shared_target/$(basename "$shared_file")")"
        done
        ok "_shared conventions"
    fi

    # Copy the DEFAULT skill set resolved from skills/manifest.json (single source
    # of truth, shared with install.sh) — no hardcoded skill list. Runs in the
    # current shell (process substitution) so $count/RECEIPT_FILES persist.
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
        RECEIPT_FILES="$RECEIPT_FILES
$(receipt_rel "$target_dir/$skill_name/SKILL.md")"
        count=$((count + 1))
    done < <(manifest_skill_lines)

    if [ "$count" -eq 0 ]; then
        fail "No skills resolved from $MANIFEST_FILE — is this a complete clone?"
        exit 1
    fi

    # Native subagents. claude-code ships Claude-format agents; pi ships the
    # Pi-format agents (O4 wiring — the brother authored examples/pi/agents/*.md).
    # Every other target has no native agents. Pre-existing files are backed up
    # then replaced atomically, and each is recorded in the receipt so
    # uninstall.sh removes them too.
    case "$agent_name" in
        claude-code) install_native_agents "$EXAMPLES_DIR/claude-code/agents" "Claude Code" ;;
        pi)          install_native_agents "$EXAMPLES_DIR/pi/agents" "Pi" ;;
    esac

    ok "$count skills installed"
}

# Install every *.md agent from $1 into the scoped agents dir, backing up any
# pre-existing same-named file and recording each in RECEIPT_FILES.
install_native_agents() {
    local agents_src="$1" label="$2"
    local agents_target
    agents_target="$(scoped_agents_path "$RECEIPT_TOOL")"
    if [ ! -d "$agents_src" ]; then
        warn "$label agents source not found: $agents_src (skipped)"
        return 0
    fi
    mkdir -p "$agents_target"
    local agent_file agent_base agent_dest acount=0
    for agent_file in "$agents_src"/*.md; do
        [ -f "$agent_file" ] || continue
        agent_base="$(basename "$agent_file")"
        agent_dest="$agents_target/$agent_base"
        if [ -f "$agent_dest" ]; then
            make_backup "$agent_dest"
            make_writable "$agent_dest"
        fi
        atomic_replace "$agent_dest" < "$agent_file"
        RECEIPT_FILES="$RECEIPT_FILES
$(receipt_rel "$agent_dest")"
        acount=$((acount + 1))
    done
    ok "$acount $label agents installed → $agents_target"
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
# O2: Claude Code hooks (ALWAYS installed for claude-code, both scopes)
#
# Copies the two deterministic-gate scripts to <target>/hooks/kurama/ and merges
# a PreToolUse block into the matching settings.json. Every hook command string
# embeds "hooks/kurama/" so uninstall.sh can filter exactly our entries back out.
# The JSON merge prefers jq (careful, idempotent, atomic, backed up); without jq
# it prints guided manual steps and NEVER sed-edits JSON. All writes recorded in
# the receipt (scripts under files[], the settings.json under settings[]).
# ============================================================================

install_hooks() {
    local hooks_dir settings_file
    hooks_dir="$(scoped_hooks_dir)"
    settings_file="$(scoped_settings_file)"

    if [ ! -d "$HOOKS_SRC" ]; then
        warn "Hooks source not found: $HOOKS_SRC (skipped)"
        return 0
    fi

    header "Installing Claude Code hooks"
    mkdir -p "$hooks_dir"

    # 1. Copy the hook scripts (executable), recording each in the receipt.
    local script dest
    for script in $HOOK_SCRIPTS; do
        [ -f "$HOOKS_SRC/$script" ] || { warn "Missing hook script: $script"; continue; }
        dest="$hooks_dir/$script"
        if [ -f "$dest" ]; then make_writable "$dest"; fi
        atomic_replace "$dest" < "$HOOKS_SRC/$script"
        chmod +x "$dest" 2>/dev/null || true
        RECEIPT_FILES="$RECEIPT_FILES
$(receipt_rel "$dest")"
    done
    ok "hook scripts → $hooks_dir"

    # 2. Build the two command strings. Project scope uses the Claude-expanded
    #    $CLAUDE_PROJECT_DIR anchor; global scope uses the absolute path. Both
    #    contain "hooks/kurama/" for surgical removal.
    local guard_cmd gate_cmd
    if [ "$SCOPE" = "project" ]; then
        guard_cmd='$CLAUDE_PROJECT_DIR/.claude/hooks/kurama/orchestrator-write-guard.sh'
        gate_cmd='$CLAUDE_PROJECT_DIR/.claude/hooks/kurama/archive-gate.sh'
    else
        guard_cmd="$hooks_dir/orchestrator-write-guard.sh"
        gate_cmd="$hooks_dir/archive-gate.sh"
    fi

    # 3. Merge the PreToolUse block into settings.json (idempotent).
    merge_hooks_settings "$settings_file" "$guard_cmd" "$gate_cmd"
    RECEIPT_SETTINGS="$RECEIPT_SETTINGS
$(receipt_rel "$settings_file")"
}

# Careful JSON merge of the Kurama PreToolUse hooks into a settings.json. Removes
# any prior kurama entries (matched by the "hooks/kurama/" substring) before
# re-adding, so it is fully idempotent. Backs up + writes atomically. Degrades to
# printed manual instructions when jq is unavailable — never sed on JSON.
merge_hooks_settings() {
    local settings_file="$1" guard_cmd="$2" gate_cmd="$3"
    mkdir -p "$(dirname "$settings_file")"

    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not found — cannot auto-merge the hooks block into settings.json"
        info "Add these PreToolUse hooks manually to: $settings_file"
        info "  Edit|Write|MultiEdit → command: $guard_cmd"
        info "  Task|Skill           → command: $gate_cmd"
        return 0
    fi

    local merged
    merged=$(
        { [ -f "$settings_file" ] && cat "$settings_file" || printf '{}'; } | \
        jq --arg guard "$guard_cmd" --arg gate "$gate_cmd" '
            .hooks = (.hooks // {}) |
            .hooks.PreToolUse = ((.hooks.PreToolUse // [])
                | map(select(
                    (((.hooks // []) | map(.command // "") | join(" "))
                        | contains("hooks/kurama/")) | not))) |
            .hooks.PreToolUse += [
                {matcher: "Edit|Write|MultiEdit",
                 hooks: [{type: "command", command: $guard}]},
                {matcher: "Task|Skill",
                 hooks: [{type: "command", command: $gate}]}
            ]
        '
    ) || { fail "Failed to merge hooks into $settings_file (left unchanged)"; return 1; }

    if [ -f "$settings_file" ]; then make_backup "$settings_file"; fi
    printf '%s\n' "$merged" | atomic_replace "$settings_file"
    ok "hooks merged into $settings_file"
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

    # Record this prompt so uninstall.sh can surgically strip Kurama's orchestrator
    # block (BEGIN:kurama … END:kurama) on removal, preserving the user's own
    # content in a shared prompt file. (Cursor is exempt above — its dedicated
    # .mdc is a verbatim copy with no markers.)
    RECEIPT_PROMPTS="$RECEIPT_PROMPTS
$(receipt_rel "$prompt_path")"

    local content
    # Strip preamble (human-readable header) — only inject from "## Kurama" onward
    content=$(sed -n '/^## Kurama/,$p' "$example_file")

    if [ -f "$prompt_path" ]; then
        # Guard against data loss: an unbalanced marker pair (BEGIN without END
        # from a manual edit, merge conflict, or external tool) would make the awk
        # rewrite below truncate everything after BEGIN. Refuse to touch the file.
        validate_markers "$prompt_path" "$MARKER_BEGIN" "$MARKER_END" "kurama"
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
# N5: Pi package stack (opt-in, consent-gated)
# ============================================================================

# Decide whether to install the Pi package stack. Honors the explicit
# --with-pi-packages / --without-pi-packages flags; otherwise asks interactively
# (and defaults to "no" when non-interactive so external installers never
# surprise-install packages). Sets PI_PACKAGES to "yes" or "no".
ask_pi_packages() {
    case "$PI_PACKAGES" in
        yes|no) return 0 ;;
    esac

    if $NON_INTERACTIVE; then
        PI_PACKAGES="no"
        return 0
    fi

    echo ""
    echo -e "  ${BOLD}Install the Pi package stack?${NC}"
    echo "  Adds: gentle-engram (memory), pi-mcp-adapter, pi-subagents-j0k3r,"
    echo "  rpiv-ask-user-question, pi-web-access, rpiv-todo, pi-btw."
    echo "  (gentle-pi is intentionally excluded — it conflicts with Kurama.)"
    echo ""
    read -rp "  Install Pi packages? [y/N]: " pi_answer
    pi_answer="${pi_answer:-N}"
    if [[ "$pi_answer" =~ ^[Yy] ]]; then
        PI_PACKAGES="yes"
    else
        PI_PACKAGES="no"
    fi
}

# Run a single `pi install` (or arbitrary pi/npm command) as a non-fatal step:
# a failure warns and is recorded, but never aborts the surrounding setup.
# Args: <human-label> <command...>. Appends to PI_INSTALL_OK / PI_INSTALL_FAIL.
pi_run_step() {
    local label="$1"; shift
    info "Pi: $label"
    if "$@"; then
        ok "$label"
        PI_INSTALL_OK="$PI_INSTALL_OK
  ✓ $label"
    else
        warn "$label failed — continuing"
        PI_INSTALL_FAIL="$PI_INSTALL_FAIL
  ✗ $label"
    fi
}

# Install the curated Pi package stack in the EXACT approved order. Skips cleanly
# when pi is not on PATH. Each step is non-fatal (warn + continue). gentle-pi is
# never installed (see the exclusion note at the top of this file).
setup_pi_packages() {
    ask_pi_packages
    [ "$PI_PACKAGES" = "yes" ] || { info "Skipping Pi package stack (opt-in)"; return 0; }

    header "Installing Pi package stack"

    if ! command -v pi &>/dev/null; then
        warn "pi not found in PATH — skipping the Pi package stack"
        info "Install Pi first, then re-run: ./setup.sh --agent pi --with-pi-packages"
        return 0
    fi

    PI_INSTALL_OK=""
    PI_INSTALL_FAIL=""

    # Approved order — pins are hardcoded above and refreshed via `npm view`.
    pi_run_step "gentle-engram@$PI_PKG_GENTLE_ENGRAM_VERSION" \
        pi install "npm:gentle-engram@$PI_PKG_GENTLE_ENGRAM_VERSION"
    pi_run_step "pi-mcp-adapter@$PI_PKG_MCP_ADAPTER_VERSION" \
        pi install "npm:pi-mcp-adapter@$PI_PKG_MCP_ADAPTER_VERSION"
    pi_run_step "pi-engram init (gentle-engram@$PI_PKG_GENTLE_ENGRAM_VERSION)" \
        npm exec --yes --package "gentle-engram@$PI_PKG_GENTLE_ENGRAM_VERSION" -- pi-engram init
    pi_run_step "pi-subagents-j0k3r@$PI_PKG_SUBAGENTS_VERSION" \
        pi install "npm:pi-subagents-j0k3r@$PI_PKG_SUBAGENTS_VERSION"
    pi_run_step "@juicesharp/rpiv-ask-user-question@$PI_PKG_ASK_USER_VERSION" \
        pi install "npm:@juicesharp/rpiv-ask-user-question@$PI_PKG_ASK_USER_VERSION"
    pi_run_step "pi-web-access@$PI_PKG_WEB_ACCESS_VERSION" \
        pi install "npm:pi-web-access@$PI_PKG_WEB_ACCESS_VERSION"
    pi_run_step "@juicesharp/rpiv-todo@$PI_PKG_TODO_VERSION" \
        pi install "npm:@juicesharp/rpiv-todo@$PI_PKG_TODO_VERSION"
    pi_run_step "pi-btw@$PI_PKG_BTW_VERSION" \
        pi install "npm:pi-btw@$PI_PKG_BTW_VERSION"

    # Record the packages Kurama installs so uninstall.sh can offer to revert
    # exactly these (O3). The npm-exec init step is NOT a package and is omitted;
    # gentle-pi is never here by construction.
    RECEIPT_PI_PACKAGES="$RECEIPT_PI_PACKAGES
npm:gentle-engram@$PI_PKG_GENTLE_ENGRAM_VERSION
npm:pi-mcp-adapter@$PI_PKG_MCP_ADAPTER_VERSION
npm:pi-subagents-j0k3r@$PI_PKG_SUBAGENTS_VERSION
npm:@juicesharp/rpiv-ask-user-question@$PI_PKG_ASK_USER_VERSION
npm:pi-web-access@$PI_PKG_WEB_ACCESS_VERSION
npm:@juicesharp/rpiv-todo@$PI_PKG_TODO_VERSION
npm:pi-btw@$PI_PKG_BTW_VERSION"

    echo ""
    if [ -n "$PI_INSTALL_OK" ]; then
        info "Pi packages installed:"
        printf '%b\n' "$PI_INSTALL_OK"
    fi
    if [ -n "$PI_INSTALL_FAIL" ]; then
        warn "Pi packages that failed (setup continued anyway):"
        printf '%b\n' "$PI_INSTALL_FAIL"
    fi
}

# ============================================================================
# O5: Engram optional persistence engine (asked once; MCP registered per client)
#
# Ask ONCE whether to use Engram. Honors --with-engram/--without-engram and
# defaults to NO when non-interactive so external installers never surprise the
# user. When enabled we ensure the binary (Homebrew on macOS with explicit
# consent, else a printed guide — NEVER a silent network call) and register the
# Engram MCP server into the client being configured, replicating the exact
# per-client server shapes gentle-ai writes. All JSON edits go through jq (backup
# + atomic) and degrade to guided manual steps when jq is missing — never sed on
# JSON. Codex is TOML, upserted with a careful block replace. Every file written
# is recorded in the receipt (engram_mcp[]).
# ============================================================================

ask_engram() {
    case "$ENGRAM" in
        yes|no) return 0 ;;
    esac

    if $NON_INTERACTIVE; then
        ENGRAM="no"
        return 0
    fi

    echo ""
    # Tolerate EOF (piped/non-tty stdin) under `set -e`: default to NO.
    read -rp "  Use Engram as the persistence engine? [y/N]: " engram_answer || engram_answer="N"
    if [[ "${engram_answer:-N}" =~ ^[Yy] ]]; then
        ENGRAM="yes"
    else
        ENGRAM="no"
    fi
}

# Resolve the most stable engram command string, mirroring gentle-ai's
# resolveEngramCommand: prefer an absolute PATH hit, but collapse a versioned
# Homebrew Cellar path back to bare "engram" (it changes on every upgrade).
# Falls back to "engram" when the binary is not yet installed.
engram_command() {
    local p
    if p="$(command -v engram 2>/dev/null)" && [ -n "$p" ]; then
        case "$p" in
            */Cellar/engram/*) echo "engram" ;;
            *)                 echo "$p" ;;
        esac
    else
        echo "engram"
    fi
}

# Ensure the engram binary is available. Runs at most once per setup invocation.
# macOS + Homebrew: offer to install with explicit consent (never in
# non-interactive mode — just guidance). Everything else: print the releases
# guide and continue (registration is still written; it activates once engram is
# on PATH). This is the ONLY place setup may run a network command, and only
# after the user says yes.
ensure_engram_binary() {
    $ENGRAM_BINARY_CHECKED && return 0
    ENGRAM_BINARY_CHECKED=true

    if command -v engram >/dev/null 2>&1; then
        ok "engram found: $(command -v engram)"
        return 0
    fi

    warn "engram not found in PATH"
    if [ "$OS" = "macos" ] && command -v brew >/dev/null 2>&1; then
        if $NON_INTERACTIVE; then
            info "Install it with: brew tap $ENGRAM_TAP && brew install engram"
            return 0
        fi
        read -rp "  Install engram now via Homebrew? [y/N]: " brew_answer || brew_answer="N"
        if [[ "${brew_answer:-N}" =~ ^[Yy] ]]; then
            info "Running: brew tap $ENGRAM_TAP && brew install engram"
            if brew tap "$ENGRAM_TAP" && brew install engram; then
                ok "engram installed via Homebrew"
            else
                warn "brew install engram failed — continuing without the binary"
                info "Install manually from: $ENGRAM_RELEASES_URL"
            fi
        else
            info "Skipped. Install later from: $ENGRAM_RELEASES_URL"
        fi
    else
        info "Install engram from: $ENGRAM_RELEASES_URL"
        info "The MCP registration is still written; it activates once engram is on PATH."
    fi
}

# Merge an Engram MCP overlay into a JSON config using a jq program. jq-only
# (never sed on JSON); degrades to printed guidance when jq is absent. Backs up +
# writes atomically, and records the file in the receipt (engram_mcp[]).
engram_merge_json() {
    local file="$1" jq_prog="$2" cmd="$3"
    mkdir -p "$(dirname "$file")"

    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not found — cannot auto-register the Engram MCP server"
        info "Add the Engram MCP server manually to: $file"
        info "  command: $cmd   args: [\"mcp\", \"--tools=agent\"]"
        return 0
    fi

    local merged
    merged=$(
        { [ -f "$file" ] && cat "$file" || printf '{}'; } | \
        jq --arg cmd "$cmd" "$jq_prog"
    ) || { fail "Failed to register Engram MCP in $file (left unchanged)"; return 1; }

    [ -f "$file" ] && make_backup "$file"
    printf '%s\n' "$merged" | atomic_replace "$file"
    ok "Engram MCP registered → $file"
    RECEIPT_ENGRAM_MCP="$RECEIPT_ENGRAM_MCP
$(receipt_rel "$file")"
}

# Codex uses TOML, not JSON. Upsert the [mcp_servers.engram] block: strip any
# existing block (up to the next section header or EOF) then append a fresh one.
# Backup + atomic, recorded in the receipt. jq never touches this file.
register_engram_codex() {
    local file="$1" cmd="$2"
    mkdir -p "$(dirname "$file")"

    local existing="" stripped
    if [ -f "$file" ]; then
        make_backup "$file"
        existing="$(cat "$file")"
    fi
    stripped="$(printf '%s\n' "$existing" | awk '
        /^\[mcp_servers\.engram\]/ { skip=1; next }
        skip && /^\[/ { skip=0 }
        !skip { print }
    ')"

    {
        # Preserve prior content, drop trailing blank lines, then append the block.
        printf '%s\n' "$stripped" | awk 'NF{last=NR} {lines[NR]=$0} END{for(i=1;i<=last;i++) print lines[i]}'
        [ -n "$stripped" ] && printf '\n'
        printf '[mcp_servers.engram]\n'
        printf 'command = "%s"\n' "$cmd"
        printf 'args = ["mcp", "--tools=agent"]\n'
    } | atomic_replace "$file"
    ok "Engram MCP registered → $file (codex TOML)"
    RECEIPT_ENGRAM_MCP="$RECEIPT_ENGRAM_MCP
$(receipt_rel "$file")"
}

# Register the Engram MCP server for one client, replicating gentle-ai's exact
# per-client shapes (inject.go). Pi needs nothing extra — the Pi package stack
# (gentle-engram) already provides Engram there.
register_engram_mcp() {
    local agent="$1" cmd file home
    cmd="$(engram_command)"
    home="$(home_dir)"

    case "$agent" in
        pi)
            info "Engram on Pi is provided by the Pi package stack (gentle-engram) — no extra MCP registration needed."
            ;;
        claude-code)
            if [ "$SCOPE" = "project" ]; then file="$TARGET_PATH/.mcp.json"; else file="$home/.claude.json"; fi
            engram_merge_json "$file" \
                '.mcpServers = (.mcpServers // {}) | .mcpServers.engram = {command: $cmd, args: ["mcp", "--tools=agent"]}' \
                "$cmd"
            ;;
        opencode)
            if [ "$SCOPE" = "project" ]; then file="$TARGET_PATH/opencode.json"; else file="$home/.config/opencode/opencode.json"; fi
            # OpenCode 1.3.3+ wants command as an array on a type:local server.
            engram_merge_json "$file" \
                '.mcp = (.mcp // {}) | .mcp.engram = {command: [$cmd, "mcp", "--tools=agent"], type: "local"}' \
                "$cmd"
            ;;
        cursor)
            if [ "$SCOPE" = "project" ]; then file="$TARGET_PATH/.cursor/mcp.json"; else file="$home/.cursor/mcp.json"; fi
            engram_merge_json "$file" \
                '.mcpServers = (.mcpServers // {}) | .mcpServers.engram = {command: $cmd, args: ["mcp", "--tools=agent"]}' \
                "$cmd"
            ;;
        gemini-cli)
            if [ "$SCOPE" = "project" ]; then file="$TARGET_PATH/.gemini/settings.json"; else file="$home/.gemini/settings.json"; fi
            engram_merge_json "$file" \
                '.mcpServers = (.mcpServers // {}) | .mcpServers.engram = {command: $cmd, args: ["mcp", "--tools=agent"]}' \
                "$cmd"
            ;;
        vscode)
            if [ "$SCOPE" = "project" ]; then
                file="$TARGET_PATH/.vscode/mcp.json"
            else
                case "$OS" in
                    macos)   file="$home/Library/Application Support/Code/User/mcp.json" ;;
                    windows) file="${APPDATA:-$home/AppData/Roaming}/Code/User/mcp.json" ;;
                    *)       file="$home/.config/Code/User/mcp.json" ;;
                esac
            fi
            # VS Code uses a fixed "servers" key rather than "mcpServers".
            engram_merge_json "$file" \
                '.servers = (.servers // {}) | .servers.engram = {command: $cmd, args: ["mcp", "--tools=agent"]}' \
                "$cmd"
            ;;
        codex)
            if [ "$SCOPE" = "project" ]; then
                info "Codex uses a single global MCP config; skipping Engram registration for project scope."
                info "Run: ./setup.sh --agent codex --with-engram   (global) to register it."
                return 0
            fi
            register_engram_codex "$home/.codex/config.toml" "$cmd"
            ;;
    esac
}

# O5 entry point per agent: ask once, ensure the binary once, register the MCP.
setup_engram() {
    local agent="$1"
    ask_engram
    [ "$ENGRAM" = "yes" ] || return 0

    header "Engram persistence engine"
    ensure_engram_binary
    register_engram_mcp "$agent"
}

# ============================================================================
# Full Setup for One Agent
# ============================================================================

setup_agent() {
    local agent="$1"
    header "Setting up $agent (scope: $SCOPE)"

    # Reset per-agent receipt accumulators (a single setup run may configure
    # several agents; each gets its own receipt).
    RECEIPT_FILES=""
    RECEIPT_SETTINGS=""
    RECEIPT_PI_PACKAGES=""
    RECEIPT_ENGRAM_MCP=""
    RECEIPT_PROMPTS=""

    install_skills "$agent"

    local prompt_path example_file
    prompt_path="$(scoped_prompt_path "$agent")"
    example_file="$(get_example_file "$agent")"

    if [[ "$agent" == "opencode" ]]; then
        # OpenCode's dedicated flow is global-only; project scope still gets its
        # skills + receipt above, and the orchestrator merge below.
        if [ "$SCOPE" = "project" ]; then
            setup_orchestrator "$prompt_path" "$EXAMPLES_DIR/pi/AGENTS.md" "$agent"
        else
            setup_opencode
        fi
    else
        setup_orchestrator "$prompt_path" "$example_file" "$agent"
    fi

    # O2: Claude Code hooks are ALWAYS installed for claude-code (both scopes).
    if [[ "$agent" == "claude-code" ]]; then
        install_hooks
    fi

    # N5: offer the Pi package stack only for the Pi target.
    if [[ "$agent" == "pi" ]]; then
        setup_pi_packages
    fi

    # O5: Engram optional persistence engine — asked once, then the MCP server is
    # registered into this client (unless declined, in which case markdown
    # persistence stays the default and is noted in the summary).
    setup_engram "$agent"

    # Flush the single per-agent receipt (skills + agents + hooks + settings +
    # pi packages + engram MCP) now that every step has recorded its writes.
    finalize_receipt
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
            skills_path="$(scoped_skills_path "$agent")"
            prompt_path="$(scoped_prompt_path "$agent")"
            echo -e "  ${GREEN}✓${NC} ${BOLD}$agent${NC} (${SCOPE})"
            echo -e "    Skills: $skills_path"
            echo -e "    Prompt: $prompt_path"
            if [ "$agent" = "claude-code" ]; then
                echo -e "    Hooks:  $(scoped_hooks_dir)"
            fi
            echo -e "    Receipt: $(scoped_receipt_dir "$agent")/$INSTALL_MANIFEST_NAME"
        done
    fi

    echo ""
    echo -e "${GREEN}${BOLD}Done!${NC} Start using SDD: open any project and type ${CYAN}/sdd-init${NC}"
    echo ""
    # O5: persistence-engine status. When Engram is enabled we confirm it (and
    # nudge to install the binary if it is not yet on PATH); when declined we tell
    # the user the harness runs on its built-in markdown persistence.
    if [ "${ENGRAM:-no}" = "yes" ]; then
        echo -e "${GREEN}Engram:${NC} enabled as the persistence engine (MCP registered per client)."
        if ! command -v engram >/dev/null 2>&1; then
            echo -e "  Install the binary to activate it: ${CYAN}$ENGRAM_RELEASES_URL${NC}"
        fi
    else
        echo -e "${YELLOW}Persistence:${NC} using the built-in ${BOLD}markdown${NC} fallback (openspec/.kurama)."
        echo -e "  Enable cross-session memory anytime with ${CYAN}--with-engram${NC} (installs Engram)."
        echo -e "  ${CYAN}$ENGRAM_RELEASES_URL${NC}"
    fi
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
echo -e "${CYAN}${BOLD}║    Kurama — Full Setup          ║${NC}"
echo -e "${CYAN}${BOLD}║   Detect • Install • Configure            ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${NC}"

# Parse arguments
AGENT=""
ALL=false
NON_INTERACTIVE=false
OPENCODE_MODE=""  # "", "single", or "multi"
PI_PACKAGES=""    # "", "yes", or "no" — controls the N5 Pi package stack
ENGRAM=""         # "", "yes", or "no" — O5 Engram persistence engine

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)          AGENT="$2"; shift 2 ;;
        --all)            ALL=true; shift ;;
        --non-interactive) NON_INTERACTIVE=true; ALL=true; shift ;;
        --scope)
            case "$2" in
                global|project) SCOPE="$2"; shift 2 ;;
                *) echo "Invalid scope: $2 (use 'global' or 'project')"; exit 1 ;;
            esac
            ;;
        --path)           TARGET_PATH="$2"; shift 2 ;;
        --with-pi-packages)    PI_PACKAGES="yes"; shift ;;
        --without-pi-packages) PI_PACKAGES="no"; shift ;;
        --with-engram)         ENGRAM="yes"; shift ;;
        --without-engram)      ENGRAM="no"; shift ;;
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
            echo "  --all                  Auto-detect and install for all found agents"
            echo "  --agent NAME           Install for a specific agent"
            echo "  --scope SCOPE          Install scope: 'global' (default) or 'project'"
            echo "  --path DIR             Target repo for --scope project (default: cwd; must be a git repo)"
            echo "  --opencode-mode M      OpenCode agent mode: 'single' or 'multi' (per-phase models)"
            echo "  --with-pi-packages     Install the Pi package stack (--agent pi, non-interactive)"
            echo "  --without-pi-packages  Skip the Pi package stack (--agent pi, non-interactive)"
            echo "  --with-engram          Use Engram as the persistence engine (register its MCP)"
            echo "  --without-engram       Keep the built-in markdown persistence (default)"
            echo "  --non-interactive      No prompts (for external installers)"
            echo "  -h, --help             Show this help"
            echo ""
            echo "Agents: claude-code, opencode, gemini-cli, cursor, vscode, codex, pi"
            echo ""
            echo "Scope:"
            echo "  global   Install to the per-user agent config dirs (~/.claude, ~/.pi, …)."
            echo "  project  Install everything into a single git repo (--path) to trial Kurama:"
            echo "           skills, agents, hooks, and the orchestrator merge live under the repo."
            exit 0
            ;;
        *)  echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --path only makes sense with project scope.
if [ -n "$TARGET_PATH" ] && [ "$SCOPE" != "project" ]; then
    echo "--path requires --scope project"; exit 1
fi

# O1: validate the project target (exists, git repo, not the Kurama repo) once.
validate_project_target

# Validate source
for skill_dir in "$SKILLS_SRC"/sdd-*/; do
    if [ ! -f "$skill_dir/SKILL.md" ]; then
        fail "Missing: $(basename "$skill_dir")/SKILL.md"
        fail "Is this a complete clone? git clone https://github.com/myst4/kurama.git"
        exit 1
    fi
done
if [ ! -f "$MANIFEST_FILE" ]; then
    fail "Missing: skills/manifest.json (the skill list source of truth)"
    fail "Is this a complete clone? git clone https://github.com/myst4/kurama.git"
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
