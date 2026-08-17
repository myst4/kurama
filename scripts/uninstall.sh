#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Kurama — Uninstall Script
# Removes exactly what install.sh recorded in each target's install manifest
# (.kurama-install-manifest.json). User-created skills are never touched.
# Supported platforms: macOS and Linux. Bash 3.2 compatible.
#
# Usage:
#   ./uninstall.sh --agent claude-code               # Remove from one global agent
#   ./uninstall.sh --path /custom/skills             # Remove from an explicit dir
#   ./uninstall.sh --scope project --path /repo       # Remove a project-scope install
#   ./uninstall.sh --all                             # Remove from every known target
#   ./uninstall.sh --agent codex --dry-run           # Show what would be removed
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared receipt library — the single copy of the receipt parser and helpers
# (issue #37). SCRIPT_DIR resolves to the clone, so this always finds it; fail
# loud on a partial clone rather than running with an undefined parser — the
# parser this script drives `rm` from.
KURAMA_LIB="$SCRIPT_DIR/lib/receipt.sh"
if [ ! -f "$KURAMA_LIB" ]; then
    echo "kurama: missing $KURAMA_LIB — incomplete clone. Re-clone or pull the full repo." >&2
    exit 1
fi
# shellcheck source=lib/receipt.sh disable=SC1091
. "$KURAMA_LIB"
command -v manifest_json_array >/dev/null 2>&1 || { echo "kurama: scripts/lib/receipt.sh is present but did not define the receipt parser" >&2; exit 1; }

INSTALL_MANIFEST_NAME=".kurama-install-manifest.json"

# Orchestrator marker pair — the block setup.sh merges into a shared prompt file.
# uninstall strips exactly this block on removal, leaving user content intact.
MARKER_BEGIN="<!-- BEGIN:kurama -->"
MARKER_END="<!-- END:kurama -->"

# Agents install.sh can write skills for (project-local is opt-in via --agent).
ALL_AGENTS="claude-code opencode codex pi omp"

DRY_RUN=false
SCOPE="global"       # global | project (O1: mirrors setup.sh)
# Set by remove_target when it refuses a target or refuses a recorded entry.
# A GLOBAL flag rather than a non-zero return, because remove_target must be
# called BARE: routing it through `|| FLAG=1` puts it in a condition context,
# and bash suppresses errexit for the whole extent of that — for the entire body
# of the one function in this script that calls rm. A `rm` or a `printf > tmp`
# that failed would then be swallowed, and the run would report a file "removed"
# that is still on disk, or mv a truncated settings.json into place, while
# exiting 0.
UNINSTALL_FAILED=0
TARGET_PATH=""       # repo root for project scope, or explicit dir for --path
PI_PACKAGES=""       # "", "yes", or "no" — O3 Pi package revert offer

# ============================================================================
# Colors
# ============================================================================

setup_colors() {
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
}

print_ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
print_warn() { echo -e "  ${YELLOW}!${NC} $1"; }
print_error(){ echo -e "  ${RED}✗${NC} $1"; }
print_info() { echo -e "  ${CYAN}→${NC} $1"; }

# ============================================================================
# Path resolution (kept in sync with install.sh get_tool_path)
# ============================================================================

# The five harness skills paths come from the shared skills_path() map (issue
# #37, which honors PI_CODING_AGENT_DIR for omp); project-local stays here.
get_tool_path() {
    local tool="$1"
    case "$tool" in
        project-local) echo "./skills" ;;
        *)             skills_path "$tool" ;;
    esac
}

# ============================================================================
# Manifest parsing — manifest_json_array / manifest_field / manifest_files /
# manifest_tools now live in scripts/lib/receipt.sh (issue #37), sourced above.
# uninstall.sh drives `rm` from what those emit, which is exactly why the parser
# is now a single shared copy that the empty-array fix can never miss again.
# ============================================================================

# O3: surgically strip the Kurama PreToolUse hooks block (entries whose command
# contains "hooks/kurama/") from a settings.json, leaving every other hook and
# key untouched. Backs up + writes atomically. jq only — never sed on JSON.
remove_hooks_from_settings() {
    local settings_file="$1"
    [ -f "$settings_file" ] || return 0

    if ! command -v jq >/dev/null 2>&1; then
        print_warn "jq not found — cannot strip the hooks block from $settings_file"
        print_info "Manually remove PreToolUse entries pointing at hooks/kurama/"
        return 0
    fi

    if $DRY_RUN; then
        print_info "would strip kurama hooks block from: $settings_file"
        return 0
    fi

    local cleaned
    cleaned=$(jq '
        if (.hooks.PreToolUse | type) == "array" then
            .hooks.PreToolUse = (.hooks.PreToolUse | map(select(
                (((.hooks // []) | map(.command // "") | join(" "))
                    | contains("hooks/kurama/")) | not)))
        else . end
        | if (.hooks.PreToolUse | type) == "array" and (.hooks.PreToolUse | length) == 0
            then del(.hooks.PreToolUse) else . end
        | if (.hooks | type) == "object" and (.hooks | length) == 0
            then del(.hooks) else . end
    ' "$settings_file") || { print_warn "failed to clean $settings_file"; UNINSTALL_FAILED=1; return 0; }

    local tmp
    tmp="$(mktemp "${settings_file}.XXXXXX")"
    cp -p "$settings_file" "${settings_file}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    printf '%s\n' "$cleaned" > "$tmp"
    mv "$tmp" "$settings_file"
    print_ok "stripped kurama hooks block from settings.json"
}

# O5 (uninstall): strip the Engram MCP registration Kurama wrote into a client
# config recorded in the receipt's engram_mcp[]. JSON configs (mcpServers / mcp /
# servers keyed) are edited with jq — never sed — deleting only the "engram" entry
# and any parent object it emptied; the Codex config.toml block is removed with the
# SAME awk method setup used to write it. Backup + atomic; every other server and
# top-level key is preserved. Without jq a JSON config prints guided manual steps.
remove_engram_from_config() {
    local file="$1"
    [ -f "$file" ] || return 0

    if $DRY_RUN; then
        print_info "would strip the Engram MCP registration from: $file"
        return 0
    fi

    case "$file" in
        *.toml)
            # Codex TOML: drop the [mcp_servers.engram] block up to the next section
            # header or EOF (mirror of setup.sh register_engram_codex's strip).
            local stripped tmp
            stripped="$(awk '
                /^\[mcp_servers\.engram\]/ { skip=1; next }
                skip && /^\[/ { skip=0 }
                !skip { print }
            ' "$file")"
            tmp="$(mktemp "${file}.XXXXXX")" || { print_warn "mktemp failed for $file"; return 0; }
            cp -p "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
            printf '%s\n' "$stripped" > "$tmp"
            mv "$tmp" "$file"
            print_ok "stripped Engram MCP block from $file (codex TOML)"
            ;;
        *)
            if ! command -v jq >/dev/null 2>&1; then
                print_warn "jq not found — cannot strip the Engram MCP server from $file"
                print_info "Manually remove the \"engram\" entry under mcpServers / mcp / servers"
                return 0
            fi
            local cleaned tmp
            cleaned=$(jq '
                (if (.mcpServers | type) == "object" then .mcpServers |= del(.engram) else . end)
                | (if (.mcp | type) == "object" then .mcp |= del(.engram) else . end)
                | (if (.servers | type) == "object" then .servers |= del(.engram) else . end)
                | (if (.mcpServers | type) == "object" and (.mcpServers | length) == 0 then del(.mcpServers) else . end)
                | (if (.mcp | type) == "object" and (.mcp | length) == 0 then del(.mcp) else . end)
                | (if (.servers | type) == "object" and (.servers | length) == 0 then del(.servers) else . end)
            ' "$file") || { print_warn "failed to clean $file"; return 0; }
            tmp="$(mktemp "${file}.XXXXXX")" || { print_warn "mktemp failed for $file"; return 0; }
            cp -p "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
            printf '%s\n' "$cleaned" > "$tmp"
            mv "$tmp" "$file"
            print_ok "stripped Engram MCP registration from $file"
            ;;
    esac
}

# Strip the Kurama TUI logo plugin from an OpenCode tui.json recorded in the
# receipt's tui_plugins[]. Mirrors gentle-ai's removeTUIPlugin: drop every
# plugin[] entry pointing at tui-plugins/kurama-logo.tsx and leave the rest of
# the file — $schema, other plugins, unrelated keys — exactly as it was. Matching
# on the suffix (not the absolute path) keeps removal working when the receipt
# was written under a different HOME. jq only (never sed on JSON); backup +
# atomic. The plugin .tsx itself is recorded in files[] and removed with them.
remove_tui_plugin_from_config() {
    local file="$1"
    [ -f "$file" ] || return 0

    if ! command -v jq >/dev/null 2>&1; then
        # The real-run jq-less case is refused up front (see the tui.json guard in
        # remove_target, before any file is removed). This branch is reached only
        # in --dry-run, where nothing is deleted; print the EXACT manual step so a
        # user without jq still knows precisely what to de-register.
        print_warn "jq not found — cannot strip the Kurama logo entry from $file"
        print_info "De-register it by hand: remove the plugin[] array entry ending in"
        print_info "  \"tui-plugins/kurama-logo.tsx\" from $file"
        return 0
    fi
    if ! jq -e . "$file" >/dev/null 2>&1; then
        print_warn "$file is not valid JSON — leaving it untouched"
        return 0
    fi

    # Nothing of ours registered → leave the file (and its mtime) alone.
    jq -e '[(.plugin // [])[]
        | select(if type == "string"
                 then endswith("tui-plugins/kurama-logo.tsx") else false end)]
        | length > 0' "$file" >/dev/null 2>&1 || return 0

    if $DRY_RUN; then
        print_info "would strip the Kurama logo plugin from: $file"
        return 0
    fi

    local cleaned tmp
    cleaned=$(jq '
        .plugin = ((.plugin // []) | map(select(
            (if type == "string"
             then endswith("tui-plugins/kurama-logo.tsx") else false end) | not)))
    ' "$file") || { print_warn "failed to clean $file"; UNINSTALL_FAILED=1; return 0; }
    tmp="$(mktemp "${file}.XXXXXX")" || { print_warn "mktemp failed for $file"; return 0; }
    cp -p "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    printf '%s\n' "$cleaned" > "$tmp"
    mv "$tmp" "$file"
    print_ok "stripped the Kurama logo plugin from $file"
}

# Strip Kurama's orchestrator block (BEGIN:kurama … END:kurama) from a prompt file
# recorded in the receipt's prompts[]. Only strips when BOTH markers are present —
# an unbalanced pair is left untouched to avoid deleting user content. Everything
# outside the block is preserved; backup + atomic.
strip_markers_from_prompt() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -qF "$MARKER_BEGIN" "$file" || return 0
    if ! grep -qF "$MARKER_END" "$file"; then
        print_warn "unbalanced kurama markers in $file — leaving it untouched"
        return 0
    fi

    if $DRY_RUN; then
        print_info "would strip the kurama orchestrator block from: $file"
        return 0
    fi

    local stripped tmp
    stripped="$(awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
        $0 == b { skip=1; next }
        $0 == e { skip=0; next }
        !skip   { print }
    ' "$file")"
    tmp="$(mktemp "${file}.XXXXXX")" || { print_warn "mktemp failed for $file"; return 0; }
    cp -p "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    printf '%s\n' "$stripped" > "$tmp"
    mv "$tmp" "$file"
    print_ok "stripped kurama orchestrator block from $file"
}

# #22: strip Kurama's agent block from an opencode.json recorded in the receipt's
# opencode_configs[]. setup.sh MERGES into that file — it is the user's config,
# not ours — so removal is surgical: every "sdd-*" key plus the profile's
# "kurama-orchestrator" go, and every other agent, model choice and top-level key
# stays. Mirrors the settings.json/tui.json strips: jq only (never sed on JSON),
# backup + atomic, and a no-op when nothing of ours is registered.
remove_kurama_agents_from_opencode_config() {
    local file="$1"
    [ -f "$file" ] || return 0

    if ! command -v jq >/dev/null 2>&1; then
        print_warn "jq not found — cannot strip the Kurama agents from $file"
        print_info "Manually remove the \"sdd-*\" agents (and \"kurama-orchestrator\") under .agent"
        return 0
    fi
    if ! jq -e . "$file" >/dev/null 2>&1; then
        print_warn "$file is not valid JSON — leaving it untouched"
        return 0
    fi

    # Nothing of ours in there → leave the file (and its mtime) alone.
    jq -e '[((.agent // {}) | keys[])
        | select(startswith("sdd-") or . == "kurama-orchestrator")]
        | length > 0' "$file" >/dev/null 2>&1 || return 0

    if $DRY_RUN; then
        print_info "would strip the Kurama sdd-* agents from: $file"
        return 0
    fi

    local cleaned tmp
    cleaned=$(jq '
        (.agent // {}) as $a
        | .agent = ($a | with_entries(select(
            ((.key | startswith("sdd-")) or (.key == "kurama-orchestrator")) | not)))
        | if (.agent | length) == 0 then del(.agent) else . end
    ' "$file") || { print_warn "failed to clean $file"; return 0; }
    tmp="$(mktemp "${file}.XXXXXX")" || { print_warn "mktemp failed for $file"; return 0; }
    cp -p "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    printf '%s\n' "$cleaned" > "$tmp"
    mv "$tmp" "$file"
    print_ok "stripped the Kurama sdd-* agents from $file"
}

# Count of artifacts the legacy sweep below removed, added to the target's total
# so the "N file(s) removed" line stays honest.
LEGACY_SWEEP_REMOVED=0

# #22: the OpenCode counterpart of the background-agents sweep. Until this
# release setup.sh recorded NONE of what setup_opencode wrote, so every receipt
# written before it lists neither the nine /sdd-* command files, nor the global
# AGENTS.md, nor opencode.json — and uninstall reported "Done." with all twelve
# still on disk, the commands still routing to agents that no longer existed.
# Recorded installs are handled by files[]/prompts[]/opencode_configs[] above;
# this pass is what makes a PRE-EXISTING install removable, and it is a no-op
# once those records exist.
sweep_legacy_opencode_artifacts() {
    local scope="$1"
    LEGACY_SWEEP_REMOVED=0
    # The OpenCode flow is global-only (project scope gets the plain orchestrator
    # merge), so these fixed ~/.config/opencode paths are the only ones it wrote.
    [ "$scope" = "project" ] && return 0

    local base="$HOME/.config/opencode"
    local f
    for f in "$base"/commands/sdd-*.md; do
        [ -f "$f" ] || continue
        if $DRY_RUN; then
            print_info "would remove (unrecorded by this receipt): ${f#"$HOME"/}"
        else
            rm -f "$f"
            print_ok "removed: ${f#"$HOME"/}"
        fi
        LEGACY_SWEEP_REMOVED=$((LEGACY_SWEEP_REMOVED + 1))
    done
    rmdir "$base/commands" 2>/dev/null || true

    # AGENTS.md. A current install carries the BEGIN:kurama block and is handled
    # by the prompts[] strip — never touched here. A pre-marker install is the
    # example file copied whole, which its GENERATED header identifies exactly:
    # only then is deleting it right, because Kurama wrote every byte of it.
    local agents_md="$base/AGENTS.md"
    if [ -f "$agents_md" ] && ! grep -qF "$MARKER_BEGIN" "$agents_md"; then
        if head -1 "$agents_md" | grep -qF 'GENERATED FILE' \
            && grep -qF 'Kurama Orchestrator' "$agents_md"; then
            if $DRY_RUN; then
                print_info "would remove (unrecorded by this receipt): ${agents_md#"$HOME"/}"
            else
                rm -f "$agents_md"
                print_ok "removed: ${agents_md#"$HOME"/}"
            fi
            LEGACY_SWEEP_REMOVED=$((LEGACY_SWEEP_REMOVED + 1))
        elif grep -qF 'Kurama Orchestrator' "$agents_md"; then
            print_warn "$agents_md carries orchestrator content with no kurama markers — left in place"
            print_info "Remove the Kurama section by hand if you no longer want it"
        fi
    fi

    # opencode.json: same surgical strip as the recorded path, and a no-op when
    # the recorded pass already ran.
    remove_kurama_agents_from_opencode_config "$base/opencode.json"
}

# O3: offer to revert the Pi packages Kurama installed (recorded in the receipt).
# Honors --with/--without-pi-packages; otherwise asks interactively (default no,
# so a shared package set is never removed by surprise). Never touches gentle-pi
# and never removes anything not recorded.
offer_pi_uninstall() {
    local manifest="$1"
    local pkgs
    pkgs="$(manifest_json_array "$manifest" "pi_packages")"
    [ -n "$pkgs" ] || return 0

    echo -e "\n${BOLD}This install recorded these Pi packages:${NC}"
    printf '%s\n' "$pkgs" | while IFS= read -r p; do [ -n "$p" ] && echo "  - $p"; done

    case "$PI_PACKAGES" in
        yes) ;;
        no)  print_info "Leaving Pi packages installed (--without-pi-packages)"; return 0 ;;
        *)
            print_info "Uninstall these Pi packages too? (they may be shared with other tools)"
            read -rp "  Revert Pi packages? [y/N]: " ans
            [[ "${ans:-N}" =~ ^[Yy] ]] || { print_info "Leaving Pi packages installed"; return 0; }
            ;;
    esac

    if ! command -v pi >/dev/null 2>&1; then
        print_warn "pi not found in PATH — cannot revert packages (skipping)"
        return 0
    fi

    local p
    printf '%s\n' "$pkgs" | while IFS= read -r p; do
        [ -n "$p" ] || continue
        if $DRY_RUN; then
            print_info "would run: pi uninstall $p"
        else
            if pi uninstall "$p" >/dev/null 2>&1; then
                print_ok "pi uninstall $p"
            else
                print_warn "pi uninstall $p failed (continuing)"
            fi
        fi
    done
}

# ============================================================================
# #33: receipt path containment
#
# remove_target drives `rm` straight from the receipt's files[]. In project scope
# that receipt lives INSIDE the target repo, so its contents are supplied by
# whoever wrote that repo — not by Kurama — and an entry that resolves outside
# the install tree must never be acted on.
#
# The bound is NOT simply the receipt dir. setup.sh's receipt_rel deliberately
# emits ../-anchored entries for a global install: skills live in
# ~/.claude/skills, but the agents, hooks and settings.json it also writes are
# SIBLINGS of that dir, so 20 of a healthy claude-code receipt's 52 files[]
# entries start with "../". Rejecting every ".." would orphan all of them. The
# bound is exactly what receipt_rel can produce — the receipt dir for a project
# receipt, its PARENT for a global one — and nothing else is removable.

# Collapse "." and ".." components in a path, textually. No filesystem access, so
# it answers the same way for a path that does not exist and cannot be walked
# past by a component that only becomes interesting once resolved.
normalize_abs_path() {
    local rest="$1" out="" comp
    while [ -n "$rest" ]; do
        comp="${rest%%/*}"
        if [ "$comp" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
        case "$comp" in
            ''|.) ;;
            ..)   out="${out%/*}" ;;
            *)    out="$out/$comp" ;;
        esac
    done
    printf '%s' "${out:-/}"
}

# True when $2 is STRICTLY inside $1. The root itself is never a recorded file,
# and never a directory the prune walk below may remove.
path_within_root() {
    local root="$1" path="$2"
    [ -n "$root" ] || return 1
    case "$path" in
        "$root"/*) return 0 ;;
        *)         return 1 ;;
    esac
}

# The tree every recorded path must stay inside, for a receipt in $1 with scope $2.
receipt_containment_root() {
    local dir_abs="$1" rscope="$2"
    if [ "$rscope" = "project" ]; then
        printf '%s' "$dir_abs"
    else
        dirname "$dir_abs"
    fi
}

# ============================================================================
# Removal
# ============================================================================

remove_target() {
    local dir="$1"
    local label="$2"
    local manifest="$dir/$INSTALL_MANIFEST_NAME"

    if [ ! -f "$manifest" ]; then
        print_warn "$label: no install manifest at $dir (nothing recorded — skipping)"
        return 0
    fi

    echo -e "\n${BOLD}Uninstalling from $label${NC} ($dir)"

    # Absolute form of the target dir, plus the tree every recorded path has to
    # stay inside (see receipt_containment_root).
    local dir_abs rscope root_abs root_phys effective_scope
    dir_abs="$(cd "$dir" 2>/dev/null && pwd)" || dir_abs=""
    if [ -z "$dir_abs" ]; then
        case "$dir" in
            /*) dir_abs="$(normalize_abs_path "$dir")" ;;
            *)  dir_abs="$(normalize_abs_path "$PWD/$dir")" ;;
        esac
    fi

    # The receipt's own "scope" is NOT authority over how far this script may
    # reach. In project scope the receipt lives inside the target repo, so its
    # scope field is written by whoever wrote that repo: a hostile receipt
    # claiming "global" (or omitting the field, which defaults to global) turned
    # the bound into the PARENT of the repo, and the documented
    # `uninstall.sh --scope project --path <repo>` then reached ../.ssh/id_rsa.
    # Take the NARROWER of how the target was addressed (SCOPE) and what the
    # receipt claims (rscope); the field is a hint, never a widening permission.
    rscope="$(manifest_field "$manifest" "scope")"; [ -n "$rscope" ] || rscope="global"
    effective_scope="global"
    if [ "$SCOPE" = "project" ] || [ "$rscope" = "project" ]; then
        effective_scope="project"
    fi
    root_abs="$(receipt_containment_root "$dir_abs" "$effective_scope")"

    # Physically resolved root. Containment is checked against THIS, because rm
    # resolves symlinks and normalize_abs_path does not (see the rm loop below).
    root_phys="$(cd -P "$root_abs" 2>/dev/null && pwd -P)" || root_phys=""
    if [ -z "$root_phys" ]; then
        print_error "$label: cannot resolve the containment root ($root_abs) — refusing"
        UNINSTALL_FAILED=1
        return 0
    fi

    # Filter files[] down to the entries that really belong to this install
    # BEFORE anything is removed. Both the rm loop and the prune walk read the
    # filtered list, so a rejected entry can neither delete a file nor let rmdir
    # climb out of the tree.
    local raw_files files unsafe=0 rel
    raw_files="$(manifest_files "$manifest")"
    files=""
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case "$rel" in
            /*)
                print_warn "$label: refusing absolute receipt entry: $rel"
                unsafe=$((unsafe + 1))
                continue
                ;;
        esac
        if ! path_within_root "$root_abs" "$(normalize_abs_path "$dir_abs/$rel")"; then
            print_warn "$label: refusing receipt entry that resolves outside $root_abs: $rel"
            unsafe=$((unsafe + 1))
            continue
        fi
        files="${files}${rel}
"
    done <<EOF
$raw_files
EOF

    # jq-optional + integrity invariant: the kurama hooks block can only be
    # stripped from settings.json when jq is present AND the file parses. Without
    # jq — or WITH jq but an unparseable settings.json (jq errors, the strip
    # below fails) — remove_hooks_from_settings can only warn AFTER the files[]
    # sweep has already deleted the hook SCRIPTS, leaving settings.json invoking
    # executables that no longer exist and the run exiting 0. A jq -e . probe
    # inside this pre-flight guard catches the unparseable-JSON case too. Detect
    # either here, before a single file is removed, and refuse the whole target.
    local settings sfile spath blocked_settings="" have_jq=0
    command -v jq >/dev/null 2>&1 && have_jq=1
    settings="$(manifest_json_array "$manifest" "settings")"
    while IFS= read -r sfile; do
        [ -n "$sfile" ] || continue
        spath="$dir/$sfile"
        [ -f "$spath" ] || continue
        # Textual probe, not a JSON parse: setup.sh embeds "hooks/kurama/" in
        # every command it writes. No match means nothing of ours is in there
        # and there is nothing for jq to strip, so the run may proceed.
        grep -qF 'hooks/kurama/' "$spath" 2>/dev/null || continue
        # With jq AND a file that parses, the strip below will succeed — nothing
        # to block. Only jq-absent, or jq-present-but-unparseable, reach here.
        if [ "$have_jq" -eq 1 ] && jq -e . "$spath" >/dev/null 2>&1; then
            continue
        fi
        # Normalized for display: the recorded form is ../settings.json, and
        # telling a user to hand-edit ".../skills/../settings.json" when they
        # have to find the file themselves is worse than not telling them.
        blocked_settings="${blocked_settings}$(normalize_abs_path "$dir_abs/$sfile")
"
    done <<EOF
$settings
EOF
    if [ -n "$blocked_settings" ]; then
        local settings_why
        if [ "$have_jq" -eq 1 ]; then
            settings_why="settings.json is not valid JSON"
        else
            settings_why="jq not found"
        fi
        if $DRY_RUN; then
            print_warn "$label: $settings_why — a real run would REFUSE this target"
            print_info "the kurama hooks block cannot be stripped from settings.json"
        else
            print_error "$label: $settings_why — cannot strip the kurama hooks block"
            print_info "Nothing was removed. Deleting the hook scripts while settings.json"
            print_info "still invokes them breaks every Edit/Write in the harness."
            print_info "Install jq / repair the JSON and re-run, or remove these by hand first:"
            while IFS= read -r spath; do
                if [ -n "$spath" ]; then
                    print_info "  every PreToolUse entry whose command contains 'hooks/kurama/' in:"
                    print_info "    $spath"
                fi
            done <<EOF
$blocked_settings
EOF
            local hookfiles
            hookfiles="$(printf '%s\n' "$files" | grep -F 'hooks/kurama/' || true)"
            if [ -n "$hookfiles" ]; then
                print_info "  then these hook scripts:"
                while IFS= read -r rel; do
                    if [ -n "$rel" ]; then
                        print_info "    $(normalize_abs_path "$dir_abs/$rel")"
                    fi
                done <<EOF
$hookfiles
EOF
            fi
            # Flag rather than `return 1`: the caller invokes remove_target BARE
            # so that `set -e` stays armed for this function's body, and a
            # non-zero return would abort the whole run instead of letting --all
            # sweep the remaining targets.
            UNINSTALL_FAILED=1
            return 0
        fi
    fi

    # jq-optional + integrity invariant (issue #40): the Kurama logo entry can only
    # be stripped from tui.json when jq is present AND the file parses. Without jq —
    # or WITH jq but an unparseable tui.json — the strip cannot run, yet the files[]
    # sweep below deletes the plugin .tsx it points at, leaving tui.json's plugin[]
    # referencing a file that is gone: a dangling TUI plugin that breaks OpenCode's
    # TUI on next start. A jq -e . probe inside this pre-flight guard catches the
    # unparseable-JSON case too. Detect either here, before a single file is
    # removed, and refuse the whole target — as the settings.json guard above does.
    local tfile tpath blocked_tui="" tui_plugins_pf
    tui_plugins_pf="$(manifest_json_array "$manifest" "tui_plugins")"
    while IFS= read -r tfile; do
        [ -n "$tfile" ] || continue
        case "$tfile" in
            /*) tpath="$(normalize_abs_path "$tfile")" ;;
            *)  tpath="$(normalize_abs_path "$dir_abs/$tfile")" ;;
        esac
        [ -f "$tpath" ] || continue
        # Textual probe, not a JSON parse: setup.sh registers the logo as a
        # plugin[] string ending in tui-plugins/kurama-logo.tsx. No match means
        # nothing of ours is registered and there is nothing for jq to strip.
        grep -qF 'tui-plugins/kurama-logo.tsx' "$tpath" 2>/dev/null || continue
        # With jq AND a file that parses, the strip will succeed — nothing to
        # block. Only jq-absent, or jq-present-but-unparseable, reach here.
        if [ "$have_jq" -eq 1 ] && jq -e . "$tpath" >/dev/null 2>&1; then
            continue
        fi
        blocked_tui="${blocked_tui}$tpath
"
    done <<EOF
$tui_plugins_pf
EOF
    if [ -n "$blocked_tui" ]; then
        local tui_why
        if [ "$have_jq" -eq 1 ]; then
            tui_why="tui.json is not valid JSON"
        else
            tui_why="jq not found"
        fi
        if $DRY_RUN; then
            print_warn "$label: $tui_why — a real run would REFUSE this target"
            print_info "the Kurama logo entry cannot be stripped from tui.json"
        else
            print_error "$label: $tui_why — cannot strip the Kurama logo from tui.json"
            print_info "Nothing was removed. Deleting the logo plugin while tui.json still"
            print_info "references it leaves OpenCode's TUI loading a plugin that is gone."
            print_info "Install jq / repair the JSON and re-run, or de-register by hand — remove"
            print_info "the plugin[] array entry ending in \"tui-plugins/kurama-logo.tsx\" from:"
            while IFS= read -r tpath; do
                [ -n "$tpath" ] && print_info "    $tpath"
            done <<EOF
$blocked_tui
EOF
            UNINSTALL_FAILED=1
            return 0
        fi
    fi

    # The lexical filter above cannot see a symlinked INTERMEDIATE DIRECTORY:
    # normalize_abs_path is textual, but rm resolves that component. In project
    # scope both halves come from the target repo — git versions symlinks, so
    # `repo/evil -> /home/u/.ssh` plus a recorded "evil/id_rsa" passed the
    # textual check as "inside the repo" and then deleted the real key. So the
    # parent is resolved PHYSICALLY here and the very same resolved path is what
    # gets checked and removed — no gap between what was validated and what is
    # deleted. (A recorded file that is itself a symlink stays safe either way:
    # rm -f unlinks the link, never what it points at.)
    local removed=0 target tbase tdir tparent prune_dirs=""
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        tbase="${rel##*/}"
        tdir="${rel%/*}"
        if [ "$tdir" = "$rel" ]; then tdir="."; fi
        tparent="$(cd -P "$dir/$tdir" 2>/dev/null && pwd -P)" || tparent=""
        # No parent directory on disk means nothing recorded there is left to
        # remove — not a rejection, just an entry that is already gone.
        [ -n "$tparent" ] || continue
        target="$tparent/$tbase"
        if ! path_within_root "$root_phys" "$target"; then
            print_warn "$label: refusing receipt entry that resolves outside $root_phys: $rel"
            unsafe=$((unsafe + 1))
            continue
        fi
        # Banked for the prune walk, resolved HERE while $dir is still on disk.
        # The walk cannot re-resolve these itself: it removes $dir partway
        # through, and every ../-anchored entry is expressed relative to it.
        prune_dirs="${prune_dirs}${tparent}
"
        if [ -e "$target" ]; then
            if $DRY_RUN; then
                print_info "would remove: $rel"
            else
                rm -f "$target"
                print_ok "removed: $rel"
            fi
            removed=$((removed + 1))
        fi
    done <<EOF
$files
EOF

    # A tampered receipt is not a clean uninstall. Whatever was legitimately
    # recorded has still been removed, but the run must not look identical to an
    # untampered one from the outside.
    if [ "$unsafe" -gt 0 ]; then
        print_warn "$label: $unsafe receipt entry/entries refused — a receipt may only name paths under $root_phys"
        UNINSTALL_FAILED=1
    fi

    # O3: strip the Kurama hooks block from every settings.json the receipt
    # recorded, then offer to revert any recorded Pi packages. Both read the
    # manifest, so they must run BEFORE it is deleted. settings[] was already
    # read above, where the jq-less case is caught before anything is removed.
    while IFS= read -r sfile; do
        [ -n "$sfile" ] || continue
        remove_hooks_from_settings "$dir/$sfile"
    done <<EOF
$settings
EOF

    # Strip the Engram MCP registration from every config the receipt recorded
    # (engram_mcp[]). Entries are relative to $dir, except the global Claude
    # ~/.claude.json which is recorded absolute — honor both.
    local efile engram_files
    engram_files="$(manifest_json_array "$manifest" "engram_mcp")"
    while IFS= read -r efile; do
        [ -n "$efile" ] || continue
        case "$efile" in
            /*) remove_engram_from_config "$efile" ;;
            *)  remove_engram_from_config "$dir/$efile" ;;
        esac
    done <<EOF
$engram_files
EOF

    # Strip the kurama orchestrator marker block from each recorded prompt file
    # (prompts[]), preserving the user's surrounding content. Same relative/absolute
    # handling as engram_mcp above.
    local pfile prompts
    prompts="$(manifest_json_array "$manifest" "prompts")"
    while IFS= read -r pfile; do
        [ -n "$pfile" ] || continue
        case "$pfile" in
            /*) strip_markers_from_prompt "$pfile" ;;
            *)  strip_markers_from_prompt "$dir/$pfile" ;;
        esac
    done <<EOF
$prompts
EOF

    # Strip the Kurama logo entry from every opencode tui.json the receipt
    # recorded (tui_plugins[]). Same relative/absolute handling as above.
    local tfile tui_files
    tui_files="$(manifest_json_array "$manifest" "tui_plugins")"
    while IFS= read -r tfile; do
        [ -n "$tfile" ] || continue
        case "$tfile" in
            /*) remove_tui_plugin_from_config "$tfile" ;;
            *)  remove_tui_plugin_from_config "$dir/$tfile" ;;
        esac
    done <<EOF
$tui_files
EOF

    # Strip Kurama's sdd-* agent block from every opencode.json the receipt
    # recorded (opencode_configs[]). Same relative/absolute handling as above.
    local ofile opencode_configs
    opencode_configs="$(manifest_json_array "$manifest" "opencode_configs")"
    while IFS= read -r ofile; do
        [ -n "$ofile" ] || continue
        case "$ofile" in
            /*) remove_kurama_agents_from_opencode_config "$ofile" ;;
            *)  remove_kurama_agents_from_opencode_config "$dir/$ofile" ;;
        esac
    done <<EOF
$opencode_configs
EOF

    # Remove the legacy background-agents.ts plugin. Older Kurama versions
    # installed it unconditionally; it is no longer shipped (it hangs the
    # OpenCode TUI), so uninstall must clear it even though no receipt lists it.
    local legacy_plugin="$HOME/.config/opencode/plugins/background-agents.ts"
    if [ -f "$legacy_plugin" ]; then
        rm -f "$legacy_plugin"
        print_ok "Removed legacy background-agents plugin: $legacy_plugin"
    fi

    # Same idea, one release later: an OpenCode receipt written before #22
    # records none of what setup_opencode wrote. Sweep those artifacts too —
    # gated on this receipt actually recording opencode, so removing claude-code
    # never reaches into ~/.config/opencode.
    # Driven by the EFFECTIVE scope, not the receipt's claim: the sweep reaches
    # into fixed $HOME/.config/opencode paths and only early-returns on
    # "project", so a project receipt spoofing "global" would have swept the
    # user's global OpenCode install from a project uninstall.
    if manifest_tools "$manifest" | grep -Fxq -- opencode; then
        sweep_legacy_opencode_artifacts "$effective_scope"
        removed=$((removed + LEGACY_SWEEP_REMOVED))
    fi

    offer_pi_uninstall "$manifest"

    if $DRY_RUN; then
        print_info "would remove: $INSTALL_MANIFEST_NAME"
        print_info "would prune emptied skill directories under $dir"
        echo -e "  ${BOLD}$removed file(s) would be removed${NC}"
        return 0
    fi

    rm -f "$manifest"

    # Prune every directory we emptied. All recorded files were already removed
    # above, so for each one we walk from its parent directory upward toward $dir
    # calling rmdir — which only succeeds on an empty directory, so user-created
    # skills, sibling files, and shared config are always preserved. This handles
    # both skill-relative global paths (sdd-apply/SKILL.md, ../agents/x.md) and the
    # deeper project-scope paths (.claude/skills/sdd-apply/SKILL.md,
    # .claude/hooks/kurama/x.sh) that the single-component strip could not reach.
    #
    # #33: the walk is bounded by the same containment root as the removal above.
    # The old stop condition was `$pdir != $dir`, which the ../-anchored entries a
    # global receipt legitimately carries never satisfy — the walk climbed past
    # ~/.claude toward $HOME and beyond, calling rmdir on everything it found
    # empty on the way up.
    # Walks the physically-resolved parents banked by the rm loop, so it prunes
    # exactly the directories whose contents were validated and removed — and
    # never climbs out of the tree through a symlinked component, which a
    # textual walk would have followed just as rmdir does.
    printf '%s\n' "$prune_dirs" | awk 'NF' | while IFS= read -r pdir; do
        while path_within_root "$root_phys" "$pdir"; do
            rmdir "$pdir" 2>/dev/null || break
            pdir="${pdir%/*}"
        done
    done
    rmdir "$dir_abs" 2>/dev/null || true

    echo -e "  ${GREEN}${BOLD}$removed file(s) removed${NC}"
}

# ============================================================================
# Help
# ============================================================================

show_help() {
    echo "Usage: uninstall.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --agent NAME           Uninstall from a specific agent target (global scope only)"
    echo "  --scope SCOPE          'global' (default) or 'project' (mirrors setup.sh)"
    echo "  --path DIR             Explicit dir (global) or repo root (--scope project)"
    echo "  --all                  Uninstall from every known global agent target"
    echo "  --with-pi-packages     Also revert recorded Pi packages (pi uninstall)"
    echo "  --without-pi-packages  Never revert Pi packages (leave them installed)"
    echo "  --dry-run              Show what would be removed without deleting"
    echo "  -h, --help             Show this help"
    echo ""
    echo "Agents: claude-code, opencode, codex, pi, omp, project-local"
    echo ""
    echo "Only files recorded in each target's $INSTALL_MANIFEST_NAME are removed, and only"
    echo "when they resolve inside the tree that install wrote to — a recorded path that"
    echo "points anywhere else is refused, never deleted."
    echo "The recorded settings.json hooks block, the Engram MCP registration, and the"
    echo "orchestrator BEGIN:kurama block are stripped surgically; other keys/content stay."
    echo ""
    echo "A project install writes ONE receipt in the repo root, shared by every harness"
    echo "installed there, so '--scope project' uninstall is all-or-nothing: --agent is"
    echo "rejected there rather than silently removing every harness."
}

# ============================================================================
# Main
# ============================================================================

setup_colors

AGENT=""
CUSTOM_PATH=""
ALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)   AGENT="$2"; shift 2 ;;
        --path)    CUSTOM_PATH="$2"; shift 2 ;;
        --scope)
            case "$2" in
                global|project) SCOPE="$2"; shift 2 ;;
                *) echo "Invalid scope: $2 (use 'global' or 'project')"; exit 1 ;;
            esac
            ;;
        --with-pi-packages)    PI_PACKAGES="yes"; shift ;;
        --without-pi-packages) PI_PACKAGES="no"; shift ;;
        --all)     ALL=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *)  echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# #33: --agent means nothing for a project uninstall, and pretending otherwise
# was destructive. A project install writes ONE receipt in the repo root, shared
# by every harness installed there: its files[], prompts[] and settings[] are the
# union across them, with no per-tool attribution. --agent was only interpolated
# into the label, so `--agent claude-code --scope project` removed every
# harness's files and stripped the kurama block from BOTH CLAUDE.md and AGENTS.md
# while printing "Uninstalling from project (claude-code)". Per-tool attribution
# needs a receipt schema that records it (#37); until then a project uninstall is
# all-or-nothing and says so rather than guessing. setup.sh's own undo hint
# already drops --agent for project scope, so this matches what it advertises.
if [[ "$SCOPE" == "project" && -n "$AGENT" ]]; then
    print_error "--agent is not supported with --scope project"
    print_info "A project install records ONE receipt in the repo root, shared by every"
    print_info "harness installed there. It carries no per-tool attribution, so removing"
    print_info "a single harness from it is not possible — a project uninstall is"
    print_info "all-or-nothing."
    print_info "To remove every Kurama install from the repo, drop --agent:"
    print_info "  uninstall.sh --scope project --path ${CUSTOM_PATH:-<repo>}"
    print_info "Add --dry-run to that first to see exactly what it would remove."
    exit 1
fi

if $DRY_RUN; then
    echo -e "${YELLOW}${BOLD}Dry run — no files will be deleted.${NC}"
fi

# O1: project scope removes the single repo-root receipt setup.sh wrote there.
# Every remove_target call below is BARE on purpose — see UNINSTALL_FAILED.
if [[ "$SCOPE" == "project" ]]; then
    TARGET_PATH="${CUSTOM_PATH:-$PWD}"
    remove_target "$TARGET_PATH" "project (repo)"
elif [[ -n "$CUSTOM_PATH" ]]; then
    remove_target "$CUSTOM_PATH" "custom path"
elif [[ -n "$AGENT" ]]; then
    target_dir="$(get_tool_path "$AGENT")"
    if [[ -z "$target_dir" ]]; then
        print_error "Unknown agent: $AGENT"
        show_help
        exit 1
    fi
    remove_target "$target_dir" "$AGENT"
elif $ALL; then
    for agent in $ALL_AGENTS; do
        remove_target "$(get_tool_path "$agent")" "$agent"
    done
else
    show_help
    exit 1
fi

if [[ $UNINSTALL_FAILED -ne 0 ]]; then
    echo -e "\n${RED}${BOLD}Uninstall did not complete cleanly — see the messages above.${NC}"
    exit 1
fi

echo -e "\n${GREEN}${BOLD}Done.${NC}"
