#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Kurama — Interactive setup front-end (gum)
#
# This script installs NOTHING. It collects choices, builds a setup.sh command
# line, shows it, and runs it. setup.sh stays the single implementation of the
# installer — every prompt here maps to a flag it already accepts, so there is
# no second code path to keep in parity. (Kurama deleted 73KB of PowerShell for
# exactly that reason; a TUI with its own path-resolution logic would repeat it.)
#
# Showing the assembled command before running is not decoration: it is how you
# learn the invocation to paste into CI, a dotfiles bootstrap, or a bug report.
#
# gum is an OPTIONAL dependency. Kurama's promise is a zero-dependency install,
# so ./setup.sh remains the documented entry point and works with nothing
# installed. This is sugar on top.
#
# Supported platforms: macOS and Linux. Bash 3.2 compatible.
#
# Usage:
#   ./scripts/setup-tui.sh
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/setup.sh"

# Every harness setup.sh accepts, paired with the binary that proves it is
# installed. Kept in the same order setup.sh's detect_agents() checks them.
AGENTS="claude-code opencode codex pi omp"

agent_binary() {
    case "$1" in
        claude-code) echo "claude" ;;
        opencode)    echo "opencode" ;;
        codex)       echo "codex" ;;
        pi)          echo "pi" ;;
        omp)         echo "omp" ;;
        *)           echo "" ;;
    esac
}

# --- preconditions ----------------------------------------------------------

if ! command -v gum >/dev/null 2>&1; then
    cat >&2 <<'EOF'
This front-end needs `gum` (https://github.com/charmbracelet/gum).

  macOS  : brew install gum
  Linux  : see https://github.com/charmbracelet/gum#installation

gum is optional — Kurama installs fine without it:

  ./scripts/setup.sh          # interactive
  ./scripts/setup.sh --help   # every flag this front-end can build
EOF
    exit 1
fi

if [ ! -f "$SETUP_SCRIPT" ]; then
    echo "setup.sh not found next to this script: $SETUP_SCRIPT" >&2
    exit 1
fi

# --- theming ----------------------------------------------------------------
# One accent colour, reused. Kurama's banner art is orange (the nine-tailed fox),
# so the TUI matches rather than inventing a second identity.
ACCENT="212"
DIM="240"

heading() {
    gum style --foreground "$ACCENT" --bold --margin "1 0 0 0" "$1"
}

# The nine-tailed fox + KURAMA wordmark, same art setup.sh and install.sh print.
# The fade-in is kept here (setup.sh passes --no-anim): this front-end only runs
# on a TTY with a human watching it start, which is the one place it earns its
# 30ms/frame. banner.sh is best-effort and always exits 0, so a terminal too
# small or without truecolor degrades on its own — falling back to a plain
# heading keeps the screen from opening empty.
print_banner() {
    [ -t 1 ] || return 1
    bash "$SCRIPT_DIR/banner.sh" 2>/dev/null
}

hint() {
    gum style --foreground "$DIM" "$1"
}

# --- 0. open the screen ------------------------------------------------------

print_banner || heading "Kurama — setup"

# The banner is drawn once, here. Each setup.sh below would otherwise paint it
# again — four foxes for a three-harness install.
export KURAMA_NO_BANNER=1

# --- 1. which harnesses ------------------------------------------------------
# Detected ones are offered pre-selected: a user who installed opencode almost
# certainly wants it wired. Undetected ones stay selectable on purpose — you may
# be provisioning a machine before installing the agent itself.

detected=""
for a in $AGENTS; do
    if command -v "$(agent_binary "$a")" >/dev/null 2>&1; then
        detected="$detected $a"
    fi
done
detected="${detected# }"

if [ -n "$detected" ]; then
    hint "Detected in PATH: $(echo "$detected" | tr ' ' ',' | sed 's/,/, /g')"
else
    hint "No harness binaries found in PATH — you can still install for any of them."
fi

# gum choose --selected takes a comma-separated list; with nothing detected the
# flag must be omitted entirely (an empty --selected preselects nothing anyway,
# but keeping the call shape identical avoids a quoting edge case in bash 3.2).
# shellcheck disable=SC2086  # $AGENTS must word-split — gum choose takes one
# argument per option, and the slugs are a fixed literal list with no spaces.
if [ -n "$detected" ]; then
    chosen="$(gum choose --no-limit \
        --header "Which harnesses? (space to toggle, enter to confirm)" \
        --selected "$(echo "$detected" | tr ' ' ',')" \
        $AGENTS)"
else
    chosen="$(gum choose --no-limit \
        --header "Which harnesses? (space to toggle, enter to confirm)" \
        $AGENTS)"
fi

[ -n "$chosen" ] || { echo "Nothing selected — aborting."; exit 0; }

# --- 2. scope ----------------------------------------------------------------

scope="$(gum choose --header "Install scope?" \
    "global — per-user config dirs (~/.claude, ~/.pi, …)" \
    "project — everything inside one git repo")"
[ -n "$scope" ] || exit 0

case "$scope" in
    global*)  scope="global" ;;
    project*) scope="project" ;;
esac

target_path=""
if [ "$scope" = "project" ]; then
    target_path="$(gum input --header "Repo path" --value "$PWD" --width 80)"
    [ -n "$target_path" ] || { echo "No path given — aborting."; exit 0; }
fi

# --- 3. per-harness extras ---------------------------------------------------
# Asked ONLY when the harness that owns the flag was selected, so an
# opencode-less install never sees an opencode question.

opencode_mode=""
opencode_profile=""
case " $chosen " in
    *" opencode "*)
        opencode_mode="$(gum choose --header "OpenCode agent mode?" \
            "single — one orchestrator, phases run as subtasks" \
            "multi — a dedicated agent per phase, model customizable")"
        case "$opencode_mode" in
            single*) opencode_mode="single" ;;
            multi*)  opencode_mode="multi" ;;
            *)       opencode_mode="" ;;
        esac

        if gum confirm "Install a named model profile?" --default=false; then
            opencode_profile="$(gum input \
                --header "Profile name (optionally NAME:provider/model)" \
                --placeholder "fast:anthropic/claude-haiku-4-5" --width 80)"
        fi
        ;;
esac

pi_packages=""
case " $chosen " in
    *" pi "*)
        if gum confirm "Install the Pi package stack? (7 pinned npm packages)" --default=false; then
            pi_packages="yes"
        else
            pi_packages="no"
        fi
        ;;
esac

# --- 4. cross-cutting options ------------------------------------------------

if gum confirm "Use Engram as the persistence engine?" --default=false; then
    engram="yes"
else
    engram="no"
fi

if gum confirm "Draw the Kurama logo at agent startup?" --default=false; then
    logo="yes"
else
    logo="no"
fi

# --- 5. build the command(s) -------------------------------------------------
# setup.sh takes ONE --agent per run, so a multi-select becomes one invocation
# per harness. Flags a given harness ignores are simply not added to its line.

build_cmd() {
    agent="$1"
    cmd="./scripts/setup.sh --agent $agent"

    [ "$scope" = "project" ] && cmd="$cmd --scope project --path \"$target_path\""

    if [ "$agent" = "opencode" ]; then
        [ -n "$opencode_mode" ] && cmd="$cmd --opencode-mode $opencode_mode"
        [ -n "$opencode_profile" ] && cmd="$cmd --opencode-profile \"$opencode_profile\""
    fi

    if [ "$agent" = "pi" ] && [ -n "$pi_packages" ]; then
        [ "$pi_packages" = "yes" ] && cmd="$cmd --with-pi-packages" || cmd="$cmd --without-pi-packages"
    fi

    [ "$engram" = "yes" ] && cmd="$cmd --with-engram" || cmd="$cmd --without-engram"
    [ "$logo" = "yes" ] && cmd="$cmd --with-logo"

    printf '%s' "$cmd"
}

heading "Command"
preview=""
for a in $chosen; do
    preview="$preview$(build_cmd "$a")
"
done
gum style --border rounded --border-foreground "$ACCENT" --padding "0 1" "${preview%
}"
hint "Re-runnable and idempotent — paste it into CI or a dotfiles bootstrap."

gum confirm "Run it now?" || { echo "Not run. The command above is yours to keep."; exit 0; }

# --- 6. run ------------------------------------------------------------------
# Executed with the real argv rather than eval'ing the preview string, so a path
# with spaces cannot re-split. The preview is for humans; this is the truth.

status=0
for a in $chosen; do
    heading "Installing $a"

    set -- --agent "$a"
    [ "$scope" = "project" ] && set -- "$@" --scope project --path "$target_path"

    if [ "$a" = "opencode" ]; then
        [ -n "$opencode_mode" ] && set -- "$@" --opencode-mode "$opencode_mode"
        [ -n "$opencode_profile" ] && set -- "$@" --opencode-profile "$opencode_profile"
    fi

    if [ "$a" = "pi" ] && [ -n "$pi_packages" ]; then
        if [ "$pi_packages" = "yes" ]; then set -- "$@" --with-pi-packages
        else set -- "$@" --without-pi-packages; fi
    fi

    if [ "$engram" = "yes" ]; then set -- "$@" --with-engram
    else set -- "$@" --without-engram; fi
    [ "$logo" = "yes" ] && set -- "$@" --with-logo

    # --non-interactive because every question setup.sh would ask has already
    # been answered above; without it setup re-asks and the TUI was pointless.
    set -- "$@" --non-interactive

    if bash "$SETUP_SCRIPT" "$@"; then
        gum style --foreground 42 "  ✓ $a done"
    else
        gum style --foreground 196 "  ✗ $a failed"
        status=1
    fi
done

exit "$status"
