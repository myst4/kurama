#!/usr/bin/env bash
# banner.sh — print the Kurama startup banner (nine-tailed fox + KURAMA wordmark)
# in 24-bit truecolor, with a live stats panel. Pure bash 3.2 / BSD userland, no
# network, and it NEVER fails: every probe is best-effort and the script always
# exits 0 so it is safe to chain in front of an agent launch, e.g.
#
#     alias kurama-opencode='"$KURAMA"/scripts/banner.sh && opencode'
#
# The art lives in assets/banner/{fox.txt,wordmark.txt} (fox.txt is generated
# from fox-grid.txt by scripts/gen-braille.mjs). banner.sh only renders it.
#
# Flags:
#   --no-anim     Skip the fade-in animation (also auto-skipped when stdout is not
#                 a TTY, when --no-anim is passed, or when NO_COLOR is set).
#   -h, --help    Show usage.
#
# Honors NO_COLOR (https://no-color.org): when set, the banner is printed with no
# ANSI color at all.

set -u

# --------------------------------------------------------------------------
# Locations
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSETS_DIR="$REPO_DIR/assets/banner"
FOX_FILE="$ASSETS_DIR/fox.txt"
WORD_FILE="$ASSETS_DIR/wordmark.txt"

# --------------------------------------------------------------------------
# Palette (orange, on the terminal's own background)
# --------------------------------------------------------------------------
FOX_R=255;   FOX_G=140;  FOX_B=66
FRESH_R=255; FRESH_G=160; FRESH_B=90
DIM_R=90;    DIM_G=45;   DIM_B=15
LABEL_R=166; LABEL_G=120; LABEL_B=80

ANIM="auto"

usage() {
    cat <<'EOF'
Usage: banner.sh [--no-anim]

Prints the Kurama startup banner (nine-tailed fox + KURAMA wordmark) with a live
stats panel. Best-effort and always exits 0.

  --no-anim     Skip the fade-in animation.
  -h, --help    Show this help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-anim) ANIM="off"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) shift ;;
    esac
done

# NO_COLOR forces a plain, uncolored banner.
color_enabled() { [ -z "${NO_COLOR:-}" ]; }

# --------------------------------------------------------------------------
# Display width — locale-independent Unicode scalar count. The Braille and
# half-block glyphs are all single-column, so #scalars == #columns. We count
# scalars as (total bytes − UTF-8 continuation bytes 0x80–0xBF), which is exact
# regardless of LC_CTYPE (macOS `awk`/`wc -m` are not reliably UTF-8 aware).
# --------------------------------------------------------------------------
dispw() {
    local s="$1" tot cont
    tot=$(printf '%s' "$s" | LC_ALL=C wc -c)
    cont=$(printf '%s' "$s" | LC_ALL=C tr -cd '\200-\277' | LC_ALL=C wc -c)
    tot=$(printf '%s' "$tot" | tr -d ' ')
    cont=$(printf '%s' "$cont" | tr -d ' ')
    printf '%s' "$(( tot - cont ))"
}

repeat_space() {
    local n="$1" out=""
    [ "$n" -gt 0 ] 2>/dev/null || { printf ''; return 0; }
    while [ "$n" -gt 0 ]; do out="$out "; n=$(( n - 1 )); done
    printf '%s' "$out"
}

# --------------------------------------------------------------------------
# Colored emission (with a brightness scale 0..100 for the fade animation)
# --------------------------------------------------------------------------
# Print a single-color run (the fox is a single-color raster).
paint_solid() { # r g b kpct text
    local r="$1" g="$2" b="$3" k="$4" text="$5"
    if color_enabled; then
        printf '\033[38;2;%d;%d;%dm%s\033[0m' \
            "$(( r * k / 100 ))" "$(( g * k / 100 ))" "$(( b * k / 100 ))" "$text"
    else
        printf '%s' "$text"
    fi
}

# Print a wordmark line: solid blocks (▀▄█) in the fresh color, shadow cells (▒)
# in the dim color — the ▒-as-shadow convention gives the beveled depth.
paint_wordmark() { # kpct text
    local k="$1" text="$2"
    if ! color_enabled; then
        printf '%s' "$text"
        return 0
    fi
    local f d z
    f=$(printf '\033[38;2;%d;%d;%dm' "$(( FRESH_R*k/100 ))" "$(( FRESH_G*k/100 ))" "$(( FRESH_B*k/100 ))")
    d=$(printf '\033[38;2;%d;%d;%dm' "$(( DIM_R*k/100 ))" "$(( DIM_G*k/100 ))" "$(( DIM_B*k/100 ))")
    z=$(printf '\033[0m')
    printf '%s' "$text" | LC_ALL=C awk -v f="$f" -v d="$d" -v z="$z" '
        BEGIN { sh = "▒" }
        { line = $0; gsub(sh, d sh f, line); printf "%s%s%s", f, line, z }'
}

# --------------------------------------------------------------------------
# Load art (bash 3.2: no mapfile). Trailing blank/short lines are preserved.
# --------------------------------------------------------------------------
FOX_LINES=(); WORD_LINES=()
load_lines() { # file  -> populates the named array via a global
    local file="$1" __line
    __LOADED=()
    [ -f "$file" ] || return 0
    while IFS= read -r __line || [ -n "$__line" ]; do
        __LOADED+=("$__line")
    done < "$file"
}
load_lines "$FOX_FILE";  FOX_LINES=("${__LOADED[@]:+${__LOADED[@]}}")
load_lines "$WORD_FILE"; WORD_LINES=("${__LOADED[@]:+${__LOADED[@]}}")

FOX_N=${#FOX_LINES[@]}
WORD_N=${#WORD_LINES[@]}

# Fox block width (max over lines) so we can pad every fox line to a rectangle.
FOX_W=0
i=0
while [ "$i" -lt "$FOX_N" ]; do
    w=$(dispw "${FOX_LINES[$i]}")
    [ "$w" -gt "$FOX_W" ] && FOX_W="$w"
    i=$(( i + 1 ))
done
WORD_W=0
i=0
while [ "$i" -lt "$WORD_N" ]; do
    w=$(dispw "${WORD_LINES[$i]}")
    [ "$w" -gt "$WORD_W" ] && WORD_W="$w"
    i=$(( i + 1 ))
done

# --------------------------------------------------------------------------
# Stats (all best-effort; empty/fallback on any failure)
# --------------------------------------------------------------------------
term_cols() {
    local c
    c=$(tput cols 2>/dev/null || printf '')
    [ -n "$c" ] || c="${COLUMNS:-80}"
    printf '%s' "$c"
}

stat_git() {
    local b
    b=$(git -C "$PWD" branch --show-current 2>/dev/null || printf '')
    if [ -n "$b" ]; then printf '%s' "$b"; else printf 'no repo'; fi
}

stat_ver() {
    local v="" c=""
    [ -f "$REPO_DIR/VERSION" ] && IFS= read -r v < "$REPO_DIR/VERSION" 2>/dev/null
    [ -n "$v" ] || v="unknown"
    c=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || printf '')
    if [ -n "$c" ]; then printf 'v%s (%s)' "$v" "$c"; else printf 'v%s' "$v"; fi
}

stat_skills() {
    local n=0 d
    if [ -d "$REPO_DIR/skills" ]; then
        for d in "$REPO_DIR/skills"/*/SKILL.md; do
            [ -f "$d" ] && n=$(( n + 1 ))
        done
    fi
    printf '%s' "$n"
}

stat_agents() {
    local n=0 d
    for d in "$REPO_DIR/examples/claude-code/agents"/sdd-*.md \
             "$REPO_DIR/examples/pi/agents"/sdd-*.md; do
        [ -f "$d" ] && n=$(( n + 1 ))
    done
    printf '%s' "$n"
}

# MCP servers: best-effort count from the two configs most likely to exist.
stat_mcp() {
    local n="" f
    for f in "$HOME/.claude.json" "$HOME/.config/opencode/opencode.json"; do
        [ -f "$f" ] || continue
        if command -v jq >/dev/null 2>&1; then
            n=$(jq -r '(.mcpServers // .mcp // {}) | length' "$f" 2>/dev/null || printf '')
        fi
        [ -n "$n" ] && [ "$n" != "null" ] && { printf '%s' "$n"; return 0; }
    done
    printf '0'
}

# --------------------------------------------------------------------------
# Frame rendering
# --------------------------------------------------------------------------
emit_frame() { # kpct
    local k="$1"
    local cols indent total rows i fox_off word_off
    cols=$(term_cols)
    case "$cols" in ''|*[!0-9]*) cols=80 ;; esac

    local side_by_side="no"
    total=$(( FOX_W + 2 + WORD_W ))
    if [ "$cols" -ge "$total" ]; then side_by_side="yes"; else total=$FOX_W; [ "$WORD_W" -gt "$total" ] && total=$WORD_W; fi
    indent=$(( (cols - total) / 2 ))
    [ "$indent" -ge 0 ] || indent=0
    local pad; pad=$(repeat_space "$indent")

    if [ "$side_by_side" = "yes" ]; then
        rows=$FOX_N
        [ "$WORD_N" -gt "$rows" ] && rows=$WORD_N
        fox_off=$(( (rows - FOX_N) / 2 ))
        word_off=$(( (rows - WORD_N) / 2 ))
        i=0
        while [ "$i" -lt "$rows" ]; do
            printf '%s' "$pad"
            local fi=$(( i - fox_off )) wi=$(( i - word_off ))
            if [ "$fi" -ge 0 ] && [ "$fi" -lt "$FOX_N" ]; then
                local fl="${FOX_LINES[$fi]}" fw
                fw=$(dispw "$fl")
                paint_solid "$FOX_R" "$FOX_G" "$FOX_B" "$k" "$fl"
                printf '%s' "$(repeat_space $(( FOX_W - fw )))"
            else
                printf '%s' "$(repeat_space "$FOX_W")"
            fi
            printf '  '
            if [ "$wi" -ge 0 ] && [ "$wi" -lt "$WORD_N" ]; then
                paint_wordmark "$k" "${WORD_LINES[$wi]}"
            fi
            printf '\n'
            i=$(( i + 1 ))
        done
    else
        i=0
        while [ "$i" -lt "$FOX_N" ]; do
            printf '%s' "$pad"
            paint_solid "$FOX_R" "$FOX_G" "$FOX_B" "$k" "${FOX_LINES[$i]}"
            printf '\n'
            i=$(( i + 1 ))
        done
        printf '\n'
        i=0
        while [ "$i" -lt "$WORD_N" ]; do
            printf '%s' "$pad"
            paint_wordmark "$k" "${WORD_LINES[$i]}"
            printf '\n'
            i=$(( i + 1 ))
        done
    fi

    # Stats panel
    printf '\n'
    local git ver skills agents mcp
    git=$(stat_git); ver=$(stat_ver); skills=$(stat_skills); agents=$(stat_agents); mcp=$(stat_mcp)
    emit_stat_row "$pad" "GIT" "$git" "VER" "$ver"
    emit_stat_row "$pad" "SKILLS" "$skills loaded" "AGENTS" "$agents phases"
    emit_stat_row "$pad" "MCP" "$mcp server(s)" "PATH" "$PWD"
}

emit_stat_row() { # pad label1 value1 label2 value2
    local pad="$1" l1="$2" v1="$3" l2="$4" v2="$5"
    printf '%s' "$pad"
    _label "$l1"; printf ' '; _value "$v1"
    printf '    '
    _label "$l2"; printf ' '; _value "$v2"
    printf '\n'
}
_label() { # text
    if color_enabled; then
        printf '\033[38;2;%d;%d;%dm%s:\033[0m' "$LABEL_R" "$LABEL_G" "$LABEL_B" "$1"
    else
        printf '%s:' "$1"
    fi
}
_value() { # text
    if color_enabled; then
        printf '\033[38;2;%d;%d;%dm%s\033[0m' "$FRESH_R" "$FRESH_G" "$FRESH_B" "$1"
    else
        printf '%s' "$1"
    fi
}

# --------------------------------------------------------------------------
# Drive: animate a short brightness fade-in on a TTY, else print once.
# --------------------------------------------------------------------------
animate() {
    [ "$ANIM" != "off" ] || return 1
    [ -t 1 ] || return 1
    color_enabled || return 1
    command -v sleep >/dev/null 2>&1 || return 1
    return 0
}

if animate; then
    printf '\033[2J\033[H'
    for k in 20 40 60 80 100; do
        printf '\033[H'
        emit_frame "$k"
        sleep 0.03 2>/dev/null || true
    done
else
    emit_frame 100
fi

exit 0
