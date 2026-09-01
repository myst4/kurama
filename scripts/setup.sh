#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Kurama — Full Setup Script
# Detects installed agents, copies skills, and configures orchestrator prompts.
# Idempotent: safe to run multiple times (uses markers to avoid duplication).
# Supported platforms: macOS and Linux
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
# shellcheck disable=SC2034  # read by read_version() in scripts/lib/receipt.sh
VERSION_FILE="$REPO_DIR/VERSION"

# Shared receipt library — the single copy of the receipt parser and helpers
# (issue #37). SCRIPT_DIR resolves to the clone, so this always finds it; fail
# loud on a partial clone rather than running with an undefined parser.
KURAMA_LIB="$SCRIPT_DIR/lib/receipt.sh"
if [ ! -f "$KURAMA_LIB" ]; then
    echo "kurama: missing $KURAMA_LIB — incomplete clone. Re-clone or pull the full repo." >&2
    exit 1
fi
# shellcheck source=lib/receipt.sh disable=SC1091
. "$KURAMA_LIB"
command -v manifest_json_array >/dev/null 2>&1 || { echo "kurama: scripts/lib/receipt.sh is present but did not define the receipt parser" >&2; exit 1; }

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
HOOK_SCRIPTS="orchestrator-write-guard.sh archive-gate.sh README.md"

# Set by merge_hooks_settings: true only when a merged settings.json really
# reached disk. install_hooks records the file in the receipt only then.
HOOKS_SETTINGS_WRITTEN=false

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
RECEIPT_GITIGNORE=""     # #105: .gitignore files carrying the managed machine-local block
RECEIPT_TUI_PLUGINS=""   # newline list of opencode tui.json files a Kurama TUI plugin was registered in
RECEIPT_OPENCODE_CONFIGS=""  # #22: opencode.json files carrying Kurama's sdd-* agent block (merged, never owned)
# #22: the OpenCode install-time choices. update.sh re-passes them so a re-sync
# reproduces the SAME install instead of falling back to the non-interactive
# defaults (single mode, no profile), which deletes every sdd-* key it does not
# re-create. Recorded per target, so a claude-code receipt never carries them.
RECEIPT_OPENCODE_MODE=""
RECEIPT_OPENCODE_PROFILE=""
RECEIPT_OPENCODE_PROFILE_MODEL=""

# #70: what actually happened to the Engram MCP registration, for show_summary.
# RECEIPT_ENGRAM_MCP cannot answer this: setup_agent CLEARS it for every harness
# so each receipt records only its own files, and show_summary runs ONCE at the
# end of a possibly multi-agent run — it would see the last agent only (and pi,
# which registers nothing, is last under --all). These four are run-scoped and
# never reset. They are counts, not flags, because one run can mix outcomes:
# with jq absent, `--all` still registers codex (TOML needs no jq) while
# claude-code and opencode degrade to manual steps.
ENGRAM_MCP_WRITTEN=0    # registrations that actually reached disk
ENGRAM_MCP_NO_JQ=0      # registrations skipped because jq is missing (manual steps printed)
ENGRAM_MCP_BUILTIN=0    # agents where Engram needs no MCP entry (pi: the package stack provides it)
ENGRAM_MCP_DEFERRED=0   # registrations postponed by design (codex in project scope: its config is global-only)

# #105: what happened to the machine-local .gitignore block, for show_summary.
# Run-scoped like the Engram counters above — setup_agent clears the per-agent
# receipt accumulators, and the summary runs ONCE at the end of a possibly
# multi-agent run. The status is the LAST outcome of the run, which is the final
# state of the file: every agent re-ensures the SAME block in the SAME file, so
# the last word is the true one (a first agent "added" it, pi later "updated" it
# to add .atl/, and what the user should be told is where it ended up).
GITIGNORE_STATUS=""     # created | added | updated | present | nogit | unbalanced | failed | "" (global scope: never ran)
GITIGNORE_PATTERNS=0    # how many patterns the block ended up carrying

# #101: prompt files that already carried the project's OWN workflow when Kurama
# merged its block in. Run-scoped, so the summary can name them after the
# per-file notice has scrolled away.
WORKFLOW_NOTICE_FILES=""

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

# #38: group selection, ported from install.sh so setup.sh alone can do a full
# setup WITHOUT an on-by-default group (e.g. --without review) or WITH an opt-in
# one (--with lang) — install.sh is now a thin wrapper that forwards these here.
# sdd-core is mandatory; quality/review/optional/tdd are on by default and opt-out;
# lang is off by default and opt-in. Kept in sync with skills/manifest.json "groups".
SETUP_REQUIRED_GROUPS=" sdd-core "
SETUP_KNOWN_GROUPS="sdd-core quality review optional tdd lang"

setup_validate_group_name() {
    case "$1" in
        sdd-core|quality|review|optional|tdd|lang) return 0 ;;
        *)
            fail "Unknown skill group: $1 (valid: quality, review, optional, tdd, lang)"
            exit 1
            ;;
    esac
}

setup_enable_group() {
    local g="$1"
    case "$SETUP_ACTIVE_GROUPS" in
        *" $g "*) return 0 ;;
    esac
    SETUP_ACTIVE_GROUPS="$SETUP_ACTIVE_GROUPS$g "
}

# Rebuild the active set from the known-group order, dropping $g. sdd-core is
# refused (it is required). Mirrors install.sh's disable_group so the two resolve
# an identical selection from the same flags.
setup_disable_group() {
    local g="$1"
    case "$SETUP_REQUIRED_GROUPS" in
        *" $g "*)
            fail "Group '$g' is required and cannot be excluded"
            exit 1
            ;;
    esac
    local rebuilt=" " tok
    for tok in $SETUP_KNOWN_GROUPS; do
        case "$SETUP_ACTIVE_GROUPS" in
            *" $tok "*)
                [ "$tok" = "$g" ] && continue
                rebuilt="$rebuilt$tok "
                ;;
        esac
    done
    SETUP_ACTIVE_GROUPS="$rebuilt"
}

MARKER_BEGIN="<!-- BEGIN:kurama -->"
MARKER_END="<!-- END:kurama -->"

# gentle-ai-installer markers (detect to avoid duplication)
GAI_MARKER_BEGIN="<!-- gentle-ai:sdd-orchestrator -->"
GAI_MARKER_END="<!-- /gentle-ai:sdd-orchestrator -->"

# (No pinned npm dependency: the background-agents plugin that required
# `unique-names-generator` is no longer installed. See install_for_opencode.)

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

# Kurama supports macOS and Linux only. The distinction that remains is real:
# Homebrew is offered for the Engram binary on macOS and nowhere else.
detect_os() {
    case "$(uname -s)" in
        Darwin)  OS="macos" ;;
        Linux)   OS="linux" ;;
        *)       OS="unknown" ;;
    esac
}

# home_dir() now lives in scripts/lib/receipt.sh (issue #37).

# ============================================================================
# Colors
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

ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}!${NC} $1"; }
fail()  { echo -e "  ${RED}✗${NC} $1"; }
info()  { echo -e "  ${BLUE}→${NC} $1"; }
header() { echo -e "\n${CYAN}${BOLD}$1${NC}"; }

# Print the fox banner instead of the plain ASCII title box. TTY-only, so piped
# runs (CI, the install test suite) keep byte-identical output. Non-zero means
# nothing was printed and the caller should fall back to the box.
#
# KURAMA_NO_BANNER=1 suppresses BOTH the banner and the fallback box. It exists
# for a front-end that already drew the banner itself: setup-tui.sh runs one
# setup.sh per selected harness, so without this a three-harness install would
# paint the fox four times.
print_banner() {
    # Written as a full if, not `[ … ] && return 0`: under `set -e` a failing
    # AND-list is only safe because every caller wraps this in `if !`, and that
    # is not a property a helper should depend on.
    if [ "${KURAMA_NO_BANNER:-0}" = "1" ]; then return 0; fi
    [ -t 1 ] || return 1
    bash "$SCRIPT_DIR/banner.sh" --no-anim 2>/dev/null
}

# ============================================================================
# Agent Detection
# ============================================================================

DETECTED_AGENTS=()

detect_agents() {
    header "Detecting installed agents..."

    check_agent "claude-code" "claude"
    check_agent "opencode"    "opencode"
    check_agent "codex"       "codex"
    check_agent "pi"          "pi"
    check_agent "omp"         "omp"

    echo ""
    if [[ ${#DETECTED_AGENTS[@]} -eq 0 ]]; then
        warn "No agents detected in PATH"
        info "Install for a specific agent anyway with: ./setup.sh --agent <name>  (claude-code, opencode, codex, pi, omp)"
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

# Global skills dir for a harness — the shared skills_path() map (issue #37).
get_skills_path() {
    skills_path "$1" global
}

# omp resolves its user base from PI_CODING_AGENT_DIR when set, else ~/.omp/agent
# (see omp's context-files docs). Every omp path in this script goes through here so
# a relocated base stays consistent across skills, prompt, agents, and the receipt.
omp_agent_base() {
    if [[ -n "${PI_CODING_AGENT_DIR:-}" ]]; then
        echo "$PI_CODING_AGENT_DIR"
    else
        echo "$(home_dir)/.omp/agent"
    fi
}

get_prompt_path() {
    local agent="$1"
    local home
    home="$(home_dir)"

    case "$agent" in
        claude-code)  echo "$home/.claude/CLAUDE.md" ;;
        opencode)     echo "$home/.config/opencode/AGENTS.md" ;;
        codex)        echo "$home/.codex/agents.md" ;;
        pi)           echo "$home/.pi/agent/AGENTS.md" ;;
        omp)          echo "$(omp_agent_base)/AGENTS.md" ;;
    esac
}

get_example_file() {
    local agent="$1"
    case "$agent" in
        claude-code)  echo "$EXAMPLES_DIR/claude-code/CLAUDE.md" ;;
        opencode)     echo "" ;; # OpenCode has special handling
        codex)        echo "$EXAMPLES_DIR/codex/agents.md" ;;
        pi)           echo "$EXAMPLES_DIR/pi/AGENTS.md" ;;
        omp)          echo "$EXAMPLES_DIR/omp/AGENTS.md" ;;
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
#   omp         → <repo>/.omp/{skills,agents}, <repo>/.omp/AGENTS.md
#   other       → <repo>/.claude/skills, <repo>/CLAUDE.md (best-effort parity)
#
# The install receipt lives in RECEIPT_DIR: the skills dir for global (unchanged),
# or the repo root for project (O1), so uninstall/update/doctor find one receipt.
# ============================================================================

# Skills directory for the current scope.
scoped_skills_path() {
    local agent="$1"
    if [ "$SCOPE" = "project" ]; then
        skills_path "$agent" project "$TARGET_PATH"
    else
        get_skills_path "$agent"
    fi
}

# Native-agents directory for the current scope (claude-code, pi, and omp).
scoped_agents_path() {
    local agent="$1"
    if [ "$SCOPE" = "project" ]; then
        case "$agent" in
            pi)  echo "$TARGET_PATH/.pi/agents" ;;
            omp) echo "$TARGET_PATH/.omp/agents" ;;
            *)   echo "$TARGET_PATH/.claude/agents" ;;
        esac
    else
        case "$agent" in
            pi)  echo "$(home_dir)/.pi/agent/agents" ;;
            omp) echo "$(omp_agent_base)/agents" ;;
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
            # omp's native provider reads the nearest non-empty .omp/AGENTS.md and has
            # the highest discovery priority, so it beats a standalone AGENTS.md.
            omp)       echo "$TARGET_PATH/.omp/AGENTS.md" ;;
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

# True when $1 resolves into the git work tree of the Kurama clone at $2.
# Compares git TOPLEVELS rather than the paths themselves, which is what makes
# this cover the clone root, every subdirectory below it, and any path that
# reaches the clone through a symlink — `cd "$link" && pwd` keeps the logical
# path, so abspath alone never sees through one, while git resolves physically.
#
# Deliberately conservative: a target outside every repo, a Kurama copy that is
# not a git checkout (release tarball), or a missing git binary all leave a side
# unresolved, and an unresolved side is never a match. The plain path equality in
# validate_project_target still guards the clone root in those cases.
resolves_into_kurama_clone() {
    local target="$1" repo="$2"
    local target_top repo_top repo_phys
    # git reports toplevels with symlinks resolved, so compare against the
    # PHYSICAL path of this copy of Kurama; abspath keeps the logical one.
    repo_phys="$(cd "$repo" 2>/dev/null && pwd -P)" || return 1
    repo_top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || return 1
    # Only a Kurama CLONE is protected. When the copy running this script is not
    # the root of its own work tree it is vendored inside somebody else's
    # repository — and that repository is a perfectly legitimate --path target,
    # so the toplevel comparison below would be a false refusal.
    [ -n "$repo_top" ] && [ "$repo_top" = "$repo_phys" ] || return 1
    target_top="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ "$target_top" = "$repo_top" ]
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

    # Never install into the Kurama clone itself — that would pollute the source
    # tree. The string compare below catches the clone root; the toplevel compare
    # catches everything else that resolves into the same work tree. Comparing
    # only the root used to let `--path <kurama>/docs` through, and a project
    # install then wrote .claude/, CLAUDE.md and a receipt into Kurama's own
    # sources (#39).
    local repo_abs
    repo_abs="$(abspath "$REPO_DIR")"
    if [ "$TARGET_PATH" = "$repo_abs" ] || resolves_into_kurama_clone "$TARGET_PATH" "$REPO_DIR"; then
        fail "Refusing to install into the Kurama repo itself: $TARGET_PATH"
        info "That path resolves inside Kurama's own source tree ($repo_abs)."
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
        # Tolerate EOF (piped/closed stdin) under `set -e`: default to the safe NO.
        read -rp "  Install anyway? [y/N]: " ans || ans="N"
        [[ "${ans:-N}" =~ ^[Yy] ]] || { info "Aborted."; exit 0; }
    fi

    ok "Project scope target: $TARGET_PATH"
}

# ============================================================================
# Version + manifest helpers (kept in sync with install.sh so both installers
# resolve the SAME default skill set and write the SAME install receipt)
#
# read_version / read_commit now live in scripts/lib/receipt.sh (issue #37).
# ============================================================================

make_writable() {
    chmod u+w "$1" 2>/dev/null || true
}

# Emit "<name> <group>" for every skill declared in skills/manifest.json. Uses jq
# when available, otherwise a portable awk fallback (bash 3.2 / BSD awk) that parses
# only the "skills" array, tracking object boundaries so name and group may sit on
# separate lines — skills/manifest.json is pretty-printed and they always do.
# CANONICAL PARSER: byte-identical copies live in install.sh and validate_skills.sh.
# There is no shared library; keep the three in sync by hand and do not "improve"
# one copy locally. Three properties must survive any edit: the !inarr guard on the
# opening rule (manifest.json also has groups/targets objects), the ^[[:space:]]*\]
# anchor on the closing rule (a bare /\]/ would match a ] inside a value), and the
# rule order, which lets a one-line {"name":"x","group":"y"} reset, capture and
# print in that order.
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

# receipt_field / receipt_json_array (setup.sh's historical names for
# manifest_field / manifest_json_array) now live in scripts/lib/receipt.sh as
# aliases (issue #37), so the call sites below read unchanged.

# Union of two newline lists: blanks dropped, duplicates dropped, insertion
# order preserved (the first list's entries keep their positions, the second
# list's new entries land at the end).
_merge_lines() {
    printf '%s\n%s\n' "$1" "$2" | awk 'NF && !seen[$0]++'
}

# Filter inherited receipt entries down to the ones still backed by a file on
# disk. Paths resolve exactly like the readers resolve them: an entry starting
# with / is absolute, anything else is relative to RECEIPT_DIR.
_receipt_existing() {
    local line out=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            /*) [ -e "$line" ] || continue ;;
            *)  [ -e "$RECEIPT_DIR/$line" ] || continue ;;
        esac
        out="$out$line
"
    done <<< "$1"
    printf '%s' "$out"
}

# Flush the receipt accumulators to RECEIPT_DIR/.kurama-install-manifest.json.
# Extends install.sh's format with additive fields — "scope", "settings"
# (settings.json files carrying a surgically-removable kurama hooks block),
# "pi_packages" (packages installed via `pi install`), "engram_mcp" (client
# config files an Engram MCP server was written into), "prompts" (orchestrator
# prompt files carrying a removable BEGIN:kurama block), "gitignore" (#105: the
# .gitignore carrying the managed machine-local block), "tui_plugins"
# (opencode tui.json files carrying a removable kurama-logo entry),
# "opencode_configs" (opencode.json files carrying Kurama's sdd-* agent block)
# and the scalar "opencode_mode"/"opencode_profile"/"opencode_profile_model"
# (the install-time OpenCode choices update.sh must re-pass) — so
# uninstall/update/doctor can reverse and re-sync exactly what setup wrote. Older
# receipts that lack these fields still parse (consumers treat them as
# global/empty).
#
# The receipt is MERGED, not truncated: in project scope every harness installed
# into the repo shares one receipt (scoped_receipt_dir returns $TARGET_PATH for
# all of them), so overwriting would discard the previous harness's files and
# leave uninstall/update/doctor blind to them. Inherited entries are only carried
# over while the file they name still exists, which keeps the union from
# accumulating stale paths that doctor would report as MISSING. In global scope
# each harness owns its own receipt dir, so the merge is a no-op union.
finalize_receipt() {
    [ -n "$RECEIPT_DIR" ] || return 0
    local manifest_path="$RECEIPT_DIR/$INSTALL_MANIFEST_NAME"
    local version commit
    version="$(read_version)"
    commit="$(read_commit)"

    # tools[]: every harness already recorded here. The v6/legacy scalar-"tool"
    # fallback is manifest_tools' single decision now (issue #37), not re-sniffed.
    # The current tool goes last and stays the value of "tool".
    local prev_tools
    prev_tools="$(manifest_tools "$manifest_path" | awk -v cur="$RECEIPT_TOOL" 'NF && $0 != cur')"

    local tools files settings pi_packages engram_mcp prompts gitignore tui_plugins opencode_configs
    tools="$(_merge_lines "$prev_tools" "$RECEIPT_TOOL")"
    files="$(_merge_lines "$(_receipt_existing "$(receipt_json_array "$manifest_path" "files")")" "$RECEIPT_FILES")"
    settings="$(_merge_lines "$(_receipt_existing "$(receipt_json_array "$manifest_path" "settings")")" "$RECEIPT_SETTINGS")"
    engram_mcp="$(_merge_lines "$(_receipt_existing "$(receipt_json_array "$manifest_path" "engram_mcp")")" "$RECEIPT_ENGRAM_MCP")"
    prompts="$(_merge_lines "$(_receipt_existing "$(receipt_json_array "$manifest_path" "prompts")")" "$RECEIPT_PROMPTS")"
    gitignore="$(_merge_lines "$(_receipt_existing "$(receipt_json_array "$manifest_path" "gitignore")")" "$RECEIPT_GITIGNORE")"
    tui_plugins="$(_merge_lines "$(_receipt_existing "$(receipt_json_array "$manifest_path" "tui_plugins")")" "$RECEIPT_TUI_PLUGINS")"
    opencode_configs="$(_merge_lines "$(_receipt_existing "$(receipt_json_array "$manifest_path" "opencode_configs")")" "$RECEIPT_OPENCODE_CONFIGS")"
    # pi_packages holds "npm:pkg@ver" specs, not paths: nothing to stat.
    pi_packages="$(_merge_lines "$(receipt_json_array "$manifest_path" "pi_packages")" "$RECEIPT_PI_PACKAGES")"

    # #22: the OpenCode mode/profile of THIS run wins; otherwise an existing
    # record survives. A project receipt shared with other harnesses (or a
    # claude-code re-run over a shared receipt dir) must never erase opencode's
    # recorded choice — that is exactly the value update.sh re-passes.
    local oc_mode oc_profile oc_profile_model
    oc_mode="$RECEIPT_OPENCODE_MODE"
    [ -n "$oc_mode" ] || oc_mode="$(receipt_field "$manifest_path" "opencode_mode")"
    if [ -n "$RECEIPT_OPENCODE_PROFILE" ]; then
        # This run resolved the profile, so its model is authoritative too —
        # including the empty value a base-only re-run ("no") leaves behind.
        oc_profile="$RECEIPT_OPENCODE_PROFILE"
        oc_profile_model="$RECEIPT_OPENCODE_PROFILE_MODEL"
    else
        oc_profile="$(receipt_field "$manifest_path" "opencode_profile")"
        oc_profile_model="$(receipt_field "$manifest_path" "opencode_profile_model")"
    fi

    mkdir -p "$RECEIPT_DIR"
    make_writable "$manifest_path"
    {
        printf '{\n'
        printf '  "name": "kurama",\n'
        printf '  "receiptSchema": %s,\n' "$RECEIPT_SCHEMA"
        printf '  "version": "%s",\n' "$version"
        [ -n "$commit" ] && printf '  "commit": "%s",\n' "$commit"
        printf '  "tool": "%s",\n' "$RECEIPT_TOOL"
        printf '  "tools": [\n'
        _json_array "$tools"
        printf '  ],\n'
        printf '  "scope": "%s",\n' "$SCOPE"
        printf '  "engram": "%s",\n' "${ENGRAM:-no}"
        # #22: emitted only when known, so a receipt that never configured
        # OpenCode stays exactly as it was and update.sh can tell "no OpenCode
        # here" apart from "OpenCode, mode unrecorded" (which it refuses).
        [ -n "$oc_mode" ] && printf '  "opencode_mode": "%s",\n' "$oc_mode"
        [ -n "$oc_profile" ] && printf '  "opencode_profile": "%s",\n' "$oc_profile"
        [ -n "$oc_profile_model" ] && printf '  "opencode_profile_model": "%s",\n' "$oc_profile_model"
        printf '  "files": [\n'
        _json_array "$files"
        printf '  ],\n'
        printf '  "settings": [\n'
        _json_array "$settings"
        printf '  ],\n'
        printf '  "pi_packages": [\n'
        _json_array "$pi_packages"
        printf '  ],\n'
        printf '  "engram_mcp": [\n'
        _json_array "$engram_mcp"
        printf '  ],\n'
        printf '  "prompts": [\n'
        _json_array "$prompts"
        printf '  ],\n'
        printf '  "gitignore": [\n'
        _json_array "$gitignore"
        printf '  ],\n'
        printf '  "tui_plugins": [\n'
        _json_array "$tui_plugins"
        printf '  ],\n'
        printf '  "opencode_configs": [\n'
        _json_array "$opencode_configs"
        printf '  ]\n'
        printf '}\n'
    } > "$manifest_path"
}

# ============================================================================
# #105: the machine-local .gitignore block
#
# Project scope writes machine-local files INTO the target repo — the receipt
# (absolute paths), `.kurama/`, timestamped merge backups, `.claude/settings.local.json`
# — and until now said nothing about any of them. In the field that ended with a
# receipt committed to a shared repo. The pattern list, the marker pair and the
# writer all live in scripts/lib/receipt.sh so setup, update, uninstall and doctor
# read ONE definition (the six-copies lesson of #37).
#
# Global scope never runs this: it writes nothing into a repo.
# A non-git target is a NOTE and a skip, never a failure — `--scope project`
# tolerates a non-repo path when the user says so interactively.
# ============================================================================

# The harnesses this install has recorded so far, plus the one being installed.
# The receipt is the memory across a multi-harness project install (they share
# one receipt dir) AND across update.sh's one-setup-run-per-slug re-sync, which
# is what lets the `pi`-only `.atl/` line survive a re-sync driven by a different
# harness. Read BEFORE finalize_receipt rewrites the file.
gitignore_installed_tools() {
    local manifest="$RECEIPT_DIR/$INSTALL_MANIFEST_NAME"
    _merge_lines "$(manifest_tools "$manifest")" "$RECEIPT_TOOL"
}

ensure_machine_local_gitignore() {
    [ "$SCOPE" = "project" ] || return 0
    [ -n "$RECEIPT_DIR" ] || return 0

    local root
    if ! root="$(git -C "$TARGET_PATH" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$root" ]; then
        GITIGNORE_STATUS="nogit"
        info ".gitignore: $TARGET_PATH is not a git repository — skipped (nothing to ignore)"
        return 0
    fi

    # The block belongs at the REPO ROOT (an unanchored pattern there matches at
    # any depth), but it has to be RECORDED relative to RECEIPT_DIR so uninstall
    # and doctor resolve it the way they resolve every other recorded path.
    # `git rev-parse --show-toplevel` answers PHYSICALLY (/private/var/… on macOS,
    # where /var is a symlink) while TARGET_PATH is the logical path, so the two
    # strings differ for the same directory and receipt_rel would fall through to
    # an absolute entry. Compare physically, then express the file through
    # TARGET_PATH so the receipt keeps its ".gitignore" / "../.gitignore" form.
    local file tools status root_phys target_phys sub rel_prefix
    root_phys="$(cd -P "$root" 2>/dev/null && pwd -P)" || root_phys="$root"
    target_phys="$(cd -P "$TARGET_PATH" 2>/dev/null && pwd -P)" || target_phys="$TARGET_PATH"
    file="$TARGET_PATH/.gitignore"
    if [ "$root_phys" != "$target_phys" ]; then
        case "$target_phys" in
            "$root_phys"/*)
                sub="${target_phys#"$root_phys"/}"
                rel_prefix="$(printf '%s' "$sub" | awk -F/ '{ for (i = 1; i <= NF; i++) printf "../" }')"
                file="$TARGET_PATH/${rel_prefix}.gitignore"
                ;;
            # Unrelated trees (a target reached through a path the repo root does
            # not prefix): record the root's own .gitignore absolute rather than
            # invent a relative form that resolves somewhere else.
            *) file="$root/.gitignore" ;;
        esac
    fi
    tools="$(gitignore_installed_tools)"
    GITIGNORE_PATTERNS="$(kurama_gitignore_pattern_count "$tools")"
    status="$(kurama_gitignore_ensure "$file" "$tools")"
    GITIGNORE_STATUS="$status"

    case "$status" in
        created|added|updated)
            ok "Machine-local files ignored: $GITIGNORE_PATTERNS pattern(s) in $file"
            ;;
        present)
            ok "Machine-local .gitignore block already current: $file"
            ;;
        unbalanced)
            warn "Unbalanced $GITIGNORE_MARKER_BEGIN / $GITIGNORE_MARKER_END markers in $file — left untouched"
            info "Fix the markers and re-run; Kurama never rewrites a block it cannot bound."
            return 0
            ;;
        *)
            warn "Could not write the machine-local block into $file"
            info "Add these by hand so they are never committed:"
            kurama_gitignore_body "$tools" | awk '!/^[[:space:]]*#/ && NF { print "      " $0 }'
            return 0
            ;;
    esac

    # Recorded so uninstall.sh strips exactly this block and doctor.sh can tell a
    # project install that has it from one that does not.
    RECEIPT_GITIGNORE="$RECEIPT_GITIGNORE
$(receipt_rel "$file")"
    return 0
}

# ============================================================================
# Install Skills
# ============================================================================

# #38: remove SKILL.md files a previous receipt recorded under $1 (this target's
# skills dir) that the current group selection no longer installs. $2 is the
# newline list of freshly recorded receipt-relative paths. Only plain-relative
# "*/SKILL.md" entries resolving under $1 are ever touched: "../"-anchored entries
# (native agents, hooks, settings live one level up), absolute entries, and — in
# project scope, where harnesses share one receipt dir — entries under a SIBLING
# harness's skills dir are all skipped. Ported from install.sh's old
# remove_stale_receipt_files so a `--without <group>` re-install leaves neither a
# stale skill loading in the agent nor a receipt entry behind (#24-adjacent).
prune_stale_skills() {
    local target_dir="$1" installed="$2"
    local manifest_path="$RECEIPT_DIR/$INSTALL_MANIFEST_NAME"
    [ -f "$manifest_path" ] || return 0

    local entry abs removed=0
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        case "$entry" in /*|*..*) continue ;; esac
        case "$entry" in */SKILL.md) ;; *) continue ;; esac
        abs="$RECEIPT_DIR/$entry"
        case "$abs" in "$target_dir"/*) ;; *) continue ;; esac
        # Herestring, not a pipe (#65/#110). `printf … | grep -q` makes grep exit
        # on its first match while printf is still writing, and under
        # `set -o pipefail` the resulting SIGPIPE becomes the PIPELINE's status —
        # so a skill that IS in the just-installed list reads as absent, the
        # `continue` is skipped, and the `rm -f` below deletes it as stale. The
        # only site of the four where the wrong verdict costs a file.
        if grep -qxF -- "$entry" <<<"$installed"; then continue; fi
        [ -e "$abs" ] || continue
        rm -f "$abs"
        rmdir "$(dirname "$abs")" 2>/dev/null || true
        removed=$((removed + 1))
    done <<< "$(manifest_json_array "$manifest_path" "files")"

    if [ "$removed" -gt 0 ]; then
        warn "$removed skill(s) from the previous install removed (no longer selected)"
    fi
}

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

    # Copy _shared — the conventions (*.md) AND the shipped helper scripts
    # (*.sh). #106 put build-skill-registry.sh there because the registry is now
    # built by a script instead of a sub-agent, and #89 lands lint-spec.sh beside
    # it. A GLOB, deliberately, not a name list: the next shipped helper travels
    # without anybody remembering to touch this loop.
    #
    # Every copied file is recorded in the receipt exactly like the .md ones, so
    # uninstall.sh removes them, doctor.sh checks them for presence and drift
    # (resolve_source already maps */_shared/* back to the repo source), and
    # update.sh re-syncs them. prune_stale_skills only ever touches "*/SKILL.md"
    # entries, so these are never mistaken for a deselected skill.
    local shared_src="$SKILLS_SRC/_shared"
    local shared_target="$target_dir/_shared"
    if [ -d "$shared_src" ]; then
        mkdir -p "$shared_target"
        local shared_file shared_base
        for shared_file in "$shared_src"/*.md "$shared_src"/*.sh; do
            [ -f "$shared_file" ] || continue
            shared_base="$(basename "$shared_file")"
            make_writable "$shared_target/$shared_base"
            cp "$shared_file" "$shared_target/$shared_base"
            # A helper the skills invoke has to be RUNNABLE. cp keeps an existing
            # destination's mode and gives a fresh copy the source mode masked by
            # the umask, so neither path can be relied on for the +x bit — and a
            # non-executable build-skill-registry.sh is a broken install that
            # looks perfectly healthy in a file listing.
            case "$shared_base" in
                *.sh) chmod +x "$shared_target/$shared_base" ;;
            esac
            RECEIPT_FILES="$RECEIPT_FILES
$(receipt_rel "$shared_target/$shared_base")"
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

    # A manifest that exists and has content but resolves to nothing means the
    # parser, not the checkout, came up empty — and the only parser that can do
    # that is the awk fallback. Name jq instead of accusing the user's clone.
    if [ "$count" -eq 0 ]; then
        if [ -s "$MANIFEST_FILE" ] && ! command -v jq >/dev/null 2>&1; then
            fail "No skills resolved from $MANIFEST_FILE — jq is not installed and the awk fallback found no skills[] entries"
            fail "Install jq and re-run, or check that skills[] in that file is well-formed."
        else
            fail "No skills resolved from $MANIFEST_FILE — is this a complete clone?"
        fi
        exit 1
    fi

    # #38: reconcile with the previous receipt BEFORE finalize rewrites it, so a
    # group dropped with --without leaves neither a stale SKILL.md on disk nor an
    # entry behind. RECEIPT_FILES holds only skills + _shared at this point (native
    # agents are recorded below), which is exactly the freshly-installed skill set.
    prune_stale_skills "$target_dir" "$RECEIPT_FILES"

    # Native subagents. Each harness has its own frontmatter contract, so the
    # agent sets are NOT interchangeable: claude-code ships Claude-format agents,
    # pi ships Pi-format, and omp ships omp task-agent format. omp deliberately
    # skips cross-harness agent roots (.claude/agents, .codex/agents, …) because
    # their frontmatter is not the omp task-agent contract, so omp needs its own
    # set under .omp/agents to get isolated per-phase contexts at all.
    # Every other target has no native agents. Pre-existing files are backed up
    # then replaced atomically, and each is recorded in the receipt so
    # uninstall.sh removes them too.
    case "$agent_name" in
        claude-code) install_native_agents "$EXAMPLES_DIR/claude-code/agents" "Claude Code" ;;
        pi)          install_native_agents "$EXAMPLES_DIR/pi/agents" "Pi" ;;
        omp)         install_native_agents "$EXAMPLES_DIR/omp/agents" "omp"
                     install_omp_rules ;;
    esac

    ok "$count skills installed"
}

# Install every *.md agent from $1 into the scoped agents dir, backing up any
# pre-existing same-named file and recording each in RECEIPT_FILES.
# #38: which optional group a native agent belongs to, so `--without <group>`
# drops its agents alongside its skills (a full setup WITHOUT the review group must
# leave no review-LAYER agents, not just no review skills). review-* are the 4R +
# refuter lenses; jd-* are the Judgment Day quality agents; everything else (the
# sdd-* phase agents) is core and always installed.
native_agent_group_active() {
    case "$1" in
        review-*) setup_group_is_active review ;;
        jd-*)     setup_group_is_active quality ;;
        *)        return 0 ;;
    esac
}

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
        # #38: an agent whose group is deselected is never installed — and a copy a
        # prior (fuller) install left behind is removed, so a `--without <group>`
        # re-install converges to the same state as a fresh one. finalize_receipt's
        # _receipt_existing then drops its now-absent path from the receipt too.
        if ! native_agent_group_active "$agent_base"; then
            [ -e "$agent_dest" ] && rm -f "$agent_dest"
            continue
        fi
        if [ -f "$agent_dest" ]; then
            make_writable "$agent_dest"
        fi
        atomic_replace --backup "$agent_dest" < "$agent_file"
        RECEIPT_FILES="$RECEIPT_FILES
$(receipt_rel "$agent_dest")"
        acount=$((acount + 1))
    done
    ok "$acount $label agents installed → $agents_target"
}

# omp-only: install the sticky rules file. omp reads RULES.md ONLY at its native
# locations (~/.omp/agent/RULES.md, or the nearest <ancestor>/.omp/RULES.md) and
# loads it as an always-apply rule re-attached near the current turn, so the
# orchestrator's hard invariants survive a long conversation. No other supported
# harness has this primitive, so this is not part of the shared prompt path.
#
# Unlike AGENTS.md, this file is NOT marker-merged: omp has no convention for
# partial rule files, and a marker block inside an always-apply rule would ship
# the markers to the model on every turn. A pre-existing file is backed up and
# replaced whole, and recorded in the receipt so uninstall removes exactly it.
install_omp_rules() {
    local rules_src="$EXAMPLES_DIR/omp/RULES.md"
    local rules_dest
    if [ "$SCOPE" = "project" ]; then
        rules_dest="$TARGET_PATH/.omp/RULES.md"
    else
        rules_dest="$(omp_agent_base)/RULES.md"
    fi
    if [ ! -f "$rules_src" ]; then
        warn "omp RULES.md source not found: $rules_src (skipped)"
        return 0
    fi
    mkdir -p "$(dirname "$rules_dest")"
    if [ -f "$rules_dest" ]; then
        make_writable "$rules_dest"
    fi
    atomic_replace --backup "$rules_dest" < "$rules_src"
    RECEIPT_FILES="$RECEIPT_FILES
$(receipt_rel "$rules_dest")"
    ok "omp sticky rules installed → $rules_dest"
}

# ============================================================================
# Safe File Operations
# Bash 3.2 compatible (macOS ships /bin/bash 3.2) — no associative arrays or
# bash-4-only syntax. These helpers protect user files from corruption.
# ============================================================================

# Write a timestamped backup of a file (no-op if it is absent). Called by
# atomic_replace --backup, not directly: the decision "is this write going to
# change anything at all" belongs to the writer, and only a write that really
# changes the file is worth a backup.
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
#
# With --backup, the target is copied aside (make_backup) immediately before it
# is replaced. That flag is the ONLY way a backup is taken, and it is honoured
# only when the new content actually differs — a write that would not change a
# single byte is dropped whole: the temp file is discarded, no backup is taken,
# and the target keeps its inode and mtime. Backups used to run unconditionally
# ahead of every write, so a plain idempotent re-run of setup.sh piled 19
# byte-identical <file>.bak.<timestamp> copies into the user's config dir, and
# another 19 on the run after that, unbounded (#39).
atomic_replace() {
    local backup=false
    if [ "${1:-}" = "--backup" ]; then backup=true; shift; fi
    local target="$1"
    local tmp
    tmp="$(mktemp "${target}.XXXXXX")" || { fail "Could not create temp file for $target"; exit 1; }
    if [ -f "$target" ]; then
        cp -p "$target" "$tmp" 2>/dev/null || true
    fi
    cat > "$tmp"
    # Unchanged content: nothing to back up and nothing to write. A missing `cmp`
    # simply fails the test, degrading to the always-write path rather than
    # skipping a write it could not prove redundant.
    if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
        return 0
    fi
    if $backup; then make_backup "$target"; fi
    mv "$tmp" "$target"
}

# Read a JSON config so it can be piped into a merge. An absent file — or one
# holding nothing but whitespace, a realistic state on a fresh machine or after a
# user clears a config — yields "{}" so the merge starts from an empty object.
# An existing file we cannot READ is an error, never a "{}" degrade: the previous
# `{ cat file || printf '{}'; }` construct turned an unreadable config into an
# empty object and rewrote the user's file from scratch.
read_json_for_merge() {
    local file="$1" content
    [ -e "$file" ] || { printf '{}'; return 0; }
    [ -r "$file" ] || return 1
    content="$(cat "$file")" || return 1
    case "$content" in
        *[![:space:]]*) printf '%s' "$content" ;;
        *)              printf '{}' ;;
    esac
}

# Guard a jq merge result before it is allowed to overwrite a user's config.
# jq exits 0 and prints NOTHING when its input is empty or whitespace-only
# (`printf '\n' | jq '.hooks = (.hooks // {})'` → no output, rc 0), so the usual
# `merged=$(… | jq …) || fail` never fires and the empty $merged lands on the
# user's file while the log prints a success line. Every merge site runs its
# result through this: empty output, or output that is not valid JSON, means
# "leave the file alone".
jq_merge_ok() {
    [ -n "$1" ] || return 1
    printf '%s\n' "$1" | jq -e . >/dev/null 2>&1
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
        # shellcheck disable=SC2016  # $CLAUDE_PROJECT_DIR is expanded by Claude Code at
        # hook-run time, not by this shell — it MUST reach settings.json unexpanded.
        guard_cmd='$CLAUDE_PROJECT_DIR/.claude/hooks/kurama/orchestrator-write-guard.sh'
        # shellcheck disable=SC2016  # same: Claude Code expands this, not bash.
        gate_cmd='$CLAUDE_PROJECT_DIR/.claude/hooks/kurama/archive-gate.sh'
    else
        guard_cmd="$hooks_dir/orchestrator-write-guard.sh"
        gate_cmd="$hooks_dir/archive-gate.sh"
    fi

    # 3. Merge the PreToolUse block into settings.json (idempotent). NON-FATAL:
    #    the skills, agents and hook scripts are already on disk, so aborting here
    #    (a jq failure on a settings.json the user broke by hand used to kill the
    #    installer under `set -e`) would leave every one of them unrecorded.
    merge_hooks_settings "$settings_file" "$guard_cmd" "$gate_cmd" \
        || warn "hooks not registered in $settings_file — fix it and re-run, the rest of the install stands"

    # Record the settings.json ONLY when one was really written. The jq-less path
    # prints manual instructions and writes nothing; recording it anyway pointed
    # uninstall/doctor at a file that does not exist.
    if $HOOKS_SETTINGS_WRITTEN; then
        RECEIPT_SETTINGS="$RECEIPT_SETTINGS
$(receipt_rel "$settings_file")"
    fi
}

# Careful JSON merge of the Kurama PreToolUse hooks into a settings.json. Removes
# any prior kurama entries (matched by the "hooks/kurama/" substring) before
# re-adding, so it is fully idempotent. Backs up + writes atomically. Degrades to
# printed manual instructions when jq is unavailable — never sed on JSON.
# Returns non-zero when the hooks were NOT registered; the caller keeps going.
merge_hooks_settings() {
    local settings_file="$1" guard_cmd="$2" gate_cmd="$3"
    HOOKS_SETTINGS_WRITTEN=false
    mkdir -p "$(dirname "$settings_file")"

    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not found — cannot auto-merge the hooks block into settings.json"
        info "Add these PreToolUse hooks manually to: $settings_file"
        info "  Edit|Write|MultiEdit → command: $guard_cmd"
        info "  Task|Skill           → command: $gate_cmd"
        return 0
    fi

    local input merged
    input="$(read_json_for_merge "$settings_file")" \
        || { fail "Cannot read $settings_file — hooks left unregistered"; return 1; }

    merged=$(
        printf '%s\n' "$input" | \
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

    jq_merge_ok "$merged" \
        || { fail "Hook merge produced no usable JSON — $settings_file left unchanged"; return 1; }

    printf '%s\n' "$merged" | atomic_replace --backup "$settings_file"
    HOOKS_SETTINGS_WRITTEN=true
    ok "hooks merged into $settings_file"
}

# ============================================================================
# Setup Orchestrator Prompt (idempotent with markers)
# ============================================================================

# True when a marker-less prompt file is one of our generated examples copied
# whole: line 1 carries build-examples' GENERATED banner (a line only Kurama
# writes) and the body carries the orchestrator heading. Byte-for-byte the same
# fingerprint sweep_legacy_opencode_artifacts uses in uninstall.sh, so "Kurama
# owns this entire file" means exactly the same thing on both ends of the
# lifecycle. Harness-agnostic on purpose: OpenCode's old wholesale `cp` produced
# this shape automatically, and every harness's manual-install instructions can
# produce it by hand.
prompt_is_kurama_generated_copy() {
    local file="$1"
    [ -f "$file" ] || return 1
    head -1 "$file" | grep -qF 'GENERATED FILE' || return 1
    grep -qF 'Kurama Orchestrator' "$file"
}

# ----------------------------------------------------------------------------
# #101: the prompt file already carries the project's OWN workflow
#
# Field case: a repo whose committed CLAUDE.md defines a mandatory pipeline
# ("the issue body is the source of truth") installed Kurama 6.1.1. The merge was
# intact — balanced markers, complete block — and #18's "SDD owns the work
# lifecycle" clause was present, verbatim, in the installed file. It still lost:
# the repo's own workflow started at line 13 with its own hard rules, and the
# clause subordinating it sat 117 lines lower. Two features later the SDD cycle
# had never run once, and nobody had decided to skip it.
#
# So the defect is not the merge and not the missing precedence sentence. It is
# that setup APPENDED a second lifecycle claim below a first one and said
# NOTHING, at the one moment a human is watching. This does not refuse, does not
# reorder, and does not touch a byte of the project's content — the project's
# instructions legitimately outrank Kurama's block. It makes the collision
# visible and hands the decision to /sdd-init, which asks how the two coexist.
# ----------------------------------------------------------------------------

# Print the content of the prompt file $1 that is NOT inside Kurama's or
# gentle-ai's markers — i.e. what the PROJECT wrote. A file with no markers is
# entirely foreign, which is exactly right for a first install.
prompt_foreign_content() {
    local file="$1"
    [ -f "$file" ] || return 0
    awk -v kb="$MARKER_BEGIN" -v ke="$MARKER_END" \
        -v gb="$GAI_MARKER_BEGIN" -v ge="$GAI_MARKER_END" '
        $0 == kb || $0 == gb { skip = 1; next }
        $0 == ke || $0 == ge { skip = 0; next }
        !skip                { print }
    ' "$file"
}

# Name what looks like a pre-existing workflow in the text on stdin, one finding
# per line, empty when nothing matches. Deliberately a HEURISTIC over the two
# shapes a project workflow actually takes in a prompt file — a section heading
# and a numbered step list. It only ever decides what the notice SAYS; it never
# decides whether Kurama installs, so a false positive costs three lines of text
# and a false negative costs nothing that was not already lost.
detect_workflow_signals() {
    awk '
        # A heading whose title names a process. Printed verbatim (trimmed) so
        # the notice quotes the project back to itself instead of paraphrasing.
        /^#{1,6}[[:space:]]/ {
            line = $0
            if (tolower(line) ~ /(workflow|process|how we work|way we work|development flow|pipeline|ways of working)/) {
                sub(/[[:space:]]+$/, "", line)
                if (!seen[line]++ && headings < 3) {
                    print "the heading \"" line "\""
                    headings++
                }
            }
        }
        # A numbered step list: 3+ "1." / "2)" openers. Two is a pair of notes;
        # three is somebody describing a procedure.
        /^[[:space:]]*[0-9]+[.)][[:space:]]+/ { steps++ }
        END { if (steps >= 3) print "a numbered step list (" steps " steps)" }
    '
}

# Print the notice for prompt file $1 whose project content produced the signals
# in $2 (possibly empty). Runs AFTER the merge so it can say where the block
# actually landed — position is the whole point of #101.
notice_pre_existing_workflow() {
    local file="$1" signals="$2"
    local total begin end where
    total="$(awk 'END { print NR + 0 }' "$file")"
    begin="$(grep -nF "$MARKER_BEGIN" "$file" 2>/dev/null | head -1 | cut -d: -f1)"
    end="$(grep -nF "$MARKER_END" "$file" 2>/dev/null | tail -1 | cut -d: -f1)"
    if [ -n "$begin" ] && [ -n "$end" ]; then
        where="lines $begin-$end of $total"
    else
        where="the end of the file"
    fi

    echo ""
    if [ -n "$signals" ]; then
        echo -e "  ${YELLOW}${BOLD}! Two workflows now live in $file${NC}"
        echo -e "    This project already describes how work is done here:"
        printf '%s\n' "$signals" | awk 'NF { print "      - " $0 }'
        WORKFLOW_NOTICE_FILES="$WORKFLOW_NOTICE_FILES
$file"
    else
        echo -e "  ${YELLOW}${BOLD}! $file already had content of its own${NC}"
    fi
    echo -e "    Kurama's orchestrator block was added at $where. Nothing you wrote was changed."
    echo -e "    ${BOLD}The project's own instructions take precedence over Kurama's block.${NC}"
    if [ -n "$signals" ]; then
        echo -e "    Two pipelines claiming the same work is a decision, not a merge conflict:"
        echo -e "    run ${CYAN}/sdd-init${NC} — it asks how the two should coexist and records the answer."
    fi
    echo ""
}

setup_orchestrator() {
    local prompt_path="$1"
    local example_file="$2"
    local agent_name="$3"

    [ -n "$example_file" ] || return 0
    [ -f "$example_file" ] || { warn "Example file not found: $example_file"; return 0; }

    local prompt_dir
    prompt_dir="$(dirname "$prompt_path")"
    mkdir -p "$prompt_dir"

    # Record this prompt so uninstall.sh can surgically strip Kurama's orchestrator
    # block (BEGIN:kurama … END:kurama) on removal, preserving the user's own
    # content in a shared prompt file.
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

        # #101: what the PROJECT already says, captured BEFORE the merge rewrites
        # the file. A wholesale copy of one of our own generated examples is not
        # the project's content — it is Kurama's, unmarked (see
        # prompt_is_kurama_generated_copy) — and its own "## SDD Workflow"
        # heading would otherwise report the installer to itself.
        local foreign="" workflow_signals=""
        if ! prompt_is_kurama_generated_copy "$prompt_path"; then
            foreign="$(prompt_foreign_content "$prompt_path" | awk 'NF')"
            if [ -n "$foreign" ]; then
                workflow_signals="$(printf '%s\n' "$foreign" | detect_workflow_signals)"
            fi
        fi

        # The injected content is multi-line. Pass it to awk via a file read with
        # getline instead of `-v content=...`: BSD awk (macOS) and mawk reject
        # literal newlines in a -v value, and -v also mangles backslashes.
        if grep -qF "$MARKER_BEGIN" "$prompt_path"; then
            # Our markers exist — replace content between them
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
                printf '%s\n' "$updated" | atomic_replace --backup "$prompt_path"
                ok "Orchestrator updated in $prompt_path"
                if [ -n "$foreign" ]; then
                    notice_pre_existing_workflow "$prompt_path" "$workflow_signals"
                fi
            else
                rm -f "$cfile"
                fail "Failed to rewrite $prompt_path (left unchanged)"; exit 1
            fi
        elif grep -qF "$GAI_MARKER_BEGIN" "$prompt_path"; then
            # gentle-ai markers exist — replace content between GAI markers with ours
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
                printf '%s\n' "$updated" | atomic_replace --backup "$prompt_path"
                ok "Orchestrator updated in $prompt_path (replaced gentle-ai section)"
                if [ -n "$foreign" ]; then
                    notice_pre_existing_workflow "$prompt_path" "$workflow_signals"
                fi
            else
                rm -f "$cfile"
                fail "Failed to rewrite $prompt_path (left unchanged)"; exit 1
            fi
        elif prompt_is_kurama_generated_copy "$prompt_path"; then
            # A pre-marker install: one of our generated examples copied WHOLE
            # into place (setup's old OpenCode branch did this, and the
            # manual-install docs still tell users to). Its body carries
            # "## Kurama Orchestrator", so the already_present branch below
            # would warn and write NOTHING — leaving the prompt frozen forever:
            # no markers would ever appear, the content would never refresh, and
            # doctor/update would keep pointing at a re-run that does nothing.
            # Kurama wrote every byte of this file, so replace it whole with the
            # marked block (backup first). The fingerprint is deliberately the
            # same one uninstall.sh's legacy sweep uses.
            {
                echo "$MARKER_BEGIN"
                echo "$content"
                echo "$MARKER_END"
            } | atomic_replace --backup "$prompt_path"
            ok "Orchestrator re-merged with markers in $prompt_path (was an unmarked full copy)"
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
                {
                    cat "$prompt_path"
                    echo ""
                    echo "$MARKER_BEGIN"
                    echo "$content"
                    echo "$MARKER_END"
                } | atomic_replace --backup "$prompt_path"
                ok "Orchestrator appended to $prompt_path"
                if [ -n "$foreign" ]; then
                    notice_pre_existing_workflow "$prompt_path" "$workflow_signals"
                fi
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

# Shape of a model ID OpenCode can actually resolve: "provider/model-id" (see
# docs/installation.md — "The format is provider/model-id"). Used to decide which
# existing "model" values are worth preserving across a re-run.
#
# The templates deliberately ship NO "model" key: an agent without one inherits
# OpenCode's default model, which is the only safe fallback (a pinned default
# would age out of the user's provider). Older Kurama versions wrote the literal
# "<your-provider/your-model>" instead, which is not a resolvable ID; a plain
# truthy check would preserve it on every re-run and make the breakage sticky.
#
# Note the pattern excludes "<", ">" and whitespace on purpose: the looser
# "^[^/]+/.+" *matches* "<your-provider/your-model>" (the "<your-provider" part
# contains no slash), so it would not filter the very literal this exists for.
OPENCODE_MODEL_RE='^[^<>[:space:]/]+/[^<>[:space:]]+$'

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
    # Tolerate EOF (piped/closed stdin) under `set -e`: fall through to the
    # documented default instead of killing an install already half on disk.
    read -rp "  Choice [1]: " mode_choice || mode_choice=""
    mode_choice="${mode_choice:-1}"

    case "$mode_choice" in
        2|multi)  OPENCODE_MODE="multi" ;;
        *)        OPENCODE_MODE="single" ;;
    esac
}

# Decide whether to install a named model profile (kurama-orchestrator + suffixed
# sdd-<phase>-NAME subagents, Tab-switchable). Honors --opencode-profile; asks
# interactively otherwise and defaults to none when non-interactive. Sets
# OPENCODE_PROFILE to "no" (skip) or a validated NAME.
ask_opencode_profile() {
    # Already resolved via flag ("no" or a NAME) — keep it.
    [[ -n "$OPENCODE_PROFILE" ]] && return

    if $NON_INTERACTIVE; then
        OPENCODE_PROFILE="no"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Named model profile (optional):${NC}"
    echo "  A profile adds a Tab-switchable 'kurama-orchestrator' with per-phase"
    echo "  sub-agents you can point at different models. Leave empty to skip."
    echo ""
    read -rp "  Profile name [skip]: " profile_name || profile_name=""
    profile_name="$(printf '%s' "$profile_name" | tr -d '[:space:]')"
    if [ -z "$profile_name" ]; then
        OPENCODE_PROFILE="no"
        return
    fi
    if ! printf '%s' "$profile_name" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
        warn "Invalid profile name '$profile_name' (lowercase letters, digits, dashes) — skipping profile"
        OPENCODE_PROFILE="no"
        return
    fi
    OPENCODE_PROFILE="$profile_name"
}

# Splice a named profile (kurama-orchestrator + sdd-<phase>-NAME) into
# opencode.json from the committed template. Idempotent: existing user-edited
# model fields for the profile's own agents are preserved across re-runs.
install_opencode_profile() {
    local config_file="$1"
    local saved="${2:-{\}}"
    local name="$OPENCODE_PROFILE"
    local model="$OPENCODE_PROFILE_MODEL"
    local template="$EXAMPLES_DIR/opencode/opencode.profile.template.json"

    if ! command -v jq &>/dev/null; then
        warn "jq not found — cannot splice the '$name' opencode profile"
        return 0
    fi
    if [ ! -f "$template" ]; then
        warn "Profile template not found: $template (skipped)"
        return 0
    fi
    if [ ! -s "$config_file" ]; then
        warn "opencode.json missing or empty — cannot splice the '$name' profile"
        return 0
    fi

    # Derive the profile agents from the template: rename the "-kurama" suffix to
    # "-NAME", in the agent keys AND in the orchestrator's task permission. The
    # template carries no "model" key, so an agent nobody assigns a model to
    # simply inherits OpenCode's default — the model from the flag is applied
    # further down, AFTER the restore, so it can win.
    #
    # #25: the permission map is RENAMED, not reassigned. Overwriting it with
    # {"*":"deny", "sdd-*-NAME":"allow"} dropped the "review-*", "jd-*" and
    # "general" grants the template (and opencode.multi.json) carry, so a
    # named-profile orchestrator could not delegate the mandated review layer at
    # all — the one path where the permission map and the template disagreed.
    # Renaming keeps template and installer in agreement by construction.
    local profile_agents
    profile_agents=$(jq --arg name "$name" '
        def rename_kurama(k): if (k|startswith("sdd-")) and (k|endswith("-kurama"))
            then (k[:-7] + "-" + $name) else k end;
        .agent
        | with_entries(.key |= rename_kurama(.))
        | .["kurama-orchestrator"].permission.task |=
            with_entries(.key |= rename_kurama(.))
    ' "$template") || { warn "Failed to build profile agents"; return 0; }

    # $saved carries the profile agents' user-edited models captured BEFORE the
    # base merge (which strips every sdd-* key, this profile's subagents included).
    local merged
    merged=$(jq --argjson prof "$profile_agents" --argjson saved "$saved" \
        --arg name "$name" --arg model "$model" '
        def isprof(k): (k == "kurama-orchestrator")
            or ((k|startswith("sdd-")) and (k|endswith("-" + $name)));

        # 1. Drop any lingering profile keys, keep everything else, add the fresh profile.
        .agent = (((.agent // {}) | with_entries(select(isprof(.key) | not))) + $prof) |

        # 2. Restore preserved model choices onto the new definitions. This is what
        #    makes a plain re-run idempotent: models the user edited by hand survive.
        reduce ($saved | to_entries[]) as $m (.;
            if .agent[$m.key] then .agent[$m.key].model = $m.value else . end) |

        # 3. An explicit --opencode-profile NAME:provider/model is an explicit choice
        #    made for THIS run, so it overrides the restore above — otherwise
        #    re-running with a different model would silently keep the old one. Omit
        #    the ":provider/model" part to re-run without touching the configured models.
        if $model != "" then
            .agent |= with_entries(if isprof(.key) then .value.model = $model else . end)
        else . end
    ' "$config_file") || { warn "Failed to splice profile into $config_file"; return 0; }

    jq_merge_ok "$merged" \
        || { warn "Profile splice produced no usable JSON — $config_file left unchanged"; return 0; }

    printf '%s\n' "$merged" | atomic_replace --backup "$config_file"
    ok "OpenCode profile '$name' installed (kurama-orchestrator + 9 sdd-<phase>-$name agents)"
}

# ============================================================================
# OpenCode deterministic gates (#90)
#
# The write guard and the archive gate are MECHANISM on OpenCode, not prose:
# `tool.execute.before` can veto a tool call (throwing aborts it), so the same
# two gates Claude Code wires as PreToolUse hooks run here through a plugin.
#
# Three files, no config merge. OpenCode auto-discovers its plugins directory —
# copying the file IS the registration, which also makes this idempotent by
# construction, the same property install_pi_logo relies on. The plugin is a thin
# adapter: the DECISION logic stays in the two bash scripts, which is why they are
# installed beside it rather than reimplemented in TypeScript. See docs/hooks.md.
#
# Called from BOTH scopes. setup_opencode() itself is global-only, but the gates
# are the one OpenCode asset a project-scope install must still get — a harness
# the support matrix calls "enforced" that silently enforces nothing in a repo
# would be the exact defect #90 was filed about.
OPENCODE_GATE_SCRIPTS="orchestrator-write-guard.sh archive-gate.sh"

install_opencode_gates() {
    local home plugin_src plugin_dir hooks_dir dest script
    home="$(home_dir)"
    plugin_src="$EXAMPLES_DIR/opencode/plugins/kurama-sdd-gates.ts"

    if [ "$SCOPE" = "project" ]; then
        plugin_dir="$TARGET_PATH/.opencode/plugins"
        hooks_dir="$TARGET_PATH/.opencode/kurama/hooks"
    else
        plugin_dir="$home/.config/opencode/plugins"
        hooks_dir="$home/.config/opencode/kurama/hooks"
    fi

    if [ ! -f "$plugin_src" ]; then
        warn "OpenCode gate plugin not found: $plugin_src (skipped)"
        return 0
    fi

    mkdir -p "$plugin_dir" "$hooks_dir"

    dest="$plugin_dir/kurama-sdd-gates.ts"
    if [ -f "$dest" ]; then make_writable "$dest"; fi
    atomic_replace "$dest" < "$plugin_src"
    RECEIPT_FILES="$RECEIPT_FILES
$(receipt_rel "$dest")"

    # The gates themselves — the same bytes claude-code installs, so the two
    # harnesses can never decide differently. Executable: the plugin runs them.
    local installed=1
    for script in $OPENCODE_GATE_SCRIPTS; do
        if [ ! -f "$HOOKS_SRC/$script" ]; then
            warn "Missing gate script: $script — OpenCode enforcement will be degraded"
            continue
        fi
        dest="$hooks_dir/$script"
        if [ -f "$dest" ]; then make_writable "$dest"; fi
        atomic_replace "$dest" < "$HOOKS_SRC/$script"
        chmod +x "$dest" 2>/dev/null || true
        RECEIPT_FILES="$RECEIPT_FILES
$(receipt_rel "$dest")"
        installed=$((installed + 1))
    done

    ok "SDD gates installed → both run as mechanisms on OpenCode (write-guard + archive-gate)"
    info "$installed files → $plugin_dir and $hooks_dir (restart opencode to load the plugin)"
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
    # #22: the resolved mode is part of the install, not a transient prompt
    # answer — update.sh re-passes it, so record it as soon as it is known
    # (before any write, so even an aborted run's receipt carries it).
    RECEIPT_OPENCODE_MODE="$OPENCODE_MODE"

    # Resolve the profile now (before any merge) and snapshot the models of its
    # own agents from the pre-merge config. The base merge below removes every
    # "sdd-*" key — which includes a profile's suffixed subagents — so we must
    # capture their user-edited models here to restore them idempotently.
    ask_opencode_profile
    RECEIPT_OPENCODE_PROFILE="$OPENCODE_PROFILE"
    RECEIPT_OPENCODE_PROFILE_MODEL="$OPENCODE_PROFILE_MODEL"
    local profile_saved="{}"
    if [ "$OPENCODE_PROFILE" != "no" ] && [ -n "$OPENCODE_PROFILE" ] \
        && command -v jq &>/dev/null && [ -s "$config_file" ]; then
        profile_saved=$(jq -c --arg name "$OPENCODE_PROFILE" --arg re "$OPENCODE_MODEL_RE" '
            def isprof(k): (k == "kurama-orchestrator")
                or ((k|startswith("sdd-")) and (k|endswith("-" + $name)));
            reduce ((.agent // {}) | to_entries[]
                | select(isprof(.key))
                | select(.value.model | strings | test($re))) as $e
                ({}; . + {($e.key): $e.value.model})
        ' "$config_file") || profile_saved="{}"
        # jq prints nothing (rc 0) on an empty input; an empty snapshot is "{}".
        [ -n "$profile_saved" ] || profile_saved="{}"
    fi

    # Install commands
    if [ -d "$commands_src" ]; then
        mkdir -p "$commands_target"
        local count=0
        for cmd_file in "$commands_src"/sdd-*.md; do
            [ -f "$cmd_file" ] || continue
            local cmd_name
            cmd_name=$(basename "$cmd_file" .md)

            if [[ "$OPENCODE_MODE" == "multi" ]] && grep -q "^subtask:" "$cmd_file"; then
                # Multi mode: subtask commands point to their dedicated subagent.
                # The committed files say "agent: sdd-orchestrator" precisely so
                # this rewrite has something to match — and so single mode, which
                # copies them verbatim and defines no phase agents, routes to the
                # one agent it does define. They used to ship the phase name
                # already, which made this sed a no-op and left five single-mode
                # commands pointing at agents that did not exist.
                sed "s/^agent: sdd-orchestrator/agent: $cmd_name/" "$cmd_file" > "$commands_target/$(basename "$cmd_file")"
            else
                cp "$cmd_file" "$commands_target/"
            fi
            # #22: these are Kurama-owned files under a Kurama-owned name, so
            # they belong in files[] — without this, uninstall left all nine
            # /sdd-* commands wired to agents it had just deleted.
            RECEIPT_FILES="$RECEIPT_FILES
$(receipt_rel "$commands_target/$(basename "$cmd_file")")"
            count=$((count + 1))
        done
        ok "$count OpenCode commands installed ($OPENCODE_MODE mode)"
    fi

    # Merge opencode.json agent config (idempotent: replaces sdd-* agents, preserves user model choices).
    # Three states, decided explicitly instead of by `[ -f ]`: a config with real
    # content is merged into; an absent or blank one is created from the template
    # (feeding jq an empty input yields an empty result, which used to be written
    # straight over the file); one we cannot read stops the run — never clobber
    # what we cannot see.
    if command -v jq &>/dev/null && [ -f "$example_config" ]; then
        local config_state="create"
        if [ -e "$config_file" ]; then
            if [ ! -r "$config_file" ]; then
                fail "Cannot read $config_file — the SDD agents were NOT merged"
                info "Fix its permissions and re-run: ./setup.sh --agent opencode"
                exit 1
            fi
            if grep -q '[^[:space:]]' "$config_file"; then config_state="merge"; fi
        fi

        if [ "$config_state" = "merge" ]; then
            local example_agents
            example_agents=$(jq '.agent // {}' "$example_config")

            # Smart merge:
            # 1. Remove all existing sdd-* keys (clean slate for our agents)
            # 2. Preserve "model" field from existing sdd-* agents (user customization)
            # 3. Add new agent definitions, restoring preserved model fields
            # 4. Don't touch non-sdd agents
            #
            # kurama-orchestrator is a profile-only key (a mode:primary agent
            # whose task permission is scoped to sdd-*-NAME subagents). Those
            # subagents are sdd-* keys and are wiped here, so the orchestrator is
            # pruned alongside them to avoid leaving a primary that delegates to
            # agents that no longer exist. When a profile follows, install_
            # opencode_profile re-adds a fresh orchestrator (its model is
            # snapshotted separately before this merge, see profile_saved).
            local merged
            merged=$(jq --argjson new_agents "$example_agents" --arg re "$OPENCODE_MODEL_RE" '
                # 1. Capture existing model fields from sdd-* agents (user customization).
                #    Only real "provider/model-id" values are worth preserving — see
                #    OPENCODE_MODEL_RE. Anything else (notably the old
                #    "<your-provider/your-model>" literal) is dropped here so the agent
                #    falls back to the template, which now carries no "model" key at all
                #    and therefore inherits the OpenCode default model.
                (reduce ((.agent // {}) | to_entries[] |
                    select(.key | startswith("sdd-")) |
                    select(.value.model | strings | test($re))) as $e
                    ({}; . + {($e.key): $e.value.model})) as $saved_models |

                # 2. Remove all sdd-* agents (and the profile orchestrator), keep
                #    user custom agents, add new template agents
                .agent = (
                    ((.agent // {}) | with_entries(select(
                        ((.key | startswith("sdd-")) or (.key == "kurama-orchestrator")) | not)))
                    + $new_agents
                ) |

                # 3. Restore user model choices onto new agent definitions
                reduce ($saved_models | to_entries[]) as $m (.;
                    if .agent[$m.key] then .agent[$m.key].model = $m.value else . end
                ) |

                # 4. Clean up stale "agents" plural key
                del(.agents)
            ' "$config_file") || {
                # Without this guard jq's raw parse error was the only message and
                # jq's own exit code (5) became the installer's — after 25 skills
                # were already on disk. The EXIT trap in setup_agent records them.
                fail "Could not parse $config_file — the SDD agents were NOT merged"
                fail "opencode.json must be strict JSON: no comments, no trailing commas."
                info "Fix it (or move it aside) and re-run: ./setup.sh --agent opencode"
                info "Your config was left unchanged."
                exit 1
            }

            jq_merge_ok "$merged" || {
                fail "The agent merge produced no usable JSON — $config_file left unchanged"
                info "Re-run after checking $config_file; nothing was written."
                exit 1
            }

            printf '%s\n' "$merged" | atomic_replace --backup "$config_file"
            ok "Agent config merged into $config_file ($OPENCODE_MODE mode)"
        else
            mkdir -p "$(dirname "$config_file")"
            cp "$example_config" "$config_file"
            ok "Config created at $config_file ($OPENCODE_MODE mode)"
        fi
        # #22: record the config we just wrote our agent block into. NOT in
        # files[] — this file is the user's, and uninstall removes files[]
        # outright; opencode_configs[] means "strip Kurama's sdd-* agents from
        # it", which is the only reversal that keeps the user's own agents.
        RECEIPT_OPENCODE_CONFIGS="$RECEIPT_OPENCODE_CONFIGS
$(receipt_rel "$config_file")"
    else
        if ! command -v jq &>/dev/null; then
            warn "jq not found — cannot auto-merge opencode.json"
        fi
        warn "Merge manually: copy agent block from examples/opencode/opencode.${OPENCODE_MODE}.json"
        info "Into: $config_file"
    fi

    # Install the shared SDD phase prompt files. Both opencode.multi.json and any
    # named profile reference these via {file:./prompts/sdd/...} — a path relative
    # to the opencode.json that contains it, which is what upstream gentle-ai emits
    # (internal/components/sdd/prompts.go). The tilde form this used to carry came
    # from upstream's PRD prose, not its code, and nothing verifies that OpenCode
    # expands ~ inside {file:}. The relative form resolves because this flow is
    # global-only: the config lands in $home/.config/opencode/opencode.json and the
    # prompts in $home/.config/opencode/prompts/sdd/, one directory below it.
    local prompts_src="$EXAMPLES_DIR/opencode/prompts/sdd"
    local prompts_target="$home/.config/opencode/prompts/sdd"
    if [ -d "$prompts_src" ]; then
        mkdir -p "$prompts_target"
        local pcount=0 prompt_file
        for prompt_file in "$prompts_src"/sdd-*.md; do
            [ -f "$prompt_file" ] || continue
            cp "$prompt_file" "$prompts_target/"
            RECEIPT_FILES="$RECEIPT_FILES
$(receipt_rel "$prompts_target/$(basename "$prompt_file")")"
            pcount=$((pcount + 1))
        done
        ok "$pcount shared SDD prompt files installed -> $prompts_target"
    fi

    # The two deterministic gates (#90). OpenCode is the second harness where
    # they are mechanism rather than prose.
    install_opencode_gates

    # Optionally splice a named model profile (kurama-orchestrator + suffixed
    # sdd-<phase>-NAME subagents) into opencode.json. Resolved above; the base
    # merge just ran, so pass the pre-merge model snapshot for idempotency.
    if [ "$OPENCODE_PROFILE" != "no" ] && [ -n "$OPENCODE_PROFILE" ]; then
        install_opencode_profile "$config_file" "$profile_saved"
    fi

    # Install the orchestrator prompt every config template references through
    # {file:./AGENTS.md}. This used to be a wholesale `cp` of the example over
    # whatever the user had, which (a) destroyed a hand-written AGENTS.md with no
    # backup, (b) left no BEGIN:kurama markers — so doctor flagged every HEALTHY
    # OpenCode install as "orchestrator not merged?" (#23) — and (c) recorded
    # nothing, so uninstall left the ~22KB file behind (#22). Routing it through
    # the same setup_orchestrator every other harness uses fixes all three at
    # once: marker merge, backup, and a prompts[] entry uninstall strips.
    setup_orchestrator "$home/.config/opencode/AGENTS.md" \
        "$EXAMPLES_DIR/opencode/AGENTS.md" opencode

    # Remove the legacy background-agents.ts plugin if an earlier Kurama install
    # left one behind. This is a migration, not a cleanup nicety: the plugin
    # hangs the TUI, so leaving it in place keeps OpenCode unusable even after
    # the user upgrades Kurama.
    local legacy_plugin="$home/.config/opencode/plugins/background-agents.ts"
    if [ -f "$legacy_plugin" ]; then
        rm -f "$legacy_plugin"
        ok "removed legacy background-agents plugin → $legacy_plugin"
    fi

    # NOTE: the legacy background-agents.ts plugin is deliberately NOT installed.
    # Delegation runs on OpenCode's native sub-agents via the `task` permission,
    # which every SDD agent entry already carries. The plugin is third-party code
    # (kdcokenny/opencode-background-agents, itself based on oh-my-opencode) that
    # was observed hanging the OpenCode TUI at startup — a black screen with no
    # error on stdout or stderr. Upstream gentle-ai dropped it for the same
    # reason. Users who want background execution should use OpenCode's own
    # experimental switch instead, exported in their shell:
    #     export OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS=true
    # See docs/sub-agents.md.

    # Opt-in cosmetic: replace the TUI splash logo with the Kurama wordmark.
    if [ "$STARTUP_LOGO" = "yes" ]; then
        install_opencode_logo "$home"
    fi

    # No npm dependency is installed here. `unique-names-generator` existed only
    # to satisfy background-agents.ts; dropping the plugin also removes the need
    # to mutate the user's own ~/.config/opencode/package.json and node_modules.
}

# ============================================================================
# Startup logo (opt-in, cross-harness)
#
# The Kurama wordmark — the same art scripts/banner.sh prints — drawn by the
# agent itself at startup. Two harnesses can do it, through very different
# mechanisms, so there is ONE consent question (asked once per run) and one
# installer per harness:
#
#   opencode  a TUI plugin registering the host's `home_logo` slot, copied to
#             ~/.config/opencode/tui-plugins/ and listed in tui.json's plugin[].
#   pi        an extension exporting a session_start hook that calls
#             ctx.ui.setHeader(), dropped into the auto-discovered extensions dir
#             (no settings.json entry needed).
#
# Both artifacts are generated from assets/banner/wordmark.txt by
# scripts/gen-logo-plugin.mjs and committed under examples/.
# ============================================================================


# OpenCode: copy the committed .tsx into ~/.config/opencode/tui-plugins/ and
# register its absolute path in tui.json's plugin[] array.
#
# tui.json is a DIFFERENT registry from opencode.json — the latter lists SERVER
# plugins, while the TUI process reads only tui.json's plugin[] (npm names or
# absolute .tsx paths). The merge mirrors gentle-ai's ensureTUIPlugin: create the
# file with its $schema when absent, append our path only when missing, and
# preserve every existing entry. jq-only (never sed on JSON), backup + atomic.
install_opencode_logo() {
    local home="$1"
    local src="$EXAMPLES_DIR/opencode/tui-plugins/kurama-logo.tsx"
    local plugin_dir="$home/.config/opencode/tui-plugins"
    local dest="$plugin_dir/kurama-logo.tsx"
    local tui_file="$home/.config/opencode/tui.json"

    if [ ! -f "$src" ]; then
        warn "TUI logo plugin source not found: $src (skipped)"
        return 0
    fi
    if ! command -v jq &>/dev/null; then
        warn "jq not found — cannot register the Kurama logo in tui.json"
        info "Add \"$dest\" to the plugin[] array in $tui_file by hand"
        return 0
    fi

    mkdir -p "$plugin_dir"
    atomic_replace "$dest" < "$src"
    RECEIPT_FILES="$RECEIPT_FILES
$(receipt_rel "$dest")"

    local merged
    if [ -s "$tui_file" ]; then
        # A tui.json we cannot parse is the user's file, not ours — refuse to
        # overwrite it and say exactly what to add.
        if ! jq -e . "$tui_file" >/dev/null 2>&1; then
            warn "$tui_file is not valid JSON — leaving it untouched"
            info "Add \"$dest\" to its plugin[] array by hand"
            return 0
        fi
        merged=$(jq --arg p "$dest" '
            .plugin = ((.plugin // []) | if index($p) then . else . + [$p] end)
        ' "$tui_file") || { warn "Failed to merge $tui_file"; return 0; }
    else
        # Missing or empty: create it with the schema line opencode writes.
        mkdir -p "$(dirname "$tui_file")"
        merged=$(jq -n --arg p "$dest" \
            '{"$schema": "https://opencode.ai/tui.json", "plugin": [$p]}') \
            || { warn "Failed to create $tui_file"; return 0; }
    fi

    jq_merge_ok "$merged" \
        || { warn "TUI plugin registration produced no usable JSON — $tui_file left unchanged"; return 0; }

    printf '%s\n' "$merged" | atomic_replace --backup "$tui_file"
    RECEIPT_TUI_PLUGINS="$RECEIPT_TUI_PLUGINS
$(receipt_rel "$tui_file")"
    ok "Kurama logo TUI plugin installed → $dest"
    info "Registered in $tui_file (restart opencode to see it)"
}

# Pi: drop the committed extension into the auto-discovered extensions dir.
# Pi loads every ~/.pi/agent/extensions/*.ts (global) and .pi/extensions/*.ts
# (project-local), so there is no registry to merge and no settings.json to
# touch — copying the file IS the installation, which also makes it idempotent
# by construction. Recorded in the receipt so uninstall removes it again.
install_pi_logo() {
    local src="$EXAMPLES_DIR/pi/extensions/kurama-logo.ts"
    local ext_dir dest

    if [ ! -f "$src" ]; then
        warn "Pi logo extension source not found: $src (skipped)"
        return 0
    fi

    if [ "$SCOPE" = "project" ]; then
        ext_dir="$TARGET_PATH/.pi/extensions"
    else
        ext_dir="$(home_dir)/.pi/agent/extensions"
    fi
    dest="$ext_dir/kurama-logo.ts"

    mkdir -p "$ext_dir"
    atomic_replace "$dest" < "$src"
    RECEIPT_FILES="$RECEIPT_FILES
$(receipt_rel "$dest")"
    ok "Kurama logo extension installed → $dest"
    info "Pi auto-discovers it (restart pi to see it)"
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
    # Tolerate EOF (piped/closed stdin) under `set -e`: default to the safe NO.
    read -rp "  Install Pi packages? [y/N]: " pi_answer || pi_answer="N"
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

# Follow a symlink chain to the file it finally names, portably. macOS's stock
# readlink has no -f (that is a GNU coreutils extension), and the one place this
# matters is a Homebrew binary — which is ALWAYS a symlink into the Cellar. Bare
# `readlink` gives one hop, so the loop walks the chain, resolving each relative
# target against the directory of the link that carried it, and `pwd -P` collapses
# the result physically. Bounded at 32 hops so a symlink cycle terminates.
resolve_symlink_path() {
    local p="$1" hops=0 d t
    while [ -L "$p" ] && [ "$hops" -lt 32 ]; do
        d="$(dirname "$p")"
        t="$(readlink "$p")" || break
        case "$t" in
            /*) p="$t" ;;
            *)  p="$d/$t" ;;
        esac
        hops=$((hops + 1))
    done
    d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || { printf '%s' "$1"; return 0; }
    printf '%s/%s' "$d" "${p##*/}"
}

# Resolve the most stable engram command string, mirroring gentle-ai's
# resolveEngramCommand: prefer an absolute PATH hit, but collapse a Homebrew
# install back to bare "engram" (its Cellar path changes on every upgrade, and
# an absolute path in a PROJECT-scope .mcp.json/opencode.json is machine-specific
# in a file the team shares). Falls back to "engram" when the binary is not yet
# installed.
#
# #105: the Cellar match alone never fired. `command -v engram` returns the
# SYMLINK Homebrew puts on PATH — /opt/homebrew/bin/engram — never the Cellar
# path it points at, so every Homebrew install wrote the absolute path, and a
# field install committed /opt/homebrew/bin/engram into a shared .mcp.json and
# opencode.json. Both halves are checked now: the brew bin prefixes on the path
# as found, and the Cellar path it resolves to. Anything else keeps its absolute
# path on purpose — a GUI-launched client does not always inherit the shell PATH,
# and outside brew there is no stable bare name to fall back on.
engram_command() {
    local p resolved
    if p="$(command -v engram 2>/dev/null)" && [ -n "$p" ]; then
        case "$p" in
            */homebrew/bin/engram|*/linuxbrew/*/bin/engram|*/Cellar/engram/*)
                echo "engram"; return 0 ;;
        esac
        resolved="$(resolve_symlink_path "$p")"
        case "$resolved" in
            */Cellar/engram/*) echo "engram"; return 0 ;;
        esac
        echo "$p"
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
        ENGRAM_MCP_NO_JQ=$((ENGRAM_MCP_NO_JQ + 1))
        return 0
    fi

    local input merged
    input="$(read_json_for_merge "$file")" \
        || { fail "Cannot read $file — Engram MCP left unregistered"; return 1; }

    merged=$(
        printf '%s\n' "$input" | \
        jq --arg cmd "$cmd" "$jq_prog"
    ) || { fail "Failed to register Engram MCP in $file (left unchanged)"; return 1; }

    jq_merge_ok "$merged" \
        || { fail "Engram registration produced no usable JSON — $file left unchanged"; return 1; }

    printf '%s\n' "$merged" | atomic_replace --backup "$file"
    ok "Engram MCP registered → $file"
    RECEIPT_ENGRAM_MCP="$RECEIPT_ENGRAM_MCP
$(receipt_rel "$file")"
    ENGRAM_MCP_WRITTEN=$((ENGRAM_MCP_WRITTEN + 1))
}

# Codex uses TOML, not JSON. Upsert the [mcp_servers.engram] block: strip any
# existing block (up to the next section header or EOF) then append a fresh one.
# Backup + atomic, recorded in the receipt. jq never touches this file.
register_engram_codex() {
    local file="$1" cmd="$2"
    mkdir -p "$(dirname "$file")"

    local existing="" stripped
    if [ -f "$file" ]; then
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
    } | atomic_replace --backup "$file"
    ok "Engram MCP registered → $file (codex TOML)"
    RECEIPT_ENGRAM_MCP="$RECEIPT_ENGRAM_MCP
$(receipt_rel "$file")"
    ENGRAM_MCP_WRITTEN=$((ENGRAM_MCP_WRITTEN + 1))
}

# Register the Engram MCP server for one client, replicating gentle-ai's exact
# per-client shapes (inject.go). Pi needs nothing extra — the Pi package stack
# (gentle-engram) already provides Engram there.
# shellcheck disable=SC2016  # The jq filters below reference $cmd, a JQ variable bound
# via --arg by engram_merge_json. Single quotes are required: expanding it in bash would
# inline the path into the filter and break jq's own quoting.
register_engram_mcp() {
    local agent="$1" cmd file home
    cmd="$(engram_command)"
    home="$(home_dir)"

    case "$agent" in
        pi)
            info "Engram on Pi is provided by the Pi package stack (gentle-engram) — no extra MCP registration needed."
            ENGRAM_MCP_BUILTIN=$((ENGRAM_MCP_BUILTIN + 1))
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
        codex)
            if [ "$SCOPE" = "project" ]; then
                info "Codex uses a single global MCP config; skipping Engram registration for project scope."
                info "Run: ./setup.sh --agent codex --with-engram   (global) to register it."
                ENGRAM_MCP_DEFERRED=$((ENGRAM_MCP_DEFERRED + 1))
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

# EXIT trap installed by setup_agent. finalize_receipt is the LAST step of a
# successful run, so anything that aborted in between — a jq failure on a config
# the user broke, a `read` hitting EOF, a full disk — used to leave a ghost
# install: dozens of files on disk that no receipt records, invisible to
# uninstall ("nothing recorded — skipping") and update ("No receipt … nothing to
# update"). The trap flushes the accumulators no matter how setup_agent leaves,
# and on a non-zero exit says how to reverse or retry.
finalize_receipt_on_exit() {
    local status=$?
    trap - EXIT
    finalize_receipt
    if [ "$status" -ne 0 ] && [ -n "$RECEIPT_DIR" ]; then
        local undo="--agent $RECEIPT_TOOL"
        [ "$SCOPE" = "project" ] && undo="--scope project --path $TARGET_PATH"
        echo ""
        fail "Setup aborted (exit $status) — a PARTIAL install is on disk."
        info "It is recorded in: $RECEIPT_DIR/$INSTALL_MANIFEST_NAME"
        info "Remove it with:    $SCRIPT_DIR/uninstall.sh $undo"
        info "Or fix the cause and re-run this command — setup is idempotent."
    fi
    exit "$status"
}

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
    RECEIPT_GITIGNORE=""
    RECEIPT_TUI_PLUGINS=""
    RECEIPT_OPENCODE_CONFIGS=""
    RECEIPT_OPENCODE_MODE=""
    RECEIPT_OPENCODE_PROFILE=""
    RECEIPT_OPENCODE_PROFILE_MODEL=""
    RECEIPT_DIR=""

    # From here on every abort still writes a receipt (see finalize_receipt_on_exit).
    trap finalize_receipt_on_exit EXIT

    install_skills "$agent"

    local prompt_path example_file
    prompt_path="$(scoped_prompt_path "$agent")"
    example_file="$(get_example_file "$agent")"

    if [[ "$agent" == "opencode" ]]; then
        # OpenCode's dedicated flow is global-only; project scope still gets its
        # skills + receipt above, the orchestrator merge below, and — since #90 —
        # the two deterministic gates, which are the one OpenCode asset a repo
        # install must not silently go without.
        if [ "$SCOPE" = "project" ]; then
            setup_orchestrator "$prompt_path" "$EXAMPLES_DIR/pi/AGENTS.md" "$agent"
            install_opencode_gates
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

    # N5: offer the Pi package stack only for the Pi target, plus the same
    # flag-gated startup logo the OpenCode flow installs (Pi draws it as its
    # startup header).
    if [[ "$agent" == "pi" ]]; then
        if [ "$STARTUP_LOGO" = "yes" ]; then
            install_pi_logo
        fi
        setup_pi_packages
    fi

    # O5: Engram optional persistence engine — asked once, then the MCP server is
    # registered into this client (unless declined, in which case markdown
    # persistence stays the default and is noted in the summary). Non-fatal for
    # the same reason as the hooks merge: the install is already on disk.
    setup_engram "$agent" \
        || warn "Engram registration did not complete — the rest of the install stands"

    # #105: name the machine-local files in the target repo's .gitignore. Runs
    # LAST among the writers and BEFORE finalize_receipt, so the block reflects
    # every harness this receipt knows about (the `pi`-only `.atl/` line) and the
    # entry reaches the receipt uninstall drives its strip from. Non-fatal for
    # the same reason as the hooks merge: the install is already on disk.
    ensure_machine_local_gitignore \
        || warn "The machine-local .gitignore block was not written — the rest of the install stands"

    # Flush the single per-agent receipt (skills + agents + hooks + settings +
    # pi packages + engram MCP) now that every step has recorded its writes.
    # Disarm FIRST: with the trap still armed, a finalize_receipt that fails
    # (unwritable receipt dir, full disk) would re-enter the handler and run the
    # very same failing write a second time, replacing the real exit status with
    # the second attempt's.
    trap - EXIT
    finalize_receipt
}

# ============================================================================
# #106: the project skill registry
#
# .kurama/skill-registry.md is the ONLY resolution surface for the
# `## Project Standards (skills to load)` block every delegation carries — with
# no registry, skill-resolver.md's step 4 fires and every phase runs blind to the
# repo's conventions. It used to be built by a sub-agent: 12-13 minutes and
# 45 KB in a real repo, 63% of it per-skill summaries #82 had already demoted to
# an opt-in fallback. It is now skills/_shared/build-skill-registry.sh, and an
# install is exactly the moment to run it: the set of installed skills just
# changed by definition.
#
# Only a NAMED target is ever built. TARGET_PATH is the validated repo root in
# project scope and empty in a plain global install, so a global run never writes
# .kurama/ into whatever directory the user happened to be standing in. The
# script keeps its own root guard (never / or $HOME, and a project marker
# required) on top of that, and reports a refusal as exit 0.
#
# There is deliberately no model-scan fallback anywhere: a missing builder is a
# broken install, so say so here rather than silently shipping a target whose
# every delegation will run without project standards.
# ============================================================================
SKILL_REGISTRY_LINE=""

refresh_skill_registry() {
    local builder="$SKILLS_SRC/_shared/build-skill-registry.sh"
    [ -n "$TARGET_PATH" ] || return 0

    if [ ! -f "$builder" ]; then
        warn "skills/_shared/build-skill-registry.sh is missing — no skill registry was built"
        info "Sub-agent delegations will run WITHOUT project standards until it is."
        info "Re-clone Kurama and re-run this command; doctor.sh reports the same finding."
        SKILL_REGISTRY_LINE="missing"
        return 0
    fi

    local out status=0
    out="$(bash "$builder" --root "$TARGET_PATH" 2>&1)" || status=$?
    if [ "$status" -ne 0 ]; then
        warn "The skill registry could not be built for $TARGET_PATH — the rest of the install stands"
        printf '%s\n' "$out" | awk 'NF { print "      " $0 }'
        SKILL_REGISTRY_LINE="failed"
        return 0
    fi

    if [ -f "$TARGET_PATH/.kurama/skill-registry.md" ]; then
        ok "${out:-skill registry written}"
        SKILL_REGISTRY_LINE="$out"
    elif [ -n "$out" ]; then
        # The builder's own root guard refused the target and said why.
        info "$out"
    fi
    return 0
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

    # #105: one line about the machine-local block, in project scope only — the
    # one moment someone is looking at what the install just did to their repo.
    case "$GITIGNORE_STATUS" in
        created|added|updated)
            echo -e "  ${GREEN}✓${NC} ${BOLD}.gitignore${NC}: Kurama block added ($GITIGNORE_PATTERNS patterns)" ;;
        present)
            echo -e "  ${GREEN}✓${NC} ${BOLD}.gitignore${NC}: Kurama block already present ($GITIGNORE_PATTERNS patterns)" ;;
        nogit)
            echo -e "  ${YELLOW}!${NC} ${BOLD}.gitignore${NC}: not a git repo — skipped" ;;
        unbalanced|failed)
            echo -e "  ${YELLOW}!${NC} ${BOLD}.gitignore${NC}: Kurama block NOT written — see the note above" ;;
    esac

    # #106: the skill registry the delegations resolve from. Named here for the
    # same reason as the .gitignore line — it is the one moment somebody is
    # looking at what the install just produced.
    case "$SKILL_REGISTRY_LINE" in
        ""|missing|failed) ;;
        *) echo -e "  ${GREEN}✓${NC} ${BOLD}Skill registry${NC}: ${SKILL_REGISTRY_LINE#skill-registry: }" ;;
    esac
    case "$SKILL_REGISTRY_LINE" in
        missing|failed)
            echo -e "  ${YELLOW}!${NC} ${BOLD}Skill registry${NC}: NOT built — delegations will run without project standards" ;;
    esac

    # #101: a prompt file that already carried the project's own workflow. Named
    # again here because the merge-time notice is 200 lines up the scrollback by
    # the time the run ends, and position is exactly what this issue is about.
    if [ -n "$(printf '%s' "$WORKFLOW_NOTICE_FILES" | awk 'NF')" ]; then
        echo ""
        echo -e "  ${YELLOW}!${NC} ${BOLD}Two workflows now live in one file${NC} — the project's own instructions take precedence:"
        printf '%s\n' "$WORKFLOW_NOTICE_FILES" | awk 'NF && !seen[$0]++ { print "      " $0 }'
        echo -e "      Run ${CYAN}/sdd-init${NC}: it asks how the two should coexist and records the answer."
    fi

    echo ""
    echo -e "${GREEN}${BOLD}Done!${NC} Start using SDD: open any project and type ${CYAN}/sdd-init${NC}"
    echo ""
    # O5: persistence-engine status. When Engram is enabled we confirm it (and
    # nudge to install the binary if it is not yet on PATH); when declined we tell
    # the user the harness runs on its built-in markdown persistence.
    if [ "${ENGRAM:-no}" = "yes" ]; then
        # #70: report what the run actually did, not what it intended. Without jq
        # the MCP merge degrades to printed manual steps and writes nothing, so
        # claiming "registered per client" here was a lie the receipt contradicted.
        # jq-missing leads, because it is the only outcome the user must act on;
        # pi (package stack) and codex-in-project-scope are by design, not faults.
        if [ "$ENGRAM_MCP_NO_JQ" -gt 0 ]; then
            echo -e "${YELLOW}Engram:${NC} enabled, but the MCP server was ${BOLD}NOT registered${NC} for $ENGRAM_MCP_NO_JQ client(s) — jq is missing."
            echo -e "  Kurama never edits JSON without jq. Apply the manual steps printed above,"
            echo -e "  or install jq and re-run this command to register it automatically."
        elif [ "$ENGRAM_MCP_WRITTEN" -gt 0 ]; then
            echo -e "${GREEN}Engram:${NC} enabled as the persistence engine (MCP registered per client)."
        elif [ "$ENGRAM_MCP_BUILTIN" -gt 0 ]; then
            echo -e "${GREEN}Engram:${NC} enabled as the persistence engine (provided by the agent's own package stack — no MCP entry needed)."
        elif [ "$ENGRAM_MCP_DEFERRED" -gt 0 ]; then
            echo -e "${YELLOW}Engram:${NC} enabled, but no MCP server was registered in this scope — see the note above."
        else
            echo -e "${YELLOW}Engram:${NC} enabled, but ${BOLD}no MCP registration was recorded${NC} — see the messages above."
        fi
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
# Interactive front-end (issue #40)
# ============================================================================
#
# setup.sh no longer carries its own text menu: the TUI (setup-tui.sh) is the one
# interactive experience, and the in-script prompt-and-select flow was removed to
# stop three front-ends drifting apart. A bare, interactive `./setup.sh` now hands
# off to the TUI when gum is available. When gum is not — and setup.sh does not
# install gum, so a TUI cannot be conjured — there is nothing to fall back to but
# the flags. Print them and exit non-zero; NEVER half-install a guessed default.
print_interactive_unavailable() {
    echo ""
    warn "Interactive setup needs gum, and gum is not installed."
    echo ""
    info "gum is optional (https://github.com/charmbracelet/gum). Install it for the guided TUI:"
    echo "    macOS  : brew install gum"
    echo "    Linux  : https://github.com/charmbracelet/gum#installation"
    echo ""
    info "Or specify the run on the command line — no gum required:"
    echo "    ./setup.sh --all                 # every detected agent"
    echo "    ./setup.sh --agent NAME          # one agent: claude-code, opencode, codex, pi, omp"
    echo "    ./setup.sh --non-interactive     # no prompts (for external installers)"
    echo "    ./setup.sh --help                # every flag"
    echo ""
}

# ============================================================================
# Main
# ============================================================================

detect_os
setup_colors

# The banner is drawn LATER, once a run is fully specified (after arg parsing).
# A bare interactive invocation hands off to setup-tui.sh, which draws its own
# banner — drawing one here too would paint the fox twice.

# Parse arguments
AGENT=""
ALL=false
NON_INTERACTIVE=false
OPENCODE_MODE=""  # "", "single", or "multi"
OPENCODE_PROFILE=""        # "" = unset (ask); "no" = none; otherwise the profile NAME
OPENCODE_PROFILE_MODEL=""  # optional provider/model applied to every profile agent
STARTUP_LOGO=""            # "yes" (via --with-logo) installs the Kurama startup logo; anything else skips it. Never prompted for — the default install stays clean.
PI_PACKAGES=""    # "", "yes", or "no" — controls the N5 Pi package stack
ENGRAM=""         # "", "yes", or "no" — O5 Engram persistence engine
# Run-shaping flags seen on this invocation that the interactive TUI hand-off
# (issue #40) cannot forward — it takes NO arguments and asks its own questions.
# An underspecified run (no --agent/--all) carrying any of these is REFUSED rather
# than silently honoring nothing. --agent/--all/--non-interactive/--help are not
# blockers and are never appended here.
HANDOFF_BLOCKED_FLAGS=()

# Every value-taking flag goes through this first: under `set -u` a bare
# `--agent` at the end of the line used to abort with a raw
# "setup.sh: line NNN: $2: unbound variable" instead of naming the flag.
require_flag_value() {
    local flag="$1" value="${2:-}"
    if [ -z "$value" ]; then
        echo "Missing value for $flag"
        echo "Run: setup.sh --help"
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)
            # Validate against the supported set. Without this an unknown slug
            # falls through every path-resolution case, yielding an empty target
            # and a bare `mkdir: : No such file or directory` — which is exactly
            # what a stale `--agent gemini-cli|cursor|vscode|antigravity` in a
            # script or CI job now produces. Fail here, by name, instead.
            require_flag_value --agent "${2:-}"
            case "$2" in
                claude-code|opencode|codex|pi|omp) AGENT="$2"; shift 2 ;;
                *)
                    echo "Unknown agent: $2"
                    echo "Supported: claude-code, opencode, codex, pi, omp"
                    exit 1
                    ;;
            esac
            ;;
        --all)            ALL=true; shift ;;
        --non-interactive) NON_INTERACTIVE=true; ALL=true; shift ;;
        --scope)
            HANDOFF_BLOCKED_FLAGS+=("--scope")
            require_flag_value --scope "${2:-}"
            case "$2" in
                global|project) SCOPE="$2"; shift 2 ;;
                *) echo "Invalid scope: $2 (use 'global' or 'project')"; exit 1 ;;
            esac
            ;;
        --path)           HANDOFF_BLOCKED_FLAGS+=("--path"); require_flag_value --path "${2:-}"; TARGET_PATH="$2"; shift 2 ;;
        --with-pi-packages)    HANDOFF_BLOCKED_FLAGS+=("--with-pi-packages");    PI_PACKAGES="yes"; shift ;;
        --without-pi-packages) HANDOFF_BLOCKED_FLAGS+=("--without-pi-packages"); PI_PACKAGES="no"; shift ;;
        --with-engram)         HANDOFF_BLOCKED_FLAGS+=("--with-engram");         ENGRAM="yes"; shift ;;
        --without-engram)      HANDOFF_BLOCKED_FLAGS+=("--without-engram");      ENGRAM="no"; shift ;;
        --with)    HANDOFF_BLOCKED_FLAGS+=("--with");    require_flag_value --with "${2:-}";    setup_validate_group_name "$2"; setup_enable_group "$2"; shift 2 ;;
        --without) HANDOFF_BLOCKED_FLAGS+=("--without"); require_flag_value --without "${2:-}"; setup_validate_group_name "$2"; setup_disable_group "$2"; shift 2 ;;
        --opencode-mode)
            HANDOFF_BLOCKED_FLAGS+=("--opencode-mode")
            require_flag_value --opencode-mode "${2:-}"
            if [[ "$2" == "single" || "$2" == "multi" ]]; then
                OPENCODE_MODE="$2"; shift 2
            else
                echo "Invalid opencode mode: $2 (use 'single' or 'multi')"; exit 1
            fi
            ;;
        --opencode-profile)
            # Grammar: NAME[:provider/model]. Split on the FIRST colon so the
            # model's own "/" survives; an empty NAME defaults to "kurama".
            HANDOFF_BLOCKED_FLAGS+=("--opencode-profile")
            require_flag_value --opencode-profile "${2:-}"
            _prof_val="$2"
            _prof_name="${_prof_val%%:*}"
            _prof_rest="${_prof_val#*:}"
            if [ "$_prof_val" = "$_prof_rest" ]; then _prof_rest=""; fi
            [ -n "$_prof_name" ] || _prof_name="kurama"
            if ! printf '%s' "$_prof_name" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
                echo "Invalid opencode profile name: $_prof_name (lowercase letters, digits, dashes)"; exit 1
            fi
            OPENCODE_PROFILE="$_prof_name"
            OPENCODE_PROFILE_MODEL="$_prof_rest"
            shift 2
            ;;
        --with-logo)    HANDOFF_BLOCKED_FLAGS+=("--with-logo");    STARTUP_LOGO="yes"; shift ;;
        --without-logo) HANDOFF_BLOCKED_FLAGS+=("--without-logo"); STARTUP_LOGO="no"; shift ;;
        -h|--help)
            echo "Usage: setup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all                  Auto-detect and install for all found agents"
            echo "  --agent NAME           Install for a specific agent: claude-code, opencode, codex, pi, omp"
            echo "  --scope SCOPE          Install scope: 'global' (default) or 'project'"
            echo "  --path DIR             Target repo for --scope project (default: cwd; must be a git repo)"
            echo "  --opencode-mode M      OpenCode agent mode: 'single' or 'multi' (per-phase models)"
            echo "  --opencode-profile P   Install a named model profile: NAME[:provider/model] (Tab-switchable)"
            echo "  --with-logo            Draw the Kurama wordmark at agent startup (opencode TUI splash, Pi header)"
            echo "  --without-logo         Keep each agent's own startup logo (this is the default; the logo is never installed unless --with-logo is passed)"
            echo "  --with-pi-packages     Install the Pi package stack (--agent pi, non-interactive)"
            echo "  --without-pi-packages  Skip the Pi package stack (--agent pi, non-interactive)"
            echo "  --with-engram          Use Engram as the persistence engine (register its MCP)"
            echo "  --without-engram       Keep the built-in markdown persistence (default)"
            echo "  --with GROUP           Include an optional skill group (quality, review, optional, tdd, lang)"
            echo "  --without GROUP        Exclude an on-by-default skill group (quality, review, optional, tdd)"
            echo "  --non-interactive      No prompts (for external installers)"
            echo "  -h, --help             Show this help"
            echo ""
            echo "Agents: claude-code, opencode, codex, pi, omp"
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

# --path only makes sense with project scope. Checked BEFORE the TUI hand-off
# (issue #40 review I1) so `./setup.sh --path DIR` still errors here rather than
# being swallowed by the interactive branch below.
if [ -n "$TARGET_PATH" ] && [ "$SCOPE" != "project" ]; then
    echo "--path requires --scope project"; exit 1
fi

# ---------------------------------------------------------------------------
# Interactive front-end: hand off to the TUI (issue #40)
# ---------------------------------------------------------------------------
# A run that names neither --agent nor --all/--non-interactive is not a fully
# specified run. setup.sh no longer prompts for the missing pieces itself — the
# in-script text menu was removed so the three front-ends stop drifting apart,
# and the TUI (setup-tui.sh) is now the one interactive experience. Delegate to
# it when gum is present (it draws its own banner and re-invokes this script per
# choice with explicit flags, so we never recurse into this branch). When gum is
# absent, setup.sh cannot install it, so a TUI is impossible: print the flag
# guide and exit 2 rather than half-install a guessed default.
if [[ -z "$AGENT" ]] && ! $ALL; then
    # The hand-off passes NO arguments and the TUI asks its own questions, so any
    # run-shaping flag given here would be silently dropped (review I1) — e.g.
    # `--without review` would install review anyway, contradicting the flag.
    # Refuse instead of honoring nothing: name the flags and point at the two ways
    # to make them apply — a concrete target, or a non-interactive run.
    if [ "${#HANDOFF_BLOCKED_FLAGS[@]}" -gt 0 ]; then
        echo ""
        fail "These flags need an explicit target and cannot be forwarded to the interactive TUI:"
        fail "  ${HANDOFF_BLOCKED_FLAGS[*]}"
        info "Name the target so they apply: add --agent <name> (or --all),"
        info "or re-run non-interactively (./setup.sh --non-interactive …) with those flags."
        exit 2
    fi
    if command -v gum >/dev/null 2>&1; then
        exec bash "$SCRIPT_DIR/setup-tui.sh"
    fi
    print_interactive_unavailable
    exit 2
fi

# A run is fully specified from here (--agent, or --all/--non-interactive). Draw
# the banner once — the interactive path above never reaches this line, so the
# TUI's own banner is the only one shown on that path.
if ! print_banner; then
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║    Kurama — Full Setup          ║${NC}"
    echo -e "${CYAN}${BOLD}║   Detect • Install • Configure            ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${NC}"
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
# examples/ is not optional and its absence must FAIL LOUD before any write (#41):
# the OpenCode target installs its /sdd-* command files from it, and every target's
# orchestrator merge reads a prompt file under it. Without this, a checkout with
# skills/ but no examples/ warns per-source, skips the commands, still prints "Done!"
# and writes a receipt for a PARTIAL install — exit 0 where it must be exit 1. Ported
# from install.sh's validate_source when the two installers collapsed (#38).
if [ ! -d "$EXAMPLES_DIR" ]; then
    fail "Missing: examples/ (agent configs and the OpenCode /sdd-* commands)"
    fail "Is this a complete clone? git clone https://github.com/myst4/kurama.git"
    exit 1
elif [ ! -d "$EXAMPLES_DIR/opencode/commands" ]; then
    fail "Missing: examples/opencode/commands (the OpenCode /sdd-* command files)"
    fail "Is this a complete clone? git clone https://github.com/myst4/kurama.git"
    exit 1
fi
# skills/_shared is not optional either and must FAIL LOUD before any write (#41):
# every target installs the shared conventions and all 20 default SKILL.md files
# reference _shared/*. install_skills only copies it behind `if [ -d "$shared_src" ]`,
# so a clone with skills/ but no _shared/ silently skips it, still prints "Done!" and
# writes a receipt for a PARTIAL install pointing at conventions that are not there —
# exit 0 where it must be exit 1. This is install.sh's pre-#38 validate_source check
# (`[ ! -d "$SKILLS_SRC/_shared" ]`), dropped when the two installers collapsed (#38)
# alongside the examples/ check above.
if [ ! -d "$SKILLS_SRC/_shared" ]; then
    fail "Missing: skills/_shared (the shared conventions every skill references)"
    fail "Is this a complete clone? git clone https://github.com/myst4/kurama.git"
    exit 1
fi

if [[ -n "$AGENT" ]]; then
    # Single agent mode
    setup_agent "$AGENT"
    INSTALLED_AGENTS+=("$AGENT")
else
    # --all / --non-interactive: auto-detect + install all. (The interactive,
    # no-flags case was handled above by the TUI hand-off, so it never reaches
    # here; $ALL is the only remaining possibility.)
    detect_agents
    # Guard the expansion: on bash 3.2 (macOS stock) "${arr[@]}" of an empty
    # array trips `set -u`. This is the --all/--non-interactive zero-agents path.
    if [ "${#DETECTED_AGENTS[@]}" -gt 0 ]; then
        for agent in "${DETECTED_AGENTS[@]}"; do
            setup_agent "$agent"
            INSTALLED_AGENTS+=("$agent")
        done
    fi
fi

if [[ ${#INSTALLED_AGENTS[@]} -gt 0 ]]; then
    # #106: build the skill registry ONCE, after every harness has landed — the
    # scan reads the skills dirs, so running it per agent would rebuild the same
    # file N times from a tree that only stops moving here.
    refresh_skill_registry
    show_summary
else
    echo ""
    warn "No agents were set up."
fi
