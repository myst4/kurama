#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Kurama — Update / Re-sync Script (O6)
#
# Re-synchronizes an existing install from the CURRENT repository checkout. It
# does NOT run `git pull` — it never mutates the user's clone; you pull first,
# then run update to push the new content onto every recorded target.
#
# It reads the install receipt(s) setup.sh wrote (.kurama-install-manifest.json)
# to learn which agent + scope were configured, re-runs the idempotent installer
# for exactly that target, and reports which recorded files actually changed plus
# the version stamp before → after. User-created files are never touched.
#
# Backup hygiene: re-running the installer backs up every pre-existing native
# agent file before overwriting it, so update prunes the accumulated `.bak.*` in
# each recorded agents dir down to the single newest backup per file (never on a
# --dry-run).
#
# Usage:
#   ./update.sh --agent claude-code                 # re-sync one global agent
#   ./update.sh --scope project --path /repo         # re-sync a project install
#   ./update.sh                                      # re-sync all global receipts
#   ./update.sh --agent pi --dry-run                 # report drift, change nothing
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SETUP_SCRIPT="$SCRIPT_DIR/setup.sh"
VERSION_FILE="$REPO_DIR/VERSION"
INSTALL_MANIFEST_NAME=".kurama-install-manifest.json"

# Every agent that can carry a global receipt (used when no --agent is given).
ALL_AGENTS="claude-code opencode codex pi omp"

SCOPE="global"
AGENT=""
TARGET_PATH=""
DRY_RUN=false

# Per-target outcomes. A refusal or a failure is about ONE target, never a reason
# to abandon the targets queued behind it: install.sh already skips-and-continues
# the same way (see its MANAGED_TARGETS_SKIPPED). Collected here so the run
# updates everything it CAN, then closes with an honest summary and exits 1.
# Newline-separated "label|receipt_dir" entries.
REFUSED_TARGETS=""
FAILED_TARGETS=""
# Set by resync_target for the target it just handled: true when that target was
# refused (a recoverable receipt gap with a printed remedy) rather than failed.
LAST_TARGET_REFUSED=false

# ============================================================================
# Colors
# ============================================================================

setup_colors() {
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
}

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }
header() { echo -e "\n${CYAN}${BOLD}$1${NC}"; }

home_dir() { echo "$HOME"; }

# ============================================================================
# Receipt helpers
# ============================================================================

read_version() {
    local v="unknown"
    [ -f "$VERSION_FILE" ] && { IFS= read -r v < "$VERSION_FILE" || true; [ -n "$v" ] || v="unknown"; }
    printf '%s' "$v"
}

# Short commit SHA of the current Kurama repo checkout ('' when git is unavailable).
repo_commit() {
    local c=""
    if command -v git >/dev/null 2>&1; then
        c="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    fi
    printf '%s' "$c"
}

# Render "version (commit)", collapsing to just "version" when no commit is known.
fmt_ver_commit() {
    local v="$1" c="$2"
    if [ -n "$c" ]; then printf '%s (%s)' "$v" "$c"; else printf '%s' "$v"; fi
}

# Skills dir (= receipt dir for global) for a global agent, mirroring setup.sh.
global_skills_path() {
    local agent="$1" home; home="$(home_dir)"
    case "$agent" in
        claude-code)  echo "$home/.claude/skills" ;;
        opencode)     echo "$home/.config/opencode/skills" ;;
        codex)        echo "$home/.codex/skills" ;;
        pi)           echo "$home/.pi/agent/skills" ;;
        omp)          echo "${PI_CODING_AGENT_DIR:-$home/.omp/agent}/skills" ;;
        *)            echo "" ;;
    esac
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

# Read a manifest scalar field ("tool", "scope", "version").
manifest_field() {
    local manifest="$1" key="$2"
    [ -f "$manifest" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$key" '.[$k] // ""' "$manifest" 2>/dev/null
        return 0
    fi
    awk -v key="$key" '
        match($0, "\"" key "\"[[:space:]]*:[[:space:]]*\"[^\"]*\"") {
            s = substr($0, RSTART, RLENGTH)
            sub(/.*:[[:space:]]*"/, "", s); sub(/".*/, "", s); print s; exit
        }' "$manifest"
}

# Emit each element of a flat receipt array — "files", "tools", … (jq or awk
# fallback). Mirrors manifest_json_array in doctor.sh/uninstall.sh/install.sh
# (and setup.sh's receipt_json_array / setup-tui.sh's copy) so every script
# parses a receipt the same way.
#
# Why the opening rule handles the whole array itself instead of just setting
# inarr: for a single-line "key": [] the array closes on the line that opened it,
# so setting inarr and skipping to the next line hands the closing-bracket check
# a bracket that never arrives. The parser then runs to the end of the receipt,
# printing the NEXT key's declaration line as if it were an element, followed by
# the elements that belong to that other key. uninstall.sh drives rm from
# files[], so an empty files[] would migrate .claude/settings.json out of
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
            gsub(/^[[:space:]]+/, "", line); gsub(/[[:space:]]+$/, "", line)
            gsub(/,$/, "", line); gsub(/"/, "", line)
            if (line != "") print line
        }' "$manifest"
}

# Every harness recorded in the receipt. A project-scope receipt is shared by
# every harness installed into that repo, so it lists them all in "tools"; the
# flat arrays below are the union across them. Receipts written by v6 and by the
# legacy install.sh have no "tools", so the effective list is the single "tool".
manifest_tools() {
    local manifest="$1" tools
    tools="$(manifest_json_array "$manifest" "tools" | awk 'NF')"
    [ -n "$tools" ] || tools="$(manifest_field "$manifest" "tool")"
    printf '%s\n' "$tools"
}

# Render a newline-separated tool list as "a, b" for a header/info line.
fmt_tool_list() {
    printf '%s\n' "$1" | awk 'NF { out = (out == "" ? $0 : out ", " $0) } END { print out }'
}

# True when the receipt recorded the Kurama startup logo (the OpenCode .tsx or
# the Pi .ts, both recorded in files[]). The re-sync below delegates to setup.sh,
# where the logo is opt-in — without re-passing the flag the refreshed receipt
# would forget a logo that is still installed, and uninstall could no longer
# reverse it.
manifest_has_startup_logo() {
    local manifest="$1"
    [ -f "$manifest" ] || return 1
    manifest_json_array "$manifest" "files" \
        | awk '/kurama-logo\.tsx?$/ { found = 1 } END { exit(found ? 0 : 1) }'
}

# Portable content hash of a file ("" if missing).
hash_file() {
    [ -f "$1" ] || { printf ''; return 0; }
    if command -v shasum >/dev/null 2>&1; then shasum "$1" | awk '{print $1}';
    elif command -v sha1sum >/dev/null 2>&1; then sha1sum "$1" | awk '{print $1}';
    else cksum "$1" | awk '{print $1"-"$2}'; fi
}

# Keep only the NEWEST timestamped backup per original file in an agents dir.
# An update re-runs the idempotent installer, which backs up every pre-existing
# agent file (via the shared make_backup: NAME.md.bak.YYYYMMDDHHMMSS) before
# overwriting it — so without pruning, agents/ accumulates one .bak per file on
# every update. Backup names carry a fixed-width, zero-padded timestamp, so a
# lexical sort is chronological: keep the last, delete the rest.
prune_stale_agent_backups() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    local pruned=0 orig baks keep bk
    # Distinct original filenames that have at least one timestamped backup.
    for orig in $(find "$dir" -maxdepth 1 -type f -name '*.bak.*' 2>/dev/null \
        | while IFS= read -r b; do bb="${b##*/}"; printf '%s\n' "${bb%.bak.*}"; done \
        | sort -u); do
        baks="$(find "$dir" -maxdepth 1 -type f -name "$orig.bak.*" 2>/dev/null | sort)"
        keep="$(printf '%s\n' "$baks" | awk 'NF{last=$0} END{print last}')"
        while IFS= read -r bk; do
            [ -n "$bk" ] || continue
            [ "$bk" = "$keep" ] && continue
            rm -f "$bk" && pruned=$((pruned + 1))
        done <<EOF
$baks
EOF
    done
    [ "$pruned" -gt 0 ] && info "pruned $pruned stale agent backup(s) in $dir (kept newest per file)"
    return 0
}

# ============================================================================
# Re-sync one recorded target
# ============================================================================

resync_target() {
    local receipt_dir="$1"
    local manifest="$receipt_dir/$INSTALL_MANIFEST_NAME"
    LAST_TARGET_REFUSED=false

    if [ ! -f "$manifest" ]; then
        warn "No receipt at $receipt_dir — nothing to update (skipping)"
        return 0
    fi

    local tools tool_label rscope old_ver new_ver old_commit new_commit
    # Every harness this receipt records — one re-sync per tool below. Falls back
    # to the single "tool" for pre-tools[] receipts.
    tools="$(manifest_tools "$manifest")"
    tool_label="$(fmt_tool_list "$tools")"
    rscope="$(manifest_field "$manifest" "scope")"; [ -n "$rscope" ] || rscope="global"
    old_ver="$(manifest_field "$manifest" "version")"; [ -n "$old_ver" ] || old_ver="unknown"
    new_ver="$(read_version)"
    # V4: honest transition — the OLD receipt's version+commit → the CURRENT repo's
    # version+commit. A pre-5.0.0 receipt has no "commit" field, so old_commit is
    # empty and only the new side shows a SHA (e.g. "5.0.0-dev → 5.0.0 (416ef29)").
    old_commit="$(manifest_field "$manifest" "commit")"
    new_commit="$(repo_commit)"

    header "Updating $tool_label ($rscope) — $receipt_dir"
    info "Version: $(fmt_ver_commit "$old_ver" "$old_commit") → $(fmt_ver_commit "$new_ver" "$new_commit")"

    # Snapshot pre-sync hashes of every recorded file. files[] is the union across
    # every recorded tool, so one snapshot covers all of them.
    local files rel pre
    files="$(manifest_json_array "$manifest" "files")"
    local hashfile; hashfile="$(mktemp)"
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        pre="$(hash_file "$receipt_dir/$rel")"
        printf '%s\t%s\n' "$rel" "$pre" >> "$hashfile"
    done <<EOF
$files
EOF

    if $DRY_RUN; then
        info "Dry run — would re-sync $(printf '%s\n' "$files" | grep -c . ) recorded file(s) from $REPO_DIR"
        rm -f "$hashfile"
        return 0
    fi

    # Normalize each recorded tool to the canonical slug setup.sh accepts.
    # install.sh stores a display name ("Claude Code") whose space would corrupt
    # the delegated command; setup.sh stores the slug already. An unrecognized
    # value is a hard stop — mis-invoking setup.sh would be worse than aborting.
    # Resolve every slug BEFORE installing anything, so a bad entry aborts the
    # target instead of leaving it half re-synced.
    # The OpenCode install-time choices, recorded by setup.sh since #22. The
    # re-sync below runs setup.sh --non-interactive, where an unset mode falls
    # back to "single" and an unset profile to "no" — and the agent merge then
    # DELETES every sdd-* key it does not re-create. A multi-mode + profile
    # install re-synced without them went from 20 agents to 1, and because
    # opencode.json is not in files[] the run still printed "no recorded file
    # changed". Re-pass them exactly like the --with-logo carry-over.
    local oc_mode oc_profile
    oc_mode="$(manifest_field "$manifest" "opencode_mode")"
    oc_profile="$(manifest_field "$manifest" "opencode_profile")"

    local tool slug; local -a slugs=()
    while IFS= read -r tool; do
        [ -n "$tool" ] || continue
        slug="$(tool_to_slug "$tool")"
        if [ -z "$slug" ]; then
            fail "Unrecognized tool in receipt: '$tool' — cannot re-sync $receipt_dir"
            rm -f "$hashfile"
            return 1
        fi
        # A receipt written before #22 (or by install.sh) records no mode. Guessing
        # one silently downgrades the install, so refuse the target instead and say
        # exactly how to make it re-syncable. Project scope never runs the OpenCode
        # flow (setup_agent routes it to the plain orchestrator merge), so no mode
        # is expected there.
        if [ "$slug" = "opencode" ] && [ "$rscope" != "project" ] && [ -z "$oc_mode" ]; then
            fail "This OpenCode receipt records no agent mode — refusing to re-sync $receipt_dir"
            info "Re-syncing without it would reset the install to single mode and delete every"
            info "sdd-* agent a multi-mode or profile install added."
            info "Re-run setup once with the mode you use, then update.sh works again:"
            info "  $SETUP_SCRIPT --agent opencode --opencode-mode single|multi [--opencode-profile NAME]"
            rm -f "$hashfile"
            LAST_TARGET_REFUSED=true
            return 1
        fi
        slugs+=("$slug")
    done <<EOF
$tools
EOF
    if [ "${#slugs[@]}" -eq 0 ]; then
        fail "Receipt records no tool — cannot re-sync $receipt_dir"
        rm -f "$hashfile"
        return 1
    fi

    # Delegate the actual re-sync to the idempotent installer, matching the
    # recorded scope — once per recorded tool, since a project-scope receipt is
    # shared by every harness installed into that repo and re-syncing only one of
    # them would let the others drift. --without-pi-packages so an update never
    # silently (re)installs the package stack; skills/agents/hooks/orchestrator
    # re-sync. An argv array keeps the slug and any spaced --path intact (no
    # word-splitting).
    # Read the logo flag once, up front: each setup.sh run below rewrites the
    # receipt, so probing it inside the loop would read a moving target.
    local with_logo=false
    if manifest_has_startup_logo "$manifest"; then with_logo=true; fi

    for slug in "${slugs[@]}"; do
        local -a args=(--agent "$slug" --non-interactive --without-pi-packages)
        if [ "$rscope" = "project" ]; then
            args+=(--scope project --path "$receipt_dir")
        fi
        # Carry an installed startup logo across the re-sync (opt-in in setup.sh).
        if $with_logo; then
            args+=(--with-logo)
        fi
        # Carry the recorded OpenCode mode + profile (#22). The profile is passed
        # in its BARE form on purpose: "NAME:provider/model" is documented as an
        # explicit choice for THAT run and overrides hand-edited models, so
        # re-passing the recorded model would revert the user's own model edits on
        # every update. Bare NAME re-installs the profile and restores the models
        # currently in the config. "no" means the install has no profile — passing
        # it would create one literally named "no".
        if [ "$slug" = "opencode" ] && [ "$rscope" != "project" ]; then
            args+=(--opencode-mode "$oc_mode")
            if [ -n "$oc_profile" ] && [ "$oc_profile" != "no" ]; then
                args+=(--opencode-profile "$oc_profile")
            fi
        fi
        if ! bash "$SETUP_SCRIPT" "${args[@]}" >/dev/null 2>&1; then
            fail "Re-sync failed for $slug ($rscope)"
            rm -f "$hashfile"
            return 1
        fi
    done

    # Report which recorded files changed (restored drift or picked up new content).
    local changed=0 post
    while IFS=$'\t' read -r rel pre; do
        [ -n "$rel" ] || continue
        post="$(hash_file "$receipt_dir/$rel")"
        if [ "$pre" != "$post" ]; then
            ok "updated: $rel"
            changed=$((changed + 1))
        fi
    done < "$hashfile"
    rm -f "$hashfile"

    if [ "$changed" -eq 0 ]; then
        # V4: only call it "already up to date" when the version AND the commit are
        # identical too — otherwise the content is byte-identical but the source moved
        # (e.g. a -dev → stable bump with no file changes), which the receipt re-stamp
        # already recorded.
        if [ "$old_ver" = "$new_ver" ] && [ "$old_commit" = "$new_commit" ]; then
            info "Already up to date — $(fmt_ver_commit "$new_ver" "$new_commit"), no recorded file changed"
        else
            info "No recorded file changed; version/commit re-stamped to $(fmt_ver_commit "$new_ver" "$new_commit")"
        fi
    else
        echo -e "  ${GREEN}${BOLD}$changed file(s) re-synced${NC}"
    fi

    # Hygiene: the re-sync above backed up each pre-existing agent file, so prune
    # the accumulated .bak.* in every recorded agents dir down to the newest per
    # file. Derive the dirs from the receipt (../agents for global, .claude/.pi
    # agents for project). Only runs on a real update (dry-run returned earlier).
    local rel ad agent_dirs=""
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case "$rel" in
            */agents/*.md|agents/*.md)
                agent_dirs="$agent_dirs
$(dirname "$receipt_dir/$rel")" ;;
        esac
    done <<EOF
$files
EOF
    agent_dirs="$(printf '%s\n' "$agent_dirs" | awk 'NF' | sort -u)"
    while IFS= read -r ad; do
        [ -n "$ad" ] || continue
        prune_stale_agent_backups "$ad"
    done <<EOF
$agent_dirs
EOF
}

# ============================================================================
# Help
# ============================================================================

show_help() {
    echo "Usage: update.sh [OPTIONS]"
    echo ""
    echo "Re-syncs an existing Kurama install from the CURRENT repo checkout."
    echo "It does NOT git pull — pull first, then run update."
    echo ""
    echo "Options:"
    echo "  --agent NAME     Update one global agent target"
    echo "  --scope SCOPE    'global' (default) or 'project'"
    echo "  --path DIR       Repo root for --scope project"
    echo "  --dry-run        Report what would re-sync without changing anything"
    echo "  -h, --help       Show this help"
    echo ""
    echo "With no --agent (global scope), every agent that has a receipt is updated."
}

# ============================================================================
# Main
# ============================================================================

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
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *)  echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

echo ""
echo -e "${CYAN}${BOLD}Kurama — Update / Re-sync${NC}"
$DRY_RUN && echo -e "${YELLOW}${BOLD}Dry run — nothing will be written.${NC}"

# Run one target and file its outcome. Never propagates the non-zero return, so
# `set -e` cannot abort the remaining targets — the end-of-run summary reports
# every refusal/failure and sets the exit code.
run_target() {
    local label="$1" dir="$2"
    if resync_target "$dir"; then
        return 0
    fi
    if $LAST_TARGET_REFUSED; then
        REFUSED_TARGETS="$REFUSED_TARGETS
$label|$dir"
    else
        FAILED_TARGETS="$FAILED_TARGETS
$label|$dir"
    fi
    return 0
}

if [ "$SCOPE" = "project" ]; then
    TARGET_PATH="${TARGET_PATH:-$PWD}"
    run_target "project" "$TARGET_PATH"
elif [ -n "$AGENT" ]; then
    dir="$(global_skills_path "$AGENT")"
    [ -n "$dir" ] || { fail "Unknown agent: $AGENT"; exit 1; }
    run_target "$AGENT" "$dir"
else
    # No agent given: update every global agent that has a receipt. One refused or
    # failed target never cancels the rest — they are independent installs.
    found=false
    for agent in $ALL_AGENTS; do
        dir="$(global_skills_path "$agent")"
        [ -n "$dir" ] || continue
        if [ -f "$dir/$INSTALL_MANIFEST_NAME" ]; then
            found=true
            run_target "$agent" "$dir"
        fi
    done
    if ! $found; then
        warn "No global install receipts found — nothing to update."
        info "Run setup.sh first, or pass --scope project --path <repo>."
    fi
fi

# End-of-run summary. A run that skipped a target must say so at the END, where
# the user actually looks: the per-target refusal scrolls away behind every target
# updated after it, and a silent exit 1 reads as "the whole update broke".
print_target_list() {
    local entries="$1" label dir count
    count="$(printf '%s\n' "$entries" | awk 'NF' | wc -l | tr -d ' ')"
    echo -e "${RED}${BOLD}Not updated — $count target(s) $2${NC}"
    while IFS='|' read -r label dir; do
        [ -n "$label" ] || continue
        fail "$label ($dir)"
    done <<EOF
$(printf '%s\n' "$entries" | awk 'NF')
EOF
}

if [ -n "$REFUSED_TARGETS" ] || [ -n "$FAILED_TARGETS" ]; then
    echo ""
    if [ -n "$REFUSED_TARGETS" ]; then
        print_target_list "$REFUSED_TARGETS" "refused"
        # Refusing is always the mode-less OpenCode receipt today; the remedy is
        # one setup run that records the mode.
        info "Re-run setup once per refused target, with the mode you use, then update again:"
        info "  $SETUP_SCRIPT --agent opencode --opencode-mode single|multi [--opencode-profile NAME]"
    fi
    if [ -n "$FAILED_TARGETS" ]; then
        print_target_list "$FAILED_TARGETS" "failed"
    fi
    echo -e "\n${YELLOW}${BOLD}Done with errors.${NC} Every other recorded target was updated."
    exit 1
fi

echo -e "\n${GREEN}${BOLD}Done.${NC}"
