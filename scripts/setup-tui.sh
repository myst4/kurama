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
# gum is an OPTIONAL dependency. Kurama installs with no build step and no
# runtime, so ./setup.sh remains the documented entry point and works with
# nothing installed beyond bash. This is sugar on top.
#
# Supported platforms: macOS and Linux. Bash 3.2 compatible.
#
# Usage:
#   ./scripts/setup-tui.sh
#
# Environment:
#   KURAMA_TUI_PROBE    Run one read-only seam and exit 0, drawing no banner and
#                       needing no gum — that is what makes these the hooks
#                       install_test.sh drives. Values:
#                         1 | targets  one tab-separated line per install this
#                                      front-end would offer to update (scope,
#                                      path, comma-joined tools, version); no
#                                      output means nothing detected
#                         preview      the command line(s) this wizard would
#                                      show AND run, taking the answers from
#                                      KURAMA_TUI_CHOSEN / _SCOPE / _PATH /
#                                      _OPENCODE_MODE / _OPENCODE_PROFILE /
#                                      _PI_PACKAGES / _ENGRAM / _LOGO, or the
#                                      maintenance line for KURAMA_TUI_MAINT
#                         profile      normalize_profile "$1": prints the
#                                      repaired profile name, or exits 1
#   KURAMA_NO_BANNER=1  Exported (not read) below: the fox is drawn once here,
#                       so the scripts this front-end runs skip theirs.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/setup.sh"

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

# --- detecting an existing install -------------------------------------------
# Read-only receipt probing, deliberately placed ABOVE the gum precondition: it
# is the one part of this front-end that is pure bash, and KURAMA_TUI_PROBE
# below has to work on a machine that never installed gum. Nothing here may call
# gum — not even heading/hint, which are not defined yet either.
#
# The parsers mirror doctor.sh's manifest_field()/manifest_json_array() rather
# than improving on them, so a receipt reads the same whichever script opens it
# (jq when present, portable awk otherwise). That is also why the receipt-array
# opening rule below was corrected in every copy at once instead of here alone —
# see docs/superpowers/specs/2026-08-10-jq-optional-fallbacks-design.md.

INSTALL_MANIFEST_NAME=".kurama-install-manifest.json"

# Where each harness keeps its GLOBAL receipt: the skills dir — the shared
# skills_path() map (issue #37); project scope puts the receipt in the repo root.
global_skills_path() {
    skills_path "$1" global
}

# manifest_field / manifest_json_array / manifest_tools now live in
# scripts/lib/receipt.sh (issue #37), sourced above.

# Newline-separated list → one line joined by $2, duplicates dropped, order kept.
join_list() {
    printf '%s\n' "$1" | awk -v sep="$2" '
        NF && !seen[$0]++ { out = (out == "" ? $0 : out sep $0) }
        END { print out }'
}

# One tab-separated line per target: scope, path, tools, version.
#
# At most two, because that is what update.sh and doctor.sh accept as units. The
# five global receipts collapse into ONE global target on purpose: with no
# --agent both scripts already walk every global receipt themselves, and a TUI
# that looped them here would be a second implementation of that walk. Its path
# field therefore carries every receipt dir found, comma-joined — informative,
# and never passed as an argument.
detect_targets() {
    local a dir manifest version paths="" tools="" versions=""

    for a in $AGENTS; do
        dir="$(global_skills_path "$a")"
        [ -n "$dir" ] || continue
        manifest="$dir/$INSTALL_MANIFEST_NAME"
        [ -f "$manifest" ] || continue
        paths="$paths$dir
"
        tools="$tools$(manifest_tools "$manifest")
"
        version="$(manifest_field "$manifest" "version")"
        [ -n "$version" ] && versions="$versions$version
"
    done

    [ -n "$paths" ] && printf '%s\t%s\t%s\t%s\n' \
        "global" "$(join_list "$paths" ",")" \
        "$(join_list "$tools" ",")" "$(join_list "$versions" ",")"

    # Project scope keeps its receipt in the repo root. $PWD is the user's repo in
    # the intended invocation (bash /path/to/kurama/scripts/setup-tui.sh from
    # inside it); run from the Kurama checkout there is nothing to find, because
    # setup.sh refuses to install into Kurama itself.
    manifest="$PWD/$INSTALL_MANIFEST_NAME"
    [ -f "$manifest" ] && printf '%s\t%s\t%s\t%s\n' \
        "project" "$PWD" \
        "$(join_list "$(manifest_tools "$manifest")" ",")" \
        "$(manifest_field "$manifest" "version")"

    return 0
}

# --- the command this front-end builds --------------------------------------
# ONE builder, used twice: the preview the user is invited to copy and the argv
# the run actually executes are the same list of words. They used to be written
# out separately, and drifted — the preview printed a cwd-relative
# `./scripts/setup.sh` (wrong under the invocation this file documents, `bash
# /path/to/kurama/scripts/setup-tui.sh` from inside your own repo) and left out
# the `--non-interactive` the run appends, so the line offered "for CI" blocked
# on prompts the wizard had already answered.
#
# Placed above the gum precondition for the same reason detect_targets is: the
# KURAMA_TUI_PROBE seam that pins preview-vs-run parity has to work on a machine
# with no gum, which is every CI runner this repo has.

# Quote one word so the preview can be pasted into a shell and split back into
# exactly these arguments — a repo path with spaces is the case that matters.
shq() {
    case "$1" in
        '')                       printf "''" ;;
        *[!A-Za-z0-9_/.:=@%+-]*)  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
        *)                        printf '%s' "$1" ;;
    esac
}

# The current ARGV, rendered as one copy-pasteable command line.
fmt_argv() {
    local out="" a
    for a in ${ARGV[@]+"${ARGV[@]}"}; do
        [ -n "$out" ] && out="$out "
        out="$out$(shq "$a")"
    done
    printf '%s\n' "$out"
}

# setup.sh takes ONE --agent per run, so a multi-select becomes one invocation
# per harness. Flags a given harness ignores are simply not added to its line.
build_setup_argv() { # agent
    ARGV=(bash "$SETUP_SCRIPT" --agent "$1")

    [ "$scope" = "project" ] && ARGV=("${ARGV[@]}" --scope project --path "$target_path")

    if [ "$1" = "opencode" ]; then
        [ -n "$opencode_mode" ] && ARGV=("${ARGV[@]}" --opencode-mode "$opencode_mode")
        [ -n "$opencode_profile" ] && ARGV=("${ARGV[@]}" --opencode-profile "$opencode_profile")
    fi

    if [ "$1" = "pi" ] && [ -n "$pi_packages" ]; then
        if [ "$pi_packages" = "yes" ]; then ARGV=("${ARGV[@]}" --with-pi-packages)
        else ARGV=("${ARGV[@]}" --without-pi-packages); fi
    fi

    if [ "$engram" = "yes" ]; then ARGV=("${ARGV[@]}" --with-engram)
    else ARGV=("${ARGV[@]}" --without-engram); fi
    [ "$logo" = "yes" ] && ARGV=("${ARGV[@]}" --with-logo)

    # Every question setup.sh would ask has already been answered above; without
    # this it re-asks and the wizard was pointless. It belongs to the preview as
    # much as to the run — that is the whole point of one builder.
    ARGV=("${ARGV[@]}" --non-interactive)
    return 0
}

# update.sh / doctor.sh, for an install that already exists.
build_maint_argv() { # script scope path
    ARGV=(bash "$SCRIPT_DIR/$1")
    [ "$2" = "project" ] && ARGV=("${ARGV[@]}" --scope project --path "$3")
    return 0
}

# NAME[:provider/model] as setup.sh will accept it, or non-zero when it cannot
# be repaired. setup.sh validates NAME against ^[a-z0-9][a-z0-9-]*$ while
# PARSING ARGUMENTS (scripts/setup.sh:2286) and exits 1 — so a stray space or a
# capital typed at the gum prompt used to abort the whole install before a
# single file was written. Whitespace and case are repairable (the interactive
# prompt in setup.sh:1258 strips whitespace the same way); anything else is the
# caller's cue to re-ask. An empty NAME defaults to "kurama", mirroring
# setup.sh:2284, so the wizard never rejects what the installer would accept.
normalize_profile() { # raw -> normalized, or status 1
    local val name rest
    val="$(printf '%s' "$1" | tr -d '[:space:]')"
    [ -n "$val" ] || return 1
    name="${val%%:*}"
    rest="${val#*:}"
    [ "$val" != "$rest" ] || rest=""
    name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    [ -n "$name" ] || name="kurama"
    printf '%s' "$name" | grep -Eq '^[a-z0-9][a-z0-9-]*$' || return 1
    if [ -n "$rest" ]; then printf '%s' "$name:$rest"; else printf '%s' "$name"; fi
}

# --- probe seams -------------------------------------------------------------
# All of them run BEFORE the gum precondition and before the banner, so
# install_test.sh can drive them on a machine with neither.
#
#   1|targets  one tab-separated line per detected install (see above)
#   preview    the command line(s) this wizard would show AND run, built from
#              KURAMA_TUI_* instead of from gum answers
#   profile    normalize_profile "$1" — prints the repaired name or exits 1
case "${KURAMA_TUI_PROBE:-}" in
    1|targets)
        detect_targets
        exit 0
        ;;
    preview)
        scope="${KURAMA_TUI_SCOPE:-global}"
        target_path="${KURAMA_TUI_PATH:-}"
        opencode_mode="${KURAMA_TUI_OPENCODE_MODE:-}"
        opencode_profile="${KURAMA_TUI_OPENCODE_PROFILE:-}"
        pi_packages="${KURAMA_TUI_PI_PACKAGES:-}"
        engram="${KURAMA_TUI_ENGRAM:-no}"
        logo="${KURAMA_TUI_LOGO:-no}"
        ARGV=()
        if [ -n "${KURAMA_TUI_MAINT:-}" ]; then
            build_maint_argv "$KURAMA_TUI_MAINT" "$scope" "$target_path"
            fmt_argv
        else
            for probe_agent in ${KURAMA_TUI_CHOSEN:-}; do
                build_setup_argv "$probe_agent"
                fmt_argv
            done
        fi
        exit 0
        ;;
    profile)
        normalize_profile "${1:-}" || exit 1
        printf '\n'
        exit 0
        ;;
esac

# --- preconditions ----------------------------------------------------------

if ! command -v gum >/dev/null 2>&1; then
    cat >&2 <<'EOF'
This front-end needs `gum` (https://github.com/charmbracelet/gum).

  macOS  : brew install gum
  Linux  : see https://github.com/charmbracelet/gum#installation

gum is optional — Kurama installs fine without it, but only non-interactively
(the interactive experience IS this gum front-end). Specify the run instead:

  ./scripts/setup.sh --all              # every detected agent
  ./scripts/setup.sh --agent NAME       # one agent (claude-code, opencode, codex, pi, omp)
  ./scripts/setup.sh --non-interactive  # no prompts (for external installers)
  ./scripts/setup.sh --help             # every flag this front-end can build
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

# --- 0.5 already installed? --------------------------------------------------
# The front door used to have one destination. Someone who already has Kurama
# and wants it re-synced, or just checked, was asked which harnesses to install
# and at what scope — and handed a setup.sh line. So: probe first, and offer the
# maintenance scripts when there is something to maintain.
#
# This stays a command builder. It assembles an update.sh/doctor.sh line, shows
# it, and runs it; it re-implements neither update nor diagnosis. With nothing
# detected, everything below is skipped and the install flow runs exactly as it
# did before.

targets="$(detect_targets)"

if [ -n "$targets" ]; then
    global_label=""
    project_label=""
    project_path=""

    # Split by hand rather than with `IFS=<tab> read -r a b c d`: a tab is IFS
    # whitespace, so read would collapse two adjacent ones and an empty middle
    # field (a receipt with no tools) would silently shift the version left.
    #
    # Labels double as the choose values: matching "global*"/"project*" back out
    # of the answer is how phase 2 reads its scope too.
    TAB="$(printf '\t')"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        t_scope="${line%%"$TAB"*}";  rest="${line#*"$TAB"}"
        t_path="${rest%%"$TAB"*}";   rest="${rest#*"$TAB"}"
        t_tools="${rest%%"$TAB"*}";  t_version="${rest#*"$TAB"}"

        label="$t_scope"
        [ -n "$t_tools" ] && label="$label — ${t_tools//,/, }"
        [ -n "$t_version" ] && label="$label (v$t_version)"
        case "$t_scope" in
            global)  global_label="$label" ;;
            project) project_label="$label — $t_path"; project_path="$t_path" ;;
        esac
    done <<EOF
$targets
EOF

    if [ -n "$global_label" ] && [ -n "$project_label" ]; then
        target="$(gum choose --header "Kurama is already installed. Which one?" \
            "$global_label" "$project_label")"
        [ -n "$target" ] || exit 0
    elif [ -n "$global_label" ]; then
        target="$global_label"
        hint "Found an existing global install: $global_label"
    else
        target="$project_label"
        hint "Found an existing project install: $project_label"
    fi

    case "$target" in
        project*) maint_scope="project" ;;
        *)        maint_scope="global" ;;
    esac

    action="$(gum choose --header "What would you like to do?" \
        "update — re-sync it from this checkout" \
        "diagnose — read-only health check, changes nothing" \
        "install again — go through the full install flow" \
        "exit — leave it as it is")"

    maint_script=""
    maint_verb=""
    case "$action" in
        update*)   maint_script="update.sh"; maint_verb="Updating" ;;
        diagnose*) maint_script="doctor.sh"; maint_verb="Diagnosing" ;;
        "install again"*) ;;  # fall through to phase 1 — today's flow, unchanged
        *) exit 0 ;;          # "exit", or escape out of the menu
    esac

    if [ -n "$maint_script" ]; then
        # Built once, shown and then run: the box below is the exact argv, with
        # this checkout's absolute path, so it still works from any directory.
        build_maint_argv "$maint_script" "$maint_scope" "$project_path"

        heading "Command"
        gum style --border rounded --border-foreground "$ACCENT" --padding "0 1" "$(fmt_argv)"
        if [ "$maint_scope" = "global" ]; then
            hint "No --agent: both scripts already cover every global receipt on this machine."
        else
            hint "Re-runnable and idempotent — paste it into CI or a dotfiles bootstrap."
        fi

        gum confirm "Run it now?" || { echo "Not run. The command above is yours to keep."; exit 0; }

        # Real argv, not an eval of the preview: a repo path with spaces must not
        # re-split. Same reason phase 6 does it this way.
        heading "$maint_verb the $maint_scope install"

        if "${ARGV[@]}"; then
            gum style --foreground 42 "  ✓ $maint_script done"
            exit 0
        else
            gum style --foreground 196 "  ✗ $maint_script reported a problem"
            exit 1
        fi
    fi
fi

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
            # Validated HERE, where a typo costs one prompt. Forwarded raw, an
            # invalid name kills the install in setup.sh's argument parser —
            # after the wizard has collected every other answer.
            profile_tries=0
            while [ "$profile_tries" -lt 3 ]; do
                profile_tries=$(( profile_tries + 1 ))
                profile_raw="$(gum input \
                    --header "Profile name (optionally NAME:provider/model)" \
                    --placeholder "fast:anthropic/claude-haiku-4-5" --width 80)"
                # Empty, or escaped out of: the same as declining the profile.
                [ -n "$profile_raw" ] || break
                if opencode_profile="$(normalize_profile "$profile_raw")"; then
                    [ "$opencode_profile" = "$profile_raw" ] || \
                        hint "Using '$opencode_profile' — setup.sh takes lowercase letters, digits and dashes."
                    break
                fi
                opencode_profile=""
                hint "'$profile_raw' is not a usable profile name (lowercase letters, digits, dashes)."
            done
            [ -n "$opencode_profile" ] || hint "No profile — continuing without one."
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

# --- 5. show the command(s) --------------------------------------------------
# build_setup_argv is defined once, at the top, and is the only thing that knows
# what a run looks like. The box below is that argv quoted for a shell — copy it
# and you get this run, from any directory, prompts already answered.

heading "Command"
preview=""
for a in $chosen; do
    build_setup_argv "$a"
    preview="$preview$(fmt_argv)
"
done
gum style --border rounded --border-foreground "$ACCENT" --padding "0 1" "${preview%
}"
hint "Re-runnable and idempotent — paste it into CI or a dotfiles bootstrap."

gum confirm "Run it now?" || { echo "Not run. The command above is yours to keep."; exit 0; }

# --- 6. run ------------------------------------------------------------------
# Executed with the real argv rather than eval'ing the preview string, so a path
# with spaces cannot re-split. Same builder as the preview: the box above is not
# a description of this, it IS this.

status=0
for a in $chosen; do
    heading "Installing $a"

    build_setup_argv "$a"

    if "${ARGV[@]}"; then
        gum style --foreground 42 "  ✓ $a done"
    else
        gum style --foreground 196 "  ✗ $a failed"
        status=1
    fi
done

exit "$status"
