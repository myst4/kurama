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

# home_dir / read_version / hash_file and the receipt parser now live in
# scripts/lib/receipt.sh (issue #37), sourced above.

# Short commit SHA of the current Kurama repo checkout ('' when git is
# unavailable). Historical name; delegates to the shared read_commit.
repo_commit() { read_commit; }

# Render "version (commit)", collapsing to just "version" when no commit is known.
fmt_ver_commit() {
    local v="$1" c="$2"
    if [ -n "$c" ]; then printf '%s (%s)' "$v" "$c"; else printf '%s' "$v"; fi
}

# ============================================================================
# Path + receipt helpers (mirror setup.sh)
# ============================================================================

# Global skills dir for a harness — the shared skills_path() map (issue #37).
global_skills_path() {
    skills_path "$1" global
}

# Map a receipt "tool" value to the canonical agent slug setup.sh accepts.
# setup.sh-written receipts already store the slug (e.g. "claude-code"), but
# install.sh-written receipts store the human DISPLAY name (e.g. "Claude Code").
# Those embedded spaces would otherwise word-split the re-sync command into a
# bogus --agent token (setup.sh: "Unknown option: Code"), aborting the update and
# leaving the receipt un-re-stamped. Recognized slugs pass through unchanged; an
# unknown value yields the empty string so the caller fails loudly instead of
# mis-invoking setup.sh. Receipts from dropped harnesses (gemini-cli, cursor,
# vscode, antigravity) land here too and correctly fail loudly.
tool_to_slug() {
    case "$1" in
        claude-code|"Claude Code")   echo "claude-code" ;;
        opencode|"OpenCode")         echo "opencode" ;;
        codex|"Codex")               echo "codex" ;;
        pi|"Pi")                     echo "pi" ;;
        omp)                         echo "omp" ;;
        *)                           echo "" ;;
    esac
}

# Set by check_orphans when it finds anything, so the caller can tell "nothing is
# installed" (a clean machine) from "unmanaged artifacts" (a broken one).
ORPHANS_FOUND=false

# Locations check_orphans has already inspected in this run. Several harnesses
# share one location — in project scope claude-code, codex and opencode all
# resolve to <repo>/.claude/skills, and claude-code and codex share
# <repo>/CLAUDE.md — so a per-agent scan would report the same artifact once per
# harness that maps to it: four real problems printed as "8 failure(s)". Dedup by
# RESOLVED PATH, exactly as check_markers does for prompt files.
ORPHANS_SEEN=""

# True (and remembers the path) the FIRST time a path is offered; false after.
orphan_first_sight() {
    local path="$1"
    [ -n "$path" ] || return 1
    printf '%s\n' "$ORPHANS_SEEN" | grep -Fxq -- "$path" && return 1
    ORPHANS_SEEN="$ORPHANS_SEEN
$path"
    return 0
}

# Where each harness keeps the artifacts a receipt would have recorded. Mirrors
# setup.sh's scoped_* resolution; an empty answer means the harness ships none of
# that kind (codex has no native agents, only two harnesses have command files).
orphan_skills_dir() {
    local agent="$1" scope="$2" base="$3"
    if [ "$scope" = "project" ]; then
        case "$agent" in
            pi)  echo "$base/.pi/skills" ;;
            omp) echo "$base/.omp/skills" ;;
            *)   echo "$base/.claude/skills" ;;
        esac
    else
        global_skills_path "$agent"
    fi
}

orphan_agents_dir() {
    local agent="$1" scope="$2" base="$3" home; home="$(home_dir)"
    if [ "$scope" = "project" ]; then
        case "$agent" in
            claude-code) echo "$base/.claude/agents" ;;
            pi)          echo "$base/.pi/agents" ;;
            omp)         echo "$base/.omp/agents" ;;
            *)           echo "" ;;
        esac
    else
        case "$agent" in
            claude-code) echo "$home/.claude/agents" ;;
            pi)          echo "$home/.pi/agent/agents" ;;
            omp)         echo "${PI_CODING_AGENT_DIR:-$home/.omp/agent}/agents" ;;
            *)           echo "" ;;
        esac
    fi
}

orphan_commands_dir() {
    local agent="$1" scope="$2" home; home="$(home_dir)"
    # Command files are a global-scope artifact only.
    if [ "$scope" = "project" ]; then echo ""; return 0; fi
    case "$agent" in
        claude-code) echo "$home/.claude/commands" ;;
        opencode)    echo "$home/.config/opencode/commands" ;;
        *)           echo "" ;;
    esac
}

# No receipt does not automatically mean "nothing installed". Kurama artifacts can
# survive on disk with the receipt gone — a hand-moved skills dir, a partial
# migration, an interrupted uninstall. That state is worse than a clean absence:
# the agents and commands are still wired and still route work, but they reference
# skill files that may no longer be there, and update.sh/uninstall.sh cannot manage
# what no receipt records. Reporting "healthy" for it is a false green, so any
# orphan found here is a failure with the exact paths to look at.
#
# #23: this runs PER AGENT that lacks a receipt, for all five harnesses. It used
# to run only when NOT ONE of the five had a receipt, and to look only at
# claude-code paths — so a machine with claude-code's receipt deleted and
# opencode's intact was diagnosed as opencode, exited 0 "Healthy", and never
# mentioned the ~/.claude agents, hooks and settings block still fully wired.
check_orphans() {
    local agent="$1" scope="${2:-global}" base="${3:-}"
    local found=false f n
    local skills_dir agents_dir cmds_dir prompt hooks_dir cfg

    skills_dir="$(orphan_skills_dir "$agent" "$scope" "$base")"
    agents_dir="$(orphan_agents_dir "$agent" "$scope" "$base")"
    cmds_dir="$(orphan_commands_dir "$agent" "$scope")"
    prompt="$(prompt_path_for "$agent" "$scope" "$base")"

    # Kurama-owned native agents (sdd-* / jd-*) wired with no receipt behind them.
    n=0
    if [ -n "$agents_dir" ] && [ -d "$agents_dir" ] && orphan_first_sight "$agents_dir"; then
        for f in "$agents_dir"/sdd-*.md "$agents_dir"/jd-*.md; do
            [ -f "$f" ] || continue
            n=$((n + 1))
        done
    fi
    if [ "$n" -gt 0 ]; then
        found=true
        bad "$n Kurama agent(s) in $agents_dir with no install receipt"
        # The agents read their phase skill at launch; a missing skills dir means
        # every delegation silently runs without its phase instructions.
        if [ -n "$skills_dir" ] && [ ! -d "$skills_dir/sdd-init" ]; then
            bad "  agents reference $skills_dir/sdd-*/SKILL.md — that path does not exist"
            for f in "$(dirname "$skills_dir")"/skills-*backup*; do
                [ -d "$f" ] || continue
                bad "  skills appear to have been moved to $(basename "$f")"
                break
            done
        fi
    fi

    # Skills still on disk with nothing recording them: update.sh cannot refresh
    # them and uninstall.sh will not remove them.
    if [ -n "$skills_dir" ] && [ -d "$skills_dir/sdd-init" ] && orphan_first_sight "$skills_dir"; then
        found=true
        bad "Kurama skills in $skills_dir with no install receipt"
    fi

    if [ -n "$cmds_dir" ] && [ -d "$cmds_dir" ] && orphan_first_sight "$cmds_dir"; then
        n=0
        for f in "$cmds_dir"/sdd-*.md; do
            [ -f "$f" ] || continue
            n=$((n + 1))
        done
        if [ "$n" -gt 0 ]; then
            found=true
            bad "$n Kurama command(s) in $cmds_dir with no install receipt"
        fi
    fi

    # An orchestrator block still merged into a shared prompt file: it keeps
    # steering the agent, and no receipt records it for removal.
    if [ -n "$prompt" ] && [ -f "$prompt" ] && orphan_first_sight "$prompt" \
        && grep -qF 'BEGIN:kurama' "$prompt" 2>/dev/null; then
        found=true
        bad "kurama orchestrator block still merged into $prompt with no install receipt"
    fi

    if [ "$agent" = "claude-code" ]; then
        if [ "$scope" = "project" ]; then hooks_dir="$base/.claude/hooks/kurama"
        else hooks_dir="$(home_dir)/.claude/hooks/kurama"; fi
        if [ -d "$hooks_dir" ] && orphan_first_sight "$hooks_dir"; then
            found=true
            bad "Kurama hook scripts in $hooks_dir with no install receipt"
        fi
    fi

    # OpenCode routes through opencode.json, not through files on disk: agents
    # left there keep every /sdd-* command pointing at Kurama.
    if [ "$agent" = "opencode" ] && [ "$scope" != "project" ]; then
        cfg="$(home_dir)/.config/opencode/opencode.json"
        if [ -f "$cfg" ] && orphan_first_sight "$cfg" && grep -q '"sdd-' "$cfg" 2>/dev/null; then
            found=true
            bad "$cfg still registers Kurama sdd-* agents with no install receipt"
        fi
    fi

    if $found; then
        ORPHANS_FOUND=true
        note "Re-run setup.sh to reinstall and write a receipt, or remove the stale files by hand."
    fi
    return 0
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

# manifest_field / manifest_json_array / manifest_tools / hash_file now live in
# scripts/lib/receipt.sh (issue #37), sourced above.

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

    if [ "$total" -eq 0 ]; then
        # Every install records at least its skills, so an empty files[] is not a
        # healthy target: it is the receipt setup.sh's EXIT trap flushes when a
        # run aborts before anything landed (or a receipt someone truncated).
        # "all 0 recorded file(s) present" read as a green light for that.
        bad "receipt records NO files — partial or aborted install (re-run setup.sh, or uninstall.sh to clean up)"
    elif [ "$missing" -gt 0 ]; then
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
        # #23: markers are how setup.sh merges TODAY, but every OpenCode install
        # written before this release had its AGENTS.md copied whole, without
        # them — so this branch flagged perfectly healthy installs as unmerged.
        # Verify by content before warning: the orchestrator IS there, it just
        # predates the marker merge (re-running setup.sh adds the markers and
        # makes it updatable/removable again).
        if grep -qF '## Kurama Orchestrator' "$prompt" 2>/dev/null; then
            note "orchestrator present but unmarked in $prompt (pre-marker install — re-run setup.sh to make it updatable)"
        else
            soft "no kurama markers in $prompt (orchestrator not merged?)"
        fi
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

    # #31: severity comes from the RECEIPT, not from the bare absence of a file.
    # Two shipped, documented paths install a claude-code target with no hooks:
    # install.sh copies skills only (docs/installation.md), and a jq-less setup.sh
    # warns loudly, prints the manual hook steps and writes no settings.json —
    # recording neither in the receipt. Both were graded a hard FAILURE, which
    # made doctor call "installed exactly as documented" broken and left the user
    # no way to reach green short of installing jq. An honest degradation is a
    # WARNING carrying its remedy. A receipt that CLAIMS the write stays red:
    # that is the state where something really did go missing after the install.
    local manifest="$receipt_dir/$INSTALL_MANIFEST_NAME"
    local claims_scripts=false claims_settings=false
    if manifest_json_array "$manifest" "files" | grep -q 'hooks/kurama/'; then
        claims_scripts=true
    fi
    if [ -n "$(manifest_json_array "$manifest" "settings" | awk 'NF')" ]; then
        claims_settings=true
    fi

    if [ -f "$hooks_dir/archive-gate.sh" ] && [ -f "$hooks_dir/orchestrator-write-guard.sh" ]; then
        pass "hook scripts present in $hooks_dir"
    elif $claims_scripts; then
        bad "hook scripts missing from $hooks_dir — the receipt records them as installed"
    else
        soft "no Kurama hook scripts in $hooks_dir (skills-only install — the receipt claims none)"
        note "Run setup.sh --agent claude-code to add the archive gate and the orchestrator write guard."
    fi

    if [ -f "$settings" ] && grep -q 'hooks/kurama/' "$settings" 2>/dev/null; then
        pass "hooks block present in settings.json"
    elif $claims_settings; then
        bad "hooks block missing from $settings — the receipt records that write"
    else
        soft "hooks not registered in $settings (the receipt records no settings write)"
        note "Register the two PreToolUse hooks by hand, or install jq and re-run setup.sh."
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
    local scope raw_tools tools tool_label t slug
    scope="$(manifest_field "$manifest" "scope")"; [ -n "$scope" ] || scope="global"
    # A project-scope receipt can record several harnesses; report them all.
    raw_tools="$(manifest_tools "$manifest")"
    tool_label="$(fmt_tool_list "$raw_tools")"

    header "Diagnosing ${tool_label:-unknown} ($scope) — $receipt_dir"
    if [ ! -f "$manifest" ]; then
        bad "no install receipt at $receipt_dir"
        return 0
    fi
    pass "receipt found: $manifest"

    # #23: normalize every recorded tool to the slug setup.sh uses, BEFORE any
    # path is resolved from it. install.sh records the DISPLAY name ("Claude
    # Code"); update.sh normalizes, doctor did not — so path resolution fell
    # through to the empty string, check_markers `continue`d on it and
    # check_hooks returned early, and doctor printed "All checks passed —
    # healthy" over an install with no orchestrator, no agents and no hooks.
    # An unresolvable value (a dropped harness, a corrupted receipt) is a hard
    # FAIL: doctor cannot diagnose a target whose paths it cannot resolve.
    tools=""
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        slug="$(tool_to_slug "$t")"
        if [ -z "$slug" ]; then
            bad "unrecognized tool in receipt: '$t' — its paths cannot be resolved (dropped harness, or a corrupted receipt)"
            continue
        fi
        tools="$tools$slug
"
    done <<TOOLS
$raw_tools
TOOLS
    tools="$(printf '%s' "$tools" | awk 'NF && !seen[$0]++')"
    if [ -z "$tools" ]; then
        bad "receipt records no usable tool — nothing else can be verified for this target"
        return 0
    fi

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

# #23: every branch that finds no receipt now scans for orphans instead of
# assuming absence. A receipt-less target is either a clean machine or a fully
# wired install nothing manages, and only the disk can tell the two apart.
if [ "$SCOPE" = "project" ]; then
    TARGET_PATH="${TARGET_PATH:-$PWD}"
    if [ -f "$TARGET_PATH/$INSTALL_MANIFEST_NAME" ]; then
        diagnose_target "$TARGET_PATH"
    else
        header "Diagnosing project scope — $TARGET_PATH"
        bad "no install receipt at $TARGET_PATH"
        for agent in $ALL_AGENTS; do
            check_orphans "$agent" project "$TARGET_PATH"
        done
        $ORPHANS_FOUND || note "No Kurama artifacts in $TARGET_PATH either — nothing is installed there."
    fi
elif [ -n "$AGENT" ]; then
    dir="$(global_skills_path "$AGENT")"
    if [ -z "$dir" ]; then
        bad "unknown agent: $AGENT"
    elif [ -f "$dir/$INSTALL_MANIFEST_NAME" ]; then
        diagnose_target "$dir"
    else
        header "Diagnosing $AGENT (global) — $dir"
        bad "no install receipt at $dir"
        check_orphans "$AGENT" global ""
        $ORPHANS_FOUND || note "No Kurama artifacts on disk either — nothing is installed."
    fi
else
    any=false
    for agent in $ALL_AGENTS; do
        dir="$(global_skills_path "$agent")"
        [ -n "$dir" ] || continue
        if [ -f "$dir/$INSTALL_MANIFEST_NAME" ]; then
            any=true
            diagnose_target "$dir"
        else
            check_orphans "$agent" global ""
        fi
    done
    if ! $any; then
        note "No global install receipts found."
        $ORPHANS_FOUND || note "No Kurama artifacts on disk either — nothing is installed."
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
