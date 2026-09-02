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
# --dry-run). Only files the receipt records are pruned — those dirs also hold
# the user's own agents, and their backups are none of update's business.
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
# Repo-side sources a recorded file can be compared against (--dry-run drift).
EXAMPLES_DIR="$REPO_DIR/examples"
SKILLS_SRC="$REPO_DIR/skills"
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

# ============================================================================
# Receipt helpers — home_dir / read_version / read_commit / hash_file and the
# receipt parser now live in scripts/lib/receipt.sh (issue #37), sourced above.
# ============================================================================

# Short commit SHA of the current Kurama repo checkout ('' when git is
# unavailable). Historical name; delegates to the shared read_commit.
repo_commit() { read_commit; }

# Render "version (commit)", collapsing to just "version" when no commit is known.
fmt_ver_commit() {
    local v="$1" c="$2"
    if [ -n "$c" ]; then printf '%s (%s)' "$v" "$c"; else printf '%s' "$v"; fi
}

# Skills dir (= receipt dir for global) for a global agent — the shared
# skills_path() map (issue #37).
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

# manifest_field / manifest_json_array / manifest_tools now live in
# scripts/lib/receipt.sh (issue #37), sourced above.

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

# hash_file() now lives in scripts/lib/receipt.sh (issue #37).

# Map a receipt-relative path back to the repo file it was installed FROM, for
# one harness ("" when the path has no repo source — an omp RULES.md, anything a
# future writer records that is generated rather than copied). Mirrors
# resolve_source in doctor.sh so update's drift preview and doctor's drift check
# answer the same question the same way.
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

# resolve_source against every tool the receipt records, for a file that exists
# on disk. A project-scope receipt is shared by every harness installed into the
# repo and resolve_source maps */agents/* per harness, so no single tool can
# resolve the whole union. Prefers the candidate the installed file actually
# matches — examples/claude-code/agents/sdd-spec.md and examples/pi/agents/
# sdd-spec.md are different files with the same basename, and first-existing
# would report a perfectly in-sync file as drifted. Falls back to the first
# candidate that exists, which keeps a genuinely drifted file reportable.
# Same contract as doctor.sh's copy.
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

# Keep only the NEWEST timestamped backup per RECORDED original file in an
# agents dir. An update re-runs the idempotent installer, which backs up every
# pre-existing agent file (via the shared make_backup: NAME.md.bak.YYYYMMDDHHMMSS)
# before overwriting it — so without pruning, agents/ accumulates one .bak per
# file on every update. Backup names carry a fixed-width, zero-padded timestamp,
# so a lexical sort is chronological: keep the last, delete the rest.
#
# $2 is the newline-separated list of basenames the receipt records for THIS dir,
# and it is the whole safety story. ~/.claude/agents is a shared directory —
# users keep their own agents (and their own hand-made backups) there — so an
# unqualified '*.bak.*' glob deleted files Kurama never created, in a dir Kurama
# does not own. An update may only prune what an update produced.
prune_stale_agent_backups() {
    local dir="$1" recorded="$2"
    [ -d "$dir" ] || return 0
    [ -n "$recorded" ] || return 0
    local pruned=0 orig keep bk
    while IFS= read -r orig; do
        [ -n "$orig" ] || continue
        # A QUOTED literal prefix plus one wildcard — never `find -name
        # "$orig.bak.*"`. $orig is receipt data and find's -name takes a PATTERN,
        # so a glob metacharacter in a recorded agent filename (`?`, `*`, `[`)
        # silently widened the match to OTHER files' backups — and this runs in
        # ~/.claude/agents, a directory shared with the user's own agents and
        # their own hand-made backups, which is precisely what $recorded exists to
        # keep this function away from. Quoting makes the shell read the basename
        # literally and leaves exactly one glob: the timestamp. (#65)
        #
        # The glob expands in sorted order and the timestamp is fixed-width and
        # zero-padded, so the last match is the newest — the one to keep.
        keep=""
        for bk in "$dir/$orig".bak.*; do
            [ -f "$bk" ] || continue
            keep="$bk"
        done
        [ -n "$keep" ] || continue
        for bk in "$dir/$orig".bak.*; do
            [ -f "$bk" ] || continue
            [ "$bk" = "$keep" ] && continue
            rm -f "$bk" && pruned=$((pruned + 1))
        done
    done <<ORIGS
$recorded
ORIGS
    [ "$pruned" -gt 0 ] && info "pruned $pruned stale agent backup(s) in $dir (kept newest per recorded file)"
    return 0
}

# ============================================================================
# #106: rebuild the project skill registry
#
# .kurama/skill-registry.md is the only surface a delegation resolves
# `## Project Standards (skills to load)` from; without it every phase runs blind
# to the repo's conventions (_shared/skill-resolver.md, step 4). The build is a
# shipped script now, not a sub-agent — one process, well under a second.
#
# The builder is read from the CLONE, not from the install: this script already
# runs from the clone and re-syncs everything else from it, so a stale installed
# copy can never be what rebuilds the registry. A missing builder is a broken
# clone and is reported as such — there is no model-scan fallback anywhere.
# ============================================================================
refresh_skill_registry() {
    local root="$1"
    local builder="$REPO_DIR/skills/_shared/build-skill-registry.sh"

    if [ ! -f "$builder" ]; then
        warn "skills/_shared/build-skill-registry.sh is missing from $REPO_DIR — the skill registry was NOT rebuilt"
        return 0
    fi

    local out status=0
    out="$(bash "$builder" --root "$root" 2>&1)" || status=$?
    if [ "$status" -ne 0 ]; then
        warn "The skill registry could not be rebuilt for $root — the rest of the update stands"
        printf '%s\n' "$out" | awk 'NF { print "      " $0 }'
        return 0
    fi
    [ -n "$out" ] && info "$out"
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

    # Normalize each recorded tool to the canonical slug setup.sh accepts.
    # install.sh stores a display name ("Claude Code") whose space would corrupt
    # the delegated command; setup.sh stores the slug already. An unrecognized
    # value is a hard stop — mis-invoking setup.sh would be worse than aborting.
    # Resolve every slug BEFORE installing anything, so a bad entry aborts the
    # target instead of leaving it half re-synced.
    #
    # This runs BEFORE the --dry-run report on purpose. A preview whose whole job
    # is to say what the real run would do must not print a drift report for a
    # target the real run would refuse outright — and an unusable "tools" value is
    # also what makes resolve_source_any resolve nothing, so the same gap produced
    # a confident "no drift" over zero comparisons.
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

    # --dry-run is documented as "report drift, change nothing", and the snapshot
    # above is exactly the data that answers it. It used to be thrown away
    # unread, leaving a constant "would re-sync N recorded file(s)" — the same N
    # for a pristine install and for one whose skills had been hand-edited. The
    # preview a user runs BEFORE the real update has to name what the real update
    # would overwrite, or it is worse than no preview at all.
    if $DRY_RUN; then
        local checked=0 drifted=0 missing=0 unresolved=0 src
        while IFS=$'\t' read -r rel pre; do
            [ -n "$rel" ] || continue
            checked=$((checked + 1))
            if [ ! -e "$receipt_dir/$rel" ]; then
                warn "missing: $rel"
                missing=$((missing + 1))
                continue
            fi
            # No repo source to compare against (generated or merged content):
            # counted, never reported as drift — that would be a false red.
            src="$(resolve_source_any "$rel" "$tools" "$receipt_dir/$rel")"
            if [ -z "$src" ] || [ ! -f "$src" ]; then
                unresolved=$((unresolved + 1))
                continue
            fi
            if [ "$pre" != "$(hash_file "$src")" ]; then
                warn "drift: $rel"
                drifted=$((drifted + 1))
            fi
        done < "$hashfile"
        rm -f "$hashfile"

        # The headline counts only what was actually compared. Reporting it over
        # $checked would let a target where NOTHING resolved to a repo source —
        # every file skipped, zero hashes compared — print "no drift, all N files
        # match": a green light the code never earned, on the script users reach
        # for when they suspect their install is broken. When nothing was
        # comparable, say that instead of a verdict.
        local comparable=$((checked - unresolved))
        local would=$((drifted + missing))
        if [ "$comparable" -eq 0 ]; then
            warn "Nothing comparable — none of the $checked recorded file(s) resolve to a repo source"
            info "This preview cannot tell you whether $receipt_dir drifted."
        elif [ "$would" -gt 0 ]; then
            echo -e "  ${YELLOW}${BOLD}$would of $comparable checked file(s) would be re-synced from $REPO_DIR${NC}"
        else
            info "No drift — all $comparable checked file(s) match $REPO_DIR"
        fi
        if [ "$unresolved" -gt 0 ] && [ "$comparable" -gt 0 ]; then
            info "$unresolved recorded file(s) skipped — no repo source to compare against"
        fi

        # #65: files[] is not the whole install. Kurama also MERGES into files it
        # does not own — the orchestrator block in prompts[], the hooks block in
        # settings[], the sdd-* agents in opencode_configs[], the logo in
        # tui_plugins[], the machine-local block in gitignore[] — and the real
        # update re-merges every one of them. None is
        # byte-comparable against a repo source (the FILE is the user's; only the
        # block inside it is ours), so this preview genuinely cannot report drift
        # for them. What it must not do is stay silent: a headline counted over
        # files[] alone read as the whole blast radius, and for an OpenCode
        # install — where the agent block lives in opencode.json, is not in
        # files[] at all, and is the surface #22 was about — that was a confident
        # wrong answer to the one question --dry-run is asked.
        local merged=0 mkey mcount
        for mkey in settings prompts opencode_configs tui_plugins; do
            mcount="$(manifest_json_array "$manifest" "$mkey" | awk 'NF' | wc -l | tr -d ' ')"
            merged=$((merged + mcount))
        done
        mcount="$(manifest_gitignore "$manifest" | awk 'NF' | wc -l | tr -d ' ')"
        merged=$((merged + mcount))
        if [ "$merged" -gt 0 ]; then
            info "$merged merged file(s) also recorded — the real update re-merges Kurama's block"
            info "into each of them. They are not byte-comparable, so no drift is reported here."
        fi
        return 0
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
        # Capture the delegated run instead of discarding it. Both streams used to
        # go to /dev/null, so every failure reached the user as a bare "Re-sync
        # failed for <slug>" with no cause — on the exact path they walk while
        # recovering a broken install, where the cause IS the answer (a target
        # that stopped being a git repo, a config jq refuses, a read-only dir).
        # Quiet on success: an update that worked has nothing to report here.
        local logfile; logfile="$(mktemp)"
        if ! bash "$SETUP_SCRIPT" "${args[@]}" >"$logfile" 2>&1; then
            fail "Re-sync failed for $slug ($rscope)"
            info "Last lines of the delegated setup.sh run:"
            awk 'NF' "$logfile" | tail -n 15 | while IFS= read -r line; do
                printf '      %s\n' "$line"
            done
            rm -f "$logfile" "$hashfile"
            return 1
        fi
        rm -f "$logfile"
    done

    # #105: the machine-local .gitignore block. The re-sync above delegates to
    # setup.sh with the SAME --scope project --path, and setup ensures the block
    # itself — which is exactly how an install predating #105 acquires one
    # without a second writer to keep in sync. Reported here because the drift
    # report below reads files[] only, and .gitignore is not a files[] entry:
    # Kurama merges a marker block into it, it never owns the file. The manifest
    # was rewritten by the delegated runs, so this reads the fresh receipt.
    if [ "$rscope" = "project" ]; then
        local gfile
        gfile="$(manifest_gitignore "$manifest" | awk 'NF' | head -1)"
        if [ -n "$gfile" ]; then
            ok "machine-local .gitignore block ensured: $gfile"
        else
            info "no machine-local .gitignore block recorded — target is not a git repo, or the write was refused (see the run above)"
        fi

        # #106: refresh .kurama/skill-registry.md, the only surface delegations
        # resolve project standards from. A re-sync is exactly when it goes
        # stale: skills were just re-installed, and a --without run may have
        # removed some. The delegated setup.sh above already rebuilt it, but
        # QUIETLY (its output is captured and only shown on failure), and an
        # update whose whole job is to keep an install honest should say so.
        # Re-running is ~100 ms and byte-identical, so the second build costs
        # nothing and covers a receipt whose delegated run predates this.
        refresh_skill_registry "$receipt_dir"
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
    # file. Only runs on a real update (dry-run returned earlier).
    #
    # Built as one "<abs agents dir>\t<basename>" line per recorded agent file
    # (../agents for global, .claude/.pi agents for project) rather than a bare
    # list of dirs: the dirs are shared with the user's own agents, so the set of
    # files an update may prune backups for is exactly the set the receipt says
    # an update created backups of.
    local rel ad agent_entries=""
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case "$rel" in
            */agents/*.md|agents/*.md)
                agent_entries="$agent_entries
$(dirname "$receipt_dir/$rel")	$(basename "$rel")" ;;
        esac
    done <<EOF
$files
EOF
    agent_entries="$(printf '%s\n' "$agent_entries" | awk 'NF' | sort -u)"
    local agent_dirs
    agent_dirs="$(printf '%s\n' "$agent_entries" | awk -F'\t' 'NF { print $1 }' | sort -u)"
    while IFS= read -r ad; do
        [ -n "$ad" ] || continue
        prune_stale_agent_backups "$ad" \
            "$(printf '%s\n' "$agent_entries" | awk -F'\t' -v d="$ad" '$1 == d { print $2 }')"
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
    echo "  --dry-run        List the recorded files that drifted from the repo, change nothing"
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
