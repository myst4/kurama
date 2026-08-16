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
# The art is drawn at the richest size that FITS, on both axes — the same
# degradation ladder the generated logo plugins use (scripts/gen-logo-plugin.mjs:
# full art ⇒ one-line ✦ KURAMA ✦ ⇒ nothing). Overflowing is not a cosmetic
# problem here: a block wider than the terminal wraps, a block taller than it
# scrolls, and the fade-in repaints from the home position — so every frame lands
# further off than the last and the five frames pile up on screen.
#
# Flags:
#   --no-anim     Skip the fade-in animation (also auto-skipped when stdout is not
#                 a TTY, when --no-anim is passed, or when NO_COLOR is set).
#   --probe-size  Print the terminal size this script resolved ("COLS ROWS") and
#                 exit 0, drawing nothing. What the ladder below is deciding on,
#                 and the seam scripts/install_test.sh asserts the probe with.
#   -h, --help    Show usage.
#
# Environment:
#   NO_COLOR              Honored (https://no-color.org): no ANSI color at all.
#   KURAMA_BANNER_COLS    Override the terminal size probe. Positive integers
#   KURAMA_BANNER_ROWS    only; anything else is ignored. This is the seam
#                         scripts/install_test.sh drives to render every rung of
#                         the ladder without a terminal.

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

# The narrowest thing that still says Kurama — the same one-liner the OpenCode
# and Pi logo plugins fall back to (scripts/gen-logo-plugin.mjs:63).
MARK="✦ KURAMA ✦"

ANIM="auto"
PROBE_SIZE="no"

usage() {
    cat <<'EOF'
Usage: banner.sh [--no-anim] [--probe-size]

Prints the Kurama startup banner (nine-tailed fox + KURAMA wordmark) with a live
stats panel. Best-effort and always exits 0.

  --no-anim     Skip the fade-in animation.
  --probe-size  Print the resolved terminal size ("COLS ROWS") and draw nothing.
  -h, --help    Show this help.

The art degrades to what fits: fox beside the wordmark, fox above it, fox alone,
a one-line "✦ KURAMA ✦", or nothing. KURAMA_BANNER_COLS / KURAMA_BANNER_ROWS
override the size probe.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-anim)    ANIM="off"; shift ;;
        --probe-size) PROBE_SIZE="yes"; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) shift ;;
    esac
done

# NO_COLOR forces a plain, uncolored banner.
color_enabled() { [ -z "${NO_COLOR:-}" ]; }

is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# --------------------------------------------------------------------------
# Display width — locale-independent Unicode scalar count. The Braille and
# half-block glyphs are all single-column, so #scalars == #columns. We count
# scalars as (total bytes − UTF-8 continuation bytes 0x80–0xBF), which is exact
# regardless of LC_CTYPE (macOS `awk`/`wc -m` are not reliably UTF-8 aware).
#
# Every call spends five subshells, so it is the reference implementation and the
# fallback — measure_lines below answers for a whole file in one awk pass, and
# both are load-time only. Measuring inside a frame is what made the fade cost
# what it did: 27 lines × 5 frames of arithmetic that never changes.
# --------------------------------------------------------------------------
dispw() {
    local s="$1" tot cont
    tot=$(printf '%s' "$s" | LC_ALL=C wc -c)
    cont=$(printf '%s' "$s" | LC_ALL=C tr -cd '\200-\277' | LC_ALL=C wc -c)
    tot=$(printf '%s' "$tot" | tr -d ' ')
    cont=$(printf '%s' "$cont" | tr -d ' ')
    printf '%s' "$(( tot - cont ))"
}

# The same subtraction, for every line of a file, in one fork. Verified against
# dispw on both art files; if awk is missing or disagrees on the line count the
# caller falls back to dispw, so this is an optimization and never a semantic.
measure_lines() { # file -> one display width per line
    [ -f "$1" ] || return 0
    LC_ALL=C awk '{ n = length($0); c = gsub(/[\200-\277]/, ""); print n - c }' "$1" 2>/dev/null
}

# printf -v builds a run of spaces without forking a subshell. Pads and fills are
# assembled once and then printed on every line of every frame.
pad_str() { # varname n
    if [ "${2:-0}" -gt 0 ] 2>/dev/null; then
        printf -v "$1" '%*s' "$2" ''
    else
        printf -v "$1" '%s' ''
    fi
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
#
# The split stays in awk. A bash `${text//▒/…}` would save one fork per row per
# frame, but bash 3.2 under a locale it does not fully recognise (LANG=C.UTF-8 on
# macOS) matched only the FIRST BYTE of the three-byte ▒ and dropped the dim
# escape from the replacement — measured, not theorised. awk with LC_ALL=C
# compares bytes and is right everywhere.
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

# Per-line widths, from one awk pass — but only if that pass is trustworthy on
# this box. `[\200-\277]` is an octal escape inside a bracket expression, which
# POSIX leaves undefined; gawk, mawk and BSD awk all honor it, and an awk that
# does not would silently over-count every Braille cell. So the fast path has to
# agree with dispw (the reference, built from `tr`, no regex escapes) on the
# first line AND return one width per loaded line, or it is discarded whole.
widths_of() { # file linecount -> populates __WIDTHS, empty when not trustworthy
    local file="$1" want="$2" w
    __WIDTHS=()
    while IFS= read -r w; do
        case "$w" in ''|*[!0-9]*) continue ;; esac
        __WIDTHS+=("$w")
    done < <(measure_lines "$file")
    [ "${#__WIDTHS[@]}" -eq "$want" ] || __WIDTHS=()
}

# widths for array $1 (the loaded lines) measured line by line with dispw.
widths_by_dispw() { # linecount arrayname...
    local n="$1" idx=0
    shift
    __WIDTHS=()
    while [ "$idx" -lt "$n" ]; do
        __WIDTHS+=("$(dispw "$1")"); shift; idx=$(( idx + 1 ))
    done
}

FOX_LINE_W=()
widths_of "$FOX_FILE" "$FOX_N"
if [ "${#__WIDTHS[@]}" -ne "$FOX_N" ] || \
   { [ "$FOX_N" -gt 0 ] && [ "${__WIDTHS[0]}" != "$(dispw "${FOX_LINES[0]}")" ]; }; then
    widths_by_dispw "$FOX_N" ${FOX_LINES[@]+"${FOX_LINES[@]}"}
fi
FOX_LINE_W=("${__WIDTHS[@]:+${__WIDTHS[@]}}")

WORD_LINE_W=()
widths_of "$WORD_FILE" "$WORD_N"
if [ "${#__WIDTHS[@]}" -ne "$WORD_N" ] || \
   { [ "$WORD_N" -gt 0 ] && [ "${__WIDTHS[0]}" != "$(dispw "${WORD_LINES[0]}")" ]; }; then
    widths_by_dispw "$WORD_N" ${WORD_LINES[@]+"${WORD_LINES[@]}"}
fi
WORD_LINE_W=("${__WIDTHS[@]:+${__WIDTHS[@]}}")

# Block widths: the art is padded to a rectangle, so the widest line is the block.
FOX_W=0
i=0
while [ "$i" -lt "$FOX_N" ]; do
    [ "${FOX_LINE_W[$i]}" -gt "$FOX_W" ] && FOX_W="${FOX_LINE_W[$i]}"
    i=$(( i + 1 ))
done
WORD_W=0
i=0
while [ "$i" -lt "$WORD_N" ]; do
    [ "${WORD_LINE_W[$i]}" -gt "$WORD_W" ] && WORD_W="${WORD_LINE_W[$i]}"
    i=$(( i + 1 ))
done
MARK_W=$(dispw "$MARK")

# The filler that squares each fox line into a rectangle, built once.
FOX_FILL=()
_fill=""
i=0
while [ "$i" -lt "$FOX_N" ]; do
    pad_str _fill $(( FOX_W - ${FOX_LINE_W[$i]} ))
    FOX_FILL+=("$_fill")
    i=$(( i + 1 ))
done
pad_str FOX_BLANK "$FOX_W"

# --------------------------------------------------------------------------
# Terminal size — asked of the real tty, not of terminfo's default
# --------------------------------------------------------------------------
# `tput cols` asks ncurses, and ncurses reads the window size from FILE
# DESCRIPTOR 2. Every caller of this script redirects stderr (setup.sh:175,
# install.sh:120, setup-tui.sh:230 all run it `2>/dev/null`) and so did the old
# probe's own command substitution — so tput never saw a window and answered with
# the terminfo default, 80x24, whatever the terminal actually was. Measured in a
# real 145x40 pty: `tput cols` = 145, `tput cols 2>/dev/null` = 80,
# `stty size </dev/tty` = "40 145".
#
# So: the controlling tty first, because it is the only source that survives a
# redirected stderr. tput and the environment are the fallbacks for the contexts
# that have no controlling tty at all (CI, cron, a pipe), where 80x24 is the
# right answer rather than a wrong measurement.
term_size() { # -> "COLS ROWS"
    local cols="" rows="" sz

    if is_num "${KURAMA_BANNER_COLS:-}" && [ "${KURAMA_BANNER_COLS}" -gt 0 ]; then
        cols="$KURAMA_BANNER_COLS"
    fi
    if is_num "${KURAMA_BANNER_ROWS:-}" && [ "${KURAMA_BANNER_ROWS}" -gt 0 ]; then
        rows="$KURAMA_BANNER_ROWS"
    fi

    if [ -z "$cols" ] || [ -z "$rows" ]; then
        # 2>/dev/null FIRST: redirections are applied left to right, and it is
        # the shell — not stty — that reports a /dev/tty this process cannot
        # open. With the order reversed that message escapes onto the screen.
        sz="$(stty size 2>/dev/null </dev/tty || printf '')"
        case "$sz" in
            *[0-9]*' '*[0-9]*)
                [ -n "$rows" ] || rows="${sz%% *}"
                [ -n "$cols" ] || cols="${sz##* }"
                ;;
        esac
    fi

    is_num "$cols" || cols="$(tput cols 2>/dev/null || printf '')"
    is_num "$rows" || rows="$(tput lines 2>/dev/null || printf '')"
    is_num "$cols" || cols="${COLUMNS:-}"
    is_num "$rows" || rows="${LINES:-}"
    is_num "$cols" || cols=80
    is_num "$rows" || rows=24
    [ "$cols" -gt 0 ] || cols=80
    [ "$rows" -gt 0 ] || rows=24

    printf '%s %s' "$cols" "$rows"
}

if [ "$PROBE_SIZE" = "yes" ]; then
    term_size
    printf '\n'
    exit 0
fi

TERM_SIZE="$(term_size)"
COLS="${TERM_SIZE%% *}"
ROWS="${TERM_SIZE##* }"

# --------------------------------------------------------------------------
# Stats (all best-effort; empty/fallback on any failure)
# --------------------------------------------------------------------------
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

# How many servers one config declares. jq when it is there; otherwise a brace-
# depth scan in awk, because "no jq" must not silently mean "no servers" — the
# panel used to print 0 for every configured machine without jq, since $n was
# only ever assigned inside the jq branch.
#
# The awk pass locates the mcpServers/mcp key, walks from its opening brace and
# counts the colons at depth 1, tracking strings and nesting so a value's own
# colons never count. It is line-oriented only until the key is found, then
# character-oriented until the object closes, which keeps it bounded on a large
# ~/.claude.json and correct on a minified one. A JSON file with no such key
# declares no servers, so that is a 0; anything that does not even open with `{`
# is unknown and prints nothing, because "I could not read it" must not arrive
# at the panel as "you have none".
#
# Checked against jq on: three servers, an empty object, a minified file, braces
# and colons inside string values, a corrupt file, and a missing file.
mcp_count_in() { # file -> integer, or empty when unknown
    local f="$1" n
    if command -v jq >/dev/null 2>&1; then
        n="$(jq -r '(.mcpServers // .mcp // {}) | length' "$f" 2>/dev/null || printf '')"
        is_num "$n" && printf '%s' "$n"
        return 0
    fi
    command -v awk >/dev/null 2>&1 || return 0
    LC_ALL=C awk '
        BEGIN { st = 0; depth = 0; n = 0; instr = 0; esc = 0; done = 0; json = 0; seen = 0 }
        {
            line = $0
            if (!seen) {
                probe = line
                sub(/^[[:space:]]+/, "", probe)
                if (probe != "") { seen = 1; json = (substr(probe, 1, 1) == "{") }
            }
            if (st == 0) {
                p = index(line, "\"mcpServers\"")
                if (p > 0) { line = substr(line, p + 12) }
                else {
                    p = index(line, "\"mcp\"")
                    if (p == 0) next
                    line = substr(line, p + 5)
                }
                st = 1
            }
            L = length(line)
            for (i = 1; i <= L; i++) {
                c = substr(line, i, 1)
                if (st == 1) {
                    if (c == "{") { st = 2; depth = 1 }
                    else if (c == "," || c == "}") { done = 1; break }   # null/scalar value
                    continue
                }
                if (instr) {
                    if (esc) { esc = 0 }
                    else if (c == "\\") { esc = 1 }
                    else if (c == "\"") { instr = 0 }
                    continue
                }
                if (c == "\"") { instr = 1; continue }
                if (c == "{" || c == "[") { depth++; continue }
                if (c == "}" || c == "]") { depth--; if (depth <= 0) { done = 1; break }; continue }
                if (c == ":" && depth == 1) n++
            }
            if (done) exit
        }
        END { if (st >= 1) print n; else if (json) print 0 }
    ' "$f" 2>/dev/null
}

# MCP servers: best-effort count over the two configs most likely to exist.
#
# A 0 from the first file is a real answer for that file and NOT an answer for
# the second one, so the walk continues past it and only a positive count stops
# it early. When a file exists but no parser could read it the panel says "n/a";
# claiming 0 servers on a machine that has ten is the one thing this must not do.
stat_mcp() {
    local f n first="" saw_file="" parsed=""
    for f in "${HOME:-}/.claude.json" "${HOME:-}/.config/opencode/opencode.json"; do
        [ -f "$f" ] || continue
        saw_file="yes"
        n="$(mcp_count_in "$f")"
        is_num "$n" || continue
        parsed="yes"
        [ -n "$first" ] || first="$n"
        if [ "$n" -gt 0 ]; then printf '%s' "$n"; return 0; fi
    done
    [ -n "$parsed" ] && { printf '%s' "$first"; return 0; }
    [ -n "$saw_file" ] && { printf 'n/a'; return 0; }
    printf '0'
}

# $HOME → ~, so the PATH stat has a chance of fitting before it is elided.
short_path() { # path
    local p="$1" h="${HOME:-}"
    if [ -n "$h" ]; then
        case "$p" in
            "$h")   p="~" ;;
            "$h"/*) p="~${p#"$h"}" ;;
        esac
    fi
    printf '%s' "$p"
}

# Keep the TAIL of a value that does not fit: the end of a path is the part that
# identifies it. A row that overflows wraps, and a wrapped row breaks the
# repaint exactly like an oversized art block does.
fit_tail() { # text budget
    local s="$1" n="$2"
    if [ "$n" -lt 2 ]; then printf ''; return 0; fi
    if [ "${#s}" -le "$n" ]; then printf '%s' "$s"; return 0; fi
    printf '…%s' "${s: $(( ${#s} - n + 1 ))}"
}

# --------------------------------------------------------------------------
# Stats, measured ONCE. They are constants for the duration of a run — the fade
# used to re-run git, jq and the skill/agent globs for every one of its five
# frames, which was most of the wall clock of an animated banner.
# --------------------------------------------------------------------------
S_GIT="$(stat_git)"
S_VER="$(stat_ver)"
S_MCP="$(stat_mcp)"
V_SKILLS="$(stat_skills) loaded"
V_AGENTS="$(stat_agents) phases"
V_MCP="$S_MCP server(s)"

# Row 2 ("SKILLS: N loaded    AGENTS: N phases") is the only panel row with no
# unbounded field, so it is what the panel's own width is measured by: labels
# ("X" + ": ") plus values plus the four-space gutter. A terminal narrower than
# that has no panel at all rather than a wrapped one.
PANEL_ROW_W=$(( 6 + 2 + ${#V_SKILLS} + 4 + 6 + 2 + ${#V_AGENTS} ))
PANEL_N=4
[ "$COLS" -ge "$PANEL_ROW_W" ] || PANEL_N=0

# --------------------------------------------------------------------------
# The degradation ladder — pick the richest block that fits BOTH axes
# --------------------------------------------------------------------------
# Ported from scripts/gen-logo-plugin.mjs:209 (full art ⇒ compact ⇒ nothing),
# with the two intermediate rungs a 24-row terminal actually lands on. The stats
# panel is one blank line plus three rows and is counted into every rung, so a
# terminal that fits the art but not the panel drops to a smaller rung rather
# than scrolling the art off the top.
SIDE_W=$(( FOX_W + 2 + WORD_W ))
SIDE_N=$FOX_N
[ "$WORD_N" -gt "$SIDE_N" ] && SIDE_N=$WORD_N
STACK_W=$FOX_W
[ "$WORD_W" -gt "$STACK_W" ] && STACK_W=$WORD_W
STACK_N=$(( FOX_N + 1 + WORD_N ))
COMPACT_N=$(( FOX_N + 1 + 1 ))   # fox, blank, one-line mark

# The animated path — and only it — keeps one row in reserve: the last line ends
# in a newline, and on a screen filled exactly to the bottom that newline scrolls
# the terminal, which is what makes each repaint-from-home land a line lower than
# the one before it. A one-shot print may legitimately fill the screen.
RESERVE=0
if [ "$ANIM" != "off" ] && [ -t 1 ] && color_enabled && command -v sleep >/dev/null 2>&1; then
    RESERVE=1
fi

fits() { # width rows
    [ "$COLS" -ge "$1" ] && [ "$ROWS" -ge $(( $2 + RESERVE )) ]
}

if   fits "$SIDE_W"  $(( SIDE_N + PANEL_N ));    then TIER="side";    ART_N=$SIDE_N
elif fits "$STACK_W" $(( STACK_N + PANEL_N ));   then TIER="stack";   ART_N=$STACK_N
elif fits "$FOX_W"   $(( COMPACT_N + PANEL_N )); then TIER="compact"; ART_N=$COMPACT_N
elif fits "$MARK_W"  1;                          then TIER="mark";    ART_N=1
else                                                  TIER="none";    ART_N=0
fi

PANEL="no"
if [ "$TIER" != "none" ] && [ "$PANEL_N" -gt 0 ] && fits "$PANEL_ROW_W" $(( ART_N + PANEL_N )); then
    PANEL="yes"
fi

# Block width of the chosen tier, and the indent that centers it.
case "$TIER" in
    side)    BLOCK_W=$SIDE_W ;;
    stack)   BLOCK_W=$STACK_W ;;
    compact) BLOCK_W=$FOX_W ;;
    *)       BLOCK_W=$MARK_W ;;
esac
INDENT=$(( (COLS - BLOCK_W) / 2 ))
[ "$INDENT" -ge 0 ] || INDENT=0
pad_str PAD "$INDENT"
MARK_INDENT=$(( (COLS - MARK_W) / 2 ))
[ "$MARK_INDENT" -ge 0 ] || MARK_INDENT=0
pad_str MARK_PAD "$MARK_INDENT"

# The panel follows the art's indent, but never past the point where its own
# rows would run off the right edge — centering three text rows under a ten-
# column "✦ KURAMA ✦" is how they ended up wider than the terminal.
PANEL_INDENT=$INDENT
[ "$PANEL_INDENT" -le $(( COLS - PANEL_ROW_W )) ] || PANEL_INDENT=$(( COLS - PANEL_ROW_W ))
[ "$PANEL_INDENT" -ge 0 ] || PANEL_INDENT=0
pad_str PANEL_PAD "$PANEL_INDENT"

# The two unbounded values — a branch name and a working directory — are the
# only things left that can overrun a row, so they are elided from the left to
# whatever the fixed columns leave them. Row 1 spends 14 fixed columns plus the
# version, row 3 spends 15 plus the server count.
V_GIT="$(fit_tail "$S_GIT" $(( COLS - PANEL_INDENT - 14 - ${#S_VER} )))"
V_PATH="$(fit_tail "$(short_path "$PWD")" $(( COLS - PANEL_INDENT - 15 - ${#V_MCP} )))"

# --------------------------------------------------------------------------
# Frame rendering — painting only. Everything it needs was measured above.
# --------------------------------------------------------------------------
emit_side() { # kpct
    local k="$1" i=0 fidx widx fox_off word_off
    fox_off=$(( (SIDE_N - FOX_N) / 2 ))
    word_off=$(( (SIDE_N - WORD_N) / 2 ))
    while [ "$i" -lt "$SIDE_N" ]; do
        printf '%s' "$PAD"
        fidx=$(( i - fox_off )); widx=$(( i - word_off ))
        if [ "$fidx" -ge 0 ] && [ "$fidx" -lt "$FOX_N" ]; then
            paint_solid "$FOX_R" "$FOX_G" "$FOX_B" "$k" "${FOX_LINES[$fidx]}"
            printf '%s' "${FOX_FILL[$fidx]}"
        else
            printf '%s' "$FOX_BLANK"
        fi
        printf '  '
        if [ "$widx" -ge 0 ] && [ "$widx" -lt "$WORD_N" ]; then
            paint_wordmark "$k" "${WORD_LINES[$widx]}"
        fi
        printf '\n'
        i=$(( i + 1 ))
    done
}

emit_stack() { # kpct
    local k="$1" i=0
    while [ "$i" -lt "$FOX_N" ]; do
        printf '%s' "$PAD"
        paint_solid "$FOX_R" "$FOX_G" "$FOX_B" "$k" "${FOX_LINES[$i]}"
        printf '\n'
        i=$(( i + 1 ))
    done
    printf '\n'
    i=0
    while [ "$i" -lt "$WORD_N" ]; do
        printf '%s' "$PAD"
        paint_wordmark "$k" "${WORD_LINES[$i]}"
        printf '\n'
        i=$(( i + 1 ))
    done
}

emit_compact() { # kpct — the fox still fits, the 95-column wordmark does not
    local k="$1" i=0
    while [ "$i" -lt "$FOX_N" ]; do
        printf '%s' "$PAD"
        paint_solid "$FOX_R" "$FOX_G" "$FOX_B" "$k" "${FOX_LINES[$i]}"
        printf '\n'
        i=$(( i + 1 ))
    done
    printf '\n'
    emit_mark "$k"
}

emit_mark() { # kpct
    printf '%s' "$MARK_PAD"
    paint_solid "$FRESH_R" "$FRESH_G" "$FRESH_B" "$1" "$MARK"
    printf '\n'
}

emit_panel() {
    printf '\n'
    emit_stat_row "GIT" "$V_GIT" "VER" "$S_VER"
    emit_stat_row "SKILLS" "$V_SKILLS" "AGENTS" "$V_AGENTS"
    emit_stat_row "MCP" "$V_MCP" "PATH" "$V_PATH"
}

emit_stat_row() { # label1 value1 label2 value2
    local l1="$1" v1="$2" l2="$3" v2="$4"
    printf '%s' "$PANEL_PAD"
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

emit_frame() { # kpct
    case "$TIER" in
        side)    emit_side "$1" ;;
        stack)   emit_stack "$1" ;;
        compact) emit_compact "$1" ;;
        mark)    emit_mark "$1" ;;
        *)       return 0 ;;
    esac
    [ "$PANEL" = "yes" ] && emit_panel
    return 0
}

# --------------------------------------------------------------------------
# Drive: animate a short brightness fade-in on a TTY, else print once.
# --------------------------------------------------------------------------
# RESERVE is exactly the animation predicate, decided before the ladder because
# the ladder has to know whether it may fill the last row.
animate() {
    [ "$RESERVE" = "1" ] && [ "$TIER" != "none" ]
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
