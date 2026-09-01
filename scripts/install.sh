#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Kurama — Install Script (compatibility wrapper, issue #38)
#
# install.sh and setup.sh used to be two installers with asymmetric capabilities
# and duplicated logic: install_skills, OS detection, colors and receipt writing
# lived in both, group selection (--with/--without) lived ONLY here, and prompts,
# hooks, engram, the startup logo and the OpenCode modes lived ONLY in setup.sh.
# Their receipts actively conflicted (#24: this script used to OVERWRITE and thus
# truncate setup.sh's richer receipt).
#
# They are collapsed into one: setup.sh is now the SINGLE installer — skills,
# native agents, Claude Code hooks, the orchestrator merge, the OpenCode modes and
# the shared #37 receipt, plus (new in #38) the --with/--without skill-group
# selection this script used to own. This file is a thin compatibility shim: it
# maps its historical flags onto setup.sh and delegates. It installs nothing and
# writes NO receipt of its own, so setup.sh (via scripts/lib/receipt.sh) is the
# sole receipt writer and the #24 receipt-conflict class is closed for good.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/setup.sh"
# shellcheck disable=SC2034  # read by read_version() in scripts/lib/receipt.sh (--version)
VERSION_FILE="$(dirname "$SCRIPT_DIR")/VERSION"

# Shared receipt library — the single copy of the receipt parser and helpers
# (issue #37). This shim only needs read_version for --version, but every one of
# the six scripts sources AND guards the lib (see install_test.sh's lib-integration
# tests), so a partial clone is caught the same way through install.sh too. The
# guard sits above arg parsing so even --help trips it.
KURAMA_LIB="$SCRIPT_DIR/lib/receipt.sh"
if [ ! -f "$KURAMA_LIB" ]; then
    echo "kurama: missing $KURAMA_LIB — incomplete clone. Re-clone or pull the full repo." >&2
    exit 1
fi
# shellcheck source=lib/receipt.sh disable=SC1091
. "$KURAMA_LIB"
command -v manifest_json_array >/dev/null 2>&1 || { echo "kurama: scripts/lib/receipt.sh is present but did not define the receipt parser" >&2; exit 1; }

print_version() {
    printf 'kurama %s\n' "$(read_version)"
}

show_help() {
    echo "Usage: install.sh [OPTIONS]"
    echo ""
    echo "install.sh is a compatibility wrapper (issue #38): it forwards to setup.sh,"
    echo "the single Kurama installer. Prefer calling scripts/setup.sh directly."
    echo ""
    echo "Options:"
    echo "  --agent NAME     Install for a specific agent (forwarded to setup.sh)"
    echo "  --path DIR       Target git repo for --agent custom (required for custom)"
    echo "  --with GROUP     Include an optional skill group (quality, review, optional, tdd)"
    echo "  --without GROUP  Exclude an on-by-default skill group (quality, review, optional, tdd)"
    echo "  --version        Print the Kurama version and exit"
    echo "  -h, --help       Show this help"
    echo ""
    echo "Agents: claude-code, opencode, codex, pi, omp, project-local, all-global, custom"
    echo ""
    echo "How each flag maps onto setup.sh:"
    echo "  --agent claude-code|opencode|codex|pi|omp  → setup.sh --agent NAME --non-interactive"
    echo "  --agent all-global                         → setup.sh --agent NAME, once per harness (all five)"
    echo "  --agent project-local                      → setup.sh --agent claude-code --scope project --path ."
    echo "  --agent custom --path DIR                  → setup.sh --agent claude-code --scope project --path DIR"
    echo "  --with / --without GROUP                   → forwarded to setup.sh unchanged"
    echo "  (no --agent)                               → setup.sh interactive detect-and-install"
    echo ""
    echo "Note: project-local and custom run a setup.sh PROJECT install (skills, native"
    echo "  agents, Claude Code hooks and the orchestrator merge under the target repo)."
    echo "  The target must ALREADY EXIST and be a git repository — project-local uses the"
    echo "  current directory; custom requires --path DIR. A non-existent or non-git target"
    echo "  is rejected (it is not created for you)."
}

# Under `set -u` a bare value-taking flag at the end of the line would abort with a
# raw "\$2: unbound variable"; name the flag instead. Same contract as setup.sh.
require_flag_value() {
    local flag="$1" value="${2:-}"
    if [ -z "$value" ]; then
        echo "Missing value for $flag"
        echo ""
        show_help
        exit 1
    fi
}

# Parse install.sh's historical flags. Group flags are collected verbatim and
# forwarded; setup.sh validates the group names (it owns --with/--without now).
AGENT=""
CUSTOM_PATH=""
GROUP_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)   require_flag_value --agent "${2:-}";   AGENT="$2"; shift 2 ;;
        --path)    require_flag_value --path "${2:-}";     CUSTOM_PATH="$2"; shift 2 ;;
        --with)    require_flag_value --with "${2:-}";     GROUP_ARGS+=(--with "$2"); shift 2 ;;
        --without) require_flag_value --without "${2:-}";  GROUP_ARGS+=(--without "$2"); shift 2 ;;
        --version) print_version; exit 0 ;;
        -h|--help) show_help; exit 0 ;;
        *)  echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# #65: --path is meaningful for exactly ONE mapping, `--agent custom` — the only
# target this wrapper does not resolve for itself (the five global harnesses
# resolve by harness, project-local by $PWD). Passed with anything else it was
# parsed, dropped, and never mentioned again: `install.sh --path ~/work/repo`
# with no --agent forwarded a bare setup.sh, which opened the interactive
# front-end against a target the user never named. That is the drop-vs-refuse
# class #40 closed for setup.sh's own hand-off, and setup.sh answers the mirror
# case the same way ("--path requires --scope project").
if [ -n "$CUSTOM_PATH" ] && [ "$AGENT" != "custom" ]; then
    if [ -z "$AGENT" ]; then
        echo "--path requires --agent custom (a bare install.sh opens the interactive installer and would ignore it)"
    else
        echo "--path requires --agent custom (--agent $AGENT resolves its own target)"
    fi
    echo ""
    show_help
    exit 1
fi

# A partial clone missing the real installer must fail loud, never silently
# succeed at doing nothing.
if [ ! -f "$SETUP_SCRIPT" ]; then
    echo "kurama: missing $SETUP_SCRIPT — incomplete clone. Re-clone or pull the full repo." >&2
    exit 1
fi

echo "install.sh is deprecated and forwards to setup.sh (issue #38) — call scripts/setup.sh directly." >&2

case "${AGENT:-}" in
    "")
        # No --agent: hand off to setup.sh's own detect + interactive flow.
        exec bash "$SETUP_SCRIPT" "${GROUP_ARGS[@]+"${GROUP_ARGS[@]}"}"
        ;;
    claude-code|opencode|codex|pi|omp)
        exec bash "$SETUP_SCRIPT" --agent "$AGENT" --non-interactive "${GROUP_ARGS[@]+"${GROUP_ARGS[@]}"}"
        ;;
    all-global)
        # install.sh's all-global installed all FIVE harnesses UNCONDITIONALLY —
        # not the PATH detect-and-install that setup.sh --all does. Preserve that
        # exactly by enumerating the five explicitly (no detection), each a full
        # setup.sh run. Global scope gives each harness its own receipt dir, so the
        # five runs never clobber one another.
        rc=0
        for a in claude-code opencode codex pi omp; do
            bash "$SETUP_SCRIPT" --agent "$a" --non-interactive "${GROUP_ARGS[@]+"${GROUP_ARGS[@]}"}" || rc=$?
        done
        exit "$rc"
        ;;
    project-local)
        # Historically "install skills into ./skills". Maps to a setup.sh project
        # trial rooted at the cwd (skills land under the repo's .claude/skills).
        exec bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$PWD" --non-interactive "${GROUP_ARGS[@]+"${GROUP_ARGS[@]}"}"
        ;;
    custom)
        # Historically "install skills into an arbitrary DIR". Maps to a setup.sh
        # project trial rooted at that DIR — which must already exist and be a git
        # repo (setup.sh's project-scope preconditions). NO silent $PWD fallback:
        # the pre-#38 `--agent custom` without --path PROMPTED for a path, and a full
        # project install (CLAUDE.md orchestrator merge, .claude/settings.json hooks,
        # 17 native agents) into whatever repo the user happens to be sitting in is
        # not a safe default. Require --path; ask when a TTY is attached (old UX),
        # otherwise fail loud.
        custom_target="$CUSTOM_PATH"
        if [ -z "$custom_target" ] && [ -t 0 ]; then
            read -rp "Enter target path: " custom_target || custom_target=""
        fi
        if [ -z "$custom_target" ]; then
            echo "--agent custom requires --path DIR (the target git repository)"
            echo ""
            show_help
            exit 1
        fi
        exec bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$custom_target" --non-interactive "${GROUP_ARGS[@]+"${GROUP_ARGS[@]}"}"
        ;;
    *)
        echo "Unknown agent: $AGENT"
        echo ""
        show_help
        exit 1
        ;;
esac
