#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Kurama — Install Script
# Copies skills to your AI coding assistant's skill directory
# Supported platforms: macOS and Linux
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SKILLS_SRC="$REPO_DIR/skills"
MANIFEST_FILE="$SKILLS_SRC/manifest.json"
VERSION_FILE="$REPO_DIR/VERSION"

# Name of the per-target install manifest (records version + installed files so
# upgrades can detect leftovers and uninstall.sh can remove exactly what we wrote).
INSTALL_MANIFEST_NAME=".kurama-install-manifest.json"

# Skill-group selection. Groups come from skills/manifest.json; sdd-core is
# mandatory, and quality + review + optional + tdd are all on by default and
# opt-out via --without. The tdd module ships by default but installing it does
# NOT activate TDD — activation stays opt-in per project (a project can start
# without tests and add them later).
# The surrounding single spaces let membership be tested with a case glob.
ACTIVE_GROUPS=" sdd-core quality review optional tdd "
REQUIRED_GROUPS=" sdd-core "

# Every group name the flags accept (default-on ones plus opt-in ones). Kept in
# sync with skills/manifest.json "groups"; drives validation + the rebuild loop.
KNOWN_GROUPS="sdd-core quality review optional tdd lang"

# Populated from the manifest once flags are parsed (see compute_active_skills).
ACTIVE_SKILLS=()

# Count of targets skipped because setup.sh manages their receipt (see
# setup_managed_receipt). Non-zero makes the run exit non-zero.
MANAGED_TARGETS_SKIPPED=0

# Set by install_skills for the target it just handled: true when that target was
# refused. "Refused" must mean the WHOLE target, so every per-target write that
# runs after install_skills — today only the OpenCode command files, which
# setup.sh also owns and rewrites per mode — is gated on this.
LAST_TARGET_REFUSED=false

# ============================================================================
# OS Detection
# ============================================================================

# macOS and Linux only.
detect_os() {
    case "$(uname -s)" in
        Darwin)  OS="macos" ;;
        Linux)   OS="linux" ;;
        *)       OS="unknown" ;;
    esac
}

os_label() {
    case "$OS" in
        macos)   echo "macOS" ;;
        linux)   echo "Linux" ;;
        *)       echo "Unknown" ;;
    esac
}

# ============================================================================
# Color support
# ============================================================================

setup_colors() {
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
}

# ============================================================================
# Path Resolution
# ============================================================================

get_tool_path() {
    local tool="$1"
    case "$tool" in
        claude-code)       echo "$HOME/.claude/skills" ;;
        opencode)          echo "$HOME/.config/opencode/skills" ;;
        opencode-commands) echo "$HOME/.config/opencode/commands" ;;
        codex)             echo "$HOME/.codex/skills" ;;
        # Pi's global skills live under its agent config dir (~/.pi/agent/skills).
        pi)                echo "$HOME/.pi/agent/skills" ;;
        # omp keeps user skills under its agent config dir (~/.omp/agent/skills).
        # PI_CODING_AGENT_DIR relocates that base when set — honor it, since omp
        # itself resolves the user base from that variable.
        omp)               echo "${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}/skills" ;;
        project-local)     echo "./skills" ;;
    esac
}

# ============================================================================
# Helpers
# ============================================================================

make_writable() {
    chmod u+w "$1" 2>/dev/null || true
}

# Print the fox banner instead of the plain ASCII title box. TTY-only, so piped
# runs (CI, the install test suite) keep byte-identical output. Non-zero means
# nothing was printed and the caller should fall back to the box.
#
# KURAMA_NO_BANNER=1 suppresses BOTH the banner and the fallback box, for a
# front-end that already drew it. Same contract as setup.sh.
print_banner() {
    # Full if, not `[ … ] && return 0` — see the note in setup.sh.
    if [ "${KURAMA_NO_BANNER:-0}" = "1" ]; then return 0; fi
    [ -t 1 ] || return 1
    bash "$SCRIPT_DIR/banner.sh" --no-anim 2>/dev/null
}

print_header() {
    if ! print_banner; then
        echo ""
        echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}${BOLD}║      Kurama — Installer        ║${NC}"
        echo -e "${CYAN}${BOLD}║   Spec-Driven Development for AI Agents  ║${NC}"
        echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${NC}"
    fi
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
    echo -e "\n${YELLOW}Persistence backend:${NC} artifacts default to the built-in markdown store"
    echo -e "  ${BOLD}openspec${NC} — files under ${BOLD}openspec/${NC}, version-controlled with the repo (default)"
    echo -e "  ${BOLD}engram${NC}   — cross-session memory: ${CYAN}https://github.com/gentleman-programming/engram${NC}"
    echo -e "  Pick one at ${BOLD}/sdd-init${NC}; ${BOLD}setup.sh --with-engram${NC} wires the Engram MCP for you"
}

show_help() {
    echo "Usage: install.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --agent NAME     Install for a specific agent (non-interactive)"
    echo "  --path DIR       Custom install path (use with --agent custom)"
    echo "  --with GROUP     Include an optional skill group (quality, review, optional, tdd, lang)"
    echo "  --without GROUP  Exclude an optional skill group (quality, review, optional, tdd)"
    echo "  --version        Print the Kurama version and exit"
    echo "  -h, --help       Show this help"
    echo ""
    echo "Agents: claude-code, opencode, codex, pi, omp, project-local, all-global"
    echo ""
    echo "Skill groups:"
    echo "  sdd-core   Core SDD pipeline + authoring utilities (always installed)"
    echo "  quality    Adversarial review skills, e.g. judgment-day (on by default; --without quality to skip)"
    echo "  review     4R review lenses + refuter, e.g. review-risk (on by default; --without review to skip)"
    echo "  optional   Optional modules, e.g. kanban-github (on by default; --without optional to skip)"
    echo "  lang       Per-language pattern skills, e.g. go-testing (OFF by default; --with lang to include)"
    echo "  tdd        TDD module (RED-GREEN-REFACTOR), skills/tdd (on by default; --without tdd to skip)"
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

# Short commit SHA of the Kurama repo this installer runs from, used to stamp the
# receipt (V3). Prints the empty string when git is unavailable or the repo has no
# HEAD — the caller then omits the "commit" field entirely so it never breaks a
# jq-less parser or an install on a machine without git.
read_commit() {
    local c=""
    if command -v git >/dev/null 2>&1; then
        c="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    fi
    printf '%s' "$c"
}

print_version() {
    printf 'kurama %s\n' "$(read_version)"
}

# Emit "<name> <group>" for every skill declared in skills/manifest.json.
# Uses jq when available, otherwise a portable awk fallback (bash 3.2 / BSD awk)
# that parses only the "skills" array. The fallback tracks object boundaries, so
# "name" and "group" may sit on separate lines — as they do in the pretty-printed
# manifest this repo ships.
#
# This awk is the canonical skills-manifest parser and is duplicated byte-for-byte
# in setup.sh and validate_skills.sh. There is no shared library: if you change it
# here, change it in all three. See
# docs/superpowers/specs/2026-08-10-jq-optional-fallbacks-design.md for the three
# properties that must be preserved (the !inarr guard, the anchored closing rule,
# and the rule order that makes a one-line object work).
manifest_skill_lines() {
    [ -f "$MANIFEST_FILE" ] || return 1
    if command -v jq >/dev/null 2>&1; then
        jq -r '.skills[] | "\(.name) \(.group)"' "$MANIFEST_FILE"
        return 0
    fi
    awk '
        !inarr && /"skills"[[:space:]]*:[[:space:]]*\[/ { inarr = 1; next }
        inarr && /^[[:space:]]*\]/                      { inarr = 0; next }
        inarr && /\{/                                   { name = ""; group = "" }
        inarr {
            if (match($0, /"name"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
                s = substr($0, RSTART, RLENGTH); sub(/.*:[[:space:]]*"/, "", s); sub(/".*/, "", s); name = s
            }
            if (match($0, /"group"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
                g = substr($0, RSTART, RLENGTH); sub(/.*:[[:space:]]*"/, "", g); sub(/".*/, "", g); group = g
            }
        }
        inarr && /\}/ {
            if (name != "" && group != "") print name " " group
            name = ""; group = ""
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
        sdd-core|quality|review|optional|tdd|lang) return 0 ;;
        *)
            print_error "Unknown skill group: $1 (valid: quality, review, optional, tdd, lang)"
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
        # sdd-core cannot be excluded, so an empty selection means the manifest
        # was not parsed — not that the user deselected everything. When the file
        # is there and non-empty, the checkout is fine and the parser is at fault;
        # without jq that is the awk fallback, so name jq instead of the clone.
        if [ -s "$MANIFEST_FILE" ] && ! command -v jq >/dev/null 2>&1; then
            print_error "No skills selected — could not parse $MANIFEST_FILE without jq"
            print_error "Install jq and re-run (macOS: brew install jq · Debian/Ubuntu: apt-get install jq)"
        else
            print_error "No skills selected — could not read $MANIFEST_FILE"
        fi
        exit 1
    fi
}

# Emit each string element of a named JSON array (files, settings, pi_packages)
# from an install manifest. Uses jq when available, otherwise a portable awk
# fallback that reads the one-element-per-line arrays setup.sh/install.sh write.
# Mirrors manifest_json_array in doctor.sh/update.sh so every script parses a
# receipt the same way.
#
# Why the opening rule handles the whole array itself instead of just setting
# inarr: for a single-line "key": [] the array closes on the line that opened it,
# so setting inarr and skipping to the next line hands the closing-bracket check
# a bracket that never arrives. The parser then runs to the end of the receipt,
# printing the NEXT key's declaration line as if it were an element, followed by
# the elements that belong to that other key. This function drives rm from
# files[] below, so an empty files[] would migrate .claude/settings.json out of
# settings[] and delete the file outright instead of stripping its kurama hooks
# block. The !inarr guard is the same defense one level up: without it a later
# "<key>" nested elsewhere in the receipt re-opens an array already closed.
manifest_json_array() {
    local manifest="$1" key="$2"
    [ -f "$manifest" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$key" '(.[$k] // [])[]' "$manifest" 2>/dev/null
        return 0
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
            line = $0
            gsub(/^[[:space:]]+/, "", line)
            gsub(/[[:space:]]+$/, "", line)
            gsub(/,$/, "", line)
            gsub(/"/, "", line)
            if (line != "") print line
        }
    ' "$manifest"
}

# Top-level receipt keys only setup.sh's finalize_receipt writes. install.sh's
# receipt is a strict subset (name/version/commit/tool/files), so seeing any of
# these means the target is managed by setup.sh.
SETUP_ONLY_RECEIPT_KEYS="tools scope settings prompts engram_mcp tui_plugins pi_packages"

# True when the receipt at $1 was written by setup.sh. write_install_manifest
# OVERWRITES, at the same path where setup.sh MERGES, so running install.sh over
# a setup.sh install used to drop tools/scope/settings/prompts/engram_mcp/
# tui_plugins and every file entry outside skills[] — hooks, native agents and
# prompt blocks became permanently un-uninstallable. install.sh cannot rewrite
# those records (it never wrote those files, and carrying unknown keys forward is
# not something the jq-less path can do safely), so it refuses the target
# instead. Detection is deliberately textual: same answer with or without jq.
setup_managed_receipt() {
    local receipt="$1" key
    [ -f "$receipt" ] || return 1
    for key in $SETUP_ONLY_RECEIPT_KEYS; do
        if grep -q "\"$key\"[[:space:]]*:" "$receipt"; then
            return 0
        fi
    done
    return 1
}

# Remove files the PREVIOUS install.sh receipt recorded that this run did not
# install — a group dropped with --without, or a skill removed from the manifest.
# Dropping them from the receipt alone (the old behavior) left them on disk and
# still loading in the agent, with nothing recording them: excluded skills that
# stayed active and unmanaged. Only plain relative entries are ever touched.
remove_stale_receipt_files() {
    local target_dir="$1" installed="$2"
    local manifest_path="$target_dir/$INSTALL_MANIFEST_NAME"
    [ -f "$manifest_path" ] || return 0

    local entry removed=0
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        # Absolute or ../-escaping entries are not something install.sh wrote.
        case "$entry" in
            /*|*..*) continue ;;
        esac
        if printf '%s\n' "$installed" | grep -qxF -- "$entry"; then continue; fi
        [ -e "$target_dir/$entry" ] || continue
        rm -f "$target_dir/$entry"
        rmdir "$(dirname "$target_dir/$entry")" 2>/dev/null || true
        removed=$((removed + 1))
    done <<< "$(manifest_json_array "$manifest_path" "files")"

    if [ "$removed" -gt 0 ]; then
        print_warn "$removed file(s) from the previous install removed (no longer selected)"
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
    local version commit
    version="$(read_version)"
    commit="$(read_commit)"

    make_writable "$manifest_path"
    {
        printf '{\n'
        printf '  "name": "kurama",\n'
        printf '  "version": "%s",\n' "$version"
        [ -n "$commit" ] && printf '  "commit": "%s",\n' "$commit"
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
    # examples/ is not optional: the OpenCode target installs its /sdd-* command
    # files from it, and every target's "next step" points at a file under it.
    # Checking it here turns an incomplete checkout into one message up front
    # instead of an abort three targets into an all-global run.
    if [ ! -d "$REPO_DIR/examples" ]; then
        print_error "Missing: examples/ (agent configs and the OpenCode /sdd-* commands)"
        missing=$((missing + 1))
    elif [ ! -d "$REPO_DIR/examples/opencode/commands" ]; then
        print_error "Missing: examples/opencode/commands (the OpenCode /sdd-* command files)"
        missing=$((missing + 1))
    fi
    if [ "$missing" -gt 0 ]; then
        echo -e "\n${RED}${BOLD}Source validation failed.${NC} Is this a complete clone of the repository?"
        echo -e "  Try: ${CYAN}git clone https://github.com/myst4/kurama.git${NC}\n"
        exit 1
    fi
}

install_skills() {
    local target_dir="$1"
    local tool_name="$2"
    LAST_TARGET_REFUSED=false

    # A target setup.sh manages carries records install.sh cannot reproduce.
    # Skip it whole — installing files whose receipt we refuse to write would be
    # the same ghost install from the other direction. Callers must skip their
    # follow-up writes for this target too; see LAST_TARGET_REFUSED.
    if setup_managed_receipt "$target_dir/$INSTALL_MANIFEST_NAME"; then
        LAST_TARGET_REFUSED=true
        echo -e "\n${BLUE}Skipping ${BOLD}$tool_name${NC}${BLUE}...${NC}"
        print_warn "This target is managed by setup.sh: $target_dir"
        print_warn "Its receipt records hooks, agents, prompt blocks and MCP registrations"
        print_warn "that install.sh never wrote and would overwrite out of existence."
        echo -e "  ${CYAN}Re-sync it with:${NC} scripts/update.sh    ${CYAN}(or re-run scripts/setup.sh)${NC}"
        MANAGED_TARGETS_SKIPPED=$((MANAGED_TARGETS_SKIPPED + 1))
        return 0
    fi

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

    # Reconcile with the previous receipt BEFORE replacing it, so a group dropped
    # with --without leaves neither a file on disk nor an entry behind.
    remove_stale_receipt_files "$target_dir" "$installed_files"
    write_install_manifest "$target_dir" "$tool_name" "$installed_files"

    echo -e "\n  ${GREEN}${BOLD}$count skills installed${NC} → $target_dir"
}

install_opencode_commands() {
    local commands_src="$REPO_DIR/examples/opencode/commands"
    local commands_target
    commands_target="$(get_tool_path opencode-commands)"

    echo -e "\n${BLUE}Installing OpenCode commands...${NC}"

    if [ ! -d "$commands_src" ]; then
        print_warn "OpenCode commands source not found: $commands_src (skipped)"
        return 0
    fi

    mkdir -p "$commands_target"

    local count=0
    for cmd_file in "$commands_src"/sdd-*.md; do
        # An unmatched glob expands to the pattern itself: without this guard an
        # incomplete checkout made `cp` fail and killed the run under `set -e`,
        # mid-way through all-global (setup.sh's equivalent loop has the guard).
        [ -f "$cmd_file" ] || continue
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
            # Refused target: no command files, and no "add the agent config"
            # banner either — setup.sh already did that and still owns it.
            if $LAST_TARGET_REFUSED; then return 0; fi
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
        codex)
            install_skills "$(get_tool_path codex)" "Codex"
            print_next_step "Codex instructions file" "examples/codex/agents.md"
            ;;
        pi)
            install_skills "$(get_tool_path pi)" "Pi"
            print_next_step "~/.pi/agent/AGENTS.md" "examples/pi/AGENTS.md"
            ;;
        omp)
            install_skills "$(get_tool_path omp)" "omp"
            print_next_step "~/.omp/agent/AGENTS.md" "examples/omp/AGENTS.md"
            ;;
        project-local)
            install_skills "$(get_tool_path project-local)" "Project-local"
            echo -e "\n${YELLOW}Note:${NC} Skills installed in ${BOLD}./skills/${NC} — relative to this project"
            ;;
        all-global)
            install_skills "$(get_tool_path claude-code)" "Claude Code"
            install_skills "$(get_tool_path opencode)" "OpenCode"
            # Same rule per target: a refused OpenCode gets no command files.
            $LAST_TARGET_REFUSED || install_opencode_commands
            install_skills "$(get_tool_path codex)" "Codex"
            install_skills "$(get_tool_path pi)" "Pi"
            install_skills "$(get_tool_path omp)" "omp"
            echo -e "\n${YELLOW}Next steps:${NC}"
            echo -e "  1. Add orchestrator to ${BOLD}~/.claude/CLAUDE.md${NC}"
            echo -e "  2. ${YELLOW}${BOLD}[REQUIRED]${NC} Add orchestrator agent to ${BOLD}~/.config/opencode/opencode.json${NC}"
            echo -e "     ${YELLOW}See: examples/opencode/opencode.single.json (or opencode.multi.json) — without this, /sdd-* commands won't work${NC}"
            echo -e "  3. Add orchestrator to ${BOLD}Codex instructions file${NC}"
            echo -e "  4. Add orchestrator to ${BOLD}~/.pi/agent/AGENTS.md${NC}"
            echo -e "  5. Add orchestrator to ${BOLD}~/.omp/agent/AGENTS.md${NC}"
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
    echo "  3) Codex          ($(get_tool_path codex))"
    echo "  4) Pi             ($(get_tool_path pi))"
    echo "  5) omp            ($(get_tool_path omp))"
    echo "  6) Project-local  ($(get_tool_path project-local))"
    echo "  7) All global     (Claude Code + OpenCode + Codex + Pi + omp)"
    echo "  8) Custom path"
    echo ""
    read -rp "Choice [1-8]: " choice

    case $choice in
        1)  install_for_agent "claude-code" ;;
        2)  install_for_agent "opencode" ;;
        3)  install_for_agent "codex" ;;
        4)  install_for_agent "pi" ;;
        5)  install_for_agent "omp" ;;
        6)  install_for_agent "project-local" ;;
        7)  install_for_agent "all-global" ;;
        8)  install_for_agent "custom" ;;
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

# Every value-taking flag goes through this first: under `set -u` a bare
# `--agent` at the end of the line used to abort with a raw
# "install.sh: line NNN: $2: unbound variable" instead of telling the user what
# the flag wants.
require_flag_value() {
    local flag="$1" value="${2:-}"
    if [ -z "$value" ]; then
        print_error "Missing value for $flag"
        echo ""
        show_help
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)   require_flag_value --agent "${2:-}";   AGENT="$2"; shift 2 ;;
        --path)    require_flag_value --path "${2:-}";    CUSTOM_PATH="$2"; shift 2 ;;
        --with)    require_flag_value --with "${2:-}";    validate_group_name "$2"; enable_group "$2"; shift 2 ;;
        --without) require_flag_value --without "${2:-}"; validate_group_name "$2"; disable_group "$2"; shift 2 ;;
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

# Targets skipped because setup.sh manages them are a non-zero outcome: the user
# asked for an install and did not get one there.
if [ "$MANAGED_TARGETS_SKIPPED" -gt 0 ]; then
    echo -e "\n${RED}${BOLD}Nothing installed for $MANAGED_TARGETS_SKIPPED target(s)${NC} — they are managed by setup.sh."
    echo -e "  Re-sync them with: ${CYAN}scripts/update.sh${NC}\n"
    exit 1
fi

echo -e "\n${GREEN}${BOLD}Done!${NC} Start using SDD with: ${CYAN}/sdd-init${NC} in your project\n"
print_engram_note
echo ""
