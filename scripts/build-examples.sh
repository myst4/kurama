#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Agent Teams Lite — Build orchestrator examples from templates
#
# Assembles examples/_templates/core.md (the shared orchestrator body) with one
# per-harness overlay (examples/_templates/<harness>.md, which holds ONLY that
# harness's deltas) into the committed orchestrator file for each harness.
#
# The generated files ARE build outputs: edit the templates, then re-run this
# script. CI (.github/workflows/pr-check.yml) rebuilds and fails on any diff, so
# hand-editing a generated file is caught. Portable: POSIX sh tools + bash 3.2.
#
# Usage: scripts/build-examples.sh
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TPL_DIR="$REPO_DIR/examples/_templates"
CORE="$TPL_DIR/core.md"

# Marker injected at the top of every generated file (HTML comment; for files
# that open with YAML frontmatter it is inserted just after the frontmatter).
MARKER="<!-- GENERATED FILE — edit examples/_templates/, then run scripts/build-examples.sh -->"

# Ordered token set substituted into core.md. A harness overlay that omits a
# token renders it empty (and surrounding blank lines are collapsed).
TOKENS="HEADER DELEGATION_MECHANISM NATIVE_NOTES MODEL_ASSIGNMENTS_SECTION STATE_CONVENTIONS"

# Every harness the build emits.
HARNESSES="claude-code codex gemini-cli opencode antigravity vscode cursor pi"

# Map a harness id to its committed output path (repo-relative).
out_path() {
  case "$1" in
    claude-code) echo "examples/claude-code/CLAUDE.md" ;;
    codex)       echo "examples/codex/agents.md" ;;
    gemini-cli)  echo "examples/gemini-cli/GEMINI.md" ;;
    opencode)    echo "examples/opencode/AGENTS.md" ;;
    antigravity) echo "examples/antigravity/sdd-orchestrator.md" ;;
    vscode)      echo "examples/vscode/copilot-instructions.md" ;;
    cursor)      echo "examples/cursor/.cursor/rules/sdd-orchestrator.mdc" ;;
    pi)          echo "examples/pi/AGENTS.md" ;;
    *)           echo "" ;;
  esac
}

# Extract one token block from an overlay file. A block is the lines between
# `<!-- @@NAME@@ -->` and the next `<!-- @@...@@ -->` delimiter, with leading and
# trailing blank lines trimmed. Prints nothing if the overlay omits the token.
extract_block() {
  overlay_file="$1"
  token_name="$2"
  awk -v tok="$token_name" '
    /^<!-- @@[A-Za-z0-9_]+@@ -->[[:space:]]*$/ {
      name = $0
      sub(/^<!-- @@/, "", name)
      sub(/@@ -->[[:space:]]*$/, "", name)
      if (capturing == 1) { capturing = 0 }
      if (name == tok)   { capturing = 1; n = 0 }
      next
    }
    capturing == 1 { buf[++n] = $0 }
    END {
      s = 1;  while (s <= n && buf[s] ~ /^[[:space:]]*$/) s++
      e = n;  while (e >= 1 && buf[e] ~ /^[[:space:]]*$/) e--
      for (i = s; i <= e; i++) print buf[i]
    }
  ' "$overlay_file"
}

build_one() {
  harness="$1"
  overlay="$TPL_DIR/$harness.md"
  rel_out="$(out_path "$harness")"

  if [ -z "$rel_out" ]; then
    echo "error: unknown harness '$harness'" >&2
    return 1
  fi
  if [ ! -f "$overlay" ]; then
    echo "error: missing overlay $overlay" >&2
    return 1
  fi

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/atl-build.XXXXXX")"

  # 1. Extract every token block into $tmp/<TOKEN>.
  for tok in $TOKENS; do
    extract_block "$overlay" "$tok" > "$tmp/$tok"
  done

  # 2. Substitute placeholder lines in core.md with their block content.
  # 3. Collapse runs of blank lines to a single blank line.
  # 4. Inject the GENERATED marker (after frontmatter if present, else on top).
  awk -v dir="$tmp" '
    /^[[:space:]]*@@[A-Za-z0-9_]+@@[[:space:]]*$/ {
      tok = $0
      gsub(/^[[:space:]]*@@/, "", tok)
      gsub(/@@[[:space:]]*$/, "", tok)
      f = dir "/" tok
      while ((getline line < f) > 0) print line
      close(f)
      next
    }
    { print }
  ' "$CORE" \
    | awk '
        /^[[:space:]]*$/ { blank++; if (blank <= 1) print ""; next }
        { blank = 0; print }
      ' \
    | awk -v marker="$MARKER" '
        NR == 1 {
          if ($0 == "---") { fm = 1; print; next }
          print marker; print ""
        }
        fm == 1 && injected == 0 && $0 == "---" {
          print; print marker; print ""; injected = 1; next
        }
        { print }
      ' > "$tmp/out"

  # 5. Write the output atomically into place.
  mkdir -p "$REPO_DIR/$(dirname "$rel_out")"
  mv "$tmp/out" "$REPO_DIR/$rel_out"
  rm -rf "$tmp"
  echo "  built $rel_out"
}

main() {
  if [ ! -f "$CORE" ]; then
    echo "error: missing core template $CORE" >&2
    exit 1
  fi
  echo "Building orchestrator examples from $TPL_DIR ..."
  for harness in $HARNESSES; do
    build_one "$harness"
  done
  echo "Done. ${HARNESSES// /, } regenerated."
}

main "$@"
