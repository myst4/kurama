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
ALL_AGENTS="claude-code opencode gemini-cli codex vscode cursor pi"

SCOPE="global"
AGENT=""
TARGET_PATH=""
DRY_RUN=false

# ============================================================================
# OS detection + colors (mirrors setup.sh so paths resolve identically)
# ============================================================================

detect_os() {
    case "$(uname -s)" in
        Darwin)  OS="macos" ;;
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then OS="wsl"; else OS="linux"; fi
            ;;
        MINGW*|MSYS*|CYGWIN*)  OS="windows" ;;
        *)  OS="unknown" ;;
    esac
}

setup_colors() {
    if [[ "$OS" == "windows" ]] && [[ -z "${WT_SESSION:-}" ]] && [[ -z "${TERM_PROGRAM:-}" ]]; then
        RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
    else
        RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
        CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
    fi
}

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }
header() { echo -e "\n${CYAN}${BOLD}$1${NC}"; }

home_dir() { if [[ "$OS" == "windows" ]]; then echo "${USERPROFILE:-$HOME}"; else echo "$HOME"; fi; }

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
        gemini-cli)   echo "$home/.gemini/skills" ;;
        cursor)       echo "$home/.cursor/skills" ;;
        vscode)       echo "$home/.copilot/skills" ;;
        codex)        echo "$home/.codex/skills" ;;
        pi)           echo "$home/.pi/agent/skills" ;;
        *)            echo "" ;;
    esac
}

# Map a receipt "tool" value to the canonical agent slug setup.sh accepts.
# setup.sh-written receipts already store the slug (e.g. "claude-code"), but
# install.sh-written receipts store the human DISPLAY name (e.g. "Claude Code",
# "Gemini CLI", "VS Code (Copilot)"). Those embedded spaces would otherwise
# word-split the re-sync command into a bogus --agent token (setup.sh: "Unknown
# option: Code"), aborting the update and leaving the receipt un-re-stamped.
# Recognized slugs pass through unchanged; an unknown value yields the empty
# string so the caller fails loudly instead of mis-invoking setup.sh.
tool_to_slug() {
    case "$1" in
        claude-code|"Claude Code")   echo "claude-code" ;;
        opencode|"OpenCode")         echo "opencode" ;;
        gemini-cli|"Gemini CLI")     echo "gemini-cli" ;;
        codex|"Codex")               echo "codex" ;;
        vscode|"VS Code (Copilot)")  echo "vscode" ;;
        cursor|"Cursor")             echo "cursor" ;;
        pi|"Pi")                     echo "pi" ;;
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

# Emit each element of the receipt "files" array (jq or awk fallback).
manifest_files() {
    local manifest="$1"
    [ -f "$manifest" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r '(.files // [])[]' "$manifest" 2>/dev/null
        return 0
    fi
    awk '
        /"files"[[:space:]]*:[[:space:]]*\[/ { inarr = 1; next }
        inarr && /\]/ { inarr = 0 }
        inarr {
            line = $0
            gsub(/^[[:space:]]+/, "", line); gsub(/[[:space:]]+$/, "", line)
            gsub(/,$/, "", line); gsub(/"/, "", line)
            if (line != "") print line
        }' "$manifest"
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

    if [ ! -f "$manifest" ]; then
        warn "No receipt at $receipt_dir — nothing to update (skipping)"
        return 0
    fi

    local tool rscope old_ver new_ver old_commit new_commit
    tool="$(manifest_field "$manifest" "tool")"
    rscope="$(manifest_field "$manifest" "scope")"; [ -n "$rscope" ] || rscope="global"
    old_ver="$(manifest_field "$manifest" "version")"; [ -n "$old_ver" ] || old_ver="unknown"
    new_ver="$(read_version)"
    # V4: honest transition — the OLD receipt's version+commit → the CURRENT repo's
    # version+commit. A pre-5.0.0 receipt has no "commit" field, so old_commit is
    # empty and only the new side shows a SHA (e.g. "5.0.0-dev → 5.0.0 (416ef29)").
    old_commit="$(manifest_field "$manifest" "commit")"
    new_commit="$(repo_commit)"

    header "Updating $tool ($rscope) — $receipt_dir"
    info "Version: $(fmt_ver_commit "$old_ver" "$old_commit") → $(fmt_ver_commit "$new_ver" "$new_commit")"

    # Snapshot pre-sync hashes of every recorded file.
    local files rel pre
    files="$(manifest_files "$manifest")"
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

    # Normalize the receipt's "tool" to the canonical slug setup.sh accepts.
    # install.sh stores a display name ("Claude Code") whose space would corrupt
    # the delegated command; setup.sh stores the slug already. An unrecognized
    # value is a hard stop — mis-invoking setup.sh would be worse than aborting.
    local slug
    slug="$(tool_to_slug "$tool")"
    if [ -z "$slug" ]; then
        fail "Unrecognized tool in receipt: '$tool' — cannot re-sync $receipt_dir"
        rm -f "$hashfile"
        return 1
    fi

    # Delegate the actual re-sync to the idempotent installer, matching the
    # recorded scope. --without-pi-packages so an update never silently
    # (re)installs the package stack; skills/agents/hooks/orchestrator re-sync.
    # An argv array keeps the slug and any spaced --path intact (no word-splitting).
    local -a args=(--agent "$slug" --non-interactive --without-pi-packages)
    if [ "$rscope" = "project" ]; then
        args+=(--scope project --path "$receipt_dir")
    fi
    if ! bash "$SETUP_SCRIPT" "${args[@]}" >/dev/null 2>&1; then
        fail "Re-sync failed for $tool ($rscope)"
        rm -f "$hashfile"
        return 1
    fi

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

detect_os
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

if [ "$SCOPE" = "project" ]; then
    TARGET_PATH="${TARGET_PATH:-$PWD}"
    resync_target "$TARGET_PATH"
elif [ -n "$AGENT" ]; then
    dir="$(global_skills_path "$AGENT")"
    [ -n "$dir" ] || { fail "Unknown agent: $AGENT"; exit 1; }
    resync_target "$dir"
else
    # No agent given: update every global agent that has a receipt.
    found=false
    for agent in $ALL_AGENTS; do
        dir="$(global_skills_path "$agent")"
        [ -n "$dir" ] || continue
        if [ -f "$dir/$INSTALL_MANIFEST_NAME" ]; then
            found=true
            resync_target "$dir"
        fi
    done
    if ! $found; then
        warn "No global install receipts found — nothing to update."
        info "Run setup.sh first, or pass --scope project --path <repo>."
    fi
fi

echo -e "\n${GREEN}${BOLD}Done.${NC}"
