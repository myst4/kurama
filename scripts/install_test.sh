#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Kurama — Install Script Tests
# Run: bash scripts/install_test.sh
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_SCRIPT="$SCRIPT_DIR/install.sh"
SETUP_SCRIPT="$SCRIPT_DIR/setup.sh"
UNINSTALL_SCRIPT="$SCRIPT_DIR/uninstall.sh"
UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"
DOCTOR_SCRIPT="$SCRIPT_DIR/doctor.sh"
TUI_SCRIPT="$SCRIPT_DIR/setup-tui.sh"
VALIDATE_SCRIPT="$SCRIPT_DIR/validate_skills.sh"
MANIFEST_FILE="$REPO_DIR/skills/manifest.json"
# The two PreToolUse hooks setup.sh installs onto the user's machine. They run on
# every Edit/Write/MultiEdit and every Task/Skill call and block with exit 2, so
# they are tested here as the shipped artifacts, from the same path setup copies.
HOOKS_SRC_DIR="$REPO_DIR/examples/claude-code/hooks"
ARCHIVE_GATE_HOOK="$HOOKS_SRC_DIR/archive-gate.sh"
WRITE_GUARD_HOOK="$HOOKS_SRC_DIR/orchestrator-write-guard.sh"

# The shipped receipt library (issue #37) — the single copy the six scripts
# source. The suite reads receipts through it (receipt_array_values below) and
# UNIT-F exercises it directly, so the tests use the SAME parser the tooling does.
KURAMA_LIB="$SCRIPT_DIR/lib/receipt.sh"
if [ ! -f "$KURAMA_LIB" ]; then
    echo "install_test.sh: missing $KURAMA_LIB — incomplete clone." >&2
    exit 1
fi
# shellcheck source=lib/receipt.sh disable=SC1091
. "$KURAMA_LIB"

# ============================================================================
# Test state
# ============================================================================

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
# shellcheck disable=SC2034  # kept for a complete color palette
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# All 28 expected default skills (sdd-core + quality + review + optional + tdd).
# The `lang` group (per-language pattern skills, e.g. go-testing) is OFF by default:
# Kurama is stack-agnostic and ships no language knowledge in a default install.
# The tdd and kanban-github modules ship by default now; installing either does NOT
# activate it (TDD stays opt-in per project; the kanban board stays opt-in via
# kanban.enabled and requires a configured gh — never probed here). The `optional`
# group now holds FIVE skills — kanban-github, sdd-learn, sdd-brainstorm (#104),
# kurama-report and systemic-issue-triage (#85, #86) — so every `--without optional`
# count below moves by five, not by one.
EXPECTED_SKILLS=(
    sdd-apply
    sdd-archive
    sdd-brainstorm
    sdd-design
    sdd-explore
    sdd-init
    sdd-learn
    sdd-propose
    sdd-spec
    sdd-tasks
    sdd-verify
    sdd-new
    sdd-continue
    sdd-ff
    skill-registry
    judgment-day
    review-risk
    review-readability
    review-reliability
    review-resilience
    review-refuter
    kanban-github
    tdd
    skill-creator
    branch-pr
    issue-creation
    kurama-report
    systemic-issue-triage
)

# ============================================================================
# Test helpers
# ============================================================================

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        return 0
    fi
    echo "  Expected: $expected"
    echo "  Actual:   $actual"
    [[ -n "$msg" ]] && echo "  Message:  $msg"
    return 1
}

assert_file_exists() {
    local file="$1"
    if [[ -f "$file" ]]; then
        return 0
    fi
    echo "  File not found: $file"
    return 1
}

assert_dir_exists() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        return 0
    fi
    echo "  Directory not found: $dir"
    return 1
}

assert_file_not_empty() {
    local file="$1"
    local min_bytes="${2:-100}"
    if [[ ! -f "$file" ]]; then
        echo "  File not found: $file"
        return 1
    fi
    local size
    size=$(wc -c < "$file" | tr -d ' ')
    if [[ "$size" -lt "$min_bytes" ]]; then
        echo "  File too small: $file ($size bytes, expected >= $min_bytes)"
        return 1
    fi
    return 0
}

assert_all_skills_installed() {
    local base_dir="$1"
    for skill in "${EXPECTED_SKILLS[@]}"; do
        assert_dir_exists "$base_dir/$skill" || return 1
        assert_file_exists "$base_dir/$skill/SKILL.md" || return 1
        assert_file_not_empty "$base_dir/$skill/SKILL.md" || return 1
    done
    return 0
}

# Run test function $1 in a subshell, echo its combined output, and exit with its
# status.
#
# #31: `set -e` is re-armed INSIDE the subshell on purpose. Callers disarm errexit
# around the call so a failing body cannot abort the whole suite; this explicit
# `set -e` is what puts it back for the body. The outer shell's -u and pipefail
# are never suppressed and carry over either way.
#
# #55: the re-arm is honoured ONLY when the caller is NOT inside a POSIX
# errexit-ignore context — an `if`/`while` condition, a `!` negation, or any
# non-final command of an `&&`/`||` list. Bash <= 5.2 let a nested `set -e`
# override that suppression; bash 5.3 (ubuntu-latest) follows POSIX strictly and
# silently ignores it, which made every "run the thing, then return 0" test
# unfailable again on CI while macOS bash 3.2 stayed green. So EVERY caller must
# reach this function through a plain assignment (or a bare command) wrapped in
# `set +e` / `set -e` — never from a condition and never from `|| status=$?`.
invoke_test_body() {
    local func="$1"
    ( set -e; "$func" 2>&1 )
}

# Count files matching -name pattern $2 under directory $1, answering 0 when the
# directory does not exist.
#
# #31: `find <missing dir> -name X | wc -l` exits 1, and under `set -o pipefail`
# that status is the whole assignment's — which aborts the test body now that
# errexit really reaches it. Every caller that counts what SURVIVED a removal is
# asking about a directory the removal may legitimately have taken with it, so
# the absent case is a real answer (zero), not an error.
count_matching_files() {
    local dir="$1" pattern="$2"
    [ -d "$dir" ] || { echo 0; return 0; }
    find "$dir" -name "$pattern" | wc -l | tr -d ' '
}

run_test() {
    local name="$1"
    local func="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    setup
    echo -n "  $name ... "
    local output status
    # #55: a plain assignment is not an errexit-ignore context, so the subshell's
    # `set -e` is honoured on every bash from 3.2 to 5.3+. `set +e` here only keeps
    # a failing body from aborting the suite — it does NOT reach the body, which
    # re-arms errexit for itself. Do not fold this back into `if output=$(...)`.
    set +e
    output=$(invoke_test_body "$func")
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}"
        if [[ -n "$output" ]]; then
            printf '%s\n' "$output" | awk '{ print "    " $0 }'
        fi
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES="$FAILURES\n  - $name"
    fi
    teardown
}

# ============================================================================
# Tests — the harness itself (#31, #55)
#
# A test suite that cannot fail is worse than no suite: it reports green over
# every regression it was written to catch. Every test shaped "run the thing,
# then `return 0`" is unfailable unless errexit is genuinely active inside the
# body: the bare command's non-zero status would neither abort the body nor reach
# run_test. invoke_test_body re-arms errexit inside its subshell to guarantee
# that, and #55 added the other half of the contract — the caller must invoke it
# from outside any errexit-ignore context, or strict-POSIX bash silently drops
# the re-arm. These two cases pin both halves: a failing bare command must fail
# its test, and a passing body must still pass.
#
# Both cases below therefore use the same `set +e` / plain call / `set -e` shape
# as run_test. Reintroducing `|| status=$?` here would make them test a path the
# harness no longer uses — and pass while the real one is broken.
# ============================================================================

# Fails on its first bare command, then claims success exactly as the unfailable
# tests did. Never registered as a test — it is the fixture the two cases below
# feed to the real harness entry point.
_fixture_test_body_fails_then_returns_zero() {
    false
    echo "errexit was NOT active: execution continued past a failed bare command"
    return 0
}

_fixture_test_body_succeeds() {
    true
    return 0
}

test_harness_bare_command_failure_fails_the_test() {
    local output status
    set +e
    output=$(invoke_test_body _fixture_test_body_fails_then_returns_zero)
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        echo "invoke_test_body returned 0 for a body whose bare command failed —"
        echo "every 'run it, then return 0' test in this file is unfailable."
        [ -n "$output" ] && printf '  body said: %s\n' "$output"
        return 1
    fi
    if printf '%s\n' "$output" | grep -q 'errexit was NOT active'; then
        echo "the body ran past its failed command (errexit suppressed inside the subshell)"
        return 1
    fi
    return 0
}

test_harness_passing_test_still_passes() {
    local status
    set +e
    invoke_test_body _fixture_test_body_succeeds > /dev/null 2>&1
    status=$?
    set -e
    assert_eq "0" "$status" "a body that succeeds must still be reported as a pass" || return 1
    return 0
}

# ============================================================================
# Tests — Help & Error Handling
# ============================================================================

test_help_flag() {
    local output
    output=$(bash "$INSTALL_SCRIPT" --help 2>&1)
    echo "$output" | grep -q "Usage:" || { echo "Help output missing 'Usage:'"; return 1; }
    echo "$output" | grep -q "claude-code" || { echo "Help output missing 'claude-code'"; return 1; }
    echo "$output" | grep -q "opencode" || { echo "Help output missing 'opencode'"; return 1; }
    echo "$output" | grep -q "all-global" || { echo "Help output missing 'all-global'"; return 1; }
    echo "$output" | grep -q "\-\-agent" || { echo "Help output missing '--agent'"; return 1; }
    echo "$output" | grep -q "\-\-path" || { echo "Help output missing '--path'"; return 1; }
}

test_help_exits_zero() {
    bash "$INSTALL_SCRIPT" --help > /dev/null 2>&1
    # If we get here, exit code was 0
    return 0
}

test_invalid_agent() {
    if bash "$INSTALL_SCRIPT" --agent nonexistent > /dev/null 2>&1; then
        echo "Expected non-zero exit for invalid agent, but got 0"
        return 1
    fi
    return 0
}

test_invalid_option() {
    if bash "$INSTALL_SCRIPT" --bogus-flag > /dev/null 2>&1; then
        echo "Expected non-zero exit for unknown option, but got 0"
        return 1
    fi
    return 0
}

# ============================================================================
# Tests — Claude Code
# ============================================================================

test_install_claude_code() {
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    assert_all_skills_installed "$HOME/.claude/skills"
}

test_claude_code_skill_count() {
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    local count
    count=$(find "$HOME/.claude/skills" -name "SKILL.md" | wc -l | tr -d ' ')
    assert_eq "28" "$count" "Expected exactly 28 skills for Claude Code"
}

# ============================================================================
# Tests — OpenCode
# ============================================================================

test_install_opencode() {
    bash "$INSTALL_SCRIPT" --agent opencode > /dev/null 2>&1
    assert_all_skills_installed "$HOME/.config/opencode/skills"
}

test_opencode_skill_count() {
    bash "$INSTALL_SCRIPT" --agent opencode > /dev/null 2>&1
    local count
    count=$(find "$HOME/.config/opencode/skills" -name "SKILL.md" | wc -l | tr -d ' ')
    assert_eq "28" "$count" "Expected exactly 28 skills for OpenCode"
}

test_opencode_commands() {
    bash "$INSTALL_SCRIPT" --agent opencode > /dev/null 2>&1
    local commands_dir="$HOME/.config/opencode/commands"
    assert_dir_exists "$commands_dir" || return 1
    assert_file_exists "$commands_dir/sdd-init.md" || return 1
    assert_file_exists "$commands_dir/sdd-apply.md" || return 1
    assert_file_exists "$commands_dir/sdd-explore.md" || return 1
    assert_file_exists "$commands_dir/sdd-verify.md" || return 1
    assert_file_exists "$commands_dir/sdd-archive.md" || return 1
    assert_file_exists "$commands_dir/sdd-new.md" || return 1
    assert_file_exists "$commands_dir/sdd-ff.md" || return 1
    assert_file_exists "$commands_dir/sdd-continue.md" || return 1
    assert_file_exists "$commands_dir/sdd-status.md" || return 1
    local count
    count=$(find "$commands_dir" -name "sdd-*.md" | wc -l | tr -d ' ')
    assert_eq "9" "$count" "Expected exactly 9 OpenCode commands"
}

# ============================================================================
# Tests — Codex
# ============================================================================

test_install_codex() {
    bash "$INSTALL_SCRIPT" --agent codex > /dev/null 2>&1
    assert_all_skills_installed "$HOME/.codex/skills"
}

test_codex_skill_count() {
    bash "$INSTALL_SCRIPT" --agent codex > /dev/null 2>&1
    local count
    count=$(find "$HOME/.codex/skills" -name "SKILL.md" | wc -l | tr -d ' ')
    assert_eq "28" "$count" "Expected exactly 28 skills for Codex"
}

# ============================================================================
# Tests — Project-local
# ============================================================================

test_install_project_local() {
    # #38: install.sh is now a wrapper; --agent project-local maps to a setup.sh
    # project trial rooted at the cwd (which must be a git repo), so the skills land
    # under the repo's .claude/skills rather than a bare ./skills.
    local project="$TEST_TMPDIR/local-project"
    make_git_repo "$project"
    (cd "$project" && bash "$INSTALL_SCRIPT" --agent project-local > /dev/null 2>&1)
    assert_all_skills_installed "$project/.claude/skills"
}

test_project_local_skill_count() {
    local project="$TEST_TMPDIR/local-project"
    make_git_repo "$project"
    (cd "$project" && bash "$INSTALL_SCRIPT" --agent project-local > /dev/null 2>&1)
    local count
    count=$(find "$project/.claude/skills" -name "SKILL.md" | wc -l | tr -d ' ')
    assert_eq "28" "$count" "Expected exactly 28 skills for project-local"
}

# ============================================================================
# Tests — Custom path
# ============================================================================

test_custom_path() {
    # #38: --agent custom --path DIR maps to a setup.sh project trial rooted at DIR
    # (a git repo); skills land under DIR/.claude/skills.
    local custom="$TEST_TMPDIR/custom-skills"
    make_git_repo "$custom"
    bash "$INSTALL_SCRIPT" --agent custom --path "$custom" > /dev/null 2>&1
    assert_all_skills_installed "$custom/.claude/skills"
}

test_custom_path_skill_count() {
    local custom="$TEST_TMPDIR/custom-skills"
    make_git_repo "$custom"
    bash "$INSTALL_SCRIPT" --agent custom --path "$custom" > /dev/null 2>&1
    local count
    count=$(find "$custom/.claude/skills" -name "SKILL.md" | wc -l | tr -d ' ')
    assert_eq "28" "$count" "Expected exactly 28 skills for custom path"
}

# ============================================================================
# Tests — All-global
# ============================================================================

test_all_global() {
    bash "$INSTALL_SCRIPT" --agent all-global > /dev/null 2>&1
    # Claude Code
    assert_all_skills_installed "$HOME/.claude/skills" || return 1
    # OpenCode
    assert_all_skills_installed "$HOME/.config/opencode/skills" || return 1
    # Codex
    assert_all_skills_installed "$HOME/.codex/skills" || return 1
    # Pi
    assert_all_skills_installed "$HOME/.pi/agent/skills" || return 1
    # omp
    assert_all_skills_installed "$HOME/.omp/agent/skills" || return 1
}

test_all_global_total_skill_count() {
    bash "$INSTALL_SCRIPT" --agent all-global > /dev/null 2>&1
    # 5 targets x 28 skills = 140 SKILL.md files
    local total=0
    for dir in \
        "$HOME/.claude/skills" \
        "$HOME/.config/opencode/skills" \
        "$HOME/.codex/skills" \
        "$HOME/.pi/agent/skills" \
        "$HOME/.omp/agent/skills"; do
        local count
        count=$(find "$dir" -name "SKILL.md" | wc -l | tr -d ' ')
        assert_eq "28" "$count" "Expected 28 skills in $dir" || return 1
        total=$((total + count))
    done
    assert_eq "140" "$total" "Expected 140 total SKILL.md files across all targets"
}

test_all_global_opencode_commands() {
    bash "$INSTALL_SCRIPT" --agent all-global > /dev/null 2>&1
    local commands_dir="$HOME/.config/opencode/commands"
    assert_dir_exists "$commands_dir" || return 1
    local count
    count=$(find "$commands_dir" -name "sdd-*.md" | wc -l | tr -d ' ')
    assert_eq "9" "$count" "Expected 9 OpenCode commands with all-global"
}

# ============================================================================
# Tests — Idempotency
# ============================================================================

test_idempotent_claude_code() {
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    assert_all_skills_installed "$HOME/.claude/skills"
    local count
    count=$(find "$HOME/.claude/skills" -name "SKILL.md" | wc -l | tr -d ' ')
    assert_eq "28" "$count" "Expected exactly 28 skills after double install"
}

test_idempotent_opencode() {
    bash "$INSTALL_SCRIPT" --agent opencode > /dev/null 2>&1
    bash "$INSTALL_SCRIPT" --agent opencode > /dev/null 2>&1
    assert_all_skills_installed "$HOME/.config/opencode/skills" || return 1
    local skill_count
    skill_count=$(find "$HOME/.config/opencode/skills" -name "SKILL.md" | wc -l | tr -d ' ')
    assert_eq "28" "$skill_count" "Expected exactly 28 skills after double install" || return 1
    local cmd_count
    cmd_count=$(find "$HOME/.config/opencode/commands" -name "sdd-*.md" | wc -l | tr -d ' ')
    assert_eq "9" "$cmd_count" "Expected exactly 9 commands after double install"
}

test_idempotent_all_global() {
    bash "$INSTALL_SCRIPT" --agent all-global > /dev/null 2>&1
    bash "$INSTALL_SCRIPT" --agent all-global > /dev/null 2>&1
    for dir in \
        "$HOME/.claude/skills" \
        "$HOME/.config/opencode/skills" \
        "$HOME/.codex/skills" \
        "$HOME/.pi/agent/skills" \
        "$HOME/.omp/agent/skills"; do
        local count
        count=$(find "$dir" -name "SKILL.md" | wc -l | tr -d ' ')
        assert_eq "28" "$count" "Expected 28 skills in $dir after double install" || return 1
    done
}

# ============================================================================
# Tests — Content integrity
# ============================================================================

test_skill_content_matches_source() {
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    local source_dir="$REPO_DIR/skills"
    for skill in "${EXPECTED_SKILLS[@]}"; do
        local src="$source_dir/$skill/SKILL.md"
        local dst="$HOME/.claude/skills/$skill/SKILL.md"
        if ! diff -q "$src" "$dst" > /dev/null 2>&1; then
            echo "Content mismatch: $skill/SKILL.md"
            echo "  Source: $src"
            echo "  Dest:   $dst"
            return 1
        fi
    done
    return 0
}

test_opencode_command_content_matches_source() {
    bash "$INSTALL_SCRIPT" --agent opencode > /dev/null 2>&1
    local source_dir="$REPO_DIR/examples/opencode/commands"
    local target_dir="$HOME/.config/opencode/commands"
    for cmd_file in "$source_dir"/sdd-*.md; do
        local name
        name=$(basename "$cmd_file")
        if ! diff -q "$cmd_file" "$target_dir/$name" > /dev/null 2>&1; then
            echo "Content mismatch: commands/$name"
            return 1
        fi
    done
    return 0
}

# ============================================================================
# Tests — Output verification
# ============================================================================

test_output_shows_skill_names() {
    # #38: install.sh delegates to setup.sh, whose output reports the count and the
    # skills directory rather than echoing every individual skill name. Assert the
    # delegated install names what it did: the agent, the count, and the skills path.
    local output
    output=$(bash "$INSTALL_SCRIPT" --agent claude-code 2>&1)
    echo "$output" | grep -q "claude-code" || { echo "Output missing the agent name"; return 1; }
    echo "$output" | grep -q "skills installed" || { echo "Output missing the skills-installed count line"; return 1; }
    echo "$output" | grep -q ".claude/skills" || { echo "Output missing the skills directory"; return 1; }
    return 0
}

test_output_shows_done_message() {
    local output
    output=$(bash "$INSTALL_SCRIPT" --agent claude-code 2>&1)
    echo "$output" | grep -q "Done!" || {
        echo "Output missing 'Done!' message"
        return 1
    }
}

test_output_shows_install_count() {
    local output
    output=$(bash "$INSTALL_SCRIPT" --agent claude-code 2>&1)
    echo "$output" | grep -q "28 skills installed" || {
        echo "Output missing '28 skills installed' message"
        return 1
    }
}

test_output_shows_next_step() {
    # setup.sh's summary points the user at the next action (open a project and run
    # /sdd-init) rather than install.sh's old "Next step" banner (#38).
    local output
    output=$(bash "$INSTALL_SCRIPT" --agent claude-code 2>&1)
    echo "$output" | grep -q "/sdd-init" || {
        echo "Output missing the /sdd-init next-step guidance"
        return 1
    }
}

test_output_shows_engram_note() {
    local output
    output=$(bash "$INSTALL_SCRIPT" --agent claude-code 2>&1)
    echo "$output" | grep -q "Engram" || {
        echo "Output missing Engram recommendation"
        return 1
    }
}

# ============================================================================
# Tests — OS detection (limited — we can only test the current OS)
# ============================================================================

test_os_detection_runs() {
    local output
    output=$(bash "$INSTALL_SCRIPT" --help 2>&1 || true)
    [[ -n "$output" ]] || { echo "No output from --help"; return 1; }
}

test_header_shows_detected_os() {
    # #38: install.sh no longer prints its own "Detected: <os>" header — it delegates
    # to setup.sh, whose header/summary frames the run instead.
    local output
    output=$(bash "$INSTALL_SCRIPT" --agent claude-code 2>&1)
    echo "$output" | grep -qiE "Setting up|Setup Complete|Kurama" || {
        echo "Output missing the setup.sh run header"
        return 1
    }
}

# ============================================================================
# Tests — Edge cases
# ============================================================================

test_pre_existing_dir_not_clobbered() {
    # Create a pre-existing file that should NOT be deleted
    mkdir -p "$HOME/.claude/skills/my-custom-skill"
    echo "custom content" > "$HOME/.claude/skills/my-custom-skill/SKILL.md"
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    # SDD skills should be installed
    assert_all_skills_installed "$HOME/.claude/skills" || return 1
    # Custom skill should still exist
    assert_file_exists "$HOME/.claude/skills/my-custom-skill/SKILL.md" || return 1
    local content
    content=$(cat "$HOME/.claude/skills/my-custom-skill/SKILL.md")
    assert_eq "custom content" "$content" "Custom skill content should be preserved"
}

test_overwrite_stale_skill() {
    # Pre-create a stale SKILL.md
    mkdir -p "$HOME/.claude/skills/sdd-apply"
    echo "stale" > "$HOME/.claude/skills/sdd-apply/SKILL.md"
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    # Should be replaced with actual content (not "stale")
    local content
    content=$(head -c 5 "$HOME/.claude/skills/sdd-apply/SKILL.md")
    if [[ "$content" == "stale" ]]; then
        echo "SKILL.md was NOT overwritten — still contains stale data"
        return 1
    fi
    assert_file_not_empty "$HOME/.claude/skills/sdd-apply/SKILL.md"
}

test_nested_custom_path() {
    # A deeply nested custom target still works: setup.sh installs into the repo's
    # .claude/skills under the deep path (#38).
    local deep="$TEST_TMPDIR/a/b/c/d/repo"
    make_git_repo "$deep"
    bash "$INSTALL_SCRIPT" --agent custom --path "$deep" > /dev/null 2>&1
    assert_all_skills_installed "$deep/.claude/skills"
}

# ============================================================================
# Tests — setup.sh orchestrator safety (marker corruption / data loss)
# ============================================================================

test_setup_unbalanced_marker_aborts() {
    # A prompt file containing BEGIN without END (manual edit, merge conflict,
    # external tool) must NOT be truncated. setup.sh must abort (non-zero exit)
    # and leave the user's file byte-for-byte intact.
    mkdir -p "$HOME/.claude"
    local f="$HOME/.claude/CLAUDE.md"
    printf '%s\n' '# User config' \
        '<!-- BEGIN:kurama -->' \
        'stale orchestrator body' \
        'CRITICAL USER CONTENT AFTER BEGIN' > "$f"
    cp "$f" "$TEST_TMPDIR/claude.orig"

    if bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1; then
        echo "Expected setup.sh to abort on unbalanced markers, but it exited 0"
        return 1
    fi

    grep -qF 'CRITICAL USER CONTENT AFTER BEGIN' "$f" || {
        echo "User content after BEGIN was lost"
        return 1
    }
    if ! cmp -s "$f" "$TEST_TMPDIR/claude.orig"; then
        echo "CLAUDE.md was modified despite the abort"
        return 1
    fi
    return 0
}

test_setup_balanced_marker_updates_and_backs_up() {
    # A balanced marker pair updates in place, preserves the surrounding user
    # content, stays idempotent, and writes a timestamped backup first.
    mkdir -p "$HOME/.claude"
    local f="$HOME/.claude/CLAUDE.md"
    printf '%s\n' '# Header' \
        '<!-- BEGIN:kurama -->' \
        'old body' \
        '<!-- END:kurama -->' \
        '# trailing user notes' > "$f"

    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1 || {
        echo "setup.sh failed on a balanced-marker update"
        return 1
    }

    grep -qF '# Header' "$f" || { echo "Header lost"; return 1; }
    grep -qF '# trailing user notes' "$f" || { echo "Trailing user notes lost"; return 1; }
    if grep -qF 'old body' "$f"; then
        echo "Old orchestrator body was not replaced"
        return 1
    fi

    local begin end
    begin=$(grep -c 'BEGIN:kurama' "$f")
    end=$(grep -c 'END:kurama' "$f")
    assert_eq "1" "$begin" "Exactly one BEGIN marker after update" || return 1
    assert_eq "1" "$end" "Exactly one END marker after update" || return 1

    local backups
    backups=$(find "$HOME/.claude" -name 'CLAUDE.md.bak.*' | wc -l | tr -d ' ')
    if [ "$backups" -lt 1 ]; then
        echo "No timestamped backup was created before rewriting"
        return 1
    fi
    return 0
}

# ============================================================================
# Tests — setup.sh manifest-driven install + receipt (parity with install.sh)
# ============================================================================

test_setup_installs_default_skill_set() {
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    assert_all_skills_installed "$HOME/.claude/skills" || return 1
    local count
    count=$(find "$HOME/.claude/skills" -name "SKILL.md" | wc -l | tr -d ' ')
    assert_eq "28" "$count" "setup.sh should install the 28 default skills"
}

test_setup_includes_tdd() {
    # setup.sh installs the default set, which now includes the tdd module.
    # Installing the module does NOT activate TDD — activation stays opt-in per
    # project.
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    assert_dir_exists "$HOME/.claude/skills/tdd" || return 1
    assert_file_exists "$HOME/.claude/skills/tdd/SKILL.md" || return 1
    return 0
}

test_setup_writes_install_manifest() {
    # setup.sh installs must leave the same receipt install.sh does, so uninstall
    # works on the recommended (setup.sh) install path.
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    grep -q '"version"' "$manifest" || { echo "setup.sh install manifest missing version field"; return 1; }
    grep -q '"files"' "$manifest" || { echo "setup.sh install manifest missing files array"; return 1; }
    grep -q 'sdd-apply/SKILL.md' "$manifest" || { echo "setup.sh install manifest missing an installed skill path"; return 1; }
    return 0
}

test_setup_uninstall_round_trip() {
    # A setup.sh install must uninstall cleanly via uninstall.sh (receipt-driven),
    # while user-created skills survive.
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    mkdir -p "$HOME/.claude/skills/my-custom"
    echo "keep me" > "$HOME/.claude/skills/my-custom/SKILL.md"

    bash "$UNINSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1

    if [ -d "$HOME/.claude/skills/sdd-apply" ]; then
        echo "sdd-apply should have been removed by uninstall after a setup.sh install"
        return 1
    fi
    if [ -f "$HOME/.claude/skills/.kurama-install-manifest.json" ]; then
        echo "install manifest should have been removed by uninstall"
        return 1
    fi
    assert_file_exists "$HOME/.claude/skills/my-custom/SKILL.md" || return 1
    local content
    content=$(cat "$HOME/.claude/skills/my-custom/SKILL.md")
    assert_eq "keep me" "$content" "User-created skill preserved through setup.sh-install uninstall"
}

test_setup_matches_manifest_default_set() {
    # setup.sh derives its skill list from skills/manifest.json (no hardcoded list):
    # the installed tree must equal install.sh's default tree exactly.
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    local setup_list
    setup_list=$(find "$HOME/.claude/skills" -name SKILL.md | sed "s#$HOME/.claude/skills/##" | sort)

    # Fresh HOME for the install.sh reference tree.
    rm -rf "$HOME/.claude/skills"
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    local install_list
    install_list=$(find "$HOME/.claude/skills" -name SKILL.md | sed "s#$HOME/.claude/skills/##" | sort)

    assert_eq "$install_list" "$setup_list" "setup.sh and install.sh must install the same default skill set"
}

# ============================================================================
# Tests — installer references point to files that exist (opencode templates)
# ============================================================================

test_no_broken_opencode_json_reference() {
    # examples/opencode/opencode.json does not exist; the real templates are
    # opencode.single.json / opencode.multi.json. Neither installer may point at
    # the nonexistent template path.
    if grep -E 'examples[/\\]opencode[/\\]opencode\.json' \
        "$SCRIPT_DIR/install.sh" > /dev/null 2>&1; then
        echo "Found reference to the nonexistent examples/opencode/opencode.json"
        return 1
    fi
    return 0
}

test_opencode_json_reference_fixed() {
    # #38: install.sh no longer emits OpenCode guidance — setup.sh owns it and builds
    # the template path from the resolved mode (opencode.single.json /
    # opencode.multi.json), never the nonexistent examples/opencode/opencode.json.
    # shellcheck disable=SC2016  # matching the literal ${OPENCODE_MODE} in setup.sh
    grep -qF 'opencode.${OPENCODE_MODE}.json' "$SCRIPT_DIR/setup.sh" || {
        echo "setup.sh does not build the mode-specific opencode template path"
        return 1
    }
    return 0
}

test_opencode_template_files_exist() {
    assert_file_exists "$REPO_DIR/examples/opencode/opencode.single.json" || return 1
    assert_file_exists "$REPO_DIR/examples/opencode/opencode.multi.json" || return 1
    if [ -f "$REPO_DIR/examples/opencode/opencode.json" ]; then
        echo "Unexpected examples/opencode/opencode.json exists (installers reference single/multi)"
        return 1
    fi
    return 0
}

# ============================================================================
# Tests — Phase 11: OpenCode shared prompts + named model profiles (W1–W3, W9)
#
# setup.sh --agent opencode runs the global flow. A fake `npm` shim on PATH keeps
# any npm invocation off the network; jq/python/git behind it stay reachable.
# --without-engram keeps the O5 flow (brew/engram) out. The shim is kept as a
# guard even though the background-agents npm dependency is no longer installed.
# ============================================================================

# Fake npm that logs nothing and exits 0, so setup_opencode's dependency install
# is a no-op (no registry, no network). Prepended to PATH; real tools stay behind.
make_npm_shim() {
    local bindir="$1"
    mkdir -p "$bindir"
    cat > "$bindir/npm" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
    chmod +x "$bindir/npm"
}

# Run the global OpenCode setup with the npm shim on PATH. Extra args are passed
# through (mode/profile). Echoes nothing; returns setup.sh's exit code.
run_setup_opencode() {
    local shim="$TEST_TMPDIR/npmshim"
    make_npm_shim "$shim"
    PATH="$shim:$PATH" bash "$SETUP_SCRIPT" --agent opencode --without-engram \
        --non-interactive "$@" > /dev/null 2>&1
}

# The legacy background-agents.ts plugin hangs the OpenCode TUI, so setup must
# neither install it nor leave one behind from an older Kurama version, and must
# not add its npm dependency to the user's own package.json.
test_opencode_background_agents_removed() {
    local plugin="$HOME/.config/opencode/plugins/background-agents.ts"
    mkdir -p "$(dirname "$plugin")"
    printf '// stale plugin from an older Kurama install\n' > "$plugin"

    run_setup_opencode --opencode-mode multi \
        || { echo "setup opencode multi failed"; return 1; }

    if [ -f "$plugin" ]; then
        echo "setup left the legacy background-agents plugin behind: $plugin"
        return 1
    fi

    local pkg="$HOME/.config/opencode/package.json"
    if [ -f "$pkg" ] && grep -q "unique-names-generator" "$pkg"; then
        echo "setup added unique-names-generator to $pkg"
        return 1
    fi
    return 0
}

test_opencode_shared_prompts_installed() {
    run_setup_opencode --opencode-mode multi || { echo "setup opencode multi failed"; return 1; }
    local pdir="$HOME/.config/opencode/prompts/sdd"
    assert_dir_exists "$pdir" || return 1
    local phase
    for phase in init explore propose spec design tasks apply verify archive; do
        assert_file_not_empty "$pdir/sdd-$phase.md" || return 1
    done
    local count
    count=$(find "$pdir" -name "sdd-*.md" | wc -l | tr -d ' ')
    assert_eq "9" "$count" "Expected 9 shared SDD prompt files"
}

test_opencode_multi_references_prompt_files() {
    # The committed multi template must reference the shared prompt files (not
    # inline the prompt text) so profiles can share one file per phase.
    local f="$REPO_DIR/examples/opencode/opencode.multi.json"
    # #78: the reference is a path RELATIVE to the opencode.json that contains it,
    # which is what upstream gentle-ai emits from code
    # (internal/components/sdd/prompts.go). The tilde form this used to assert came
    # from upstream's PRD prose, and nothing verifies that OpenCode expands ~ inside
    # {file:} — if it does not, all 9 subagents start with no prompt at all.
    grep -q 'file:\./prompts/sdd/sdd-apply.md' "$f" || {
        echo "opencode.multi.json does not reference the shared apply prompt file"; return 1; }
    if grep -q 'file:~' "$f"; then
        echo "opencode.multi.json still uses the unverified {file:~...} form"; return 1
    fi
    # And it must NOT still carry the old inline executor prompt.
    if grep -q 'You are an SDD executor' "$f"; then
        echo "opencode.multi.json still inlines executor prompt text"; return 1
    fi
    return 0
}

test_opencode_profile_generates_agents() {
    run_setup_opencode --opencode-mode multi --opencode-profile testp:prov/model \
        || { echo "setup opencode profile install failed"; return 1; }
    local cfg="$HOME/.config/opencode/opencode.json"
    assert_file_exists "$cfg" || return 1
    jq -e . "$cfg" > /dev/null 2>&1 || { echo "opencode.json is not valid JSON"; return 1; }
    jq -e '.agent["kurama-orchestrator"]' "$cfg" > /dev/null 2>&1 || {
        echo "kurama-orchestrator agent missing"; return 1; }
    local n
    n=$(jq -r '[.agent | keys[] | select(endswith("-testp"))] | length' "$cfg")
    assert_eq "9" "$n" "Expected 9 sdd-<phase>-testp profile subagents" || return 1
    # Orchestrator is primary; a suffixed subagent is a hidden subagent.
    assert_eq "primary" "$(jq -r '.agent["kurama-orchestrator"].mode' "$cfg")" \
        "kurama-orchestrator must be mode:primary" || return 1
    assert_eq "subagent" "$(jq -r '.agent["sdd-apply-testp"].mode' "$cfg")" \
        "sdd-apply-testp must be mode:subagent" || return 1
    # Task permission scoped to this profile's own suffixed agents. #78 named each
    # one instead of globbing, so the scoping is asserted phase by phase: every
    # suffixed agent is granted, and no unsuffixed base phase agent is.
    local phase
    for phase in init explore propose spec design tasks apply verify archive; do
        assert_eq "allow" "$(jq -r --arg k "sdd-$phase-testp" '.agent["kurama-orchestrator"].permission.task[$k]' "$cfg")" \
            "orchestrator task permission not scoped to sdd-$phase-testp" || return 1
        assert_eq "null" "$(jq -r --arg k "sdd-$phase" '.agent["kurama-orchestrator"].permission.task[$k]' "$cfg")" \
            "the profile orchestrator must not grant the unsuffixed sdd-$phase" || return 1
    done
    # The model passed on the flag is applied to profile agents on first install.
    assert_eq "prov/model" "$(jq -r '.agent["sdd-apply-testp"].model' "$cfg")" \
        "flag model not applied to sdd-apply-testp" || return 1
    # The base multi agents survive alongside the profile.
    jq -e '.agent["sdd-apply"]' "$cfg" > /dev/null 2>&1 || {
        echo "base sdd-apply agent was clobbered by the profile"; return 1; }
}

test_opencode_profile_idempotent_preserves_model() {
    # Two documented behaviors, opposite by design (install_opencode_profile steps
    # 2 and 3). A bare `--opencode-profile NAME` re-run RESTORES hand-edited models;
    # `NAME:provider/model` is an explicit choice for THIS run and deliberately
    # overrides them, so re-running with a new model is not silently ignored.
    run_setup_opencode --opencode-mode multi --opencode-profile testp:prov/model \
        || { echo "first profile install failed"; return 1; }
    local cfg="$HOME/.config/opencode/opencode.json"
    local edited
    edited=$(jq '.agent["sdd-apply-testp"].model = "HAND/EDITED"' "$cfg")
    printf '%s\n' "$edited" > "$cfg"

    # 1. Bare re-run (no ":provider/model") must PRESERVE the hand edit.
    run_setup_opencode --opencode-mode multi --opencode-profile testp \
        || { echo "bare profile re-run failed"; return 1; }
    assert_eq "HAND/EDITED" "$(jq -r '.agent["sdd-apply-testp"].model' "$cfg")" \
        "a bare profile re-run must preserve the hand-edited model" || return 1

    # 2. An explicit model must OVERRIDE it — otherwise changing the model by
    #    re-running would silently do nothing.
    run_setup_opencode --opencode-mode multi --opencode-profile testp:prov/other \
        || { echo "explicit-model profile re-run failed"; return 1; }
    assert_eq "prov/other" "$(jq -r '.agent["sdd-apply-testp"].model' "$cfg")" \
        "an explicit :provider/model must override a hand-edited model" || return 1

    # No duplicate profile keys after either re-run.
    local n
    n=$(jq -r '[.agent | keys[] | select(endswith("-testp"))] | length' "$cfg")
    assert_eq "9" "$n" "Expected 9 profile agents after re-run (no duplicates)"
}

test_opencode_profile_rejects_bad_name() {
    # An invalid profile name must abort before any work.
    if bash "$SETUP_SCRIPT" --agent opencode --opencode-profile 'Bad Name' \
        --without-engram --non-interactive > /dev/null 2>&1; then
        echo "setup.sh accepted an invalid profile name"; return 1
    fi
    return 0
}

test_opencode_base_rerun_prunes_orphan_orchestrator() {
    # Install a profile, then re-run WITHOUT --opencode-profile. The base merge
    # strips every sdd-* key (which removes the profile's suffixed subagents), so
    # it must also prune kurama-orchestrator — otherwise a mode:primary agent is
    # left dangling, scoped to sdd-*-NAME subagents that no longer exist.
    run_setup_opencode --opencode-mode multi --opencode-profile testp:prov/model \
        || { echo "profile install failed"; return 1; }
    local cfg="$HOME/.config/opencode/opencode.json"
    jq -e '.agent["kurama-orchestrator"]' "$cfg" > /dev/null 2>&1 || {
        echo "precondition: kurama-orchestrator should exist after profile install"; return 1; }
    # Re-run base-only (non-interactive default profile = "no").
    run_setup_opencode --opencode-mode multi || { echo "base-only re-run failed"; return 1; }
    jq -e . "$cfg" > /dev/null 2>&1 || { echo "opencode.json not valid JSON after re-run"; return 1; }
    # The suffixed subagents are gone.
    local n
    n=$(jq -r '[.agent | keys[] | select(endswith("-testp"))] | length' "$cfg")
    assert_eq "0" "$n" "profile subagents should be gone after base-only re-run" || return 1
    # And the orchestrator no longer dangles.
    if jq -e '.agent["kurama-orchestrator"]' "$cfg" > /dev/null 2>&1; then
        echo "orphaned kurama-orchestrator left behind after base-only re-run"; return 1
    fi
    # Base multi agents are present and intact.
    jq -e '.agent["sdd-apply"]' "$cfg" > /dev/null 2>&1 || {
        echo "base sdd-apply missing after base-only re-run"; return 1; }
    return 0
}

test_opencode_status_command_installed() {
    bash "$INSTALL_SCRIPT" --agent opencode > /dev/null 2>&1
    assert_file_exists "$HOME/.config/opencode/commands/sdd-status.md" || return 1
    # It is a meta command routed to the orchestrator (no subtask rewrite).
    grep -q '^agent: sdd-orchestrator' "$HOME/.config/opencode/commands/sdd-status.md" || {
        echo "sdd-status.md must route to sdd-orchestrator"; return 1; }
}

# ============================================================================
# Tests — Manifest-driven install + versioning (E10)
# ============================================================================

test_manifest_exists_and_parses() {
    assert_file_exists "$MANIFEST_FILE" || return 1
    if command -v jq > /dev/null 2>&1; then
        jq -e . "$MANIFEST_FILE" > /dev/null 2>&1 || { echo "manifest.json failed jq parse"; return 1; }
    elif command -v python3 > /dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$MANIFEST_FILE" > /dev/null 2>&1 \
            || { echo "manifest.json failed python parse"; return 1; }
    fi
    grep -q '"go-testing"' "$MANIFEST_FILE" || { echo "manifest missing go-testing"; return 1; }
    grep -q '"judgment-day"' "$MANIFEST_FILE" || { echo "manifest missing judgment-day"; return 1; }
    return 0
}

test_version_flag() {
    local output
    output=$(bash "$INSTALL_SCRIPT" --version 2>&1)
    echo "$output" | grep -q "kurama" || { echo "Version output missing 'kurama'"; return 1; }
    echo "$output" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+' || { echo "Version output missing a semver-like version"; return 1; }
}

test_version_exits_zero() {
    bash "$INSTALL_SCRIPT" --version > /dev/null 2>&1
    return 0
}

test_install_writes_install_manifest() {
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    grep -q '"version"' "$manifest" || { echo "install manifest missing version field"; return 1; }
    grep -q '"files"' "$manifest" || { echo "install manifest missing files array"; return 1; }
    grep -q 'sdd-apply/SKILL.md' "$manifest" || { echo "install manifest missing an installed skill path"; return 1; }
    return 0
}

test_default_install_includes_optional_groups() {
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    if [ -d "$HOME/.claude/skills/go-testing" ]; then
        echo "go-testing is in the opt-in lang group and must NOT install by default"; return 1
    fi
    assert_dir_exists "$HOME/.claude/skills/kanban-github" || return 1   # optional group ships kanban-github too
    assert_dir_exists "$HOME/.claude/skills/judgment-day" || return 1
    return 0
}

test_without_optional_excludes_go_testing() {
    # The optional group holds FIVE skills now; go-testing moved to the opt-in `lang`
    # group, so --without optional drops those five, landing 23.
    bash "$INSTALL_SCRIPT" --agent claude-code --without optional > /dev/null 2>&1
    local base="$HOME/.claude/skills"
    if [ -d "$base/kanban-github" ]; then
        echo "kanban-github should be excluded by --without optional"
        return 1
    fi
    if [ -d "$base/kanban-github" ]; then
        echo "kanban-github should be excluded by --without optional"
        return 1
    fi
    # The `optional` group holds FIVE skills now (#73 added sdd-learn, #104 added
    # sdd-brainstorm, #85 added kurama-report, #86 added systemic-issue-triage).
    # Naming all five is what keeps the total below honest: drop only some of them
    # while another group silently gains a skill and the arithmetic still lands on
    # the same number.
    if [ -d "$base/sdd-learn" ]; then
        echo "sdd-learn should be excluded by --without optional"
        return 1
    fi
    if [ -d "$base/sdd-brainstorm" ]; then
        echo "sdd-brainstorm should be excluded by --without optional"
        return 1
    fi
    if [ -d "$base/kurama-report" ]; then
        echo "kurama-report should be excluded by --without optional"
        return 1
    fi
    if [ -d "$base/systemic-issue-triage" ]; then
        echo "systemic-issue-triage should be excluded by --without optional"
        return 1
    fi
    assert_dir_exists "$base/judgment-day" || return 1   # quality group still on
    assert_dir_exists "$base/sdd-apply" || return 1       # sdd-core always on
    local count
    count=$(find "$base" -name "SKILL.md" | wc -l | tr -d ' ')
    # Expressed against EXPECTED_SKILLS, not the literal 23: 26 - 3 and 28 - 5 are both
    # 23, so a hardcoded 23 would have passed unchanged on the pre-#85/#86 tree and
    # proved nothing about the two new skills leaving the group.
    assert_eq "$(( ${#EXPECTED_SKILLS[@]} - 5 ))" "$count" \
        "Expected the default set minus the optional group's FIVE skills (kanban-github, sdd-learn, sdd-brainstorm, kurama-report, systemic-issue-triage)"
}

test_without_quality_excludes_judgment_day() {
    bash "$INSTALL_SCRIPT" --agent claude-code --without quality > /dev/null 2>&1
    local base="$HOME/.claude/skills"
    if [ -d "$base/judgment-day" ]; then
        echo "judgment-day should be excluded by --without quality"
        return 1
    fi
    assert_dir_exists "$base/kanban-github" || return 1         # optional group still on
    local count
    count=$(find "$base" -name "SKILL.md" | wc -l | tr -d ' ')
    assert_eq "27" "$count" "Expected 27 skills with --without quality (28 default - judgment-day)"
}

test_without_both_groups() {
    bash "$INSTALL_SCRIPT" --agent claude-code --without quality --without optional > /dev/null 2>&1
    local base="$HOME/.claude/skills"
    if [ -d "$base/judgment-day" ]; then echo "judgment-day should be excluded"; return 1; fi
    if [ -d "$base/kanban-github" ]; then echo "kanban-github should be excluded"; return 1; fi
    if [ -d "$base/sdd-learn" ]; then echo "sdd-learn should be excluded"; return 1; fi
    if [ -d "$base/sdd-brainstorm" ]; then echo "sdd-brainstorm should be excluded"; return 1; fi
    if [ -d "$base/kurama-report" ]; then echo "kurama-report should be excluded"; return 1; fi
    if [ -d "$base/systemic-issue-triage" ]; then echo "systemic-issue-triage should be excluded"; return 1; fi
    local count
    count=$(find "$base" -name "SKILL.md" | wc -l | tr -d ' ')
    # Same reason as --without optional above: 26 - 4 and 28 - 6 are both 22, so the
    # literal would survive the change untouched.
    assert_eq "$(( ${#EXPECTED_SKILLS[@]} - 6 ))" "$count" \
        "Expected the default set minus judgment-day and the optional group's five skills"
}

test_reject_without_required_group() {
    if bash "$INSTALL_SCRIPT" --agent claude-code --without sdd-core > /dev/null 2>&1; then
        echo "Expected non-zero exit for --without sdd-core, but got 0"
        return 1
    fi
    return 0
}

# ============================================================================
# Tests — TDD module group (default-on; opt out with --without tdd)
# ============================================================================

test_default_install_includes_tdd() {
    # The tdd group is now default-on: a plain install ships skills/tdd as part of
    # the 28-skill default set. Installing the module does NOT activate TDD —
    # activation stays opt-in per project.
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    local base="$HOME/.claude/skills"
    assert_dir_exists "$base/tdd" || return 1
    assert_file_exists "$base/tdd/SKILL.md" || return 1
    assert_file_not_empty "$base/tdd/SKILL.md" || return 1
    local count
    count=$(find "$base" -name "SKILL.md" | wc -l | tr -d ' ')
    assert_eq "28" "$count" "Default install must include tdd (28 skills)"
}

test_without_tdd_excludes_tdd() {
    # --without tdd opts the module out: skills/tdd is dropped, landing the
    # remaining 27 default skills. The other default-on groups stay on.
    bash "$INSTALL_SCRIPT" --agent claude-code --without tdd > /dev/null 2>&1
    local base="$HOME/.claude/skills"
    if [ -d "$base/tdd" ]; then
        echo "tdd should be excluded by --without tdd"
        return 1
    fi
    assert_dir_exists "$base/judgment-day" || return 1   # quality group still on
    assert_dir_exists "$base/kanban-github" || return 1  # optional group still on
    assert_dir_exists "$base/sdd-apply" || return 1       # sdd-core always on
    local count
    count=$(find "$base" -name "SKILL.md" | wc -l | tr -d ' ')
    assert_eq "27" "$count" "Expected 27 skills with --without tdd"
}

test_lang_group_is_opt_in() {
    # Kurama ships no language knowledge by default: the `lang` group (go-testing)
    # must be absent from a default install and present only with --with lang.
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    local base="$HOME/.claude/skills"
    if [ -d "$base/go-testing" ]; then
        echo "go-testing must NOT install by default (lang group is opt-in)"
        return 1
    fi
    bash "$INSTALL_SCRIPT" --agent claude-code --with lang > /dev/null 2>&1
    assert_dir_exists "$base/go-testing" || return 1
    assert_file_not_empty "$base/go-testing/SKILL.md" || return 1
    # sdd-core is untouched by the opt-in.
    assert_dir_exists "$base/sdd-apply" || return 1
    local count
    count=$(find "$base" -name "SKILL.md" | wc -l | tr -d ' ')
    assert_eq "29" "$count" "Expected 29 skills with --with lang (28 default + go-testing)"
}

test_with_tdd_includes_tdd() {
    # tdd is default-on, so --with tdd is idempotent: skills/tdd ships and the
    # count stays at the 28-skill default set.
    bash "$INSTALL_SCRIPT" --agent claude-code --with tdd > /dev/null 2>&1
    local base="$HOME/.claude/skills"
    assert_dir_exists "$base/tdd" || return 1
    assert_file_exists "$base/tdd/SKILL.md" || return 1
    assert_file_not_empty "$base/tdd/SKILL.md" || return 1
    # Default-on groups still present.
    assert_dir_exists "$base/judgment-day" || return 1
    assert_dir_exists "$base/kanban-github" || return 1
    assert_dir_exists "$base/sdd-apply" || return 1
    local count
    count=$(find "$base" -name "SKILL.md" | wc -l | tr -d ' ')
    assert_eq "28" "$count" "Expected 28 skills with --with tdd (default set already includes tdd)"
}

test_with_tdd_uninstall_round_trip() {
    # Installing the tdd module and uninstalling leaves the target clean:
    # skills/tdd and the install manifest are gone, user-created skills survive.
    bash "$INSTALL_SCRIPT" --agent claude-code --with tdd > /dev/null 2>&1
    assert_dir_exists "$HOME/.claude/skills/tdd" || return 1
    mkdir -p "$HOME/.claude/skills/my-custom"
    echo "keep me" > "$HOME/.claude/skills/my-custom/SKILL.md"

    bash "$UNINSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1

    if [ -d "$HOME/.claude/skills/tdd" ]; then
        echo "tdd should have been removed by uninstall"
        return 1
    fi
    if [ -f "$HOME/.claude/skills/.kurama-install-manifest.json" ]; then
        echo "install manifest should have been removed by uninstall"
        return 1
    fi
    assert_file_exists "$HOME/.claude/skills/my-custom/SKILL.md" || return 1
    local content
    content=$(cat "$HOME/.claude/skills/my-custom/SKILL.md")
    assert_eq "keep me" "$content" "User-created skill preserved through tdd uninstall"
}

# ============================================================================
# Tests — Pi agent (P5 installer wiring)
# Pi's global context/skills live under its agent config dir (~/.pi/agent). The
# installers write skills to ~/.pi/agent/skills and merge the orchestrator rule
# into ~/.pi/agent/AGENTS.md (Pi's global context file, loaded natively).
# ============================================================================

test_install_omp() {
    bash "$INSTALL_SCRIPT" --agent omp > /dev/null 2>&1
    assert_all_skills_installed "$HOME/.omp/agent/skills"
}

test_omp_skill_count() {
    bash "$INSTALL_SCRIPT" --agent omp > /dev/null 2>&1
    local count
    count=$(find "$HOME/.omp/agent/skills" -name "SKILL.md" | wc -l | tr -d ' ')
    assert_eq "28" "$count" "Expected exactly 28 skills for omp"
}

test_omp_writes_install_manifest() {
    bash "$INSTALL_SCRIPT" --agent omp > /dev/null 2>&1
    local manifest="$HOME/.omp/agent/skills/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    grep -q '"files"' "$manifest" || { echo "omp install manifest missing files array"; return 1; }
    return 0
}

test_omp_honors_relocated_agent_base() {
    # omp resolves its user base from PI_CODING_AGENT_DIR when set. Kurama must
    # follow it, or a relocated install writes to a directory omp never reads.
    local relocated="$TEST_TMPDIR/relocated-omp"
    PI_CODING_AGENT_DIR="$relocated" bash "$INSTALL_SCRIPT" --agent omp > /dev/null 2>&1
    assert_dir_exists "$relocated/skills" || return 1
    assert_file_exists "$relocated/skills/sdd-apply/SKILL.md" || return 1
    # The default location must stay untouched when the variable redirects it.
    if [ -d "$HOME/.omp/agent/skills" ]; then
        echo "PI_CODING_AGENT_DIR was set but the default ~/.omp/agent/skills was written anyway"
        return 1
    fi
    return 0
}

test_setup_omp_writes_orchestrator() {
    bash "$SETUP_SCRIPT" --agent omp > /dev/null 2>&1
    assert_all_skills_installed "$HOME/.omp/agent/skills" || return 1
    local prompt="$HOME/.omp/agent/AGENTS.md"
    assert_file_exists "$prompt" || return 1
    grep -qF 'BEGIN:kurama' "$prompt" || { echo "omp orchestrator missing BEGIN:kurama marker"; return 1; }
    grep -qF 'END:kurama' "$prompt" || { echo "omp orchestrator missing END:kurama marker"; return 1; }
    return 0
}

test_omp_installs_native_agents() {
    # omp DELIBERATELY skips cross-harness agent roots (.claude/agents, .codex/agents,
    # …) because their frontmatter is not the omp task-agent contract. So omp needs its
    # own set under .omp/agents or the phases silently degrade to inline execution.
    bash "$SETUP_SCRIPT" --agent omp > /dev/null 2>&1
    local agents_dir="$HOME/.omp/agent/agents"
    assert_dir_exists "$agents_dir" || return 1
    local agent
    for agent in "${EXPECTED_AGENTS[@]}"; do
        assert_file_exists "$agents_dir/$agent.md" || return 1
        assert_file_not_empty "$agents_dir/$agent.md" || return 1
    done
    local count
    count=$(find "$agents_dir" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
    assert_eq "17" "$count" "setup.sh --agent omp should install exactly 17 omp agents" || return 1
    local manifest="$HOME/.omp/agent/skills/.kurama-install-manifest.json"
    grep -q '\.\./agents/review-risk.md' "$manifest" || {
        echo "omp receipt missing ../agents/review-risk.md"; return 1; }
    return 0
}

test_omp_agents_use_the_omp_contract() {
    # The frontmatter contract is what makes these agents visible to omp at all.
    # Pi fields (effort, memory_*) and Pi's `find` tool name would be silently
    # wrong: omp reads thinkingLevel and names the tool glob.
    local src="$REPO_DIR/examples/omp/agents"
    assert_dir_exists "$src" || return 1
    local f
    for f in "$src"/*.md; do
        grep -q '^name: ' "$f" || { echo "$f missing name (omp requires it)"; return 1; }
        grep -q '^description: ' "$f" || { echo "$f missing description (omp requires it)"; return 1; }
        grep -q '^spawns: ' "$f" || { echo "$f missing spawns — phases must never delegate"; return 1; }
        if grep -q '^effort:' "$f"; then
            echo "$f uses Pi's effort field; omp reads thinkingLevel"; return 1
        fi
        if grep -qE '^  - (find|memory_[a-z]+)$' "$f"; then
            echo "$f references a Pi-only tool (find/memory_*); omp has glob and no mem tools"; return 1
        fi
    done
    # The read-only review lenses must stay read-only: tools is exactly `read`.
    for f in review-risk review-readability review-reliability review-resilience review-refuter jd-judge-a jd-judge-b; do
        local tools
        tools=$(awk '/^tools:/{f=1;next} /^[a-z-]+:/{f=0} f&&/^  - /{printf "%s,",$2}' "$src/$f.md")
        assert_eq "read," "$tools" "$f must be read-only (tools: read)" || return 1
    done
    return 0
}

test_omp_installs_sticky_rules() {
    # RULES.md is omp's always-apply primitive, re-attached near the current turn.
    # Pi has no equivalent, so this asset is omp-only. It carries the invariants
    # that must not decay across a long conversation.
    bash "$SETUP_SCRIPT" --agent omp > /dev/null 2>&1
    local rules="$HOME/.omp/agent/RULES.md"
    assert_file_exists "$rules" || return 1
    assert_file_not_empty "$rules" || return 1
    grep -qi 'coordinator' "$rules" || { echo "RULES.md lost the delegate-only invariant"; return 1; }
    grep -qi 'human' "$rules" || { echo "RULES.md lost the human merge gate"; return 1; }
    # Recorded in the receipt so uninstall removes exactly it.
    local manifest="$HOME/.omp/agent/skills/.kurama-install-manifest.json"
    grep -q '\.\./RULES.md' "$manifest" || { echo "omp receipt missing ../RULES.md"; return 1; }
    return 0
}

test_omp_uninstall_round_trip() {
    # A full install/uninstall cycle leaves nothing of Kurama's behind, and does
    # not eat a pre-existing user AGENTS.md.
    bash "$SETUP_SCRIPT" --agent omp > /dev/null 2>&1
    assert_file_exists "$HOME/.omp/agent/RULES.md" || return 1
    assert_dir_exists "$HOME/.omp/agent/agents" || return 1
    bash "$UNINSTALL_SCRIPT" --agent omp > /dev/null 2>&1
    if [ -f "$HOME/.omp/agent/RULES.md" ]; then
        echo "uninstall left RULES.md behind"; return 1
    fi
    if [ -f "$HOME/.omp/agent/agents/sdd-apply.md" ]; then
        echo "uninstall left the omp agents behind"; return 1
    fi
    if [ -f "$HOME/.omp/agent/skills/sdd-apply/SKILL.md" ]; then
        echo "uninstall left the skills behind"; return 1
    fi
    # The orchestrator block is stripped surgically, so the file may survive empty.
    if [ -f "$HOME/.omp/agent/AGENTS.md" ] && grep -qF 'BEGIN:kurama' "$HOME/.omp/agent/AGENTS.md"; then
        echo "uninstall left the kurama orchestrator block in AGENTS.md"; return 1
    fi
    return 0
}

test_install_pi() {
    bash "$INSTALL_SCRIPT" --agent pi > /dev/null 2>&1
    assert_all_skills_installed "$HOME/.pi/agent/skills"
}

test_pi_skill_count() {
    bash "$INSTALL_SCRIPT" --agent pi > /dev/null 2>&1
    local count
    count=$(find "$HOME/.pi/agent/skills" -name "SKILL.md" | wc -l | tr -d ' ')
    assert_eq "28" "$count" "Expected exactly 28 skills for Pi"
}

test_pi_writes_install_manifest() {
    # install.sh --agent pi leaves the same receipt as every other target so
    # uninstall.sh works for Pi installs.
    bash "$INSTALL_SCRIPT" --agent pi > /dev/null 2>&1
    local manifest="$HOME/.pi/agent/skills/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    grep -q '"files"' "$manifest" || { echo "Pi install manifest missing files array"; return 1; }
    grep -q 'tdd/SKILL.md' "$manifest" || { echo "Pi install manifest missing tdd (default set)"; return 1; }
    return 0
}

test_setup_pi_writes_orchestrator() {
    # setup.sh --agent pi installs the default skill set into ~/.pi/agent/skills
    # and merges the orchestrator rule into the global Pi context file
    # (~/.pi/agent/AGENTS.md) using the standard kurama markers.
    bash "$SETUP_SCRIPT" --agent pi > /dev/null 2>&1
    assert_all_skills_installed "$HOME/.pi/agent/skills" || return 1
    local prompt="$HOME/.pi/agent/AGENTS.md"
    assert_file_exists "$prompt" || return 1
    grep -qF 'BEGIN:kurama' "$prompt" || { echo "Pi orchestrator missing BEGIN:kurama marker"; return 1; }
    grep -qF 'END:kurama' "$prompt" || { echo "Pi orchestrator missing END:kurama marker"; return 1; }
    grep -qF 'Kurama Orchestrator' "$prompt" || { echo "Pi orchestrator body missing"; return 1; }
    return 0
}

# ============================================================================
# Tests — N4: Claude Code native agents (setup.sh installs 17 agents +
# records them in the per-target receipt for receipt-driven removal)
# ============================================================================

# The 17 native agents setup.sh must install for claude-code: 9 SDD phase agents
# plus the 8 review/Judgment-Day agents added in Phase 10a.
EXPECTED_AGENTS=(
    sdd-apply sdd-archive sdd-design sdd-explore sdd-init
    sdd-propose sdd-spec sdd-tasks sdd-verify
    review-risk review-readability review-reliability review-resilience
    review-refuter jd-judge-a jd-judge-b jd-fix-agent
)

test_setup_installs_all_claude_agents() {
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    local agents_dir="$HOME/.claude/agents"
    assert_dir_exists "$agents_dir" || return 1
    local agent
    for agent in "${EXPECTED_AGENTS[@]}"; do
        assert_file_exists "$agents_dir/$agent.md" || return 1
        assert_file_not_empty "$agents_dir/$agent.md" || return 1
    done
    local count
    count=$(find "$agents_dir" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
    assert_eq "17" "$count" "setup.sh should install exactly 17 Claude Code agents"
}

test_setup_agents_recorded_in_receipt() {
    # Every installed agent is listed in the SAME per-target receipt (relative to
    # the skills dir as ../agents/NAME.md) so uninstall.sh removes them too.
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    grep -q '\.\./agents/review-risk.md' "$manifest" || {
        echo "receipt missing ../agents/review-risk.md"; return 1; }
    grep -q '\.\./agents/jd-fix-agent.md' "$manifest" || {
        echo "receipt missing ../agents/jd-fix-agent.md"; return 1; }
    grep -q '\.\./agents/sdd-apply.md' "$manifest" || {
        echo "receipt missing ../agents/sdd-apply.md"; return 1; }
    return 0
}

test_setup_agents_backs_up_preexisting() {
    # A pre-existing agent file with the same name must be backed up (.bak.*)
    # before it is overwritten — never silently clobbered.
    mkdir -p "$HOME/.claude/agents"
    local victim="$HOME/.claude/agents/review-risk.md"
    printf 'USER CUSTOM AGENT BODY\n' > "$victim"

    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1 || {
        echo "setup.sh failed while installing agents"; return 1; }

    local backups
    backups=$(find "$HOME/.claude/agents" -name 'review-risk.md.bak.*' | wc -l | tr -d ' ')
    if [ "$backups" -lt 1 ]; then
        echo "No timestamped backup was created for a pre-existing agent"
        return 1
    fi
    # The backup preserves the user's original content.
    local bak
    bak=$(find "$HOME/.claude/agents" -name 'review-risk.md.bak.*' | head -1)
    grep -qF 'USER CUSTOM AGENT BODY' "$bak" || {
        echo "Backup does not contain the original user content"; return 1; }
    return 0
}

test_pi_installs_native_agents() {
    # O4 wiring: Pi now ships its own native agents (Pi format, authored in
    # examples/pi/agents/). A global Pi install lands all 17 into
    # ~/.pi/agent/agents/ and records them in the receipt.
    bash "$SETUP_SCRIPT" --agent pi --without-pi-packages > /dev/null 2>&1
    local agents_dir="$HOME/.pi/agent/agents"
    assert_dir_exists "$agents_dir" || return 1
    local agent
    for agent in "${EXPECTED_AGENTS[@]}"; do
        assert_file_exists "$agents_dir/$agent.md" || return 1
        assert_file_not_empty "$agents_dir/$agent.md" || return 1
    done
    local count
    count=$(find "$agents_dir" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
    assert_eq "17" "$count" "setup.sh --agent pi should install exactly 17 Pi agents" || return 1
    # Pi agents are recorded in the receipt (../agents/NAME.md relative to skills).
    local manifest="$HOME/.pi/agent/skills/.kurama-install-manifest.json"
    grep -q '\.\./agents/review-risk.md' "$manifest" || {
        echo "Pi receipt missing ../agents/review-risk.md"; return 1; }
    return 0
}

test_non_target_agents_have_no_native_agents() {
    # Targets other than claude-code, pi and omp ship NO native agents.
    bash "$SETUP_SCRIPT" --agent codex > /dev/null 2>&1
    if [ -d "$HOME/.codex/agents" ]; then
        echo "codex unexpectedly grew a native agents directory"
        return 1
    fi
    return 0
}

# ============================================================================
# Tests — N5: Pi package stack (opt-in, consent-gated). These use FAKE pi/npm
# shims on a temp PATH that only log their argv — no real package manager, no
# network is ever invoked.
# ============================================================================

# Create fake pi + npm executables in $1 that append their invocation to $2.
make_pi_shims() {
    local bindir="$1" logfile="$2"
    mkdir -p "$bindir"
    cat > "$bindir/pi" <<SHIM
#!/usr/bin/env bash
printf 'pi %s\n' "\$*" >> "$logfile"
exit 0
SHIM
    cat > "$bindir/npm" <<SHIM
#!/usr/bin/env bash
printf 'npm %s\n' "\$*" >> "$logfile"
exit 0
SHIM
    chmod +x "$bindir/pi" "$bindir/npm"
}

test_pi_packages_exact_sequence() {
    # With --with-pi-packages and pi on PATH, setup.sh must invoke the approved
    # package stack in the EXACT approved order, with the pinned versions.
    local bindir="$TEST_TMPDIR/shimbin" log="$TEST_TMPDIR/pi-calls.log"
    make_pi_shims "$bindir" "$log"

    PATH="$bindir:$PATH" bash "$SETUP_SCRIPT" --agent pi --with-pi-packages > /dev/null 2>&1 || {
        echo "setup.sh --agent pi --with-pi-packages exited non-zero"; return 1; }

    assert_file_exists "$log" || { echo "no pi/npm calls were logged"; return 1; }

    # gentle-pi (rival harness) must NEVER be installed.
    if grep -q 'gentle-pi' "$log"; then
        echo "gentle-pi appeared in the install sequence — it must be excluded"
        return 1
    fi

    local expected actual
    expected="pi install npm:gentle-engram@0.1.10
pi install npm:pi-mcp-adapter@2.11.0
npm exec --yes --package gentle-engram@0.1.10 -- pi-engram init
pi install npm:pi-subagents-j0k3r@1.4.1
pi install npm:@juicesharp/rpiv-ask-user-question@2.0.0
pi install npm:pi-web-access@0.13.0
pi install npm:@juicesharp/rpiv-todo@2.0.0
pi install npm:pi-btw@0.4.1"
    actual="$(cat "$log")"
    assert_eq "$expected" "$actual" "Pi package install sequence must match the approved order + pins"
}

test_pi_packages_without_flag_skips() {
    # --without-pi-packages must skip the stack entirely: pi/npm are never called.
    local bindir="$TEST_TMPDIR/shimbin" log="$TEST_TMPDIR/pi-calls.log"
    make_pi_shims "$bindir" "$log"

    PATH="$bindir:$PATH" bash "$SETUP_SCRIPT" --agent pi --without-pi-packages > /dev/null 2>&1 || {
        echo "setup.sh --agent pi --without-pi-packages exited non-zero"; return 1; }

    if [ -f "$log" ]; then
        echo "pi/npm were invoked despite --without-pi-packages"
        return 1
    fi
    # The Pi skill install itself must still have happened.
    assert_all_skills_installed "$HOME/.pi/agent/skills" || return 1
    return 0
}

test_pi_packages_failure_is_non_fatal() {
    # A failing `pi install` must warn and CONTINUE — never abort setup — and the
    # remaining packages in the sequence must still be attempted.
    local bindir="$TEST_TMPDIR/shimbin" log="$TEST_TMPDIR/pi-calls.log"
    mkdir -p "$bindir"
    # pi fails ONLY for pi-mcp-adapter (2nd step); everything else succeeds.
    cat > "$bindir/pi" <<SHIM
#!/usr/bin/env bash
printf 'pi %s\n' "\$*" >> "$log"
case "\$*" in
    *pi-mcp-adapter*) exit 7 ;;
esac
exit 0
SHIM
    cat > "$bindir/npm" <<SHIM
#!/usr/bin/env bash
printf 'npm %s\n' "\$*" >> "$log"
exit 0
SHIM
    chmod +x "$bindir/pi" "$bindir/npm"

    if ! PATH="$bindir:$PATH" bash "$SETUP_SCRIPT" --agent pi --with-pi-packages > /dev/null 2>&1; then
        echo "a single failed pi install aborted the whole setup (must be non-fatal)"
        return 1
    fi

    # All 8 steps must still have been attempted despite the 2nd one failing.
    local lines
    lines=$(wc -l < "$log" | tr -d ' ')
    assert_eq "8" "$lines" "all 8 package steps must be attempted even when one fails" || return 1
    grep -q 'pi-btw@' "$log" || { echo "later packages were skipped after a failure"; return 1; }
    return 0
}

test_pi_packages_skipped_when_pi_absent() {
    # When pi is NOT on PATH, the stack is skipped cleanly (no crash), even with
    # --with-pi-packages. Build a restricted PATH (symlink farm) that deliberately
    # omits pi so the absence is deterministic regardless of the host.
    local bindir="$TEST_TMPDIR/nopi-bin"
    mkdir -p "$bindir"
    local tool p
    for tool in bash sh env uname grep egrep dirname basename mkdir cp mv cat date chmod rm ls awk sed tr wc find mktemp sort head printf test jq; do
        p="$(command -v "$tool" 2>/dev/null)" || continue
        ln -sf "$p" "$bindir/$tool"
    done
    # Deliberately DO NOT link pi (or npm) into the farm.

    local output
    if ! output=$(PATH="$bindir" bash "$SETUP_SCRIPT" --agent pi --with-pi-packages 2>&1); then
        echo "setup.sh crashed when pi was absent (must skip gracefully)"
        return 1
    fi
    echo "$output" | grep -qi 'pi not found' || {
        echo "expected a 'pi not found' skip message when pi is absent"; return 1; }
    # Skills must still be installed even though the package stack was skipped.
    assert_all_skills_installed "$HOME/.pi/agent/skills" || return 1
    return 0
}

# ============================================================================
# Tests — Review lens group (4R + refuter, default-on)
# ============================================================================

REVIEW_LENSES=(review-risk review-readability review-reliability review-resilience review-refuter)

test_review_lenses_installed_by_default() {
    # The review group is default-on: a plain install ships all five 4R + refuter
    # lenses alongside the rest of the default set.
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    local base="$HOME/.claude/skills"
    local lens
    for lens in "${REVIEW_LENSES[@]}"; do
        assert_dir_exists "$base/$lens" || return 1
        assert_file_exists "$base/$lens/SKILL.md" || return 1
        assert_file_not_empty "$base/$lens/SKILL.md" || return 1
    done
    return 0
}

test_without_review_excludes_lenses() {
    # The review group opts out like quality/optional: --without review drops all
    # five lenses and lands the remaining 23 default skills.
    bash "$INSTALL_SCRIPT" --agent claude-code --without review > /dev/null 2>&1
    local base="$HOME/.claude/skills"
    local lens
    for lens in "${REVIEW_LENSES[@]}"; do
        if [ -d "$base/$lens" ]; then
            echo "$lens should be excluded by --without review"
            return 1
        fi
    done
    assert_dir_exists "$base/judgment-day" || return 1   # quality group still on
    assert_dir_exists "$base/sdd-apply" || return 1       # sdd-core always on
    local count
    count=$(find "$base" -name "SKILL.md" | wc -l | tr -d ' ')
    assert_eq "23" "$count" "Expected 23 skills with --without review (28 default - 5 lenses)"
}

# ============================================================================
# Tests — Kanban module (Phase 9; optional group, default-on; install ≠ activate)
# The module is pure Markdown protocol — these tests ONLY verify files and counts.
# No live `gh` or network calls are made (activation requires a configured gh and
# only happens during a real SDD cycle, never here).
# ============================================================================

test_kanban_installed_by_default() {
    # The kanban-github module ships in the default set (manifest `optional` group).
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    local base="$HOME/.claude/skills"
    assert_dir_exists "$base/kanban-github" || return 1
    assert_file_exists "$base/kanban-github/SKILL.md" || return 1
    assert_file_not_empty "$base/kanban-github/SKILL.md" || return 1
    return 0
}

test_kanban_listed_in_manifest_optional_group() {
    # Structural check only — kanban-github is declared once in the manifest's optional
    # group. No install, no gh.
    grep -q '"kanban-github"' "$MANIFEST_FILE" || { echo "manifest missing kanban-github skill"; return 1; }
    if command -v jq > /dev/null 2>&1; then
        local group
        group=$(jq -r '.skills[] | select(.name == "kanban-github") | .group' "$MANIFEST_FILE")
        assert_eq "optional" "$group" "kanban-github must be in the optional manifest group" || return 1
    fi
    return 0
}

test_without_optional_excludes_kanban() {
    # --without optional drops the whole optional group, kanban-github included.
    bash "$INSTALL_SCRIPT" --agent claude-code --without optional > /dev/null 2>&1
    if [ -d "$HOME/.claude/skills/kanban-github" ]; then
        echo "kanban-github should be excluded by --without optional"
        return 1
    fi
    return 0
}

# ============================================================================
# Tests — Phase 6 surface (sdd-status.sh + generated Pi harness)
# ============================================================================

test_sdd_status_exists_and_executable() {
    local status_script="$SCRIPT_DIR/sdd-status.sh"
    assert_file_exists "$status_script" || return 1
    [ -x "$status_script" ] || { echo "sdd-status.sh is not executable"; return 1; }
    return 0
}

test_sdd_status_empty_dir_exit_zero() {
    local empty="$TEST_TMPDIR/empty-project"
    mkdir -p "$empty"
    local output
    if ! output=$(bash "$SCRIPT_DIR/sdd-status.sh" "$empty" 2>&1); then
        echo "sdd-status.sh should exit 0 on an empty project"
        return 1
    fi
    echo "$output" | grep -q "No active SDD cycles" || {
        echo "sdd-status.sh empty output should say 'No active SDD cycles'"
        return 1
    }
    return 0
}

test_sdd_status_json_parses_on_empty() {
    local empty="$TEST_TMPDIR/empty-json-project"
    mkdir -p "$empty"
    local output
    output=$(bash "$SCRIPT_DIR/sdd-status.sh" --json "$empty" 2>&1) || {
        echo "sdd-status.sh --json should exit 0 on an empty project"
        return 1
    }
    if command -v jq >/dev/null 2>&1; then
        echo "$output" | jq -e '.changes == []' >/dev/null 2>&1 || {
            echo "sdd-status.sh --json did not emit a valid empty changes array"
            return 1
        }
    elif command -v python3 >/dev/null 2>&1; then
        echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("changes")==[] else 1)' || {
            echo "sdd-status.sh --json did not emit valid JSON with an empty changes array"
            return 1
        }
    else
        echo "$output" | grep -q '"changes"' || {
            echo "sdd-status.sh --json missing changes key (no JSON parser to validate fully)"
            return 1
        }
    fi
    return 0
}

test_sdd_status_conforming_engram_cycle_is_not_degraded() {
    # A post-#30 engram cycle writes the mandated cycle marker and NOTHING else
    # to disk. Labelling it "engram (fallback)" called a fully conforming cycle
    # degraded, and probing artifact files alone printed "Last phase: none /
    # Next phase: explore" two lines above "Recorded phase: tasks".
    local proj="$TEST_TMPDIR/engram-project"
    mkdir -p "$proj/.kurama/sdd/my-change"
    cat > "$proj/.kurama/sdd/my-change/state.md" <<'EOF'
change: my-change
phase: tasks
artifact_store.mode: engram
last_updated: 2026-08-15
EOF
    local output
    output=$(bash "$SCRIPT_DIR/sdd-status.sh" "$proj" 2>&1) || {
        echo "sdd-status.sh failed on an engram cycle"; return 1; }

    if printf '%s\n' "$output" | grep -qi 'fallback'; then
        echo "a conforming engram cycle is still labelled a fallback"; return 1
    fi
    printf '%s\n' "$output" | grep -qE '^  Store: +engram$' || {
        echo "the store label is not the recorded mode:"; printf '%s\n' "$output"; return 1; }
    printf '%s\n' "$output" | grep -qE '^  Last phase: +tasks$' || {
        echo "the recorded phase did not win over the artifact probes"; return 1; }
    printf '%s\n' "$output" | grep -qE '^  Next phase: +apply' || {
        echo "next phase does not follow the recorded phase"; return 1; }

    local json
    json=$(bash "$SCRIPT_DIR/sdd-status.sh" "$proj" --json 2>&1) || {
        echo "sdd-status.sh --json failed"; return 1; }
    if command -v jq > /dev/null 2>&1; then
        assert_eq "engram" "$(printf '%s' "$json" | jq -r '.changes[0].store')" \
            "JSON store is not a legal artifact-store mode" || return 1
        assert_eq "tasks" "$(printf '%s' "$json" | jq -r '.changes[0].last_phase')" \
            "JSON last_phase contradicts recorded_phase" || return 1
    fi
    return 0
}

test_sdd_status_marker_only_openspec_cycle_is_not_hybrid() {
    # The .kurama/ markers are written in EVERY mode, so their presence is not
    # evidence of a second store — upgrading on it made "openspec" unreachable.
    local proj="$TEST_TMPDIR/openspec-project"
    mkdir -p "$proj/openspec/changes/my-change" "$proj/.kurama/sdd/my-change"
    printf 'schema: spec-driven\n' > "$proj/openspec/config.yaml"
    printf '# proposal\n' > "$proj/openspec/changes/my-change/proposal.md"
    printf 'change: my-change\nphase: propose\n' > "$proj/.kurama/sdd/my-change/state.md"

    local output
    output=$(bash "$SCRIPT_DIR/sdd-status.sh" "$proj" 2>&1) || {
        echo "sdd-status.sh failed on an openspec cycle"; return 1; }
    printf '%s\n' "$output" | grep -qE '^  Store: +openspec$' || {
        echo "a marker-only openspec cycle is not labelled openspec:"; printf '%s\n' "$output"; return 1; }
    return 0
}

test_sdd_status_unprovable_store_is_labelled_unknown() {
    # No recorded mode anywhere: say so instead of guessing engram.
    local proj="$TEST_TMPDIR/unknown-store-project"
    mkdir -p "$proj/.kurama/sdd/my-change"
    printf 'change: my-change\nphase: explore\n' > "$proj/.kurama/sdd/my-change/state.md"

    local output
    output=$(bash "$SCRIPT_DIR/sdd-status.sh" "$proj" 2>&1) || {
        echo "sdd-status.sh failed"; return 1; }
    printf '%s\n' "$output" | grep -qE '^  Store: +unknown +\(cycle markers only\)$' || {
        echo "an unprovable store is not labelled honestly:"; printf '%s\n' "$output"; return 1; }
    if command -v jq > /dev/null 2>&1; then
        local json
        json=$(bash "$SCRIPT_DIR/sdd-status.sh" "$proj" --json 2>&1)
        printf '%s' "$json" | jq -e '.changes[0].store == null' > /dev/null 2>&1 || {
            echo "JSON store must be null, never a prose label"; return 1; }
    fi
    return 0
}

test_pi_example_generated() {
    # G9: Pi is the 8th generated harness; its orchestrator lands at examples/pi/AGENTS.md.
    assert_file_exists "$REPO_DIR/examples/pi/AGENTS.md" || return 1
    assert_file_not_empty "$REPO_DIR/examples/pi/AGENTS.md" 500 || return 1
    return 0
}

# ============================================================================
# Tests — Uninstall round-trip (E10)
# ============================================================================

test_uninstall_round_trip() {
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    # A user-created skill must survive uninstall.
    mkdir -p "$HOME/.claude/skills/my-custom"
    echo "keep me" > "$HOME/.claude/skills/my-custom/SKILL.md"

    bash "$UNINSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1

    if [ -d "$HOME/.claude/skills/sdd-apply" ]; then
        echo "sdd-apply should have been removed by uninstall"
        return 1
    fi
    if [ -f "$HOME/.claude/skills/.kurama-install-manifest.json" ]; then
        echo "install manifest should have been removed by uninstall"
        return 1
    fi
    assert_file_exists "$HOME/.claude/skills/my-custom/SKILL.md" || return 1
    local content
    content=$(cat "$HOME/.claude/skills/my-custom/SKILL.md")
    assert_eq "keep me" "$content" "User-created skill preserved through uninstall"
}

test_uninstall_dry_run_preserves_files() {
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    bash "$UNINSTALL_SCRIPT" --agent claude-code --dry-run > /dev/null 2>&1
    # Nothing should be deleted on a dry run.
    assert_all_skills_installed "$HOME/.claude/skills" || return 1
    assert_file_exists "$HOME/.claude/skills/.kurama-install-manifest.json" || return 1
    return 0
}

test_uninstall_custom_path() {
    # #38: --agent custom maps to a setup.sh project install; its receipt lives at the
    # repo root and uninstall takes the project selectors.
    local custom="$TEST_TMPDIR/custom-skills"
    make_git_repo "$custom"
    bash "$INSTALL_SCRIPT" --agent custom --path "$custom" > /dev/null 2>&1
    assert_file_exists "$custom/.kurama-install-manifest.json" || return 1
    bash "$UNINSTALL_SCRIPT" --scope project --path "$custom" --without-pi-packages > /dev/null 2>&1
    if [ -d "$custom/.claude/skills/sdd-apply" ]; then
        echo "sdd-apply should have been removed from the custom project path"
        return 1
    fi
    return 0
}

# ============================================================================
# Tests — Meta-skill registration (M3): sdd-new / sdd-continue / sdd-ff
# ============================================================================

test_meta_skills_installed_by_default() {
    # The three orchestrator meta-skills live in the sdd-core group, so a plain
    # install must ship them (they are the /sdd-new, /sdd-continue, /sdd-ff
    # entry points).
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    local base="$HOME/.claude/skills"
    for meta in sdd-new sdd-continue sdd-ff; do
        assert_dir_exists "$base/$meta" || return 1
        assert_file_exists "$base/$meta/SKILL.md" || return 1
        assert_file_not_empty "$base/$meta/SKILL.md" || return 1
    done
    return 0
}

# ============================================================================
# Tests — Packaging manifests (M5): plugin.json / marketplace.json /
# parse as JSON and plugin.json version == VERSION
# ============================================================================

# Parse a JSON file: jq preferred, python3 fallback, soft-pass if neither exists.
json_file_parses() {
    local f="$1"
    if command -v jq > /dev/null 2>&1; then
        jq -e . "$f" > /dev/null 2>&1
    elif command -v python3 > /dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" > /dev/null 2>&1
    else
        return 0  # No JSON parser available — soft pass.
    fi
}

test_plugin_json_valid() {
    local f="$REPO_DIR/.claude-plugin/plugin.json"
    assert_file_exists "$f" || return 1
    json_file_parses "$f" || { echo "plugin.json is not valid JSON"; return 1; }
    return 0
}

test_marketplace_json_valid() {
    local f="$REPO_DIR/.claude-plugin/marketplace.json"
    assert_file_exists "$f" || return 1
    json_file_parses "$f" || { echo "marketplace.json is not valid JSON"; return 1; }
    return 0
}

test_none_mode_fully_removed() {
    # S-mode-1. `none` meant "persist no SDD artifacts" in a workflow whose premise is that
    # specs are the source of truth: sdd-archive had nothing to merge, so the main specs
    # never advanced. Removing the enum value is not enough — every phase carried a `none`
    # branch, and a leftover branch is what makes a removed mode quietly still reachable.
    # Two files are exempt because naming the mode is their job: docs/changelog.md is a
    # historical record and must keep describing it as it existed, and docs/migration.md
    # exists precisely to tell a project still on `none` what to do.
    local hits
    # shellcheck disable=SC2016  # literal backticks are the point — this matches the mode as written in prose
    hits=$(grep -rn -- '`none`' "$REPO_DIR/skills" "$REPO_DIR/docs" 2>/dev/null \
        | grep -v 'docs/changelog.md' \
        | grep -v 'docs/migration.md' \
        | grep -v 'Removed mode' \
        | grep -v 'skill_resolution' || true)
    if [ -n "$hits" ]; then
        echo "the none artifact-store mode still appears:"
        echo "$hits" | head -5
        return 1
    fi
    # The enum itself must be the three surviving modes.
    grep -q 'engram | openspec | hybrid`' "$REPO_DIR/skills/_shared/persistence-contract.md" \
        || { echo "persistence-contract.md does not declare the three-mode enum"; return 1; }
    # And the removal must be explained where someone hitting an old config would look.
    grep -qi 'report it as unsupported' "$REPO_DIR/skills/_shared/persistence-contract.md" \
        || { echo "persistence-contract.md must say what to do when a config still says none"; return 1; }
    return 0
}

test_dropped_harnesses_rejected_by_name() {
    # The four dropped harnesses (gemini-cli, cursor, vscode, antigravity) were valid
    # --agent values, so stale scripts and CI jobs still pass them. setup.sh never
    # validated the slug: an unknown one fell through every path-resolution case and
    # produced an empty target plus a bare `mkdir: : No such file or directory`. The
    # failure must name the agent and the supported set instead.
    local a out status
    for a in gemini-cli cursor vscode antigravity bogus; do
        # The status is captured on the same line as the output: with errexit live
        # in the test body (#31), a bare `out=$(...)` on a command expected to fail
        # aborts the case before the assertion below ever runs — which is exactly
        # how this case sat unfailable, never once reading setup.sh's exit code.
        status=0
        out=$(bash "$SETUP_SCRIPT" --agent "$a" 2>&1) || status=$?
        if [ "$status" -eq 0 ]; then
            echo "--agent $a was accepted; it must fail"
            return 1
        fi
        case "$out" in
            *"Unknown agent: $a"*) ;;
            *) echo "--agent $a failed without naming the agent: $out"; return 1 ;;
        esac
        case "$out" in
            *"claude-code, opencode, codex, pi, omp"*) ;;
            *) echo "--agent $a did not name the supported set"; return 1 ;;
        esac
    done
    # And the supported five must still be accepted by the same validator. Only the
    # validator's verdict is under test here, so a non-zero exit from a later
    # install step is not this case's business — the status is captured (never
    # ignored with `|| true`) and the message is what gets asserted.
    for a in claude-code opencode codex pi omp; do
        status=0
        out=$(bash "$SETUP_SCRIPT" --agent "$a" --non-interactive 2>&1) || status=$?
        case "$out" in
            *"Unknown agent"*) echo "--agent $a was rejected; it is supported (exit $status)"; return 1 ;;
        esac
    done
    return 0
}

test_dropped_harness_artifacts_are_gone() {
    # Removing a harness from the installers is not enough: a leftover template keeps
    # build-examples.sh emitting its orchestrator, and a leftover manifest target keeps
    # install.sh writing skills where nothing reads them.
    local p
    for p in \
        "$REPO_DIR/examples/gemini-cli" "$REPO_DIR/examples/cursor" \
        "$REPO_DIR/examples/vscode" "$REPO_DIR/examples/antigravity" \
        "$REPO_DIR/examples/_templates/gemini-cli.md" "$REPO_DIR/examples/_templates/cursor.md" \
        "$REPO_DIR/examples/_templates/vscode.md" "$REPO_DIR/examples/_templates/antigravity.md" \
        "$REPO_DIR/gemini-extension.json"; do
        if [ -e "$p" ]; then
            echo "dropped-harness artifact still present: $p"
            return 1
        fi
    done
    if command -v jq > /dev/null 2>&1; then
        local targets
        targets=$(jq -r '.targets | keys | join(" ")' "$REPO_DIR/skills/manifest.json")
        case "$targets" in
            *gemini*|*cursor*|*vscode*|*antigravity*)
                echo "manifest.json still declares a dropped target: $targets"; return 1 ;;
        esac
    fi
    return 0
}

test_kurama_state_survives_mode_removal() {
    # S-mode-3. `.kurama/` is harness infrastructure, not an SDD artifact — the persistence
    # modes never gated it, and removing a mode must not accidentally make it conditional.
    local f="$REPO_DIR/skills/_shared/persistence-contract.md"
    assert_file_exists "$f" || return 1
    grep -q '.kurama/sdd/' "$f" \
        || { echo "the .kurama/sdd/ fallback disappeared from the persistence contract"; return 1; }
    grep -qi 'written in every mode' "$REPO_DIR/skills/sdd-init/SKILL.md" \
        || { echo "sdd-init must still write the registry in every mode"; return 1; }
    return 0
}

test_orchestrator_prompt_delegates_heavy_blocks() {
    # The orchestrator prompt is reprocessed on EVERY turn of EVERY session, so its size is
    # the dominant token cost in the whole system (docs/token-economics.md, insight 4).
    # Four procedures that only matter conditionally were moved into _shared reference files
    # the orchestrator loads on demand. This test protects both halves of that contract:
    # every extracted block still has exactly one canonical home, and the prompt still
    # carries the trigger that sends the orchestrator there.
    local shared="$REPO_DIR/skills/_shared"
    assert_file_exists "$shared/orchestrator-sdd-protocol.md" || return 1
    assert_file_not_empty "$shared/orchestrator-sdd-protocol.md" || return 1

    # Each extracted procedure lives in its owning shared file.
    grep -q "SDD Session Preflight" "$shared/orchestrator-sdd-protocol.md" || {
        echo "preflight procedure missing from orchestrator-sdd-protocol.md"; return 1; }
    grep -q "Automatic Mode Gatekeeper" "$shared/orchestrator-sdd-protocol.md" || {
        echo "auto gatekeeper missing from orchestrator-sdd-protocol.md"; return 1; }
    grep -q "SDD Entry Routing" "$shared/orchestrator-sdd-protocol.md" || {
        echo "entry routing missing from orchestrator-sdd-protocol.md"; return 1; }
    grep -q "Lens selection triage" "$shared/review-ledger-contract.md" || {
        echo "lens triage missing from review-ledger-contract.md"; return 1; }
    grep -q "Phase I/O" "$shared/sdd-phase-common.md" || {
        echo "phase I/O table missing from sdd-phase-common.md"; return 1; }

    # Every generated orchestrator prompt still points at those homes, and stays lean.
    local f flat bytes
    for f in "$REPO_DIR/examples/claude-code/CLAUDE.md" \
             "$REPO_DIR/examples/pi/AGENTS.md" \
             "$REPO_DIR/examples/codex/agents.md" \
             "$REPO_DIR/examples/opencode/AGENTS.md" \
             "$REPO_DIR/examples/omp/AGENTS.md"; do
        assert_file_exists "$f" || return 1
        flat=$(tr '\n' ' ' < "$f")
        case "$flat" in
            *"orchestrator-sdd-protocol.md"*) ;;
            *) echo "$f lost the pointer to orchestrator-sdd-protocol.md"; return 1 ;;
        esac
        case "$flat" in
            *"review-ledger-contract.md"*) ;;
            *) echo "$f lost the pointer to review-ledger-contract.md"; return 1 ;;
        esac
        # A regression budget, not a golden size: the pre-diet prompts were ~28.5KB.
        bytes=$(wc -c < "$f" | tr -d ' ')
        if [ "$bytes" -gt 24000 ]; then
            echo "$f is ${bytes}B — orchestrator prompt regressed past its 24KB budget"
            return 1
        fi
    done
}

test_phase_skill_loading_reads_paths_by_default() {
    # #79.1. `skill-resolver.md` is the canonical resolution protocol: the delegator passes
    # exact SKILL.md PATHS by default and compact rules are an opt-in low-token trade, because
    # a digest is lossy by construction and goes stale silently. `sdd-phase-common.md` is the
    # file EVERY phase agent reads at startup, and it used to order the opposite on BOTH of its
    # surfaces — "Do NOT read any SKILL.md files" on the injected path, and "apply the
    # registry's Compact Rules" on the registry fallback. A sub-agent obeys the file it is told
    # to load, not the protocol it never sees, so the startup file wins in practice and the
    # canonical default is dead letter. Both surfaces are pinned here, against the canonical
    # file in the same test so a future flip of the default fails loudly instead of drifting.
    local common="$REPO_DIR/skills/_shared/sdd-phase-common.md"
    local resolver="$REPO_DIR/skills/_shared/skill-resolver.md"
    assert_file_exists "$common" || return 1
    assert_file_exists "$resolver" || return 1

    # The canonical rule this test measures against. If it ever flips, this test is stale and
    # must be re-pointed — never deleted, or the contradiction returns unobserved.
    grep -qi 'opt-in' "$resolver" \
        || { echo "skill-resolver.md no longer calls compact rules opt-in — this test is stale"; return 1; }

    # Surface 1 — the injected path. The contradictory order must be gone...
    if grep -qF 'Do NOT read any SKILL.md files' "$common"; then
        echo "sdd-phase-common.md still forbids reading SKILL.md on the injected path"; return 1
    fi
    # ...and the DEFAULT block shape must be named, with the instruction to read it in full.
    grep -qF 'Project Standards (skills to load)' "$common" \
        || { echo "sdd-phase-common.md never names the default 'skills to load' block"; return 1; }
    grep -qiF 'read each listed file in full' "$common" \
        || { echo "sdd-phase-common.md does not tell the phase agent to read the listed SKILL.md files"; return 1; }
    # The opt-in shape stays documented — removing it would strand the low-token mode the
    # delegator is still allowed to choose.
    grep -qF 'Project Standards (auto-resolved)' "$common" \
        || { echo "sdd-phase-common.md dropped the opt-in auto-resolved block"; return 1; }

    # Surface 2 — the registry fallback. It must route through the index, not Compact Rules.
    if grep -qF 'Compact Rules** section, apply rules' "$common"; then
        echo "sdd-phase-common.md fallback still applies compact rules instead of reading paths"; return 1
    fi
    grep -qF '**skills index**' "$common" \
        || { echo "sdd-phase-common.md fallback never routes through the registry's skills index"; return 1; }

    # #41 invariant, untouched by the above: `.kurama/` is hidden AND gitignored, so existence
    # is `test -f` or Read — a finder reports "missing" for a file that is right there.
    grep -qF 'test -f' "$common" \
        || { echo "sdd-phase-common.md lost the fail-loud check for .kurama/skill-registry.md"; return 1; }
    grep -qi 'never with a finder' "$common" \
        || { echo "sdd-phase-common.md no longer bans finders as an existence check"; return 1; }
    return 0
}

test_preflight_resolves_no_dangling_delivery_value() {
    # #79.2. The preflight used to resolve a fourth value, `delivery`, declare that it fed the
    # Review Workload Guard, and forward it in every phase prompt — while no phase read it and
    # the guard it named measures the real diff with git at PR time instead. A contract the
    # repo declares and nothing consumes is a false promise, so the promise was removed rather
    # than wired. This pins BOTH halves: the value is gone from the whole skills tree, and the
    # preflight's arity is consistently three everywhere it is counted.
    local osp="$REPO_DIR/skills/_shared/orchestrator-sdd-protocol.md"
    assert_file_exists "$osp" || return 1

    # No skill resolves, forwards, or names the dangling strategy anywhere.
    local leftovers
    leftovers=$(grep -rl 'delivery_strategy\|ask-on-risk' "$REPO_DIR/skills" 2>/dev/null || true)
    if [ -n "$leftovers" ]; then
        echo "a delivery strategy value nothing reads is back in: $leftovers"; return 1
    fi

    # Arity: three, with no counting artifact of the removed fourth left behind.
    if grep -qi 'four values\|all four\|four groups' "$osp"; then
        echo "orchestrator-sdd-protocol.md still counts the preflight as four values"; return 1
    fi
    grep -qi 'three values' "$osp" \
        || { echo "orchestrator-sdd-protocol.md never states the preflight's three values"; return 1; }

    # The reason it is three, recorded where the next reader would otherwise re-add it.
    grep -qi 'delivery is not a preflight value' "$osp" \
        || { echo "orchestrator-sdd-protocol.md does not say why delivery is not a preflight value"; return 1; }

    # The guard that DOES decide partitioning is a git measurement and stays untouched.
    local bpr="$REPO_DIR/skills/branch-pr/SKILL.md"
    assert_file_exists "$bpr" || return 1
    grep -qi 'Review Workload Guard' "$bpr" \
        || { echo "branch-pr lost the Review Workload Guard that replaces the preflight value"; return 1; }
    return 0
}

test_change_size_absent_means_standard() {
    # S-seq-2 / S-size-2. Every change created before the size field existed has no
    # `## Change Size` section. The contract must resolve that to `standard` — the long path
    # — in every place that sequences phases. Guessing `small` would silently strip two
    # planning phases from in-flight work; failing would block it outright.
    local f
    for f in "$REPO_DIR/skills/_shared/sdd-phase-common.md" \
             "$REPO_DIR/skills/sdd-ff/SKILL.md" \
             "$REPO_DIR/skills/sdd-new/SKILL.md" \
             "$REPO_DIR/skills/sdd-continue/SKILL.md" \
             "$REPO_DIR/skills/sdd-tasks/SKILL.md"; do
        assert_file_exists "$f" || return 1
        # Normalize newlines: these are prose contracts and the normative phrase must be
        # findable regardless of where the author wrapped the line.
        local flat
        flat=$(tr '\n' ' ' < "$f")
        case "$flat" in
            *"Change Size"*) ;;
            *) echo "$f does not resolve the change size before sequencing"; return 1 ;;
        esac
        case "$flat" in
            *"absent or unrecognized"*|*"default when the section is absent"*) ;;
            *) echo "$f does not state that an absent size means standard"; return 1 ;;
        esac
    done
    return 0
}

test_small_change_collapses_without_omitting() {
    # S-collapse-1..3. Skipping spec/design deadlocks: sdd-tasks requires both and
    # sdd-archive blocks without a delta spec because it has nothing to merge into the main
    # specs. The contract must therefore collapse them into the proposal, and must still
    # block when the inline spec is missing or empty.
    local propose="$REPO_DIR/skills/sdd-propose/SKILL.md"
    local tasks="$REPO_DIR/skills/sdd-tasks/SKILL.md"
    local archive="$REPO_DIR/skills/sdd-archive/SKILL.md"
    assert_file_exists "$propose" || return 1

    grep -q '## Spec (inline)' "$propose" \
        || { echo "sdd-propose has no inline spec template for small changes"; return 1; }
    grep -q '## Design (inline)' "$propose" \
        || { echo "sdd-propose has no inline design template for small changes"; return 1; }
    # All five criteria must be present, and ambiguity must resolve to standard.
    grep -qi 'ambiguity always resolves to .\?standard' "$propose" \
        || { echo "sdd-propose must resolve ambiguity to standard"; return 1; }

    grep -q '## Spec (inline)' "$tasks" \
        || { echo "sdd-tasks does not read the inline spec for small changes"; return 1; }
    grep -q '## Spec (inline)' "$archive" \
        || { echo "sdd-archive does not locate the inline delta spec"; return 1; }
    # The guard that protects the source of truth.
    grep -qi 'missing, empty, or carries no' "$archive" \
        || { echo "sdd-archive must block on a missing or empty inline spec"; return 1; }
    return 0
}

test_sdd_design_description_marks_spec_optional() {
    # S-design-1. sdd-design reads proposal (required) and spec (OPTIONAL) — the phase may
    # run in parallel with sdd-spec, so a spec is not guaranteed to exist. An agent
    # description that promises "proposal and specs" reads as a hard dependency and would
    # have a reader treat a missing spec as a blocker. Description and SKILL.md must agree.
    local skill="$REPO_DIR/skills/sdd-design/SKILL.md"
    assert_file_exists "$skill" || return 1
    grep -qi 'spec.*(optional' "$skill" \
        || { echo "sdd-design SKILL.md no longer marks spec optional — this test is stale"; return 1; }

    local f
    for f in "$REPO_DIR/examples/claude-code/agents/sdd-design.md" \
             "$REPO_DIR/examples/pi/agents/sdd-design.md"; do
        assert_file_exists "$f" || return 1
        local desc
        desc=$(grep -m1 '^description:' "$f") || { echo "no description in $f"; return 1; }
        # The contradictory phrasing: promises specs as an input with no optionality.
        case "$desc" in
            *"proposal and specs"*)
                echo "$(basename "$(dirname "$(dirname "$f")")")/agents/sdd-design.md still reads 'proposal and specs' — spec must be described as optional"
                return 1 ;;
        esac
        echo "$desc" | grep -qi 'optional' \
            || { echo "$f description must state the spec is optional context"; return 1; }
    done
    return 0
}

test_dependency_graph_matches_canonical_dag() {
    # The orchestrator prompt ships a drawing of the DAG. A drawing that implies design
    # depends on spec contradicts the canonical declaration in sdd-phase-common.md, and the
    # generated prompt is what the orchestrator actually reads.
    local canonical="$REPO_DIR/skills/_shared/sdd-phase-common.md"
    assert_file_exists "$canonical" || return 1
    grep -q 'may run in parallel\|MAY run in parallel' "$canonical" \
        || { echo "canonical DAG no longer declares the parallel branch — this test is stale"; return 1; }

    local f="$REPO_DIR/examples/claude-code/CLAUDE.md"
    assert_file_exists "$f" || return 1
    # The old drawing pointed design's arrow into specs.
    grep -q 'proposal -> specs' "$f" \
        && { echo "CLAUDE.md still ships the ambiguous 'proposal -> specs' graph"; return 1; }
    grep -qi 'optional' "$f" \
        || { echo "CLAUDE.md dependency graph must state the spec/design optionality"; return 1; }
    return 0
}

test_plugin_json_version_matches_version_file() {
    local f="$REPO_DIR/.claude-plugin/plugin.json"
    local version_file="$REPO_DIR/VERSION"
    assert_file_exists "$f" || return 1
    assert_file_exists "$version_file" || return 1

    local expected
    IFS= read -r expected < "$version_file"

    local actual
    if command -v jq > /dev/null 2>&1; then
        actual=$(jq -r '.version' "$f")
    elif command -v python3 > /dev/null 2>&1; then
        actual=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$f")
    else
        # No JSON parser — assert the VERSION string appears verbatim in the file.
        if grep -qF "\"$expected\"" "$f"; then
            return 0
        fi
        echo "No JSON parser and plugin.json lacks the VERSION string '$expected'"
        return 1
    fi
    assert_eq "$expected" "$actual" "plugin.json version must equal the VERSION file"
}

# ============================================================================
# Tests — Release commit stamping (V3–V6): receipts stamp the source commit,
# update.sh shows an honest version+commit transition, and a git-less host still
# installs (the commit field is simply omitted). These use the REAL repo git for
# the positive cases and a git-less symlink-farm PATH for the negative case.
# ============================================================================

# Extract the receipt "commit" field ('' when absent). jq when present, awk fallback.
receipt_commit_value() {
    local manifest="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r '.commit // ""' "$manifest" 2>/dev/null
    else
        awk '
            match($0, /"commit"[[:space:]]*:[[:space:]]*"[^"]*"/) {
                s = substr($0, RSTART, RLENGTH); sub(/.*:[[:space:]]*"/, "", s); sub(/".*/, "", s); print s; exit
            }' "$manifest"
    fi
}

test_receipt_records_commit() {
    # install.sh runs from the real Kurama git repo, so the receipt must carry a
    # "commit" field with a valid short SHA. The "version" field format is unchanged.
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    grep -q '"commit"' "$manifest" || { echo "receipt missing commit field"; return 1; }
    local commit
    commit="$(receipt_commit_value "$manifest")"
    echo "$commit" | grep -qE '^[0-9a-f]{7,40}$' || {
        echo "commit is not a valid short SHA: '$commit'"; return 1; }
    # The version field is still a plain version string (format not broken).
    grep -q '"version"[[:space:]]*:[[:space:]]*"[0-9]' "$manifest" || {
        echo "version field format changed unexpectedly"; return 1; }
    return 0
}

test_setup_receipt_records_commit() {
    # setup.sh writes the same commit stamp (parity with install.sh).
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    local commit
    commit="$(receipt_commit_value "$manifest")"
    echo "$commit" | grep -qE '^[0-9a-f]{7,40}$' || {
        echo "setup.sh receipt commit is not a valid short SHA: '$commit'"; return 1; }
    return 0
}

test_update_shows_commit_transition() {
    # update.sh's transition line reports version+commit; with nothing changed and an
    # identical commit it says "up to date". The new-side commit appears in parens.
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    local output
    output=$(bash "$UPDATE_SCRIPT" --agent claude-code 2>&1)
    echo "$output" | grep -q 'Version:' || { echo "update missing Version transition line"; return 1; }
    echo "$output" | grep -qE 'Version:.*\([0-9a-f]{7,40}\)' || {
        echo "update transition line missing the (commit) segment"; return 1; }
    echo "$output" | grep -qi 'up to date' || {
        echo "expected 'up to date' when version+commit identical and nothing changed"; return 1; }
    return 0
}

test_update_restamps_install_sh_receipt() {
    # A pre-#38 install.sh stored the human DISPLAY name in the receipt "tool" field
    # ("Claude Code", with a space) — unlike setup.sh, which stores the slug. install.sh
    # is now a wrapper that writes the slug via setup.sh, but LEGACY display-name receipts
    # still exist on users' machines and update.sh must still normalize them before
    # delegating to setup.sh; otherwise the space word-splits into a bogus --agent token
    # ("Unknown option: Code"), the re-sync fails, update exits 1, and the receipt is NEVER
    # re-stamped (V4 unmet). Stage a faithful legacy receipt and drive that path.
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1

    # Overwrite with a pre-5.0.0 install.sh-shaped receipt: display-name tool, older
    # version, no commit, and no tools[] (the modern array setup.sh added later), so
    # update.sh resolves the tool from the spaced "tool" field and must normalize it.
    cat > "$manifest" <<'LEGACY'
{
  "name": "kurama",
  "version": "5.0.0-dev",
  "tool": "Claude Code",
  "files": [
    "sdd-apply/SKILL.md"
  ]
}
LEGACY
    grep -q '"tool"[[:space:]]*:[[:space:]]*"Claude Code"' "$manifest" || {
        echo "failed to stage a legacy display-name receipt"; return 1; }

    local output rc
    output=$(bash "$UPDATE_SCRIPT" --agent claude-code 2>&1) && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "update.sh must exit 0 on a legacy install.sh receipt (got exit $rc)"
        printf '%s\n' "$output" | awk '{ print "    " $0 }'
        return 1
    fi
    echo "$output" | grep -qi 'Re-sync failed' && {
        echo "update.sh reported 'Re-sync failed' on the install.sh path"; return 1; }
    echo "$output" | grep -qE 'Version:.*5\.0\.0-dev.*\([0-9a-f]{7,40}\)' || {
        echo "transition line missing the '-dev -> version (commit)' re-stamp"; return 1; }

    # The receipt must be re-stamped: commit present again, version bumped to the
    # repo VERSION, and the tool normalized to the slug the re-sync wrote.
    grep -q '"commit"' "$manifest" || {
        echo "receipt not re-stamped: commit still absent"; return 1; }
    local ver
    IFS= read -r ver < "$REPO_DIR/VERSION"
    grep -q "\"version\"[[:space:]]*:[[:space:]]*\"$ver\"" "$manifest" || {
        echo "receipt version not re-stamped to repo VERSION ($ver)"; return 1; }
    grep -q '"tool"[[:space:]]*:[[:space:]]*"claude-code"' "$manifest" || {
        echo "receipt tool not normalized to the slug after re-sync"; return 1; }
    return 0
}

test_receipt_omits_commit_without_git() {
    # A git-less host must still install cleanly — the commit field is simply omitted,
    # never a hard failure. Build a symlink-farm PATH that deliberately excludes git.
    local bindir="$TEST_TMPDIR/nogit-bin"
    mkdir -p "$bindir"
    local tool p
    for tool in bash sh env uname grep egrep dirname basename mkdir cp mv cat date chmod rm ls awk sed tr wc find mktemp sort head printf test jq; do
        p="$(command -v "$tool" 2>/dev/null)" || continue
        ln -sf "$p" "$bindir/$tool"
    done
    # Deliberately DO NOT link git into the farm.

    if ! PATH="$bindir" bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1; then
        echo "install must succeed even when git is absent from PATH"
        return 1
    fi
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    if grep -q '"commit"' "$manifest"; then
        echo "commit field must be omitted when git is unavailable"
        return 1
    fi
    # The install itself is still complete and valid.
    assert_all_skills_installed "$HOME/.claude/skills" || return 1
    return 0
}

# ============================================================================
# Tests — Phase 10b: scope project (O1), hooks (O2), Pi agents (O4),
# update.sh (O6), doctor.sh (O7). Fully offline: git init is local, and the
# doctor tooling probes (gh/pi/engram) are shadowed by fast local shims so no
# network is ever touched.
# ============================================================================

# Init a bare-bones git work tree (local, no network) at $1.
make_git_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q >/dev/null 2>&1
    git -C "$dir" config user.email test@example.com >/dev/null 2>&1
    git -C "$dir" config user.name test >/dev/null 2>&1
}

# Local shims for gh/pi/engram so doctor.sh never hits the network. Prepended to
# PATH; real core tools (grep/awk/jq/…) stay reachable behind them.
make_doctor_shims() {
    local bindir="$1"
    mkdir -p "$bindir"
    cat > "$bindir/gh" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  "auth status") echo "Logged in (project read:project)"; exit 0 ;;
esac
exit 0
SHIM
    cat > "$bindir/pi" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  list) echo "gentle-engram pi-mcp-adapter pi-btw"; exit 0 ;;
esac
exit 0
SHIM
    cat > "$bindir/engram" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  --version) echo "engram 9.9.9"; exit 0 ;;
esac
exit 0
SHIM
    chmod +x "$bindir/gh" "$bindir/pi" "$bindir/engram"
}

# ---- O1: scope project ----

test_scope_project_installs_into_repo() {
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    printf '# Existing project rules\n' > "$repo/CLAUDE.md"

    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" --non-interactive \
        > /dev/null 2>&1 || { echo "project-scope setup exited non-zero"; return 1; }

    # Everything lands inside the repo, not the global config dirs.
    assert_all_skills_installed "$repo/.claude/skills" || return 1
    assert_dir_exists "$repo/.claude/agents" || return 1
    local agent_count
    agent_count=$(find "$repo/.claude/agents" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
    assert_eq "17" "$agent_count" "17 agents into the repo" || return 1
    assert_file_exists "$repo/.claude/hooks/kurama/archive-gate.sh" || return 1
    # Orchestrator merged into the repo's CLAUDE.md, preserving prior content.
    grep -qF 'Existing project rules' "$repo/CLAUDE.md" || { echo "existing CLAUDE.md content lost"; return 1; }
    grep -qF 'BEGIN:kurama' "$repo/CLAUDE.md" || { echo "orchestrator not merged into repo CLAUDE.md"; return 1; }
    # NOTHING was written to the global config dir.
    if [ -d "$HOME/.claude/skills/sdd-apply" ]; then
        echo "project scope leaked into the global ~/.claude"
        return 1
    fi
    return 0
}

test_scope_project_receipt_at_repo_root() {
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" --non-interactive > /dev/null 2>&1
    # Receipt lives at the repo root (O1), not in the skills dir.
    assert_file_exists "$repo/.kurama-install-manifest.json" || return 1
    if [ -f "$repo/.claude/skills/.kurama-install-manifest.json" ]; then
        echo "project receipt should be at the repo root, not the skills dir"
        return 1
    fi
    grep -q '"scope": "project"' "$repo/.kurama-install-manifest.json" || {
        echo "receipt missing scope=project"; return 1; }
    grep -q '.claude/skills/sdd-apply/SKILL.md' "$repo/.kurama-install-manifest.json" || {
        echo "receipt paths not repo-relative"; return 1; }
    return 0
}

test_scope_project_rejects_kurama_repo() {
    # Never install into the Kurama repo itself.
    if bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$REPO_DIR" --non-interactive > /dev/null 2>&1; then
        echo "setup must refuse to install into the Kurama repo"
        return 1
    fi
    return 0
}

test_scope_project_rejects_non_git_noninteractive() {
    local plain="$TEST_TMPDIR/plain-dir"
    mkdir -p "$plain"
    if bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$plain" --non-interactive > /dev/null 2>&1; then
        echo "non-interactive setup must abort on a non-git target"
        return 1
    fi
    return 0
}

test_scope_project_uninstall_clean() {
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" --non-interactive > /dev/null 2>&1
    mkdir -p "$repo/.claude/skills/my-custom"
    echo "keep me" > "$repo/.claude/skills/my-custom/SKILL.md"

    bash "$UNINSTALL_SCRIPT" --scope project --path "$repo" --without-pi-packages > /dev/null 2>&1

    if [ -d "$repo/.claude/skills/sdd-apply" ]; then echo "sdd-apply not removed"; return 1; fi
    if [ -d "$repo/.claude/hooks/kurama" ]; then echo "hooks dir not pruned"; return 1; fi
    if [ -f "$repo/.kurama-install-manifest.json" ]; then echo "receipt not removed"; return 1; fi
    assert_file_exists "$repo/.claude/skills/my-custom/SKILL.md" || return 1
    return 0
}

# Print a flat JSON string array from a receipt, one entry per line (nothing when
# the key is absent). Issue #37 ended the six byte-identical parser copies (and
# this test's private seventh copy that was "kept in sync by convention"): this
# now delegates to manifest_json_array from scripts/lib/receipt.sh, sourced above,
# so the test reads receipts through the EXACT parser uninstall/update/doctor use —
# including the single-line "key": [] handling
# test_nojq_receipt_parser_ignores_single_line_empty_array guards.
receipt_array_values() {
    manifest_json_array "$1" "$2"
}

# True when $2 is an exact line of the newline-separated list $1.
#
# #99: herestring, never `printf | grep -q`. See assert_matches for the full
# reason — grep -q closes the pipe on its first match and the writer takes
# SIGPIPE, which pipefail then reports as "no match".
receipt_array_has() {
    grep -qxF "$2" <<<"$1"
}

test_scope_project_receipt_records_every_tool() {
    # Two harnesses share ONE repo-root receipt (O1), so the second install must
    # MERGE into it rather than truncate it. tools[] holds both slugs and prompts[]
    # holds both orchestrator files — otherwise uninstall walks an incomplete list
    # and leaves the first harness's BEGIN:kurama block behind.
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    # npm shim keeps the opencode dependency step offline (same guard as the
    # global opencode tests).
    local shim="$TEST_TMPDIR/npmshim"
    make_npm_shim "$shim"

    PATH="$shim:$PATH" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "claude-code project setup exited non-zero"; return 1; }
    PATH="$shim:$PATH" bash "$SETUP_SCRIPT" --agent opencode --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "opencode project setup exited non-zero"; return 1; }

    local manifest="$repo/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1

    local tools
    tools="$(receipt_array_values "$manifest" tools)"
    local tool
    for tool in claude-code opencode; do
        receipt_array_has "$tools" "$tool" || {
            echo "receipt tools[] missing '$tool' (got: $(printf '%s' "$tools" | tr '\n' ' '))"
            return 1
        }
    done

    # prompts[] is compared by basename: entries are repo-relative paths.
    local prompt_names="" entry
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        prompt_names="$prompt_names${entry##*/}"$'\n'
    done <<< "$(receipt_array_values "$manifest" prompts)"
    local name
    for name in CLAUDE.md AGENTS.md; do
        receipt_array_has "$prompt_names" "$name" || {
            echo "receipt prompts[] missing '$name' (got: $(printf '%s' "$prompt_names" | tr '\n' ' '))"
            return 1
        }
    done

    # Both prompt files really carry a block to strip before the uninstall runs.
    grep -qF 'BEGIN:kurama' "$repo/CLAUDE.md" || { echo "CLAUDE.md has no kurama block to remove"; return 1; }
    grep -qF 'BEGIN:kurama' "$repo/AGENTS.md" || { echo "AGENTS.md has no kurama block to remove"; return 1; }

    bash "$UNINSTALL_SCRIPT" --scope project --path "$repo" --without-pi-packages > /dev/null 2>&1

    local f
    for f in "$repo/CLAUDE.md" "$repo/AGENTS.md"; do
        [ -f "$f" ] || continue
        if grep -qF 'BEGIN:kurama' "$f"; then
            echo "uninstall left a BEGIN:kurama block in ${f##*/}"
            return 1
        fi
    done
    return 0
}

# ---- TUI detect-and-update pre-flight (setup-tui.sh, KURAMA_TUI_PROBE=1) ----
# The gum TUI cannot be driven from here, but its detection pre-flight is pure
# bash and carries the logic most likely to be wrong: the two receipt locations
# (repo root vs per-harness global skills dir) and the tools[]/tool fallback.
# KURAMA_TUI_PROBE=1 makes the script print one TAB-separated line per detected
# install — <scope>\t<path>\t<comma-joined tools>\t<version> — and exit 0 before
# it touches gum or the banner. The tests below drive that seam, which is the
# same code the TUI itself runs, not a copy of it.

# Run the probe with $1 as CWD (project detection reads $PWD). Prints its stdout
# verbatim; stderr is dropped so a stray warning cannot corrupt the fields.
run_tui_probe() {
    (cd "$1" && KURAMA_TUI_PROBE=1 bash "$TUI_SCRIPT" 2>/dev/null)
}

# Number of non-empty lines in $1 (0 for the empty string).
probe_line_count() {
    printf '%s\n' "$1" | awk 'NF' | wc -l | tr -d ' '
}

# True when $2 is a whole entry of the comma-joined tools field $1.
#
# #99: the commas are split by parameter expansion rather than `| tr`, so there
# is no writer left for grep -q's early exit to signal.
probe_tools_has() {
    local lines="${1//,/$'\n'}"
    grep -qxF "$2" <<<"$lines"
}

# Strip tools[] from a receipt, leaving the v6 / legacy install.sh shape that
# only carries the scalar "tool". jq when present, awk otherwise — the same
# two-path style receipt_array_values uses to read them.
receipt_drop_tools() {
    local manifest="$1"
    local tmp="$manifest.tmp"
    if command -v jq > /dev/null 2>&1; then
        jq 'del(.tools)' "$manifest" > "$tmp"
    else
        awk '
            /"tools"[[:space:]]*:[[:space:]]*\[/ { skip = 1; next }
            skip && /^[[:space:]]*\],?[[:space:]]*$/ { skip = 0; next }
            skip { next }
            { print }' "$manifest" > "$tmp"
    fi
    mv "$tmp" "$manifest"
}

test_tui_probe_detects_project_install() {
    # One repo, two harnesses, one shared repo-root receipt (O1) — so the probe
    # must report ONE project target that names both, not one line per harness.
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    # npm shim keeps the opencode dependency step offline.
    local shim="$TEST_TMPDIR/npmshim"
    make_npm_shim "$shim"

    PATH="$shim:$PATH" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "claude-code project setup exited non-zero"; return 1; }
    PATH="$shim:$PATH" bash "$SETUP_SCRIPT" --agent opencode --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "opencode project setup exited non-zero"; return 1; }

    local out status=0
    out="$(run_tui_probe "$repo")" || status=$?
    assert_eq "0" "$status" "probe must exit 0" || return 1
    assert_eq "1" "$(probe_line_count "$out")" "one project receipt is one line" || return 1

    # Fields are read positionally, not substring-matched, so a reordering of the
    # line is a failure here rather than a silent pass.
    local scope path tools version
    IFS=$'\t' read -r scope path tools version <<< "$out"
    assert_eq "project" "$scope" "field 1 is the scope" || return 1
    assert_eq "$repo" "$path" "field 2 is the probed directory" || return 1
    local tool
    for tool in claude-code opencode; do
        probe_tools_has "$tools" "$tool" || {
            echo "probe tools field missing '$tool' (got: '$tools')"
            return 1
        }
    done
    [ -n "$version" ] || { echo "probe version field (4) is empty"; return 1; }
    return 0
}

test_tui_probe_v6_receipt_reports_its_tool() {
    # A receipt written before tools[] existed only carries the scalar "tool".
    # The probe must fall back to it instead of reporting an unnamed install.
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "claude-code project setup exited non-zero"; return 1; }

    local manifest="$repo/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    receipt_drop_tools "$manifest"
    if grep -q '"tools"' "$manifest"; then
        echo "tools[] survived the v6 downgrade — the fallback is not being exercised"
        return 1
    fi
    grep -q '"tool": "claude-code"' "$manifest" || {
        echo "the v6 downgrade also dropped the scalar tool field"; return 1; }

    local out status=0
    out="$(run_tui_probe "$repo")" || status=$?
    assert_eq "0" "$status" "probe must exit 0" || return 1
    assert_eq "1" "$(probe_line_count "$out")" "one project receipt is one line" || return 1

    local scope path tools version
    IFS=$'\t' read -r scope path tools version <<< "$out"
    assert_eq "project" "$scope" "field 1 is the scope" || return 1
    assert_eq "$repo" "$path" "field 2 is the probed directory" || return 1
    assert_eq "claude-code" "$tools" "field 3 falls back to the scalar tool" || return 1
    [ -n "$version" ] || { echo "probe version field (4) is empty"; return 1; }
    return 0
}

test_tui_probe_no_receipt_is_silent() {
    # Nothing in $PWD and nothing in the sandboxed HOME: the probe prints nothing
    # and still exits 0, so the TUI falls through to today's install flow.
    local empty="$TEST_TMPDIR/empty"
    mkdir -p "$empty"

    local out status=0
    out="$(run_tui_probe "$empty")" || status=$?
    assert_eq "0" "$status" "probe must exit 0 when nothing is installed" || return 1
    assert_eq "0" "$(probe_line_count "$out")" "no receipt anywhere means no output" || return 1
    return 0
}

test_tui_probe_detects_global_install() {
    # Global receipts live in the per-harness skills dir, not the repo root.
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "global claude-code setup exited non-zero"; return 1; }
    assert_file_exists "$HOME/.claude/skills/.kurama-install-manifest.json" || return 1

    # Probed from a directory that has no receipt of its own, so the global line
    # is the only one the probe can emit.
    local elsewhere="$TEST_TMPDIR/elsewhere"
    mkdir -p "$elsewhere"

    local out status=0
    out="$(run_tui_probe "$elsewhere")" || status=$?
    assert_eq "0" "$status" "probe must exit 0" || return 1
    assert_eq "1" "$(probe_line_count "$out")" "one global install is one line" || return 1

    local scope path tools version
    IFS=$'\t' read -r scope path tools version <<< "$out"
    assert_eq "global" "$scope" "field 1 is the scope" || return 1
    case "$path" in
        "$HOME"/*) ;;
        *) echo "field 2 is not a path under the sandboxed HOME (got: '$path')"; return 1 ;;
    esac
    probe_tools_has "$tools" claude-code || {
        echo "probe tools field missing 'claude-code' (got: '$tools')"; return 1; }
    [ -n "$version" ] || { echo "probe version field (4) is empty"; return 1; }
    return 0
}

test_tui_probe_runs_without_gum() {
    # The whole point of answering before the gum precondition check: without gum
    # that check exits 1, and a probe placed after it could never report anything
    # on a machine that has Kurama but not gum.
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    local shim="$TEST_TMPDIR/npmshim"
    make_npm_shim "$shim"

    PATH="$shim:$PATH" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "claude-code project setup exited non-zero"; return 1; }
    PATH="$shim:$PATH" bash "$SETUP_SCRIPT" --agent opencode --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "opencode project setup exited non-zero"; return 1; }

    # Restricted PATH (symlink farm) that deliberately omits gum, so its absence
    # is deterministic regardless of the host — same trick as the pi-absent test.
    local bindir="$TEST_TMPDIR/nogum-bin"
    mkdir -p "$bindir"
    local tool p
    for tool in bash sh env uname grep egrep dirname basename mkdir cp mv cat date chmod rm ls awk sed tr wc find mktemp sort head tail printf test jq git; do
        p="$(command -v "$tool" 2>/dev/null)" || continue
        ln -sf "$p" "$bindir/$tool"
    done
    if [ -e "$bindir/gum" ]; then
        echo "gum is reachable on the restricted PATH — the test proves nothing"
        return 1
    fi

    local out status=0
    out="$(cd "$repo" && PATH="$bindir" KURAMA_TUI_PROBE=1 bash "$TUI_SCRIPT" 2>/dev/null)" || status=$?
    assert_eq "0" "$status" "probe must exit 0 even with gum missing" || return 1
    assert_eq "1" "$(probe_line_count "$out")" "one project receipt is one line" || return 1

    local scope path tools version
    IFS=$'\t' read -r scope path tools version <<< "$out"
    assert_eq "project" "$scope" "field 1 is the scope" || return 1
    assert_eq "$repo" "$path" "field 2 is the probed directory" || return 1
    local t
    for t in claude-code opencode; do
        probe_tools_has "$tools" "$t" || {
            echo "probe tools field missing '$t' (got: '$tools')"
            return 1
        }
    done
    [ -n "$version" ] || { echo "probe version field (4) is empty"; return 1; }
    return 0
}

# ---- O2: hooks always for claude-code ----

test_hooks_installed_global_claude() {
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    assert_file_exists "$HOME/.claude/hooks/kurama/archive-gate.sh" || return 1
    assert_file_exists "$HOME/.claude/hooks/kurama/orchestrator-write-guard.sh" || return 1
    [ -x "$HOME/.claude/hooks/kurama/archive-gate.sh" ] || { echo "hook not executable"; return 1; }
    # settings.json carries a PreToolUse block pointing at hooks/kurama/.
    local settings="$HOME/.claude/settings.json"
    assert_file_exists "$settings" || return 1
    grep -q 'hooks/kurama/' "$settings" || { echo "settings.json missing kurama hooks block"; return 1; }
    # Receipt records the scripts (files[]) and the settings.json (settings[]).
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    grep -q '../hooks/kurama/archive-gate.sh' "$manifest" || { echo "receipt missing hook script"; return 1; }
    grep -q '../settings.json' "$manifest" || { echo "receipt missing settings entry"; return 1; }
    return 0
}

test_hooks_merge_preserves_foreign_entries() {
    # A pre-existing unrelated hook + top-level key must survive the merge.
    mkdir -p "$HOME/.claude"
    printf '{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/my/own.sh"}]}]}}\n' \
        > "$HOME/.claude/settings.json"
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    local settings="$HOME/.claude/settings.json"
    grep -q '/my/own.sh' "$settings" || { echo "foreign hook lost in merge"; return 1; }
    grep -q '"opus"' "$settings" || { echo "foreign top-level key lost in merge"; return 1; }
    grep -q 'hooks/kurama/' "$settings" || { echo "kurama hooks not merged"; return 1; }
    # Idempotent: a second run must not duplicate the kurama block.
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    local n
    n=$(grep -c 'hooks/kurama/orchestrator-write-guard.sh' "$settings")
    assert_eq "1" "$n" "kurama guard hook must appear exactly once after re-run"
}

test_hooks_removed_by_uninstall() {
    mkdir -p "$HOME/.claude"
    printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/my/own.sh"}]}]}}\n' \
        > "$HOME/.claude/settings.json"
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    bash "$UNINSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    # Scripts gone.
    if [ -d "$HOME/.claude/hooks/kurama" ]; then echo "hooks dir not pruned"; return 1; fi
    # Kurama block stripped, foreign hook preserved.
    local settings="$HOME/.claude/settings.json"
    if grep -q 'hooks/kurama/' "$settings"; then echo "kurama hooks block not stripped"; return 1; fi
    grep -q '/my/own.sh' "$settings" || { echo "foreign hook lost during uninstall"; return 1; }
    return 0
}

# ---- O4: Pi agents in project scope ----

test_pi_agents_project_scope() {
    local repo="$TEST_TMPDIR/piproj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent pi --scope project --path "$repo" --non-interactive --without-pi-packages \
        > /dev/null 2>&1 || { echo "pi project setup exited non-zero"; return 1; }
    assert_all_skills_installed "$repo/.pi/skills" || return 1
    assert_dir_exists "$repo/.pi/agents" || return 1
    local count
    count=$(find "$repo/.pi/agents" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
    assert_eq "17" "$count" "17 Pi agents into .pi/agents" || return 1
    grep -qF 'BEGIN:kurama' "$repo/AGENTS.md" || { echo "pi orchestrator not merged into repo AGENTS.md"; return 1; }
    return 0
}

# ---- O6: update.sh re-sync ----

test_update_resyncs_modified_skill() {
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    echo "TAMPERED" > "$HOME/.claude/skills/sdd-apply/SKILL.md"
    bash "$UPDATE_SCRIPT" --agent claude-code > /dev/null 2>&1
    if grep -q 'TAMPERED' "$HOME/.claude/skills/sdd-apply/SKILL.md"; then
        echo "update.sh did not restore the tampered skill"
        return 1
    fi
    diff -q "$HOME/.claude/skills/sdd-apply/SKILL.md" "$REPO_DIR/skills/sdd-apply/SKILL.md" > /dev/null 2>&1 || {
        echo "restored skill does not match repo source"; return 1; }
    return 0
}

test_update_dry_run_changes_nothing() {
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    echo "TAMPERED" > "$HOME/.claude/skills/sdd-apply/SKILL.md"
    bash "$UPDATE_SCRIPT" --agent claude-code --dry-run > /dev/null 2>&1
    grep -q 'TAMPERED' "$HOME/.claude/skills/sdd-apply/SKILL.md" || {
        echo "dry-run update must NOT modify files"; return 1; }
    return 0
}

test_update_resyncs_project_scope() {
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" --non-interactive > /dev/null 2>&1
    echo "TAMPERED" > "$repo/.claude/skills/sdd-apply/SKILL.md"
    bash "$UPDATE_SCRIPT" --scope project --path "$repo" > /dev/null 2>&1
    if grep -q 'TAMPERED' "$repo/.claude/skills/sdd-apply/SKILL.md"; then
        echo "project-scope update did not restore the tampered skill"
        return 1
    fi
    return 0
}

# ---- O7: doctor.sh ----

test_doctor_healthy_exit_zero() {
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    if ! PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" --agent claude-code > /dev/null 2>&1; then
        echo "doctor.sh should exit 0 on a healthy install"
        return 1
    fi
    return 0
}

test_doctor_missing_markers_is_warning_not_failure() {
    # grep -c prints "0" AND exits 1 on no match, so `$(grep -c ... || echo 0)`
    # yielded "0\n0": `[ -eq ]` died with "integer expression expected" and the
    # else branch reported a bogus UNBALANCED. That masked the real diagnosis —
    # a prompt file rewritten over the merged orchestrator block reads exactly
    # like this. A prompt with no markers is a WARNING, never a hard failure.
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    # Rewrite the prompt over the merged block, as a user editing CLAUDE.md would.
    printf '# CLAUDE.md\n\nMy own instructions.\n' > "$HOME/.claude/CLAUDE.md"
    local output status
    output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" --agent claude-code 2>&1) && status=0 || status=$?
    case "$output" in
        *"integer expression expected"*)
            echo "doctor.sh still emits a bash error counting markers"; return 1 ;;
        *UNBALANCED*)
            echo "doctor.sh reports UNBALANCED for a prompt with zero markers"; return 1 ;;
    esac
    echo "$output" | grep -qi 'no kurama markers' \
        || { echo "doctor.sh must name the unmerged orchestrator"; return 1; }
    if [ "$status" -ne 0 ]; then
        echo "a missing orchestrator block is a warning, not a failure (exit $status)"
        return 1
    fi
    return 0
}

test_doctor_broken_receipt_exit_nonzero() {
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    # Break the install: remove a recorded file.
    rm -f "$HOME/.claude/skills/sdd-apply/SKILL.md"
    local output status
    output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" --agent claude-code 2>&1) && status=0 || status=$?
    if [ "$status" -eq 0 ]; then
        echo "doctor.sh should exit non-zero when a recorded file is missing"
        return 1
    fi
    echo "$output" | grep -qi 'MISSING' || { echo "doctor.sh should report the MISSING file"; return 1; }
    return 0
}

test_doctor_orphaned_agents_exit_nonzero() {
    # Artifacts on disk with the receipt gone (hand-moved skills dir, partial
    # migration, interrupted uninstall). doctor must NOT call this healthy: the
    # agents are still wired and still route work, but nothing manages them.
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    bash "$SETUP_SCRIPT" --agent claude-code > /dev/null 2>&1
    # Strip the receipt and move the skills aside, leaving agents + commands wired.
    rm -f "$HOME/.claude/skills/.kurama-install-manifest.json"
    mv "$HOME/.claude/skills" "$HOME/.claude/skills-gentle-backup-20260101000000"
    local output
    if output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" 2>&1); then
        echo "doctor.sh must exit non-zero when Kurama agents exist with no receipt"
        return 1
    fi
    echo "$output" | grep -qi 'no install receipt' \
        || { echo "doctor.sh should name the orphaned agents"; return 1; }
    echo "$output" | grep -qi 'does not exist' \
        || { echo "doctor.sh should report the missing skills path the agents reference"; return 1; }
    return 0
}

test_doctor_no_install_is_not_a_failure() {
    # The clean case: no receipt AND no artifacts. That is absence, not breakage,
    # so it must stay exit 0 — otherwise doctor cries wolf on a fresh machine.
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    local output
    output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" 2>&1) \
        || { echo "doctor.sh must exit 0 when nothing is installed"; return 1; }
    echo "$output" | grep -qi 'nothing is installed' \
        || { echo "doctor.sh should say nothing is installed"; return 1; }
    return 0
}

test_doctor_project_scope_healthy() {
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" --non-interactive > /dev/null 2>&1
    if ! PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" --scope project --path "$repo" > /dev/null 2>&1; then
        echo "doctor.sh should exit 0 on a healthy project install"
        return 1
    fi
    return 0
}

# ---- O5: Engram optional persistence engine (fake engram/brew/claude shims) ----

# Local shims for the O5 flow so no real binary or network is ever touched. With
# $3="with-engram" (default) an `engram` fake is on PATH; "no-engram" omits it so
# the brew/guide branch is exercised. `brew` and `claude` fakes always append
# their argv to $2 so a test can prove they were (not) invoked.
make_engram_shims() {
    local bindir="$1" log="$2" mode="${3:-with-engram}"
    mkdir -p "$bindir"
    if [ "$mode" = "with-engram" ]; then
        cat > "$bindir/engram" <<SHIM
#!/usr/bin/env bash
echo "engram \$*" >> "$log"
case "\$1" in --version) echo "engram 9.9.9" ;; esac
exit 0
SHIM
        chmod +x "$bindir/engram"
    fi
    cat > "$bindir/brew" <<SHIM
#!/usr/bin/env bash
echo "brew \$*" >> "$log"
exit 0
SHIM
    cat > "$bindir/claude" <<SHIM
#!/usr/bin/env bash
echo "claude \$*" >> "$log"
exit 0
SHIM
    chmod +x "$bindir/brew" "$bindir/claude"
}

test_engram_without_flag_no_changes() {
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1
    # No MCP config written when Engram is declined.
    if [ -f "$HOME/.claude.json" ]; then echo ".claude.json must not be written without engram"; return 1; fi
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    grep -q '"engram": "no"' "$manifest" || { echo "receipt must record engram=no"; return 1; }
    # engram_mcp array must be empty.
    local n
    n=$(jq '.engram_mcp | length' "$manifest")
    assert_eq "0" "$n" "engram_mcp must be empty when declined"
}

test_engram_registers_claude_global() {
    local bindir="$TEST_TMPDIR/engrambin" log="$TEST_TMPDIR/engram-calls.log"
    make_engram_shims "$bindir" "$log"
    PATH="$bindir:$PATH" bash "$SETUP_SCRIPT" --agent claude-code --with-engram --non-interactive > /dev/null 2>&1 \
        || { echo "engram setup exited non-zero"; return 1; }
    # Generic mcpServers.engram shape with the canonical args.
    assert_file_exists "$HOME/.claude.json" || return 1
    jq -e '.mcpServers.engram' "$HOME/.claude.json" > /dev/null || { echo "mcpServers.engram missing"; return 1; }
    local args
    args=$(jq -rc '.mcpServers.engram.args' "$HOME/.claude.json")
    assert_eq '["mcp","--tools=agent"]' "$args" "engram args must be [mcp,--tools=agent]" || return 1
    # Receipt records the registration and engram=yes.
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    grep -q '"engram": "yes"' "$manifest" || { echo "receipt must record engram=yes"; return 1; }
    local n
    n=$(jq '.engram_mcp | length' "$manifest")
    [ "$n" -ge 1 ] || { echo "engram_mcp must record the .claude.json path"; return 1; }
    return 0
}

test_engram_opencode_project_shape() {
    local bindir="$TEST_TMPDIR/engrambin" log="$TEST_TMPDIR/engram-calls.log"
    make_engram_shims "$bindir" "$log"
    local repo="$TEST_TMPDIR/ocproj"
    make_git_repo "$repo"
    PATH="$bindir:$PATH" bash "$SETUP_SCRIPT" --agent opencode --scope project --path "$repo" \
        --with-engram --non-interactive > /dev/null 2>&1 || { echo "opencode engram setup non-zero"; return 1; }
    # OpenCode wants command as an array on a type:local server (inject.go parity).
    assert_file_exists "$repo/opencode.json" || return 1
    jq -e '.mcp.engram' "$repo/opencode.json" > /dev/null || { echo "mcp.engram missing"; return 1; }
    local type first
    type=$(jq -r '.mcp.engram.type' "$repo/opencode.json")
    assert_eq "local" "$type" "opencode engram server type must be local" || return 1
    first=$(jq -r '.mcp.engram.command | type' "$repo/opencode.json")
    assert_eq "array" "$first" "opencode engram command must be an array" || return 1
    return 0
}

test_engram_codex_toml_upsert() {
    local bindir="$TEST_TMPDIR/engrambin" log="$TEST_TMPDIR/engram-calls.log"
    make_engram_shims "$bindir" "$log"
    mkdir -p "$HOME/.codex"
    printf 'model = "gpt-5"\n\n[features]\nfoo = true\n' > "$HOME/.codex/config.toml"
    PATH="$bindir:$PATH" bash "$SETUP_SCRIPT" --agent codex --with-engram --non-interactive > /dev/null 2>&1 \
        || { echo "codex engram setup non-zero"; return 1; }
    local toml="$HOME/.codex/config.toml"
    grep -q '^\[mcp_servers.engram\]' "$toml" || { echo "[mcp_servers.engram] block missing"; return 1; }
    grep -q 'args = \["mcp", "--tools=agent"\]' "$toml" || { echo "engram args line missing"; return 1; }
    # Existing content survives the TOML upsert.
    grep -q 'foo = true' "$toml" || { echo "pre-existing codex config lost"; return 1; }
    # Idempotent: a second run must not duplicate the block.
    PATH="$bindir:$PATH" bash "$SETUP_SCRIPT" --agent codex --with-engram --non-interactive > /dev/null 2>&1
    local n
    n=$(grep -c '^\[mcp_servers.engram\]' "$toml")
    assert_eq "1" "$n" "engram block must appear exactly once after re-run"
}

test_engram_project_scope_claude() {
    local bindir="$TEST_TMPDIR/engrambin" log="$TEST_TMPDIR/engram-calls.log"
    make_engram_shims "$bindir" "$log"
    local repo="$TEST_TMPDIR/enproj"
    make_git_repo "$repo"
    PATH="$bindir:$PATH" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --with-engram --non-interactive > /dev/null 2>&1 || { echo "project engram setup non-zero"; return 1; }
    # Project scope writes the Claude project MCP file (.mcp.json) inside the repo.
    assert_file_exists "$repo/.mcp.json" || return 1
    jq -e '.mcpServers.engram' "$repo/.mcp.json" > /dev/null || { echo ".mcp.json engram server missing"; return 1; }
    # Receipt records it repo-relative (never a global leak).
    grep -q '"\.mcp\.json"' "$repo/.kurama-install-manifest.json" || {
        echo "receipt must record .mcp.json repo-relative"; return 1; }
    if [ -f "$HOME/.claude.json" ]; then echo "project engram must not touch the global ~/.claude.json"; return 1; fi
    return 0
}

test_engram_brew_not_invoked_noninteractive() {
    # No engram binary on PATH + non-interactive: setup must NOT run brew (network
    # only ever with explicit consent), yet still write the registration.
    local bindir="$TEST_TMPDIR/engrambin" log="$TEST_TMPDIR/engram-calls.log"
    make_engram_shims "$bindir" "$log" "no-engram"
    : > "$log"
    PATH="$bindir:$PATH" bash "$SETUP_SCRIPT" --agent claude-code --with-engram --non-interactive > /dev/null 2>&1 \
        || { echo "engram setup non-zero"; return 1; }
    if [ -f "$log" ] && grep -q 'brew ' "$log"; then echo "brew must not be invoked in non-interactive mode"; return 1; fi
    # Registration is still written even when consent/install is skipped.
    assert_file_exists "$HOME/.claude.json" || return 1
    jq -e '.mcpServers.engram' "$HOME/.claude.json" > /dev/null || {
        echo "engram MCP must still be registered when the binary install is skipped"; return 1; }
    return 0
}

test_engram_uninstall_removes_registration() {
    # setup --with-engram registers mcpServers.engram in ~/.claude.json; uninstall
    # must strip exactly that entry (receipt-driven) and leave every other server
    # and top-level key byte-intact. Fully offline (fake engram/brew/claude shims).
    local bindir="$TEST_TMPDIR/engrambin" log="$TEST_TMPDIR/engram-calls.log"
    make_engram_shims "$bindir" "$log"

    # Pre-seed a config with an unrelated MCP server + top-level key that must survive.
    mkdir -p "$HOME/.claude"
    printf '{"someKey":"keep","mcpServers":{"other":{"command":"x"}}}\n' > "$HOME/.claude.json"

    PATH="$bindir:$PATH" bash "$SETUP_SCRIPT" --agent claude-code --with-engram --non-interactive \
        > /dev/null 2>&1 || { echo "engram setup exited non-zero"; return 1; }
    jq -e '.mcpServers.engram' "$HOME/.claude.json" > /dev/null || {
        echo "engram was not registered before uninstall"; return 1; }
    # The receipt recorded the touched config in engram_mcp[].
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    local n
    n=$(jq '.engram_mcp | length' "$manifest")
    [ "$n" -ge 1 ] || { echo "engram_mcp must record the .claude.json path"; return 1; }

    # Uninstall strips the engram registration only.
    bash "$UNINSTALL_SCRIPT" --agent claude-code --without-pi-packages > /dev/null 2>&1

    if jq -e '.mcpServers.engram' "$HOME/.claude.json" > /dev/null 2>&1; then
        echo "engram registration was NOT removed by uninstall"; return 1; fi
    jq -e '.mcpServers.other' "$HOME/.claude.json" > /dev/null || {
        echo "unrelated MCP server was lost during engram uninstall"; return 1; }
    local sk
    sk=$(jq -r '.someKey' "$HOME/.claude.json")
    assert_eq "keep" "$sk" "unrelated top-level key preserved through engram uninstall" || return 1
    return 0
}

test_doctor_reports_engram_mcp() {
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    local bindir="$TEST_TMPDIR/engrambin" log="$TEST_TMPDIR/engram-calls.log"
    make_engram_shims "$bindir" "$log"
    PATH="$bindir:$PATH" bash "$SETUP_SCRIPT" --agent claude-code --with-engram --non-interactive > /dev/null 2>&1
    local output
    output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" --agent claude-code 2>&1)
    echo "$output" | grep -qi 'Engram MCP registered' || { echo "doctor must mention the Engram MCP registration"; return 1; }
    return 0
}

# ============================================================================
# Tests — the two shipped PreToolUse hooks (#31)
#
# These two scripts run on the USER's machine on every Edit/Write/MultiEdit and
# every Task/Skill call, and they block with exit 2. Nothing in this repo had
# ever piped a payload into either of them: their entire behaviour — what they
# allow, what they block, and every escape hatch documented in docs/hooks.md —
# was unverified. A broken guard fails in both directions and both are bad: one
# stops all work, the other silently stops guarding.
#
# Everything below drives the SHIPPED files under examples/claude-code/hooks/
# (the exact bytes setup.sh copies), through stdin, exactly as Claude Code does.
# ============================================================================

# The hook's combined output and exit code from the last run_hook call. Two
# globals rather than a return value because a test needs BOTH, and a hook that
# blocks exits 2 — which a plain command substitution would turn into an aborted
# test body now that errexit really reaches it.
HOOK_OUT=""
HOOK_STATUS=0

# Pipe payload $2 into hook $1 (extra args are passed to the hook, as CLI mode
# takes a change name). Env overrides go in front of the call:
#   KURAMA_GUARD_BYPASS=1 run_hook "$WRITE_GUARD_HOOK" "$payload"
run_hook() {
    local hook="$1" payload="$2"
    shift 2
    HOOK_STATUS=0
    HOOK_OUT="$(printf '%s' "$payload" | bash "$hook" "$@" 2>&1)" || HOOK_STATUS=$?
    return 0
}

# A PreToolUse Edit payload for file $2, in project $1. $3, when non-empty, is
# the ROOT-level agent_id Claude Code sets only inside a subagent.
edit_payload() {
    local root="$1" file="$2" agent="${3:-}"
    if [ -n "$agent" ]; then
        printf '{"session_id":"s1","agent_id":"%s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"a","new_string":"b"}}' \
            "$agent" "$root" "$file"
    else
        printf '{"session_id":"s1","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"a","new_string":"b"}}' \
            "$root" "$file"
    fi
}

# A PreToolUse Skill payload naming skill $2, in project $1.
skill_payload() {
    printf '{"session_id":"s1","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"%s"}}' "$1" "$2"
}

# A git repo carrying an ACTIVE SDD cycle in engram-fallback shape: the
# .kurama/sdd/<change>/state.md marker batch 1 made every mode write, and no
# archive report (writing one is what retires the cycle).
make_active_cycle_repo() {
    local root="$1" change="${2:-add-widget}"
    make_git_repo "$root"
    mkdir -p "$root/src" "$root/.kurama/sdd/$change"
    printf 'export const widget = 1;\n' > "$root/src/widget.ts"
    printf '# Cycle state\n\nphase: apply\n' > "$root/.kurama/sdd/$change/state.md"
}

# Write a verify report for $2 under $1/.kurama/sdd/, with verdict $3 and an
# optional Content Binding Tree-Hash $4.
write_verify_report() {
    local root="$1" change="$2" verdict="$3" tree="${4:-}"
    mkdir -p "$root/.kurama/sdd/$change"
    {
        printf '# Verify report — %s\n\n' "$change"
        if [ -n "$tree" ]; then
            printf '## Content Binding\n\nTree-Hash: %s\n\n' "$tree"
        fi
        printf '### Verdict\n\n%s\n' "$verdict"
    } > "$root/.kurama/sdd/$change/verify-report.md"
}

test_write_guard_allows_writes_when_no_cycle_is_active() {
    local repo="$TEST_TMPDIR/no-cycle"
    make_git_repo "$repo"
    mkdir -p "$repo/src"
    printf 'x\n' > "$repo/src/app.ts"
    run_hook "$WRITE_GUARD_HOOK" "$(edit_payload "$repo" "src/app.ts")"
    assert_eq "0" "$HOOK_STATUS" "a repo with no SDD cycle must not be guarded at all" || {
        printf '%s\n' "$HOOK_OUT"; return 1; }
    return 0
}

test_write_guard_blocks_repo_code_during_an_active_cycle() {
    local repo="$TEST_TMPDIR/active"
    make_active_cycle_repo "$repo"
    run_hook "$WRITE_GUARD_HOOK" "$(edit_payload "$repo" "src/widget.ts")"
    assert_eq "2" "$HOOK_STATUS" "an orchestrator write to repo code during a cycle must be blocked" || {
        printf '%s\n' "$HOOK_OUT"; return 1; }
    # exit 2 feeds stderr back to the model, so the message IS the remedy.
    printf '%s\n' "$HOOK_OUT" | grep -q 'BLOCKED by kurama orchestrator-write-guard' || {
        echo "the block carries no identifying message:"; printf '%s\n' "$HOOK_OUT"; return 1; }
    printf '%s\n' "$HOOK_OUT" | grep -q 'DELEGATE' || {
        echo "the block never tells the orchestrator what to do instead"; return 1; }
    return 0
}

test_write_guard_exempts_the_sdd_artifact_paths() {
    # The cycle cannot advance if the guard blocks the very files the phases
    # persist their state and artifacts into.
    local repo="$TEST_TMPDIR/exempt"
    make_active_cycle_repo "$repo"
    local p
    for p in ".kurama/sdd/add-widget/state.md" "openspec/changes/add-widget/design.md"; do
        run_hook "$WRITE_GUARD_HOOK" "$(edit_payload "$repo" "$p")"
        assert_eq "0" "$HOOK_STATUS" "marker/artifact path '$p' must stay writable during a cycle" || {
            printf '%s\n' "$HOOK_OUT"; return 1; }
    done
    # An absolute path resolves to the same exemption.
    run_hook "$WRITE_GUARD_HOOK" "$(edit_payload "$repo" "$repo/.kurama/sdd/add-widget/state.md")"
    assert_eq "0" "$HOOK_STATUS" "an absolute marker path must be exempt too" || return 1
    # …and a path outside the repo is none of the guard's business.
    run_hook "$WRITE_GUARD_HOOK" "$(edit_payload "$repo" "$TEST_TMPDIR/elsewhere/notes.md")"
    assert_eq "0" "$HOOK_STATUS" "a write outside the project must not be guarded" || return 1
    return 0
}

test_write_guard_stops_guarding_once_the_cycle_is_archived() {
    # archive-report.md is what retires a cycle. Without this, a repo would stay
    # guarded forever after its first SDD change.
    local repo="$TEST_TMPDIR/retired"
    make_active_cycle_repo "$repo"
    run_hook "$WRITE_GUARD_HOOK" "$(edit_payload "$repo" "src/widget.ts")"
    assert_eq "2" "$HOOK_STATUS" "precondition: the cycle must be active before it is retired" || return 1

    printf '# Archive report\n' > "$repo/.kurama/sdd/add-widget/archive-report.md"
    run_hook "$WRITE_GUARD_HOOK" "$(edit_payload "$repo" "src/widget.ts")"
    assert_eq "0" "$HOOK_STATUS" "an archived cycle must stop guarding writes" || {
        printf '%s\n' "$HOOK_OUT"; return 1; }
    return 0
}

test_write_guard_passes_subagent_writes_and_resists_spoofing() {
    local repo="$TEST_TMPDIR/subagent"
    make_active_cycle_repo "$repo"
    # A delegated writer (sdd-apply) is the INTENDED author of repo code.
    run_hook "$WRITE_GUARD_HOOK" "$(edit_payload "$repo" "src/widget.ts" "agent_7")"
    assert_eq "0" "$HOOK_STATUS" "a subagent write must pass — delegation is the point" || {
        printf '%s\n' "$HOOK_OUT"; return 1; }

    # The hardening that matters: agent_id is read at the JSON ROOT only. Here it
    # sits inside tool_input — the user-controlled half of the payload — which is
    # what both parsers must refuse to honour: jq anchors to the root key, and the
    # no-jq fallback scans only the prefix BEFORE "tool_input". A recursive
    # descent (or an unanchored grep) finds it and hands a main-thread write the
    # subagent pass.
    local spoof
    spoof=$(printf '{"session_id":"s1","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"src/widget.ts","meta":{"agent_id":"forged"}}}' "$repo")
    run_hook "$WRITE_GUARD_HOOK" "$spoof"
    assert_eq "2" "$HOOK_STATUS" "an agent_id inside tool_input must not bypass the guard" || {
        printf '%s\n' "$HOOK_OUT"; return 1; }
    return 0
}

test_write_guard_override_env_vars_open_the_gate() {
    local repo="$TEST_TMPDIR/override"
    make_active_cycle_repo "$repo"
    local payload
    payload="$(edit_payload "$repo" "src/widget.ts")"
    run_hook "$WRITE_GUARD_HOOK" "$payload"
    assert_eq "2" "$HOOK_STATUS" "precondition: this write must be blocked without an override" || return 1

    KURAMA_GUARD_BYPASS=1 run_hook "$WRITE_GUARD_HOOK" "$payload"
    assert_eq "0" "$HOOK_STATUS" "KURAMA_GUARD_BYPASS=1 must allow the call" || {
        printf '%s\n' "$HOOK_OUT"; return 1; }
    KURAMA_ORCHESTRATOR_GUARD=0 run_hook "$WRITE_GUARD_HOOK" "$payload"
    assert_eq "0" "$HOOK_STATUS" "KURAMA_ORCHESTRATOR_GUARD=0 must disable the guard" || {
        printf '%s\n' "$HOOK_OUT"; return 1; }
    return 0
}

test_archive_gate_ignores_every_non_archive_launch() {
    # The gate is wired on Task|Skill, which fires for every delegation in the
    # session. Anything that is not an sdd-archive launch must pass untouched —
    # including in a repo with no verify report anywhere.
    local repo="$TEST_TMPDIR/gate-passthrough"
    make_active_cycle_repo "$repo"
    local s
    for s in sdd-apply sdd-verify review-risk; do
        run_hook "$ARCHIVE_GATE_HOOK" "$(skill_payload "$repo" "$s")"
        assert_eq "0" "$HOOK_STATUS" "a '$s' launch is not the gate's business" || {
            printf '%s\n' "$HOOK_OUT"; return 1; }
    done
    return 0
}

test_archive_gate_blocks_an_archive_with_no_verify_report() {
    local repo="$TEST_TMPDIR/gate-noreport"
    make_active_cycle_repo "$repo"
    KURAMA_CHANGE=add-widget run_hook "$ARCHIVE_GATE_HOOK" "$(skill_payload "$repo" sdd-archive)"
    assert_eq "2" "$HOOK_STATUS" "archiving without a verify report must be blocked" || {
        printf '%s\n' "$HOOK_OUT"; return 1; }
    printf '%s\n' "$HOOK_OUT" | grep -q 'no verify-report found' || {
        echo "the block never says the report is what is missing:"; printf '%s\n' "$HOOK_OUT"; return 1; }
    return 0
}

test_archive_gate_passes_a_pass_verdict_in_the_kurama_store() {
    # The engram-fallback store (.kurama/sdd/<change>/verify-report.md) is the
    # every-mode location batch 1 settled on; the gate must read it, and must find
    # the change on its own when nothing names it.
    local repo="$TEST_TMPDIR/gate-pass"
    make_active_cycle_repo "$repo"
    write_verify_report "$repo" add-widget "PASS WITH WARNINGS"
    KURAMA_CHANGE=add-widget run_hook "$ARCHIVE_GATE_HOOK" "$(skill_payload "$repo" sdd-archive)"
    assert_eq "0" "$HOOK_STATUS" "a PASS WITH WARNINGS verdict must open the gate" || {
        printf '%s\n' "$HOOK_OUT"; return 1; }
    # Same report, no KURAMA_CHANGE: the auto-detect has to land on it.
    run_hook "$ARCHIVE_GATE_HOOK" "$(skill_payload "$repo" sdd-archive)"
    assert_eq "0" "$HOOK_STATUS" "the gate must auto-detect the only active change" || {
        printf '%s\n' "$HOOK_OUT"; return 1; }
    return 0
}

test_archive_gate_blocks_a_fail_verdict() {
    local repo="$TEST_TMPDIR/gate-fail"
    make_active_cycle_repo "$repo"
    write_verify_report "$repo" add-widget "FAIL"
    KURAMA_CHANGE=add-widget run_hook "$ARCHIVE_GATE_HOOK" "$(skill_payload "$repo" sdd-archive)"
    assert_eq "2" "$HOOK_STATUS" "a FAIL verdict must not be archivable" || {
        printf '%s\n' "$HOOK_OUT"; return 1; }
    printf '%s\n' "$HOOK_OUT" | grep -q 'verify verdict is FAIL' || {
        echo "the block never names the FAIL verdict:"; printf '%s\n' "$HOOK_OUT"; return 1; }

    # An unfilled template is not a PASS either — that is the report nobody wrote.
    write_verify_report "$repo" add-widget "{VERDICT}"
    KURAMA_CHANGE=add-widget run_hook "$ARCHIVE_GATE_HOOK" "$(skill_payload "$repo" sdd-archive)"
    assert_eq "2" "$HOOK_STATUS" "an unfilled verdict template must not be archivable" || return 1
    return 0
}

test_archive_gate_content_binding_blocks_a_stale_receipt() {
    local repo="$TEST_TMPDIR/gate-binding"
    make_active_cycle_repo "$repo"
    local payload
    payload="$(skill_payload "$repo" sdd-archive)"

    # Start from a Tree-Hash that cannot be the live one. The block message
    # reports the live hash, which is how the fresh case below gets a correct
    # receipt WITHOUT this test reimplementing the hook's pathspec — a private
    # copy of it here would drift silently and pass either way.
    write_verify_report "$repo" add-widget "PASS" "0000000000000000000000000000000000000000"
    KURAMA_CHANGE=add-widget run_hook "$ARCHIVE_GATE_HOOK" "$payload"
    assert_eq "2" "$HOOK_STATUS" "a Tree-Hash that does not match the tree must block" || {
        printf '%s\n' "$HOOK_OUT"; return 1; }
    printf '%s\n' "$HOOK_OUT" | grep -q 'verify receipt stale' || {
        echo "the block never names the stale receipt:"; printf '%s\n' "$HOOK_OUT"; return 1; }

    local live
    live=$(printf '%s\n' "$HOOK_OUT" | awk '/live Tree-Hash:/ { print $NF; exit }')
    [ -n "$live" ] || { echo "the block never reported the live Tree-Hash"; return 1; }

    # A receipt bound to the current tree: fresh, so the verdict gate decides.
    write_verify_report "$repo" add-widget "PASS" "$live"
    KURAMA_CHANGE=add-widget run_hook "$ARCHIVE_GATE_HOOK" "$payload"
    assert_eq "0" "$HOOK_STATUS" "a receipt bound to the current tree must be accepted" || {
        printf '%s\n' "$HOOK_OUT"; return 1; }

    # Touch repository code — and only that — and the same receipt goes stale.
    printf 'export const widget = 2;\n' > "$repo/src/widget.ts"
    KURAMA_CHANGE=add-widget run_hook "$ARCHIVE_GATE_HOOK" "$payload"
    assert_eq "2" "$HOOK_STATUS" "a code edit after verification must invalidate the receipt" || {
        printf '%s\n' "$HOOK_OUT"; return 1; }
    printf '%s\n' "$HOOK_OUT" | grep -q 'verify receipt stale' || {
        echo "the post-edit block is not the staleness one:"; printf '%s\n' "$HOOK_OUT"; return 1; }
    return 0
}

test_archive_gate_override_env_var_opens_the_gate() {
    local repo="$TEST_TMPDIR/gate-override"
    make_active_cycle_repo "$repo"
    local payload
    payload="$(skill_payload "$repo" sdd-archive)"
    KURAMA_CHANGE=add-widget run_hook "$ARCHIVE_GATE_HOOK" "$payload"
    assert_eq "2" "$HOOK_STATUS" "precondition: no report, so the gate must be shut" || return 1

    KURAMA_ARCHIVE_OVERRIDE=1 KURAMA_CHANGE=add-widget run_hook "$ARCHIVE_GATE_HOOK" "$payload"
    assert_eq "0" "$HOOK_STATUS" "KURAMA_ARCHIVE_OVERRIDE=1 must open the gate" || {
        printf '%s\n' "$HOOK_OUT"; return 1; }
    # The override is loud on purpose: it must say a reason has to be recorded.
    printf '%s\n' "$HOOK_OUT" | grep -qi 'REASON' || {
        echo "the override is silent about the reason it must be recorded with:"
        printf '%s\n' "$HOOK_OUT"; return 1; }

    # …and it bypasses the content binding too, not only the verdict gate.
    write_verify_report "$repo" add-widget "PASS" "0000000000000000000000000000000000000000"
    KURAMA_ARCHIVE_OVERRIDE=1 KURAMA_CHANGE=add-widget run_hook "$ARCHIVE_GATE_HOOK" "$payload"
    assert_eq "0" "$HOOK_STATUS" "the override must bypass the content-binding check too" || return 1
    return 0
}

test_nojq_hooks_decide_the_same_way_without_jq() {
    # Both hooks carry their own awk fallback for a jq-less host, and the write
    # guard's agent_id extraction takes a DIFFERENT code path there — a depth-aware
    # scan that accepts the key only at brace depth 1, where the jq half indexes the
    # root object directly. A hook that fails open without jq would guard nothing on
    # exactly the machines this project promises to work on.
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1
    local repo="$TEST_TMPDIR/nojq-hooks"
    make_active_cycle_repo "$repo"

    local status=0
    printf '%s' "$(edit_payload "$repo" "src/widget.ts")" \
        | PATH="$bindir" bash "$WRITE_GUARD_HOOK" > /dev/null 2>&1 || status=$?
    assert_eq "2" "$status" "without jq the write guard must still block repo code" || return 1

    status=0
    printf '%s' "$(edit_payload "$repo" "src/widget.ts" "agent_7")" \
        | PATH="$bindir" bash "$WRITE_GUARD_HOOK" > /dev/null 2>&1 || status=$?
    assert_eq "0" "$status" "without jq a subagent write must still pass" || return 1

    # Root-anchoring has to hold on the no-jq half too: an agent_id inside
    # tool_input is user-controlled and must not read as subagent context.
    local spoof
    spoof=$(printf '{"session_id":"s1","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"src/widget.ts","meta":{"agent_id":"forged"}}}' "$repo")
    status=0
    printf '%s' "$spoof" | PATH="$bindir" bash "$WRITE_GUARD_HOOK" > /dev/null 2>&1 || status=$?
    assert_eq "2" "$status" "without jq an agent_id inside tool_input must not bypass the guard" || return 1

    status=0
    printf '%s' "$(skill_payload "$repo" sdd-archive)" \
        | PATH="$bindir" KURAMA_CHANGE=add-widget bash "$ARCHIVE_GATE_HOOK" > /dev/null 2>&1 || status=$?
    assert_eq "2" "$status" "without jq the archive gate must still block a missing report" || return 1

    write_verify_report "$repo" add-widget "PASS"
    status=0
    printf '%s' "$(skill_payload "$repo" sdd-archive)" \
        | PATH="$bindir" KURAMA_CHANGE=add-widget bash "$ARCHIVE_GATE_HOOK" > /dev/null 2>&1 || status=$?
    assert_eq "0" "$status" "without jq a PASS verdict must still open the gate" || return 1
    return 0
}

# ============================================================================
# Tests — validate_skills.sh frontmatter linter (#31)
#
# The linter's job is to be the thing that notices a SKILL.md a harness cannot
# read. It reported PASS on three malformed inputs: a frontmatter fence that is
# never closed (so the ENTIRE file is frontmatter to anything that parses it),
# an empty `name:`, and an empty `description:` — the last two being exactly the
# fields Claude Code and OpenCode index skills by.
#
# validate_skills.sh has no self-test mechanism and lints the repo it lives in,
# resolved from its own location. So the fixtures below are driven through a
# throwaway repo with a copy of the SHIPPED script in it: same code, same code
# path, a skills tree we control. The other checks fail against a bare fixture
# tree by design (no manifest, no installers) — every case here reads the
# frontmatter check's own lines, never the exit code.
# ============================================================================

# Build a throwaway repo at $1 that validate_skills.sh will lint: a copy of the
# real script under scripts/, and an empty skills/ for the fixtures.
make_linter_fixture_repo() {
    local root="$1"
    mkdir -p "$root/scripts" "$root/skills"
    cp "$VALIDATE_SCRIPT" "$root/scripts/validate_skills.sh"
}

# Write stdin as skills/$2/SKILL.md inside the fixture repo $1.
write_fixture_skill() {
    local root="$1" name="$2"
    mkdir -p "$root/skills/$name"
    cat > "$root/skills/$name/SKILL.md"
}

# Echo the frontmatter section of the linter's report for fixture repo $1. The
# section ends at the next `== ... ==` header, so a later check's output can
# never be mistaken for a frontmatter verdict.
lint_fixture_frontmatter_report() {
    local root="$1" output status=0
    output=$(bash "$root/scripts/validate_skills.sh" 2>&1) || status=$?
    printf '%s\n' "$output" | awk '
        /^== SKILL\.md frontmatter ==$/ { on = 1; next }
        on && /^== / { exit }
        on { print }
    '
}

test_validate_skills_rejects_unclosed_frontmatter_fence() {
    local root="$TEST_TMPDIR/lint-unclosed"
    make_linter_fixture_repo "$root"
    write_fixture_skill "$root" unclosed <<'MD'
---
name: unclosed
description: the closing fence never arrives, so this whole file is frontmatter
MD
    local report
    report="$(lint_fixture_frontmatter_report "$root")"
    printf '%s\n' "$report" | grep -q '\[FAIL\].*unclosed' || {
        echo "the linter accepted a SKILL.md whose frontmatter fence is never closed:"
        printf '%s\n' "$report"
        return 1
    }
    return 0
}

test_validate_skills_rejects_empty_name() {
    local root="$TEST_TMPDIR/lint-emptyname"
    make_linter_fixture_repo "$root"
    write_fixture_skill "$root" emptyname <<'MD'
---
name:
description: a real description, but the name a harness indexes by is blank
---

Body.
MD
    local report
    report="$(lint_fixture_frontmatter_report "$root")"
    printf '%s\n' "$report" | grep -q '\[FAIL\].*emptyname' || {
        echo "the linter accepted a SKILL.md with an empty name:"
        printf '%s\n' "$report"
        return 1
    }
    return 0
}

test_validate_skills_rejects_empty_description() {
    local root="$TEST_TMPDIR/lint-emptydesc"
    make_linter_fixture_repo "$root"
    write_fixture_skill "$root" emptydesc <<'MD'
---
name: emptydesc
description:
---

Body.
MD
    local report
    report="$(lint_fixture_frontmatter_report "$root")"
    printf '%s\n' "$report" | grep -q '\[FAIL\].*emptydesc' || {
        echo "the linter accepted a SKILL.md with an empty description:"
        printf '%s\n' "$report"
        return 1
    }
    return 0
}

test_validate_skills_accepts_wellformed_frontmatter() {
    # The other half of the contract: tightening a linter is only useful if it
    # still passes what is correct. A multi-line folded description is in here
    # because that is the shape several shipped skills use.
    local root="$TEST_TMPDIR/lint-good"
    make_linter_fixture_repo "$root"
    write_fixture_skill "$root" wellformed <<'MD'
---
name: wellformed
description: >-
  A folded description that continues
  onto a second line.
---

Body with a horizontal rule below, which is NOT a frontmatter fence.

---

More body.
MD
    local report
    report="$(lint_fixture_frontmatter_report "$root")"
    if printf '%s\n' "$report" | grep -q '\[FAIL\]'; then
        echo "the linter rejected a well-formed SKILL.md:"
        printf '%s\n' "$report"
        return 1
    fi
    printf '%s\n' "$report" | grep -q '\[ OK \]' || {
        echo "the frontmatter check never reported a verdict at all:"
        printf '%s\n' "$report"
        return 1
    }
    return 0
}

# ============================================================================
# Tests — jq-less host (the awk fallbacks actually work)
#
# Kurama needs no build step and no runtime, and jq is optional — it is needed only
# for the JSON-merging extras (the settings.json hooks block, the Engram MCP
# registration, opencode's tui.json). But every restricted-PATH farm in this file
# linked jq in, so the awk fallbacks were never executed here. They are also never
# executed on a developer's Mac (macOS ships jq in /usr/bin since 15),
# which is exactly how two defects shipped: manifest_skill_lines resolved 0 skills
# from the pretty-printed manifest, and the receipt array parser walked past a
# single-line "key": [] into the NEXT key. The farm below is the same idiom as the
# pi-absent / git-absent / gum-absent ones, with jq as the subject.
#
# What a jq-less install does NOT promise: an identical tree. Measured on project
# scope, claude-code — the receipt comes out byte-identical, and the trees differ
# in exactly one file, `.claude/settings.json`, which exists with jq and not
# without it. That is merge_hooks_settings degrading to printed manual steps and
# returning 0, the documented contract in docs/installation.md:141-142 — JSON
# edits go through jq or not at all, never sed. It is intentional, so these cases
# assert what is actually guaranteed (exit 0, the full skill set, the receipt's
# arrays, a merged orchestrator) rather than whole-tree equality. Anyone adding a
# tree comparison here has to exclude that file, for that reason.
# ============================================================================

# Build a restricted PATH (symlink farm) at $1 holding the core tools an install
# needs, deliberately WITHOUT jq, so its absence is deterministic regardless of
# the host. python3 IS linked: it is what a real jq-less Linux box looks like, and
# it keeps validate_skills.sh's JSON checks running for real instead of soft-
# skipping them — no copy of manifest_skill_lines has a python3 branch, so it
# cannot stand in for jq in anything tested here.
make_nojq_farm() {
    local bindir="$1"
    mkdir -p "$bindir"
    local tool p
    # shasum/sha1sum/cksum are doctor.sh's drift hashers and stat is archive-gate's
    # mtime probe. They are core tools on any real box; leaving them out would make
    # doctor compare two empty hashes and report "no drift" without ever having
    # looked — an absence that has nothing to do with jq, which is the only thing
    # this farm exists to remove.
    for tool in bash sh env uname grep egrep dirname basename mkdir cp mv cat date chmod rm rmdir ls awk sed tr wc find mktemp sort head tail printf test touch ln cut diff git python3 shasum sha1sum cksum stat; do
        p="$(command -v "$tool" 2>/dev/null)" || continue
        ln -sf "$p" "$bindir/$tool"
    done
    # Deliberately DO NOT link jq into the farm.
}

# Fail unless jq is genuinely unreachable through the farm at $1. A farm that
# still saw jq would make every case in this section vacuously green, so this
# guard runs first in all of them. Asked two ways: no link in the directory, and
# `command -v jq` — the question every script under test asks — empty with the
# farm as the whole PATH (hash -r so a location this shell already remembered
# cannot answer for it).
assert_farm_has_no_jq() {
    local bindir="$1"
    if [ -e "$bindir/jq" ]; then
        echo "jq is linked into the farm ($bindir/jq) — this case would prove nothing"
        return 1
    fi
    local found
    found="$(bash -c 'PATH="$1"; hash -r; command -v jq' bash "$bindir" 2>/dev/null || true)"
    if [ -n "$found" ]; then
        echo "command -v jq resolves to '$found' under the farm PATH — this case would prove nothing"
        return 1
    fi
    return 0
}

# Fail unless the receipts $1 (control) and $2 hold the same entries, in the same
# order, for every array key named after them. Read through receipt_array_values,
# i.e. the way the shipped tooling reads a receipt rather than a private parser.
assert_receipt_arrays_match() {
    local control="$1" target="$2"
    shift 2
    local key expected actual
    for key in "$@"; do
        expected="$(receipt_array_values "$control" "$key")"
        actual="$(receipt_array_values "$target" "$key")"
        if [ "$expected" != "$actual" ]; then
            echo "  receipt ${key}[] differs from the jq-present control run:"
            echo "    control: $(printf '%s' "$expected" | tr '\n' ' ')"
            echo "    no jq:   $(printf '%s' "$actual" | tr '\n' ' ')"
            return 1
        fi
    done
    return 0
}

# Fail unless $1 carries a balanced kurama orchestrator block. Counting BOTH
# markers is what separates a merged prompt from a half-written one: uninstall
# refuses to strip an unbalanced pair, so it would leave the block behind forever.
assert_balanced_kurama_block() {
    local file="$1"
    assert_file_exists "$file" || return 1
    local begin end
    begin=$(grep -cF 'BEGIN:kurama' "$file" 2>/dev/null || true)
    end=$(grep -cF 'END:kurama' "$file" 2>/dev/null || true)
    if [ "$begin" -lt 1 ] || [ "$begin" != "$end" ]; then
        echo "  ${file##*/}: $begin BEGIN:kurama / $end END:kurama (expected a matching pair)"
        return 1
    fi
    return 0
}

# Count installed SKILL.md files under $1 (0 when the directory does not exist).
count_skill_files() {
    [ -d "$1" ] || { echo 0; return 0; }
    find "$1" -name 'SKILL.md' | wc -l | tr -d ' '
}

# Rewrite $1 in place so its files[] becomes a single-line empty array, leaving
# every other key exactly as setup.sh wrote it. No writer in this repo emits that
# shape, which is why the receipt parser's opening rule was never exercised
# against it; the receipt this runs on is a throwaway install, never a real one.
collapse_receipt_files_to_empty_array() {
    local manifest="$1"
    local tmp="$manifest.tmp"
    awk '
        !collapsed && /^[[:space:]]*"files"[[:space:]]*:[[:space:]]*\[[[:space:]]*$/ {
            print "  \"files\": [],"; collapsed = 1; skip = 1; next
        }
        skip && /^[[:space:]]*\],?[[:space:]]*$/ { skip = 0; next }
        skip { next }
        { print }
    ' "$manifest" > "$tmp" && mv "$tmp" "$manifest"
}

test_nojq_setup_claude_code_project_installs() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    # A control install on the host PATH fixes the expected skill count, so this
    # asserts "same as with jq" rather than a literal that rots on the next skill.
    local control="$TEST_TMPDIR/control-repo" target="$TEST_TMPDIR/nojq-repo"
    make_git_repo "$control"
    make_git_repo "$target"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$control" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "control (jq present) setup exited non-zero"; return 1; }
    local expected
    expected="$(count_skill_files "$control/.claude/skills")"
    [ "$expected" -gt 0 ] || { echo "control install resolved 0 skills — nothing to compare against"; return 1; }

    local output status=0
    output=$(PATH="$bindir" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$target" \
        --without-engram --non-interactive 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
        echo "setup.sh exited $status without jq (must install cleanly):"
        printf '%s\n' "$output" | tail -5
        return 1
    fi

    assert_eq "$expected" "$(count_skill_files "$target/.claude/skills")" \
        "a jq-less install must resolve the same skills as a jq-present one" || return 1
    assert_all_skills_installed "$target/.claude/skills" || return 1
    assert_file_exists "$target/.kurama-install-manifest.json" || return 1
    assert_receipt_arrays_match "$control/.kurama-install-manifest.json" \
        "$target/.kurama-install-manifest.json" files tools || return 1
    assert_balanced_kurama_block "$target/CLAUDE.md" || return 1
    return 0
}

test_nojq_setup_opencode_project_installs() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1
    # npm shim inside the farm keeps the opencode dependency step offline, the
    # same guard the other opencode tests use; it has nothing to do with jq.
    make_npm_shim "$bindir"

    # A project-scope opencode install writes its prompt to AGENTS.md but keeps the
    # skills under .claude/skills — same tree as claude-code, so the same path.
    local control="$TEST_TMPDIR/control-repo" target="$TEST_TMPDIR/nojq-repo"
    make_git_repo "$control"
    make_git_repo "$target"
    local shim="$TEST_TMPDIR/npmshim"
    make_npm_shim "$shim"
    PATH="$shim:$PATH" bash "$SETUP_SCRIPT" --agent opencode --scope project --path "$control" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "control (jq present) setup exited non-zero"; return 1; }
    local expected
    expected="$(count_skill_files "$control/.claude/skills")"
    [ "$expected" -gt 0 ] || { echo "control install resolved 0 skills — nothing to compare against"; return 1; }

    local output status=0
    output=$(PATH="$bindir" bash "$SETUP_SCRIPT" --agent opencode --scope project --path "$target" \
        --without-engram --non-interactive 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
        echo "setup.sh exited $status without jq (must install cleanly):"
        printf '%s\n' "$output" | tail -5
        return 1
    fi

    assert_eq "$expected" "$(count_skill_files "$target/.claude/skills")" \
        "a jq-less install must resolve the same skills as a jq-present one" || return 1
    assert_all_skills_installed "$target/.claude/skills" || return 1
    assert_file_exists "$target/.kurama-install-manifest.json" || return 1
    assert_receipt_arrays_match "$control/.kurama-install-manifest.json" \
        "$target/.kurama-install-manifest.json" files tools || return 1
    assert_balanced_kurama_block "$target/AGENTS.md" || return 1
    return 0
}

test_nojq_validate_skills_exits_zero() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local output status=0
    output=$(PATH="$bindir" bash "$VALIDATE_SCRIPT" 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
        echo "validate_skills.sh exited $status without jq (must pass):"
        printf '%s\n' "$output" | grep -a 'FAIL' | head -5
        return 1
    fi
    # An exit 0 that silently validated nothing would be no better than the bug.
    printf '%s\n' "$output" | grep -aq 'skills\[\]' && {
        echo "validate_skills.sh still reports an empty skills[] without jq"; return 1; }
    return 0
}

test_nojq_receipt_parser_ignores_single_line_empty_array() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    # A real receipt from a real install — the parser is driven through the script
    # that drives rm from files[], not reimplemented here.
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "project setup exited non-zero"; return 1; }
    local manifest="$repo/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    # Preconditions the regression needs to be visible: settings[] follows files[]
    # and names a file that is really on disk, so a parser that runs past the empty
    # files[] hands uninstall a live path.
    grep -q '"settings"' "$manifest" || { echo "receipt has no settings[] to leak from"; return 1; }
    grep -q '.claude/settings.json' "$manifest" || { echo "receipt does not record .claude/settings.json"; return 1; }
    assert_file_exists "$repo/.claude/settings.json" || return 1

    collapse_receipt_files_to_empty_array "$manifest"
    grep -q '"files": \[\],' "$manifest" || {
        echo "the receipt was not mutated to a single-line empty files[]"; return 1; }

    local output status=0
    output=$(PATH="$bindir" bash "$UNINSTALL_SCRIPT" --scope project --path "$repo" \
        --dry-run --without-pi-packages 2>&1) || status=$?
    assert_eq "0" "$status" "uninstall --dry-run must exit 0" || return 1

    # files[] is empty, so the parser must yield nothing at all. Before the fix it
    # yielded settings[]'s contents and this line reads
    # "would remove: .claude/settings.json" — the user's settings deleted outright
    # instead of having its kurama hooks block stripped.
    if printf '%s\n' "$output" | grep -aq 'would remove: .claude/settings.json'; then
        echo "the parser leaked settings[] into files[] — uninstall would delete settings.json:"
        printf '%s\n' "$output" | grep -a 'would remove:'
        return 1
    fi
    # The receipt itself is removed by separate code and is not counted here, so an
    # empty files[] must report exactly zero.
    printf '%s\n' "$output" | grep -aqF '0 file(s) would be removed' || {
        echo "an empty files[] must resolve to 0 removals; got:"
        printf '%s\n' "$output" | grep -a 'would remove:\|file(s) would be removed'
        return 1
    }
    return 0
}

# ---------------------------------------------------------------------------
# #31: a jq-less install must be HEALTHY, not merely exit 0.
#
# The four cases above asserted "it installs". None asked the shipped health
# check what it thought of the result — and the answer was a hard FAILURE:
# setup.sh degrades honestly (loud warning, printed manual hook steps, and a
# receipt that records no settings write it never made), then doctor.sh graded
# that same install red over the hooks block setup had deliberately not written.
# One of the two had to be wrong. The verdict: an honest, documented degradation
# is a WARNING carrying its remedy; a receipt that CLAIMS a write which is not
# there stays a hard FAILURE. Both directions are pinned — a doctor that warned
# unconditionally would pass the second case and be useless.
# ---------------------------------------------------------------------------

test_nojq_doctor_grades_the_documented_degradation_a_warning() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1
    local repo="$TEST_TMPDIR/nojq-proj"
    make_git_repo "$repo"

    local status=0
    PATH="$bindir" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 || status=$?
    assert_eq "0" "$status" "a jq-less install must still complete" || return 1

    # Preconditions — this is the honest-degradation shape, not a broken install:
    # the hook scripts really are on disk, no settings.json was written, and the
    # receipt claims neither more nor less than that.
    local manifest="$repo/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    assert_file_exists "$repo/.claude/hooks/kurama/archive-gate.sh" || return 1
    if [ -f "$repo/.claude/settings.json" ]; then
        echo "precondition: a jq-less run must write no settings.json"; return 1
    fi
    if grep -q 'settings.json' "$manifest"; then
        echo "precondition: the receipt must claim no settings write"; return 1
    fi

    local output dstatus=0
    output=$(PATH="$bindir" bash "$DOCTOR_SCRIPT" --scope project --path "$repo" 2>&1) || dstatus=$?
    if [ "$dstatus" -ne 0 ]; then
        echo "doctor exited $dstatus over an install it had no evidence was broken:"
        printf '%s\n' "$output" | grep -a '✗' | head -5
        return 1
    fi
    printf '%s\n' "$output" | grep -aq 'hook scripts present' || {
        echo "doctor never confirmed the hook scripts a jq-less install DOES write"; return 1; }
    # The warning has to carry the way out, or it is just a quieter dead end.
    printf '%s\n' "$output" | grep -aqi 'jq' || {
        echo "the warning never mentions jq — the user cannot tell what degraded"; return 1; }
    printf '%s\n' "$output" | grep -aq 'warning(s)' || {
        echo "the degradation was not reported as a warning at all:"
        printf '%s\n' "$output" | tail -5
        return 1
    }
    return 0
}

test_doctor_fails_when_the_receipt_claims_an_unregistered_hooks_write() {
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    # jq present: setup registers the hooks block AND records the settings.json.
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup claude-code failed"; return 1; }
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    local settings="$HOME/.claude/settings.json"
    grep -q 'settings.json' "$manifest" || {
        echo "precondition: the receipt must record the settings write"; return 1; }
    grep -q 'hooks/kurama/' "$settings" || {
        echo "precondition: setup must have registered the hooks block"; return 1; }

    # The block is gone but the file is not, so check_receipt_files stays green
    # and check_hooks is the only check that can see the problem.
    printf '{}\n' > "$settings"

    local output status=0
    output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" --agent claude-code 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        echo "doctor passed an install whose receipt claims a hooks block that is gone"
        return 1
    fi
    printf '%s\n' "$output" | grep -aq 'hooks block missing' || {
        echo "the failure never names the missing hooks block:"
        printf '%s\n' "$output" | grep -a '✗' | head -5
        return 1
    }
    return 0
}

test_nojq_install_sh_installs_and_is_graded_healthy() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    # install.sh had zero jq-less coverage, and it is the script whose copied awk
    # receipt parsers already shipped two defects.
    local status=0
    PATH="$bindir" bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1 || status=$?
    assert_eq "0" "$status" "install.sh must install without jq" || return 1
    assert_all_skills_installed "$HOME/.claude/skills" || return 1
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1

    # …and the shipped health check must agree. install.sh is the documented
    # skills-only installer (docs/installation.md): it writes no hooks and its
    # receipt claims none, so the absence is honest and grades as a warning.
    local output dstatus=0
    output=$(PATH="$bindir" bash "$DOCTOR_SCRIPT" --agent claude-code 2>&1) || dstatus=$?
    if [ "$dstatus" -ne 0 ]; then
        echo "doctor exited $dstatus over a jq-less install.sh install:"
        printf '%s\n' "$output" | grep -a '✗' | head -5
        return 1
    fi
    printf '%s\n' "$output" | grep -aq 'all .* recorded file(s) present' || {
        echo "doctor never verified the recorded files (no-jq receipt parse?):"
        printf '%s\n' "$output" | head -8
        return 1
    }
    return 0
}

test_nojq_update_sh_resyncs_and_is_graded_healthy() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1
    local repo="$TEST_TMPDIR/nojq-proj"
    make_git_repo "$repo"

    # A full jq-present install first, so the update is re-syncing a target that
    # DOES carry hooks + a registered settings block: any severity change must not
    # be able to hide a real regression behind a blanket warning.
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "control (jq present) setup exited non-zero"; return 1; }
    echo "TAMPERED" > "$repo/.claude/skills/sdd-apply/SKILL.md"

    local status=0
    PATH="$bindir" bash "$UPDATE_SCRIPT" --scope project --path "$repo" > /dev/null 2>&1 || status=$?
    assert_eq "0" "$status" "update.sh must re-sync without jq" || return 1
    if grep -q 'TAMPERED' "$repo/.claude/skills/sdd-apply/SKILL.md"; then
        echo "a jq-less update.sh did not restore the tampered skill"; return 1
    fi
    grep -q 'hooks/kurama/' "$repo/.claude/settings.json" 2>/dev/null || {
        echo "the jq-less update dropped the hooks block the install had registered"; return 1; }

    local output dstatus=0
    output=$(PATH="$bindir" bash "$DOCTOR_SCRIPT" --scope project --path "$repo" 2>&1) || dstatus=$?
    if [ "$dstatus" -ne 0 ]; then
        echo "doctor exited $dstatus after a jq-less update.sh re-sync:"
        printf '%s\n' "$output" | grep -a '✗' | head -5
        return 1
    fi
    return 0
}

# ============================================================================
# Tests — installer correctness (#20 ghost installs, #21 empty-jq blanking,
# #24 install.sh receipt/flag defects)
#
# The shared question behind this section: when a step fails halfway, does the
# installer leave the machine in a state the shipped tooling can still see and
# reverse? Files on disk with no receipt (a "ghost install"), a config blanked by
# an empty jq result, or a truncated receipt all answer "no" — and all three
# looked like a successful install from the console.
# ============================================================================

# A settings.json the user broke by hand (trailing comma). jq refuses it, so the
# hooks merge must fail — what setup does *next* is what these cases assert.
write_broken_settings_json() {
    local file="$1"
    mkdir -p "$(dirname "$file")"
    printf '{\n  "model": "opus",\n}\n' > "$file"
}

test_setup_survives_hooks_merge_failure() {
    write_broken_settings_json "$HOME/.claude/settings.json"
    local output status=0
    output=$(bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive 2>&1) || status=$?
    assert_eq "0" "$status" "a failed hooks merge must not abort an otherwise-good install" || return 1
    assert_all_skills_installed "$HOME/.claude/skills" || return 1

    # The receipt exists and records what really landed — the ghost-install fix.
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    grep -q 'sdd-apply/SKILL.md' "$manifest" || { echo "receipt does not record the installed skills"; return 1; }

    # The unparseable file is the user's: left byte-for-byte alone …
    grep -q '"model": "opus",' "$HOME/.claude/settings.json" || {
        echo "setup rewrote the settings.json it could not parse"; return 1; }
    # … and never claimed in the receipt, which would send uninstall after a file
    # Kurama never touched.
    if grep -q 'settings.json' "$manifest"; then
        echo "receipt claims a settings.json that was never merged"; return 1
    fi
    printf '%s\n' "$output" | grep -q 'hooks not registered' || {
        echo "the failure was never reported to the user"; return 1; }
    return 0
}

test_setup_eof_stdin_leaves_no_ghost_install() {
    local shim="$TEST_TMPDIR/npmshim"
    make_npm_shim "$shim"
    # No --non-interactive: the prompts run and hit EOF immediately, which used to
    # kill the script under `set -e` after the skills were already on disk.
    local status=0
    PATH="$shim:$PATH" bash "$SETUP_SCRIPT" --agent opencode --without-engram \
        < /dev/null > /dev/null 2>&1 || status=$?
    assert_eq "0" "$status" "closed stdin must fall back to the prompt defaults, not abort" || return 1
    assert_all_skills_installed "$HOME/.config/opencode/skills" || return 1
    assert_file_exists "$HOME/.config/opencode/skills/.kurama-install-manifest.json" || return 1
    return 0
}

test_setup_unparseable_opencode_json_is_controlled() {
    local cfg="$HOME/.config/opencode/opencode.json"
    mkdir -p "$(dirname "$cfg")"
    printf '{\n  // a JSONC comment opencode tolerates and jq does not\n  "theme": "kurama"\n}\n' > "$cfg"
    local before output status=0
    before="$(cat "$cfg")"
    output=$(bash "$SETUP_SCRIPT" --agent opencode --without-engram --non-interactive 2>&1) || status=$?

    # A Kurama-controlled exit with an explanation, not jq's own status (5) leaking
    # out of the installer with jq's raw parse error as the only clue.
    assert_eq "1" "$status" "setup must exit 1; jq's exit code must not become the installer's" || return 1
    printf '%s\n' "$output" | grep -q 'opencode.json' || { echo "no message naming the offending file"; return 1; }
    assert_eq "$before" "$(cat "$cfg")" "the config it cannot parse must be left unchanged" || return 1

    # And whatever landed before the abort is recorded, so it can be removed.
    local manifest="$HOME/.config/opencode/skills/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    grep -q 'sdd-apply/SKILL.md' "$manifest" || {
        echo "ghost install: skills on disk, nothing in the receipt"; return 1; }
    return 0
}

test_nojq_receipt_omits_unwritten_settings() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1
    local repo="$TEST_TMPDIR/nojq-proj"
    make_git_repo "$repo"

    local status=0
    PATH="$bindir" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 || status=$?
    assert_eq "0" "$status" "a jq-less install must still complete" || return 1

    local manifest="$repo/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    # Without jq the hooks block is printed as manual steps and nothing is written,
    # so nothing may be recorded either.
    #
    # Forward guard, not a co-assertion: no jq-less path writes a settings.json
    # today, so this cannot fail on the current tree. It is here so that a future
    # "write it with sed/awk when jq is missing" shortcut trips a test instead of
    # silently editing user JSON with a line editor.
    if [ -f "$repo/.claude/settings.json" ]; then
        echo "jq-less run wrote a settings.json it has no parser for"; return 1
    fi
    if grep -q 'settings.json' "$manifest"; then
        echo "receipt records a settings.json that was never written"; return 1
    fi
    return 0
}

test_setup_empty_settings_json_not_blanked() {
    # A realistic state: fresh machine, or a config the user cleared.
    mkdir -p "$HOME/.claude"
    : > "$HOME/.claude/settings.json"
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup exited non-zero"; return 1; }
    local settings="$HOME/.claude/settings.json"
    jq -e . "$settings" > /dev/null 2>&1 || {
        echo "settings.json is not valid JSON after the merge ($(wc -c < "$settings" | tr -d ' ') bytes)"; return 1; }
    grep -q 'hooks/kurama/' "$settings" || {
        echo "the log claimed a merge but no kurama hooks are registered"; return 1; }
    return 0
}

test_setup_empty_opencode_json_not_blanked() {
    local cfg="$HOME/.config/opencode/opencode.json"
    mkdir -p "$(dirname "$cfg")"
    : > "$cfg"
    run_setup_opencode || { echo "setup opencode exited non-zero"; return 1; }
    jq -e . "$cfg" > /dev/null 2>&1 || {
        echo "opencode.json is not valid JSON after the merge ($(wc -c < "$cfg" | tr -d ' ') bytes)"; return 1; }
    # Mode-agnostic: single mode registers sdd-orchestrator, multi one agent per
    # phase. Either way, zero sdd-* agents means /sdd-* silently stops working.
    jq -e '[.agent | keys[] | select(startswith("sdd-"))] | length > 0' "$cfg" > /dev/null 2>&1 || {
        echo "no sdd-* agents registered — /sdd-* commands would silently stop working"; return 1; }
    return 0
}

test_setup_empty_claude_json_engram_not_blanked() {
    local bindir="$TEST_TMPDIR/engrambin" log="$TEST_TMPDIR/engram-calls.log"
    make_engram_shims "$bindir" "$log"
    : > "$HOME/.claude.json"
    PATH="$bindir:$PATH" bash "$SETUP_SCRIPT" --agent claude-code --with-engram --non-interactive \
        > /dev/null 2>&1 || { echo "engram setup exited non-zero"; return 1; }
    jq -e . "$HOME/.claude.json" > /dev/null 2>&1 || { echo ".claude.json was blanked by the merge"; return 1; }
    jq -e '.mcpServers.engram' "$HOME/.claude.json" > /dev/null 2>&1 || {
        echo "the Engram server was reported registered but is not in the file"; return 1; }
    return 0
}

test_install_refuses_setup_managed_receipt() {
    # #38/#24: install.sh no longer REFUSES a target setup.sh manages — it IS setup.sh
    # now (delegation), so re-running install.sh over a setup install RE-SYNCS it
    # cleanly through the single writer. The richer receipt (tools[], settings[], hook
    # file entries) must survive — install.sh must never truncate it (the #24 bug).
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup exited non-zero"; return 1; }
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    grep -q '"settings"' "$manifest" || { echo "premise: setup receipt lacks settings[]"; return 1; }

    local output status=0
    output=$(bash "$INSTALL_SCRIPT" --agent claude-code 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
        echo "install.sh (wrapper) must re-sync a setup-managed target, not fail (exit $status)"
        printf '%s\n' "$output" | awk '{ print "    " $0 }'
        return 1
    fi
    # setup-only keys install.sh used to truncate survive — one coherent receipt.
    grep -q '"settings"' "$manifest" || { echo "settings[] lost — the wrapper truncated the receipt (#24 regressed)"; return 1; }
    grep -q 'hooks/kurama/archive-gate.sh' "$manifest" || { echo "hook file entries lost"; return 1; }
    grep -q '"tools"' "$manifest" || { echo "tools[] lost"; return 1; }
    grep -q '"tool"[[:space:]]*:[[:space:]]*"claude-code"' "$manifest" || {
        echo "receipt tool is not the setup.sh slug 'claude-code'"; return 1; }
    return 0
}

test_install_refuse_writes_nothing_for_opencode() {
    # #38: install.sh no longer refuses a setup-managed OpenCode target — it delegates
    # to setup.sh, the sole owner of the /sdd-* command files and the receipt. Re-running
    # install.sh over a setup opencode install must RE-SYNC it cleanly (exit 0, the 9
    # commands present, one coherent receipt), not refuse it.
    run_setup_opencode || { echo "setup opencode exited non-zero"; return 1; }
    local cmd_dir="$HOME/.config/opencode/commands"
    local before_count
    before_count=$(find "$cmd_dir" -name 'sdd-*.md' | wc -l | tr -d ' ')
    [ "$before_count" -gt 0 ] || { echo "setup installed no commands — nothing to re-sync"; return 1; }

    local status=0
    bash "$INSTALL_SCRIPT" --agent opencode > /dev/null 2>&1 || status=$?
    if [ "$status" -ne 0 ]; then echo "install.sh must re-sync the opencode target, not refuse it (exit $status)"; return 1; fi

    local after_count
    after_count=$(find "$cmd_dir" -name 'sdd-*.md' | wc -l | tr -d ' ')
    assert_eq "9" "$after_count" "the delegated re-sync keeps the 9 OpenCode commands" || return 1
    local manifest="$HOME/.config/opencode/skills/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    grep -q '"tool"[[:space:]]*:[[:space:]]*"opencode"' "$manifest" || {
        echo "opencode receipt tool wrong after re-sync"; return 1; }
    return 0
}

test_install_without_group_removes_excluded_skills() {
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1 || { echo "first install failed"; return 1; }
    assert_dir_exists "$HOME/.claude/skills/review-risk" || return 1

    bash "$INSTALL_SCRIPT" --agent claude-code --without review > /dev/null 2>&1 \
        || { echo "re-install with --without review failed"; return 1; }
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    if grep -q 'review-risk' "$manifest"; then echo "receipt still lists the excluded skill"; return 1; fi
    # Dropping it from the receipt without removing it is the bug: the skill keeps
    # loading in the agent while nothing records it.
    if [ -e "$HOME/.claude/skills/review-risk/SKILL.md" ]; then
        echo "excluded skill left on disk and now unmanaged: review-risk/SKILL.md"; return 1
    fi
    assert_file_exists "$HOME/.claude/skills/sdd-apply/SKILL.md" || return 1
    return 0
}

test_install_incomplete_checkout_aborts_early() {
    # #38: install.sh is a wrapper — a checkout missing the real installer (setup.sh)
    # must abort loudly and write nothing, not silently do nothing. (The examples/
    # completeness check now lives in setup.sh, the sole installer — enforced there
    # and pinned by test_g_setup_missing_examples_fails_loud_before_write; this test
    # pins the wrapper's own delegate-present guard.)
    local fake="$TEST_TMPDIR/partial-repo"
    mkdir -p "$fake/scripts"
    cp "$INSTALL_SCRIPT" "$fake/scripts/install.sh"
    # install.sh sources scripts/lib/receipt.sh (issue #37); ship it so the abort
    # under test is the missing setup.sh, not the missing lib.
    cp -R "$SCRIPT_DIR/lib" "$fake/scripts/lib"
    ln -s "$REPO_DIR/skills" "$fake/skills"
    cp "$REPO_DIR/VERSION" "$fake/VERSION"
    # Deliberately DO NOT copy setup.sh — the delegate is absent.

    local output status=0
    output=$(bash "$fake/scripts/install.sh" --agent all-global 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then echo "install.sh reported success with no setup.sh present"; return 1; fi
    printf '%s\n' "$output" | grep -q 'setup.sh' || {
        echo "the abort never names the missing setup.sh"; printf '%s\n' "$output" | tail -3; return 1; }
    # It aborts up front, before delegating to anything.
    if [ -d "$HOME/.claude/skills" ]; then echo "targets were written before the abort"; return 1; fi
    return 0
}

test_install_flag_without_value_shows_usage() {
    local output status=0
    output=$(bash "$INSTALL_SCRIPT" --agent 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then echo "a valueless --agent must not exit 0"; return 1; fi
    if printf '%s\n' "$output" | grep -q 'unbound variable'; then
        echo "raw bash error leaked instead of a usage message:"
        printf '%s\n' "$output" | tail -3
        return 1
    fi
    printf '%s\n' "$output" | grep -qi 'usage' || { echo "no usage message"; return 1; }
    return 0
}

test_setup_flag_without_value_shows_usage() {
    local output status=0
    output=$(bash "$SETUP_SCRIPT" --agent 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then echo "a valueless --agent must not exit 0"; return 1; fi
    if printf '%s\n' "$output" | grep -q 'unbound variable'; then
        echo "raw bash error leaked instead of a usage message:"
        printf '%s\n' "$output" | tail -3
        return 1
    fi
    printf '%s\n' "$output" | grep -qi 'missing value' || { echo "no 'missing value' message"; return 1; }
    return 0
}

# ============================================================================
# Tests — #22: the OpenCode install is fully recorded in the receipt
#
# setup_opencode wrote four things no receipt mentioned: the nine /sdd-* command
# files, the global AGENTS.md, the sdd-* block of opencode.json, and the resolved
# mode/profile. The two maintenance paths then lied about the result — update
# re-ran setup with neither mode nor profile (a multi+profile install collapsed
# from 20 agents to 1 while printing "no recorded file changed"), and uninstall
# reported "Done." with all twelve files still on disk.
# ============================================================================

OPENCODE_RECEIPT_REL="skills/.kurama-install-manifest.json"

test_opencode_receipt_records_commands_prompt_and_config() {
    run_setup_opencode --opencode-mode multi || { echo "setup opencode multi failed"; return 1; }
    local manifest="$HOME/.config/opencode/$OPENCODE_RECEIPT_REL"
    assert_file_exists "$manifest" || return 1

    # The nine command files carry Kurama-owned names and Kurama-owned content →
    # files[], the array uninstall removes outright.
    local n
    n=$(receipt_array_values "$manifest" "files" | grep -c 'commands/sdd-.*\.md' || true)
    assert_eq "9" "$n" "the receipt must record all nine OpenCode command files" || return 1

    # AGENTS.md is a SHARED prompt file: recorded in prompts[] so uninstall strips
    # our block instead of deleting a file the user may also write in.
    receipt_array_values "$manifest" "prompts" | grep -q 'AGENTS\.md' || {
        echo "the receipt does not record the OpenCode orchestrator prompt"; return 1; }

    # opencode.json is the user's config we merge into → its own array, whose
    # reversal is "strip Kurama's agents", never rm.
    receipt_array_values "$manifest" "opencode_configs" | grep -q 'opencode\.json' || {
        echo "the receipt does not record opencode.json"; return 1; }

    # And it must NOT be in files[]: that would make uninstall delete the whole
    # config, taking every agent the user defined with it.
    if receipt_array_values "$manifest" "files" | grep -q 'opencode\.json'; then
        echo "opencode.json is recorded in files[] — uninstall would delete the user's config"; return 1
    fi
    return 0
}

test_opencode_receipt_records_mode_and_profile() {
    run_setup_opencode --opencode-mode multi --opencode-profile testp:prov/model \
        || { echo "setup opencode multi+profile failed"; return 1; }
    local manifest="$HOME/.config/opencode/$OPENCODE_RECEIPT_REL"
    grep -q '"opencode_mode": "multi"' "$manifest" || {
        echo "the resolved --opencode-mode is not recorded"; return 1; }
    grep -q '"opencode_profile": "testp"' "$manifest" || {
        echo "the resolved --opencode-profile is not recorded"; return 1; }
    grep -q '"opencode_profile_model": "prov/model"' "$manifest" || {
        echo "the profile model is not recorded"; return 1; }
    return 0
}

test_setup_receipt_omits_opencode_keys_for_other_agents() {
    # The keys are per-target, not global state: a claude-code receipt that
    # carried them would make update.sh re-pass an OpenCode mode to a harness
    # that has none.
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup claude-code failed"; return 1; }
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    if grep -q 'opencode_mode' "$manifest"; then
        echo "a claude-code receipt records an OpenCode mode"; return 1
    fi
    return 0
}

test_update_preserves_opencode_mode_and_profile() {
    run_setup_opencode --opencode-mode multi --opencode-profile testp:prov/model \
        || { echo "setup opencode multi+profile failed"; return 1; }
    local cfg="$HOME/.config/opencode/opencode.json"
    local before
    before=$(jq -r '[.agent | keys[]] | length' "$cfg")
    [ "$before" -ge 19 ] || { echo "precondition: expected the multi+profile agent set, got $before"; return 1; }
    # Multi mode also rewrites each subtask command's `agent:` line — the other
    # half of the install a mode-less re-sync silently reverted.
    grep -q '^agent: sdd-apply$' "$HOME/.config/opencode/commands/sdd-apply.md" || {
        echo "precondition: multi-mode command routing missing"; return 1; }

    bash "$UPDATE_SCRIPT" --agent opencode > /dev/null 2>&1 || { echo "update.sh failed"; return 1; }

    assert_eq "$before" "$(jq -r '[.agent | keys[]] | length' "$cfg")" \
        "the re-sync dropped agents (mode/profile not carried over)" || return 1
    jq -e '.agent["sdd-apply-testp"]' "$cfg" > /dev/null 2>&1 || {
        echo "the profile's suffixed subagents did not survive the re-sync"; return 1; }
    jq -e '.agent["kurama-orchestrator"]' "$cfg" > /dev/null 2>&1 || {
        echo "the profile orchestrator did not survive the re-sync"; return 1; }
    grep -q '^agent: sdd-apply$' "$HOME/.config/opencode/commands/sdd-apply.md" || {
        echo "the re-sync reverted the multi-mode command routing"; return 1; }
    return 0
}

test_update_preserves_hand_edited_profile_model() {
    # The recorded model documents the install-time choice; update deliberately
    # re-passes the profile in its BARE form, because "NAME:provider/model" is
    # documented as overriding hand edits — an update must not revert them.
    run_setup_opencode --opencode-mode multi --opencode-profile testp:prov/model \
        || { echo "setup opencode multi+profile failed"; return 1; }
    local cfg="$HOME/.config/opencode/opencode.json"
    local edited
    edited=$(jq '.agent["sdd-apply-testp"].model = "HAND/EDITED"' "$cfg")
    printf '%s\n' "$edited" > "$cfg"

    bash "$UPDATE_SCRIPT" --agent opencode > /dev/null 2>&1 || { echo "update.sh failed"; return 1; }
    assert_eq "HAND/EDITED" "$(jq -r '.agent["sdd-apply-testp"].model' "$cfg")" \
        "update.sh reverted a hand-edited profile model" || return 1
    return 0
}

test_update_refuses_opencode_receipt_without_mode() {
    run_setup_opencode --opencode-mode multi || { echo "setup opencode multi failed"; return 1; }
    local manifest="$HOME/.config/opencode/$OPENCODE_RECEIPT_REL"
    local cfg="$HOME/.config/opencode/opencode.json"
    # Every receipt written before #22 (and every install.sh receipt) looks like
    # this: OpenCode recorded, mode not.
    local stripped
    stripped=$(grep -v '"opencode_mode"' "$manifest")
    printf '%s\n' "$stripped" > "$manifest"
    local before
    before=$(jq -cS '.agent' "$cfg")

    local output status=0
    output=$(bash "$UPDATE_SCRIPT" --agent opencode 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        echo "update.sh re-synced OpenCode with no recorded mode (silent downgrade)"; return 1
    fi
    printf '%s\n' "$output" | grep -q -- '--opencode-mode' || {
        echo "the refusal never says how to make the target re-syncable"; return 1; }
    assert_eq "$before" "$(jq -cS '.agent' "$cfg")" \
        "a refused re-sync must leave opencode.json byte-identical" || return 1
    return 0
}

test_update_refusal_does_not_abort_the_other_targets() {
    # A refusal is about ONE receipt. Under `set -euo pipefail` the bare
    # resync_target call let that `return 1` kill the whole run, so every target
    # QUEUED BEHIND the mode-less OpenCode receipt (codex, pi, omp — ALL_AGENTS
    # order puts opencode second) was never touched and the run ended with no
    # summary. install.sh already skips-and-continues; update must match.
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup claude-code failed"; return 1; }
    run_setup_opencode --opencode-mode multi || { echo "setup opencode multi failed"; return 1; }
    bash "$SETUP_SCRIPT" --agent codex --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup codex failed"; return 1; }

    # Make the OpenCode receipt mode-less: every pre-#22 receipt looks like this.
    local manifest="$HOME/.config/opencode/$OPENCODE_RECEIPT_REL"
    local stripped
    stripped=$(grep -v '"opencode_mode"' "$manifest")
    printf '%s\n' "$stripped" > "$manifest"

    # Drift a recorded file in the target queued AFTER opencode: only a re-sync
    # that actually reached codex restores it.
    local codex_skill="$HOME/.codex/skills/sdd-apply/SKILL.md"
    assert_file_exists "$codex_skill" || return 1
    printf 'clobbered\n' > "$codex_skill"

    local output status=0
    output=$(bash "$UPDATE_SCRIPT" 2>&1) || status=$?

    # The refused target still makes the run fail — silence would hide it.
    if [ "$status" -eq 0 ]; then
        echo "a refused target must still make the run exit non-zero"; return 1
    fi
    # ...but the targets behind it were updated anyway.
    if grep -q '^clobbered$' "$codex_skill"; then
        echo "codex was never re-synced — the OpenCode refusal aborted the loop"; return 1
    fi
    # ...and the run closes with an honest summary naming the skipped target.
    printf '%s\n' "$output" | grep -q 'Not updated' || {
        echo "the run printed no end-of-run summary of the skipped target(s)"; return 1; }
    printf '%s\n' "$output" | grep -qi 'opencode' || {
        echo "the summary never names the refused target"; return 1; }
    printf '%s\n' "$output" | grep -q -- '--opencode-mode' || {
        echo "the summary never states the remedy"; return 1; }
    return 0
}

test_uninstall_removes_every_opencode_artifact() {
    run_setup_opencode --opencode-mode multi --opencode-profile testp \
        || { echo "setup opencode multi+profile failed"; return 1; }
    local cfg="$HOME/.config/opencode/opencode.json"
    # A user-defined agent that must survive the removal.
    local with_own
    with_own=$(jq '.agent["my-own"] = {"mode":"subagent"}' "$cfg")
    printf '%s\n' "$with_own" > "$cfg"

    bash "$UNINSTALL_SCRIPT" --agent opencode --without-pi-packages > /dev/null 2>&1

    local left
    left=$(count_matching_files "$HOME/.config/opencode/commands" 'sdd-*.md')
    assert_eq "0" "$left" "the nine /sdd-* command files survived the uninstall" || return 1

    local agents_md="$HOME/.config/opencode/AGENTS.md"
    if [ -f "$agents_md" ] && grep -q 'Kurama Orchestrator' "$agents_md"; then
        echo "the orchestrator prompt survived the uninstall"; return 1
    fi

    local n
    n=$(jq -r '[(.agent // {}) | keys[] | select(startswith("sdd-") or . == "kurama-orchestrator")] | length' "$cfg")
    assert_eq "0" "$n" "opencode.json still routes to sdd-* agents that no longer exist" || return 1
    jq -e '.agent["my-own"]' "$cfg" > /dev/null 2>&1 || {
        echo "the uninstall removed a user-defined agent"; return 1; }
    return 0
}

test_uninstall_sweeps_legacy_opencode_artifacts() {
    run_setup_opencode --opencode-mode multi || { echo "setup opencode multi failed"; return 1; }
    local manifest="$HOME/.config/opencode/$OPENCODE_RECEIPT_REL"
    # Rewrite the receipt into its pre-#22 shape — no command entries, no
    # prompts[], no opencode_configs[] — which is what every OpenCode install
    # already on a user's machine looks like.
    local legacy
    legacy=$(jq '.files = [.files[] | select(test("commands/sdd-") | not)]
                 | .prompts = [] | .opencode_configs = []' "$manifest")
    printf '%s\n' "$legacy" > "$manifest"
    # …and the AGENTS.md that install wrote: the example copied whole, no markers.
    cp "$REPO_DIR/examples/opencode/AGENTS.md" "$HOME/.config/opencode/AGENTS.md"

    bash "$UNINSTALL_SCRIPT" --agent opencode --without-pi-packages > /dev/null 2>&1

    local left
    left=$(count_matching_files "$HOME/.config/opencode/commands" 'sdd-*.md')
    assert_eq "0" "$left" "legacy receipt: the /sdd-* commands were left behind" || return 1
    if [ -f "$HOME/.config/opencode/AGENTS.md" ]; then
        echo "legacy receipt: the wholesale AGENTS.md was left behind"; return 1
    fi
    local n
    n=$(jq -r '[(.agent // {}) | keys[] | select(startswith("sdd-"))] | length' \
        "$HOME/.config/opencode/opencode.json")
    assert_eq "0" "$n" "legacy receipt: opencode.json still routes to sdd-* agents" || return 1
    return 0
}

test_uninstall_leaves_foreign_agents_md_alone() {
    # The sweep may only delete an AGENTS.md Kurama wrote every byte of. A file
    # the user owns is reported, never removed.
    run_setup_opencode --opencode-mode single || { echo "setup opencode failed"; return 1; }
    local manifest="$HOME/.config/opencode/$OPENCODE_RECEIPT_REL"
    local legacy
    legacy=$(jq '.prompts = []' "$manifest")
    printf '%s\n' "$legacy" > "$manifest"
    printf '# My own AGENTS.md\n\nMy notes.\n' > "$HOME/.config/opencode/AGENTS.md"

    bash "$UNINSTALL_SCRIPT" --agent opencode --without-pi-packages > /dev/null 2>&1
    grep -q 'My notes' "$HOME/.config/opencode/AGENTS.md" 2>/dev/null || {
        echo "the uninstall deleted a user-written AGENTS.md"; return 1; }
    return 0
}

test_uninstall_claude_code_never_touches_opencode() {
    # The sweep is gated on the receipt recording opencode. Without that gate,
    # removing claude-code would reach into ~/.config/opencode.
    run_setup_opencode --opencode-mode multi || { echo "setup opencode failed"; return 1; }
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup claude-code failed"; return 1; }
    bash "$UNINSTALL_SCRIPT" --agent claude-code --without-pi-packages > /dev/null 2>&1

    local left
    left=$(count_matching_files "$HOME/.config/opencode/commands" 'sdd-*.md')
    assert_eq "9" "$left" "uninstalling claude-code removed OpenCode's command files" || return 1
    jq -e '[(.agent // {}) | keys[] | select(startswith("sdd-"))] | length > 0' \
        "$HOME/.config/opencode/opencode.json" > /dev/null 2>&1 || {
        echo "uninstalling claude-code stripped OpenCode's agents"; return 1; }
    return 0
}

# A pre-marker prompt file: the generated example copied whole, exactly as the
# old wholesale `cp` (and the manual-install docs) leave it — plus a sentinel so
# "was this file rewritten or only warned about?" is answered by content, not by
# timestamps.
write_pre_marker_prompt_copy() {
    local example="$1" target="$2"
    mkdir -p "$(dirname "$target")"
    cp "$example" "$target"
    printf '\nSTALE-SENTINEL-FROM-AN-OLDER-RELEASE\n' >> "$target"
}

test_setup_remerges_a_pre_marker_prompt_copy() {
    # C1: every OpenCode install written before the marker merge has an
    # unmarked AGENTS.md whose body contains "## Kurama Orchestrator" — one of
    # ORCHESTRATOR_HEADINGS. setup_orchestrator's already_present branch warns
    # and writes NOTHING, so the prompt is frozen: no markers ever appear,
    # content is never refreshed, doctor keeps telling the user to re-run setup,
    # and update keeps reporting "no recorded file changed".
    run_setup_opencode --opencode-mode single || { echo "setup opencode failed"; return 1; }
    local prompt="$HOME/.config/opencode/AGENTS.md"
    write_pre_marker_prompt_copy "$REPO_DIR/examples/opencode/AGENTS.md" "$prompt"
    local before
    before=$(grep -cF 'BEGIN:kurama' "$prompt" || true)
    assert_eq "0" "$before" "precondition: the pre-marker copy must carry no markers" || return 1

    run_setup_opencode --opencode-mode single || { echo "setup opencode re-run failed"; return 1; }

    local b e
    b=$(grep -cF 'BEGIN:kurama' "$prompt" || true)
    e=$(grep -cF 'END:kurama' "$prompt" || true)
    assert_eq "1" "$b" "the re-run did not add a BEGIN marker to the pre-marker copy" || return 1
    assert_eq "1" "$e" "the re-run did not add an END marker to the pre-marker copy" || return 1
    # Rewritten, not appended to: the stale content is gone …
    if grep -q 'STALE-SENTINEL' "$prompt"; then
        echo "the re-run left the stale content in place (append, not refresh)"; return 1
    fi
    # … and the fresh orchestrator content is there.
    grep -qF '## Kurama Orchestrator' "$prompt" || {
        echo "the refreshed prompt lost the orchestrator content"; return 1; }
    # The old file is recoverable.
    local baks
    baks=$(find "$(dirname "$prompt")" -name 'AGENTS.md.bak.*' | wc -l | tr -d ' ')
    [ "$baks" -ge 1 ] || { echo "the rewrite kept no backup of the pre-marker file"; return 1; }
    return 0
}

test_setup_remerges_a_pre_marker_claude_prompt_copy() {
    # The same shape on a second harness: the fingerprint is build-examples'
    # GENERATED banner, which only Kurama writes, so the re-merge is generic
    # rather than an OpenCode special case.
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup claude-code failed"; return 1; }
    local prompt="$HOME/.claude/CLAUDE.md"
    write_pre_marker_prompt_copy "$REPO_DIR/examples/claude-code/CLAUDE.md" "$prompt"
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup claude-code re-run failed"; return 1; }

    local b
    b=$(grep -cF 'BEGIN:kurama' "$prompt" || true)
    assert_eq "1" "$b" "a pre-marker CLAUDE.md copy was not re-merged with markers" || return 1
    if grep -q 'STALE-SENTINEL' "$prompt"; then
        echo "the re-run left the stale content in place"; return 1
    fi
    return 0
}

test_setup_leaves_a_user_written_prompt_warn_only() {
    # The other side of the fingerprint: a file the USER wrote (no GENERATED
    # banner) keeps the warn-only behavior — setup must never rewrite it.
    run_setup_opencode --opencode-mode single || { echo "setup opencode failed"; return 1; }
    local prompt="$HOME/.config/opencode/AGENTS.md"
    printf '# My own AGENTS.md\n\n## Kurama Orchestrator\n\nmy hand-written notes\n' > "$prompt"

    local shim="$TEST_TMPDIR/npmshim"
    make_npm_shim "$shim"
    local output
    output=$(PATH="$shim:$PATH" bash "$SETUP_SCRIPT" --agent opencode --without-engram \
        --non-interactive --opencode-mode single 2>&1) \
        || { echo "setup opencode re-run failed"; return 1; }

    grep -q 'my hand-written notes' "$prompt" || {
        echo "setup rewrote a user-written prompt file"; return 1; }
    local b
    b=$(grep -cF 'BEGIN:kurama' "$prompt" || true)
    assert_eq "0" "$b" "setup marker-merged a file it does not own" || return 1
    printf '%s\n' "$output" | grep -q 'already present' || {
        echo "setup never reported that it left the file alone"; return 1; }
    return 0
}

# ============================================================================
# Tests — #23: doctor verdicts it actually verified
#
# Three independent false verdicts: an orphan scan that only ran when NOT ONE of
# the five harnesses had a receipt (and only looked at claude-code paths), a
# display-name receipt that skipped every path-derived check in silence, and a
# marker check that flagged every healthy OpenCode install as unmerged.
# ============================================================================

test_doctor_orphan_scan_runs_per_agent() {
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup claude-code failed"; return 1; }
    run_setup_opencode --opencode-mode single || { echo "setup opencode failed"; return 1; }
    # claude-code loses its receipt while opencode keeps one — the exact shape
    # that used to skip the orphan scan entirely and exit 0 "Healthy".
    rm -f "$HOME/.claude/skills/.kurama-install-manifest.json"

    local output status=0
    output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        echo "doctor was green over a fully wired claude-code install with no receipt"; return 1
    fi
    printf '%s\n' "$output" | grep -q 'no install receipt' || {
        echo "the orphaned claude-code artifacts are never named"; return 1; }
    printf '%s\n' "$output" | grep -q 'hooks/kurama with no install receipt' || {
        echo "the orphaned hooks are never reported"; return 1; }
    printf '%s\n' "$output" | grep -q 'Diagnosing opencode' || {
        echo "the receipt-backed opencode target was not diagnosed"; return 1; }
    return 0
}

test_doctor_orphan_scan_covers_opencode() {
    # The scan used to inspect claude-code paths only, so an orphaned OpenCode
    # install (commands + agents in opencode.json) was invisible.
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    run_setup_opencode --opencode-mode multi || { echo "setup opencode failed"; return 1; }
    rm -f "$HOME/.config/opencode/$OPENCODE_RECEIPT_REL"

    local output status=0
    output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        echo "doctor was green over an orphaned OpenCode install"; return 1
    fi
    printf '%s\n' "$output" | grep -q 'Kurama command(s)' || {
        echo "the orphaned /sdd-* commands are never named"; return 1; }
    printf '%s\n' "$output" | grep -q 'opencode.json still registers' || {
        echo "the orphaned opencode.json agents are never named"; return 1; }
    return 0
}

test_doctor_normalizes_display_name_receipt() {
    # install.sh records the DISPLAY name ("Claude Code"); doctor used it
    # verbatim, resolved every path to empty, and skipped the marker and hooks
    # checks without a word.
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup claude-code failed"; return 1; }
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    local renamed
    renamed=$(sed -e 's/"tool": "claude-code"/"tool": "Claude Code"/' \
                  -e 's/^    "claude-code"/    "Claude Code"/' "$manifest")
    printf '%s\n' "$renamed" > "$manifest"
    # Break something ONLY a path-derived check can see (the recorded files are
    # all still on disk, so check_receipt_files stays green).
    printf '{}\n' > "$HOME/.claude/settings.json"

    local output status=0
    output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" --agent claude-code 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        echo "doctor passed an install with no hooks block (display-name receipt)"; return 1
    fi
    printf '%s\n' "$output" | grep -q 'hooks block missing' || {
        echo "the hooks check never ran for a display-name receipt"; return 1; }
    printf '%s\n' "$output" | grep -q 'markers balanced' || {
        echo "the marker check never ran for a display-name receipt"; return 1; }
    return 0
}

test_doctor_unresolvable_tool_is_hard_fail() {
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup claude-code failed"; return 1; }
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    # A receipt from one of the dropped harnesses: no path can be resolved from
    # it, so there is nothing doctor can honestly verify.
    local renamed
    renamed=$(sed -e 's/"tool": "claude-code"/"tool": "gemini-cli"/' \
                  -e 's/^    "claude-code"/    "gemini-cli"/' "$manifest")
    printf '%s\n' "$renamed" > "$manifest"

    local output status=0
    output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" --agent claude-code 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        echo "a receipt naming a dropped harness was diagnosed as healthy"; return 1
    fi
    printf '%s\n' "$output" | grep -q 'gemini-cli' || {
        echo "the unrecognized tool is never named"; return 1; }
    return 0
}

test_doctor_green_on_healthy_opencode() {
    # The inverse false verdict: global opencode's AGENTS.md is now marker-merged
    # like every other harness, so a correct install must be green.
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    run_setup_opencode --opencode-mode multi || { echo "setup opencode failed"; return 1; }

    local output status=0
    output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" --agent opencode 2>&1) || status=$?
    if printf '%s\n' "$output" | grep -q 'orchestrator not merged'; then
        echo "a healthy OpenCode install is still flagged as unmerged"; return 1
    fi
    printf '%s\n' "$output" | grep -q 'markers balanced' || {
        echo "the OpenCode orchestrator block carries no markers"; return 1; }
    assert_eq "0" "$status" "doctor must be green on a fresh, correct OpenCode install" || return 1
    return 0
}

test_doctor_unmarked_orchestrator_is_recognized_by_content() {
    # A pre-marker OpenCode install (AGENTS.md copied whole) is healthy, not
    # unmerged — doctor must say so by content instead of warning.
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    run_setup_opencode --opencode-mode single || { echo "setup opencode failed"; return 1; }
    cp "$REPO_DIR/examples/opencode/AGENTS.md" "$HOME/.config/opencode/AGENTS.md"

    local output status=0
    output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" --agent opencode 2>&1) || status=$?
    if printf '%s\n' "$output" | grep -q 'orchestrator not merged'; then
        echo "a pre-marker OpenCode install is reported as unmerged"; return 1
    fi
    printf '%s\n' "$output" | grep -q 'present but unmarked' || {
        echo "doctor does not report the unmarked orchestrator honestly"; return 1; }
    assert_eq "0" "$status" "a pre-marker install is not a failure" || return 1
    return 0
}

test_doctor_project_orphans_are_not_double_reported() {
    # I1: in project scope several harnesses share one location —
    # claude-code/codex/opencode all resolve to <repo>/.claude/skills, and
    # claude-code+codex share <repo>/CLAUDE.md. A per-agent loop reported the
    # same artifact once per harness that maps to it: four real problems printed
    # as "8 failure(s)". The verdict was right, the count was not.
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "project setup failed"; return 1; }
    rm -f "$repo/.kurama-install-manifest.json"

    local output status=0
    output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" --scope project --path "$repo" 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        echo "doctor was green over an orphaned project install"; return 1
    fi
    local n
    n=$(printf '%s\n' "$output" | grep -c 'Kurama skills in' || true)
    assert_eq "1" "$n" "the shared project skills dir is reported once per harness" || return 1
    n=$(printf '%s\n' "$output" | grep -c 'orchestrator block still merged' || true)
    assert_eq "1" "$n" "the shared CLAUDE.md block is reported once per harness" || return 1
    # And no failure line is printed twice, whatever the artifact.
    local total distinct
    total=$(printf '%s\n' "$output" | grep -c '✗' || true)
    distinct=$(printf '%s\n' "$output" | grep '✗' | sort -u | wc -l | tr -d ' ')
    assert_eq "$distinct" "$total" "doctor printed the same failure more than once" || return 1
    return 0
}

test_doctor_partial_receipt_is_not_reported_healthy() {
    # setup.sh's EXIT trap now flushes a receipt even when the run aborts before
    # anything landed. doctor must not read the resulting empty arrays as
    # "0 of 0 files present — healthy".
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    local dir="$HOME/.claude/skills"
    mkdir -p "$dir"
    cat > "$dir/.kurama-install-manifest.json" <<'JSON'
{
  "name": "kurama",
  "version": "0.0.0-test",
  "tool": "claude-code",
  "tools": [
    "claude-code"
  ],
  "scope": "global",
  "engram": "no",
  "files": [
  ],
  "settings": [
  ],
  "pi_packages": [
  ],
  "engram_mcp": [
  ],
  "prompts": [
  ],
  "tui_plugins": [
  ]
}
JSON
    local output status=0
    output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" --agent claude-code 2>&1) || status=$?
    if printf '%s\n' "$output" | grep -q 'integer expression expected'; then
        echo "doctor emitted a bash error on a partial receipt"; return 1
    fi
    if [ "$status" -eq 0 ]; then
        echo "a receipt recording zero files was reported healthy"; return 1
    fi
    printf '%s\n' "$output" | grep -q 'records NO files' || {
        echo "doctor never says the receipt records nothing"; return 1; }
    return 0
}

# ============================================================================
# Tests — #25 + the OpenCode template invariants
#
# The named-profile orchestrator hard-assigned its task permission, dropping the
# review layer the multi-mode orchestrator is allowed to delegate to. Template
# and installer must agree, in both directions.
# ============================================================================

test_opencode_profile_permission_allows_review_layer() {
    run_setup_opencode --opencode-mode multi --opencode-profile testp \
        || { echo "setup opencode profile install failed"; return 1; }
    local cfg="$HOME/.config/opencode/opencode.json"
    assert_eq "deny" "$(jq -r '.agent["kurama-orchestrator"].permission.task["*"]' "$cfg")" \
        "the profile orchestrator must still deny by default" || return 1
    # #78: the allowlist names every target explicitly instead of globbing. A
    # wildcard OpenCode does not expand in permission.task falls through to
    # "*": "deny" and kills delegation with no error, so each grant must also
    # correspond to an agent that actually exists in the installed config.
    local key
    for key in init explore propose spec design tasks apply verify archive; do
        assert_eq "allow" "$(jq -r --arg k "sdd-$key-testp" '.agent["kurama-orchestrator"].permission.task[$k]' "$cfg")" \
            "the profile orchestrator must delegate to its own sdd-$key-testp subagent" || return 1
        jq -e --arg k "sdd-$key-testp" '.agent[$k]' "$cfg" > /dev/null 2>&1 || {
            echo "granted sdd-$key-testp but no agent by that name is defined"; return 1; }
    done
    assert_eq "allow" "$(jq -r '.agent["kurama-orchestrator"].permission.task["general"]' "$cfg")" \
        "the profile orchestrator cannot delegate to general" || return 1
    # The 8 review-layer agents #25 enumerated, each named rather than globbed.
    for key in review-risk review-readability review-reliability review-resilience \
               review-refuter jd-judge-a jd-judge-b jd-fix-agent; do
        assert_eq "allow" "$(jq -r --arg k "$key" '.agent["kurama-orchestrator"].permission.task[$k]' "$cfg")" \
            "the profile orchestrator cannot delegate $key" || return 1
    done
    # The template's "-kurama" placeholder must NOT leak in: the profile only
    # drives its own suffixed subagents.
    assert_eq "null" "$(jq -r '.agent["kurama-orchestrator"].permission.task["sdd-apply-kurama"]' "$cfg")" \
        "the template's placeholder suffix was not renamed" || return 1
    return 0
}

test_opencode_templates_allow_the_review_layer() {
    local multi="$REPO_DIR/examples/opencode/opencode.multi.json"
    local prof="$REPO_DIR/examples/opencode/opencode.profile.template.json"
    assert_eq "allow" "$(jq -r '.agent["sdd-orchestrator"].permission.task["general"]' "$multi")" \
        "opencode.multi.json denies the general agent" || return 1
    # #25 enumerated 8 review-layer agents and proposed "review-*"/"jd-*" as
    # shorthand for exactly those. #78 replaced the shorthand with the 8 names, so
    # the grant no longer depends on OpenCode expanding a glob in permission.task.
    # Both templates must carry the same set — that is the drift #25 closed.
    local key f globs
    for key in review-risk review-readability review-reliability review-resilience \
               review-refuter jd-judge-a jd-judge-b jd-fix-agent general; do
        assert_eq "allow" "$(jq -r --arg k "$key" '.agent["kurama-orchestrator"].permission.task[$k]' "$prof")" \
            "the profile template denies $key" || return 1
        assert_eq "allow" "$(jq -r --arg k "$key" '.agent["sdd-orchestrator"].permission.task[$k]' "$multi")" \
            "opencode.multi.json denies $key" || return 1
    done
    # No "allow" in either template may be expressed as a glob.
    for f in "$multi" "$prof"; do
        globs=$(jq -r '[.agent[] | (.permission.task // {}) | to_entries[]
            | select(.value == "allow") | select(.key | test("[*]")) | .key] | join(",")' "$f")
        [ -z "$globs" ] || {
            echo "$(basename "$f") still grants via glob: $globs"; return 1; }
    done
    return 0
}

test_no_prose_claims_profile_delegation_is_exclusive() {
    # The config allows review-*/jd-*/general (see the two tests above), but the
    # prose said the profile orchestrator "delegates only to its own sdd-*-NAME
    # subagents" — and the copy inside the SHIPPED prompt contradicted the review
    # rule three paragraphs above it. Being the more specific sentence, it read as
    # the governing exception and the review layer got skipped. Any wording that
    # narrows the profile's delegation to sdd-*-NAME is a lie about the map.
    local f
    for f in "$REPO_DIR/docs/opencode-profiles.md" \
             "$REPO_DIR/examples/_templates/opencode.md" \
             "$REPO_DIR/examples/opencode/AGENTS.md"; do
        assert_file_exists "$f" || return 1
        if grep -nEi 'delegates only|only delegates' "$f"; then
            echo "$f claims the profile orchestrator delegates only to its own subagents"
            return 1
        fi
    done
    return 0
}

test_opencode_commands_never_hardcode_engram_mode() {
    # Every executor command must RESOLVE the artifact store, never assume it.
    #
    # The loop counts what it read, the way its sibling below does: a check whose
    # whole job is "no file says X" reports success just as loudly when there are
    # no files — this test passed with examples/opencode/commands/ deleted.
    local f n=0
    for f in "$REPO_DIR"/examples/opencode/commands/*.md; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        if grep -q 'Artifact store mode: engram' "$f"; then
            echo "$(basename "$f") hardcodes 'Artifact store mode: engram'"; return 1
        fi
    done
    [ "$n" -ge 9 ] || { echo "expected at least the 9 OpenCode commands, scanned $n"; return 1; }
    return 0
}

test_opencode_executor_commands_name_the_envelope_fields() {
    local f n=0
    for f in "$REPO_DIR"/examples/opencode/commands/sdd-*.md; do
        grep -q '^subtask:' "$f" || continue
        n=$((n + 1))
        grep -q 'risks' "$f" || {
            echo "$(basename "$f") never names the risks envelope field"; return 1; }
        grep -q 'skill_resolution' "$f" || {
            echo "$(basename "$f") never names skill_resolution"; return 1; }
    done
    [ "$n" -ge 5 ] || { echo "expected at least 5 executor commands, found $n"; return 1; }
    return 0
}

test_skills_declare_no_tools_frontmatter() {
    # Skills are instructions, not agents: a tools:/allowed-tools: key there is
    # ignored by every harness and reads as an enforced boundary that is not one.
    #
    # Counted for the same reason as its siblings: with skills/ gone the glob
    # matches nothing, every iteration is skipped and the test reports PASS. The
    # floor is the default skill set itself, so it cannot rot out of date — every
    # skill a default install ships must have been read for this to mean anything.
    local f n=0
    for f in "$REPO_DIR"/skills/*/SKILL.md; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        if grep -Eq '^(tools|allowed-tools):' "$f"; then
            echo "$(basename "$(dirname "$f")")/SKILL.md declares a tools: key"; return 1
        fi
    done
    [ "$n" -ge "${#EXPECTED_SKILLS[@]}" ] || {
        echo "expected at least ${#EXPECTED_SKILLS[@]} SKILL.md files, scanned $n"; return 1; }
    return 0
}

test_codex_template_declares_no_task_tool() {
    local f="$REPO_DIR/examples/_templates/codex.md"
    assert_file_exists "$f" || return 1
    # shellcheck disable=SC2016  # the backticks are markdown in the file we grep, not a subshell
    grep -qF 'no `task` tool' "$f" || {
        echo "the codex overlay no longer states that Codex has no task tool"; return 1; }
    if grep -Eqi 'use the .?task.? tool|delegate (it |them |this )?via the .?task.? tool' "$f"; then
        echo "the codex overlay instructs delegation through a task tool Codex does not have"; return 1
    fi
    return 0
}

test_cycle_markers_written_in_every_mode() {
    # #30. The two hooks read only the filesystem. If a skill stops mandating the
    # .kurama/sdd/ markers, engram mode silently loses both gates again.
    local pc="$REPO_DIR/skills/_shared/persistence-contract.md"
    grep -qi 'Hook-visible cycle markers' "$pc" \
        || { echo "the cycle-marker contract disappeared"; return 1; }
    grep -q '.kurama/sdd/{change-name}/verify-report.md' "$REPO_DIR/skills/sdd-verify/SKILL.md" \
        || { echo "sdd-verify no longer writes the verify-report marker"; return 1; }
    grep -q '.kurama/sdd/{change-name}/archive-report.md' "$REPO_DIR/skills/sdd-archive/SKILL.md" \
        || { echo "sdd-archive no longer writes the archive-report marker"; return 1; }
    # The third marker is the orchestrator's, and the contract that ASSIGNS it is not
    # the file the orchestrator is routed to. With the mandate only in
    # persistence-contract.md, engram mode wrote no state.md at all and the write
    # guard stayed inert — lock the orchestrator's own rulebook to it.
    local osp="$REPO_DIR/skills/_shared/orchestrator-sdd-protocol.md"
    grep -q '.kurama/sdd/' "$osp" \
        || { echo "orchestrator-sdd-protocol.md never names .kurama/sdd/"; return 1; }
    grep -q 'state\.md' "$osp" \
        || { echo "orchestrator-sdd-protocol.md never mandates the state.md marker"; return 1; }
    # The paths must still be the ones the shipped hooks actually check.
    # shellcheck disable=SC2016  # "$change" is the literal shell variable name inside the hook
    grep -qF '.kurama/sdd/$change/verify-report.md' \
        "$REPO_DIR/examples/claude-code/hooks/archive-gate.sh" \
        || { echo "archive-gate no longer reads the mandated path"; return 1; }
    grep -q 'archive-report.md' \
        "$REPO_DIR/examples/claude-code/hooks/orchestrator-write-guard.sh" \
        || { echo "write-guard no longer retires on archive-report.md"; return 1; }
    return 0
}

# ============================================================================
# Run all tests
# ============================================================================

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║    Kurama — Install Tests      ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BOLD}The harness itself${NC}"
run_test "a failing bare command fails its test" test_harness_bare_command_failure_fails_the_test
run_test "a passing body is still reported as a pass" test_harness_passing_test_still_passes
echo ""

echo -e "${BOLD}Help & Error Handling${NC}"
run_test "--help flag shows usage info" test_help_flag
run_test "--help exits with code 0" test_help_exits_zero
run_test "Invalid agent exits non-zero" test_invalid_agent
run_test "Unknown option exits non-zero" test_invalid_option
echo ""

echo -e "${BOLD}Claude Code${NC}"
run_test "Installs all 28 skills to ~/.claude/skills" test_install_claude_code
run_test "Exactly 28 SKILL.md files" test_claude_code_skill_count
echo ""

echo -e "${BOLD}OpenCode${NC}"
run_test "Installs all 28 skills to ~/.config/opencode/skills" test_install_opencode
run_test "Exactly 28 SKILL.md files" test_opencode_skill_count
run_test "Installs 9 command files" test_opencode_commands
echo ""

echo -e "${BOLD}Codex${NC}"
run_test "Installs all 28 skills to ~/.codex/skills" test_install_codex
run_test "Exactly 28 SKILL.md files" test_codex_skill_count
echo ""

echo -e "${BOLD}Project-local${NC}"
run_test "Installs all 28 skills to ./skills/" test_install_project_local
run_test "Exactly 28 SKILL.md files" test_project_local_skill_count
echo ""

echo -e "${BOLD}Custom path${NC}"
run_test "Installs to arbitrary custom path" test_custom_path
run_test "Exactly 28 SKILL.md files" test_custom_path_skill_count
run_test "Handles deeply nested custom path" test_nested_custom_path
echo ""

echo -e "${BOLD}All-global${NC}"
run_test "Installs to all 5 global targets" test_all_global
run_test "140 total SKILL.md files (5x28)" test_all_global_total_skill_count
run_test "Also installs OpenCode commands" test_all_global_opencode_commands
echo ""

echo -e "${BOLD}Idempotency${NC}"
run_test "Claude Code: double install is safe" test_idempotent_claude_code
run_test "OpenCode: double install is safe" test_idempotent_opencode
run_test "All-global: double install is safe" test_idempotent_all_global
echo ""

echo -e "${BOLD}Content integrity${NC}"
run_test "Skills match source files exactly" test_skill_content_matches_source
run_test "Commands match source files exactly" test_opencode_command_content_matches_source
echo ""

echo -e "${BOLD}Output verification${NC}"
run_test "Output reports agent, count and skills path" test_output_shows_skill_names
run_test "Output shows Done! message" test_output_shows_done_message
run_test "Output shows install count" test_output_shows_install_count
run_test "Output shows next-step guidance" test_output_shows_next_step
run_test "Output recommends Engram" test_output_shows_engram_note
echo ""

echo -e "${BOLD}OS detection${NC}"
run_test "--help runs without error" test_os_detection_runs
run_test "Delegated run shows the setup.sh header" test_header_shows_detected_os
echo ""

echo -e "${BOLD}Edge cases${NC}"
run_test "Pre-existing custom skill not clobbered" test_pre_existing_dir_not_clobbered
run_test "Stale SKILL.md is overwritten" test_overwrite_stale_skill
echo ""

echo -e "${BOLD}setup.sh orchestrator safety${NC}"
run_test "Unbalanced marker (BEGIN w/o END) aborts, file intact" test_setup_unbalanced_marker_aborts
run_test "Balanced marker updates in place + writes backup" test_setup_balanced_marker_updates_and_backs_up
echo ""

echo -e "${BOLD}setup.sh manifest-driven install + receipt${NC}"
run_test "setup.sh installs the 28 default skills" test_setup_installs_default_skill_set
run_test "setup.sh includes the default tdd module" test_setup_includes_tdd
run_test "setup.sh writes an install manifest (receipt)" test_setup_writes_install_manifest
run_test "uninstall.sh cleans a setup.sh install" test_setup_uninstall_round_trip
run_test "setup.sh tree equals install.sh default tree" test_setup_matches_manifest_default_set
echo ""

echo -e "${BOLD}OpenCode template references${NC}"
run_test "No reference to nonexistent examples/opencode/opencode.json" test_no_broken_opencode_json_reference
run_test "Installers reference opencode.single.json" test_opencode_json_reference_fixed
run_test "opencode.single/multi.json templates exist" test_opencode_template_files_exist
echo ""

echo -e "${BOLD}Phase 11 — OpenCode shared prompts + model profiles${NC}"
run_test "legacy background-agents plugin is removed, never installed" test_opencode_background_agents_removed
run_test "shared SDD prompt files install (9)" test_opencode_shared_prompts_installed
run_test "multi.json references shared prompt files (not inline)" test_opencode_multi_references_prompt_files
run_test "profile splices kurama-orchestrator + 9 suffixed agents" test_opencode_profile_generates_agents
run_test "profile re-run preserves hand-edited models" test_opencode_profile_idempotent_preserves_model
run_test "invalid profile name is rejected" test_opencode_profile_rejects_bad_name
run_test "base-only re-run prunes orphaned kurama-orchestrator" test_opencode_base_rerun_prunes_orphan_orchestrator
run_test "sdd-status command installs + routes to orchestrator" test_opencode_status_command_installed
echo ""

echo -e "${BOLD}Manifest & versioning${NC}"
run_test "manifest.json exists and parses" test_manifest_exists_and_parses
run_test "--version prints the version" test_version_flag
run_test "--version exits with code 0" test_version_exits_zero
run_test "Install writes an install manifest" test_install_writes_install_manifest
run_test "Default install includes optional groups" test_default_install_includes_optional_groups
run_test "--without optional excludes the group's five skills (23 skills)" test_without_optional_excludes_go_testing
run_test "--without quality excludes judgment-day (27 skills)" test_without_quality_excludes_judgment_day
run_test "--without quality --without optional (22 skills)" test_without_both_groups
run_test "--without sdd-core is rejected" test_reject_without_required_group
echo ""

echo -e "${BOLD}TDD module (default-on group)${NC}"
run_test "Default install includes tdd (28 skills)" test_default_install_includes_tdd
run_test "--without tdd excludes tdd (27 skills)" test_without_tdd_excludes_tdd
run_test "lang group is opt-in (--with lang adds go-testing)" test_lang_group_is_opt_in
run_test "--with tdd is idempotent (28 skills)" test_with_tdd_includes_tdd
run_test "--with tdd uninstall round-trip is clean" test_with_tdd_uninstall_round_trip
echo ""

echo -e "${BOLD}Pi agent (P5 installer wiring)${NC}"
run_test "install.sh --agent omp installs 28 skills" test_install_omp
run_test "Exactly 28 SKILL.md files for omp" test_omp_skill_count
run_test "omp install writes an install manifest" test_omp_writes_install_manifest
run_test "omp honors PI_CODING_AGENT_DIR relocation" test_omp_honors_relocated_agent_base
run_test "setup.sh --agent omp merges the orchestrator prompt" test_setup_omp_writes_orchestrator
run_test "omp installs its 17 native agents" test_omp_installs_native_agents
run_test "omp agents follow the omp task-agent contract" test_omp_agents_use_the_omp_contract
run_test "omp installs RULES.md sticky rules" test_omp_installs_sticky_rules
run_test "omp install/uninstall round-trip is clean" test_omp_uninstall_round_trip
run_test "install.sh --agent pi installs 28 skills" test_install_pi
run_test "Exactly 28 SKILL.md files for Pi" test_pi_skill_count
run_test "Pi install writes an install manifest" test_pi_writes_install_manifest
run_test "setup.sh --agent pi writes orchestrator to ~/.pi/agent/AGENTS.md" test_setup_pi_writes_orchestrator
echo ""

echo -e "${BOLD}N4 — Claude Code native agents (setup.sh)${NC}"
run_test "setup.sh installs all 17 native agents to ~/.claude/agents" test_setup_installs_all_claude_agents
run_test "installed agents are recorded in the receipt" test_setup_agents_recorded_in_receipt
run_test "pre-existing agent is backed up before overwrite" test_setup_agents_backs_up_preexisting
run_test "Pi installs its 17 native agents (O4 wiring)" test_pi_installs_native_agents
run_test "non-agent-shipping target grows no agents dir" test_non_target_agents_have_no_native_agents
echo ""

echo -e "${BOLD}N5 — Pi package stack (opt-in, fake pi/npm shims)${NC}"
run_test "exact install sequence + pins, gentle-pi excluded" test_pi_packages_exact_sequence
run_test "--without-pi-packages skips the stack" test_pi_packages_without_flag_skips
run_test "a failed pi install is non-fatal (continues)" test_pi_packages_failure_is_non_fatal
run_test "stack skipped cleanly when pi is absent" test_pi_packages_skipped_when_pi_absent
echo ""

echo -e "${BOLD}Review lens group (G1, default-on)${NC}"
run_test "review lenses install by default" test_review_lenses_installed_by_default
run_test "--without review excludes the 5 lenses (23 skills)" test_without_review_excludes_lenses
echo ""

echo -e "${BOLD}Kanban module (Phase 9, optional group, default-on)${NC}"
run_test "kanban-github installs by default" test_kanban_installed_by_default
run_test "kanban-github is listed in the optional manifest group" test_kanban_listed_in_manifest_optional_group
run_test "--without optional excludes kanban-github" test_without_optional_excludes_kanban
echo ""

echo -e "${BOLD}Phase 6 surface (G9 Pi + sdd-status.sh)${NC}"
run_test "sdd-status.sh exists and is executable" test_sdd_status_exists_and_executable
run_test "sdd-status.sh exits 0 on an empty project" test_sdd_status_empty_dir_exit_zero
run_test "sdd-status.sh --json parses on an empty project" test_sdd_status_json_parses_on_empty
run_test "a conforming engram cycle is not called degraded" test_sdd_status_conforming_engram_cycle_is_not_degraded
run_test "a marker-only openspec cycle is not hybrid" test_sdd_status_marker_only_openspec_cycle_is_not_hybrid
run_test "an unprovable store is labelled unknown" test_sdd_status_unprovable_store_is_labelled_unknown
run_test "examples/pi/AGENTS.md is generated" test_pi_example_generated
echo ""

echo -e "${BOLD}Uninstall${NC}"
run_test "Uninstall round-trip removes only recorded files" test_uninstall_round_trip
run_test "Uninstall --dry-run preserves files" test_uninstall_dry_run_preserves_files
run_test "Uninstall works on a custom path" test_uninstall_custom_path
echo ""

echo -e "${BOLD}Meta-skill registration (M3)${NC}"
run_test "sdd-new/continue/ff install by default" test_meta_skills_installed_by_default
echo ""

echo -e "${BOLD}Packaging manifests (M5)${NC}"
run_test "plugin.json is valid JSON" test_plugin_json_valid
run_test "marketplace.json is valid JSON" test_marketplace_json_valid
run_test "plugin.json version equals VERSION file" test_plugin_json_version_matches_version_file
run_test "none artifact-store mode is fully removed" test_none_mode_fully_removed
run_test "dropped harnesses are rejected by name" test_dropped_harnesses_rejected_by_name
run_test "dropped harness artifacts are gone" test_dropped_harness_artifacts_are_gone
run_test ".kurama state survives the mode removal" test_kurama_state_survives_mode_removal
run_test "orchestrator prompt delegates heavy blocks to _shared" test_orchestrator_prompt_delegates_heavy_blocks
run_test "phase skill loading reads SKILL.md paths by default" test_phase_skill_loading_reads_paths_by_default
run_test "preflight resolves no dangling delivery value" test_preflight_resolves_no_dangling_delivery_value
run_test "absent change size resolves to standard" test_change_size_absent_means_standard
run_test "small change collapses spec/design, never omits" test_small_change_collapses_without_omitting
run_test "sdd-design description marks spec optional" test_sdd_design_description_marks_spec_optional
run_test "dependency graph matches the canonical DAG" test_dependency_graph_matches_canonical_dag
echo ""

echo -e "${BOLD}Release commit stamping (V3–V6)${NC}"
run_test "install.sh receipt records a valid source commit" test_receipt_records_commit
run_test "setup.sh receipt records a valid source commit" test_setup_receipt_records_commit
run_test "update.sh shows a version+commit transition line" test_update_shows_commit_transition
run_test "update re-stamps an install.sh (display-name) receipt" test_update_restamps_install_sh_receipt
run_test "git-absent host installs, commit field omitted" test_receipt_omits_commit_without_git
echo ""

echo -e "${BOLD}Phase 10b — scope project (O1)${NC}"
run_test "project scope installs everything into the repo" test_scope_project_installs_into_repo
run_test "project receipt lives at the repo root" test_scope_project_receipt_at_repo_root
run_test "refuses to install into the Kurama repo" test_scope_project_rejects_kurama_repo
run_test "non-git target aborts (non-interactive)" test_scope_project_rejects_non_git_noninteractive
run_test "project uninstall is clean, user files survive" test_scope_project_uninstall_clean
run_test "project receipt records every installed harness" test_scope_project_receipt_records_every_tool
echo ""

echo -e "${BOLD}TUI detect-and-update pre-flight (setup-tui.sh probe)${NC}"
run_test "project install is detected with both harnesses" test_tui_probe_detects_project_install
run_test "v6-style receipt (no tools[]) still reports its tool" test_tui_probe_v6_receipt_reports_its_tool
run_test "no receipt: no output, exit 0" test_tui_probe_no_receipt_is_silent
run_test "global install is detected in the sandboxed HOME" test_tui_probe_detects_global_install
run_test "probe answers before the gum precondition" test_tui_probe_runs_without_gum
echo ""

echo -e "${BOLD}Phase 10b — Claude Code hooks (O2)${NC}"
run_test "hooks installed + settings block (global)" test_hooks_installed_global_claude
run_test "hooks merge preserves foreign entries, idempotent" test_hooks_merge_preserves_foreign_entries
run_test "uninstall strips hooks block, keeps foreign hooks" test_hooks_removed_by_uninstall
echo ""

echo -e "${BOLD}Phase 10b — Pi agents in project scope (O4)${NC}"
run_test "Pi installs 17 agents into .pi/agents" test_pi_agents_project_scope
echo ""

echo -e "${BOLD}Phase 10b — update.sh re-sync (O6)${NC}"
run_test "update restores a modified skill (global)" test_update_resyncs_modified_skill
run_test "update --dry-run changes nothing" test_update_dry_run_changes_nothing
run_test "update re-syncs a project install" test_update_resyncs_project_scope
echo ""

echo -e "${BOLD}Phase 10b — doctor.sh health check (O7)${NC}"
run_test "doctor is green on a healthy install (exit 0)" test_doctor_healthy_exit_zero
run_test "unmerged orchestrator is a warning, not UNBALANCED" test_doctor_missing_markers_is_warning_not_failure
run_test "doctor is red on a broken receipt (exit 1)" test_doctor_broken_receipt_exit_nonzero
run_test "doctor is green on a healthy project install" test_doctor_project_scope_healthy
run_test "doctor is red on orphaned agents (no receipt)" test_doctor_orphaned_agents_exit_nonzero
run_test "doctor is green when nothing is installed" test_doctor_no_install_is_not_a_failure
echo ""

echo -e "${BOLD}Phase 10b — Engram persistence engine (O5, fake engram/brew/claude)${NC}"
run_test "--without-engram writes zero Engram config" test_engram_without_flag_no_changes
run_test "registers generic mcpServers.engram (claude global)" test_engram_registers_claude_global
run_test "opencode uses command-array + type:local (project)" test_engram_opencode_project_shape
run_test "codex TOML block upsert is idempotent, preserves config" test_engram_codex_toml_upsert
run_test "project scope writes .mcp.json inside the repo" test_engram_project_scope_claude
run_test "non-interactive never invokes brew (guide only)" test_engram_brew_not_invoked_noninteractive
run_test "uninstall strips the Engram MCP registration, rest intact" test_engram_uninstall_removes_registration
run_test "doctor mentions the Engram MCP registration" test_doctor_reports_engram_mcp
echo ""

echo -e "${BOLD}Shipped PreToolUse hooks (payload-driven)${NC}"
run_test "no active cycle: every write is allowed" test_write_guard_allows_writes_when_no_cycle_is_active
run_test "active cycle: an inline write to repo code is blocked" test_write_guard_blocks_repo_code_during_an_active_cycle
run_test ".kurama/ and openspec/ stay writable during a cycle" test_write_guard_exempts_the_sdd_artifact_paths
run_test "an archived cycle stops guarding" test_write_guard_stops_guarding_once_the_cycle_is_archived
run_test "subagent writes pass; payload content cannot spoof one" test_write_guard_passes_subagent_writes_and_resists_spoofing
run_test "both write-guard overrides open the gate" test_write_guard_override_env_vars_open_the_gate
run_test "the gate ignores every non-archive launch" test_archive_gate_ignores_every_non_archive_launch
run_test "no verify report: archiving is blocked" test_archive_gate_blocks_an_archive_with_no_verify_report
run_test "a PASS report in .kurama/sdd/ opens the gate" test_archive_gate_passes_a_pass_verdict_in_the_kurama_store
run_test "FAIL and unfilled-template verdicts are blocked" test_archive_gate_blocks_a_fail_verdict
run_test "a stale Tree-Hash blocks; a fresh one passes" test_archive_gate_content_binding_blocks_a_stale_receipt
run_test "KURAMA_ARCHIVE_OVERRIDE bypasses both checks" test_archive_gate_override_env_var_opens_the_gate
run_test "both hooks decide the same way without jq" test_nojq_hooks_decide_the_same_way_without_jq
echo ""

echo -e "${BOLD}validate_skills.sh — frontmatter linter${NC}"
run_test "an unclosed --- fence is a failure" test_validate_skills_rejects_unclosed_frontmatter_fence
run_test "an empty name: is a failure" test_validate_skills_rejects_empty_name
run_test "an empty description: is a failure" test_validate_skills_rejects_empty_description
run_test "well-formed frontmatter still passes" test_validate_skills_accepts_wellformed_frontmatter
echo ""

echo -e "${BOLD}jq-less host (awk fallbacks, restricted-PATH farm without jq)${NC}"
run_test "claude-code project install needs no jq" test_nojq_setup_claude_code_project_installs
run_test "opencode project install needs no jq" test_nojq_setup_opencode_project_installs
run_test "validate_skills.sh passes without jq" test_nojq_validate_skills_exits_zero
run_test "single-line empty files[] resolves to nothing" test_nojq_receipt_parser_ignores_single_line_empty_array
run_test "a jq-less install is graded healthy, not failed" test_nojq_doctor_grades_the_documented_degradation_a_warning
run_test "a claimed-but-missing hooks write stays a failure" test_doctor_fails_when_the_receipt_claims_an_unregistered_hooks_write
run_test "install.sh installs + grades healthy without jq" test_nojq_install_sh_installs_and_is_graded_healthy
run_test "update.sh re-syncs + grades healthy without jq" test_nojq_update_sh_resyncs_and_is_graded_healthy
echo ""

echo -e "${BOLD}Installer correctness — ghost installs, blanked configs, receipt truncation${NC}"
run_test "a failed hooks merge still writes a receipt" test_setup_survives_hooks_merge_failure
run_test "closed stdin installs instead of dying on read" test_setup_eof_stdin_leaves_no_ghost_install
run_test "unparseable opencode.json: controlled exit + receipt" test_setup_unparseable_opencode_json_is_controlled
run_test "jq-less run records no settings.json it never wrote" test_nojq_receipt_omits_unwritten_settings
run_test "empty settings.json is merged, never blanked" test_setup_empty_settings_json_not_blanked
run_test "empty opencode.json is created, never blanked" test_setup_empty_opencode_json_not_blanked
run_test "empty .claude.json survives the Engram merge" test_setup_empty_claude_json_engram_not_blanked
run_test "install.sh re-syncs (never truncates) a setup.sh receipt" test_install_refuses_setup_managed_receipt
run_test "install.sh re-syncs a setup-managed OpenCode target" test_install_refuse_writes_nothing_for_opencode
run_test "--without removes the excluded skills from disk" test_install_without_group_removes_excluded_skills
run_test "incomplete checkout aborts before writing" test_install_incomplete_checkout_aborts_early
run_test "install.sh: valueless flag prints usage" test_install_flag_without_value_shows_usage
run_test "setup.sh: valueless flag prints usage" test_setup_flag_without_value_shows_usage
echo ""

echo -e "${BOLD}#22 — the OpenCode install is fully recorded${NC}"
run_test "receipt records commands, prompt and opencode.json" test_opencode_receipt_records_commands_prompt_and_config
run_test "receipt records the resolved mode + profile" test_opencode_receipt_records_mode_and_profile
run_test "a non-OpenCode receipt carries no OpenCode keys" test_setup_receipt_omits_opencode_keys_for_other_agents
run_test "update re-syncs multi+profile without downgrading" test_update_preserves_opencode_mode_and_profile
run_test "update preserves a hand-edited profile model" test_update_preserves_hand_edited_profile_model
run_test "update refuses an OpenCode receipt with no mode" test_update_refuses_opencode_receipt_without_mode
run_test "a refused target never aborts the other targets" test_update_refusal_does_not_abort_the_other_targets
run_test "uninstall removes every OpenCode artifact" test_uninstall_removes_every_opencode_artifact
run_test "uninstall sweeps a pre-#22 OpenCode receipt" test_uninstall_sweeps_legacy_opencode_artifacts
run_test "the sweep never deletes a user-written AGENTS.md" test_uninstall_leaves_foreign_agents_md_alone
run_test "uninstalling claude-code never touches OpenCode" test_uninstall_claude_code_never_touches_opencode
run_test "a pre-marker prompt copy is re-merged, not frozen" test_setup_remerges_a_pre_marker_prompt_copy
run_test "the same re-merge works on a claude-code copy" test_setup_remerges_a_pre_marker_claude_prompt_copy
run_test "a user-written prompt stays warn-only" test_setup_leaves_a_user_written_prompt_warn_only
echo ""

echo -e "${BOLD}#23 — doctor verdicts it actually verified${NC}"
run_test "orphan scan runs per agent lacking a receipt" test_doctor_orphan_scan_runs_per_agent
run_test "orphan scan covers OpenCode, not just claude-code" test_doctor_orphan_scan_covers_opencode
run_test "display-name receipt still runs every check" test_doctor_normalizes_display_name_receipt
run_test "an unresolvable tool is a hard failure" test_doctor_unresolvable_tool_is_hard_fail
run_test "a healthy OpenCode install is green" test_doctor_green_on_healthy_opencode
run_test "a pre-marker orchestrator is verified by content" test_doctor_unmarked_orchestrator_is_recognized_by_content
run_test "project orphans are reported once, not per harness" test_doctor_project_orphans_are_not_double_reported
run_test "a partial receipt is never reported healthy" test_doctor_partial_receipt_is_not_reported_healthy
echo ""

echo -e "${BOLD}#25 — profile permissions + OpenCode template invariants${NC}"
run_test "profile orchestrator may delegate the review layer" test_opencode_profile_permission_allows_review_layer
run_test "both templates allow general/review-*/jd-*" test_opencode_templates_allow_the_review_layer
run_test "no prose narrows profile delegation to sdd-*-NAME" test_no_prose_claims_profile_delegation_is_exclusive
run_test "no command hardcodes the engram artifact store" test_opencode_commands_never_hardcode_engram_mode
run_test "executor commands name risks + skill_resolution" test_opencode_executor_commands_name_the_envelope_fields
run_test "no SKILL.md declares a tools: key" test_skills_declare_no_tools_frontmatter
run_test "the codex overlay claims no task tool" test_codex_template_declares_no_task_tool
run_test "cycle markers are mandated in every mode" test_cycle_markers_written_in_every_mode
echo ""

# ============================================================================
# #34 — build guards (scripts/build-examples.sh)
#
# Self-contained section: helpers, tests and the run_test calls all live here so
# the block can move as one piece. Every case runs build-examples.sh against a
# THROWAWAY copy of the repo, so nothing here can write into the real examples/.
# ============================================================================

# Stage the minimum tree build-examples.sh needs: it reads
# $REPO/examples/_templates/*.md, writes only under $REPO/examples/, and derives
# $REPO from its own location — so a copy of the script plus the templates is a
# complete, disposable build.
stage_build_examples_repo() {
    local dest="$1"
    mkdir -p "$dest/scripts" "$dest/examples/_templates" || return 1
    cp "$SCRIPT_DIR/build-examples.sh" "$dest/scripts/build-examples.sh" || return 1
    cp "$REPO_DIR"/examples/_templates/*.md "$dest/examples/_templates/" || return 1
    return 0
}

# A @@TOKEN@@ that nobody registered in $TOKENS has no extracted block file, and
# awk's `getline < f` returns -1 for it. That used to drop the line silently:
# five orchestrators shipping with a section missing, exit 0, CI green.
test_build_examples_rejects_unknown_placeholder() {
    local repo="$TEST_TMPDIR/build-unknown-token"
    stage_build_examples_repo "$repo" \
        || { echo "could not stage the throwaway build tree"; return 1; }

    # A contributor adds a placeholder to core.md and forgets to register it.
    printf '\n@@NOT_A_REGISTERED_TOKEN@@\n' >> "$repo/examples/_templates/core.md"

    local output status
    output="$(bash "$repo/scripts/build-examples.sh" 2>&1)" && status=0 || status=$?

    if [[ $status -eq 0 ]]; then
        echo "build-examples exited 0 on an unregistered @@TOKEN@@ (silent drop)"
        printf '%s\n' "$output"
        return 1
    fi
    if ! printf '%s\n' "$output" | grep -q 'NOT_A_REGISTERED_TOKEN'; then
        echo "the failure never names the offending token:"
        printf '%s\n' "$output"
        return 1
    fi
    # A loud failure must not leave a half-substituted orchestrator behind.
    if [[ -f "$repo/examples/claude-code/CLAUDE.md" ]]; then
        echo "build-examples wrote an output file despite failing"
        return 1
    fi
    return 0
}

# The other direction: the committed templates must still build, and build to
# exactly what is committed — so the new error path cannot fire on a good tree.
test_build_examples_rebuilds_committed_outputs_byte_for_byte() {
    local repo="$TEST_TMPDIR/build-clean"
    stage_build_examples_repo "$repo" \
        || { echo "could not stage the throwaway build tree"; return 1; }

    local output status
    output="$(bash "$repo/scripts/build-examples.sh" 2>&1)" && status=0 || status=$?
    if [[ $status -ne 0 ]]; then
        echo "build-examples failed on the committed templates (exit $status):"
        printf '%s\n' "$output"
        return 1
    fi

    local rel
    for rel in examples/claude-code/CLAUDE.md examples/codex/agents.md \
               examples/opencode/AGENTS.md examples/pi/AGENTS.md \
               examples/omp/AGENTS.md; do
        assert_file_not_empty "$repo/$rel" 1000 || return 1
        if ! cmp -s "$repo/$rel" "$REPO_DIR/$rel"; then
            echo "rebuilt $rel differs from the committed file"
            return 1
        fi
    done
    return 0
}

echo -e "${BOLD}#34 — build guards (unknown template placeholders)${NC}"
run_test "an unregistered @@TOKEN@@ fails loudly, naming it" test_build_examples_rejects_unknown_placeholder
run_test "the committed templates rebuild byte-for-byte" test_build_examples_rebuilds_committed_outputs_byte_for_byte
echo ""

# ===== UNIT-A (issue #32) =====
#
# update.sh hardening. #32 filed five defects; four reproduce against this tree
# and are fixed here. The fifth — the first unusable receipt killing the whole
# multi-target run under `set -e` — was already closed by ec8cdf3 for the
# REFUSAL branch, so the pin below covers the other exit out of resync_target
# (an unrecognized tool, filed as a failure) instead.
#
# Every test drives the real update.sh against a real install inside the
# sandboxed $HOME run_test provides, so each assertion is about what the user
# sees or what survives on disk — never an internal.

# The documented contract of --dry-run is "report drift, change nothing". It
# snapshotted every recorded file's hash and then threw the snapshot away,
# printing a constant "would re-sync N recorded file(s)" — the same N for a
# pristine install and for one whose skills had been hand-edited. A user
# previewing the update saw nothing, ran the real update, and lost the edit.
test_update_dry_run_reports_drifted_files() {
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup claude-code failed"; return 1; }
    printf 'LOCAL EDIT\n' > "$HOME/.claude/skills/sdd-apply/SKILL.md"

    local output status=0
    output=$(bash "$UPDATE_SCRIPT" --agent claude-code --dry-run 2>&1) || status=$?
    assert_eq "0" "$status" "a dry run must exit 0" || return 1

    printf '%s\n' "$output" | grep -q 'sdd-apply/SKILL.md' || {
        echo "the dry run never names the drifted file:"
        printf '%s\n' "$output"
        return 1
    }
    # ...and it is still only a preview.
    grep -q 'LOCAL EDIT' "$HOME/.claude/skills/sdd-apply/SKILL.md" || {
        echo "the dry run modified the drifted file"; return 1; }
    return 0
}

# The other direction: a pristine install must preview as clean. A drift report
# that cries wolf on every recorded file is as useless as one that reports
# nothing, and it is the case every user sees first.
test_update_dry_run_clean_install_reports_no_drift() {
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup claude-code failed"; return 1; }

    local output status=0
    output=$(bash "$UPDATE_SCRIPT" --agent claude-code --dry-run 2>&1) || status=$?
    assert_eq "0" "$status" "a dry run must exit 0" || return 1

    if printf '%s\n' "$output" | grep -qE 'drift:|missing:'; then
        echo "a freshly installed target previewed as drifted:"
        printf '%s\n' "$output"
        return 1
    fi
    printf '%s\n' "$output" | grep -qi 'no drift' || {
        echo "the dry run never states the target is in sync:"
        printf '%s\n' "$output"
        return 1
    }
    return 0
}

# ~/.claude/agents is a SHARED directory — users keep their own agents there.
# The prune globbed every *.bak.* in it and deleted all but the lexically last
# per name, so a user's own backup of their own agent was collected as
# collateral on the next update. Only originals the receipt records may be
# pruned.
test_update_prune_spares_user_owned_agent_backups() {
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup claude-code failed"; return 1; }
    local agents="$HOME/.claude/agents"
    assert_dir_exists "$agents" || return 1

    # An agent Kurama never installed, with the user's own backups beside it.
    printf 'mine\n' > "$agents/my-own-agent.md"
    printf 'v1\n'   > "$agents/my-own-agent.md.bak.20200101000000"
    printf 'v2\n'   > "$agents/my-own-agent.md.bak.20200102000000"
    # ...and stale backups of an agent the receipt DOES record.
    printf 'old\n'  > "$agents/sdd-spec.md.bak.20200101000000"
    printf 'old\n'  > "$agents/sdd-spec.md.bak.20200102000000"

    bash "$UPDATE_SCRIPT" --agent claude-code > /dev/null 2>&1 \
        || { echo "update.sh failed"; return 1; }

    assert_file_exists "$agents/my-own-agent.md" || return 1
    assert_file_exists "$agents/my-own-agent.md.bak.20200101000000" || {
        echo "update deleted a backup of a user-owned agent"; return 1; }
    assert_file_exists "$agents/my-own-agent.md.bak.20200102000000" || {
        echo "update deleted a backup of a user-owned agent"; return 1; }

    # The recorded agent is still pruned to a single backup — the one this very
    # re-sync wrote, whose timestamp sorts after both 2020 ones.
    local kept
    kept=$(count_matching_files "$agents" 'sdd-spec.md.bak.*')
    assert_eq "1" "$kept" "a recorded agent keeps exactly one backup" || return 1
    if [ -f "$agents/sdd-spec.md.bak.20200101000000" ]; then
        echo "the stale backup of a recorded agent was not pruned"; return 1
    fi
    return 0
}

# The re-sync delegates to setup.sh with stdout AND stderr on /dev/null, so
# every failure surfaced as a bare "Re-sync failed for <slug>" — on the exact
# path a user walks while recovering a broken install. The cause must reach them.
test_update_failure_shows_delegated_setup_output() {
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" --non-interactive > /dev/null 2>&1 \
        || { echo "project-scope setup failed"; return 1; }
    # The target stops being a git repo (a deleted .git, a moved checkout, a
    # restored backup): setup.sh refuses it in non-interactive mode and says so.
    rm -rf "$repo/.git"

    local output status=0
    output=$(bash "$UPDATE_SCRIPT" --scope project --path "$repo" 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        echo "update exited 0 although the delegated setup.sh failed"; return 1
    fi
    printf '%s\n' "$output" | grep -q 'Re-sync failed' || {
        echo "no per-target failure line:"; printf '%s\n' "$output"; return 1; }
    printf '%s\n' "$output" | grep -q 'not a git repository' || {
        echo "the delegated setup.sh output never reaches the user:"
        printf '%s\n' "$output"
        return 1
    }
    return 0
}

# Same mechanism as the OpenCode mode/profile loss fixed in #22: update.sh
# delegates with --non-interactive, where ask_engram defaults to "no", so the
# FIRST update re-stamped the receipt engram: no and the choice was gone. The
# receipt already records it — re-pass it like the --with-logo carry-over.
test_update_carries_engram_across_resync() {
    bash "$SETUP_SCRIPT" --agent claude-code --with-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup claude-code --with-engram failed"; return 1; }
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    grep -q '"engram": "yes"' "$manifest" || {
        echo "setup did not record engram: yes"; return 1; }

    bash "$UPDATE_SCRIPT" --agent claude-code > /dev/null 2>&1 \
        || { echo "update.sh failed"; return 1; }

    grep -q '"engram": "yes"' "$manifest" || {
        echo "update.sh re-stamped the receipt — the Engram choice is lost:"
        grep '"engram"' "$manifest"
        return 1
    }
    return 0
}

# ec8cdf3 fixed the multi-target abort for the REFUSAL branch (a mode-less
# OpenCode receipt). An unrecognized tool leaves resync_target by the other
# door — it is filed as a failure, not a refusal — so pin that branch too: the
# targets queued behind it must still be updated, and the run must close with a
# summary naming the one it skipped.
test_update_unrecognized_tool_does_not_abort_the_other_targets() {
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup claude-code failed"; return 1; }
    bash "$SETUP_SCRIPT" --agent codex --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup codex failed"; return 1; }

    # A receipt from a harness Kurama no longer supports. ALL_AGENTS puts
    # claude-code FIRST, so this unusable target is handled before codex.
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    local rewritten
    rewritten=$(awk '{ gsub(/"claude-code"/, "\"gemini-cli\""); print }' "$manifest")
    printf '%s\n' "$rewritten" > "$manifest"

    local codex_skill="$HOME/.codex/skills/sdd-apply/SKILL.md"
    assert_file_exists "$codex_skill" || return 1
    printf 'clobbered\n' > "$codex_skill"

    local output status=0
    output=$(bash "$UPDATE_SCRIPT" 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        echo "an unusable receipt must still make the run exit non-zero"; return 1
    fi
    if grep -q '^clobbered$' "$codex_skill"; then
        echo "codex was never re-synced — the unusable receipt aborted the loop"
        printf '%s\n' "$output"
        return 1
    fi
    printf '%s\n' "$output" | grep -q 'Not updated' || {
        echo "no end-of-run summary naming the skipped target:"
        printf '%s\n' "$output"
        return 1
    }
    return 0
}

# A drift preview that compared NOTHING must not report "no drift". Every
# recorded file whose path has no repo mapping is skipped, and a receipt where
# every file is skipped used to still print "No drift — all N recorded file(s)
# match": a green light over zero comparisons, on the script users reach for when
# they already suspect the install is broken. The headline counts only what was
# actually compared, and says so when that is nothing.
test_update_dry_run_says_when_nothing_was_comparable() {
    bash "$SETUP_SCRIPT" --agent omp --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup omp failed"; return 1; }
    local manifest="$HOME/.omp/agent/skills/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    # omp's RULES.md is the one recorded path with no repo source mapping. A
    # receipt holding only it is a target where nothing is comparable.
    assert_file_exists "$HOME/.omp/agent/RULES.md" || return 1
    printf '%s\n' \
        '{' \
        '  "name": "kurama",' \
        '  "version": "6.0.0",' \
        '  "tool": "omp",' \
        '  "tools": [' \
        '    "omp"' \
        '  ],' \
        '  "scope": "global",' \
        '  "engram": "no",' \
        '  "files": [' \
        '    "../RULES.md"' \
        '  ],' \
        '  "settings": [],' \
        '  "pi_packages": [],' \
        '  "engram_mcp": [],' \
        '  "prompts": [],' \
        '  "tui_plugins": [],' \
        '  "opencode_configs": []' \
        '}' > "$manifest"

    local output status=0
    output=$(bash "$UPDATE_SCRIPT" --agent omp --dry-run 2>&1) || status=$?
    assert_eq "0" "$status" "a dry run must exit 0" || return 1

    if printf '%s\n' "$output" | grep -qi 'no drift'; then
        echo "the preview claimed 'no drift' having compared nothing:"
        printf '%s\n' "$output"
        return 1
    fi
    printf '%s\n' "$output" | grep -qi 'nothing comparable' || {
        echo "the preview never says it could compare nothing:"
        printf '%s\n' "$output"
        return 1
    }
    return 0
}

# The preview must not describe a target the real run would refuse. The tool
# validation used to sit BELOW the dry-run return, so a receipt with an
# unrecognized tool got a plausible drift report and no hint that `update.sh`
# without --dry-run would refuse it outright.
test_update_dry_run_refuses_what_the_real_run_would_refuse() {
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup claude-code failed"; return 1; }
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    local rewritten
    rewritten=$(awk '{ gsub(/"claude-code"/, "\"gemini-cli\""); print }' "$manifest")
    printf '%s\n' "$rewritten" > "$manifest"

    local output status=0
    output=$(bash "$UPDATE_SCRIPT" --agent claude-code --dry-run 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        echo "the preview exited 0 for a target the real run refuses:"
        printf '%s\n' "$output"
        return 1
    fi
    printf '%s\n' "$output" | grep -q 'Unrecognized tool' || {
        echo "the preview never names the unusable tool:"
        printf '%s\n' "$output"
        return 1
    }
    if printf '%s\n' "$output" | grep -qi 'no drift'; then
        echo "the preview reported a drift verdict for a refused target:"
        printf '%s\n' "$output"
        return 1
    fi
    return 0
}

echo -e "${BOLD}#32 — update.sh hardening${NC}"
run_test "--dry-run names the recorded files that drifted" test_update_dry_run_reports_drifted_files
run_test "--dry-run on a pristine install reports no drift" test_update_dry_run_clean_install_reports_no_drift
run_test "--dry-run says when nothing was comparable" test_update_dry_run_says_when_nothing_was_comparable
run_test "--dry-run refuses what the real run would refuse" test_update_dry_run_refuses_what_the_real_run_would_refuse
run_test "the backup prune spares user-owned agent backups" test_update_prune_spares_user_owned_agent_backups
run_test "a failed re-sync shows the delegated setup.sh output" test_update_failure_shows_delegated_setup_output
run_test "--with-engram survives a re-sync" test_update_carries_engram_across_resync
run_test "an unusable receipt does not abort the queued targets" test_update_unrecognized_tool_does_not_abort_the_other_targets
# ===== UNIT-C (issue #35) =====
#
# #35: plugin.json shipped two defects — homepage/repository still pointed at
# the pre-rename Gentleman-Programming/agent-teams-lite repo instead of this
# repo's real origin, and the "agents" array hand-listed only the 9 SDD-phase
# agents, silently missing the 8 review-layer agents (the 4R lenses,
# review-refuter, the two Judgment Day judges, and jd-fix-agent) that
# setup.sh's install_native_agents() copies wholesale from
# examples/claude-code/agents/*.md for --agent claude-code. The Claude Code
# plugin schema's "agents" field takes file paths (a string or an array), not
# a directory glob like "skills" gets, so the manifest list has to be
# hand-enumerated — which means nothing stops it drifting from the on-disk
# set the next time an agent is added or removed there. These tests close
# that gap: one confirms the repository URL fix, the other two fail loudly
# the moment examples/claude-code/agents/ and plugin.json's "agents" array
# disagree, in either direction.

# Print the sorted basenames of every *.md file directly under dir $1.
list_agent_basenames() {
    local dir="$1"
    local f base
    for f in "$dir"/*.md; do
        [ -e "$f" ] || continue
        base="${f##*/}"
        echo "$base"
    done | sort
}

# Print the sorted basenames referenced by plugin.json's "agents" array.
# jq preferred; a portable grep fallback keeps this working without jq,
# per the jq-optional invariant every script path here must honor.
plugin_json_agent_basenames() {
    local plugin_file="$1"
    local paths
    if command -v jq > /dev/null 2>&1; then
        paths=$(jq -r '.agents[]?' "$plugin_file" 2>/dev/null)
    else
        paths=$(grep -oE '"\./examples/claude-code/agents/[A-Za-z0-9_-]+\.md"' "$plugin_file" \
            | tr -d '"')
    fi
    local p
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        echo "${p##*/}"
    done <<< "$paths" | sort
}

test_plugin_json_repository_url() {
    local plugin_file="$REPO_DIR/.claude-plugin/plugin.json"
    assert_file_exists "$plugin_file" || return 1
    if grep -q 'Gentleman-Programming/agent-teams-lite' "$plugin_file"; then
        echo "plugin.json still points at the pre-rename Gentleman-Programming/agent-teams-lite repo"
        return 1
    fi
    grep -q '"homepage": "https://github.com/myst4/kurama"' "$plugin_file" \
        || { echo "plugin.json 'homepage' does not point at https://github.com/myst4/kurama"; return 1; }
    grep -q '"repository": "https://github.com/myst4/kurama"' "$plugin_file" \
        || { echo "plugin.json 'repository' does not point at https://github.com/myst4/kurama"; return 1; }
    return 0
}

test_plugin_json_agents_match_disk_set() {
    local plugin_file="$REPO_DIR/.claude-plugin/plugin.json"
    local agents_dir="$REPO_DIR/examples/claude-code/agents"
    assert_file_exists "$plugin_file" || return 1
    assert_dir_exists "$agents_dir" || return 1

    local disk_names manifest_names
    disk_names=$(list_agent_basenames "$agents_dir")
    manifest_names=$(plugin_json_agent_basenames "$plugin_file")

    if [ -z "$disk_names" ]; then
        echo "no *.md agent files found in $agents_dir"
        return 1
    fi
    if [ -z "$manifest_names" ]; then
        echo "plugin.json 'agents' field is empty or unparseable"
        return 1
    fi

    assert_eq "$disk_names" "$manifest_names" \
        "plugin.json 'agents' list has drifted from examples/claude-code/agents/ on disk"
}

test_plugin_json_agents_count_is_17() {
    local plugin_file="$REPO_DIR/.claude-plugin/plugin.json"
    local count
    count=$(plugin_json_agent_basenames "$plugin_file" | wc -l | tr -d ' ')
    assert_eq "17" "$count" "plugin.json must register all 17 Claude Code agents"
}

echo -e "${BOLD}UNIT-C (issue #35) — plugin.json manifest drift${NC}"
run_test "plugin.json homepage/repository point at myst4/kurama" test_plugin_json_repository_url
run_test "plugin.json 'agents' matches examples/claude-code/agents/ on disk" test_plugin_json_agents_match_disk_set
run_test "plugin.json registers all 17 agents" test_plugin_json_agents_count_is_17

# ===== UNIT-B (issue #33) =====
# ============================================================================
# uninstall.sh hardening — three defects, all on the highest-blast-radius path
# in the repo (the one that calls rm):
#
#   1. `--agent X --scope project` interpolated X into the LABEL only and then
#      removed the whole shared project receipt — every harness's files, and the
#      kurama block out of both CLAUDE.md and AGENTS.md — while printing one
#      harness's name. A project receipt carries no per-tool attribution, so the
#      only honest answers are "remove everything" or "refuse". It now refuses.
#   2. Without jq the hooks block cannot be stripped from settings.json, but the
#      files[] sweep ran FIRST: the hook scripts were deleted, the strip then
#      warned and returned, and the run exited 0 — leaving settings.json invoking
#      executables that no longer exist. Now detected before anything is removed.
#   3. files[] came straight from a receipt that, in project scope, lives inside
#      the target repo and is written by whoever wrote that repo. Entries were
#      joined onto the target dir and rm'd with no containment check at all.
#
# The containment rule is the subtle one: setup.sh's receipt_rel DELIBERATELY
# emits ../-anchored entries for a global install (skills sit in
# ~/.claude/skills; agents, hooks and settings.json are its SIBLINGS), so 20 of a
# claude-code receipt's 52 files[] entries legitimately start with "../". A naive
# "reject every .." rule would orphan all of them — hence the last case here,
# which pins that they still get removed.
# ============================================================================

# Insert $2 as the first element of the receipt $1's files[], verbatim. Mirrors
# collapse_receipt_files_to_empty_array's awk shape: one element per line, so a
# crafted entry is indistinguishable from a recorded one to every reader.
inject_receipt_files_entry() {
    local manifest="$1" entry="$2"
    local tmp="$manifest.tmp"
    awk -v entry="$entry" '
        !injected && /^[[:space:]]*"files"[[:space:]]*:[[:space:]]*\[[[:space:]]*$/ {
            print; print "    \"" entry "\","; injected = 1; next
        }
        { print }
    ' "$manifest" > "$tmp" && mv "$tmp" "$manifest"
}

test_uninstall_rejects_agent_in_project_scope() {
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "claude-code project setup exited non-zero"; return 1; }
    bash "$SETUP_SCRIPT" --agent opencode --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "opencode project setup exited non-zero"; return 1; }

    # Preconditions: ONE receipt shared by both harnesses, and both prompt files
    # carrying a kurama block — exactly the union the old code removed wholesale.
    local manifest="$repo/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1
    grep -q 'BEGIN:kurama' "$repo/CLAUDE.md" || { echo "CLAUDE.md carries no kurama block"; return 1; }
    grep -q 'BEGIN:kurama' "$repo/AGENTS.md" || { echo "AGENTS.md carries no kurama block"; return 1; }
    local before
    before=$(count_matching_files "$repo/.claude/skills" 'SKILL.md')
    [ "$before" -gt 0 ] || { echo "no skills installed — this case would prove nothing"; return 1; }

    local output status=0
    output=$(bash "$UNINSTALL_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-pi-packages 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        echo "--agent with --scope project must not exit 0; the run reported:"
        printf '%s\n' "$output" | grep -a 'removed' | head -5
        return 1
    fi

    # A refusal removes nothing at all.
    assert_file_exists "$manifest" || { echo "the refused run deleted the receipt"; return 1; }
    assert_eq "$before" "$(count_matching_files "$repo/.claude/skills" 'SKILL.md')" \
        "the refused run removed skill files" || return 1
    grep -q 'BEGIN:kurama' "$repo/CLAUDE.md" || { echo "the refused run stripped CLAUDE.md"; return 1; }
    grep -q 'BEGIN:kurama' "$repo/AGENTS.md" || { echo "the refused run stripped AGENTS.md"; return 1; }

    # And it says how to proceed instead of leaving the user guessing.
    printf '%s\n' "$output" | grep -aq -- '--scope project' || {
        echo "the refusal never shows the all-or-nothing command; got:"
        printf '%s\n' "$output"
        return 1
    }
    return 0
}

test_uninstall_project_scope_removes_every_harness_without_agent() {
    # The other half of the ruling: the documented all-or-nothing path must
    # really clear BOTH harnesses, or the refusal above just strands the user.
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "claude-code project setup exited non-zero"; return 1; }
    bash "$SETUP_SCRIPT" --agent opencode --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "opencode project setup exited non-zero"; return 1; }
    mkdir -p "$repo/.claude/skills/my-custom"
    echo "keep me" > "$repo/.claude/skills/my-custom/SKILL.md"

    local status=0
    bash "$UNINSTALL_SCRIPT" --scope project --path "$repo" --without-pi-packages \
        > /dev/null 2>&1 || status=$?
    assert_eq "0" "$status" "the all-or-nothing project uninstall must exit 0" || return 1

    if [ -f "$repo/.kurama-install-manifest.json" ]; then echo "receipt not removed"; return 1; fi
    if [ -d "$repo/.claude/skills/sdd-apply" ]; then echo "sdd-apply not removed"; return 1; fi
    local f
    for f in CLAUDE.md AGENTS.md; do
        if [ -f "$repo/$f" ] && grep -q 'BEGIN:kurama' "$repo/$f"; then
            echo "uninstall left a BEGIN:kurama block in $f"; return 1
        fi
    done
    local content
    content=$(cat "$repo/.claude/skills/my-custom/SKILL.md" 2>/dev/null || echo MISSING)
    assert_eq "keep me" "$content" "user-created skill preserved" || return 1
    return 0
}

test_uninstall_without_jq_refuses_before_deleting_hook_scripts() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    # Install WITH jq, so settings.json really carries the hooks block that a
    # jq-less removal cannot take back out.
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive \
        > /dev/null 2>&1 || { echo "setup exited non-zero"; return 1; }
    local settings="$HOME/.claude/settings.json"
    local guard="$HOME/.claude/hooks/kurama/orchestrator-write-guard.sh"
    local gate="$HOME/.claude/hooks/kurama/archive-gate.sh"
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    assert_file_exists "$settings" || return 1
    assert_file_exists "$guard" || return 1
    assert_file_exists "$gate" || return 1
    grep -q 'hooks/kurama/' "$settings" || { echo "setup wrote no hooks block"; return 1; }

    local output status=0
    output=$(PATH="$bindir" bash "$UNINSTALL_SCRIPT" --agent claude-code \
        --without-pi-packages 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        echo "a jq-less run that cannot clean settings.json must not exit 0; it said:"
        printf '%s\n' "$output" | tail -5
        return 1
    fi

    # The whole point: settings.json still names the hooks, so the hooks are
    # still there. Deleting them first is what made every Edit/Write fail.
    grep -q 'hooks/kurama/' "$settings" || { echo "the refused run mangled settings.json"; return 1; }
    assert_file_exists "$guard" || {
        echo "the write-guard hook was deleted while settings.json still invokes it"; return 1; }
    assert_file_exists "$gate" || {
        echo "the archive-gate hook was deleted while settings.json still invokes it"; return 1; }
    assert_file_exists "$manifest" || { echo "the refused run deleted the receipt"; return 1; }
    assert_dir_exists "$HOME/.claude/skills/sdd-apply" || {
        echo "the refused run removed skills"; return 1; }

    # It must name exactly what to remove by hand — the settings file and the
    # hook scripts — or the user cannot get out of the state it just refused.
    printf '%s\n' "$output" | grep -aqF "$settings" || {
        echo "the refusal does not name settings.json; got:"; printf '%s\n' "$output"; return 1; }
    printf '%s\n' "$output" | grep -aqF 'orchestrator-write-guard.sh' || {
        echo "the refusal does not name the hook scripts; got:"; printf '%s\n' "$output"; return 1; }
    return 0
}

test_uninstall_without_jq_still_clears_a_target_with_no_hooks_block() {
    # The guard must be narrow: codex records no settings[] at all, so there is
    # nothing jq is needed for and a jq-less uninstall must still complete.
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    bash "$SETUP_SCRIPT" --agent codex --without-engram --non-interactive \
        > /dev/null 2>&1 || { echo "codex setup exited non-zero"; return 1; }
    local skills="$HOME/.codex/skills"
    assert_dir_exists "$skills/sdd-apply" || return 1

    local output status=0
    output=$(PATH="$bindir" bash "$UNINSTALL_SCRIPT" --agent codex \
        --without-pi-packages 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
        echo "a jq-less uninstall with nothing to strip must exit 0 (got $status):"
        printf '%s\n' "$output" | tail -10
        return 1
    fi
    if [ -d "$skills/sdd-apply" ]; then echo "sdd-apply survived the uninstall"; return 1; fi
    if [ -f "$skills/.kurama-install-manifest.json" ]; then echo "receipt survived"; return 1; fi
    return 0
}

test_uninstall_refuses_absolute_receipt_files_entry() {
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "project setup exited non-zero"; return 1; }

    local outside="$TEST_TMPDIR/outside"
    mkdir -p "$outside"
    echo "do not touch" > "$outside/canary.txt"

    local manifest="$repo/.kurama-install-manifest.json"
    inject_receipt_files_entry "$manifest" "$outside/canary.txt"
    grep -qF "\"$outside/canary.txt\"," "$manifest" || {
        echo "the crafted absolute entry was not injected"; return 1; }

    local output status=0
    output=$(bash "$UNINSTALL_SCRIPT" --scope project --path "$repo" \
        --without-pi-packages 2>&1) || status=$?

    assert_file_exists "$outside/canary.txt" || {
        echo "an absolute receipt entry reached a file outside the target dir"; return 1; }
    printf '%s\n' "$output" | grep -aq 'refusing' || {
        echo "the absolute entry was accepted silently (exit $status); got:"
        printf '%s\n' "$output" | head -20
        return 1
    }
    # A tampered receipt must be distinguishable from a clean uninstall by exit
    # code alone — a caller that only checks $? would otherwise never know.
    if [ "$status" -eq 0 ]; then
        echo "a refused receipt entry must not exit 0"
        return 1
    fi
    return 0
}

test_uninstall_refuses_parent_traversal_receipt_files_entry() {
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "project setup exited non-zero"; return 1; }

    # A sibling of the target repo — reachable from it with a single "..", which
    # is what a hostile or corrupt receipt in a cloned repo would use.
    local outside="$TEST_TMPDIR/outside"
    mkdir -p "$outside"
    echo "do not touch" > "$outside/canary.txt"

    local manifest="$repo/.kurama-install-manifest.json"
    inject_receipt_files_entry "$manifest" "../outside/canary.txt"
    grep -qF '"../outside/canary.txt",' "$manifest" || {
        echo "the crafted traversal entry was not injected"; return 1; }

    local output status=0
    output=$(bash "$UNINSTALL_SCRIPT" --scope project --path "$repo" \
        --without-pi-packages 2>&1) || status=$?

    assert_file_exists "$outside/canary.txt" || {
        echo "a ../ receipt entry deleted a file outside the target repo"; return 1; }
    # The prune walk runs off the same list: an accepted traversal entry also
    # let rmdir climb out of the target.
    assert_dir_exists "$outside" || {
        echo "the prune walk removed a directory outside the target repo"; return 1; }
    printf '%s\n' "$output" | grep -aq 'refusing' || {
        echo "the traversal entry was accepted silently (exit $status); got:"
        printf '%s\n' "$output" | head -20
        return 1
    }
    if [ "$status" -eq 0 ]; then
        echo "a refused receipt entry must not exit 0"
        return 1
    fi
    return 0
}

# Rewrite the receipt $1's "scope" scalar to $2, or delete the field entirely
# when $2 is empty. Lets a case hand uninstall a receipt that LIES about its own
# scope — which in project scope is not a hypothetical: the receipt is a file in
# the target repo, written by whoever wrote that repo.
set_receipt_scope() {
    local manifest="$1" scope="$2"
    local tmp="$manifest.tmp"
    if [ -n "$scope" ]; then
        awk -v s="$scope" '
            /^[[:space:]]*"scope"[[:space:]]*:/ {
                sub(/:[[:space:]]*"[^"]*"/, ": \"" s "\""); print; next
            }
            { print }
        ' "$manifest" > "$tmp" && mv "$tmp" "$manifest"
    else
        awk '!/^[[:space:]]*"scope"[[:space:]]*:/' "$manifest" > "$tmp" && mv "$tmp" "$manifest"
    fi
}

test_uninstall_ignores_a_receipt_that_lies_about_its_scope() {
    # The containment bound must come from HOW THE TARGET WAS ADDRESSED, not
    # from a field inside the attacker-supplied receipt. A project receipt
    # claiming "global" — or simply omitting "scope", which defaults to global —
    # widened the bound to the PARENT of the repo, so the documented
    # `--scope project --path <repo>` reached ../<sibling>/ and deleted it.
    local claim
    for claim in global ""; do
        local repo="$TEST_TMPDIR/proj-${claim:-absent}"
        make_git_repo "$repo"
        bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
            --without-engram --non-interactive > /dev/null 2>&1 \
            || { echo "project setup exited non-zero"; return 1; }

        local outside="$TEST_TMPDIR/outside-${claim:-absent}"
        mkdir -p "$outside"
        echo "do not touch" > "$outside/canary.txt"

        local manifest="$repo/.kurama-install-manifest.json"
        inject_receipt_files_entry "$manifest" "../outside-${claim:-absent}/canary.txt"
        set_receipt_scope "$manifest" "$claim"
        # Precondition: the receipt really does claim what this case needs.
        if [ -n "$claim" ]; then
            grep -q '"scope"[[:space:]]*:[[:space:]]*"global"' "$manifest" || {
                echo "the receipt was not made to claim global scope"; return 1; }
        else
            if grep -q '"scope"[[:space:]]*:' "$manifest"; then
                echo "the scope field was not removed from the receipt"; return 1
            fi
        fi

        local output status=0
        output=$(bash "$UNINSTALL_SCRIPT" --scope project --path "$repo" \
            --without-pi-packages 2>&1) || status=$?

        assert_file_exists "$outside/canary.txt" || {
            echo "a receipt claiming scope='${claim:-<absent>}' widened the bound and deleted outside the repo"
            return 1
        }
        assert_dir_exists "$outside" || {
            echo "the prune walk climbed out under a spoofed scope='${claim:-<absent>}'"; return 1; }
        printf '%s\n' "$output" | grep -aq 'refusing' || {
            echo "scope='${claim:-<absent>}' was accepted silently (exit $status); got:"
            printf '%s\n' "$output" | head -20
            return 1
        }
        if [ "$status" -eq 0 ]; then
            echo "a refused entry under scope='${claim:-<absent>}' must not exit 0"
            return 1
        fi
    done
    return 0
}

test_uninstall_refuses_an_entry_behind_a_symlinked_directory() {
    # Containment cannot be purely textual while rm is physical. git versions
    # symlinks, so in project scope BOTH halves ship in the hostile repo: a
    # symlinked directory and a receipt entry pointing through it. The textual
    # check reads "repo/evil/id_rsa" as inside the repo; rm resolves `evil` and
    # deletes the real file somewhere else entirely.
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "project setup exited non-zero"; return 1; }

    local secrets="$TEST_TMPDIR/secrets"
    mkdir -p "$secrets"
    echo "do not touch" > "$secrets/id_rsa"
    ln -s "$secrets" "$repo/evil"
    # Precondition: the symlink really does resolve out of the repo, so the
    # textual reading and the physical one genuinely disagree.
    assert_file_exists "$repo/evil/id_rsa" || {
        echo "the symlinked directory does not resolve — this case would prove nothing"
        return 1
    }

    local manifest="$repo/.kurama-install-manifest.json"
    inject_receipt_files_entry "$manifest" "evil/id_rsa"
    grep -qF '"evil/id_rsa",' "$manifest" || {
        echo "the crafted symlink entry was not injected"; return 1; }

    local output status=0
    output=$(bash "$UNINSTALL_SCRIPT" --scope project --path "$repo" \
        --without-pi-packages 2>&1) || status=$?

    assert_file_exists "$secrets/id_rsa" || {
        echo "an entry behind a symlinked directory deleted a file outside the repo"; return 1; }
    printf '%s\n' "$output" | grep -aq 'refusing' || {
        echo "the symlinked-directory entry was accepted silently (exit $status); got:"
        printf '%s\n' "$output" | head -20
        return 1
    }
    if [ "$status" -eq 0 ]; then
        echo "a refused receipt entry must not exit 0"
        return 1
    fi
    return 0
}

test_uninstall_still_removes_legitimate_parent_anchored_entries() {
    # The containment rule must not be "reject every ..": a global receipt
    # records agents and hooks as ../-anchored siblings of the skills dir, and
    # rejecting those would leave 20 of 52 recorded files on disk forever.
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive \
        > /dev/null 2>&1 || { echo "setup exited non-zero"; return 1; }
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1

    local ups
    ups=$(receipt_array_values "$manifest" "files" | grep -c '^\.\./' || true)
    [ "${ups:-0}" -gt 0 ] || {
        echo "the receipt records no ../-anchored entries — this case would prove nothing"
        return 1
    }
    assert_dir_exists "$HOME/.claude/agents" || return 1
    assert_file_exists "$HOME/.claude/hooks/kurama/orchestrator-write-guard.sh" || return 1

    local status=0
    bash "$UNINSTALL_SCRIPT" --agent claude-code --without-pi-packages \
        > /dev/null 2>&1 || status=$?
    # Also the "clean run" half of the exit-code contract the containment cases
    # assert from the other side: an untampered receipt exits 0.
    assert_eq "0" "$status" "the uninstall must exit 0" || return 1

    local left
    left=$(count_matching_files "$HOME/.claude/agents" 'sdd-*.md')
    assert_eq "0" "$left" "../agents entries survived the uninstall" || return 1
    if [ -d "$HOME/.claude/hooks/kurama" ]; then
        echo "../hooks entries survived the uninstall"; return 1
    fi
    return 0
}

echo -e "${BOLD}#33 — uninstall hardening (UNIT-B)${NC}"
run_test "--agent with --scope project refuses and removes nothing" test_uninstall_rejects_agent_in_project_scope
run_test "the all-or-nothing project uninstall clears every harness" test_uninstall_project_scope_removes_every_harness_without_agent
run_test "without jq, uninstall refuses before deleting the hook scripts" test_uninstall_without_jq_refuses_before_deleting_hook_scripts
run_test "without jq, a target with no hooks block still uninstalls" test_uninstall_without_jq_still_clears_a_target_with_no_hooks_block
run_test "an absolute receipt files[] entry is refused" test_uninstall_refuses_absolute_receipt_files_entry
run_test "a ../ receipt files[] entry is refused" test_uninstall_refuses_parent_traversal_receipt_files_entry
run_test "a receipt that lies about its scope cannot widen the bound" test_uninstall_ignores_a_receipt_that_lies_about_its_scope
run_test "an entry behind a symlinked directory is refused" test_uninstall_refuses_an_entry_behind_a_symlinked_directory
run_test "legitimate ../-anchored entries are still removed" test_uninstall_still_removes_legitimate_parent_anchored_entries

echo ""

# ============================================================================
# ===== UNIT-E (issue #39) =====
#
# setup.sh minor hardening. Two independent defects, one section:
#   1. Backups were unconditional. `make_backup` ran before every write with no
#      comparison against what was about to be written, so a plain idempotent
#      re-run copied 19 byte-identical files aside as <file>.bak.<timestamp>
#      (measured on a sandboxed HOME: 3 runs → 38 files, all identical).
#   2. The `--scope project` guard only string-compared the target against the
#      clone root, so any SUBDIRECTORY of the Kurama clone was accepted and got
#      .claude/, CLAUDE.md and the receipt written into the source tree.
# ============================================================================

# A throwaway copy of the Kurama clone: its own git repo, its own scripts/setup.sh,
# and the sources a project install reads. The clone-guard tests below point
# --path INTO this copy, so a regression writes into $TEST_TMPDIR instead of the
# real source tree — and the guard still faces a genuine "target inside the clone
# that is running setup", because the setup.sh under test is the staged one.
stage_kurama_clone_files() {
    local dest="$1"
    mkdir -p "$dest/scripts" "$dest/docs" || return 1
    cp "$SCRIPT_DIR/setup.sh" "$SCRIPT_DIR/banner.sh" "$dest/scripts/" || return 1
    # setup.sh sources scripts/lib/receipt.sh (issue #37) and aborts without it,
    # so a staged clone must ship the lib exactly as a real clone does.
    cp -R "$SCRIPT_DIR/lib" "$dest/scripts/lib" || return 1
    cp -R "$REPO_DIR/examples" "$REPO_DIR/skills" "$dest/" || return 1
    cp "$REPO_DIR/VERSION" "$dest/VERSION" || return 1
    printf '# staged docs\n' > "$dest/docs/index.md" || return 1
    [ -d "$dest/skills/sdd-apply" ] || return 1
    return 0
}

stage_kurama_clone() {
    stage_kurama_clone_files "$1" || return 1
    make_git_repo "$1"
    return 0
}

# Report (and clear) the artifacts a project-scope install leaves in a directory.
# Named paths only — never a glob — so a failing guard test cleans up after
# itself without ever being able to delete something it did not create.
project_install_artifacts_cleared() {
    local dir="$1" leaked=0 stray
    for stray in "$dir/.claude" "$dir/CLAUDE.md" "$dir/.kurama-install-manifest.json"; do
        if [ -e "$stray" ]; then
            rm -rf "$stray"
            leaked=1
        fi
    done
    [ "$leaked" -eq 0 ]
}

test_setup_rerun_writes_no_new_backups() {
    # The whole point of an idempotent installer: running it twice leaves the disk
    # where the first run left it. Nothing setup writes changes between two
    # identical runs, so a second wave of .bak files is pure noise in the user's
    # config dir — and it is unbounded, one wave per re-run, forever.
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "the first setup run exited non-zero"; return 1; }
    local first
    first=$(find "$HOME" -name '*.bak.*' | wc -l | tr -d ' ')
    assert_eq "0" "$first" "a fresh install has nothing to back up" || return 1

    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "the second setup run exited non-zero"; return 1; }
    local second
    second=$(find "$HOME" -name '*.bak.*' | wc -l | tr -d ' ')
    if [ "$second" -ne 0 ]; then
        echo "an unchanged re-run wrote $second backup file(s), e.g.:"
        find "$HOME" -name '*.bak.*' | sed "s|$HOME|~|" | head -5
        return 1
    fi
    return 0
}

test_setup_rerun_still_backs_up_a_hand_edited_file() {
    # The other half of the contract: the skip is content-based, NOT "never back
    # up on a re-run". A file the user edited by hand is still copied aside
    # before setup overwrites it — and it is the ONLY file backed up.
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "the first setup run exited non-zero"; return 1; }
    local victim="$HOME/.claude/agents/review-risk.md"
    assert_file_exists "$victim" || return 1
    printf 'HAND EDITED BODY\n' > "$victim"

    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "the second setup run exited non-zero"; return 1; }

    local baks bak
    baks=$(find "$HOME" -name '*.bak.*' | wc -l | tr -d ' ')
    if [ "$baks" -ne 1 ]; then
        echo "expected exactly one backup (the hand-edited file), got $baks:"
        find "$HOME" -name '*.bak.*' | sed "s|$HOME|~|" | head -5
        return 1
    fi
    bak=$(find "$HOME" -name 'review-risk.md.bak.*' | head -1)
    [ -n "$bak" ] || { echo "the hand-edited agent was not the file backed up"; return 1; }
    grep -qF 'HAND EDITED BODY' "$bak" || {
        echo "the backup does not hold the hand-edited content"; return 1; }
    if grep -qF 'HAND EDITED BODY' "$victim"; then
        echo "the file was backed up but never replaced with the shipped version"
        return 1
    fi
    return 0
}

test_scope_project_rejects_a_subdirectory_of_the_clone() {
    # `--path <clone>/docs` used to be accepted: the guard compared the target
    # string against the clone ROOT only, so every subdirectory slipped through
    # and Kurama installed itself into its own source tree.
    local clone="$TEST_TMPDIR/staged-clone"
    stage_kurama_clone "$clone" || { echo "could not stage the throwaway clone"; return 1; }

    local output status=0
    output=$(bash "$clone/scripts/setup.sh" --agent claude-code --scope project \
        --path "$clone/docs" --without-engram --non-interactive 2>&1) || status=$?

    local clean=0
    project_install_artifacts_cleared "$clone/docs" || clean=1
    if [ "$status" -eq 0 ]; then
        echo "setup accepted a subdirectory of its own clone as a project target"
        printf '%s\n' "$output" | tail -5
        return 1
    fi
    if [ "$clean" -ne 0 ]; then
        echo "setup refused the target but still wrote into the clone's docs/"
        return 1
    fi
    printf '%s\n' "$output" | grep -qF 'Refusing to install into the Kurama' || {
        echo "the refusal never says the target is the Kurama clone:"
        printf '%s\n' "$output" | tail -5
        return 1
    }
    return 0
}

test_scope_project_rejects_a_symlink_into_the_clone() {
    # The same rejection through a symlink: `cd $link && pwd` keeps the LOGICAL
    # path, so no string comparison against the clone root can see through it.
    # Comparing git toplevels does, because git resolves the path physically.
    local clone="$TEST_TMPDIR/staged-clone-link"
    stage_kurama_clone "$clone" || { echo "could not stage the throwaway clone"; return 1; }
    local link="$TEST_TMPDIR/linked-docs"
    ln -s "$clone/docs" "$link" || { echo "could not create the symlink"; return 1; }

    local output status=0
    output=$(bash "$clone/scripts/setup.sh" --agent claude-code --scope project \
        --path "$link" --without-engram --non-interactive 2>&1) || status=$?

    local clean=0
    project_install_artifacts_cleared "$clone/docs" || clean=1
    if [ "$status" -eq 0 ]; then
        echo "setup followed a symlink into its own clone and installed there"
        printf '%s\n' "$output" | tail -5
        return 1
    fi
    if [ "$clean" -ne 0 ]; then
        echo "setup refused the symlink but still wrote through it into the clone"
        return 1
    fi
    return 0
}

test_scope_project_guard_does_not_misfire_on_a_non_repo() {
    # The guard rejects a target that resolves INTO the clone, not every target it
    # cannot resolve. A plain directory outside any repo still gets the
    # pre-existing "not a git repository" abort, with its own remedy.
    local plain="$TEST_TMPDIR/plain-dir"
    mkdir -p "$plain"

    local output status=0
    output=$(bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$plain" \
        --without-engram --non-interactive 2>&1) || status=$?

    [ "$status" -ne 0 ] || { echo "a non-git target must still abort"; return 1; }
    printf '%s\n' "$output" | grep -qF 'not a git repository' || {
        echo "a non-git target lost its own diagnostic:"
        printf '%s\n' "$output" | tail -5
        return 1
    }
    if printf '%s\n' "$output" | grep -qF 'Refusing to install into the Kurama'; then
        echo "the clone guard misfired on a directory outside the clone:"
        printf '%s\n' "$output" | tail -5
        return 1
    fi
    return 0
}

test_scope_project_allows_a_repo_that_vendors_a_kurama_copy() {
    # The guard protects a Kurama CLONE, not "every work tree that happens to
    # contain a copy of Kurama". A project that vendors an unpacked (non-git)
    # Kurama under tools/ shares its git toplevel with that copy, so a bare
    # toplevel comparison would refuse the user's own repository.
    local proj="$TEST_TMPDIR/vendoring-project"
    make_git_repo "$proj"
    stage_kurama_clone_files "$proj/tools/kurama" \
        || { echo "could not stage the vendored Kurama copy"; return 1; }

    bash "$proj/tools/kurama/scripts/setup.sh" --agent claude-code --scope project \
        --path "$proj" --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup refused a project that merely vendors a Kurama copy"; return 1; }
    assert_dir_exists "$proj/.claude/skills/sdd-apply" || return 1
    return 0
}

echo -e "${BOLD}#39 — setup.sh minor hardening (backups + clone guard)${NC}"
run_test "an unchanged re-run writes no new .bak files" test_setup_rerun_writes_no_new_backups
run_test "a hand-edited file is still backed up, and only it" test_setup_rerun_still_backs_up_a_hand_edited_file
run_test "--scope project refuses a subdirectory of the clone" test_scope_project_rejects_a_subdirectory_of_the_clone
run_test "--scope project refuses a symlink into the clone" test_scope_project_rejects_a_symlink_into_the_clone
run_test "the clone guard does not misfire on a non-repo target" test_scope_project_guard_does_not_misfire_on_a_non_repo
run_test "a repo that vendors a Kurama copy is still installable" test_scope_project_allows_a_repo_that_vendors_a_kurama_copy

# ===== UNIT-D (issue #36) =====
# ============================================================================
# #36 — the first thing anyone sees: banner.sh's degradation ladder and size
# probe, its MCP count without jq, and setup-tui.sh's copy-this-command preview.
#
# Self-contained: helpers, cases and run_test calls all live in this block so it
# can move as one piece.
#
# What is NOT asserted here, because a test suite has no terminal: the fade-in
# itself. `animate()` requires `[ -t 1 ]`, so every render below is the one-shot
# path. The five-frame repaint was verified by hand in a pty — see the notes in
# the PR — and the property that makes it correct (the whole render fits the
# terminal on both axes) is exactly what these cases pin.
# ============================================================================

BANNER_SCRIPT="$SCRIPT_DIR/banner.sh"

# Render the banner as if the terminal were $1 x $2. NO_COLOR so the assertions
# measure glyphs instead of escape sequences; --no-anim because there is no tty
# to animate on anyway and the flag makes that explicit.
unit_d_render_banner() { # cols rows outfile
    NO_COLOR=1 KURAMA_BANNER_COLS="$1" KURAMA_BANNER_ROWS="$2" \
        bash "$BANNER_SCRIPT" --no-anim > "$3" 2>&1
}

# Widest DISPLAY column of any line in $1 — bytes minus UTF-8 continuation
# bytes, the same locale-independent count banner.sh's dispw does. `wc -m` and
# awk are not reliably UTF-8 aware on macOS, and the art is Braille.
unit_d_widest_col() { # file
    local line tot cont w max=0
    while IFS= read -r line || [ -n "$line" ]; do
        tot=$(printf '%s' "$line" | LC_ALL=C wc -c | tr -d ' ')
        cont=$(printf '%s' "$line" | LC_ALL=C tr -cd '\200-\277' | LC_ALL=C wc -c | tr -d ' ')
        w=$(( tot - cont ))
        [ "$w" -gt "$max" ] && max=$w
    done < "$1"
    printf '%s' "$max"
}

# Fail unless the render in $3 fits a $1 x $2 terminal on BOTH axes. Overflowing
# either one is what made the fade-in stack five frames on top of each other.
unit_d_assert_fits() { # cols rows file
    local cols="$1" rows="$2" file="$3" lines widest
    lines=$(wc -l < "$file" | tr -d ' ')
    widest=$(unit_d_widest_col "$file")
    if [ "$widest" -gt "$cols" ]; then
        echo "  ${cols}x${rows}: a line is $widest columns wide — it wraps"
        return 1
    fi
    if [ "$lines" -gt "$rows" ]; then
        echo "  ${cols}x${rows}: $lines lines — it scrolls"
        return 1
    fi
    return 0
}

# Every rung of the ladder, and the sizes on either side of each threshold.
test_banner_never_overflows_the_terminal() {
    local out="$TEST_TMPDIR/banner.txt" size cols rows
    for size in 200x50 145x40 145x24 144x40 100x30 95x36 95x24 80x24 80x23 \
                80x20 48x23 47x23 40x10 12x6 12x3 9x40 1x1; do
        cols="${size%x*}"; rows="${size#*x}"
        unit_d_render_banner "$cols" "$rows" "$out"
        unit_d_assert_fits "$cols" "$rows" "$out" || return 1
    done
    return 0
}

# The widest rung: fox and wordmark side by side, 145 columns of art.
test_banner_draws_the_full_art_when_it_fits() {
    local out="$TEST_TMPDIR/banner.txt" widest lines
    unit_d_render_banner 200 50 "$out"
    widest=$(unit_d_widest_col "$out")
    lines=$(wc -l < "$out" | tr -d ' ')
    if [ "$widest" -lt 140 ]; then
        echo "  a 200-column terminal drew only $widest columns — the wordmark is missing"
        return 1
    fi
    if [ "$lines" -gt 25 ]; then
        echo "  side-by-side art should be ~21 lines, got $lines (it stacked instead)"
        return 1
    fi
    return 0
}

# The regression the issue is about: 80x24 used to emit 32 lines, ten of them
# 89-95 columns wide. It must now keep the fox AND fit.
test_banner_keeps_the_fox_on_an_80x24_terminal() {
    local out="$TEST_TMPDIR/banner.txt" lines
    unit_d_render_banner 80 24 "$out"
    unit_d_assert_fits 80 24 "$out" || return 1
    lines=$(wc -l < "$out" | tr -d ' ')
    if [ "$lines" -lt 15 ]; then
        echo "  80x24 fell all the way past the fox ($lines lines)"
        return 1
    fi
    if ! grep -q 'KURAMA' "$out"; then
        echo "  80x24 drew art but never says KURAMA"
        return 1
    fi
    return 0
}

# Narrower than the fox: the one-line mark, the same rung the generated logo
# plugins fall back to.
test_banner_degrades_to_the_one_line_mark() {
    local out="$TEST_TMPDIR/banner.txt" lines
    unit_d_render_banner 40 10 "$out"
    unit_d_assert_fits 40 10 "$out" || return 1
    lines=$(wc -l < "$out" | tr -d ' ')
    if [ "$lines" -gt 6 ]; then
        echo "  40x10 should be the one-line mark plus the panel, got $lines lines"
        return 1
    fi
    if ! grep -q 'KURAMA' "$out"; then
        echo "  the compact rung dropped the name entirely"
        return 1
    fi
    return 0
}

# Last rung: nothing at all, and still exit 0 — banner.sh is chained in front of
# agent launches with &&.
test_banner_draws_nothing_when_even_the_mark_does_not_fit() {
    local out="$TEST_TMPDIR/banner.txt" status=0
    NO_COLOR=1 KURAMA_BANNER_COLS=8 KURAMA_BANNER_ROWS=40 \
        bash "$BANNER_SCRIPT" --no-anim > "$out" 2>&1 || status=$?
    if [ "$status" -ne 0 ]; then
        echo "  banner.sh exited $status on a terminal too small to draw in"
        return 1
    fi
    if [ -s "$out" ]; then
        echo "  8 columns is narrower than '✦ KURAMA ✦' but something was drawn:"
        cat "$out"
        return 1
    fi
    return 0
}

test_banner_size_probe_prefers_explicit_overrides() {
    local out
    out="$(KURAMA_BANNER_COLS=145 KURAMA_BANNER_ROWS=40 bash "$BANNER_SCRIPT" --probe-size 2>/dev/null)" \
        || { echo "  --probe-size exited non-zero"; return 1; }
    assert_eq "145 40" "$out" "the override was not honored" || return 1
    return 0
}

# Junk overrides must fall THROUGH to the real probe, not be believed and not
# crash the arithmetic that sizes the ladder.
test_banner_size_probe_ignores_junk_overrides() {
    local junk plain
    junk="$(KURAMA_BANNER_COLS=abc KURAMA_BANNER_ROWS=-5 bash "$BANNER_SCRIPT" --probe-size 2>/dev/null)" \
        || { echo "  --probe-size exited non-zero on junk input"; return 1; }
    plain="$(bash "$BANNER_SCRIPT" --probe-size 2>/dev/null)" \
        || { echo "  --probe-size exited non-zero"; return 1; }
    assert_eq "$plain" "$junk" "junk overrides changed the resolved size" || return 1
    case "$junk" in
        *[!0-9\ ]*|'' ) echo "  resolved size is not two numbers: [$junk]"; return 1 ;;
    esac
    return 0
}

# The defect itself: `tput cols` reads the window size from fd 2, so with stderr
# redirected — which is how all three callers invoke this script — it answers
# with terminfo's 80 whatever the terminal is. The probe must ask the tty.
test_banner_size_probe_reads_the_tty_not_terminfo() {
    local out tty_size t_rows t_cols
    out="$(TERM='' COLUMNS='' LINES='' bash "$BANNER_SCRIPT" --probe-size 2>/dev/null)" \
        || { echo "  --probe-size exited non-zero"; return 1; }
    tty_size="$(stty size 2>/dev/null </dev/tty || true)"
    if [ -n "$tty_size" ]; then
        t_rows="${tty_size%% *}"; t_cols="${tty_size##* }"
        assert_eq "$t_cols $t_rows" "$out" "the probe ignored the controlling tty" || return 1
    else
        # No controlling tty and no terminfo (CI): the documented default, and
        # specifically not 0, empty, or an error.
        assert_eq "80 24" "$out" "no tty and no terminfo should resolve to 80x24" || return 1
    fi
    return 0
}

# Write a config declaring $2 MCP servers to $1.
unit_d_write_mcp_config() { # file count
    local file="$1" n="$2" i=1 body=""
    mkdir -p "$(dirname "$file")"
    while [ "$i" -le "$n" ]; do
        [ -n "$body" ] && body="$body,"
        body="$body
    \"srv$i\": { \"command\": \"x\", \"args\": [\"--a\", \"1\"] }"
        i=$(( i + 1 ))
    done
    printf '{\n  "mcpServers": {%s\n  },\n  "model": "x"\n}\n' "$body" > "$file"
}

unit_d_banner_mcp_value() { # PATH file-for-output
    NO_COLOR=1 KURAMA_BANNER_COLS=120 KURAMA_BANNER_ROWS=40 PATH="$1" \
        bash "$BANNER_SCRIPT" --no-anim 2>&1 \
        | sed -n 's/.*MCP: \([^ ]*\) server(s).*/\1/p'
}

# Without jq the count was never assigned, so the panel reported "0 server(s)"
# on every machine that has any.
test_banner_counts_mcp_servers_without_jq() {
    local bindir="$TEST_TMPDIR/nojq-bin" got
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1
    unit_d_write_mcp_config "$HOME/.claude.json" 3

    got="$(unit_d_banner_mcp_value "$bindir")"
    assert_eq "3" "$got" "the no-jq fallback did not count the servers" || return 1

    # And the jq path — when this host has jq — must agree to the digit.
    got="$(unit_d_banner_mcp_value "$PATH")"
    assert_eq "3" "$got" "the ambient (jq) path disagrees with the fallback" || return 1
    return 0
}

# A legitimate 0 in the first candidate is an answer about THAT file, not about
# the machine: the walk has to continue to the second one.
test_banner_mcp_count_does_not_stop_at_a_legitimate_zero() {
    local bindir="$TEST_TMPDIR/nojq-bin" got
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1
    printf '{ "mcpServers": {} }\n' > "$HOME/.claude.json"
    unit_d_write_mcp_config "$HOME/.config/opencode/opencode.json" 2

    got="$(unit_d_banner_mcp_value "$bindir")"
    assert_eq "2" "$got" "an empty first config shadowed the second" || return 1
    got="$(unit_d_banner_mcp_value "$PATH")"
    assert_eq "2" "$got" "an empty first config shadowed the second (jq path)" || return 1
    return 0
}

# "I could not read it" must never arrive at the panel as "you have none".
test_banner_mcp_says_n_a_when_the_config_cannot_be_read() {
    local bindir="$TEST_TMPDIR/nojq-bin" got
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1
    printf 'this is not json\n' > "$HOME/.claude.json"

    got="$(unit_d_banner_mcp_value "$bindir")"
    assert_eq "n/a" "$got" "an unreadable config was reported as zero servers" || return 1
    return 0
}

# The shape Claude Code actually writes: a per-project (usually empty) mcpServers
# nested under "projects", with the real top-level key AFTER it. $2 servers at
# the top level. This is the file that broke the first-occurrence scan — jq reads
# the top-level key, an unanchored scan reads the nested empty one and says 0.
unit_d_write_claude_nested_before_toplevel() { # file top_count
    local file="$1" n="$2" i=1 body=""
    mkdir -p "$(dirname "$file")"
    while [ "$i" -le "$n" ]; do
        [ -n "$body" ] && body="$body,"
        body="$body
    \"srv$i\": { \"command\": \"x\", \"args\": [\"--a\", \"1\"] }"
        i=$(( i + 1 ))
    done
    # projects.<path>.mcpServers = {} comes first and is empty; the real one is last.
    printf '{\n  "projects": {\n    "/some/repo": { "mcpServers": {}, "allowedTools": [] }\n  },\n  "mcpServers": {%s\n  },\n  "model": "x"\n}\n' \
        "$body" > "$file"
}

# The OpenCode config shape: the "mcp" key (not "mcpServers"), preceded by a
# string VALUE equal to "mcp" that the old index()-based match counted as the
# key. $2 servers.
unit_d_write_opencode_mcp() { # file count
    local file="$1" n="$2" i=1 body=""
    mkdir -p "$(dirname "$file")"
    while [ "$i" -le "$n" ]; do
        [ -n "$body" ] && body="$body,"
        body="$body
    \"srv$i\": { \"type\": \"local\" }"
        i=$(( i + 1 ))
    done
    # "description": "mcp" is a string VALUE equal to the key name — the exact
    # thing the old index() match counted as the key.
    printf '{\n  "theme": "opencode",\n  "description": "mcp",\n  "mcp": {%s\n  }\n}\n' \
        "$body" > "$file"
}

# The Critical regression: on the real Claude Code file the top-level key is not
# the first "mcpServers" in the file, it is the last. Anchoring the scan at
# depth 1 is the whole fix. Red against the first-occurrence scan (it returns 0),
# green once the scan tracks brace depth.
test_banner_counts_mcp_under_nested_project_shape() {
    local bindir="$TEST_TMPDIR/nojq-bin" got
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1
    unit_d_write_claude_nested_before_toplevel "$HOME/.claude.json" 3

    got="$(unit_d_banner_mcp_value "$bindir")"
    assert_eq "3" "$got" "a nested project mcpServers shadowed the top-level count" || return 1
    got="$(unit_d_banner_mcp_value "$PATH")"
    assert_eq "3" "$got" "the ambient (jq) path disagrees on the nested shape" || return 1
    return 0
}

# Exercises the "mcp" branch AND the string-value guard: the "description": "mcp"
# value must not be mistaken for the key. Red against the old index() match
# (which false-matched the value and returned 0), green with the colon guard.
test_banner_counts_opencode_mcp_key_shape() {
    local bindir="$TEST_TMPDIR/nojq-bin" got
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1
    # No claude.json, so the walk falls through to the opencode candidate.
    rm -f "$HOME/.claude.json"
    unit_d_write_opencode_mcp "$HOME/.config/opencode/opencode.json" 2

    got="$(unit_d_banner_mcp_value "$bindir")"
    assert_eq "2" "$got" "the opencode \"mcp\" key was miscounted without jq" || return 1
    got="$(unit_d_banner_mcp_value "$PATH")"
    assert_eq "2" "$got" "the ambient (jq) path disagrees on the opencode shape" || return 1
    return 0
}

# ---- setup-tui.sh: the command it shows is the command it runs --------------

# The preview seam runs above the gum precondition, so it works on a PATH with
# no gum — which is every CI runner here.
unit_d_tui_preview() { # runs setup-tui.sh's preview probe with the env it reads
    KURAMA_TUI_PROBE=preview bash "$TUI_SCRIPT" 2>&1
}

# The headline "copy this command" line used to be a hand-written
# `./scripts/setup.sh …`: relative to the user's own repo under the invocation
# this script documents, and missing the --non-interactive the run appends.
test_tui_preview_is_the_argv_it_runs() {
    local line
    line="$(KURAMA_TUI_CHOSEN=opencode KURAMA_TUI_SCOPE=global \
            KURAMA_TUI_OPENCODE_MODE=multi KURAMA_TUI_ENGRAM=no KURAMA_TUI_LOGO=yes \
            unit_d_tui_preview)" || { echo "  the preview probe failed: $line"; return 1; }

    case "$line" in
        *"./scripts/"*)
            echo "  the preview is still cwd-relative: $line"; return 1 ;;
    esac
    case "$line" in
        *"$SETUP_SCRIPT"*) ;;
        *) echo "  the preview does not name this checkout's setup.sh: $line"; return 1 ;;
    esac
    case "$line" in
        *--non-interactive*) ;;
        *) echo "  the preview omits --non-interactive, so pasting it blocks on a prompt: $line"; return 1 ;;
    esac
    case "$line" in
        *"--agent opencode"*) ;;
        *) echo "  the preview lost the harness: $line"; return 1 ;;
    esac
    return 0
}

# The preview is advertised as pasteable. Pasting it has to reproduce the argv,
# including a repo path with spaces in it.
test_tui_preview_quotes_a_path_with_spaces() {
    local weird="$TEST_TMPDIR/my repo/with spaces" line found_path=no found_ni=no a
    line="$(KURAMA_TUI_CHOSEN=claude-code KURAMA_TUI_SCOPE=project \
            KURAMA_TUI_PATH="$weird" KURAMA_TUI_ENGRAM=no KURAMA_TUI_LOGO=no \
            unit_d_tui_preview)" || { echo "  the preview probe failed: $line"; return 1; }

    eval "set -- $line"
    for a in "$@"; do
        [ "$a" = "$weird" ] && found_path=yes
        [ "$a" = "--non-interactive" ] && found_ni=yes
    done
    if [ "$found_path" != "yes" ]; then
        echo "  the pasted line does not rebuild the path as ONE argument:"
        echo "    $line"
        return 1
    fi
    [ "$found_ni" = "yes" ] || { echo "  --non-interactive lost when re-split"; return 1; }
    if [ "$1" != "bash" ] || [ "$2" != "$SETUP_SCRIPT" ]; then
        echo "  the pasted line does not start with this checkout's setup.sh: $1 $2"
        return 1
    fi
    return 0
}

# The maintenance branch had the same relative-path defect, from the same cause.
test_tui_maintenance_preview_is_absolute() {
    local line
    line="$(KURAMA_TUI_MAINT=update.sh KURAMA_TUI_SCOPE=global unit_d_tui_preview)" \
        || { echo "  the preview probe failed: $line"; return 1; }
    case "$line" in
        *"./scripts/"*) echo "  the maintenance preview is still cwd-relative: $line"; return 1 ;;
    esac
    case "$line" in
        *"$SCRIPT_DIR/update.sh"*) ;;
        *) echo "  the maintenance preview does not name this checkout: $line"; return 1 ;;
    esac
    return 0
}

unit_d_normalize_profile() { # raw -> normalized on stdout, non-zero if refused
    KURAMA_TUI_PROBE=profile bash "$TUI_SCRIPT" "$1" 2>/dev/null
}

# A stray space or a capital used to be forwarded verbatim and kill the install
# in setup.sh's argument parser. Repairable input is repaired; the rest is
# refused here, where refusing costs one re-prompt instead of the whole run.
test_tui_profile_name_is_repaired_or_refused() {
    local got
    got="$(unit_d_normalize_profile 'Fast')" || { echo "  'Fast' was refused"; return 1; }
    assert_eq "fast" "$got" "a capital should be lowercased" || return 1

    got="$(unit_d_normalize_profile '  fast  ')" || { echo "  padded input was refused"; return 1; }
    assert_eq "fast" "$got" "surrounding whitespace should be stripped" || return 1

    got="$(unit_d_normalize_profile 'Fast:Anthropic/Claude-X')" \
        || { echo "  NAME:provider/model was refused"; return 1; }
    assert_eq "fast:Anthropic/Claude-X" "$got" "only NAME may be lowercased" || return 1

    got="$(unit_d_normalize_profile ':provider/model')" \
        || { echo "  an empty NAME was refused, but setup.sh defaults it"; return 1; }
    assert_eq "kurama:provider/model" "$got" "an empty NAME should default to kurama" || return 1

    if got="$(unit_d_normalize_profile 'bad_name')"; then
        echo "  'bad_name' was accepted as [$got] — setup.sh would exit 1 on it"
        return 1
    fi
    if got="$(unit_d_normalize_profile '-lead')"; then
        echo "  '-lead' was accepted as [$got] — setup.sh requires a leading alnum"
        return 1
    fi
    return 0
}

# The contract, end to end and without restating the regex: what the wizard
# forwards must survive setup.sh's own parser, and the raw form must not have.
test_tui_repaired_profile_name_is_one_setup_accepts() {
    local raw='My Profile' fixed status=0
    if bash "$SETUP_SCRIPT" --opencode-profile "$raw" --help > /dev/null 2>&1; then
        echo "  setup.sh accepted '$raw' — this case no longer proves anything"
        return 1
    fi
    fixed="$(unit_d_normalize_profile "$raw")" || { echo "  '$raw' was refused instead of repaired"; return 1; }
    bash "$SETUP_SCRIPT" --opencode-profile "$fixed" --help > /dev/null 2>&1 || status=$?
    if [ "$status" -ne 0 ]; then
        echo "  setup.sh rejected the repaired name '$fixed' (exit $status)"
        return 1
    fi
    return 0
}

echo -e "${BOLD}#36 — banner ladder, MCP count, TUI preview${NC}"
run_test "the render fits every terminal on the ladder" test_banner_never_overflows_the_terminal
run_test "a wide terminal gets fox + wordmark" test_banner_draws_the_full_art_when_it_fits
run_test "80x24 keeps the fox and still fits" test_banner_keeps_the_fox_on_an_80x24_terminal
run_test "narrower than the fox degrades to one line" test_banner_degrades_to_the_one_line_mark
run_test "too small to draw draws nothing, exit 0" test_banner_draws_nothing_when_even_the_mark_does_not_fit
run_test "the size probe honors explicit overrides" test_banner_size_probe_prefers_explicit_overrides
run_test "junk overrides fall through to the real probe" test_banner_size_probe_ignores_junk_overrides
run_test "the size probe asks the tty, not terminfo" test_banner_size_probe_reads_the_tty_not_terminfo
run_test "MCP servers are counted without jq" test_banner_counts_mcp_servers_without_jq
run_test "a legitimate 0 does not shadow the next config" test_banner_mcp_count_does_not_stop_at_a_legitimate_zero
run_test "an unreadable config reports n/a, never 0" test_banner_mcp_says_n_a_when_the_config_cannot_be_read
run_test "a nested project mcpServers does not shadow the top-level count" test_banner_counts_mcp_under_nested_project_shape
run_test "the opencode mcp key shape is counted without jq" test_banner_counts_opencode_mcp_key_shape
run_test "the TUI preview is the argv it runs" test_tui_preview_is_the_argv_it_runs
run_test "the preview re-splits, spaces and all" test_tui_preview_quotes_a_path_with_spaces
run_test "the maintenance preview is absolute too" test_tui_maintenance_preview_is_absolute
run_test "a profile name is repaired or refused" test_tui_profile_name_is_repaired_or_refused
run_test "the repaired name is one setup.sh accepts" test_tui_repaired_profile_name_is_one_setup_accepts

echo ""

# ===== UNIT-F (issue #37) =====
#
# The six byte-identical receipt-parser copies (and this suite's private seventh
# copy) are gone: scripts/lib/receipt.sh is the one implementation, sourced above.
# These tests exercise that single lib directly — the parser over the historical
# cases (the PR #13 single-line empty-array bug included), the new receiptSchema
# field, manifest_tools' legacy/modern gate, and skills_path — plus an integration
# check that every one of the six scripts actually sources the lib and fails loud
# without it. The old "kept in sync by convention" machinery is retired.

# --- (a) the single lib parser, parametrized over the historical cases --------

test_lib_manifest_json_array_reads_multi_element() {
    local m="$TEST_TMPDIR/r.json"
    printf '{\n  "files": [\n    "a/SKILL.md",\n    "b/SKILL.md"\n  ]\n}\n' > "$m"
    assert_eq "a/SKILL.md
b/SKILL.md" "$(manifest_json_array "$m" files)" "multi-element files[]" || return 1
    return 0
}

test_lib_manifest_json_array_single_line_empty_yields_nothing() {
    # The PR #13 defect, driven straight at the lib: a single-line "files": []
    # must yield NOTHING and must not leak the next key (settings[]) — the exact
    # read uninstall.sh drives rm from.
    local m="$TEST_TMPDIR/r.json"
    printf '{\n  "files": [],\n  "settings": [\n    ".claude/settings.json"\n  ]\n}\n' > "$m"
    assert_eq "" "$(manifest_json_array "$m" files)" "empty files[] must yield nothing" || return 1
    assert_eq ".claude/settings.json" "$(manifest_json_array "$m" settings)" \
        "settings[] must still read after an empty files[]" || return 1
    return 0
}

test_lib_manifest_json_array_single_line_populated() {
    local m="$TEST_TMPDIR/r.json"
    printf '{\n  "tools": ["claude-code", "opencode"]\n}\n' > "$m"
    assert_eq "claude-code
opencode" "$(manifest_json_array "$m" tools)" "single-line populated array" || return 1
    return 0
}

test_lib_manifest_json_array_absent_key_yields_nothing() {
    local m="$TEST_TMPDIR/r.json"
    printf '{\n  "files": [\n    "a"\n  ]\n}\n' > "$m"
    assert_eq "" "$(manifest_json_array "$m" nope)" "absent key must yield nothing" || return 1
    return 0
}

test_lib_manifest_field_reads_and_missing() {
    local m="$TEST_TMPDIR/r.json"
    printf '{\n  "version": "4.2.0",\n  "tool": "claude-code"\n}\n' > "$m"
    assert_eq "4.2.0" "$(manifest_field "$m" version)" "scalar field read" || return 1
    assert_eq "" "$(manifest_field "$m" nope)" "absent scalar field is empty" || return 1
    return 0
}

test_lib_receipt_schema_present_absent_and_nonnumeric() {
    local m="$TEST_TMPDIR/r.json"
    printf '{\n  "receiptSchema": 1,\n  "tool": "claude-code"\n}\n' > "$m"
    assert_eq "1" "$(receipt_schema "$m")" "integer receiptSchema is read" || return 1
    printf '{\n  "tool": "claude-code"\n}\n' > "$m"
    assert_eq "0" "$(receipt_schema "$m")" "a pre-#37 receipt reports schema 0" || return 1
    assert_eq "0" "$(receipt_schema "$TEST_TMPDIR/missing.json")" "a missing receipt reports 0" || return 1
    return 0
}

test_lib_manifest_tools_modern_and_legacy() {
    local m="$TEST_TMPDIR/r.json"
    # Modern (receiptSchema >= 1): tools[] is authoritative.
    printf '{\n  "receiptSchema": 1,\n  "tool": "claude-code",\n  "tools": [\n    "claude-code",\n    "opencode"\n  ]\n}\n' > "$m"
    assert_eq "claude-code
opencode" "$(manifest_tools "$m")" "modern receipt lists tools[]" || return 1
    # Legacy (no receiptSchema, no tools[]): frozen scalar-"tool" fallback.
    printf '{\n  "version": "3.0.0",\n  "tool": "Claude Code"\n}\n' > "$m"
    assert_eq "Claude Code" "$(manifest_tools "$m")" "legacy receipt falls back to scalar tool" || return 1
    return 0
}

test_lib_skills_path_global_project_and_omp() {
    unset PI_CODING_AGENT_DIR  # a preset relocation would change the omp default
    assert_eq "$HOME/.claude/skills" "$(skills_path claude-code global)" "claude-code global" || return 1
    assert_eq "$HOME/.config/opencode/skills" "$(skills_path opencode global)" "opencode global" || return 1
    assert_eq "$HOME/.codex/skills" "$(skills_path codex global)" "codex global" || return 1
    assert_eq "$HOME/.pi/agent/skills" "$(skills_path pi global)" "pi global" || return 1
    assert_eq "$HOME/.omp/agent/skills" "$(skills_path omp global)" "omp global default" || return 1
    assert_eq "" "$(skills_path bogus global)" "unknown harness is empty" || return 1
    assert_eq "/repo/.pi/skills" "$(skills_path pi project /repo)" "pi project scope" || return 1
    assert_eq "/repo/.claude/skills" "$(skills_path claude-code project /repo)" "claude-code project scope" || return 1
    local out
    out="$(PI_CODING_AGENT_DIR=/custom/omp skills_path omp global)"
    assert_eq "/custom/omp/skills" "$out" "omp honors PI_CODING_AGENT_DIR" || return 1
    return 0
}

# --- (b) integration: every script sources the one lib, and fails loud without it

# Every script must both SOURCE the lib and carry the missing-lib GUARD — grepping
# the source line alone would let someone delete the guard from one script (the
# deletion path is uninstall.sh) and stay green while a partial clone runs it with
# an undefined parser.
test_lib_all_six_scripts_source_it() {
    local s missing=""
    for s in setup.sh install.sh uninstall.sh update.sh doctor.sh setup-tui.sh; do
        # shellcheck disable=SC2016  # matching the literal source lines as written
        grep -qF 'KURAMA_LIB="$SCRIPT_DIR/lib/receipt.sh"' "$SCRIPT_DIR/$s" \
            && grep -qF '[ ! -f "$KURAMA_LIB" ]' "$SCRIPT_DIR/$s" \
            && grep -qF '. "$KURAMA_LIB"' "$SCRIPT_DIR/$s" \
            || missing="$missing $s"
    done
    [ -z "$missing" ] || { echo "scripts missing the source line or the guard:$missing"; return 1; }
    return 0
}

test_lib_missing_aborts_loud() {
    # A partial clone: EACH script without its lib sibling must abort non-zero and
    # name the lib, never run on with an undefined parser. The guard sits above arg
    # parsing, so --help trips it. Looped over all six — the deletion path
    # (uninstall.sh) is exactly the one a single-script test would miss.
    local nolib="$TEST_TMPDIR/nolib" s output status
    for s in setup.sh install.sh uninstall.sh update.sh doctor.sh setup-tui.sh; do
        rm -rf "$nolib"; mkdir -p "$nolib"
        cp "$SCRIPT_DIR/$s" "$nolib/$s"
        status=0
        output=$(bash "$nolib/$s" --help 2>&1) || status=$?
        [ "$status" -ne 0 ] || { echo "$s: a missing lib/receipt.sh must abort non-zero"; return 1; }
        printf '%s\n' "$output" | grep -qF 'lib/receipt.sh' || {
            echo "$s: the abort never names the missing lib:"; printf '%s\n' "$output" | tail -3; return 1; }
    done
    return 0
}

test_lib_truncated_lib_aborts_loud() {
    # A present-but-empty lib (truncated download / bad merge) leaves the parser
    # undefined. Each script must catch that too — via the command -v guard after
    # the source — instead of running on with a missing manifest_json_array.
    local dir="$TEST_TMPDIR/emptylib" s output status
    for s in setup.sh install.sh uninstall.sh update.sh doctor.sh setup-tui.sh; do
        rm -rf "$dir"; mkdir -p "$dir/lib"
        cp "$SCRIPT_DIR/$s" "$dir/$s"
        : > "$dir/lib/receipt.sh"
        status=0
        output=$(bash "$dir/$s" --help 2>&1) || status=$?
        [ "$status" -ne 0 ] || { echo "$s: an empty lib must abort non-zero"; return 1; }
        printf '%s\n' "$output" | grep -qF 'did not define the receipt parser' || {
            echo "$s: the abort never flags the undefined parser:"; printf '%s\n' "$output" | tail -3; return 1; }
    done
    return 0
}

echo -e "${BOLD}UNIT-F (issue #37) — shared receipt library${NC}"
run_test "lib parser reads a multi-element array" test_lib_manifest_json_array_reads_multi_element
run_test "lib parser: single-line empty array yields nothing, no leak" test_lib_manifest_json_array_single_line_empty_yields_nothing
run_test "lib parser reads a single-line populated array" test_lib_manifest_json_array_single_line_populated
run_test "lib parser: an absent key yields nothing" test_lib_manifest_json_array_absent_key_yields_nothing
run_test "lib reads a scalar field, empty when absent" test_lib_manifest_field_reads_and_missing
run_test "receipt_schema reads the int, 0 when absent/missing" test_lib_receipt_schema_present_absent_and_nonnumeric
run_test "manifest_tools: modern tools[] and legacy scalar fallback" test_lib_manifest_tools_modern_and_legacy
run_test "skills_path: global, project, and omp relocation" test_lib_skills_path_global_project_and_omp
run_test "all six scripts source + guard scripts/lib/receipt.sh" test_lib_all_six_scripts_source_it
run_test "all six abort loud when lib/receipt.sh is missing" test_lib_missing_aborts_loud
run_test "all six abort loud when lib/receipt.sh is empty/truncated" test_lib_truncated_lib_aborts_loud

echo ""

# ===== UNIT-G (issue #38) =====
#
# install.sh and setup.sh were collapsed into one install path. setup.sh gained the
# --with/--without skill-group selection install.sh used to own (so a full setup can
# drop the review group — skills AND review-layer agents), and install.sh became a
# thin wrapper that maps its historical flags onto setup.sh and writes NO receipt of
# its own: setup.sh (via scripts/lib/receipt.sh) is the sole receipt writer, closing
# the #24 receipt-conflict class for good. These tests pin the moved capability, the
# flag mapping (especially --all/all-global), and the single-writer invariant.

# --- (a) setup.sh honours --with/--without --------------------------------------

test_g_setup_without_review_is_a_full_review_free_setup() {
    # The headline of #38: a FULL setup WITHOUT the review group — no review skills
    # AND no review-layer native agents — with the rest of the install (hooks, the
    # other groups, the orchestrator merge) intact.
    bash "$SETUP_SCRIPT" --agent claude-code --without review --non-interactive > /dev/null 2>&1
    local base="$HOME/.claude/skills" agents="$HOME/.claude/agents"
    local lens
    for lens in review-risk review-readability review-reliability review-resilience review-refuter; do
        [ -d "$base/$lens" ] && { echo "review skill $lens should be excluded"; return 1; }
        [ -e "$agents/$lens.md" ] && { echo "review-layer agent $lens.md should be excluded"; return 1; }
    done
    assert_dir_exists "$base/sdd-apply" || return 1       # sdd-core still on
    assert_dir_exists "$base/judgment-day" || return 1    # quality still on
    local count
    count=$(find "$base" -name SKILL.md | wc -l | tr -d ' ')
    assert_eq "23" "$count" "full setup --without review lands 23 skills" || return 1
    # A genuinely full setup: Claude Code hooks were still installed.
    assert_file_exists "$HOME/.claude/settings.json" || return 1
    return 0
}

test_g_setup_without_rejects_required_group() {
    if bash "$SETUP_SCRIPT" --agent claude-code --without sdd-core --non-interactive > /dev/null 2>&1; then
        echo "setup.sh --without sdd-core must exit non-zero (sdd-core is required)"; return 1
    fi
    return 0
}

test_g_setup_with_lang_adds_language_skills() {
    bash "$SETUP_SCRIPT" --agent claude-code --with lang --non-interactive > /dev/null 2>&1
    assert_dir_exists "$HOME/.claude/skills/go-testing" || return 1
    local count
    count=$(find "$HOME/.claude/skills" -name SKILL.md | wc -l | tr -d ' ')
    assert_eq "29" "$count" "setup.sh --with lang lands 29 skills" || return 1
    return 0
}

test_g_setup_reinstall_without_review_prunes() {
    # A default install then a --without review re-install converges to the same state
    # as a fresh one: the review skill is removed from disk AND from the receipt (not
    # merely dropped from the active set and left loading — the #24-adjacent bug).
    bash "$SETUP_SCRIPT" --agent claude-code --non-interactive > /dev/null 2>&1
    assert_dir_exists "$HOME/.claude/skills/review-risk" || return 1
    bash "$SETUP_SCRIPT" --agent claude-code --without review --non-interactive > /dev/null 2>&1
    [ -e "$HOME/.claude/skills/review-risk/SKILL.md" ] && { echo "stale review skill left on disk after prune"; return 1; }
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    grep -q 'review-risk' "$manifest" && { echo "receipt still references review-risk after prune"; return 1; }
    # The rest of the install is intact — this pruned, it did not wipe.
    assert_dir_exists "$HOME/.claude/skills/sdd-apply" || return 1
    return 0
}

# --- (b) install.sh wrapper maps each documented flag onto setup.sh --------------

test_g_wrapper_agent_maps_to_full_setup() {
    # install.sh --agent NAME runs the SAME full setup.sh install (28 skills) and
    # writes setup.sh's slug-tool receipt with the setup-only keys — proof the full
    # installer ran through the delegate, not install.sh's old skills-only path.
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    assert_all_skills_installed "$HOME/.claude/skills" || return 1
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    grep -q '"tool"[[:space:]]*:[[:space:]]*"claude-code"' "$manifest" || {
        echo "wrapper receipt tool is not the setup.sh slug 'claude-code'"; return 1; }
    grep -q '"settings"' "$manifest" || { echo "wrapper did not run the full setup (no settings[] in receipt)"; return 1; }
    return 0
}

test_g_wrapper_all_global_installs_five_unconditionally() {
    # all-global maps to an EXPLICIT enumeration of the five harnesses — not
    # setup.sh --all's PATH detection, which would install nothing in this agent-less
    # test environment. All five skills dirs must be populated regardless of PATH.
    bash "$INSTALL_SCRIPT" --agent all-global > /dev/null 2>&1
    local d
    for d in "$HOME/.claude/skills" "$HOME/.config/opencode/skills" "$HOME/.codex/skills" \
             "$HOME/.pi/agent/skills" "$HOME/.omp/agent/skills"; do
        local c; c=$(find "$d" -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')
        assert_eq "28" "$c" "all-global must install 28 skills into $d" || return 1
    done
    return 0
}

test_g_wrapper_forwards_group_flags() {
    # A group flag rides through the wrapper into setup.sh unchanged.
    bash "$INSTALL_SCRIPT" --agent claude-code --without review > /dev/null 2>&1
    [ -d "$HOME/.claude/skills/review-risk" ] && { echo "--without review not forwarded through the wrapper"; return 1; }
    local count
    count=$(find "$HOME/.claude/skills" -name SKILL.md | wc -l | tr -d ' ')
    assert_eq "23" "$count" "wrapper --without review lands 23 skills" || return 1
    return 0
}

test_g_wrapper_version_and_help_answered_locally() {
    # --version and --help are answered by the wrapper itself (setup.sh has no
    # --version), and --help still documents the historical agents.
    local vout; vout=$(bash "$INSTALL_SCRIPT" --version 2>&1)
    printf '%s' "$vout" | grep -qE '^kurama [0-9]' || { echo "--version did not print 'kurama <version>'"; return 1; }
    local hout; hout=$(bash "$INSTALL_SCRIPT" --help 2>&1)
    printf '%s' "$hout" | grep -q 'all-global' || { echo "--help lost the all-global agent"; return 1; }
    printf '%s' "$hout" | grep -q 'setup.sh' || { echo "--help does not mention the setup.sh delegate"; return 1; }
    return 0
}

test_g_wrapper_prints_deprecation_notice() {
    # A one-line deprecation notice is emitted (to stderr) when the wrapper delegates.
    local errout; errout=$(bash "$INSTALL_SCRIPT" --agent claude-code 2>&1 >/dev/null)
    printf '%s' "$errout" | grep -qi 'deprecat' || { echo "no deprecation notice on stderr"; return 1; }
    return 0
}

# --- (c) install.sh writes no receipt of its own — setup.sh is the sole writer ---

test_g_wrapper_does_not_truncate_setup_receipt() {
    # #24 closed for good: run setup.sh, then install.sh, over the same claude-code
    # target. The wrapper must NOT truncate the richer receipt — the setup-only keys
    # survive because the SAME setup.sh writer produced both.
    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive > /dev/null 2>&1
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    grep -q '"settings"' "$manifest" || { echo "premise: setup.sh receipt lacks settings[]"; return 1; }
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    grep -q '"settings"' "$manifest" || { echo "install.sh truncated the receipt (settings[] gone) — #24 regressed"; return 1; }
    grep -q '"tools"' "$manifest" || { echo "install.sh truncated tools[] — #24 regressed"; return 1; }
    grep -q 'hooks/kurama/archive-gate.sh' "$manifest" || { echo "hook file entries lost after the install.sh run"; return 1; }
    return 0
}

test_g_wrapper_writes_no_display_name_tool() {
    # The old install.sh stored the DISPLAY name ("Claude Code"); the wrapper delegates
    # to setup.sh, which records the slug — no install.sh-only receipt shape remains.
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    if grep -q '"tool"[[:space:]]*:[[:space:]]*"Claude Code"' "$manifest"; then
        echo "wrapper still wrote install.sh's display-name tool 'Claude Code'"; return 1
    fi
    return 0
}

# --- (d) setup.sh fails loud on an incomplete source tree (I3, ported from install.sh)

test_g_setup_missing_examples_fails_loud_before_write() {
    # I3 (#38): the examples/ completeness check that used to live in install.sh's
    # validate_source moved into setup.sh when the two installers collapsed. examples/
    # is not optional — the OpenCode target installs its /sdd-* commands from it and
    # every orchestrator merge reads a prompt file under it — so a clone with skills/
    # but no examples/ must FAIL LOUD (exit 1, naming the missing path) BEFORE any
    # write, honouring the #41 fail-loud invariant. The pre-collapse hazard: warn
    # per-source, skip the commands, still print "Done!" and write a receipt for a
    # PARTIAL install — exit 0 where it must be exit 1.
    local clone="$TEST_TMPDIR/staged-clone-no-examples"
    stage_kurama_clone "$clone" || { echo "could not stage the throwaway clone"; return 1; }
    rm -rf "$clone/examples" || { echo "could not remove examples/ from the staged clone"; return 1; }

    local output status=0
    output=$(bash "$clone/scripts/setup.sh" --agent claude-code --without-engram --non-interactive 2>&1) || status=$?

    if [ "$status" -eq 0 ]; then
        echo "setup.sh installed from a clone missing examples/ instead of aborting"
        printf '%s\n' "$output" | tail -5
        return 1
    fi
    printf '%s\n' "$output" | grep -qF 'Missing: examples/' || {
        echo "the abort never names the missing examples/ path:"
        printf '%s\n' "$output" | tail -5
        return 1
    }
    local receipt="$HOME/.claude/skills/.kurama-install-manifest.json"
    if [ -e "$receipt" ]; then
        echo "setup.sh wrote a receipt for a partial install: $receipt"
        return 1
    fi
    return 0
}

echo -e "${BOLD}UNIT-G (issue #38) — collapse install.sh into setup.sh${NC}"
run_test "setup.sh --without review is a full review-free setup" test_g_setup_without_review_is_a_full_review_free_setup
run_test "setup.sh --without sdd-core is rejected" test_g_setup_without_rejects_required_group
run_test "setup.sh --with lang adds language skills (29)" test_g_setup_with_lang_adds_language_skills
run_test "setup.sh --without review re-install prunes stale review" test_g_setup_reinstall_without_review_prunes
run_test "wrapper --agent maps to the full setup.sh install" test_g_wrapper_agent_maps_to_full_setup
run_test "wrapper all-global installs all five (no detection)" test_g_wrapper_all_global_installs_five_unconditionally
run_test "wrapper forwards --with/--without to setup.sh" test_g_wrapper_forwards_group_flags
run_test "wrapper answers --version/--help locally" test_g_wrapper_version_and_help_answered_locally
run_test "wrapper prints a deprecation notice" test_g_wrapper_prints_deprecation_notice
run_test "wrapper never truncates the setup.sh receipt (#24)" test_g_wrapper_does_not_truncate_setup_receipt
run_test "wrapper writes no display-name receipt of its own" test_g_wrapper_writes_no_display_name_tool
run_test "setup.sh fails loud on a clone missing examples/ (no partial receipt)" test_g_setup_missing_examples_fails_loud_before_write

echo ""

# ============================================================================
# ===== UNIT-H (issue #40) =====
# Simplification decisions: one interactive front-end (the TUI), an honest
# jq-less logo de-registration path, and a doctor check for a dangling logo.
# ============================================================================

# ---- R2: setup.sh interactive front-end delegates to the TUI ----

# A bare, interactive `./setup.sh` with gum available must hand off to
# setup-tui.sh (the one interactive experience) rather than run its own menu.
# KURAMA_TUI_PROBE makes the delegated TUI print its probe line and exit 0 before
# the wizard — an observable proof of the hand-off that the removed text menu
# could never produce.
test_h_setup_interactive_with_gum_delegates_to_tui() {
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    local shim="$TEST_TMPDIR/npmshim"
    make_npm_shim "$shim"
    # An OpenCode project install gives the TUI probe a receipt to report.
    PATH="$shim:$PATH" bash "$SETUP_SCRIPT" --agent opencode --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "opencode project setup exited non-zero"; return 1; }
    # A fake gum on PATH makes setup.sh's interactive branch take the delegation.
    local bindir="$TEST_TMPDIR/gumbin"
    mkdir -p "$bindir"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bindir/gum"
    chmod +x "$bindir/gum"
    local out status=0
    out="$(cd "$repo" && PATH="$bindir:$PATH" KURAMA_NO_BANNER=1 KURAMA_TUI_PROBE=1 \
        bash "$SETUP_SCRIPT" 2>/dev/null)" || status=$?
    assert_eq "0" "$status" "interactive + gum must delegate and exit 0 via the TUI probe" || return 1
    printf '%s\n' "$out" | grep -q 'project' \
        || { echo "no TUI probe output — delegation did not happen (got: $out)"; return 1; }
    printf '%s\n' "$out" | grep -q 'opencode' \
        || { echo "probe missing opencode — not the TUI's output (got: $out)"; return 1; }
    return 0
}

# Without gum, setup.sh cannot conjure a TUI and installs nothing interactively:
# it must print the non-interactive flag guide and exit 2 — never half-install a
# guessed default.
test_h_setup_interactive_without_gum_prints_guide_exits_2() {
    # Restricted PATH (symlink farm) that deliberately omits gum, so its absence
    # is deterministic on any host — same trick as the TUI-probe test.
    local bindir="$TEST_TMPDIR/nogum-bin"
    mkdir -p "$bindir"
    local tool p
    for tool in bash sh env uname grep egrep dirname basename mkdir cp mv cat date \
                chmod rm ls awk sed tr wc find mktemp sort head tail printf test git; do
        p="$(command -v "$tool" 2>/dev/null)" || continue
        ln -sf "$p" "$bindir/$tool"
    done
    if [ -e "$bindir/gum" ]; then
        echo "gum is reachable on the restricted PATH — the test proves nothing"
        return 1
    fi
    local out status=0
    out="$(PATH="$bindir" KURAMA_NO_BANNER=1 bash "$SETUP_SCRIPT" 2>&1)" || status=$?
    assert_eq "2" "$status" "interactive without gum must exit 2, never half-install" || return 1
    printf '%s\n' "$out" | grep -q -- '--non-interactive' \
        || { echo "flag guide does not mention --non-interactive (got: $out)"; return 1; }
    printf '%s\n' "$out" | grep -qi 'gum' \
        || { echo "guide does not explain gum drives the interactive TUI (got: $out)"; return 1; }
    # Never half-install: no skills written under the fresh HOME.
    if [ -d "$HOME/.claude/skills" ]; then
        echo "half-install: ~/.claude/skills was created on a refused interactive run"
        return 1
    fi
    return 0
}

# The TUI hand-off takes NO arguments, so an underspecified run (no --agent/--all)
# carrying a run-shaping flag would have that flag SILENTLY DROPPED. `--without
# review` is the sharp case: the review group would install ANYWAY, contradicting
# the explicit flag. setup.sh must REFUSE (non-zero, naming the flag) and install
# nothing — never silently honor nothing (review fix I1).
test_h_setup_interactive_refuses_unforwardable_flags() {
    local out status=0
    out="$(KURAMA_NO_BANNER=1 bash "$SETUP_SCRIPT" --without review 2>&1)" || status=$?
    [ "$status" -ne 0 ] \
        || { echo "'--without review' with no target exited 0 (silently honored nothing)"; return 1; }
    printf '%s\n' "$out" | grep -q -- '--without' \
        || { echo "refusal did not name the offending flag (got: $out)"; return 1; }
    # It installed nothing — least of all the review group it was told to skip.
    if [ -d "$HOME/.claude/skills" ]; then
        echo "half-install: ~/.claude/skills created on a refused underspecified run"
        return 1
    fi
    return 0
}

# ---- R3: jq-less logo de-registration is honest; doctor flags a dangling logo ----

# Installing --with-logo (jq present) registers the plugin in tui.json AND records
# the .tsx in files[]. Uninstalling WITHOUT jq cannot strip the registration, so it
# must refuse rather than delete the .tsx and leave tui.json pointing at a ghost:
# tui.json untouched, the .tsx kept, a non-zero exit, and the exact manual snippet.
test_h_uninstall_jqless_logo_path_is_honest() {
    run_setup_opencode --with-logo || { echo "opencode --with-logo install failed"; return 1; }
    local tui="$HOME/.config/opencode/tui.json"
    local tsx="$HOME/.config/opencode/tui-plugins/kurama-logo.tsx"
    assert_file_exists "$tui" || return 1
    grep -q 'kurama-logo.tsx' "$tui" \
        || { echo "logo was not registered in tui.json (jq missing at install?)"; return 1; }
    assert_file_exists "$tsx" || return 1
    local before; before="$(cat "$tui")"
    # Restricted PATH without jq (symlink farm), so jq's absence is deterministic.
    local bindir="$TEST_TMPDIR/nojq-bin"
    mkdir -p "$bindir"
    local tool p
    for tool in bash sh env uname grep egrep dirname basename mkdir cp mv cat date \
                chmod rm ls awk sed tr wc find mktemp sort head tail printf test git; do
        p="$(command -v "$tool" 2>/dev/null)" || continue
        ln -sf "$p" "$bindir/$tool"
    done
    if [ -e "$bindir/jq" ]; then
        echo "jq is reachable on the restricted PATH — the test proves nothing"
        return 1
    fi
    local out status=0
    out="$(PATH="$bindir" bash "$UNINSTALL_SCRIPT" --agent opencode 2>&1)" || status=$?
    [ "$status" -ne 0 ] \
        || { echo "uninstall exited 0 while unable to de-register the logo (broken state)"; return 1; }
    local after; after="$(cat "$tui" 2>/dev/null)"
    assert_eq "$before" "$after" "tui.json must be left untouched without jq" || return 1
    # Refused before the file sweep, so the plugin .tsx survives too — no dangling ref.
    assert_file_exists "$tsx" || return 1
    printf '%s\n' "$out" | grep -q 'tui-plugins/kurama-logo.tsx' \
        || { echo "no exact manual de-registration snippet printed (got: $out)"; return 1; }
    return 0
}

# A logo still registered in tui.json whose .tsx is gone is a dangling TUI plugin.
# doctor must flag it (hard fail), not report the install healthy.
test_h_doctor_flags_registered_but_missing_logo() {
    run_setup_opencode --with-logo || { echo "opencode --with-logo install failed"; return 1; }
    local tsx="$HOME/.config/opencode/tui-plugins/kurama-logo.tsx"
    assert_file_exists "$tsx" || return 1
    # Broken state: delete the plugin file, leave tui.json referencing it.
    rm -f "$tsx"
    local shim="$TEST_TMPDIR/docshims"
    make_doctor_shims "$shim"
    local out status=0
    out="$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" --agent opencode 2>&1)" || status=$?
    [ "$status" -ne 0 ] \
        || { echo "doctor exited 0 over a dangling logo registration"; return 1; }
    printf '%s\n' "$out" | grep -qi 'registered in .* but its plugin file is gone' \
        || { echo "doctor did not flag the dangling logo (got: $out)"; return 1; }
    return 0
}

echo -e "${BOLD}UNIT-H (issue #40): simplification decisions${NC}"
run_test "setup.sh interactive + gum hands off to the TUI" test_h_setup_interactive_with_gum_delegates_to_tui
run_test "setup.sh interactive - gum prints the flag guide and exits 2" test_h_setup_interactive_without_gum_prints_guide_exits_2
run_test "setup.sh refuses unforwardable flags (--without review) instead of honoring nothing" test_h_setup_interactive_refuses_unforwardable_flags
run_test "uninstall.sh jq-less logo path leaves tui.json untouched" test_h_uninstall_jqless_logo_path_is_honest
run_test "doctor.sh flags a registered-but-missing logo plugin" test_h_doctor_flags_registered_but_missing_logo

echo ""

# ============================================================================
# ===== UNIT-I (issue #63) =====
# Batch integration follow-ups: two #41-class fail-loud gaps the collapse/jq work
# left behind, plus two regression pins the per-task reviewers punted to the final
# review. Two are code fixes (setup.sh _shared guard, uninstall.sh jq-present
# unparseable-config refusal); two pin behaviour that is already correct so a
# revert cannot slip back in green.
# ============================================================================

test_i_setup_missing_shared_fails_loud_before_write() {
    # #63: install.sh's pre-#38 validate_source checked `[ ! -d "$SKILLS_SRC/_shared" ]`;
    # the #38 collapse ported the examples/ and manifest checks into setup.sh but dropped
    # _shared. skills/_shared is load-bearing — every target installs it and all 20 default
    # SKILL.md files reference _shared/* — yet install_skills copies it only behind
    # `if [ -d "$shared_src" ]`, so a clone with skills/ but no _shared/ silently skipped it,
    # still printed "Done!" and wrote a receipt for a PARTIAL install: exit 0 where it must
    # be exit 1. Same #41 fail-loud class as the examples/ gap pinned in UNIT-G, and _shared
    # is more load-bearing (all targets, not just OpenCode).
    local clone="$TEST_TMPDIR/staged-clone-no-shared"
    stage_kurama_clone "$clone" || { echo "could not stage the throwaway clone"; return 1; }
    rm -rf "$clone/skills/_shared" || { echo "could not remove skills/_shared from the staged clone"; return 1; }

    local output status=0
    output=$(bash "$clone/scripts/setup.sh" --agent claude-code --without-engram --non-interactive 2>&1) || status=$?

    if [ "$status" -eq 0 ]; then
        echo "setup.sh installed from a clone missing skills/_shared instead of aborting"
        printf '%s\n' "$output" | tail -5
        return 1
    fi
    printf '%s\n' "$output" | grep -qF 'Missing: skills/_shared' || {
        echo "the abort never names the missing skills/_shared path:"
        printf '%s\n' "$output" | tail -5
        return 1
    }
    local receipt="$HOME/.claude/skills/.kurama-install-manifest.json"
    if [ -e "$receipt" ]; then
        echo "setup.sh wrote a receipt for a partial install: $receipt"
        return 1
    fi
    return 0
}

test_i_uninstall_refuses_corrupt_settings_with_jq_present() {
    # #63: both jq-less pre-flight honesty guards were gated on `! command -v jq` only, so
    # with jq PRESENT and an unparseable settings.json the rm loop deleted the hook scripts,
    # remove_hooks_from_settings then hit its warn-and-return, and the run exited 0 "Done."
    # leaving settings.json invoking deleted executables — a broken PreToolUse hook on every
    # Edit/Write. The fix adds a `jq -e .` validity probe inside the pre-flight guard: an
    # unparseable config is refused BEFORE any file is removed, exactly as the jq-absent path
    # does. This test runs with jq present (the default PATH).
    command -v jq >/dev/null 2>&1 || { echo "jq is required for this test"; return 1; }

    bash "$SETUP_SCRIPT" --agent claude-code --without-engram --non-interactive \
        > /dev/null 2>&1 || { echo "setup exited non-zero"; return 1; }
    local settings="$HOME/.claude/settings.json"
    local guard="$HOME/.claude/hooks/kurama/orchestrator-write-guard.sh"
    local gate="$HOME/.claude/hooks/kurama/archive-gate.sh"
    local manifest="$HOME/.claude/skills/.kurama-install-manifest.json"
    assert_file_exists "$settings" || return 1
    assert_file_exists "$guard" || return 1
    assert_file_exists "$gate" || return 1
    grep -q 'hooks/kurama/' "$settings" || { echo "setup wrote no hooks block"; return 1; }

    # Corrupt settings.json into invalid JSON while KEEPING the hooks/kurama/ text, so the
    # pre-flight textual probe still recognises it as ours to strip AND jq can no longer
    # parse it. Trailing garbage after a valid object is a jq parse error (exit non-zero).
    printf '\n]]]NOT JSON\n' >> "$settings"
    if jq -e . "$settings" >/dev/null 2>&1; then
        echo "settings.json is still valid JSON — the corruption did not take"; return 1
    fi
    grep -q 'hooks/kurama/' "$settings" || { echo "corruption dropped the hooks block text"; return 1; }

    local output status=0
    output=$(bash "$UNINSTALL_SCRIPT" --agent claude-code --without-pi-packages 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        echo "uninstall exited 0 over an unparseable settings.json (jq present); it said:"
        printf '%s\n' "$output" | tail -8
        return 1
    fi
    # The preferred fix refuses BEFORE the rm loop, so the hook scripts survive and
    # settings.json is never left pointing at deleted executables.
    assert_file_exists "$guard" || {
        echo "the write-guard hook was deleted while settings.json still invokes it"; return 1; }
    assert_file_exists "$gate" || {
        echo "the archive-gate hook was deleted while settings.json still invokes it"; return 1; }
    assert_file_exists "$manifest" || { echo "the refused run deleted the receipt"; return 1; }
    return 0
}

test_i_install_custom_without_path_refuses() {
    # #63 pins #38's C1: `install.sh --agent custom` with NO --path and stdin not a
    # TTY must REFUSE — exit non-zero, install NOTHING — never silently full-install
    # into $PWD. The pre-#38 code was `target="${CUSTOM_PATH:-$PWD}"`, so a revert of
    # the require-`--path` guard (install.sh:150-159) would run a whole project
    # install (CLAUDE.md orchestrator merge, .claude/settings.json hooks, native
    # agents) into whatever repo the user happens to be sitting in. Only positive
    # `--agent custom --path DIR` cases exist, so that revert stays green without this.
    # The cwd is a real git repo on purpose: a reintroduced $PWD fallback WOULD pass
    # setup.sh's project preconditions and install here, so the refusal is the only
    # thing keeping the tree clean. stdin is /dev/null so the interactive prompt path
    # (`[ -t 0 ]`) is not taken and the non-interactive refusal is what we exercise.
    local sandbox="$TEST_TMPDIR/custom-no-path-cwd"
    make_git_repo "$sandbox"

    local output status=0
    output=$(cd "$sandbox" && bash "$INSTALL_SCRIPT" --agent custom </dev/null 2>&1) || status=$?

    if [ "$status" -eq 0 ]; then
        echo "install.sh --agent custom with no --path (non-TTY) exited 0 instead of refusing"
        printf '%s\n' "$output" | tail -5
        return 1
    fi
    # Nothing may have landed in the cwd: no hooks receipt, no orchestrator merge, no tree.
    if [ -e "$sandbox/.claude/settings.json" ]; then
        echo "the refused run still wrote .claude/settings.json into the cwd"
        return 1
    fi
    if [ -e "$sandbox/CLAUDE.md" ]; then
        echo "the refused run still merged a CLAUDE.md orchestrator block into the cwd"
        return 1
    fi
    if [ -e "$sandbox/.claude" ]; then
        echo "the refused run still created a .claude/ tree in the cwd"
        return 1
    fi
    if [ -e "$sandbox/.kurama-install-manifest.json" ]; then
        echo "the refused run still wrote an install receipt into the cwd"
        return 1
    fi
    printf '%s\n' "$output" | grep -qF 'requires --path' || {
        echo "the refusal never tells the user --path is required:"
        printf '%s\n' "$output" | tail -5
        return 1
    }
    return 0
}

test_i_uninstall_directory_entry_aborts_loud() {
    # #63 pins #33's I1: remove_target drives `rm -f` straight from the receipt's
    # files[] with errexit armed, and the four call sites are BARE on purpose so a
    # failed rm aborts the run instead of being swallowed. A files[] entry that names
    # a DIRECTORY makes `rm -f` fail with EISDIR (rm refuses a directory without -r);
    # the fixed code lets that abort loudly — no false "removed:" line for the entry,
    # never reaching "Done." Reintroducing `|| UNINSTALL_FAILED=1` (or `|| true`) at
    # the rm would swallow the EISDIR, print a false "removed:", and still report
    # success — and the suite would stay green because no other test drives a
    # directory entry through the rm loop. uninstall.sh runs here as a SUBPROCESS, so
    # its errexit abort cannot abort this suite.
    command -v jq >/dev/null 2>&1 || { echo "jq is required to inject the receipt entry"; return 1; }
    local repo="$TEST_TMPDIR/proj-dir-entry"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "the project install setup exited non-zero"; return 1; }

    local receipt="$repo/.kurama-install-manifest.json"
    assert_file_exists "$receipt" || return 1

    # A real, existing DIRECTORY inside the containment root (the repo). rm -f refuses
    # it (EISDIR); a plain file entry here would delete cleanly and prove nothing.
    mkdir -p "$repo/kurama-dir-entry" || { echo "could not stage the directory entry"; return 1; }
    local tmp="$receipt.tmp"
    if ! jq '.files += ["kurama-dir-entry"]' "$receipt" > "$tmp"; then
        echo "could not inject the directory entry into files[]"; return 1
    fi
    mv "$tmp" "$receipt"
    if ! jq -e '.files | index("kurama-dir-entry")' "$receipt" >/dev/null; then
        echo "the directory entry did not land in files[]"; return 1
    fi

    local output status=0
    output=$(bash "$UNINSTALL_SCRIPT" --scope project --path "$repo" --without-pi-packages 2>&1) || status=$?

    if [ "$status" -eq 0 ]; then
        echo "uninstall exited 0 over a files[] entry that is a directory (EISDIR swallowed):"
        printf '%s\n' "$output" | tail -8
        return 1
    fi
    if printf '%s\n' "$output" | grep -qF 'removed: kurama-dir-entry'; then
        echo "uninstall printed a false 'removed:' line for the directory it could not rm"
        return 1
    fi
    if printf '%s\n' "$output" | grep -qF 'Done.'; then
        echo "uninstall reached 'Done.' after failing to remove a directory entry"
        return 1
    fi
    # rm -f left the directory in place — the run really did fail to remove it.
    assert_dir_exists "$repo/kurama-dir-entry" || return 1
    return 0
}

echo -e "${BOLD}UNIT-I (issue #63): batch integration follow-ups${NC}"
run_test "setup.sh fails loud on a clone missing skills/_shared (no partial receipt)" test_i_setup_missing_shared_fails_loud_before_write
run_test "uninstall refuses a corrupt settings.json with jq present (hooks survive)" test_i_uninstall_refuses_corrupt_settings_with_jq_present
run_test "install.sh --agent custom with no --path (non-TTY) refuses, installs nothing" test_i_install_custom_without_path_refuses
run_test "uninstall aborts loud on a receipt files[] entry that is a directory (EISDIR)" test_i_uninstall_directory_entry_aborts_loud

echo ""

# ============================================================================
# ===== UNIT-J (issue #70) =====
# The three jq asterisks the audit left standing. Two are the write guard's
# agent_id extraction — the no-jq path root-anchored itself by assuming a key
# ORDER that JSON does not guarantee, and the rewrite that drops that assumption
# must not trade away the anti-spoofing property it was there for. The third is
# setup.sh's closing summary claiming an Engram MCP registration that a jq-less
# run never made.
# ============================================================================

# An Edit payload for file $2 in project $1, with the ROOT-level agent_id $3
# serialized AFTER tool_input. Same object as edit_payload's three-argument form
# — JSON object keys are unordered, so both spellings are the same payload and
# the guard has to decide the same way about them (#70).
edit_payload_agent_last() {
    local root="$1" file="$2" agent="$3"
    printf '{"session_id":"s1","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"a","new_string":"b"},"agent_id":"%s"}' \
        "$root" "$file" "$agent"
}

# Echo the write guard's exit status over payload $2. With $1 empty the ambient
# PATH is used (jq present); with $1 naming a jq-less farm, PATH is REPLACED by
# it so the hook takes its awk/grep fallback. Echoes rather than returns because
# a blocking hook exits 2, which a bare call would turn into an aborted body now
# that errexit really reaches it.
write_guard_status() {
    local bindir="$1" payload="$2" status=0
    if [ -n "$bindir" ]; then
        printf '%s' "$payload" | PATH="$bindir" bash "$WRITE_GUARD_HOOK" > /dev/null 2>&1 || status=$?
    else
        printf '%s' "$payload" | bash "$WRITE_GUARD_HOOK" > /dev/null 2>&1 || status=$?
    fi
    printf '%s' "$status"
}

# Fail unless the write guard BLOCKS payload $2 under BOTH parsers — ambient jq
# and the jq-less farm at $1. $3 labels the payload shape in the message. The
# payload is validated as JSON first: an unparseable one makes jq's extractor
# return empty, which blocks for the wrong reason and would pass vacuously.
assert_write_guard_blocks_both_parsers() {
    local bindir="$1" payload="$2" label="$3"
    if ! printf '%s' "$payload" | jq -e . > /dev/null 2>&1; then
        echo "the $label spoof payload is not valid JSON — it would block for the wrong reason"
        return 1
    fi
    assert_eq "2" "$(write_guard_status "" "$payload")" \
        "with jq the $label agent_id spoof must not bypass the guard" || return 1
    assert_eq "2" "$(write_guard_status "$bindir" "$payload")" \
        "without jq the $label agent_id spoof must not bypass the guard" || return 1
    return 0
}

test_j_write_guard_decides_the_same_way_whatever_the_key_order() {
    # #70.1: the no-jq extraction root-anchored agent_id with
    # `sed 's/"tool_input".*//'` and a grep over what was left — which is only the
    # root when agent_id happens to be serialized BEFORE tool_input. JSON object key
    # order is not guaranteed, so the same subagent payload with the keys the other
    # way round yielded an EMPTY agent_id: the guard read a delegated writer as the
    # main thread and blocked it. It fails closed, so it is not a hole — but on a
    # jq-less box it deadlocks every delegated writer, sdd-apply included, and the
    # deadlock is invisible to a suite that only ever sends one key order.
    #
    # The decision must come from the payload's CONTENT under either parser, so all
    # four combinations of {key order} x {jq, no jq} are exercised and all four must
    # ALLOW the subagent write.
    command -v jq >/dev/null 2>&1 || { echo "jq is required for the jq half of this case"; return 1; }
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/keyorder"
    make_active_cycle_repo "$repo"

    # Precondition, so "allowed in all four" cannot pass on a guard that allows
    # everything: the SAME write with no agent_id at all must be blocked by both
    # parsers. Without this, deleting the subagent check entirely stays green.
    local main_payload
    main_payload="$(edit_payload "$repo" "src/widget.ts")"
    assert_eq "2" "$(write_guard_status "" "$main_payload")" \
        "precondition: with jq a main-thread write must still be blocked" || return 1
    assert_eq "2" "$(write_guard_status "$bindir" "$main_payload")" \
        "precondition: without jq a main-thread write must still be blocked" || return 1

    local agent_first agent_last
    agent_first="$(edit_payload "$repo" "src/widget.ts" "agent_7")"
    agent_last="$(edit_payload_agent_last "$repo" "src/widget.ts" "agent_7")"

    assert_eq "0" "$(write_guard_status "" "$agent_first")" \
        "jq, agent_id BEFORE tool_input: a subagent write must be allowed" || return 1
    assert_eq "0" "$(write_guard_status "" "$agent_last")" \
        "jq, agent_id AFTER tool_input: a subagent write must be allowed" || return 1
    assert_eq "0" "$(write_guard_status "$bindir" "$agent_first")" \
        "no jq, agent_id BEFORE tool_input: a subagent write must be allowed" || return 1
    assert_eq "0" "$(write_guard_status "$bindir" "$agent_last")" \
        "no jq, agent_id AFTER tool_input: a subagent write must be allowed" || return 1
    return 0
}

test_j_write_guard_still_refuses_a_spoofed_agent_id_inside_tool_input() {
    # #70.1's other half: the property the key-order fix must NOT trade away.
    # agent_id is read at the JSON ROOT only, because everything under tool_input is
    # the model's own content — a Write whose text happens to contain "agent_id"
    # (this very hook, a fixture, a doc) must never read as subagent context and
    # unlock the guard. The old prefix scan got that right by accident of cutting at
    # "tool_input"; a rewrite that walks the payload has to get it right on purpose.
    #
    # The three shapes below are the ones a brace-depth walk gets wrong when it
    # ignores STRING context: a plainly nested object, an agent_id inside a quoted
    # string value, and a string carrying unbalanced closing braces that fake an
    # early return to depth 1. All three must BLOCK, under jq and under the fallback.
    command -v jq >/dev/null 2>&1 || { echo "jq is required for the jq half of this case"; return 1; }
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/spoof"
    make_active_cycle_repo "$repo"

    # Precondition: an honest ROOT agent_id in the same repo IS allowed, so these
    # three blocks are the guard rejecting the spoof and not the guard being deaf.
    assert_eq "0" "$(write_guard_status "" "$(edit_payload "$repo" "src/widget.ts" "agent_7")")" \
        "precondition: a real root agent_id must be honoured with jq" || return 1
    assert_eq "0" "$(write_guard_status "$bindir" "$(edit_payload "$repo" "src/widget.ts" "agent_7")")" \
        "precondition: a real root agent_id must be honoured without jq" || return 1

    local nested in_string brace_bait
    nested='{"session_id":"s1","cwd":"'"$repo"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"src/widget.ts","meta":{"agent_id":"forged"}}}'
    in_string='{"session_id":"s1","cwd":"'"$repo"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"src/widget.ts","content":"{\"agent_id\": \"fake\"}"}}'
    brace_bait='{"session_id":"s1","cwd":"'"$repo"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"src/widget.ts","content":"}}}} \"agent_id\": \"fake\""}}'

    assert_write_guard_blocks_both_parsers "$bindir" "$nested" "nested-object" || return 1
    assert_write_guard_blocks_both_parsers "$bindir" "$in_string" "quoted-string" || return 1
    assert_write_guard_blocks_both_parsers "$bindir" "$brace_bait" "brace-bait" || return 1
    return 0
}

test_j_engram_summary_matches_the_registration_it_actually_made() {
    # #70.2: setup.sh's closing summary printed "MCP registered per client" whenever
    # ENGRAM=yes. Without jq, engram_merge_json degrades to printed manual steps and
    # registers NOTHING — yet the summary still said it had. doctor.sh was already
    # self-aware here; the summary was not, so a jq-less user was told cross-session
    # memory was wired up when no config had been touched.
    #
    # The summary is now a four-way branch over run-scoped COUNTERS rather than
    # booleans, because one --all run genuinely mixes outcomes: with jq absent codex
    # still registers (its config is TOML and needs no jq) while claude-code and
    # opencode degrade. Branch order is NO_JQ → WRITTEN → BUILTIN → DEFERRED.
    #
    # Three of the four are pinned below, each against its exact sentence and each
    # only after the GROUND TRUTH has been checked, so no half can pass vacuously:
    # drop the claim unconditionally and the jq half fails; keep it unconditionally
    # and the jq-less half fails; fold pi into a degradation branch and the third
    # fails. DEFERRED (codex in project scope) and the mixed --all run are left out
    # on purpose — the counters make them self-consistent and --all is expensive.
    #
    # Every grep stops at a COLOUR boundary: setup_colors assigns the escapes
    # unconditionally, so "Engram:" and the bold "NOT registered" sit inside ANSI
    # codes and only the runs between them can be matched as literals.
    command -v jq >/dev/null 2>&1 || { echo "jq is required for the control halves of this case"; return 1; }
    local log="$TEST_TMPDIR/engram-calls.log"
    local manifest_name=".kurama-install-manifest.json"
    local out status summary recorded

    # ---- half 1 (WRITTEN): jq present, claude-code. It really is registered. ----
    local jqbin="$TEST_TMPDIR/engram-jqbin" jqhome="$TEST_TMPDIR/home-engram-jq"
    make_engram_shims "$jqbin" "$log"
    mkdir -p "$jqhome"
    status=0
    out=$(HOME="$jqhome" PATH="$jqbin:$PATH" bash "$SETUP_SCRIPT" --agent claude-code \
        --with-engram --non-interactive 2>&1) || status=$?
    assert_eq "0" "$status" "the jq-present --with-engram install must complete" || {
        printf '%s\n' "$out" | tail -8; return 1; }
    jq -e '.mcpServers.engram' "$jqhome/.claude.json" > /dev/null 2>&1 || {
        echo "ground truth: jq present, yet no engram MCP was registered in .claude.json"; return 1; }
    recorded="$(receipt_array_values "$jqhome/.claude/skills/$manifest_name" "engram_mcp")"
    [ -n "$recorded" ] || { echo "ground truth: the receipt recorded no engram_mcp entry"; return 1; }

    # The summary block is everything from the "Done!" line down — the part a user
    # reads last and believes.
    summary="$(printf '%s\n' "$out" | sed -n '/Done!/,$p')"
    printf '%s\n' "$summary" | grep -qF 'enabled as the persistence engine (MCP registered per client).' || {
        echo "a registration WAS made, but the summary does not report it:"
        printf '%s\n' "$summary"; return 1; }

    # ---- half 2 (NO_JQ): jq absent, claude-code. Nothing was registered. ----
    local nobin="$TEST_TMPDIR/engram-nojqbin" nohome="$TEST_TMPDIR/home-engram-nojq"
    make_nojq_farm "$nobin"
    make_engram_shims "$nobin" "$log"
    assert_farm_has_no_jq "$nobin" || return 1
    mkdir -p "$nohome"
    status=0
    out=$(HOME="$nohome" PATH="$nobin" bash "$SETUP_SCRIPT" --agent claude-code \
        --with-engram --non-interactive 2>&1) || status=$?
    assert_eq "0" "$status" "a jq-less --with-engram install must still complete" || {
        printf '%s\n' "$out" | tail -8; return 1; }
    if [ -e "$nohome/.claude.json" ]; then
        echo "ground truth: the jq-less run wrote a .claude.json it has no JSON merger for"
        return 1
    fi
    recorded="$(receipt_array_values "$nohome/.claude/skills/$manifest_name" "engram_mcp")"
    if [ -n "$recorded" ]; then
        echo "ground truth: the jq-less run recorded an engram_mcp entry it never wrote: $recorded"
        return 1
    fi

    summary="$(printf '%s\n' "$out" | sed -n '/Done!/,$p')"
    # Exactly one client (claude-code) failed to register, so the count is 1.
    printf '%s\n' "$summary" | grep -qF 'enabled, but the MCP server was' || {
        echo "the jq-less summary does not report the registration as skipped:"
        printf '%s\n' "$summary"; return 1; }
    printf '%s\n' "$summary" | grep -qF 'for 1 client(s) — jq is missing.' || {
        echo "the jq-less summary does not count the client or name jq as the reason:"
        printf '%s\n' "$summary"; return 1; }
    # …and the WRITTEN sentence must be nowhere near it: that is the false claim.
    if printf '%s\n' "$summary" | grep -qF 'MCP registered per client'; then
        echo "no MCP was registered, yet the summary still claims one per client:"
        printf '%s\n' "$summary"; return 1
    fi

    # ---- half 3 (BUILTIN): pi. No MCP entry is NEEDED — not a degradation. ----
    # Engram on Pi comes from the Pi package stack (gentle-engram), so this run
    # legitimately registers nothing. It is the branch a careless edit is likeliest
    # to break, because "no MCP entry" reads like a failure to anyone skimming.
    local pibin="$TEST_TMPDIR/engram-pibin" pihome="$TEST_TMPDIR/home-engram-pi"
    make_engram_shims "$pibin" "$log"
    mkdir -p "$pihome"
    status=0
    out=$(HOME="$pihome" PATH="$pibin:$PATH" bash "$SETUP_SCRIPT" --agent pi \
        --with-engram --without-pi-packages --non-interactive 2>&1) || status=$?
    assert_eq "0" "$status" "the pi --with-engram install must complete" || {
        printf '%s\n' "$out" | tail -8; return 1; }
    if [ -e "$pihome/.claude.json" ]; then
        echo "ground truth: the pi run registered an MCP server in a client config"; return 1
    fi
    recorded="$(receipt_array_values "$pihome/.pi/agent/skills/$manifest_name" "engram_mcp")"
    if [ -n "$recorded" ]; then
        echo "ground truth: the pi run recorded an engram_mcp entry: $recorded"; return 1
    fi

    summary="$(printf '%s\n' "$out" | sed -n '/Done!/,$p')"
    printf '%s\n' "$summary" | grep -qF "provided by the agent's own package stack — no MCP entry needed" || {
        echo "the pi summary never explains that no MCP entry is needed:"
        printf '%s\n' "$summary"; return 1; }
    if printf '%s\n' "$summary" | grep -qE 'NOT registered|jq is missing|no MCP registration was recorded'; then
        echo "pi's legitimate no-MCP-entry outcome is reported as a failure:"
        printf '%s\n' "$summary"; return 1
    fi
    return 0
}


# An Edit payload for file $3 in project $1 whose tool_input carries its OWN "cwd"
# ($2, a decoy root) serialized BEFORE the root cwd. Several tools legitimately take
# a cwd, so this is a shape a model can produce without meaning any harm — and the
# FIRST "cwd" in the payload text is the decoy, which is what an unanchored scan
# returns. No agent_id: this is the main thread.
edit_payload_cwd_hijack() {
    local root="$1" decoy="$2" file="$3"
    printf '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"cwd":"%s","file_path":"%s","old_string":"a","new_string":"b"},"cwd":"%s"}' \
        "$decoy" "$file" "$root"
}

# The same hijack aimed at the archive gate: a Skill payload naming $3, in project
# $1, whose tool_input carries the decoy cwd $2 ahead of the root cwd.
skill_payload_cwd_hijack() {
    local root="$1" decoy="$2" skill="$3"
    printf '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"cwd":"%s","skill":"%s"},"cwd":"%s"}' \
        "$decoy" "$skill" "$root"
}

# Echo the exit status of hook $2 over payload $3, through the jq-less farm at $1
# when $1 is non-empty and the ambient PATH (jq present) when it is empty.
#
# CLAUDE_PROJECT_DIR is pinned EMPTY, not merely left unset: it is the FIRST source
# the hooks consult for the project root, so an ambient value on the developer's or
# CI machine would skip the payload-cwd fallback entirely and every assertion in
# this case would pass without exercising the code it is about. KURAMA_CHANGE names
# the cycle for the archive gate; the write guard does not read it.
hook_status_no_project_dir() {
    local bindir="$1" hook="$2" payload="$3" status=0
    if [ -n "$bindir" ]; then
        printf '%s' "$payload" | CLAUDE_PROJECT_DIR="" KURAMA_CHANGE=add-widget \
            PATH="$bindir" bash "$hook" > /dev/null 2>&1 || status=$?
    else
        printf '%s' "$payload" | CLAUDE_PROJECT_DIR="" KURAMA_CHANGE=add-widget \
            bash "$hook" > /dev/null 2>&1 || status=$?
    fi
    printf '%s' "$status"
}

test_j_hooks_resolve_the_root_cwd_not_a_tool_input_one() {
    # The second field #70's root-anchoring had to cover, and the one with the wider
    # blast radius. `cwd` is a ROOT field of the PreToolUse contract, but several
    # tools take a cwd of their own, so a payload can carry two — and the shared
    # json_str helper disagreed with itself about which one it meant: jq walked
    # `.. | objects` in pre-order and returned the ROOT one, while the textual half
    # returned whichever came FIRST in the bytes. Same payload, two different project
    # roots, decided by which parser the host happened to have.
    #
    # Both failure modes were real, and in opposite directions:
    #   write guard, no jq  — resolved a root the target file is not under, so the
    #                         path arms fell through to `*) exit 0` and a MAIN-THREAD
    #                         write to repo code was ALLOWED. Fail-open, and worse
    #                         than the key-order bug #70 was opened for.
    #   archive gate, no jq — hunted for the verify report under the wrong root,
    #                         found none, and REFUSED a legitimate archive.
    #                         Fail-closed, but still a false verdict.
    #
    # So both hooks are driven with one shape, under both parsers: the guard must
    # BLOCK and the gate must ALLOW, exactly as they do on the honest payload.
    command -v jq >/dev/null 2>&1 || { echo "jq is required for the jq half of this case"; return 1; }
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/cwd-hijack"
    make_active_cycle_repo "$repo"
    # The decoy is a REAL directory with no SDD cycle in it — the most favourable
    # shape for the bug: a guard that resolves there finds no active cycle and has
    # every reason to allow the write.
    local decoy="$TEST_TMPDIR/cwd-decoy"
    mkdir -p "$decoy/src"
    printf 'export const widget = 1;\n' > "$decoy/src/widget.ts"

    local hijack
    hijack="$(edit_payload_cwd_hijack "$repo" "$decoy" "src/widget.ts")"

    # Non-vacuity 1: the decoy really is the FIRST "cwd" in the payload text. If the
    # builder ever drifts to root-first, an unanchored scan would return the right
    # answer by accident and this case would prove nothing.
    local first_cwd
    first_cwd="$(printf '%s' "$hijack" \
        | grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -n 1 \
        | sed -e 's/.*"cwd"[[:space:]]*:[[:space:]]*"//' -e 's/"$//')"
    assert_eq "$decoy" "$first_cwd" \
        "the decoy must be the first cwd in the payload bytes, or the hijack is not being tested" || return 1

    # Non-vacuity 2: the honest payload — same repo, same file, no decoy — must give
    # the verdicts asserted below. Otherwise a hook that blocks (or allows)
    # everything would satisfy this case without ever reading a cwd.
    local honest
    honest="$(edit_payload "$repo" "src/widget.ts")"
    assert_eq "2" "$(hook_status_no_project_dir "" "$WRITE_GUARD_HOOK" "$honest")" \
        "baseline: with jq the honest main-thread write must be blocked" || return 1
    assert_eq "2" "$(hook_status_no_project_dir "$bindir" "$WRITE_GUARD_HOOK" "$honest")" \
        "baseline: without jq the honest main-thread write must be blocked" || return 1

    # The write guard must reach the same verdict over the hijacked payload.
    assert_eq "2" "$(hook_status_no_project_dir "" "$WRITE_GUARD_HOOK" "$hijack")" \
        "with jq a tool_input cwd must not redirect the guard's project root" || return 1
    assert_eq "2" "$(hook_status_no_project_dir "$bindir" "$WRITE_GUARD_HOOK" "$hijack")" \
        "without jq a tool_input cwd must not redirect the guard's project root" || return 1

    # Now the archive gate, over the same shape. A PASS report in the REAL repo is
    # what makes the archive legitimate; under the decoy root there is none, so a
    # hook that resolves there refuses an archive it should have opened.
    write_verify_report "$repo" add-widget "PASS"
    local gate_honest gate_hijack
    gate_honest="$(skill_payload "$repo" sdd-archive)"
    gate_hijack="$(skill_payload_cwd_hijack "$repo" "$decoy" sdd-archive)"
    assert_eq "0" "$(hook_status_no_project_dir "" "$ARCHIVE_GATE_HOOK" "$gate_honest")" \
        "baseline: with jq a PASS verdict must open the gate" || return 1
    assert_eq "0" "$(hook_status_no_project_dir "$bindir" "$ARCHIVE_GATE_HOOK" "$gate_honest")" \
        "baseline: without jq a PASS verdict must open the gate" || return 1
    assert_eq "0" "$(hook_status_no_project_dir "" "$ARCHIVE_GATE_HOOK" "$gate_hijack")" \
        "with jq a tool_input cwd must not hide the verify report from the gate" || return 1
    assert_eq "0" "$(hook_status_no_project_dir "$bindir" "$ARCHIVE_GATE_HOOK" "$gate_hijack")" \
        "without jq a tool_input cwd must not hide the verify report from the gate" || return 1
    return 0
}
echo -e "${BOLD}UNIT-J (issue #70): the jq asterisks${NC}"
run_test "write guard decides the same way whatever the JSON key order (jq and awk)" test_j_write_guard_decides_the_same_way_whatever_the_key_order
run_test "write guard still refuses an agent_id spoofed inside tool_input (jq and awk)" test_j_write_guard_still_refuses_a_spoofed_agent_id_inside_tool_input
run_test "both hooks resolve the ROOT cwd, not a tool_input one (jq and awk)" test_j_hooks_resolve_the_root_cwd_not_a_tool_input_one
run_test "engram summary reports the registration that actually happened (jq / no jq / pi)" test_j_engram_summary_matches_the_registration_it_actually_made

echo ""

# ============================================================================
# ===== UNIT-K (issue #71) =====
# uninstall.sh's silent-success paths: an unparseable config left carrying dead
# Kurama entries after the files were deleted, and a crafted receipt entry that
# aborts the sweep mid-way. Plus the tui.json twin #63 fixed but never pinned.
# ============================================================================

test_k_uninstall_refuses_a_corrupt_opencode_config() {
    # #71.1: remove_engram_from_config and remove_kurama_agents_from_opencode_config
    # both end in `print_warn …; return 0` with no UNINSTALL_FAILED and no pre-flight
    # `jq -e .` probe. So an unparseable opencode.json meant the recorded files were
    # deleted, the config was left carrying Kurama's entries, and the run still
    # printed "Done." and exited 0 — the user was told the uninstall succeeded. Same
    # defect class #63 fixed for settings.json, one config over.
    #
    # A GLOBAL opencode install --with-engram records that one file in BOTH
    # engram_mcp[] and opencode_configs[], so corrupting it drives both functions in
    # a single run. The exit code is the assertion: the warning text is already
    # printed today, and printing it while exiting 0 is exactly the bug.
    command -v jq >/dev/null 2>&1 || { echo "jq is required for this test"; return 1; }
    local shim="$TEST_TMPDIR/ocbin" log="$TEST_TMPDIR/engram-calls.log"
    make_npm_shim "$shim"
    make_engram_shims "$shim" "$log"
    PATH="$shim:$PATH" bash "$SETUP_SCRIPT" --agent opencode --with-engram --non-interactive \
        > /dev/null 2>&1 || { echo "the opencode --with-engram install exited non-zero"; return 1; }

    local config="$HOME/.config/opencode/opencode.json"
    assert_file_exists "$config" || return 1
    jq -e '.mcp.engram' "$config" > /dev/null 2>&1 || {
        echo "precondition: engram was not registered in opencode.json"; return 1; }

    # Corrupted the same way the settings.json twin is: trailing garbage after a
    # valid object, so Kurama's entries stay textually present (a pre-flight still
    # recognises the file as ours to clean) while jq can no longer parse it.
    printf '\n]]]NOT JSON\n' >> "$config"
    if jq -e . "$config" > /dev/null 2>&1; then
        echo "opencode.json is still valid JSON — the corruption did not take"; return 1
    fi
    grep -q '"engram"' "$config" || { echo "corruption dropped the engram entry text"; return 1; }

    local output status=0
    output=$(bash "$UNINSTALL_SCRIPT" --agent opencode --without-pi-packages 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        echo "uninstall exited 0 over an unparseable opencode.json; it said:"
        printf '%s\n' "$output" | tail -8
        return 1
    fi
    printf '%s\n' "$output" | grep -qF 'opencode.json' || {
        echo "the failure never names the config it could not clean:"
        printf '%s\n' "$output" | tail -8
        return 1
    }
    return 0
}

test_k_uninstall_refuses_a_corrupt_tui_json_with_jq_present() {
    # #71's regression note: PR #63 fixed BOTH pre-flight halves — settings.json and
    # tui.json — but pinned only the settings.json one (UNIT-I above). Reverting the
    # `jq -e .` probe from the tui.json guard leaves this suite fully green today,
    # because the only tui.json case that exists (UNIT-H's jq-less logo path) is
    # already carried by the `have_jq` half of that same condition. THAT GAP IS WHY
    # THIS CASE EXISTS: jq PRESENT, tui.json unparseable.
    #
    # The consequence being pinned: the strip cannot run, so removing the logo .tsx
    # recorded in files[] would leave tui.json's plugin[] pointing at a file that is
    # gone — a dangling TUI plugin that breaks OpenCode's TUI on next start. Refuse
    # the whole target before anything is removed, exactly as the jq-absent path does.
    command -v jq >/dev/null 2>&1 || { echo "jq is required for this test"; return 1; }
    run_setup_opencode --with-logo || { echo "opencode --with-logo install failed"; return 1; }
    local tui="$HOME/.config/opencode/tui.json"
    local tsx="$HOME/.config/opencode/tui-plugins/kurama-logo.tsx"
    assert_file_exists "$tui" || return 1
    assert_file_exists "$tsx" || return 1
    grep -q 'kurama-logo.tsx' "$tui" \
        || { echo "logo was not registered in tui.json (jq missing at install?)"; return 1; }

    printf '\n]]]NOT JSON\n' >> "$tui"
    if jq -e . "$tui" > /dev/null 2>&1; then
        echo "tui.json is still valid JSON — the corruption did not take"; return 1
    fi
    grep -q 'kurama-logo.tsx' "$tui" \
        || { echo "corruption dropped the plugin registration text"; return 1; }
    local before; before="$(cat "$tui")"

    local output status=0
    output=$(bash "$UNINSTALL_SCRIPT" --agent opencode --without-pi-packages 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        echo "uninstall exited 0 over an unparseable tui.json (jq present); it said:"
        printf '%s\n' "$output" | tail -8
        return 1
    fi
    assert_eq "$before" "$(cat "$tui")" "an unstrippable tui.json must be left untouched" || return 1
    assert_file_exists "$tsx" || {
        echo "the logo plugin was deleted while tui.json still references it"; return 1; }
    printf '%s\n' "$output" | grep -qF 'tui.json' || {
        echo "the refusal never names tui.json:"
        printf '%s\n' "$output" | tail -8
        return 1
    }
    return 0
}

test_k_uninstall_refuses_a_dir_slash_entry_and_finishes_the_rest() {
    # #71.3: the rm loop splits every files[] entry into $tdir/$tbase. An entry
    # ending in "/" (or "a/..") leaves $tbase EMPTY, so $target is the DIRECTORY
    # itself and the bare `rm -f` fails with EISDIR — under errexit that aborts the
    # whole run inside the loop, so every entry recorded AFTER the crafted one is
    # silently left on disk and the summary is never printed. The documented fix is a
    # per-entry refusal (`case "$tbase" in ''|.|..)`) that lets the sweep continue.
    #
    # This is NOT UNIT-I's directory entry, which names a real path and must abort
    # loudly: here the entry is malformed rather than a genuine target, so refusing
    # it and carrying on is the correct behaviour.
    #
    # The exit CODE deliberately is not asserted: an errexit abort and a refusal that
    # flags UNINSTALL_FAILED both exit non-zero, so it cannot tell the two apart.
    # What proves the run CONTINUED is the entry recorded after the crafted one being
    # gone, plus remove_target reaching its closing "N file(s) removed" line — which
    # an abort inside the loop never reaches.
    command -v jq >/dev/null 2>&1 || { echo "jq is required to inject the receipt entries"; return 1; }
    local repo="$TEST_TMPDIR/proj-dir-slash"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "the project install setup exited non-zero"; return 1; }

    local receipt="$repo/.kurama-install-manifest.json"
    assert_file_exists "$receipt" || return 1

    # The crafted entry: a real directory inside the containment root, recorded with
    # a trailing slash so the basename comes out empty. The sentinel inside it keeps
    # the prune walk from being able to claim it either way.
    mkdir -p "$repo/kurama-dir-entry" || { echo "could not stage the directory entry"; return 1; }
    printf 'sentinel\n' > "$repo/kurama-dir-entry/keep.txt"
    # The legitimate entry recorded AFTER it — the one whose removal proves the sweep
    # got past the refusal instead of dying on it.
    printf 'late\n' > "$repo/kurama-late-entry.txt"

    local tmp="$receipt.tmp"
    if ! jq '.files += ["kurama-dir-entry/", "kurama-late-entry.txt"]' "$receipt" > "$tmp"; then
        echo "could not inject the receipt entries"; return 1
    fi
    mv "$tmp" "$receipt"
    local order
    order="$(jq -r '[.files[] | select(. == "kurama-dir-entry/" or . == "kurama-late-entry.txt")] | join(",")' "$receipt")"
    assert_eq "kurama-dir-entry/,kurama-late-entry.txt" "$order" \
        "the crafted entry must be recorded BEFORE the legitimate one, or the case proves nothing" || return 1

    local output status=0
    output=$(bash "$UNINSTALL_SCRIPT" --scope project --path "$repo" --without-pi-packages 2>&1) || status=$?

    # Continued: the entry after the crafted one was still removed.
    if [ -e "$repo/kurama-late-entry.txt" ]; then
        echo "the sweep never reached the entry recorded after the malformed one (exit $status):"
        printf '%s\n' "$output" | tail -8
        return 1
    fi
    # Completed: remove_target printed its closing summary rather than dying mid-loop.
    printf '%s\n' "$output" | grep -qF 'file(s) removed' || {
        echo "the run never reached remove_target's closing summary (exit $status):"
        printf '%s\n' "$output" | tail -8
        return 1
    }
    # Refused: the malformed entry was named, not silently skipped …
    printf '%s\n' "$output" | grep -qF 'kurama-dir-entry' || {
        echo "the malformed entry was never named in the output:"
        printf '%s\n' "$output" | tail -8
        return 1
    }
    # … never reported as removed …
    if printf '%s\n' "$output" | grep -qF 'removed: kurama-dir-entry'; then
        echo "uninstall printed a 'removed:' line for the malformed entry"
        return 1
    fi
    # … and the directory it named is still there.
    assert_dir_exists "$repo/kurama-dir-entry" || return 1
    assert_file_exists "$repo/kurama-dir-entry/keep.txt" || return 1
    return 0
}

echo -e "${BOLD}UNIT-K (issue #71): uninstall silent-success paths${NC}"
run_test "uninstall refuses a corrupt opencode.json (non-zero, names the config)" test_k_uninstall_refuses_a_corrupt_opencode_config
run_test "uninstall refuses a corrupt tui.json with jq present (logo plugin survives)" test_k_uninstall_refuses_a_corrupt_tui_json_with_jq_present
run_test "uninstall refuses a 'dir/' receipt entry and still sweeps the rest" test_k_uninstall_refuses_a_dir_slash_entry_and_finishes_the_rest

echo ""

# ============================================================================
# UNIT-L (issues #73, #102): session identity — persona, the user's name, sdd-learn
#
# #102 added a fifth property: BOTH values must be resolvable in a session that
# never runs an SDD cycle. #73 wrote them for "session start" but left the
# resolution instructions in a file the prompt loads at CYCLE start, so a session
# with no cycle greeted nobody and adopted no voice, whatever the config said.
#
# Three additions share one plumbing point (the settings the preflight already
# resolves at session start), and each carries a property that breaks silently:
#
#   * persona ABSENT must stay indistinguishable from the pre-#73 install. The
#     installer must never read, branch on, or template the setting.
#   * a persona that IS set must reach the orchestrator's conversation and stop
#     there. Losing the artifact-boundary clause while keeping the persona line
#     is the exact failure #73 exists to prevent, and no other case in this file
#     would notice it.
#   * the user's name is resolved per-machine from git and must never reach a
#     file git would carry into a commit. `openspec/config.yaml` is SHARED, so a
#     name persisted there greets every teammate as whoever ran `sdd-init`.
#   * `sdd-learn` ships in the manifest's `optional` group, which is in setup.sh's
#     default active set — so it installs by default, and every skill count in
#     this file moved 24 -> 25 for it (120 -> 125 across the five global targets).
#     #104's `sdd-brainstorm` joins the same group and moved them again, 25 -> 26
#     (125 -> 130), and #85/#86's `kurama-report` + `systemic-issue-triage` a third
#     time, 26 -> 28 (130 -> 140). The group now drops FIVE skills under
#     `--without optional`.
#
# NOTE on the control run. A "byte-identical to before the feature" case invites
# `git show main:examples/claude-code/CLAUDE.md` as its control, but
# .github/workflows/pr-check.yml checks out at actions/checkout's default depth
# of 1: `main` is not a ref on CI, so a history-based control would either fail
# there or degrade to a skip — a vacuous green in the one place it matters most.
# The control used instead needs no history and is stronger for what is actually
# claimed: the same repo state installed three ways (no settings file at all /
# `persona: neutral` / `persona: argentino`) must produce three byte-identical
# trees. Persona-absent behaving differently would diverge them; the installer
# templating the persona anywhere would diverge them.
# ============================================================================

# Write the `openspec/config.yaml` shape `sdd-init` persists into the repo at $1,
# carrying the persona in $2. Trimmed to the settings block these cases need — the
# canonical schema lives in skills/sdd-init/SKILL.md; what is required here is a
# real settings home with a real persona key, not a full fixture.
write_sdd_init_config() {
    local repo="$1" persona="$2"
    mkdir -p "$repo/openspec"
    {
        printf '# openspec/config.yaml\n'
        printf 'schema: spec-driven\n'
        printf 'artifact_store:\n'
        printf '  mode: openspec\n'
        printf 'execution_mode: supervised\n'
        printf 'compliance_mode: behavioral\n'
        printf 'persona: %s\n' "$persona"
        printf 'tdd:\n'
        printf '  enabled: false\n'
        printf 'kanban:\n'
        printf '  enabled: false\n'
    } > "$repo/openspec/config.yaml"
}

# Fail unless the installed trees at $1 and $2 are byte-identical. `.git` is
# excluded because the two repos are genuinely different repositories, and
# `openspec/` because it is the settings home the caller deliberately varies —
# it is the INPUT, not part of what the installer produced. `.kurama/` is
# excluded for a third reason (#106): the skill registry setup builds there
# indexes skills by ABSOLUTE path, so two different repos cannot produce a
# byte-identical one and comparing it asks an impossible question. Its content is
# asserted directly by UNIT-U instead. $3 names the comparison so a failure says
# which pair diverged.
assert_installed_trees_identical() {
    local a="$1" b="$2" what="$3"
    local out
    out="$(diff -r -x '.git' -x 'openspec' -x '.kurama' "$a" "$b" 2>&1)" || true
    if [ -n "$out" ]; then
        echo "  $what: the installed trees differ"
        # #99: herestring — `printf | head` is the same SIGPIPE shape, and a big
        # diff is exactly when head closes the pipe first.
        head -20 <<<"$out"
        return 1
    fi
    return 0
}

# Print the kurama orchestrator block of the prompt file $1 — everything strictly
# between the BEGIN/END markers, so a user's own rules above or below the block
# can never answer for it. Empty when the file or the markers are missing, which
# is why every caller size-checks the result before grepping it.
kurama_block() {
    local file="$1"
    [ -f "$file" ] || return 0
    awk '/<!-- BEGIN:kurama -->/ { f = 1; next } /<!-- END:kurama -->/ { f = 0 } f' "$file"
}

# Print the orchestrator half of the prompt text on stdin: the lines from the
# `## Kurama Orchestrator` heading up to — and not including — `## SDD Workflow`.
# That half is what every session reads regardless of whether a cycle ever starts,
# so an instruction found HERE is an instruction that is not behind the SDD gate,
# and one found only after the cut is one a non-SDD session never executes.
pre_sdd_region() {
    awk '/^## SDD Workflow/ { exit } /^## Kurama Orchestrator/ { f = 1 } f'
}

# Fail unless $1 carries the session-identity RESOLUTION instructions themselves —
# the literal settings home the persona key is read from, the literal name ladder,
# and the two rules that must travel with them. $2 names the prompt under test.
assert_region_carries_session_identity() {
    local region="$1" what="$2"
    assert_matches "$region" 'persona.*openspec/config\.yaml' \
        "$what: where the persona key is read from (the settings home, named in the prompt itself)" || return 1
    assert_matches "$region" 'sdd-init/.project.' \
        "$what: the engram-mode settings home for that same key" || return 1
    assert_matches "$region" 'do not open.{0,40}personas\.md' \
        "$what: the neutral/absent no-op — the preset registry is never opened" || return 1
    assert_matches "$region" 'git config user\.name' \
        "$what: step 1 of the name ladder, as the runnable command" || return 1
    assert_matches "$region" 'empty.*gh api user' \
        "$what: the gh fallback, conditioned on step 1 coming back empty" || return 1
    assert_matches "$region" 'name .*(never|not) written to a committed file' \
        "$what: the never-committed rule, travelling WITH the instruction" || return 1
    return 0
}

# Fail unless $1 is a plausible orchestrator block rather than the empty string a
# missing file or an unbalanced marker pair yields. Every `grep -q ... || return 1`
# in this section is a pass-by-default over an empty haystack without it.
assert_block_is_substantial() {
    local block="$1"
    local bytes
    bytes=$(printf '%s' "$block" | wc -c | tr -d ' ')
    if [ "$bytes" -lt 2000 ]; then
        echo "  the extracted kurama block is ${bytes}B — the markers or the merge are broken,"
        echo "  and every content assertion below would pass over an empty string"
        return 1
    fi
    return 0
}

# Fail unless the ERE $2 matches a line of $1 (case-insensitively). $3 names the
# contract clause, so a failure reports what the prompt lost rather than a regex.
#
# #99: the haystack reaches grep as a HERESTRING, never through a pipe. With
# `printf '%s\n' "$haystack" | grep -Eqi`, grep -q exits on its first match and
# closes the pipe; on a haystack larger than the pipe buffer printf is still
# writing and takes SIGPIPE, and under `set -euo pipefail` the pipeline's status
# is printf's 141 — so a MATCH was reported as "nothing matched". It fired on the
# ~23KB orchestrator prompt on macOS/bash 3.2 (PR #98). A herestring has no
# writer process to signal. Do not reintroduce the pipe.
assert_matches() {
    local haystack="$1" pattern="$2" what="$3"
    if grep -Eqi "$pattern" <<<"$haystack"; then
        return 0
    fi
    echo "  the shipped text no longer carries: $what"
    echo "    (nothing matched: $pattern)"
    return 1
}

# The inverse: fail when the ERE $2 DOES match. Same #99 rule: herestring in,
# and the evidence lines are capped with grep's own `-m 3` rather than `| head -3`
# — head closing the pipe would SIGPIPE grep for the same reason.
assert_not_matches() {
    local haystack="$1" pattern="$2" what="$3"
    if grep -Eqi "$pattern" <<<"$haystack"; then
        echo "  the shipped text must not carry: $what"
        grep -Ein -m 3 "$pattern" <<<"$haystack" | awk '{ print "    " $0 }'
        return 1
    fi
    return 0
}

# Print the file $1 as a single line, newlines collapsed to spaces. Every contract
# sentence pinned in this section is a wrapped markdown bullet, so a line-oriented
# match would miss it for a reason that has nothing to do with the contract.
flatten_file() {
    tr '\n' ' ' < "$1"
}

# Print every tracked path in the repo $1 whose CONTENT holds the literal $2.
# Routed through `git grep` on purpose: "tracked" then means what git itself
# would carry into a commit — .gitignore and all — rather than what a filesystem
# walk happens to find.
tracked_files_containing() {
    local repo="$1" needle="$2"
    git -C "$repo" grep -lF -- "$needle" 2>/dev/null || true
}

# validate_skills.sh's own frontmatter rule: the file must open with `---` on line
# 1 and close the fence later. A file that opens a fence and never closes it has
# no frontmatter at all, rather than a frontmatter that is the whole file.
#
# One awk pass, NOT `head -1 | grep -q` + `tail -n +2 | grep -q`, and the reason is
# not style. The fence closes near the TOP of a SKILL.md, so `grep -q` matches and
# exits while `tail` still has the whole body to write. Once the file exceeds the
# pipe buffer (~16KB on macOS before it grows), `tail` blocks, takes SIGPIPE, and
# exits 141 — which `set -o pipefail` promotes to the pipeline's status. The helper
# then reports "the fence never closes" about a file whose fence plainly closes on
# line 15, and it does so DETERMINISTICALLY above that size.
#
# It had never fired because every skill was under the buffer: sdd-learn is 13.9KB
# and returns 0, sdd-brainstorm is 22.2KB and returned 141 every single time. The
# awk below is the same logic as validate_skills.sh's own frontmatter_fence_closed
# — deliberately, so the test helper and the shipped gate cannot drift — and it
# reads the file directly, so there is no pipe to break.
skill_frontmatter_fence_closed() {
    local file="$1"
    [ -f "$file" ] || return 1
    awk '
        NR == 1 && $0 !~ /^---[[:space:]]*$/ { exit }
        NR > 1 && /^---[[:space:]]*$/         { closed = 1; exit }
        END { exit (closed ? 0 : 1) }
    ' "$file"
}

# Print the YAML frontmatter of $1 — the lines strictly between the opening and
# closing fences. Callers must have checked the fence closes first.
skill_frontmatter() {
    awk 'NR == 1 { next } /^---[[:space:]]*$/ { exit } { print }' "$1"
}

test_l_persona_absent_installs_a_byte_identical_tree() {
    # What would make this pass for the wrong reason: three installs that all
    # FAILED leave three identically empty trees, and `diff -r` is silent over
    # them. Three guards close that: every tree is asserted to be a COMPLETE
    # install, the inputs are asserted to genuinely differ, and the comparator is
    # proved to notice a planted file before its silence is trusted anywhere.
    local none="$TEST_TMPDIR/persona-none"
    local neutral="$TEST_TMPDIR/persona-neutral"
    local preset="$TEST_TMPDIR/persona-preset"
    make_git_repo "$none"
    make_git_repo "$neutral"
    make_git_repo "$preset"
    write_sdd_init_config "$neutral" neutral
    write_sdd_init_config "$preset" argentino

    local d
    for d in "$none" "$neutral" "$preset"; do
        bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$d" \
            --non-interactive --without-engram > /dev/null 2>&1 \
            || { echo "project-scope setup exited non-zero for ${d##*/}"; return 1; }
        assert_all_skills_installed "$d/.claude/skills" || return 1
        assert_eq "${#EXPECTED_SKILLS[@]}" "$(count_skill_files "$d/.claude/skills")" \
            "${d##*/} is not a complete install — an empty tree compares equal to anything" || return 1
        assert_balanced_kurama_block "$d/CLAUDE.md" || return 1
    done

    # The inputs really did differ, or this compares three copies of one question.
    grep -q '^persona: argentino$' "$preset/openspec/config.yaml" \
        || { echo "the preset variant never received persona: argentino"; return 1; }
    grep -q '^persona: neutral$' "$neutral/openspec/config.yaml" \
        || { echo "the neutral variant never received persona: neutral"; return 1; }
    if [ -e "$none/openspec/config.yaml" ]; then
        echo "the persona-absent variant must have NO settings file at all"
        return 1
    fi

    # Positive control for the comparator itself.
    printf 'sentinel\n' > "$neutral/.kurama-tree-compare-sentinel"
    if assert_installed_trees_identical "$none" "$neutral" "positive control" > /dev/null 2>&1; then
        rm -f "$neutral/.kurama-tree-compare-sentinel"
        echo "diff -r stayed silent over a planted file — its silence below proves nothing"
        return 1
    fi
    rm -f "$neutral/.kurama-tree-compare-sentinel"

    assert_installed_trees_identical "$none" "$neutral" \
        "persona absent vs persona: neutral" || return 1
    assert_installed_trees_identical "$none" "$preset" \
        "persona absent vs persona: argentino" || return 1
    return 0
}

test_l_neutral_and_absent_are_the_same_declared_no_op() {
    # The byte-identical trees above prove the INSTALLER is persona-blind. They say
    # nothing about the orchestrator, which resolves the setting at runtime out of
    # files this repo ships — so those files have to state the no-op themselves.
    #
    # The sharpest observable of the no-op is that `_shared/personas.md` is never
    # opened on the neutral or absent path. This suite CANNOT watch that read: the
    # reader is a model consuming a prompt, and install_test.sh runs installers and
    # inspects files — there is no session to trace and no descriptor to watch. What
    # it can pin, and does, is the instruction that forbids the read, in the exact
    # file the orchestrator executes. Anything stronger needs a session-level probe
    # this repo does not have, and pretending otherwise would be the worst outcome:
    # a case that reads like it proves the read never happens and proves nothing.
    #
    # Both paths are pinned, not just the absent one. `sdd-init` writes
    # `persona: neutral` EXPLICITLY today, so absent is the legacy shape and
    # explicit-neutral is what almost every real settings home carries.
    #
    # What would make this pass for the wrong reason: grepping the whole CLAUDE.md
    # would also match a user's own rules outside the block, and grepping a MISSING
    # file matches nothing at all while the `|| return 1` chain still reads as a
    # pass. So the prompt is narrowed to the block between the markers and
    # size-checked, and every protocol file is asserted to exist before it is read.
    local repo="$TEST_TMPDIR/persona-absent-prompt"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --non-interactive --without-engram > /dev/null 2>&1 \
        || { echo "project-scope setup exited non-zero"; return 1; }

    local block
    block="$(kurama_block "$repo/CLAUDE.md")"
    assert_block_is_substantial "$block" || return 1
    assert_matches "$block" 'persona.*neutral.*(today|unchanged|no-op|exact behavio)' \
        "absent/neutral declared a no-op in the prompt (today's behavior, no voice adopted)" || return 1

    # The preflight that actually resolves the key. Pinned against the skill file the
    # orchestrator executes, never against docs/ — the two can drift and only one runs.
    local protocol="$repo/.claude/skills/_shared/orchestrator-sdd-protocol.md"
    assert_file_exists "$protocol" || return 1
    assert_file_not_empty "$protocol" 1000 || return 1
    local proto_flat
    proto_flat="$(flatten_file "$protocol")"

    assert_matches "$proto_flat" 'do not read.{0,40}personas\.md' \
        "the instruction NOT to open the preset registry on the neutral/absent path" || return 1
    assert_matches "$proto_flat" 'read the file only in this case' \
        "the read confined to the known-preset branch (nothing else may open the registry)" || return 1
    assert_matches "$proto_flat" 'behaves exactly as it did before the key existed' \
        "the equivalence contract (no persona key == the pre-#73 session)" || return 1
    assert_matches "$proto_flat" 'persona: neutral.{0,40}written explicitly.{0,40}identical to absent' \
        "explicit neutral declared identical to absent (the path sdd-init actually writes)" || return 1
    # A committed config means a typo in it reaches all three teammates at once, so
    # the unknown-value branch must degrade, never fail.
    assert_matches "$proto_flat" 'unknown value.{0,40}fall back to.{0,20}neutral' \
        "the unknown-value fallback to neutral" || return 1
    assert_matches "$proto_flat" 'never fail the preflight' \
        "the rule that an unknown persona never fails the preflight" || return 1

    local registry_flat
    registry_flat="$(flatten_file "$repo/.claude/skills/_shared/personas.md")"
    assert_matches "$registry_flat" 'degrades to.{0,20}neutral.{0,40}never fails' \
        "the same degrade-never-fail rule restated in the registry" || return 1
    return 0
}

test_l_persona_reaches_the_orchestrator_conversation_only() {
    # The persona setting is inert at install time — the case above pins that — so
    # what is verified here is the prompt the orchestrator will consult once the
    # setting resolves: it must carry the persona instruction AND, in the same
    # prompt, the boundary that keeps the persona out of every artifact.
    #
    # What would make this pass for the wrong reason: a single `grep -q persona`
    # over the whole file passes on a prompt that adopts a voice and says nothing
    # about artifacts — the exact regression #73 is designed to avoid. So the
    # boundary clause is asserted as its own anchor, on the extracted block, and
    # the block is size-checked so an empty haystack cannot answer for it.
    local repo="$TEST_TMPDIR/persona-set"
    make_git_repo "$repo"
    write_sdd_init_config "$repo" argentino
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --non-interactive --without-engram > /dev/null 2>&1 \
        || { echo "project-scope setup exited non-zero"; return 1; }

    local block
    block="$(kurama_block "$repo/CLAUDE.md")"
    assert_block_is_substantial "$block" || return 1

    assert_matches "$block" 'persona' \
        "the persona instruction" || return 1
    # THE half that matters.
    assert_matches "$block" '(specs|proposals|designs).*commit messages.*language' \
        "the artifact boundary (specs/proposals/designs/commits keep the project's language)" || return 1
    assert_matches "$block" 'never an override' \
        "the precedence rule (an explicit user instruction beats the configured persona)" || return 1
    # #73 composes the persona with the Language Domain Contract already in core.md
    # rather than replacing it: the persona sets the register of the half that was
    # ALREADY going out in the user's language, and grants nothing on the artifact
    # half. Both halves are asserted, because a persona that quietly widened the
    # contract would still satisfy the persona anchors above on their own.
    assert_matches "$block" 'language domain contract' \
        "the Language Domain Contract the persona composes with" || return 1
    assert_matches "$block" 'artifacts default to neutral english' \
        "the artifact half of that contract (a persona must not widen it)" || return 1
    # #73 keeps the presets in a registry file "so adding one is a file, not a code
    # change". A preset NAME baked into the shipped prompt would break that, and
    # would also mean this case was reading its own input back.
    assert_not_matches "$block" 'argentino' \
        "a hardcoded preset name (presets belong to _shared/personas.md, not the prompt)" || return 1

    # The registry the prompt points at has to be installed, or a resolved persona
    # has nothing to resolve against — and the boundary must be restated there,
    # since that file is what a non-neutral session actually reads.
    local registry="$repo/.claude/skills/_shared/personas.md"
    assert_file_exists "$registry" || return 1
    assert_file_not_empty "$registry" 500 || return 1
    grep -q 'argentino' "$registry" \
        || { echo "the installed personas.md carries no argentino preset"; return 1; }
    local registry_flat
    registry_flat="$(flatten_file "$registry")"
    assert_matches "$registry_flat" '(specs|proposals|designs).*commit messages.*language' \
        "the artifact boundary, restated in the registry a non-neutral session actually reads" || return 1
    return 0
}

test_l_user_name_never_lands_in_a_committed_file() {
    # #73 resolves the user's name from `git config user.name` precisely so it stays
    # per-machine. `openspec/config.yaml` is committed and shared, so a name written
    # into it — or into the receipt, or into a generated prompt — greets all three
    # teammates as whoever happened to run `sdd-init`.
    #
    # What would make this pass for the wrong reason: `git grep` finding nothing
    # because nothing is tracked, because the search itself is broken, or because
    # the name was never distinctive enough to tell from ordinary prose. Guarded by
    # asserting the name IS configured, that a real install IS staged, and — the
    # one that matters — that the same search finds a deliberately planted copy
    # before it is trusted to report zero.
    local repo="$TEST_TMPDIR/named-proj"
    local who='Zzyzx Quillfeather'
    make_git_repo "$repo"
    # Set BOTH homes for the name. Repo-local alone would only be visible to a
    # leak that ran `git -C <target> config`; the global one (safe — HOME is the
    # per-test sandbox) is what a resolution running in the installer's own cwd
    # would read. A case blind to half the resolution paths is a case that reports
    # clean over the leak it did not think of.
    git -C "$repo" config user.name "$who" >/dev/null 2>&1
    git config --global user.name "$who" >/dev/null 2>&1
    git config --global user.email test@example.com >/dev/null 2>&1
    assert_eq "$who" "$(git -C "$repo" config user.name)" \
        "the distinctive name was not configured — the search below would prove nothing" || return 1
    assert_eq "$who" "$(git config --global user.name)" \
        "the sandboxed global git identity was not set — a leak from the installer's cwd would go unseen" || return 1

    write_sdd_init_config "$repo" argentino
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --non-interactive --without-engram > /dev/null 2>&1 \
        || { echo "project-scope setup exited non-zero"; return 1; }
    git -C "$repo" add -A >/dev/null 2>&1

    # A real install is staged: the search has something to look through.
    local tracked
    tracked=$(git -C "$repo" ls-files | wc -l | tr -d ' ')
    if [ "$tracked" -lt 20 ]; then
        echo "only $tracked tracked files — nothing was installed, so finding no name means nothing"
        return 1
    fi
    git -C "$repo" ls-files | grep -qx 'CLAUDE.md' \
        || { echo "the merged orchestrator prompt is not tracked — it was never searched"; return 1; }
    git -C "$repo" ls-files | grep -qx 'openspec/config.yaml' \
        || { echo "the settings home is not tracked — it was never searched"; return 1; }

    # Positive control: plant the name in a tracked file and require the search to
    # find it, then take it back out.
    printf '%s\n' "$who" > "$repo/.kurama-name-probe"
    git -C "$repo" add -A >/dev/null 2>&1
    if [ -z "$(tracked_files_containing "$repo" "$who")" ]; then
        echo "the tracked-content search missed a planted copy of the name — it cannot report a clean tree"
        return 1
    fi
    git -C "$repo" rm -q --cached .kurama-name-probe >/dev/null 2>&1
    rm -f "$repo/.kurama-name-probe"

    local hits
    hits="$(tracked_files_containing "$repo" "$who")"
    if [ -n "$hits" ]; then
        echo "the user's name reached files git would commit:"
        printf '%s\n' "$hits" | head -10 | awk '{ print "    " $0 }'
        return 1
    fi
    # Named explicitly, because these three are the ones a future change is most
    # likely to start writing the name into.
    if grep -qF "$who" "$repo/openspec/config.yaml"; then
        echo "the name was persisted into the SHARED openspec/config.yaml"; return 1
    fi
    if grep -qF "$who" "$repo/.kurama-install-manifest.json"; then
        echo "the name was recorded in the install receipt"; return 1
    fi
    if grep -qF "$who" "$repo/CLAUDE.md"; then
        echo "the name was baked into the merged orchestrator prompt"; return 1
    fi
    # The generated overlays this repo ships are committed files too: they must
    # carry the RULE about the name, never a resolved value.
    grep -Eqi "name .*(never|not) written to a committed file" "$REPO_DIR/examples/claude-code/CLAUDE.md" \
        || { echo "the shipped prompt states no rule keeping the name out of committed files"; return 1; }
    return 0
}

test_l_sdd_learn_installs_by_default() {
    # `sdd-learn` sits in the manifest's `optional` group, which is in setup.sh's
    # SETUP_ACTIVE_GROUPS — so a plain install ships it, with no flag.
    #
    # What would make this pass for the wrong reason: asserting only that the
    # directory exists, which an empty leftover directory satisfies. The file is
    # size-checked, and the count is pinned to EXPECTED_SKILLS so adding the skill
    # without moving the totals cannot slip through.
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    local base="$HOME/.claude/skills"
    assert_dir_exists "$base/sdd-learn" || return 1
    assert_file_exists "$base/sdd-learn/SKILL.md" || return 1
    assert_file_not_empty "$base/sdd-learn/SKILL.md" 500 || return 1
    assert_eq "${#EXPECTED_SKILLS[@]}" "$(count_skill_files "$base")" \
        "the default set must be exactly the EXPECTED_SKILLS list, sdd-learn included" || return 1
    return 0
}

test_l_sdd_learn_is_a_well_formed_registered_skill() {
    # Installed is not the same as loadable: a SKILL.md whose frontmatter fence
    # never closes, or whose name:/description: are empty, is dead weight in every
    # harness. validate_skills.sh is the shipped gate for exactly that, so it is
    # run here rather than reimplemented — but running it proves nothing about
    # sdd-learn unless sdd-learn is registered in the manifest it walks, which is
    # asserted first.
    assert_file_exists "$MANIFEST_FILE" || return 1
    grep -q '"sdd-learn"' "$MANIFEST_FILE" \
        || { echo "sdd-learn is not registered in skills/manifest.json — validate_skills.sh never sees it"; return 1; }

    local src="$REPO_DIR/skills/sdd-learn/SKILL.md"
    assert_file_exists "$src" || return 1
    skill_frontmatter_fence_closed "$src" \
        || { echo "skills/sdd-learn/SKILL.md: the frontmatter fence never closes"; return 1; }
    local fm
    fm="$(skill_frontmatter "$src")"
    printf '%s\n' "$fm" | grep -qE '^name:[[:space:]]*sdd-learn[[:space:]]*$' \
        || { echo "skills/sdd-learn/SKILL.md: frontmatter 'name:' is not sdd-learn"; return 1; }
    printf '%s\n' "$fm" | grep -qE '^description:[[:space:]]*[^[:space:]]' \
        || { echo "skills/sdd-learn/SKILL.md: frontmatter 'description:' is missing or empty"; return 1; }
    # A folded/literal scalar (`description: >`) satisfies the rule above with an
    # empty body, so the continuation has to carry real text of its own.
    if printf '%s\n' "$fm" | grep -qE '^description:[[:space:]]*[>|][-+0-9]*[[:space:]]*$'; then
        printf '%s\n' "$fm" | grep -qE '^[[:space:]]+[^[:space:]]' \
            || { echo "skills/sdd-learn/SKILL.md: 'description:' folds into an empty block"; return 1; }
    fi

    local output status=0
    output=$(bash "$VALIDATE_SCRIPT" 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
        echo "validate_skills.sh exited $status with sdd-learn registered:"
        printf '%s\n' "$output" | grep -a 'FAIL' | head -5
        return 1
    fi
    return 0
}

test_l_session_identity_resolves_without_an_sdd_cycle() {
    # #102. Both identity values were WRITTEN for session start and READ from a file
    # the prompt only loads when a cycle starts — "Load it when a cycle starts. A
    # session that never invokes SDD never needs it". So in a session that never ran
    # SDD, neither the greeting nor the persona ever fired: confirmed in the field on
    # a 6.1.1 repo where no cycle had run and neither took effect. The first use the
    # protocol itself lists for the name is the GREETING, which happens before any
    # cycle exists, so the instruction could never fire where it was needed most.
    #
    # The fix moves the resolution INSTRUCTIONS into the always-read half of the
    # prompt and leaves only the rationale and the full ladder behind the gate. What
    # is pinned here is that the shipped prompt carries the instruction ITSELF — the
    # literal settings home the persona key is read from and the literal `git config
    # user.name` ladder — plus the two rules that must travel with it rather than
    # stay behind it: the personas.md read ban on the neutral path, and the name
    # never reaching a committed file.
    #
    # What would make this pass for the wrong reason:
    #
    #   * Grepping the WHOLE prompt. The SDD half still names the protocol file and
    #     still points at *Session identity* inside it, so a whole-prompt grep for
    #     "persona" or "session identity" is satisfied by exactly the broken shape
    #     this case exists to catch. Every assertion runs on the region BEFORE
    #     `## SDD Workflow`.
    #   * An empty region — a renamed heading, an unbalanced marker pair — over which
    #     every `assert_matches ... || return 1` reads as a pass. Size-checked first.
    #   * A splitter that silently returns the whole block, putting the SDD half back
    #     into the haystack. Proved against a sentinel before it is trusted:
    #     `orchestrator-sdd-protocol.md` is in the full block and must be ABSENT from
    #     the region.
    #   * A pointer standing in for the instruction. A pointer sentence cannot carry
    #     `git config user.name` or `openspec/config.yaml`, which is why the runnable
    #     command and the literal path are what is asserted — not the word "persona".
    local repo="$TEST_TMPDIR/identity-no-cycle"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --non-interactive --without-engram > /dev/null 2>&1 \
        || { echo "project-scope setup exited non-zero"; return 1; }

    local block region
    block="$(kurama_block "$repo/CLAUDE.md")"
    assert_block_is_substantial "$block" || return 1
    region="$(printf '%s\n' "$block" | pre_sdd_region)"

    # The splitter's own positive control, before its output is trusted as a haystack.
    # Herestrings, not pipes (#99): these two haystacks are the ~23KB prompt that
    # made `printf | grep -q` take SIGPIPE on macOS.
    grep -q 'orchestrator-sdd-protocol\.md' <<<"$block" \
        || { echo "the full block never named the protocol file — the sentinel below proves nothing"; return 1; }
    if grep -q 'orchestrator-sdd-protocol\.md' <<<"$region"; then
        echo "the pre-SDD region still contains the SDD half — the split did not happen,"
        echo "and every assertion below would be answered by the gated text"
        return 1
    fi
    local region_bytes
    region_bytes=$(printf '%s' "$region" | wc -c | tr -d ' ')
    if [ "$region_bytes" -lt 2000 ]; then
        echo "  the pre-SDD region is ${region_bytes}B — the headings moved, and every"
        echo "  assertion below would match over an empty string"
        return 1
    fi

    assert_region_carries_session_identity "$region" "the installed CLAUDE.md" || return 1

    # All five harnesses ship this prompt, and omp/opencode are the ones a byte-budget
    # trim would quietly reach for first. The committed outputs carry no BEGIN/END
    # markers — the installer adds those — so they are regioned straight from the file.
    local f
    for f in "$REPO_DIR/examples/claude-code/CLAUDE.md" \
             "$REPO_DIR/examples/pi/AGENTS.md" \
             "$REPO_DIR/examples/codex/agents.md" \
             "$REPO_DIR/examples/opencode/AGENTS.md" \
             "$REPO_DIR/examples/omp/AGENTS.md"; do
        assert_file_exists "$f" || return 1
        local shipped
        shipped="$(pre_sdd_region < "$f")"
        if [ "$(printf '%s' "$shipped" | wc -c | tr -d ' ')" -lt 2000 ]; then
            echo "  ${f##*/examples/}: the pre-SDD region is empty or truncated"
            return 1
        fi
        assert_region_carries_session_identity "$shipped" "${f##*/examples/}" || return 1
    done
    return 0
}


# ===== UNIT-O (issues #93–#96) =====
# The four hook findings from the v6.1.1 risk review. Three were real and are fixed
# here; the fourth (#93) is pinned as the property it claimed was broken, because it
# is not — see test_o_write_guard_reads_file_path_out_of_tool_input_only.
#
# Everything below drives the SHIPPED files under examples/claude-code/hooks/, the
# exact bytes setup.sh copies onto a user's machine, through stdin.
# ============================================================================

# Echo hook $2's exit status over payload $3, through the jq-less farm at $1 when
# $1 is non-empty and the ambient PATH (jq present) when it is empty. $4 is the
# KURAMA_CHANGE the archive gate should assume ("" leaves it unset, which is what
# makes the gate auto-detect).
#
# CLAUDE_PROJECT_DIR is pinned EMPTY rather than left unset: it is the FIRST source
# the hooks consult for the project root, so an ambient value on the developer's or
# CI machine would skip the payload-cwd path entirely. Echoes rather than returns
# because a blocking hook exits 2, which a bare call would turn into an aborted body.
o_hook_status() {
    local bindir="$1" hook="$2" payload="$3" change="${4:-}" status=0
    if [ -n "$bindir" ]; then
        printf '%s' "$payload" | CLAUDE_PROJECT_DIR="" KURAMA_CHANGE="$change" \
            PATH="$bindir" bash "$hook" > /dev/null 2>&1 || status=$?
    else
        printf '%s' "$payload" | CLAUDE_PROJECT_DIR="" KURAMA_CHANGE="$change" \
            bash "$hook" > /dev/null 2>&1 || status=$?
    fi
    printf '%s' "$status"
}

# A PreToolUse Write payload for file $2 in project $1, whose content is $3.
o_write_payload() {
    printf '{"session_id":"s1","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"%s","content":"%s"}}' \
        "$1" "$2" "$3"
}

# A PreToolUse Task payload in project $1: description $2, subagent_type $3, prompt $4.
o_task_payload() {
    printf '{"session_id":"s1","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Task","tool_input":{"description":"%s","subagent_type":"%s","prompt":"%s"}}' \
        "$1" "$2" "$3" "$4"
}

# A PreToolUse Skill payload naming skill $2 with args $3, in project $1.
o_skill_payload_with_args() {
    printf '{"session_id":"s1","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"%s","args":"%s"}}' \
        "$1" "$2" "$3"
}

# Fail unless the write guard reaches verdict $4 over payload $3 under BOTH parsers
# — ambient jq and the jq-less farm at $1. $2 labels the payload in the message.
# The payload is validated as JSON first: an unparseable one makes jq's extractor
# return empty, which decides for the wrong reason and would pass vacuously.
assert_o_guard_verdict_both_parsers() {
    local bindir="$1" label="$2" payload="$3" want="$4"
    if ! printf '%s' "$payload" | jq -e . > /dev/null 2>&1; then
        echo "the '$label' payload is not valid JSON — it would decide for the wrong reason"
        return 1
    fi
    assert_eq "$want" "$(o_hook_status "" "$WRITE_GUARD_HOOK" "$payload")" \
        "with jq: $label" || return 1
    assert_eq "$want" "$(o_hook_status "$bindir" "$WRITE_GUARD_HOOK" "$payload")" \
        "without jq: $label" || return 1
    return 0
}

test_o_write_guard_canonicalizes_before_the_exemption_globs() {
    # #94. The exemption arms are GLOBS over a string, and the string used to be the
    # raw concatenation of the root and whatever file_path said. ".kurama/../src/x"
    # matches "$root"/.kurama/* on the literal bytes and resolves to repository code:
    # the guard exempted precisely the main-thread write to repo code it exists to
    # block, and the same worked through openspec/. The path is now canonicalized —
    # lexically, because a Write CREATES its target and there is nothing on disk to
    # resolve yet — before the case runs.
    command -v jq >/dev/null 2>&1 || { echo "jq is required for the jq half of this case"; return 1; }
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/canon"
    make_active_cycle_repo "$repo"
    mkdir -p "$repo/openspec/changes/add-widget"

    # Non-vacuity: the honest verdicts this case is asserting deviations from.
    assert_o_guard_verdict_both_parsers "$bindir" "honest write to repo code" \
        "$(edit_payload "$repo" "src/widget.ts")" "2" || return 1
    assert_o_guard_verdict_both_parsers "$bindir" "honest write to the .kurama marker" \
        "$(edit_payload "$repo" ".kurama/sdd/add-widget/state.md")" "0" || return 1
    assert_o_guard_verdict_both_parsers "$bindir" "honest write to an openspec artifact" \
        "$(edit_payload "$repo" "openspec/changes/add-widget/design.md")" "0" || return 1

    # The bypass: an exempt prefix followed by "..", in every spelling.
    assert_o_guard_verdict_both_parsers "$bindir" "relative .kurama/.. escape" \
        "$(edit_payload "$repo" ".kurama/../src/widget.ts")" "2" || return 1
    assert_o_guard_verdict_both_parsers "$bindir" "relative openspec/.. escape" \
        "$(edit_payload "$repo" "openspec/../src/widget.ts")" "2" || return 1
    assert_o_guard_verdict_both_parsers "$bindir" "absolute .kurama/.. escape" \
        "$(edit_payload "$repo" "$repo/.kurama/../src/widget.ts")" "2" || return 1
    assert_o_guard_verdict_both_parsers "$bindir" "escape that climbs twice and comes back" \
        "$(edit_payload "$repo" ".kurama/sdd/../../src/widget.ts")" "2" || return 1

    # …and canonicalization must not cost the exemption its OWN noisy spellings.
    # "./" and "." segments are what a model writes without thinking about it, and
    # before the fix they fell through to the guarded arm by accident of the glob.
    assert_o_guard_verdict_both_parsers "$bindir" "dot segments inside an exempt path" \
        "$(edit_payload "$repo" "./.kurama/./sdd/add-widget/state.md")" "0" || return 1
    assert_o_guard_verdict_both_parsers "$bindir" "a path that leaves .kurama and returns" \
        "$(edit_payload "$repo" ".kurama/sdd/../sdd/add-widget/state.md")" "0" || return 1

    # A ".." that climbs clean out of the project is still none of the guard's
    # business — the fix must not turn "outside the repo" into a block.
    assert_o_guard_verdict_both_parsers "$bindir" "a path that leaves the project entirely" \
        "$(edit_payload "$repo" "../elsewhere/notes.md")" "0" || return 1
    return 0
}

test_o_write_guard_resolves_symlinks_before_the_exemption_globs() {
    # #94's other half. Lexical normalization alone still decides on a name: a
    # symlink under .kurama/ keeps the exempt PREFIX while the write lands on
    # repository code, so the longest EXISTING prefix is resolved with `cd -P` +
    # `pwd -P` (macOS has neither `realpath -m` nor `readlink -f`).
    #
    # The root is resolved the same way, and that is not symmetry for its own sake:
    # resolving only the target would make "$root"/* stop matching on any host whose
    # project path crosses a symlink — /tmp -> /private/tmp on macOS, which is where
    # this suite runs — and the guard would fall through to "outside the repo, allow".
    # That is fail-OPEN, so the last assertion below pins it explicitly.
    command -v jq >/dev/null 2>&1 || { echo "jq is required for the jq half of this case"; return 1; }
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/symlink-guard"
    make_active_cycle_repo "$repo"

    # A symlink under the exempt directory pointing back at repository code.
    ln -sfn "$repo/src" "$repo/.kurama/escape"
    assert_o_guard_verdict_both_parsers "$bindir" "symlink under .kurama into repo code" \
        "$(edit_payload "$repo" ".kurama/escape/widget.ts")" "2" || return 1

    # The project reached through a symlinked root: same repo, same file, same
    # verdict. If only one side of the glob were canonical this reads as "outside
    # the repo" and the write is allowed.
    local linkroot="$TEST_TMPDIR/symlink-guard-link"
    ln -sfn "$repo" "$linkroot"
    assert_o_guard_verdict_both_parsers "$bindir" "repo code reached through a symlinked root" \
        "$(edit_payload "$linkroot" "src/widget.ts")" "2" || return 1
    assert_o_guard_verdict_both_parsers "$bindir" "the marker reached through a symlinked root" \
        "$(edit_payload "$linkroot" ".kurama/sdd/add-widget/state.md")" "0" || return 1
    return 0
}

test_o_write_guard_reads_file_path_out_of_tool_input_only() {
    # #93 claimed a payload could spoof file_path by spelling one out inside the
    # Write CONTENT, and proposed swapping the read to json_root_str. Both halves of
    # that are wrong, and this case pins why so the claim is not re-filed:
    #
    #   * content cannot spoof. Every quote inside a JSON string is serialized as
    #     \" , which breaks the "<field>": "value" shape both extractors look for —
    #     asserted below with the issue's own payload, under both parsers.
    #   * json_root_str would read file_path at the ROOT, where it never is (it lives
    #     in tool_input), so it would return empty and the guard would exit 0 on
    #     EVERY write. The last block asserts the field is still read at all.
    #
    # What IS real, and what the fix closed, is a jq/no-jq DISAGREEMENT of exactly
    # the class #70 was opened for: a same-named key in a NESTED object, serialized
    # ahead of the real one, won the textual scan while jq returned the real value.
    # file_path is now read as a direct key of tool_input by both halves.
    command -v jq >/dev/null 2>&1 || { echo "jq is required for the jq half of this case"; return 1; }
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/filepath-anchor"
    make_active_cycle_repo "$repo"

    # Non-vacuity: an honest exempt path IS honoured, so the blocks below are the
    # guard refusing a spoof and not the guard having gone deaf to file_path.
    assert_o_guard_verdict_both_parsers "$bindir" "an honest exempt file_path is honoured" \
        "$(edit_payload "$repo" ".kurama/sdd/add-widget/state.md")" "0" || return 1

    local content_spoof nested_spoof root_decoy edits_decoy
    # The issue's payload: a fake pair inside content, serialized BEFORE the real key.
    content_spoof='{"session_id":"s1","cwd":"'"$repo"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"content":"{\"file_path\": \"'"$repo"'/.kurama/scratch\"}","file_path":"src/widget.ts"}}'
    # A nested OBJECT carrying the key — a real key, not text — ahead of the real one.
    nested_spoof='{"session_id":"s1","cwd":"'"$repo"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"meta":{"file_path":"'"$repo"'/.kurama/scratch"},"file_path":"src/widget.ts"}}'
    # A file_path at the ROOT must not outrank tool_input's, whichever comes first.
    root_decoy='{"file_path":"'"$repo"'/.kurama/scratch","session_id":"s1","cwd":"'"$repo"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"src/widget.ts"}}'
    # …nor may one inside an array element, which is the shape MultiEdit carries.
    edits_decoy='{"session_id":"s1","cwd":"'"$repo"'","hook_event_name":"PreToolUse","tool_name":"MultiEdit","tool_input":{"edits":[{"file_path":"'"$repo"'/.kurama/scratch","old_string":"a","new_string":"b"}],"file_path":"src/widget.ts"}}'

    assert_o_guard_verdict_both_parsers "$bindir" "file_path spelled out inside content" \
        "$content_spoof" "2" || return 1
    assert_o_guard_verdict_both_parsers "$bindir" "file_path in a nested object, serialized first" \
        "$nested_spoof" "2" || return 1
    assert_o_guard_verdict_both_parsers "$bindir" "file_path at the payload root" \
        "$root_decoy" "2" || return 1
    assert_o_guard_verdict_both_parsers "$bindir" "file_path inside an edits[] element" \
        "$edits_decoy" "2" || return 1
    return 0
}

test_o_write_guard_decides_a_large_payload_promptly() {
    # The guard runs on EVERY Edit/Write/MultiEdit, and a Write payload carries the
    # whole file. The no-jq extractor is a segment walk precisely so it stays at C
    # speed; a per-character shell or awk loop would turn a routine write into a
    # multi-minute stall, and the canonicalization added for #94 must not put a
    # per-byte pass back into the payload path (it works on the PATH, not the bytes).
    #
    # The bound is deliberately loose — this is a stall detector, not a benchmark.
    command -v jq >/dev/null 2>&1 || { echo "jq is required for the jq half of this case"; return 1; }
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/bigpayload"
    make_active_cycle_repo "$repo"

    local big
    big="$(head -c 120000 /dev/zero | tr '\0' 'x')"
    [ "${#big}" -ge 120000 ] || { echo "the 120KB content never got built (${#big} bytes)"; return 1; }

    local payload started elapsed
    payload="$(o_write_payload "$repo" "src/widget.ts" "$big")"

    started=$(date +%s)
    assert_eq "2" "$(o_hook_status "" "$WRITE_GUARD_HOOK" "$payload")" \
        "with jq a 120KB Write to repo code must still be blocked" || return 1
    assert_eq "2" "$(o_hook_status "$bindir" "$WRITE_GUARD_HOOK" "$payload")" \
        "without jq a 120KB Write to repo code must still be blocked" || return 1
    elapsed=$(( $(date +%s) - started ))
    if [ "$elapsed" -gt 20 ]; then
        echo "two 120KB payloads took ${elapsed}s — the payload scan is no longer linear"
        return 1
    fi
    return 0
}

test_o_archive_gate_keys_on_the_launch_identity_not_the_payload_text() {
    # #95. The gate decided whether a Task/Skill call was an archive launch with a
    # raw substring test over the WHOLE payload, so any delegation that merely
    # MENTIONED the phase — a prompt quoting the SDD phase list out of CLAUDE.md, a
    # skill argument naming it — entered the gate and, with nothing to archive, was
    # blocked outright. It is now keyed on the invoked identity: tool_input.skill,
    # tool_input.subagent_type, tool_input.description. Free-form prose (prompt,
    # args, content) is deliberately never consulted.
    command -v jq >/dev/null 2>&1 || { echo "jq is required for the jq half of this case"; return 1; }
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/gate-identity"
    make_active_cycle_repo "$repo"

    local quoting args_mention real_skill real_agent real_desc
    quoting="$(o_task_payload "$repo" "Fix the login bug" "general-purpose" \
        "The SDD phases are sdd-explore, sdd-propose, sdd-spec, sdd-design, sdd-tasks, sdd-apply, sdd-verify, sdd-archive. You are running NONE of them: just fix the login bug.")"
    args_mention="$(o_skill_payload_with_args "$repo" "branch-pr" "open the PR before sdd-archive runs")"
    real_skill="$(skill_payload "$repo" sdd-archive)"
    real_agent="$(o_task_payload "$repo" "Close out the change" "sdd-archive" "Archive it.")"
    real_desc="$(o_task_payload "$repo" "run sdd-archive" "general-purpose" "Archive it.")"

    # There is no verify report anywhere, so a launch that reaches the gate BLOCKS.
    # That is what makes the two pass-throughs meaningful rather than vacuous.
    local p
    for p in "$real_skill" "$real_agent" "$real_desc"; do
        assert_eq "2" "$(o_hook_status "" "$ARCHIVE_GATE_HOOK" "$p")" \
            "with jq a real sdd-archive launch must still be gated" || return 1
        assert_eq "2" "$(o_hook_status "$bindir" "$ARCHIVE_GATE_HOOK" "$p")" \
            "without jq a real sdd-archive launch must still be gated" || return 1
    done

    for p in "$quoting" "$args_mention"; do
        assert_eq "0" "$(o_hook_status "" "$ARCHIVE_GATE_HOOK" "$p")" \
            "with jq a launch that only MENTIONS the phase is not the gate's business" || return 1
        assert_eq "0" "$(o_hook_status "$bindir" "$ARCHIVE_GATE_HOOK" "$p")" \
            "without jq a launch that only MENTIONS the phase is not the gate's business" || return 1
    done

    # …and once the change really has a PASS, the real launches open the gate. Without
    # this the case would also pass on a gate that blocks every archive forever.
    write_verify_report "$repo" add-widget "PASS"
    assert_eq "0" "$(o_hook_status "" "$ARCHIVE_GATE_HOOK" "$real_skill")" \
        "a PASS verdict must still open the gate for a real launch" || return 1
    assert_eq "0" "$(o_hook_status "$bindir" "$ARCHIVE_GATE_HOOK" "$real_agent")" \
        "a PASS verdict must still open the gate without jq" || return 1
    return 0
}

test_o_archive_gate_stays_quiet_on_a_repo_with_nothing_to_archive() {
    # The exact shape #95 was filed from: a fresh clone right after sdd-init, where
    # openspec/changes holds only archive/. The detection loop skips archive/, so no
    # change resolved, and every Task/Skill call whose text happened to contain the
    # phase name was blocked with "no verify-report found for change '<unknown>'" —
    # a message describing a situation the caller was not in. Nothing here is an
    # archive launch, so nothing may be blocked.
    local repo="$TEST_TMPDIR/gate-freshclone"
    make_git_repo "$repo"
    mkdir -p "$repo/src" "$repo/openspec/changes/archive"
    : > "$repo/openspec/changes/archive/.gitkeep"
    printf 'x\n' > "$repo/src/app.ts"

    local quoting
    quoting="$(o_task_payload "$repo" "Fix the login bug" "general-purpose" \
        "Phases: sdd-explore through sdd-verify, then sdd-archive. Just fix the login bug.")"
    assert_eq "0" "$(o_hook_status "" "$ARCHIVE_GATE_HOOK" "$quoting")" \
        "a fresh clone must not block an unrelated delegation that names the phase" || return 1

    # A real launch in the same repo still blocks — and now says WHY it could not
    # even name a change, instead of leaving '<unknown>' to be misread as a missing
    # report for a change that exists.
    HOOK_STATUS=0
    run_hook "$ARCHIVE_GATE_HOOK" "$(skill_payload "$repo" sdd-archive)"
    assert_eq "2" "$HOOK_STATUS" "a real archive launch with nothing to archive must still block" || {
        printf '%s\n' "$HOOK_OUT"; return 1; }
    printf '%s\n' "$HOOK_OUT" | grep -q 'No change could be resolved' || {
        echo "the block never explains that no change was found at all:"
        printf '%s\n' "$HOOK_OUT"; return 1; }
    return 0
}

test_o_archive_gate_index_path_cannot_be_pre_empted() {
    # #96 (CWE-377). compute_tree_hash used to mktemp a file, delete it so git would
    # initialize a fresh index at that name, and let git recreate it — which throws
    # away the exclusive-creation guarantee mktemp existed for: any local user who
    # learns the name can create it in the window before git does.
    #
    # The consequence is not the redirected write the report assumed — modern git
    # reads the index first and takes its lock with O_EXCL, so it FAILS instead. It
    # is worse in kind: compute_tree_hash then returns nothing, the content binding
    # degrades to "not computable", and a STALE receipt is archived. The gate that
    # exists to catch an edit-after-PASS silently stops catching it.
    #
    # The race is made deterministic with two PATH shims: mktemp records the name it
    # hands out for a PLAIN call (a `mktemp -d` call passes straight through), and rm
    # plants a symlink at exactly that name right after deleting it — the attacker
    # winning the window, every time. With the index inside a private mktemp -d
    # directory there is no plain mktemp call to observe and no deleted name to
    # re-create, so the binding still computes and the stale receipt still blocks.
    local repo="$TEST_TMPDIR/gate-race"
    make_active_cycle_repo "$repo"
    write_verify_report "$repo" add-widget "PASS" "0000000000000000000000000000000000000000"

    local shim="$TEST_TMPDIR/race-bin" slotf="$TEST_TMPDIR/race-slot" victim="$TEST_TMPDIR/race-victim"
    rm -rf "$shim"; mkdir -p "$shim"
    rm -f "$slotf"
    printf 'the file the attacker points the name at\n' > "$victim"

    local real_mktemp real_rm real_ln
    real_mktemp="$(command -v mktemp)"
    real_rm="$(command -v rm)"
    real_ln="$(command -v ln)"

    cat > "$shim/mktemp" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in -*d*) exec "$real_mktemp" "\$@" ;; esac
done
p="\$("$real_mktemp" "\$@")" || exit 1
printf '%s' "\$p" > "$slotf"
printf '%s\n' "\$p"
EOF
    cat > "$shim/rm" <<EOF
#!/usr/bin/env bash
"$real_rm" "\$@"; rc=\$?
slot=""
[ -f "$slotf" ] && slot="\$(cat "$slotf")"
if [ -n "\$slot" ]; then
  for a in "\$@"; do
    [ "\$a" = "\$slot" ] && "$real_ln" -s "$victim" "\$slot" 2>/dev/null
  done
fi
exit \$rc
EOF
    chmod +x "$shim/mktemp" "$shim/rm"

    local payload
    payload="$(skill_payload "$repo" sdd-archive)"

    # Non-vacuity: with no attacker at all the recorded hash is wrong, so the gate
    # blocks on the stale receipt. That is the verdict the race must not be able to
    # change.
    local status=0
    printf '%s' "$payload" | CLAUDE_PROJECT_DIR="" KURAMA_CHANGE=add-widget \
        bash "$ARCHIVE_GATE_HOOK" > /dev/null 2>&1 || status=$?
    assert_eq "2" "$status" "baseline: a Tree-Hash that does not match the tree must block" || return 1

    status=0
    printf '%s' "$payload" | CLAUDE_PROJECT_DIR="" KURAMA_CHANGE=add-widget \
        PATH="$shim:$PATH" bash "$ARCHIVE_GATE_HOOK" > /dev/null 2>&1 || status=$?
    assert_eq "2" "$status" "a pre-empted throwaway index must not suppress the content binding" || {
        if [ -f "$slotf" ]; then
            echo "  the index name handed out (and then re-creatable): $(cat "$slotf")"
        fi
        return 1; }

    # The shims only fire on a PLAIN mktemp call, so their silence IS the property:
    # the throwaway index name was never handed out to be pre-empted.
    if [ -f "$slotf" ]; then
        echo "compute_tree_hash still takes a plain mktemp path it has to delete first"
        return 1
    fi
    return 0
}

echo -e "${BOLD}UNIT-L (issues #73, #102): session identity — persona, name, sdd-learn${NC}"
run_test "persona absent installs a byte-identical tree" test_l_persona_absent_installs_a_byte_identical_tree
run_test "neutral and absent are the same declared no-op" test_l_neutral_and_absent_are_the_same_declared_no_op
run_test "a set persona reaches conversation only, never artifacts" test_l_persona_reaches_the_orchestrator_conversation_only
run_test "the user's name never lands in a committed file" test_l_user_name_never_lands_in_a_committed_file
run_test "session identity resolves without an SDD cycle (#102)" test_l_session_identity_resolves_without_an_sdd_cycle
run_test "sdd-learn installs by default (optional group)" test_l_sdd_learn_installs_by_default
run_test "sdd-learn is a well-formed, registered skill" test_l_sdd_learn_is_a_well_formed_registered_skill


# ============================================================================
# UNIT-M (issue #104): the brainstorm gate and Kurama's own interview skill
#
# The gap #104 closed: `sdd-new` ran init -> explore -> propose -> gate, so the
# FIRST time a human decided anything was AFTER a proposal existed, with the
# approach already picked by a sub-agent. Kurama also declared a `brainstorming`
# pairing in three places, all of them pointing at SUB-AGENTS — and brainstorming
# is dialogue, which a sub-agent cannot conduct because there is no human on the
# other side of its session. Same shape as #102: the right instruction on the
# wrong layer.
#
# Four properties break silently and are pinned here:
#
#   * The gate must sit BEFORE the explore delegation. A gate that fires after
#     the artifacts are written is not a gate, and a plain grep for its heading
#     cannot tell the difference — so ordering is checked structurally.
#   * `sdd-brainstorm` must never write a spec, code, or a doc under
#     `docs/superpowers/`. That is precisely why superpowers' skill was NOT
#     adopted as the engine: it owns its own artifacts and hands off to
#     `writing-plans`, bypassing `sdd-propose`. Ours inheriting that behavior
#     would recreate the #101 collision from the inside.
#   * The three misplaced declarations must score ZERO. Leaving one behind means
#     a sub-agent still believes it may run a question round.
#   * No `/sdd-brainstorm` command line in any of the five prompts. A command
#     line costs ~100-150 B per prompt and `omp` had 97 B of headroom, so the
#     skill is reached from the gate and by trigger, never by a listed command.
#     That is a budget DECISION, not an omission — it needs a guard or the next
#     person "fixes" it.
# ============================================================================

# Print the 1-based line number of the first line of $2 matching ERE $1, or nothing.
# Ordering assertions use this instead of a whole-file grep: "the gate is somewhere
# in the file" is the exact claim that would survive the gate being moved after the
# explore delegation, which is the regression this section exists to catch.
#
# awk rather than `grep -nE | head -1 | cut`, for the same reason as
# skill_frontmatter_fence_closed above: `head -1` closes the pipe under `grep` as
# soon as the first match lands, and under `set -o pipefail` that SIGPIPE becomes
# the status of a command substitution running under `set -e`.
heading_line() {
    awk -v re="$1" '$0 ~ re { print NR; exit }' "$2" 2>/dev/null
}

# Fail unless heading ERE $2 appears strictly before heading ERE $3 in file $1.
# Both must be found: two missing headings would otherwise compare as "" < "",
# and an empty-vs-empty comparison is the classic vacuous pass.
assert_heading_precedes() {
    local file="$1" first="$2" second="$3" what="$4"
    local a b
    a="$(heading_line "$first" "$file")"
    b="$(heading_line "$second" "$file")"
    if [ -z "$a" ]; then
        echo "  ${file##*/}: no heading matched $first — $what cannot be checked"
        return 1
    fi
    if [ -z "$b" ]; then
        echo "  ${file##*/}: no heading matched $second — $what cannot be checked"
        return 1
    fi
    if [ "$a" -ge "$b" ]; then
        echo "  ${file##*/}: $what — the first heading is at line $a, the second at line $b"
        return 1
    fi
    return 0
}

test_m_sdd_new_gates_before_it_explores() {
    # (a) STRUCTURAL, not a string grep. What would make a grep-based version pass
    # for the wrong reason: the gate text present but relocated below the explore
    # delegation, which is functionally identical to having no gate at all. Line
    # ORDER is the property, so line order is what is compared — and both headings
    # are required to exist before the comparison is trusted.
    local f="$REPO_DIR/skills/sdd-new/SKILL.md"
    assert_file_exists "$f" || return 1
    assert_file_not_empty "$f" 2000 || return 1

    assert_heading_precedes "$f" '^### 1\.5\. Brainstorm gate' '^### 2\. Explore' \
        "the brainstorm gate must run BEFORE the explore delegation" || return 1
    assert_heading_precedes "$f" '^### 2\. Explore' '^### 2\.5\. Approach gate' \
        "the approach gate must come after exploration produced the approaches" || return 1
    assert_heading_precedes "$f" '^### 2\.5\. Approach gate' '^### 3\. Propose' \
        "the approach gate must stop the cycle BEFORE sdd-propose is delegated" || return 1

    # The heading alone is not the gate. Each clause below is a decision #104 took
    # that a heading-only edit would silently drop.
    local flat
    flat="$(flatten_file "$f")"
    assert_matches "$flat" 'gh issue view' \
        "the gate reads the issue BODY before classifying (that is where vague requests come from)" || return 1
    assert_matches "$flat" 'vague' \
        "the gate names the vague classification" || return 1
    assert_matches "$flat" 'auto.{0,120}vague.{0,80}(stops|stop)' \
        "in auto a vague request STOPS at the gate — ambiguity resolves before artifacts are written" || return 1
    assert_matches "$flat" 'sdd-brainstorm/SKILL\.md.{0,40}INLINE' \
        "the gate runs sdd-brainstorm INLINE, not as a sub-agent" || return 1
    assert_matches "$flat" 'sdd/\{change-name\}/brainstorm' \
        "the gate names the ledger's topic key so it can be passed downstream by reference" || return 1
    assert_matches "$flat" '(does not resolve|not resolve).{0,80}(continue|Explore)' \
        "an absent optional module degrades to a note, never a blocked cycle" || return 1
    # The brainstorm round may delegate a real sdd-explore to answer what the code can
    # answer. Step 2 running a second full exploration over the same change would pay
    # twice and produce two approach tables free to disagree.
    assert_matches "$flat" 'do NOT run a second exploration' \
        "step 2 reuses an exploration the brainstorm round already produced" || return 1
    assert_matches "$flat" 'refinement pass' \
        "the alternative to a second full exploration" || return 1
    return 0
}

test_m_brainstorm_never_writes_a_spec_or_a_parallel_artifact() {
    # (b) The skill's whole reason for existing over superpowers' is that its output
    # is an SDD artifact. What would make this pass for the wrong reason: running the
    # negative assertions over a file that does not exist, or over an empty string —
    # both match nothing and read as a pass. The file is size-checked first, and a
    # positive control proves the haystack is really the skill body.
    local f="$REPO_DIR/skills/sdd-brainstorm/SKILL.md"
    assert_file_exists "$f" || return 1
    assert_file_not_empty "$f" 3000 || return 1
    local flat
    flat="$(flatten_file "$f")"

    # Positive control for the haystack itself.
    assert_matches "$flat" 'decision ledger' \
        "the extracted body is really sdd-brainstorm (control for the negatives below)" || return 1

    assert_not_matches "$flat" 'docs/superpowers' \
        "a spec tree parallel to openspec/ — the second source of truth #101 is about" || return 1
    assert_not_matches "$flat" 'writing-plans' \
        "a handoff that bypasses sdd-propose" || return 1
    assert_not_matches "$flat" 'openspec/changes/\{change-name\}/(proposal|design|tasks)\.md' \
        "any change-folder artifact other than brainstorm.md — those belong to their phases" || return 1

    # The prohibitions must be stated, not merely obeyed by omission: this file is a
    # prompt, and a rule it does not carry is a rule the model never sees.
    assert_matches "$flat" 'never (write|produce).{0,120}(code|spec)' \
        "the explicit ban on writing code or a spec" || return 1
    assert_matches "$flat" 'never invoke.{0,40}implementation skill' \
        "the explicit ban on invoking an implementation skill" || return 1
    assert_matches "$flat" 'SDD owns the work lifecycle' \
        "the invariant that the only exit is the SDD pipeline" || return 1
    return 0
}

test_m_brainstorm_carries_its_distinguishing_mechanics() {
    # The bar #104 set is "much better than superpowers' brainstorming for a VAGUE
    # request". Each clause here is one of the differences that bar names; a skill
    # that lost any of them would still install, still lint, and still read fine.
    local f="$REPO_DIR/skills/sdd-brainstorm/SKILL.md"
    assert_file_exists "$f" || return 1
    local flat
    flat="$(flatten_file "$f")"

    # 1. Explore BEFORE the first question — superpowers asks first and explores later.
    assert_matches "$flat" 'never ask the human what the repo can answer' \
        "the explore-instead-of-ask rule" || return 1
    # 2. A ledger with STATE. All four states, or the anti-invention device is partial.
    local st
    for st in resolved open contradicted deferred; do
        assert_matches "$flat" "\`$st\`" "the ledger state \`$st\`" || return 1
    done
    assert_matches "$flat" 'deferred.{0,200}(never|not) (filled in|invented|resolved)' \
        "the rule that a decision nobody made is deferred, never filled in" || return 1
    # 3. Options at a FORK, with a marked recommendation — and an open question left open.
    #    The `.{1,3}` spans the en dash in "2-4" as one CHARACTER in a UTF-8 locale and as
    #    three BYTES under LC_ALL=C, which is what CI runs with. A bare `.` matches only on
    #    the first of those, and would turn this into a silent skip on the machine that
    #    matters most.
    assert_matches "$flat" '2.{1,3}4 concrete options' \
        "2-4 concrete options rather than a generic yes/no" || return 1
    assert_matches "$flat" 'recommended' \
        "the marked recommendation" || return 1
    assert_matches "$flat" 'options only at a real fork' \
        "options belong to forks with trade-offs, not to every question" || return 1
    assert_matches "$flat" 'ask it open' \
        "a genuinely open question is asked open, never turned into a menu" || return 1
    assert_matches "$flat" 'verify a premise before you build on it' \
        "never accept a claim about the codebase without checking it" || return 1
    # 4. Decomposition as the first check.
    assert_matches "$flat" 'decomposition' \
        "the decomposition check" || return 1
    # 5. A readiness test plus a round cap — not relentlessness, and not padding either.
    #    Both halves of the budget rule are pinned: the 3-4 NORM and the 7 CEILING. Keeping
    #    only the ceiling is how "aim for three" quietly becomes "ask seven every time".
    assert_matches "$flat" 'readiness test' \
        "the readiness test that ends the interview" || return 1
    assert_matches "$flat" 'seven questions in one round, STOP' \
        "the hard stop at seven — it stops and asks, it does not merely check in" || return 1
    assert_matches "$flat" 'aim for three or four' \
        "3-4 questions as the NORM, so the cap is not read as a target" || return 1
    assert_matches "$flat" 'ceiling for a tangled request, never the target' \
        "seven stated as a ceiling rather than a quota" || return 1
    assert_matches "$flat" 'cannot name the branch it resolves, do not ask it' \
        "every question must resolve a named ledger branch" || return 1
    # 6. One question per turn, through the harness's own primitive where it exists.
    assert_matches "$flat" 'one question per turn' \
        "the one-question-per-turn rule" || return 1
    assert_matches "$flat" 'AskUserQuestion' \
        "the Claude Code question primitive" || return 1
    assert_matches "$flat" 'OpenCode the .question. tool' \
        "the OpenCode question primitive" || return 1
    # 7. The Language Domain Contract split: questions in the user's language, ledger in English.
    assert_matches "$flat" "user's language.{0,120}neutral English" \
        "questions in the user's language, the ledger in neutral English" || return 1
    # 8. Persisted as its own artifact, in all three modes.
    assert_matches "$flat" 'sdd/\{change-name\}/brainstorm' \
        "the engram topic key" || return 1
    assert_matches "$flat" 'openspec/changes/\{change-name\}/brainstorm\.md' \
        "the openspec path" || return 1
    assert_matches "$flat" 'hybrid.{0,80}both' \
        "the hybrid rule (both stores)" || return 1
    # 9. It runs inline. This is the property that made the old pairing impossible.
    assert_matches "$flat" '(run it inline|Run INLINE)' \
        "the inline-execution rule" || return 1
    assert_matches "$flat" 'never launch it as a sub-agent' \
        "the ban on delegating a dialogue skill" || return 1
    return 0
}

test_m_the_misplaced_pairing_scores_zero() {
    # (c) + (d). The three declarations #104 found, all pointing at sub-agents. What
    # would make this pass for the wrong reason: three greps over three files that do
    # not exist, or over a file whose content changed shape so the pattern could never
    # match anything. Every file is existence- and size-checked, and each one carries a
    # positive control proving the haystack is the real document.
    local explore="$REPO_DIR/skills/sdd-explore/SKILL.md"
    local propose="$REPO_DIR/skills/sdd-propose/SKILL.md"
    local companions="$REPO_DIR/docs/companion-skills.md"
    local f flat
    for f in "$explore" "$propose" "$companions"; do
        assert_file_exists "$f" || return 1
        assert_file_not_empty "$f" 1000 || return 1
    done

    flat="$(flatten_file "$explore")"
    assert_matches "$flat" 'Step 3: Investigate the Codebase' \
        "sdd-explore's real body (control)" || return 1
    assert_not_matches "$flat" 'brainstorming-type skill' \
        "the sub-agent brainstorming pairing in sdd-explore" || return 1
    assert_matches "$flat" 'you are a sub-agent, and there is no user on the other side' \
        "the reason the pairing was removed, stated where it used to live" || return 1

    flat="$(flatten_file "$propose")"
    assert_matches "$flat" 'Change Size' \
        "sdd-propose's real body (control)" || return 1
    assert_not_matches "$flat" 'brainstorming-type skill' \
        "the sub-agent brainstorming pairing in sdd-propose" || return 1

    # (d) The docs table row. The row form is what is banned — the file still DISCUSSES
    # brainstorming, on purpose, so a bare word match would be wrong in both directions.
    flat="$(flatten_file "$companions")"
    assert_matches "$flat" 'systematic-debugging' \
        "the three surviving pairings (control)" || return 1
    # The dots stand in for the row's backticks: a literal backtick inside a
    # single-quoted ERE is what SC2016 flags, and the class is not what is being
    # asserted here anyway — the ROW SHAPE is.
    if grep -qE '^\|[[:space:]]*.brainstorming.[[:space:]]*\|' "$companions"; then
        echo "  docs/companion-skills.md still pairs brainstorming in the table:"
        grep -nE '^\|[[:space:]]*.brainstorming.[[:space:]]*\|' "$companions" | head -2 | awk '{ print "    " $0 }'
        return 1
    fi
    assert_matches "$flat" 'sdd-brainstorm' \
        "the replacement note naming Kurama's own skill" || return 1
    # The other three rows stay — this was a removal of ONE row, not of the table.
    local row
    for row in 'systematic-debugging' 'verification-before-completion' 'receiving-code-review'; do
        grep -qE "^\|[[:space:]]*.$row.[[:space:]]*\|" "$companions" \
            || { echo "  docs/companion-skills.md lost the $row pairing row"; return 1; }
    done
    return 0
}

test_m_no_command_line_and_every_prompt_under_budget() {
    # (e) + (f). One test because they are one decision: the skill is reached from the
    # gate and by trigger rather than by a listed command BECAUSE a command line costs
    # ~100-150 B in each of five prompts and omp had 97 B of headroom.
    #
    # What would make this pass for the wrong reason: a missing or truncated prompt
    # matches no pattern at all, so "no /sdd-brainstorm anywhere" reads as a pass over
    # an empty file. Two guards: every prompt is size-floored, and `/sdd-learn` is
    # asserted PRESENT as a positive control — it is the other optional-group skill and
    # it DOES carry a command line, so the grep provably finds one when there is one.
    local f flat bytes
    for f in "$REPO_DIR/examples/claude-code/CLAUDE.md" \
             "$REPO_DIR/examples/pi/AGENTS.md" \
             "$REPO_DIR/examples/codex/agents.md" \
             "$REPO_DIR/examples/opencode/AGENTS.md" \
             "$REPO_DIR/examples/omp/AGENTS.md"; do
        assert_file_exists "$f" || return 1
        assert_file_not_empty "$f" 15000 || return 1
        flat="$(flatten_file "$f")"

        # Positive control: a command line IS findable by this grep.
        assert_matches "$flat" '/sdd-learn' \
            "${f##*/examples/}: the /sdd-learn command line (control for the ban below)" || return 1
        assert_not_matches "$flat" '/sdd-brainstorm' \
            "${f##*/examples/}: a /sdd-brainstorm command line — the budget decision #104 took" || return 1

        # The one prompt edit the feature was allowed: the human-gate list.
        assert_matches "$flat" 'human gates \(brainstorm,' \
            "${f##*/examples/}: the brainstorm gate in the human-gate list" || return 1
        assert_matches "$flat" 'vague request stops at the brainstorm gate' \
            "${f##*/examples/}: the auto-mode rule that a vague request still stops" || return 1

        bytes=$(wc -c < "$f" | tr -d ' ')
        if [ "$bytes" -gt 24000 ]; then
            echo "  ${f##*/examples/} is ${bytes}B — past the 24KB orchestrator prompt budget"
            return 1
        fi
    done
    return 0
}

test_m_brainstorm_installs_by_default() {
    # `sdd-brainstorm` joins the manifest's `optional` group, which is in setup.sh's
    # default active set — so a plain install ships it with no flag.
    #
    # What would make this pass for the wrong reason: asserting only that the directory
    # exists, which an empty leftover directory satisfies. The file is size-checked and
    # the total is pinned to EXPECTED_SKILLS, so adding the skill without moving the
    # counts cannot slip through.
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    local base="$HOME/.claude/skills"
    assert_dir_exists "$base/sdd-brainstorm" || return 1
    assert_file_exists "$base/sdd-brainstorm/SKILL.md" || return 1
    assert_file_not_empty "$base/sdd-brainstorm/SKILL.md" 3000 || return 1
    assert_eq "${#EXPECTED_SKILLS[@]}" "$(count_skill_files "$base")" \
        "the default set must be exactly the EXPECTED_SKILLS list, sdd-brainstorm included" || return 1
    return 0
}

test_m_brainstorm_is_a_well_formed_registered_skill() {
    # Installed is not the same as loadable: a SKILL.md whose frontmatter fence never
    # closes, or whose name:/description: are empty, is dead weight in every harness.
    # validate_skills.sh is the shipped gate for exactly that, so it is RUN here rather
    # than reimplemented — but running it proves nothing about sdd-brainstorm unless
    # sdd-brainstorm is registered in the manifest it walks, which is asserted first.
    assert_file_exists "$MANIFEST_FILE" || return 1
    grep -q '"sdd-brainstorm"' "$MANIFEST_FILE" \
        || { echo "sdd-brainstorm is not registered in skills/manifest.json — validate_skills.sh never sees it"; return 1; }
    grep -q 'skills/sdd-brainstorm/' "$REPO_DIR/AGENTS.md" \
        || { echo "sdd-brainstorm is missing from the AGENTS.md skill table"; return 1; }

    local src="$REPO_DIR/skills/sdd-brainstorm/SKILL.md"
    assert_file_exists "$src" || return 1
    skill_frontmatter_fence_closed "$src" \
        || { echo "skills/sdd-brainstorm/SKILL.md: the frontmatter fence never closes"; return 1; }
    local fm
    fm="$(skill_frontmatter "$src")"
    printf '%s\n' "$fm" | grep -qE '^name:[[:space:]]*sdd-brainstorm[[:space:]]*$' \
        || { echo "skills/sdd-brainstorm/SKILL.md: frontmatter 'name:' is not sdd-brainstorm"; return 1; }
    printf '%s\n' "$fm" | grep -qE '^description:[[:space:]]*[^[:space:]]' \
        || { echo "skills/sdd-brainstorm/SKILL.md: frontmatter 'description:' is missing or empty"; return 1; }
    # A folded scalar (`description: >`) satisfies the rule above with an empty body,
    # so the continuation has to carry real text of its own.
    if printf '%s\n' "$fm" | grep -qE '^description:[[:space:]]*[>|][-+0-9]*[[:space:]]*$'; then
        printf '%s\n' "$fm" | grep -qE '^[[:space:]]+[^[:space:]]' \
            || { echo "skills/sdd-brainstorm/SKILL.md: 'description:' folds into an empty block"; return 1; }
    fi
    # The description is how every harness routes a natural-language request to this
    # skill. Without the triggers it is installed and unreachable.
    local fm_flat
    fm_flat="$(printf '%s\n' "$fm" | tr '\n' ' ')"
    local trig
    for trig in 'brainstorm' 'grill me' 'stress-test this plan' 'hagamos brainstorming' 'no sé bien qué quiero'; do
        case "$fm_flat" in
            *"$trig"*) ;;
            *) echo "skills/sdd-brainstorm/SKILL.md: the description is missing the \"$trig\" trigger"; return 1 ;;
        esac
    done

    local output status=0
    output=$(bash "$VALIDATE_SCRIPT" 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
        echo "validate_skills.sh exited $status with sdd-brainstorm registered:"
        printf '%s\n' "$output" | grep -a 'FAIL' | head -5
        return 1
    fi
    return 0
}

test_m_the_ledger_is_a_declared_artifact_in_both_conventions() {
    # The ledger is written by the ORCHESTRATOR, inline, which is exactly the kind of
    # writer that drifts away from the convention files nobody made it read. Both
    # convention files are the canonical homes for "where does this artifact live",
    # and `sdd-propose` is the phase that has to find it — so all three are pinned
    # together, against the SAME literal key.
    #
    # What would make this pass for the wrong reason: matching the word "brainstorm"
    # anywhere in a long file. The literal artifact key and the literal path are what
    # is asserted, since only those are what a reader would actually act on.
    local osc="$REPO_DIR/skills/_shared/openspec-convention.md"
    local egc="$REPO_DIR/skills/_shared/engram-convention.md"
    local propose="$REPO_DIR/skills/sdd-propose/SKILL.md"
    local f
    for f in "$osc" "$egc" "$propose"; do
        assert_file_exists "$f" || return 1
        assert_file_not_empty "$f" 1000 || return 1
    done

    grep -qF 'openspec/changes/{change-name}/brainstorm.md' "$osc" \
        || { echo "openspec-convention.md never names the brainstorm.md path"; return 1; }
    grep -qF 'brainstorm.md' "$osc" \
        || { echo "openspec-convention.md's change-folder tree is missing brainstorm.md"; return 1; }
    grep -qE '^\|[[:space:]]*.brainstorm.[[:space:]]*\|[[:space:]]*sdd-brainstorm' "$egc" \
        || { echo "engram-convention.md's artifact-type table is missing the brainstorm type"; return 1; }

    local flat
    flat="$(flatten_file "$propose")"
    assert_matches "$flat" 'sdd/\{change-name\}/brainstorm' \
        "sdd-propose reading the ledger by its topic key" || return 1
    assert_matches "$flat" 'deferred.{0,200}(Risks|Open Questions)' \
        "the rule that a deferred decision becomes a risk / open question" || return 1
    assert_matches "$flat" 'assumed:' \
        "the rule that an unresolved success criterion is written as assumed:" || return 1
    assert_matches "$flat" 'never (silently resolved|promote a .deferred. decision)' \
        "the ban on promoting a deferred decision to resolved" || return 1
    return 0
}

test_m_the_issue_decisions_comment_is_offered_never_automatic() {
    # Mauro's flow is issue-driven: most vague requests arrive as a ticket on a board.
    # Closing that loop is worth a lot — and it is also the one place this skill writes
    # somewhere other people read, so it is the one place an unattended write would be a
    # real incident. `auto` must NOT be an exception: `auto` waives the orchestrator's
    # internal gates, never an outward-facing action.
    #
    # What would make this pass for the wrong reason: matching the word "issue", which a
    # skill this size contains for a dozen unrelated reasons. The offer, the approval, the
    # auto carve-out and the direction of truth are each asserted as their own clause.
    local f="$REPO_DIR/skills/sdd-brainstorm/SKILL.md"
    assert_file_exists "$f" || return 1
    local flat
    flat="$(flatten_file "$f")"

    assert_matches "$flat" 'gh issue comment' \
        "the concrete command that posts the Decisions comment" || return 1
    assert_matches "$flat" 'approval-gated, and it is never automatic' \
        "the comment is offered and approved, never posted on its own" || return 1
    assert_matches "$flat" 'never automatic.{0,40}auto.{0,20}included' \
        "auto does NOT waive the approval — it is an outward-facing write" || return 1
    assert_matches "$flat" 'ticket.{0,200}truth' \
        "the direction of truth: the issue is the ticket, the artifacts are the truth" || return 1
    assert_matches "$flat" 'never an input to a later phase' \
        "a tracker comment never flows back into the pipeline" || return 1
    return 0
}

test_m_sdd_ff_announces_the_bypass() {
    # `sdd-ff` starts at propose: it never explored and now it never brainstorms either.
    # That is a legitimate fast path — the user typing /sdd-ff is asserting they know what
    # they want — but an ACCIDENTAL bypass and an explicit one look identical from the
    # inside, and only the notice tells them apart.
    #
    # What would make this pass for the wrong reason: matching "brainstorm" anywhere in
    # sdd-ff, which the notice's own condition mentions. The assertions below pin the three
    # separable properties instead — the notice text, the escape hatch it names, and the
    # fact that it is a notice rather than a prompt (a question here would break `auto`,
    # which sdd-ff always implies).
    local f="$REPO_DIR/skills/sdd-ff/SKILL.md"
    assert_file_exists "$f" || return 1
    assert_file_not_empty "$f" 2000 || return 1
    local flat
    flat="$(flatten_file "$f")"

    assert_matches "$flat" 'propose .{0,20}\(spec' \
        "sdd-ff's real phase list (control: this is the fast-forward skill)" || return 1
    assert_matches "$flat" 'No exploration or brainstorm exists' \
        "the one-line notice printed when neither artifact exists" || return 1
    assert_matches "$flat" 'Use ./sdd-new' \
        "the notice names /sdd-new as the way to get the gate" || return 1
    assert_matches "$flat" 'notice, not a question' \
        "it never stops the run — sdd-ff always implies auto" || return 1
    assert_matches "$flat" 'When either artifact exists, say nothing' \
        "the notice does not fire when the gate already happened" || return 1
    return 0
}

echo -e "${BOLD}UNIT-M (issue #104): brainstorm gate + sdd-brainstorm${NC}"
run_test "sdd-new gates BEFORE it explores (structural)" test_m_sdd_new_gates_before_it_explores
run_test "sdd-brainstorm never writes a spec or a parallel artifact" test_m_brainstorm_never_writes_a_spec_or_a_parallel_artifact
run_test "sdd-brainstorm carries its distinguishing mechanics" test_m_brainstorm_carries_its_distinguishing_mechanics
run_test "the misplaced brainstorming pairing scores zero" test_m_the_misplaced_pairing_scores_zero
run_test "no /sdd-brainstorm command line; all five prompts under budget" test_m_no_command_line_and_every_prompt_under_budget
run_test "sdd-brainstorm installs by default (optional group)" test_m_brainstorm_installs_by_default
run_test "sdd-brainstorm is a well-formed, registered skill" test_m_brainstorm_is_a_well_formed_registered_skill
run_test "the ledger is a declared artifact in both conventions" test_m_the_ledger_is_a_declared_artifact_in_both_conventions
run_test "the issue Decisions comment is offered, never automatic" test_m_the_issue_decisions_comment_is_offered_never_automatic
run_test "sdd-ff announces the gate it bypasses" test_m_sdd_ff_announces_the_bypass

# ============================================================================
# UNIT-S (issue #88): Work Unit Evidence — mandatory execution evidence in ALL
# modes, with `tdd.enabled` true or false.
#
# The bug: with TDD off (the default) nothing in sdd-apply forced a work unit to
# run anything before being marked `[x]`, so "done" rested on the model's word and
# sdd-verify had nothing to audit. These tests pin the producer side (sdd-apply
# writes the block), the checker side (sdd-verify audits it, WARNING vs CRITICAL),
# and the structural property that makes the whole thing worth having: the gate is
# reachable on the NON-TDD path.
#
# Every content assertion below runs over a size-checked file through flatten_file,
# because each clause is a wrapped markdown bullet or table row: a line-oriented
# match would miss it for a reason that has nothing to do with the contract. All
# patterns are ASCII on purpose — CI runs under LC_ALL=C, where an em dash is three
# bytes rather than one character, so any `.` spanning one is given room to match.
# ============================================================================

test_s_apply_carries_the_evidence_block_in_every_mode() {
    # Wrong-reason pass this guards against: the block present but described as a
    # TDD-mode artifact, which would leave the default path exactly as broken as
    # before. Hence the explicit "EVERY mode / true OR false" and "does not depend
    # on tdd.enabled" clauses, not just the presence of the heading. A second
    # wrong-reason pass — asserting over a missing or truncated file, where every
    # pattern fails and nothing is really checked — is closed by the size check and
    # the positive control first.
    local f="$REPO_DIR/skills/sdd-apply/SKILL.md"
    assert_file_exists "$f" || return 1
    assert_file_not_empty "$f" 9000 || return 1
    local flat
    flat="$(flatten_file "$f")"

    # Positive control: the haystack really is sdd-apply.
    assert_matches "$flat" 'apply-progress' \
        "the extracted body is really sdd-apply (control for the clauses below)" || return 1

    assert_matches "$flat" 'Work Unit Evidence' \
        "the evidence block exists at all" || return 1
    assert_matches "$flat" 'EVERY mode.{0,60}tdd\.enabled.{0,40}true OR false' \
        "the gate runs in every mode with the TDD flag either way" || return 1
    assert_matches "$flat" 'Nothing.{1,8}about this gate depends on .tdd.enabled' \
        "evidence must never be made conditional on the opt-in TDD flag" || return 1

    # The three fields, each pinned by what it must actually contain — a heading
    # named "Test" proves nothing about whether a command and its result are required.
    assert_matches "$flat" 'smallest command that proves THIS unit' \
        "the exact test/check command run for this unit" || return 1
    assert_matches "$flat" 'exit code plus pass/fail counts, or the verbatim last lines' \
        "the exact RESULT, not a summary of it" || return 1
    assert_matches "$flat" 'harness/runtime the unit actually ran under' \
        "the harness/runtime field" || return 1
    assert_matches "$flat" 'rollback boundary' \
        "the rollback boundary field" || return 1
    assert_matches "$flat" 'revert to undo THIS unit and nothing else' \
        "the rollback boundary is scoped to this unit, not to the whole change" || return 1
    assert_matches "$flat" 'commit, the file list, or the migration step' \
        "what a rollback boundary may name" || return 1

    # The N/A rule is the difference between an escape hatch and a loophole.
    assert_matches "$flat" 'N/A. is valid ONLY with a reason' \
        "N/A needs a stated reason" || return 1
    assert_matches "$flat" 'bare .N/A., an empty field, or an omitted line is a GAP' \
        "a bare N/A is a gap, not an answer" || return 1
    assert_matches "$flat" 'Rollback never takes .N/A' \
        "the rollback boundary has no N/A escape at all" || return 1

    assert_matches "$flat" 'Never claim a pass without the command that produced it' \
        "no claimed pass without the command behind it" || return 1
    assert_matches "$flat" 'Never fabricate output' \
        "the ban on inventing a result" || return 1
    assert_matches "$flat" 'Do NOT mark a unit.{0,20}tasks complete when the focused test command' \
        "a failed check blocks the [x] instead of being written under it" || return 1

    # Supplements, never competes.
    assert_matches "$flat" 'SUPPLEMENTS the TDD module' \
        "the block adds to the TDD module rather than replacing it" || return 1
    assert_matches "$flat" 'recorded IN ADDITION' \
        "with TDD on, both the cycle evidence and this block are recorded" || return 1

    # It must land where THIS mode records completion, engram included, and reach the
    # orchestrator through the phase-specific report fields Section D already allows.
    assert_matches "$flat" 'tasks artifact content for .engram' \
        "the engram path for the block, not just tasks.md" || return 1
    assert_matches "$flat" 'Work Unit Evidence\*\* \(ALL modes' \
        "the return envelope's detailed_report carries the evidence field" || return 1
    assert_matches "$flat" 'carried forward VERBATIM' \
        "a later batch never erases an earlier unit's evidence (read-merge-write)" || return 1
    return 0
}

test_s_verify_audits_it_with_the_warning_critical_split() {
    # Wrong-reason pass this guards against: an audit that exists but is capped at
    # WARNING like the TDD audit is, which would let a code-touching unit claim
    # passing tests with no command and still archive. Both severities are pinned,
    # and so is the rule that they must not be collapsed into each other.
    local f="$REPO_DIR/skills/sdd-verify/SKILL.md"
    assert_file_exists "$f" || return 1
    assert_file_not_empty "$f" 20000 || return 1
    local flat
    flat="$(flatten_file "$f")"

    # Positive control: the haystack really is sdd-verify.
    assert_matches "$flat" 'compliance matrix' \
        "the extracted body is really sdd-verify (control for the clauses below)" || return 1

    assert_matches "$flat" 'Work Unit Evidence Audit' \
        "the audit exists at all" || return 1
    assert_matches "$flat" 'ALL modes.{0,20}never conditional' \
        "the audit is never skipped for a mode" || return 1
    assert_matches "$flat" 'independent of .compliance_mode. and of .tdd\.enabled' \
        "neither switch can turn the audit off or reinterpret it" || return 1

    # WARNING is the floor; CRITICAL is reserved for the two unbacked assertions and
    # for a recorded failure sitting under a checked box.
    assert_matches "$flat" 'No Work Unit Evidence block at all [|] \*\*WARNING\*\*' \
        "a checked unit with no evidence block is a WARNING at least" || return 1
    assert_matches "$flat" '\*\*CRITICAL\*\* when the unit touched code' \
        "it escalates to CRITICAL when the unit touched code" || return 1
    assert_matches "$flat" 'claimed pass.{0,120}no command recorded' \
        "a claimed pass with no command is itself a finding" || return 1
    assert_matches "$flat" 'N/A. on Test or Harness with no stated reason [|] \*\*WARNING\*\*' \
        "an unexplained N/A is a WARNING" || return 1
    assert_matches "$flat" 'Rollback boundary missing, or .N/A.{0,40}[|] \*\*WARNING\*\*' \
        "a missing rollback boundary is a WARNING" || return 1
    assert_matches "$flat" 'recorded result is a FAILURE [|] \*\*CRITICAL\*\*' \
        "a recorded failure under an [x] is CRITICAL in both compliance modes" || return 1
    assert_matches "$flat" 'named boundary \(commit, file list' \
        "the audit checks the rollback boundary names something revertible" || return 1
    assert_matches "$flat" 'floor is WARNING' \
        "an unevidenced [x] is never merely a SUGGESTION" || return 1

    # Composition with the TDD module's existing RED-evidence check.
    assert_matches "$flat" 'How this composes with the TDD audit \(Step 6a\)' \
        "the composition with the TDD audit is stated, not left to inference" || return 1
    assert_matches "$flat" 'Both run; neither replaces the other' \
        "both audits run when TDD is on" || return 1
    assert_matches "$flat" 'traceability ON TOP of this block' \
        "TDD adds scenario/test traceability on top rather than substituting" || return 1
    assert_matches "$flat" 'Never.{0,20}downgrade a CRITICAL here to a WARNING' \
        "the TDD audit's WARNING cap must not leak onto this audit" || return 1

    # The report has somewhere to put the finding, or the audit is unreportable.
    assert_matches "$flat" '### Work Unit Evidence Audit' \
        "the verify report template carries an evidence section" || return 1
    return 0
}

test_s_the_gate_is_reachable_with_tdd_off() {
    # (a) STRUCTURAL, not a string grep, and the reason is the bug itself: RED/GREEN
    # evidence already existed, it was just unreachable with tdd.enabled false. Text
    # placed inside the TDD-only branch would satisfy every assertion in the two
    # tests above while changing nothing on the default path. Line ORDER is the
    # property, so line order is what is compared. assert_heading_precedes requires
    # BOTH headings to exist, so a pair of missing headings cannot compare equal and
    # pass vacuously.
    local a="$REPO_DIR/skills/sdd-apply/SKILL.md"
    local v="$REPO_DIR/skills/sdd-verify/SKILL.md"
    assert_file_exists "$a" || return 1
    assert_file_exists "$v" || return 1

    # Step 3a is the TDD branch and Step 3b the standard one; a gate after BOTH and
    # before the "mark complete" step is on every path into Step 4.
    assert_heading_precedes "$a" '^### Step 3a: Implement Tasks' \
        '^### Step 3b: Implement Tasks' \
        "the two implementation branches must both precede the gate" || return 1
    assert_heading_precedes "$a" '^### Step 3b: Implement Tasks' \
        '^### Step 3c: Hard Gate' \
        "the evidence gate must sit outside the TDD branch, after the standard one" || return 1
    assert_heading_precedes "$a" '^### Step 3c: Hard Gate' \
        '^### Step 4: Mark Tasks Complete' \
        "the gate must run BEFORE tasks are marked complete, not after" || return 1

    # Same property on the checker side: the evidence audit is its own step, ahead of
    # (and outside) the tdd.enabled-gated Step 6a that is skipped when TDD is off.
    assert_heading_precedes "$v" '^### Step 2a: Work Unit Evidence Audit' \
        '^### Step 3: Check Correctness' \
        "the evidence audit belongs with the completeness check, not with the TDD audit" || return 1
    assert_heading_precedes "$v" '^### Step 2a: Work Unit Evidence Audit' \
        '^### Step 6a: TDD Audit' \
        "the audit must not be nested inside the step that TDD-off skips entirely" || return 1
    return 0
}

test_s_docs_and_tasks_declare_evidence_always_on() {
    # The producer and the checker can be right while the docs still tell a project
    # that execution evidence arrives with the optional module — which is how the
    # gate gets "simplified away" in a later pass. Wrong-reason pass guarded: the
    # phrase living only inside docs/tdd.md's TDD-on table, where it would read as
    # conditional; the always-on wording is asserted explicitly.
    local d="$REPO_DIR/docs/tdd.md"
    assert_file_exists "$d" || return 1
    assert_file_not_empty "$d" 5000 || return 1
    local flat
    flat="$(flatten_file "$d")"
    assert_matches "$flat" 'Work Unit Evidence is always on' \
        "the docs state the block is always on" || return 1
    assert_matches "$flat" 'Independently of TDD.{1,8}and of .tdd.enabled' \
        "the docs state the block does not depend on the opt-in flag" || return 1
    assert_matches "$flat" 'Enabling TDD.{1,8}never replaces that block' \
        "TDD is opt-in ON TOP of the evidence, not instead of it" || return 1
    assert_matches "$flat" 'Disabling TDD removes.{1,8}the cycle, never the evidence' \
        "turning TDD off leaves the evidence requirement standing" || return 1

    # The planning phase must leave the slot empty: a pre-filled block is the exact
    # unbacked claim the gate exists to stop.
    local t="$REPO_DIR/skills/sdd-tasks/SKILL.md"
    assert_file_exists "$t" || return 1
    assert_file_not_empty "$t" 5000 || return 1
    local tflat
    tflat="$(flatten_file "$t")"
    assert_matches "$tflat" 'Leave the evidence slot empty' \
        "sdd-tasks plans the checklist and leaves the evidence to sdd-apply" || return 1
    assert_matches "$tflat" 'NEVER pre-fill a Work Unit Evidence block' \
        "the rule against a placeholder block in the planned checklist" || return 1
    assert_matches "$tflat" 'evidence .{0,20}sdd-apply. adds later never counts against it' \
        "the 530-word budget covers the plan, not the evidence appended later" || return 1
    return 0
}

test_s_the_tdd_module_rules_are_not_weakened() {
    # The always-on gate had one obvious wrong way to land: relaxing the opt-in
    # module so the two stop overlapping. These are pre-existing invariants, asserted
    # here so this change cannot quietly trade one for the other. They are also the
    # control for the composition claims above — "both run" is only meaningful while
    # the TDD half still says what it always said.
    local a="$REPO_DIR/skills/sdd-apply/SKILL.md"
    local v="$REPO_DIR/skills/sdd-verify/SKILL.md"
    local d="$REPO_DIR/docs/tdd.md"
    local aflat vflat dflat
    aflat="$(flatten_file "$a")"
    vflat="$(flatten_file "$v")"
    dflat="$(flatten_file "$d")"

    assert_matches "$aflat" 'never skip RED' \
        "sdd-apply still forbids skipping the failing test first" || return 1
    assert_matches "$aflat" 'RED.{1,10}GREEN.{1,10}REFACTOR' \
        "sdd-apply still names the full cycle" || return 1
    assert_matches "$vflat" 'test-after detected' \
        "sdd-verify still labels the TDD-process gap" || return 1
    assert_matches "$vflat" 'NEVER CRITICAL' \
        "the TDD audit's findings are still capped at WARNING" || return 1
    assert_matches "$dflat" 'never CRITICAL' \
        "the docs still describe the TDD audit as non-blocking" || return 1
    return 0
}

echo -e "${BOLD}UNIT-S (issue #88): Work Unit Evidence in all modes${NC}"
run_test "sdd-apply carries the Work Unit Evidence block in every mode" test_s_apply_carries_the_evidence_block_in_every_mode
run_test "sdd-verify audits it (WARNING floor, CRITICAL on unbacked code claims)" test_s_verify_audits_it_with_the_warning_critical_split
run_test "the evidence gate is reachable with TDD off (structural)" test_s_the_gate_is_reachable_with_tdd_off
run_test "docs and sdd-tasks declare evidence always-on, TDD opt-in on top" test_s_docs_and_tasks_declare_evidence_always_on
run_test "the opt-in TDD module's rules are not weakened" test_s_the_tdd_module_rules_are_not_weakened

echo ""

echo -e "${BOLD}UNIT-O (issues #93–#96): the two shipped hooks${NC}"
run_test "write guard canonicalizes the path before the exemption globs (#94)" test_o_write_guard_canonicalizes_before_the_exemption_globs
run_test "write guard resolves symlinks on both sides of the globs (#94)" test_o_write_guard_resolves_symlinks_before_the_exemption_globs
run_test "write guard reads file_path out of tool_input only (#93)" test_o_write_guard_reads_file_path_out_of_tool_input_only
run_test "write guard decides a 120KB payload promptly (jq and awk)" test_o_write_guard_decides_a_large_payload_promptly
run_test "archive gate keys on the launch identity, not the payload text (#95)" test_o_archive_gate_keys_on_the_launch_identity_not_the_payload_text
run_test "archive gate stays quiet on a repo with nothing to archive (#95)" test_o_archive_gate_stays_quiet_on_a_repo_with_nothing_to_archive
run_test "archive gate's throwaway index cannot be pre-empted (#96)" test_o_archive_gate_index_path_cannot_be_pre_empted

echo ""

# ============================================================================
# UNIT-T (issue #89): the delta-spec linter and the three skills that run it
#
# Skills are validated mechanically by validate_skills.sh; change artifacts
# never were. A delta spec with a partial MODIFIED block, a scenario without
# GIVEN/WHEN/THEN, a missing RFC 2119 keyword, a leftover placeholder or a
# dangling RENAMED reached sdd-archive, which merges it into openspec/specs/ —
# the source of truth, with sdd-archive as its ONLY writer. #80 fixed the worst
# data-loss case by prose; skills/_shared/lint-spec.sh is the mechanical half.
#
# Every case below asserts the LEVEL line, not just the exit code: a linter that
# exits 1 for the wrong reason is worse than one that exits 0, because it trains
# the reader to stop looking at the message.
# ============================================================================

LINT_SPEC="$REPO_DIR/skills/_shared/lint-spec.sh"

# Write the remaining arguments as lines of the file $1, creating its parents.
# Line-by-line rather than a heredoc so a fixture can be built from a loop (the
# five-scenario baseline) with the same helper as a literal one.
t_write() {
    local f="$1"; shift
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$@" > "$f"
}

# Run the linter, leaving its combined output in T_OUT and its status in
# T_STATUS. errexit is disarmed only around the call — a non-zero exit IS the
# subject of most of these tests.
t_lint() {
    local status=0
    set +e
    T_OUT=$(bash "$LINT_SPEC" "$@" 2>&1)
    status=$?
    set -e
    T_STATUS=$status
}

# Case-SENSITIVE finding assertion. assert_matches is grep -Ei, which cannot
# tell an `ERROR:` level from the word "error" inside a message — and the level
# is precisely what sdd-verify and sdd-archive branch on.
t_assert_line() {
    local out="$1" pattern="$2" what="$3"
    if printf '%s\n' "$out" | grep -Eq "$pattern"; then
        return 0
    fi
    echo "  no finding line matched: $what"
    echo "    (pattern: $pattern)"
    echo "    the linter said:"
    printf '%s\n' "$out" | awk '{ print "      " $0 }'
    return 1
}

t_assert_no_line() {
    local out="$1" pattern="$2" what="$3"
    if printf '%s\n' "$out" | grep -Eq "$pattern"; then
        echo "  the linter must NOT have reported: $what"
        printf '%s\n' "$out" | grep -En "$pattern" | head -3 | awk '{ print "    " $0 }'
        return 1
    fi
    return 0
}

# A structurally perfect delta: all four sections, RFC 2119 keywords, stable
# unique IDs, full GIVEN/WHEN/THEN, reasons on REMOVED, both names on RENAMED.
# Every negative fixture below is this file with ONE property broken, so a test
# that fails is pointing at that property and not at fixture noise.
t_write_clean_delta() {
    t_write "$1" \
        '# Delta for Auth' \
        '' \
        '## ADDED Requirements' \
        '' \
        '### Requirement: Session Expiration' \
        '' \
        'The system MUST expire a session after 30 minutes of inactivity.' \
        '' \
        '#### Scenario: [S-session-1] Idle session expires' \
        '' \
        '- GIVEN a session idle for 30 minutes' \
        '- WHEN the user issues any request' \
        '- THEN the request is rejected with 401' \
        '' \
        '#### Scenario: [S-session-2] Active session survives' \
        '' \
        '- GIVEN a session with activity in the last minute' \
        '- WHEN the user issues any request' \
        '- THEN the request is served' \
        '' \
        '## REMOVED Requirements' \
        '' \
        '### Requirement: Legacy Cookie Auth' \
        '' \
        '(Reason: replaced by bearer tokens)' \
        '(Migration: clients send the Authorization header)' \
        '' \
        '## RENAMED Requirements' \
        '' \
        '### Requirement: Login Flow -> Sign-in Flow' \
        '' \
        '(Reason: matches the product vocabulary)' \
        '(Migration: None)'
}

# The five-scenario baseline the #80 case is measured against.
t_write_baseline_main_spec() {
    local f="$1" n
    mkdir -p "$(dirname "$f")"
    {
        printf '%s\n' '# Auth Specification' '' '## Purpose' '' \
            'Authentication behaviour.' '' '## Requirements' '' \
            '### Requirement: Session Expiration' '' \
            'The system MUST expire a session after 30 minutes of inactivity.' ''
        for n in 1 2 3 4 5; do
            printf '#### Scenario: [S-session-%s] Case %s\n\n' "$n" "$n"
            printf -- '- GIVEN a precondition %s\n' "$n"
            printf -- '- WHEN an action %s\n' "$n"
            printf -- '- THEN an outcome %s\n\n' "$n"
        done
    } > "$f"
}

test_t_the_linter_ships_and_is_a_well_formed_shell_script() {
    # It lives in _shared because that is the directory every install already
    # copies and every skill already references. Shipping it under scripts/
    # would put it somewhere the installed harness cannot reach at all.
    assert_file_exists "$LINT_SPEC" || return 1
    assert_file_not_empty "$LINT_SPEC" 2000 || return 1
    head -n 1 "$LINT_SPEC" | grep -q '^#!.*bash' \
        || { echo "lint-spec.sh has no bash shebang"; return 1; }

    if command -v shellcheck > /dev/null 2>&1; then
        local out status=0
        set +e
        out=$(shellcheck "$LINT_SPEC" 2>&1)
        status=$?
        set -e
        if [ "$status" -ne 0 ]; then
            echo "shellcheck rejected skills/_shared/lint-spec.sh:"
            printf '%s\n' "$out" | head -20 | awk '{ print "    " $0 }'
            return 1
        fi
    fi
    return 0
}

test_t_the_linter_is_portable_bash_3_2() {
    # It runs on USER machines, where bash is whatever the OS shipped — 3.2 on
    # macOS — and where rg/fd/jq are not assumed to exist (#13). A bash-4-only
    # construct here fails on exactly the platform the harness ships to most.
    #
    # Scanned with full-line comments blanked out (line numbers preserved): the
    # script's own header DOCUMENTS the ban by naming mapfile and ${var,,}, and
    # a checker that cannot tell a banned construct from a note about it forces
    # the next author to delete the explanation to get green.
    local code="$TEST_TMPDIR/lint-spec.code"
    sed 's|^[[:space:]]*#.*$||' "$LINT_SPEC" > "$code"
    grep -Eq 'lint_file|structural_pass' "$code" \
        || { echo "the comment-stripped copy lost the script body — the scan below would pass vacuously"; return 1; }

    local banned
    for banned in 'mapfile' 'readarray' 'declare -A' 'local -A' '\$\{[A-Za-z_][A-Za-z0-9_]*,,' '\$\{[A-Za-z_][A-Za-z0-9_]*\^\^'; do
        if grep -Eq "$banned" "$code"; then
            echo "lint-spec.sh uses a bash-4-only construct ($banned):"
            grep -En "$banned" "$code" | head -3 | awk '{ print "    " $0 }'
            return 1
        fi
    done
    # Dependency ban: the shipped script may only reach for the POSIX toolbox.
    local dep
    for dep in '(^|[^-[:alnum:]_/])rg ' '(^|[^-[:alnum:]_/])fd ' '(^|[^-[:alnum:]_/])jq '; do
        if grep -Eq "$dep" "$code"; then
            echo "lint-spec.sh reaches for a non-POSIX dependency ($dep):"
            grep -En "$dep" "$code" | head -3 | awk '{ print "    " $0 }'
            return 1
        fi
    done

    # And it actually runs with bash's POSIX behaviour armed, over a real spec —
    # a grep for banned words cannot prove that, and --help alone would exit
    # before touching awk, sort or the temp files.
    local spec="$TEST_TMPDIR/posix/spec.md"
    t_write_clean_delta "$spec"
    local status=0
    set +e
    bash --posix "$LINT_SPEC" "$spec" > /dev/null 2>&1
    status=$?
    set -e
    assert_eq "0" "$status" "bash --posix could not run the linter over a clean spec" || return 1
    return 0
}

test_t_a_clean_delta_is_silent_and_exits_zero() {
    # The control for every case below: if this fixture ever reports something,
    # the negative tests are proving nothing about the property they name.
    local spec="$TEST_TMPDIR/clean/spec.md"
    t_write_clean_delta "$spec"
    t_lint "$spec"
    assert_eq "0" "$T_STATUS" "a structurally clean delta must exit 0" || return 1
    if [ -n "$T_OUT" ]; then
        echo "  a clean delta must produce NO output; got:"
        printf '%s\n' "$T_OUT" | awk '{ print "    " $0 }'
        return 1
    fi
    return 0
}

test_t_an_unknown_delta_section_is_an_error() {
    # openspec-convention.md -> Delta Spec Sections defines exactly four. A fifth
    # merges as nothing at all: sdd-archive has no branch for it, so every
    # requirement underneath is silently dropped on the floor.
    local spec="$TEST_TMPDIR/section/spec.md"
    t_write "$spec" \
        '# Delta for Auth' \
        '' \
        '## ADDED Requirements' \
        '' \
        '### Requirement: Session Expiration' \
        '' \
        'The system MUST expire a session.' \
        '' \
        '#### Scenario: [S-session-1] Idle session expires' \
        '' \
        '- GIVEN an idle session' \
        '- WHEN the user issues a request' \
        '- THEN the request is rejected' \
        '' \
        '## DELETED Requirements' \
        '' \
        '### Requirement: Old Thing' \
        '' \
        '(Reason: gone)'
    t_lint "$spec"
    assert_eq "1" "$T_STATUS" "an unknown delta section must exit 1" || return 1
    t_assert_line "$T_OUT" ':15: ERROR: unknown delta section .## DELETED Requirements.' \
        "the DELETED section named on its own line, as an ERROR" || return 1
    t_assert_line "$T_OUT" 'ADDED / MODIFIED / REMOVED / RENAMED' \
        "the finding naming the canonical set" || return 1
    return 0
}

test_t_a_requirement_without_an_rfc_2119_keyword_is_an_error() {
    # "Use RFC 2119 keywords" is a rules.specs line in every generated
    # config.yaml and a Rules bullet in sdd-spec. Without one, requirement
    # STRENGTH is unstated, and sdd-verify's compliance matrix — which treats a
    # MUST scenario without a passing test as CRITICAL — has nothing to grade.
    local spec="$TEST_TMPDIR/rfc/spec.md"
    t_write "$spec" \
        '# Delta for Auth' \
        '' \
        '## ADDED Requirements' \
        '' \
        '### Requirement: Session Expiration' \
        '' \
        'The system expires a session after a while.' \
        '' \
        '#### Scenario: [S-session-1] Idle session expires' \
        '' \
        '- GIVEN an idle session' \
        '- WHEN the user issues a request' \
        '- THEN the request is rejected'
    t_lint "$spec"
    assert_eq "1" "$T_STATUS" "a requirement with no RFC 2119 keyword must exit 1" || return 1
    t_assert_line "$T_OUT" ':5: ERROR: requirement .Session Expiration. states no RFC 2119 keyword' \
        "the requirement named at its own heading line, as an ERROR" || return 1
    return 0
}

test_t_a_requirement_without_a_scenario_is_an_error() {
    # sdd-spec: "Every requirement MUST have at least ONE scenario". A
    # requirement with none is untestable by construction — sdd-verify can only
    # build a compliance matrix out of scenarios.
    local spec="$TEST_TMPDIR/noscen/spec.md"
    t_write "$spec" \
        '# Delta for Auth' \
        '' \
        '## ADDED Requirements' \
        '' \
        '### Requirement: Session Expiration' \
        '' \
        'The system MUST expire a session after 30 minutes.'
    t_lint "$spec"
    assert_eq "1" "$T_STATUS" "a requirement with no scenario must exit 1" || return 1
    t_assert_line "$T_OUT" ':5: ERROR: requirement .Session Expiration. carries no .#### Scenario:. block' \
        "the scenario-less requirement, as an ERROR" || return 1
    return 0
}

test_t_a_scenario_missing_given_when_then_is_an_error() {
    # The finding must name WHICH of the three is missing: "malformed scenario"
    # sends the author back to read the whole block, and the whole point of a
    # mechanical check is that it already knows.
    local spec="$TEST_TMPDIR/gwt/spec.md"
    t_write "$spec" \
        '# Delta for Auth' \
        '' \
        '## ADDED Requirements' \
        '' \
        '### Requirement: Session Expiration' \
        '' \
        'The system MUST expire a session.' \
        '' \
        '#### Scenario: [S-session-1] Idle session expires' \
        '' \
        '- GIVEN an idle session' \
        '- THEN the request is rejected'
    t_lint "$spec"
    assert_eq "1" "$T_STATUS" "a scenario without WHEN must exit 1" || return 1
    t_assert_line "$T_OUT" ':9: ERROR: scenario .*is missing WHEN' \
        "the missing keyword named explicitly, as an ERROR" || return 1
    t_assert_no_line "$T_OUT" 'is missing GIVEN' \
        "GIVEN as missing — it is present in the fixture" || return 1
    return 0
}

test_t_malformed_and_duplicate_scenario_ids_are_errors() {
    # IDs are STABLE for the life of the requirement: sdd-tasks and sdd-verify
    # reference them, and the TDD audit looks for them inside test names. A
    # duplicate makes every one of those references ambiguous.
    local spec="$TEST_TMPDIR/ids/spec.md"
    t_write "$spec" \
        '# Delta for Auth' \
        '' \
        '## ADDED Requirements' \
        '' \
        '### Requirement: Session Expiration' \
        '' \
        'The system MUST expire a session.' \
        '' \
        '#### Scenario: [S-session-1] Idle session expires' \
        '' \
        '- GIVEN an idle session' \
        '- WHEN the user issues a request' \
        '- THEN the request is rejected' \
        '' \
        '#### Scenario: [S-session-1] Active session survives' \
        '' \
        '- GIVEN an active session' \
        '- WHEN the user issues a request' \
        '- THEN the request is served' \
        '' \
        '#### Scenario: [SESSION9] Expired token is refused' \
        '' \
        '- GIVEN an expired token' \
        '- WHEN the user issues a request' \
        '- THEN the request is rejected'
    t_lint "$spec"
    assert_eq "1" "$T_STATUS" "duplicate and malformed IDs must exit 1" || return 1
    t_assert_line "$T_OUT" ':15: ERROR: duplicate scenario ID .\[S-session-1\]. - already used on line 9' \
        "the duplicate ID, naming BOTH lines, as an ERROR" || return 1
    t_assert_line "$T_OUT" ':21: ERROR: malformed scenario ID .\[SESSION9\]' \
        "the malformed ID, as an ERROR" || return 1
    return 0
}

test_t_a_partial_modified_block_names_the_baseline_count() {
    # THE #80 case, made mechanical. A five-scenario requirement whose author
    # pastes only the scenario they edited archives as a one-scenario
    # requirement: sdd-archive replaces the whole matching block and cannot tell
    # a deliberate deletion from an incomplete paste. The finding has to name
    # the baseline count, because that number is the whole argument.
    local proj="$TEST_TMPDIR/proj"
    t_write_baseline_main_spec "$proj/openspec/specs/auth/spec.md"
    local delta="$proj/openspec/changes/add-mfa/specs/auth/spec.md"
    t_write "$delta" \
        '# Delta for Auth' \
        '' \
        '## MODIFIED Requirements' \
        '' \
        '### Requirement: Session Expiration' \
        '' \
        'The system MUST expire a session after 15 minutes of inactivity.' \
        '(Previously: the timeout was 30 minutes)' \
        '' \
        '#### Scenario: [S-session-3] Case 3' \
        '' \
        '- GIVEN a precondition 3' \
        '- WHEN an action 3' \
        '- THEN an outcome 3'

    # The baseline itself must be clean, or the assertions below are measuring
    # a broken fixture rather than the delta.
    t_lint "$proj/openspec/specs/auth/spec.md"
    assert_eq "0" "$T_STATUS" "the five-scenario baseline fixture must itself lint clean" || return 1

    t_lint "$delta"
    assert_eq "1" "$T_STATUS" "a MODIFIED block that drops scenarios must exit 1" || return 1
    t_assert_line "$T_OUT" ':5: ERROR: MODIFIED requirement .Session Expiration. carries 1 scenario' \
        "the partial MODIFIED block, as an ERROR at the requirement heading" || return 1
    t_assert_line "$T_OUT" 'currently has 5' \
        "the baseline count named in the finding" || return 1
    t_assert_line "$T_OUT" '4 scenario\(s\) would be DELETED' \
        "the consequence stated as a count of losses" || return 1

    # Control 1: the SAME delta carrying the full block is clean. Without this,
    # the test above would also pass for a linter that rejects every MODIFIED.
    local full="$proj/openspec/changes/add-mfa/specs/auth/spec.md"
    {
        printf '%s\n' '# Delta for Auth' '' '## MODIFIED Requirements' '' \
            '### Requirement: Session Expiration' '' \
            'The system MUST expire a session after 15 minutes of inactivity.' \
            '(Previously: the timeout was 30 minutes)' ''
        local n
        for n in 1 2 3 4 5; do
            printf '#### Scenario: [S-session-%s] Case %s\n\n' "$n" "$n"
            printf -- '- GIVEN a precondition %s\n' "$n"
            printf -- '- WHEN an action %s\n' "$n"
            printf -- '- THEN an outcome %s\n\n' "$n"
        done
    } > "$full"
    t_lint "$full"
    assert_eq "0" "$T_STATUS" "a MODIFIED block carrying the FULL baseline must lint clean" || return 1

    # Control 2: with no baseline to compare against, the check is SKIPPED, not
    # guessed. Inventing a loss against an absent main spec would make the
    # linter unusable on a first cycle, where every domain is an empty baseline.
    t_write "$delta" \
        '# Delta for Auth' \
        '' \
        '## MODIFIED Requirements' \
        '' \
        '### Requirement: Session Expiration' \
        '' \
        'The system MUST expire a session after 15 minutes of inactivity.' \
        '' \
        '#### Scenario: [S-session-3] Case 3' \
        '' \
        '- GIVEN a precondition 3' \
        '- WHEN an action 3' \
        '- THEN an outcome 3'
    mkdir -p "$TEST_TMPDIR/empty-specs"
    t_lint --specs "$TEST_TMPDIR/empty-specs" "$delta"
    assert_eq "0" "$T_STATUS" "with no baseline in the main-spec tree the MODIFIED check must be skipped" || return 1
    return 0
}

test_t_a_renamed_entry_must_name_both_requirements() {
    # A RENAMED entry rewrites a heading in place and KEEPS the scenarios. With
    # only one name the merger has nothing to match on — and modelling the
    # rename as REMOVED + ADDED instead discards the scenario history and every
    # stable ID downstream phases hold.
    local spec="$TEST_TMPDIR/renamed/spec.md"
    t_write "$spec" \
        '# Delta for Auth' \
        '' \
        '## RENAMED Requirements' \
        '' \
        '### Requirement: Login Flow' \
        '' \
        '(Reason: matches the product vocabulary)'
    t_lint "$spec"
    assert_eq "1" "$T_STATUS" "a one-sided RENAMED entry must exit 1" || return 1
    t_assert_line "$T_OUT" ':5: ERROR: RENAMED requirement .Login Flow. names only one requirement' \
        "the dangling rename, as an ERROR" || return 1
    return 0
}

test_t_placeholders_error_and_open_markers_warn() {
    # Template braces are an ERROR because they mean the writer shipped the
    # TEMPLATE; TBD/TODO/XXX are a WARNING because they are a real sentence with
    # an open question in it. The two levels are the whole distinction.
    local spec="$TEST_TMPDIR/placeholder/spec.md"
    t_write "$spec" \
        '# Delta for Auth' \
        '' \
        '## ADDED Requirements' \
        '' \
        '### Requirement: {Requirement Name}' \
        '' \
        'The system MUST reject a request when the token is TBD.' \
        '' \
        '#### Scenario: [S-session-1] Idle session expires' \
        '' \
        '- GIVEN an idle session' \
        '- WHEN the user issues a request' \
        '- THEN the request is rejected'
    t_lint "$spec"
    assert_eq "1" "$T_STATUS" "a spec with leftover placeholders must exit 1" || return 1
    t_assert_line "$T_OUT" ':5: ERROR: unfilled template placeholder \{Requirement Name\}' \
        "the unreplaced template brace, as an ERROR" || return 1
    t_assert_line "$T_OUT" ':7: WARNING: placeholder marker \(TBD / TODO / XXX\)' \
        "the open marker, as a WARNING and not an ERROR" || return 1
    return 0
}

test_t_a_removed_entry_without_a_reason_is_an_error() {
    # A REMOVED block deletes a requirement from the source of truth, and the
    # reason is the only record of WHY once the requirement itself is gone.
    # openspec-convention.md -> Delta Spec Sections says the delta MUST carry
    # `(Reason: ...)`, so this is an ERROR: the canonical contract decides the
    # level, not how survivable the omission feels. Downgrading it here would
    # make the linter and the convention disagree about the same sentence.
    local spec="$TEST_TMPDIR/removed/spec.md"
    t_write "$spec" \
        '# Delta for Auth' \
        '' \
        '## REMOVED Requirements' \
        '' \
        '### Requirement: Legacy Cookie Auth' \
        '' \
        '(Migration: clients send the Authorization header)'
    t_lint "$spec"
    assert_eq "1" "$T_STATUS" "a reasonless REMOVED entry must exit 1" || return 1
    t_assert_line "$T_OUT" ':5: ERROR: REMOVED requirement .Legacy Cookie Auth. carries no' \
        "the reasonless removal, as an ERROR (the convention says MUST)" || return 1
    t_assert_no_line "$T_OUT" ': WARNING:' \
        "a WARNING — that was the pre-convention level and must not come back" || return 1
    return 0
}

test_t_a_change_directory_argument_lints_its_domain_specs() {
    # The three skills call it with the CHANGE directory, not a file: a change
    # can span several domains, and asking each caller to enumerate them is how
    # a domain gets skipped. The narrow expansion (specs/ or spec.md) is also
    # what keeps proposal.md — which carries `## Design (inline)` on the small
    # path — from being linted as a delta spec.
    local change="$TEST_TMPDIR/changes/add-mfa"
    t_write "$change/proposal.md" \
        '# Proposal' '' '## Design (inline)' '' 'Not a delta spec section.'
    t_write_clean_delta "$change/specs/auth/spec.md"
    t_write "$change/specs/billing/spec.md" \
        '# Delta for Billing' \
        '' \
        '## ADDED Requirements' \
        '' \
        '### Requirement: Invoice Export' \
        '' \
        'The system MUST export an invoice as PDF.' \
        '' \
        '#### Scenario: [S-invoice-1] Export succeeds' \
        '' \
        '- GIVEN a settled invoice' \
        '- THEN a PDF is produced'
    # A domain file that is NOT named spec.md. The convention is
    # {domain}/spec.md, but a flat specs/{domain}.md is the obvious drift, and a
    # spec the linter silently skips is indistinguishable from a spec that
    # passed — so the specs/ path component has to be enough on its own.
    t_write "$change/specs/reporting.md" \
        '# Delta for Reporting' \
        '' \
        '## ADDED Requirements' \
        '' \
        '### Requirement: Weekly Digest' \
        '' \
        'The digest is sent on Mondays.'

    t_lint "$change"
    assert_eq "1" "$T_STATUS" "a change dir with broken domains must exit 1" || return 1
    t_assert_line "$T_OUT" 'specs/billing/spec\.md:9: ERROR: scenario .*is missing WHEN' \
        "the finding attributed to the billing domain file ({domain}/spec.md)" || return 1
    t_assert_line "$T_OUT" 'specs/reporting\.md:5: ERROR: requirement .Weekly Digest. states no RFC 2119' \
        "the finding attributed to the flat specs/{domain}.md file" || return 1
    t_assert_no_line "$T_OUT" 'specs/auth/spec\.md' \
        "any finding against the clean auth domain" || return 1
    t_assert_no_line "$T_OUT" 'proposal\.md' \
        "a finding against proposal.md — it is not a delta spec" || return 1
    return 0
}

test_t_usage_errors_exit_two_and_never_report_a_pass() {
    # Exit 2 is reserved for "the linter did not run". Collapsing it into 0
    # would make a typo in a skill's invocation read as a clean spec — the same
    # fail-open class as #41, in the one script whose whole job is to be trusted.
    local status=0
    set +e
    bash "$LINT_SPEC" > /dev/null 2>&1
    status=$?
    set -e
    assert_eq "2" "$status" "no arguments must exit 2" || return 1

    set +e
    bash "$LINT_SPEC" "$TEST_TMPDIR/does-not-exist.md" > /dev/null 2>&1
    status=$?
    set -e
    assert_eq "2" "$status" "a missing path must exit 2, never 0" || return 1

    mkdir -p "$TEST_TMPDIR/no-specs-here"
    set +e
    bash "$LINT_SPEC" "$TEST_TMPDIR/no-specs-here" > /dev/null 2>&1
    status=$?
    set -e
    assert_eq "2" "$status" "a directory holding no spec files must exit 2, never a silent 0" || return 1

    set +e
    bash "$LINT_SPEC" --help > /dev/null 2>&1
    status=$?
    set -e
    assert_eq "0" "$status" "--help must exit 0" || return 1
    return 0
}

test_t_kuramas_own_delta_specs_lint_clean() {
    # Dogfood: the repo's own change artifacts are the only delta specs in the
    # tree that nobody wrote for this test. If the linter cannot pass them, its
    # rules are stricter than the convention it claims to enforce.
    local changes="$REPO_DIR/openspec/changes"
    [ -d "$changes" ] || return 0
    local found=0 d status=0
    for d in "$changes"/*/; do
        [ -d "${d}specs" ] || continue
        found=1
        set +e
        local out
        out=$(bash "$LINT_SPEC" "${d}specs" 2>&1)
        status=$?
        set -e
        if [ "$status" -ne 0 ]; then
            echo "the linter rejects Kurama's own delta spec ${d}specs:"
            printf '%s\n' "$out" | head -10 | awk '{ print "    " $0 }'
            return 1
        fi
    done
    assert_eq "1" "$found" "no openspec change with a specs/ directory was found to dogfood against" || return 1
    return 0
}

test_t_sdd_spec_lints_its_own_output_before_persisting() {
    # The writer is the cheapest place to catch a structural defect: it still
    # has the baseline it read in Step 3 and the intent it was given. Catching
    # the same defect at archive time costs a blocked cycle.
    local f="$REPO_DIR/skills/sdd-spec/SKILL.md"
    assert_file_exists "$f" || return 1
    local flat
    flat="$(flatten_file "$f")"

    assert_matches "$flat" '_shared/lint-spec\.sh' \
        "sdd-spec naming the linter by its _shared home" || return 1
    assert_matches "$flat" 'Step 4b' \
        "the lint step sitting before Step 5 (persist)" || return 1
    assert_matches "$flat" 'fail-loud existence check' \
        "the #41 rule: resolve the script with test -f, never a finder" || return 1
    assert_matches "$flat" '\[ -f skills/_shared/lint-spec\.sh \]' \
        "the concrete test -f probe, not a bare invocation" || return 1
    assert_matches "$flat" 'status: blocked' \
        "the blocked envelope for findings it cannot resolve" || return 1
    assert_matches "$flat" 'NEVER report a lint pass you did not run' \
        "the ban on claiming a clean lint when the script is absent" || return 1
    return 0
}

test_t_sdd_verify_gates_on_the_linter_at_critical() {
    # sdd-verify is the quality gate, and CRITICAL is the level sdd-archive
    # refuses on. Reporting lint ERRORs as WARNINGs would let every structural
    # defect through the one phase whose job is to stop them.
    local f="$REPO_DIR/skills/sdd-verify/SKILL.md"
    assert_file_exists "$f" || return 1
    local flat
    flat="$(flatten_file "$f")"

    assert_matches "$flat" '_shared/lint-spec\.sh' \
        "sdd-verify naming the linter by its _shared home" || return 1
    assert_matches "$flat" '\[ -f skills/_shared/lint-spec\.sh \]' \
        "the test -f probe (#41 fail-loud)" || return 1
    assert_matches "$flat" 'Every .ERROR:. line is a CRITICAL issue' \
        "the ERROR -> CRITICAL mapping stated as a rule" || return 1
    assert_matches "$flat" 'WARNING:. line is a WARNING' \
        "WARNING findings staying non-blocking" || return 1
    assert_matches "$flat" 'NEVER report a lint pass you did not run' \
        "the ban on a silent pass when the script is absent" || return 1
    return 0
}

test_t_sdd_archive_refuses_to_merge_a_spec_with_errors() {
    # sdd-archive is the ONLY writer of openspec/specs/. A refusal here is the
    # last mechanical stop before a malformed requirement becomes the source of
    # truth — and in engram mode there is no git history to recover it from.
    local f="$REPO_DIR/skills/sdd-archive/SKILL.md"
    assert_file_exists "$f" || return 1
    local flat
    flat="$(flatten_file "$f")"

    assert_matches "$flat" '_shared/lint-spec\.sh' \
        "sdd-archive naming the linter by its _shared home" || return 1
    assert_matches "$flat" '\[ -f skills/_shared/lint-spec\.sh \]' \
        "the test -f probe (#41 fail-loud)" || return 1
    assert_matches "$flat" 'Step 1a' \
        "the gate as a numbered step ahead of Step 2 (the merge), not a passing remark" || return 1
    assert_matches "$flat" 'An .ERROR:. line REFUSES the merge' \
        "the refusal, in sdd-archive's own refusal idiom" || return 1
    assert_matches "$flat" 'next_recommended: sdd-spec' \
        "the refusal routing back to the phase that can fix it" || return 1
    assert_matches "$flat" 'Do NOT merge the clean domains and skip the broken one' \
        "the ban on a partial merge around the refusal" || return 1
    assert_matches "$flat" 'BEFORE any merge' \
        "the gate running before anything is written" || return 1
    return 0
}

test_t_the_linter_wiring_is_new_on_this_branch() {
    # Mutation guard for the four assertions above: they pass trivially if the
    # phrases were already in the skills. origin/main is the baseline, and it
    # must carry ZERO hits.
    if ! git -C "$REPO_DIR" rev-parse --verify --quiet origin/main > /dev/null 2>&1; then
        # Shallow CI checkout with no baseline ref. The presence half still
        # holds; only the "this is new" half is unverifiable here.
        return 0
    fi
    local skill hits
    for skill in skills/sdd-spec/SKILL.md skills/sdd-verify/SKILL.md skills/sdd-archive/SKILL.md; do
        hits=$(git -C "$REPO_DIR" show "origin/main:$skill" 2>/dev/null | grep -c 'lint-spec\.sh' || true)
        hits=$(printf '%s' "$hits" | tr -d ' ')
        if [ "${hits:-0}" -ne 0 ]; then
            echo "origin/main:$skill already mentions lint-spec.sh ($hits hits) — the wiring assertions prove nothing"
            return 1
        fi
    done
    if git -C "$REPO_DIR" cat-file -e origin/main:skills/_shared/lint-spec.sh 2>/dev/null; then
        echo "origin/main already ships skills/_shared/lint-spec.sh"
        return 1
    fi
    return 0
}

test_t_the_tree_hash_index_lives_in_a_private_temp_dir() {
    # CWE-377. Both Content Binding blocks used to do `tmp_index="$(mktemp)"; rm -f
    # "$tmp_index"` — mktemp a file, then UNLINK it so git can create its own index at
    # that path. Between the rm and git's create, the name is unowned and world-writable
    # in /tmp: anyone can plant a file there. The value being computed is the receipt
    # that decides whether a PASS still binds to the code — the single number
    # sdd-archive and archive-gate.sh gate on — so it is the last hash in the pipeline
    # that should be computable by someone else. `mktemp -d` hands out a 0700 directory
    # and the index is born inside it, never at a name that existed unowned.
    #
    # The pathspec is deliberately NOT part of this change: sdd-verify Step 6b,
    # sdd-archive Step 0 and the archive-gate hook must keep hashing the same tree, and
    # it is asserted unchanged below.
    local f
    for f in "$REPO_DIR/skills/sdd-verify/SKILL.md" "$REPO_DIR/skills/sdd-archive/SKILL.md"; do
        assert_file_exists "$f" || return 1
        local flat
        flat="$(flatten_file "$f")"
        assert_not_matches "$flat" 'mktemp\)"; rm -f' \
            "${f##*/skills/}: the unlink-then-let-git-recreate temp index (CWE-377)" || return 1
        assert_matches "$flat" 'tmp_dir="\$\(mktemp -d\)"' \
            "${f##*/skills/}: the private temp DIRECTORY that replaces it" || return 1
        # shellcheck disable=SC2016  # matching the literal $tmp_dir as written in the skill
        assert_matches "$flat" 'GIT_INDEX_FILE="\$tmp_dir/index"' \
            "${f##*/skills/}: the index living inside that directory" || return 1
        # The hash itself must not have moved: same pathspec, same exclusions.
        assert_matches "$flat" "git add -A -- \. ':\(exclude\)openspec' ':\(exclude\)\.kurama'" \
            "${f##*/skills/}: the pathspec, byte-identical across all three computations" || return 1
    done
    return 0
}

test_t_the_docs_point_at_the_linter() {
    # docs/concepts.md is where delta-spec structure is documented for a human.
    # A mechanical gate nobody knows about gets worked around rather than fixed.
    local f="$REPO_DIR/docs/concepts.md"
    assert_file_exists "$f" || return 1
    local flat
    flat="$(flatten_file "$f")"
    assert_matches "$flat" 'skills/_shared/lint-spec\.sh' \
        "docs/concepts.md naming the linter and its path" || return 1
    assert_matches "$flat" 'file:line: LEVEL: message' \
        "the finding format a reader will see" || return 1
    assert_matches "$flat" 'fewer scenarios than the same requirement' \
        "the MODIFIED whole-block check documented as the motivating case" || return 1
    return 0
}

echo -e "${BOLD}UNIT-T (issue #89): delta-spec linter + the skills that run it${NC}"
run_test "lint-spec.sh ships in _shared and is shellcheck-clean" test_t_the_linter_ships_and_is_a_well_formed_shell_script
run_test "lint-spec.sh is portable bash 3.2 (no bash-4, no rg/fd/jq)" test_t_the_linter_is_portable_bash_3_2
run_test "a clean delta is silent and exits 0" test_t_a_clean_delta_is_silent_and_exits_zero
run_test "an unknown delta section is an ERROR" test_t_an_unknown_delta_section_is_an_error
run_test "a requirement with no RFC 2119 keyword is an ERROR" test_t_a_requirement_without_an_rfc_2119_keyword_is_an_error
run_test "a requirement with no scenario is an ERROR" test_t_a_requirement_without_a_scenario_is_an_error
run_test "a scenario missing GIVEN/WHEN/THEN is an ERROR" test_t_a_scenario_missing_given_when_then_is_an_error
run_test "malformed and duplicate scenario IDs are ERRORs" test_t_malformed_and_duplicate_scenario_ids_are_errors
run_test "a partial MODIFIED block names the baseline count (#80)" test_t_a_partial_modified_block_names_the_baseline_count
run_test "a RENAMED entry must name both requirements" test_t_a_renamed_entry_must_name_both_requirements
run_test "template braces ERROR, TBD/TODO/XXX WARN" test_t_placeholders_error_and_open_markers_warn
run_test "a REMOVED entry with no reason is an ERROR" test_t_a_removed_entry_without_a_reason_is_an_error
run_test "a change-directory argument lints its domain specs" test_t_a_change_directory_argument_lints_its_domain_specs
run_test "usage errors exit 2 and never report a pass" test_t_usage_errors_exit_two_and_never_report_a_pass
run_test "Kurama's own delta specs lint clean (dogfood)" test_t_kuramas_own_delta_specs_lint_clean
run_test "sdd-spec lints its own output before persisting" test_t_sdd_spec_lints_its_own_output_before_persisting
run_test "sdd-verify gates on the linter at CRITICAL" test_t_sdd_verify_gates_on_the_linter_at_critical
run_test "sdd-archive refuses to merge a spec with ERRORs" test_t_sdd_archive_refuses_to_merge_a_spec_with_errors
run_test "the linter wiring is new on this branch (origin/main clean)" test_t_the_linter_wiring_is_new_on_this_branch
run_test "the Tree-Hash index lives in a private temp dir (CWE-377)" test_t_the_tree_hash_index_lives_in_a_private_temp_dir
run_test "docs/concepts.md points at the linter" test_t_the_docs_point_at_the_linter

echo ""

# ============================================================================
# UNIT-N (issue #99) — the assertion helpers themselves
#
# assert_matches is shared by every contract case in this file, so a flake in it
# is a flake in all of them. It read `printf '%s\n' "$haystack" | grep -Eqi`:
# grep -q exits on its FIRST match and closes the pipe, and once the haystack is
# larger than the kernel's pipe buffer printf is still writing when that happens.
# printf dies of SIGPIPE (141), `set -o pipefail` makes 141 the pipeline's status,
# and the helper reports "nothing matched" over text that matched on line 1. That
# is what turned PR #98 — VERSION, two manifests and a changelog — red on macOS
# while Ubuntu passed, and it pointed the reader at a content regression that did
# not exist. The helpers now read their haystack from a herestring: no writer
# process exists for grep's early exit to signal.
# ============================================================================

# Build a haystack of at least $1 bytes whose FIRST line is $2 and whose filler
# can never match it. The filler doubles, so 64KB is ten concatenations.
build_oversized_haystack() { # bytes first_line
    local want="$1" first="$2"
    local filler='padding line that carries no sentinel and never matches the pattern'
    while [ "${#filler}" -lt "$want" ]; do
        filler="$filler"$'\n'"$filler"
    done
    printf '%s\n%s' "$first" "$filler"
}

test_n_assert_matches_survives_a_haystack_larger_than_the_pipe_buffer() {
    # What would make this pass for the wrong reason:
    #
    #   * A haystack that fits in the pipe buffer (16KB on macOS, 64KB on Linux).
    #     printf's whole write lands in the buffer and returns before grep -q can
    #     exit, so the OLD code passes too and the case proves nothing. The size is
    #     therefore asserted at >= 64KB before the loop, not assumed.
    #   * A match near the END of the haystack. grep -q would then have consumed
    #     the entire stream before exiting, so there is no early close and no
    #     SIGPIPE — again green on the broken helper. The sentinel is pinned to
    #     line 1, and that placement is asserted.
    #   * One iteration. The bug is a race between two processes: the broken helper
    #     passed most of the time and failed on a minority of macOS runs. A single
    #     green run is not evidence, so the assertion runs 20 times.
    #   * A pattern that cannot fail. If the sentinel also appeared in the filler,
    #     or if assert_matches returned 0 unconditionally, the loop would be
    #     vacuous. Both are ruled out first: the filler alone must NOT match, and
    #     assert_matches must return 1 for a pattern that is genuinely absent.
    local sentinel='kurama-sigpipe-sentinel-99'
    local haystack
    haystack="$(build_oversized_haystack 65536 "$sentinel")"

    local bytes
    bytes=$(printf '%s' "$haystack" | wc -c | tr -d ' ')
    if [ "$bytes" -lt 65536 ]; then
        echo "  the haystack is ${bytes}B — under the pipe buffer, where the broken"
        echo "  helper passes as well and this case proves nothing"
        return 1
    fi

    local first_line
    first_line="$(head -1 <<<"$haystack")"
    if [ "$first_line" != "$sentinel" ]; then
        echo "  the sentinel is not on line 1 — grep would drain the whole stream"
        echo "  before exiting, and the early close this case exists for never happens"
        return 1
    fi

    # Negative control: the filler must not answer for the sentinel.
    local filler
    filler="$(tail -n +2 <<<"$haystack")"
    if grep -Eqi "$sentinel" <<<"$filler"; then
        echo "  the filler already carries the sentinel — the match below is not the"
        echo "  first line's"
        return 1
    fi

    # Positive control: the helper must still be able to say no.
    local out status
    set +e
    out="$(assert_matches "$haystack" 'sentinel-that-is-nowhere-in-the-haystack' 'a pattern that is absent' 2>&1)"
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        echo "  assert_matches returned 0 for a pattern absent from the haystack —"
        echo "  every assertion in this file is unfailable"
        return 1
    fi

    # The regression itself: 20 consecutive runs, each of which the piped helper
    # could lose to SIGPIPE.
    local i
    for ((i = 1; i <= 20; i++)); do
        assert_matches "$haystack" "$sentinel" \
            "the first line of a ${bytes}B haystack (run $i/20)" || {
            echo "  assert_matches lost a match on line 1 of a ${bytes}B haystack —"
            echo "  the pipe is back in the helper (#99)"
            return 1
        }
    done

    # assert_not_matches takes the same early exit, and its evidence line is the
    # other half: `grep -Ein ... | head -3` SIGPIPEs grep itself.
    for ((i = 1; i <= 20; i++)); do
        set +e
        out="$(assert_not_matches "$haystack" "$sentinel" 'the sentinel' 2>&1)"
        status=$?
        set -e
        if [ "$status" -eq 0 ]; then
            echo "  assert_not_matches missed a match on line 1 of a ${bytes}B haystack"
            echo "  (run $i/20) — the pipe is back in the helper (#99)"
            return 1
        fi
        case "$out" in
            *"$sentinel"*) : ;;
            *)
                echo "  assert_not_matches failed without quoting the offending line"
                echo "  (run $i/20) — its evidence pipeline died before printing:"
                printf '    %s\n' "$out"
                return 1
                ;;
        esac
    done
    return 0
}

echo -e "${BOLD}UNIT-N (issue #99): the assertion helpers themselves${NC}"
run_test "assert_matches survives a haystack larger than the pipe buffer" test_n_assert_matches_survives_a_haystack_larger_than_the_pipe_buffer

echo ""

# ============================================================================
# UNIT-U (issue #106): the skill registry is a script, not a sub-agent
#
# `.kurama/skill-registry.md` is the ONLY surface a delegation resolves
# `## Project Standards (skills to load)` from — no registry and every phase runs
# blind to the repo's conventions (skill-resolver.md, step 4). It was built by a
# sub-agent: measured at 12-13 minutes and 44,954 bytes in a real repo, 63% of it
# hand-written per-skill summaries that PR #82 had already demoted to an opt-in
# fallback. It is now skills/_shared/build-skill-registry.sh — index only, no
# model in the loop.
#
# That moved three things at once, and each is a case below:
#
#   1. THE SCAN. One level deep, `find -L` so a symlinked skill dir resolves and
#      a nested fixture two levels down does NOT get indexed; `_shared`,
#      `skill-registry` and `sdd-*` excluded; frontmatter `name` + `description`
#      only, CRLF and `> | |- >-` block scalars handled; dedupe by name with
#      project scope winning; sorted. Asserted as EXACT table rows, because the
#      fifteen consumers of this file parse that shape.
#
#   2. THE INSTALL PATH. install_skills copied `_shared/*.md` and nothing else,
#      so a shipped .sh could not travel. The glob is `*.md` AND `*.sh` now
#      (generic on purpose — #89's lint-spec.sh rides the same path), the
#      executable bit is set explicitly, and every copied file is recorded in the
#      receipt like the .md ones so uninstall removes it and doctor checks it.
#
#   3. THE PROSE. sdd-init Step 4 and the skill-registry skill re-listed the
#      eleven scan directories and told the model to glob them. Upstream kept
#      exactly that as a "fallback" and the two lists have already drifted apart.
#      Both now run the script and neither carries a directory list — there is no
#      fallback scan at all.
#
# Most of this runs under the jq-less farm: the receipt grew entries a jq-less
# uninstall drives `rm` from, and the awk fallback parser is the one no
# developer's Mac ever executes — which is how the single-line-empty-array bug
# shipped (#13).
#
# NOTE on controls. Like UNIT-L and UNIT-P, nothing here reads git history:
# .github/workflows/pr-check.yml checks out at depth 1, so `origin/main` is not a
# ref on CI and a history-based control would fail there or degrade to a vacuous
# skip. Every case asserts the new behaviour directly, which is absent on main by
# construction — verified by hand against `git show origin/main:`, where
# skills/sdd-init/SKILL.md has 2 hits and skills/skill-registry/SKILL.md 6 hits
# of the forbidden directory-list/glob/compact-rules patterns, both name the
# builder ZERO times, and skills/_shared/build-skill-registry.sh does not exist.
# ============================================================================

BUILD_REGISTRY_SCRIPT="$REPO_DIR/skills/_shared/build-skill-registry.sh"

# Write a one-skill fixture: $1/SKILL.md with `name: $2` and `description: $3`.
u_make_skill() {
    local dir="$1" nm="$2" desc="$3"
    mkdir -p "$dir"
    printf -- '---\nname: %s\ndescription: "%s"\n---\n\nbody\n' "$nm" "$desc" > "$dir/SKILL.md"
}

# The fixture tree every scan case shares. Builds under $1 (a fresh dir):
#
#   home/.claude/skills/  alpha        folded `>` scalar + a nested metadata: block
#                         crlf-skill   every line CRLF-terminated
#                         linked       a SYMLINK to a skill dir outside the tree
#                         bundle/inner a SKILL.md TWO levels down — must not index
#                         _shared      excluded by name
#                         skill-registry, sdd-init, sdd-new   excluded by name
#                         dup          also present project-level: project wins
#   proj/.claude/skills/  bare         no frontmatter at all: name falls back
#                         dup          the copy that must win
#   proj/.codex/skills/   pipe         a `|` in the description, which would
#                                      otherwise break the markdown table
#   proj/AGENTS.md        an index referencing one existing and one missing .md
#
# HOME is already $TEST_TMPDIR/home (see setup()), so "home/" here IS $HOME.
u_make_fixture() {
    local w="$1"
    local h="$w/home" p="$w/proj"
    mkdir -p "$h/.claude/skills" "$p/.claude/skills" "$p/.codex/skills"
    make_git_repo "$p"

    mkdir -p "$h/.claude/skills/alpha"
    cat > "$h/.claude/skills/alpha/SKILL.md" <<'ALPHA'
---
name: alpha
description: >
  Does alpha things across the codebase.
  Trigger: When user says "alpha" or edits *.al files.
license: MIT
metadata:
  author: someone
  version: "1.0"
---
body
ALPHA

    mkdir -p "$h/.claude/skills/crlf-skill"
    printf -- '---\r\nname: crlf-skill\r\ndescription: "Handles CRLF. Trigger: on windows files"\r\n---\r\nbody\r\n' \
        > "$h/.claude/skills/crlf-skill/SKILL.md"

    mkdir -p "$w/elsewhere/linked"
    cat > "$w/elsewhere/linked/SKILL.md" <<'LINKED'
---
name: linked
description: |
  A skill reached through a symlink.
  Trigger: whenever symlinks matter
---
LINKED
    ln -s "$w/elsewhere/linked" "$h/.claude/skills/linked"

    # Two levels down: a bundle's own source copy. Indexing it turns one skill
    # into two rows and the delegator then picks between them arbitrarily.
    u_make_skill "$h/.claude/skills/bundle/inner" nested-should-not-appear "nope"

    local d
    for d in _shared skill-registry sdd-init sdd-new; do
        u_make_skill "$h/.claude/skills/$d" "$d" "excluded"
    done

    u_make_skill "$h/.claude/skills/dup" dup "USER copy. Trigger: user"
    u_make_skill "$p/.claude/skills/dup" dup "PROJECT copy. Trigger: project"

    # No frontmatter at all: the name falls back to the directory name.
    mkdir -p "$p/.claude/skills/bare"
    printf 'just a body\n' > "$p/.claude/skills/bare/SKILL.md"

    u_make_skill "$p/.codex/skills/pipe" pipe "Has a | pipe. Trigger: a|b table breaker"

    cat > "$p/AGENTS.md" <<'CONV'
# Agents
See [conventions](docs/conv.md) and `docs/other.md` and [missing](docs/nope.md).
CONV
    mkdir -p "$p/docs"
    : > "$p/docs/conv.md"
    : > "$p/docs/other.md"
}

# The data rows of the `## User Skills` table in the registry at $1 — header and
# separator dropped, so a caller can compare them to an exact expected block.
u_registry_rows() {
    awk '
        /^## User Skills/ { inside = 1; next }
        /^## / { inside = 0 }
        inside && /^\| Trigger \|/ { next }
        inside && /^\|[- |]*\|$/ { next }
        inside && /^\|/ { print }
    ' "$1"
}

# Same, for the `## Project Conventions` table.
u_convention_rows() {
    awk '
        /^## Project Conventions/ { inside = 1; next }
        /^## / { inside = 0 }
        inside && /^\| File \|/ { next }
        inside && /^\|[- |]*\|$/ { next }
        inside && /^\|/ { print }
    ' "$1"
}

test_u_scan_indexes_the_fixture_tree_exactly() {
    local w="$TEST_TMPDIR"
    u_make_fixture "$w"
    local p="$w/proj" h="$w/home"

    local out status=0
    out=$(bash "$BUILD_REGISTRY_SCRIPT" --root "$p" 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
        echo "builder exited $status: $out"
        return 1
    fi

    assert_file_exists "$p/.kurama/skill-registry.md" || return 1

    # Every claim of this section in one block: the folded `>` scalar is read and
    # its Trigger: extracted, the CRLF file parses, the symlinked dir resolves,
    # the nested fixture is absent, `_shared`/`skill-registry`/`sdd-*` are absent,
    # the project `dup` wins over the user one, `bare` falls back to its directory
    # name with an em dash for the missing trigger, the pipe is escaped, and the
    # whole thing is sorted by name.
    local expected actual
    expected="| When user says \"alpha\" or edits *.al files. | alpha | $h/.claude/skills/alpha/SKILL.md |
| — | bare | $p/.claude/skills/bare/SKILL.md |
| on windows files | crlf-skill | $h/.claude/skills/crlf-skill/SKILL.md |
| project | dup | $p/.claude/skills/dup/SKILL.md |
| whenever symlinks matter | linked | $h/.claude/skills/linked/SKILL.md |
| a\\|b table breaker | pipe | $p/.codex/skills/pipe/SKILL.md |"
    actual="$(u_registry_rows "$p/.kurama/skill-registry.md")"
    if [ "$expected" != "$actual" ]; then
        echo "  the index table is not what the scan must produce."
        echo "  expected:"; printf '%s\n' "$expected" | awk '{ print "    " $0 }'
        echo "  actual:"; printf '%s\n' "$actual" | awk '{ print "    " $0 }'
        return 1
    fi

    # The summary line is what setup/update/sdd-init report to the user.
    assert_matches "$out" '^skill-registry: 6 skills \(3 user, 3 project\)' \
        "the one-line summary with the split counts" || return 1

    # The index file AND the .md paths it references THAT EXIST — docs/nope.md is
    # referenced and absent, so it must not appear.
    expected="| AGENTS.md | AGENTS.md | Index — references the files below |
| conv.md | docs/conv.md | Referenced by AGENTS.md |
| other.md | docs/other.md | Referenced by AGENTS.md |"
    actual="$(u_convention_rows "$p/.kurama/skill-registry.md")"
    if [ "$expected" != "$actual" ]; then
        echo "  the Project Conventions table is wrong."
        echo "  expected:"; printf '%s\n' "$expected" | awk '{ print "    " $0 }'
        echo "  actual:"; printf '%s\n' "$actual" | awk '{ print "    " $0 }'
        return 1
    fi
    return 0
}

test_u_registry_is_an_index_with_no_compact_rules() {
    local w="$TEST_TMPDIR"
    u_make_fixture "$w"
    bash "$BUILD_REGISTRY_SCRIPT" --root "$w/proj" >/dev/null 2>&1 \
        || { echo "builder exited non-zero"; return 1; }

    local body
    body="$(cat "$w/proj/.kurama/skill-registry.md")"

    # THE point of #106. 63% of the old 45 KB was per-skill summaries the
    # resolver only reaches for when the budget is tight; the script writes none,
    # and nothing may reintroduce them without this failing.
    assert_not_matches "$body" 'Compact Rules' \
        "a Compact Rules section — the registry is an index, by construction" || return 1

    # The shape the fifteen consumers parse, unchanged.
    assert_matches "$body" '^## User Skills$' "the User Skills heading" || return 1
    assert_matches "$body" '^\| Trigger \| Skill \| Path \|$' "the index table header" || return 1
    assert_matches "$body" '^## Project Conventions$' "the Project Conventions heading" || return 1
    return 0
}

test_u_second_run_is_byte_identical_and_leaves_no_temp() {
    local w="$TEST_TMPDIR"
    u_make_fixture "$w"
    local reg="$w/proj/.kurama/skill-registry.md"

    bash "$BUILD_REGISTRY_SCRIPT" --root "$w/proj" >/dev/null 2>&1 || { echo "first run failed"; return 1; }
    cp "$reg" "$w/first.md"
    bash "$BUILD_REGISTRY_SCRIPT" --root "$w/proj" >/dev/null 2>&1 || { echo "second run failed"; return 1; }

    if ! cmp -s "$w/first.md" "$reg"; then
        echo "  a second run rewrote the registry — it is not idempotent:"
        diff "$w/first.md" "$reg" | head -10 | awk '{ print "    " $0 }'
        return 1
    fi

    # The write is temp + mv precisely so a hook reading the file mid-refresh
    # never sees half of it. A leftover .tmp is the proof the rename was skipped.
    local leftovers
    leftovers="$(count_matching_files "$w/proj/.kurama" '*.tmp*')"
    if [ "$leftovers" != "0" ]; then
        echo "  $leftovers temp file(s) left in .kurama/ — the write was not atomic"
        return 1
    fi
    return 0
}

test_u_root_guard_refuses_home_and_filesystem_root() {
    local w="$TEST_TMPDIR"
    u_make_fixture "$w"

    # $HOME: what a cwd-relative default does the one time somebody runs this
    # from the wrong shell. It must refuse, say why, and exit 0 — the callers run
    # it opportunistically and must not abort an install over it.
    local out status=0
    out=$(bash "$BUILD_REGISTRY_SCRIPT" --root "$HOME" 2>&1) || status=$?
    assert_eq "0" "$status" "a refused root is exit 0, never a failure" || return 1
    assert_matches "$out" 'not a project root' "the refusal, in words" || return 1
    if [ -e "$HOME/.kurama" ]; then
        echo "  the builder created $HOME/.kurama — the home-directory guard did not hold"
        return 1
    fi

    # The filesystem root, same contract. Never written to on any machine that
    # runs this suite, hence the existence check rather than a content one.
    status=0
    out=$(bash "$BUILD_REGISTRY_SCRIPT" --root / 2>&1) || status=$?
    assert_eq "0" "$status" "/ is refused with exit 0" || return 1
    assert_matches "$out" 'not a project root' "the refusal for /" || return 1
    if [ -e "/.kurama" ]; then
        echo "  the builder created /.kurama — the filesystem-root guard did not hold"
        return 1
    fi

    # A directory with no project marker at all: same refusal.
    mkdir -p "$w/nomarker"
    status=0
    out=$(bash "$BUILD_REGISTRY_SCRIPT" --root "$w/nomarker" 2>&1) || status=$?
    assert_eq "0" "$status" "an unmarked directory is refused with exit 0" || return 1
    if [ -e "$w/nomarker/.kurama" ]; then
        echo "  the builder wrote into a directory with no .git, .kurama/ or skills dir"
        return 1
    fi

    # --quiet is what a caller passes when a refusal must not print at all.
    status=0
    out=$(bash "$BUILD_REGISTRY_SCRIPT" --root "$HOME" --quiet 2>&1) || status=$?
    assert_eq "0" "$status" "--quiet still exits 0 on a refusal" || return 1
    if [ -n "$out" ]; then
        echo "  --quiet printed on a refusal: $out"
        return 1
    fi
    return 0
}

test_u_build_finishes_in_seconds_not_minutes() {
    local w="$TEST_TMPDIR"
    u_make_fixture "$w"
    # Bulk the tree up past any real machine's per-directory count, so the
    # measurement is about the scan and not about six fixture files.
    local i
    for i in $(seq 1 60); do
        u_make_skill "$HOME/.claude/skills/bulk-$i" "bulk-$i" "Bulk skill $i. Trigger: bulk $i"
    done

    local start end elapsed
    start=$(date +%s)
    bash "$BUILD_REGISTRY_SCRIPT" --root "$w/proj" >/dev/null 2>&1 || { echo "builder failed"; return 1; }
    end=$(date +%s)
    elapsed=$((end - start))

    # Deliberately generous: the point is seconds versus the 12-13 minutes the
    # sub-agent took, not a benchmark.
    if [ "$elapsed" -gt 2 ]; then
        echo "  the scan took ${elapsed}s for 66 skills — it must be under 2s"
        return 1
    fi
    # A timing case that measured a build which never happened would be worse
    # than no case at all.
    assert_file_exists "$w/proj/.kurama/skill-registry.md" || return 1
    local rows
    rows="$(u_registry_rows "$w/proj/.kurama/skill-registry.md" | awk 'END { print NR + 0 }')"
    assert_eq "66" "$rows" "the timed run indexed every skill" || return 1
    return 0
}

test_u_clone_copy_does_not_index_kuramas_own_sources() {
    local w="$TEST_TMPDIR"
    u_make_fixture "$w"

    # setup.sh and update.sh run the builder FROM THE CLONE. skills/ there holds
    # sources, including groups a default install excludes (`lang`/go-testing) —
    # indexing them advertises skills the project does not have, at paths inside
    # somebody else's checkout. skills/manifest.json sits beside _shared/ in the
    # clone and never travels to an install, which is the distinction the script
    # keys on.
    bash "$BUILD_REGISTRY_SCRIPT" --root "$w/proj" >/dev/null 2>&1 || { echo "builder failed"; return 1; }
    local body
    body="$(cat "$w/proj/.kurama/skill-registry.md")"
    assert_not_matches "$body" "$REPO_DIR/skills/" \
        "a path into the Kurama clone's own sources" || return 1

    # The catch-all still fires for a REAL install: the builder placed in a
    # skills dir with no manifest.json beside it indexes that dir's siblings,
    # which is how a nonstandard harness target is covered at all.
    local nonstd="$w/nonstandard-skills"
    mkdir -p "$nonstd/_shared"
    cp "$BUILD_REGISTRY_SCRIPT" "$nonstd/_shared/build-skill-registry.sh"
    chmod +x "$nonstd/_shared/build-skill-registry.sh"
    u_make_skill "$nonstd/only-here" only-here "Reachable only through the catch-all. Trigger: catch-all"

    bash "$nonstd/_shared/build-skill-registry.sh" --root "$w/proj" >/dev/null 2>&1 \
        || { echo "installed-copy run failed"; return 1; }
    body="$(cat "$w/proj/.kurama/skill-registry.md")"
    assert_matches "$body" '\| only-here \|' \
        "the skill only the installed-location catch-all can reach" || return 1
    return 0
}

# ---- the install path: _shared/*.sh travels, is executable, is recorded ----

test_u_project_install_ships_the_builder_executable_and_recorded() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"

    local output status=0
    output=$(PATH="$bindir" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
        echo "setup.sh exited $status:"; printf '%s\n' "$output" | tail -5; return 1
    fi

    local builder="$repo/.claude/skills/_shared/build-skill-registry.sh"
    assert_file_exists "$builder" || {
        echo "  install_skills copied _shared/*.md only — the shipped script did not travel"
        return 1
    }
    if [ ! -x "$builder" ]; then
        echo "  the installed builder is not executable — a broken install that looks healthy in a listing"
        return 1
    fi
    # Byte-identical to the repo source, or doctor's drift check is meaningless.
    if ! cmp -s "$builder" "$BUILD_REGISTRY_SCRIPT"; then
        echo "  the installed builder differs from $BUILD_REGISTRY_SCRIPT"
        return 1
    fi

    # Recorded like every other installed file, read through the SAME parser
    # uninstall/doctor/update use — under the jq-less farm, which is the copy no
    # developer's Mac executes.
    local manifest="$repo/.kurama-install-manifest.json"
    local files
    files="$(receipt_array_values "$manifest" "files")"
    if ! receipt_array_has "$files" ".claude/skills/_shared/build-skill-registry.sh"; then
        echo "  files[] does not record the shipped script — uninstall would leave it behind"
        printf '%s\n' "$files" | grep '_shared' | awk '{ print "    " $0 }'
        return 1
    fi
    # The .md conventions must still be recorded: the glob widened, it did not move.
    if ! receipt_array_has "$files" ".claude/skills/_shared/skill-resolver.md"; then
        echo "  widening the _shared glob dropped the .md conventions from files[]"
        return 1
    fi
    return 0
}

test_u_project_install_builds_the_registry() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"

    local output status=0
    output=$(PATH="$bindir" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
        echo "setup.sh exited $status:"; printf '%s\n' "$output" | tail -5; return 1
    fi

    assert_file_exists "$repo/.kurama/skill-registry.md" || {
        echo "  a project install left no skill registry — every delegation would resolve without standards"
        return 1
    }
    local body
    body="$(cat "$repo/.kurama/skill-registry.md")"
    assert_not_matches "$body" 'Compact Rules' "a Compact Rules section" || return 1
    # The skills just installed are project-level and must be in the index.
    assert_matches "$body" '\| judgment-day \|' "an installed skill in the index" || return 1
    # sdd-*, _shared and skill-registry are excluded by name.
    assert_not_matches "$body" '\| sdd-apply \|' "an sdd-* phase skill, which is excluded" || return 1
    assert_not_matches "$body" '\| skill-registry \|' "the registry skill itself, which is excluded" || return 1
    # setup names it where the user is looking.
    assert_matches "$output" 'Skill registry.*skills \(' "the summary line naming the registry" || return 1
    return 0
}

test_u_uninstall_removes_the_shipped_script() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    PATH="$bindir" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup exited non-zero"; return 1; }
    assert_file_exists "$repo/.claude/skills/_shared/build-skill-registry.sh" || return 1

    PATH="$bindir" bash "$UNINSTALL_SCRIPT" --scope project --path "$repo" --without-pi-packages \
        > /dev/null 2>&1 || { echo "uninstall exited non-zero"; return 1; }

    if [ -e "$repo/.claude/skills/_shared/build-skill-registry.sh" ]; then
        echo "  uninstall left the shipped script behind — a recorded file it drives rm from"
        return 1
    fi
    if [ -d "$repo/.claude/skills/_shared" ]; then
        echo "  _shared/ survived the uninstall, still holding:"
        find "$repo/.claude/skills/_shared" -mindepth 1 -maxdepth 1 | awk '{ print "    " $0 }' 
        return 1
    fi
    return 0
}

test_u_doctor_flags_a_missing_or_unexecutable_builder() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    PATH="$bindir" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup exited non-zero"; return 1; }

    local builder="$repo/.claude/skills/_shared/build-skill-registry.sh"
    local out

    # Healthy install: doctor names the builder as present.
    out=$(PATH="$bindir" bash "$DOCTOR_SCRIPT" --scope project --path "$repo" 2>&1 || true)
    assert_matches "$out" 'skill-registry builder installed' \
        "the green line for a builder that is there" || return 1

    # Deleted: /skill-registry and /sdd-init have NO fallback scan by design, so
    # this is a hard failure with a name, not a generic "1 of N files missing".
    mv "$builder" "$TEST_TMPDIR/builder.bak"
    out=$(PATH="$bindir" bash "$DOCTOR_SCRIPT" --scope project --path "$repo" 2>&1 || true)
    assert_matches "$out" 'skill-registry builder missing' \
        "a named finding for the missing builder" || return 1
    assert_matches "$out" 'NO fallback scan' \
        "why it matters: nothing else can build the registry" || return 1
    mv "$TEST_TMPDIR/builder.bak" "$builder"

    # Present but not executable: same class of broken install, invisible in a
    # file listing, so it gets its own finding.
    chmod -x "$builder"
    out=$(PATH="$bindir" bash "$DOCTOR_SCRIPT" --scope project --path "$repo" 2>&1 || true)
    assert_matches "$out" 'skill-registry builder is not executable' \
        "a named finding for a non-executable builder" || return 1
    chmod +x "$builder"
    return 0
}

test_u_registry_alone_is_not_proof_of_initialization() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    PATH="$bindir" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup exited non-zero"; return 1; }
    assert_file_exists "$repo/.kurama/skill-registry.md" || return 1

    # #101 closed "installed, never initialized" by accepting .kurama/ as proof
    # the phase ran — and skill-registry.md was the file it named. setup.sh writes
    # that file itself now, so accepting it would grade every FRESH install
    # "initialized" and re-open the exact silent partial success #101 fixed.
    local out
    out=$(PATH="$bindir" bash "$DOCTOR_SCRIPT" --scope project --path "$repo" 2>&1 || true)
    assert_matches "$out" 'installed, never initialized' \
        "the #101 warning, which the install-time registry must not silence" || return 1

    # Anything ELSE under .kurama/ is still sdd-init's own output and still counts.
    printf 'execution_mode: supervised\n' > "$repo/.kurama/settings.yaml"
    out=$(PATH="$bindir" bash "$DOCTOR_SCRIPT" --scope project --path "$repo" 2>&1 || true)
    assert_matches "$out" 'initialized: .kurama/ settings bundle present' \
        "the pass once a real settings bundle is there" || return 1
    assert_not_matches "$out" 'installed, never initialized' \
        "the warning, which must be gone once init really ran" || return 1
    return 0
}

test_u_update_rebuilds_the_registry() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    PATH="$bindir" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup exited non-zero"; return 1; }

    # A registry deleted by hand (or never built, on an install predating #106)
    # must come back on the next re-sync — that is the whole point of putting a
    # refresh point there.
    rm -f "$repo/.kurama/skill-registry.md"
    local out status=0
    out=$(PATH="$bindir" bash "$UPDATE_SCRIPT" --scope project --path "$repo" 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
        echo "update.sh exited $status:"; printf '%s\n' "$out" | tail -8; return 1
    fi
    assert_file_exists "$repo/.kurama/skill-registry.md" || {
        echo "  a re-sync left no registry behind"
        return 1
    }
    assert_matches "$out" 'skill-registry: [0-9]+ skills' \
        "the rebuild line, so an update SAYS it refreshed the registry" || return 1
    return 0
}

# ---- the prose: one implementation, and no directory list anywhere ----

test_u_skills_run_the_script_and_carry_no_directory_list() {
    local f body
    for f in "$REPO_DIR/skills/sdd-init/SKILL.md" "$REPO_DIR/skills/skill-registry/SKILL.md"; do
        assert_file_exists "$f" || return 1
        body="$(cat "$f")"

        # Positive control FIRST: a file that names the script is a file that was
        # actually rewritten. Without this, every assertion below would pass on
        # an empty file.
        assert_matches "$body" 'build-skill-registry\.sh' \
            "${f##*/}: the script it must run" || return 1

        # The eleven scan directories, re-listed in prose in TWO skills, is
        # exactly the drift upstream shipped: their two lists have already
        # diverged. The script owns the list now, and only the script.
        assert_not_matches "$body" '[~]/\.claude/skills' \
            "${f##*/}: a hardcoded user-level skills path" || return 1
        assert_not_matches "$body" '[~]/\.codex/skills|[~]/\.config/opencode/skills' \
            "${f##*/}: more hardcoded scan paths" || return 1
        assert_not_matches "$body" '\.pi/agent/skills|\.omp/agent/skills' \
            "${f##*/}: the remaining hardcoded scan paths" || return 1

        # And no instruction for the model to do the scan itself.
        assert_not_matches "$body" '\*\*?/SKILL\.md' \
            "${f##*/}: a glob for the model to run" || return 1
        assert_not_matches "$body" '## Compact Rules|Generate Compact Rules' \
            "${f##*/}: the compact-rules section that was 63% of the old build" || return 1
    done

    # Both must say what happens when the script is not there: stop. A silent
    # fallback to a hand scan is how two implementations start disagreeing.
    body="$(cat "$REPO_DIR/skills/skill-registry/SKILL.md")"
    assert_matches "$body" 'no fallback scan|NO fallback scan|There is no fallback' \
        "skill-registry: the no-fallback rule" || return 1
    body="$(cat "$REPO_DIR/skills/sdd-init/SKILL.md")"
    assert_matches "$body" 'no fallback|do not scan by hand|STOP' \
        "sdd-init Step 4: the no-fallback rule" || return 1
    return 0
}

echo -e "${BOLD}UNIT-U (issue #106): the skill registry is a script, not a sub-agent${NC}"
run_test "the scan indexes the fixture tree exactly" test_u_scan_indexes_the_fixture_tree_exactly
run_test "the registry is an index — no Compact Rules" test_u_registry_is_an_index_with_no_compact_rules
run_test "a second run is byte-identical, no .tmp left" test_u_second_run_is_byte_identical_and_leaves_no_temp
run_test "root guard: \$HOME, / and unmarked dirs refused" test_u_root_guard_refuses_home_and_filesystem_root
run_test "the build finishes in seconds, not minutes" test_u_build_finishes_in_seconds_not_minutes
run_test "the clone copy never indexes Kurama's sources" test_u_clone_copy_does_not_index_kuramas_own_sources
run_test "install ships _shared/*.sh executable + recorded" test_u_project_install_ships_the_builder_executable_and_recorded
run_test "a project install builds the registry" test_u_project_install_builds_the_registry
run_test "uninstall removes the shipped script" test_u_uninstall_removes_the_shipped_script
run_test "doctor flags a missing/unexecutable builder" test_u_doctor_flags_a_missing_or_unexecutable_builder
run_test "the registry alone is not proof of sdd-init" test_u_registry_alone_is_not_proof_of_initialization
run_test "update.sh rebuilds the registry on re-sync" test_u_update_rebuilds_the_registry
run_test "the skills run the script and list no directories" test_u_skills_run_the_script_and_carry_no_directory_list

echo ""

# ============================================================================
# UNIT-P (issues #105, #101): machine-local files, and a repo that already has
# its own workflow
#
# Both issues are the same failure in two places: setup.sh does something
# consequential to the target repo and says nothing about it.
#
#   #105  Project scope writes machine-local files INTO the repo — the receipt
#         (absolute paths), .kurama/, timestamped merge backups,
#         .claude/settings.local.json — and never touched .gitignore. Six docs
#         asserted ".kurama/ is gitignored" as fact with no producer. In the
#         field a receipt full of absolute paths was COMMITTED, and .mcp.json /
#         opencode.json were committed carrying /opt/homebrew/bin/engram,
#         because engram_command matched */Cellar/engram/* against a path
#         `command -v` never returns: Homebrew puts a SYMLINK on PATH.
#
#   #101  setup.sh appended Kurama's "SDD owns the work lifecycle" block 117
#         lines BELOW a pre-existing workflow in the same CLAUDE.md and printed
#         nothing. The precedence clause was present and readable, and lost
#         anyway. Position is not neutral in a 335-line file.
#
# Most of this section runs under the jq-less farm on purpose. The receipt grew
# a new array key (gitignore[]) that uninstall drives an rm-adjacent rewrite
# from, and the awk fallback parser is the one no developer's Mac ever executes
# — which is exactly how the single-line-empty-array bug shipped (#13). The one
# case that needs jq is the Engram registration: engram_merge_json is jq-only by
# the documented never-sed-on-JSON contract.
#
# NOTE on controls. Like UNIT-L, nothing here reads git history:
# .github/workflows/pr-check.yml checks out at depth 1, so `origin/main` is not
# a ref on CI and a history-based control would fail there or degrade to a
# vacuous skip. Every case below asserts the new behaviour directly, which is
# absent on main by construction — verified by hand against a clone whose
# scripts/setup.sh and scripts/lib/receipt.sh came from `git show origin/main:`:
# no .gitignore written, no gitignore[] key, no workflow notice, and
# "command": "/opt/homebrew/bin/engram" in .mcp.json.
# ============================================================================

# Print the managed machine-local block of the .gitignore at $1 — everything
# strictly between the markers. Empty when the file or the markers are missing,
# which is why every caller size-checks or grep-counts the result.
gitignore_block() {
    local file="$1"
    [ -f "$file" ] || return 0
    awk '/^# BEGIN:kurama$/ { f = 1; next } /^# END:kurama$/ { f = 0 } f' "$file"
}

# Fail unless the .gitignore at $1 carries exactly one balanced managed block.
assert_balanced_gitignore_block() {
    local file="$1"
    assert_file_exists "$file" || return 1
    local begin end
    begin=$(grep -cxF '# BEGIN:kurama' "$file" 2>/dev/null || true)
    end=$(grep -cxF '# END:kurama' "$file" 2>/dev/null || true)
    if [ "$begin" != "1" ] || [ "$end" != "1" ]; then
        echo "  ${file##*/}: $begin BEGIN:kurama / $end END:kurama (expected exactly one pair)"
        return 1
    fi
    return 0
}

# The PATTERNS of the managed block at $1 — its non-comment, non-blank lines.
# The comments are the per-pattern "why"; what a repo actually ignores is this.
gitignore_block_patterns() {
    gitignore_block "$1" | awk '!/^[[:space:]]*#/ && NF'
}

# Build a Homebrew-shaped engram at $1: a bin/engram SYMLINK into a versioned
# Cellar path, which is what `command -v engram` really returns on a Mac and the
# exact shape the */Cellar/engram/* case could never match. Echoes the bin dir.
make_brew_engram() {
    local root="$1" version="${2:-1.2.3}"
    mkdir -p "$root/bin" "$root/Cellar/engram/$version/bin"
    cat > "$root/Cellar/engram/$version/bin/engram" <<'SHIM'
#!/usr/bin/env bash
echo "engram 1.2.3"
exit 0
SHIM
    chmod +x "$root/Cellar/engram/$version/bin/engram"
    ln -sf "$root/Cellar/engram/$version/bin/engram" "$root/bin/engram"
    printf '%s' "$root/bin"
}

test_p_project_install_writes_the_managed_gitignore_block() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"

    local output status=0
    output=$(PATH="$bindir" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
        echo "setup.sh exited $status:"; printf '%s\n' "$output" | tail -5; return 1
    fi

    assert_balanced_gitignore_block "$repo/.gitignore" || return 1

    # The four machine-local patterns, each of which was individually left to a
    # human to remember. .atl/ is Pi-only and this install is claude-code.
    local patterns
    patterns="$(gitignore_block_patterns "$repo/.gitignore")"
    local want
    for want in '.kurama/' '.kurama-install-manifest.json' '*.bak.[0-9]*' '.claude/settings.local.json'; do
        if ! printf '%s\n' "$patterns" | grep -qxF -- "$want"; then
            echo "  the managed block is missing the pattern: $want"
            printf '%s\n' "$patterns" | awk '{ print "    " $0 }'
            return 1
        fi
    done
    if printf '%s\n' "$patterns" | grep -qxF -- '.atl/'; then
        echo "  .atl/ is Pi runtime state and must not appear in a claude-code-only install"
        return 1
    fi

    # The invariant that killed the `none` mode: the specs are the source of
    # truth and MUST be committed. Same for the shared MEMORY.md. Checked over
    # the WHOLE file, not just the block — a rule outside the markers would be
    # just as fatal and Kurama is the only thing that wrote this file.
    if grep -qE '(^|/)openspec' "$repo/.gitignore"; then
        echo "  openspec/ must NEVER be ignored — the specs are the source of truth"
        grep -nE '(^|/)openspec' "$repo/.gitignore" | awk '{ print "    " $0 }'
        return 1
    fi
    if grep -qF 'MEMORY.md' "$repo/.gitignore"; then
        echo "  MEMORY.md is a team artifact and must NEVER be ignored"
        return 1
    fi

    # Every pattern carries its own one-line reason: a bare list dropped into
    # somebody else's repo is unreviewable, and the reasons are what let a
    # reviewer tell this block from a hand-edit.
    local comments
    comments=$(gitignore_block "$repo/.gitignore" | grep -c '^#' || true)
    if [ "$comments" -lt 4 ]; then
        echo "  the block carries $comments comment lines — the per-pattern 'why' is gone"
        return 1
    fi

    # And the summary says it happened, with the count. A block written in
    # silence is the defect this issue is about.
    assert_matches "$output" '\.gitignore.*Kurama block added \(4 patterns\)' \
        "the Setup Complete summary line naming the block and its pattern count" || return 1
    return 0
}

test_p_second_run_leaves_the_gitignore_byte_identical() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    # Rules the repo already had. They must survive untouched, in place, and the
    # block must never be written twice.
    printf 'node_modules/\ndist/\n.env\n' > "$repo/.gitignore"
    local before; before="$(cat "$repo/.gitignore")"

    PATH="$bindir" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "first setup exited non-zero"; return 1; }
    local first; first="$(cat "$repo/.gitignore")"
    local first_hash; first_hash="$(hash_file "$repo/.gitignore")"

    local output; output=$(PATH="$bindir" bash "$SETUP_SCRIPT" --agent claude-code --scope project \
        --path "$repo" --without-engram --non-interactive 2>&1) \
        || { echo "second setup exited non-zero"; return 1; }

    if [ "$first_hash" != "$(hash_file "$repo/.gitignore")" ]; then
        echo "  the second run rewrote .gitignore — an unchanged block must not be touched"
        diff <(printf '%s\n' "$first") <(cat "$repo/.gitignore") | head -10 | awk '{ print "    " $0 }'
        return 1
    fi
    assert_balanced_gitignore_block "$repo/.gitignore" || return 1
    assert_matches "$output" '\.gitignore.*already present' \
        "the summary reporting the block as already present rather than added again" || return 1

    # The repo's own three rules, byte-for-byte, still the first three lines.
    if [ "$(head -3 "$repo/.gitignore")" != "$before" ]; then
        echo "  the repo's own rules were modified or reordered"
        head -5 "$repo/.gitignore" | awk '{ print "    " $0 }'
        return 1
    fi
    return 0
}

test_p_uninstall_removes_the_block_and_keeps_unrelated_lines() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    printf 'node_modules/\ndist/\n.env\n' > "$repo/.gitignore"
    local before; before="$(cat "$repo/.gitignore")"

    PATH="$bindir" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup exited non-zero"; return 1; }
    grep -qxF '# BEGIN:kurama' "$repo/.gitignore" || { echo "no block to remove"; return 1; }

    PATH="$bindir" bash "$UNINSTALL_SCRIPT" --scope project --path "$repo" --without-pi-packages \
        > /dev/null 2>&1 || { echo "uninstall exited non-zero"; return 1; }

    assert_file_exists "$repo/.gitignore" || return 1
    if grep -qF 'kurama' "$repo/.gitignore"; then
        echo "  the managed block survived the uninstall:"
        grep -nF 'kurama' "$repo/.gitignore" | head -5 | awk '{ print "    " $0 }'
        return 1
    fi
    # Byte-for-byte back to what the repo had — not "close enough", and not one
    # blank line longer per install/uninstall cycle.
    assert_eq "$before" "$(cat "$repo/.gitignore")" \
        "uninstall must return .gitignore to exactly what the repo wrote" || return 1
    return 0
}

test_p_uninstall_removes_a_gitignore_kurama_created() {
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    [ -f "$repo/.gitignore" ] && { echo "fixture already has a .gitignore"; return 1; }

    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup exited non-zero"; return 1; }
    assert_file_exists "$repo/.gitignore" || return 1

    bash "$UNINSTALL_SCRIPT" --scope project --path "$repo" --without-pi-packages \
        > /dev/null 2>&1 || { echo "uninstall exited non-zero"; return 1; }

    # Kurama created the file and it held nothing else, so removing the block
    # leaves nothing — the repo goes back to having no .gitignore at all rather
    # than keeping an empty one nobody asked for.
    if [ -f "$repo/.gitignore" ]; then
        echo "  a .gitignore holding nothing but our block should be removed, not left empty:"
        awk '{ print "    [" $0 "]" }' "$repo/.gitignore"
        return 1
    fi
    return 0
}

test_p_non_git_target_skips_the_block_and_exits_zero() {
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    # A directory, deliberately NOT a git repo. --scope project tolerates one
    # when the user says so, and there is nothing to gitignore in it.
    local plain="$TEST_TMPDIR/plain"
    mkdir -p "$plain"

    local output status=0
    output=$(printf 'y\n' | PATH="$bindir" bash "$SETUP_SCRIPT" --agent claude-code --scope project \
        --path "$plain" --without-engram 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
        echo "a non-git project target must still install cleanly (exit 0), got $status:"
        printf '%s\n' "$output" | tail -5
        return 1
    fi
    if [ -e "$plain/.gitignore" ]; then
        echo "  a .gitignore was written into a directory git does not track"
        return 1
    fi
    assert_matches "$output" '\.gitignore.*not a git repo.*skipped' \
        "the summary line saying the block was skipped, and why" || return 1
    # Skipped, not silently claimed: nothing may be recorded for uninstall to strip.
    local recorded
    recorded="$(receipt_array_values "$plain/.kurama-install-manifest.json" gitignore)"
    if [ -n "$(printf '%s' "$recorded" | awk 'NF')" ]; then
        echo "  the receipt records a .gitignore block that was never written: $recorded"
        return 1
    fi
    return 0
}

test_p_receipt_records_the_block_for_both_parsers() {
    # The receipt grew an array key that uninstall rewrites a user file from.
    # Read it BOTH ways over the same bytes: jq (the host's) and the awk
    # fallback the shipped lib uses when jq is absent. A key only one of them
    # can see is the #13 shape all over again.
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup exited non-zero"; return 1; }

    local manifest="$repo/.kurama-install-manifest.json"
    assert_file_exists "$manifest" || return 1

    if ! command -v jq >/dev/null 2>&1; then
        echo "  jq is absent on this host — this case compares the two parsers and needs both"
        return 1
    fi
    local with_jq without_jq
    with_jq="$(jq -r '(.gitignore // [])[]' "$manifest")"
    # The lib's awk branch, reached by making jq unresolvable for this call only.
    local farm="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$farm"
    assert_farm_has_no_jq "$farm" || return 1
    without_jq="$(PATH="$farm" bash -c '
        . "$1/lib/receipt.sh"
        manifest_gitignore "$2"
    ' bash "$SCRIPT_DIR" "$manifest")"

    if [ -z "$(printf '%s' "$with_jq" | awk 'NF')" ]; then
        echo "  the receipt records no gitignore[] entry at all"
        return 1
    fi
    assert_eq "$with_jq" "$without_jq" \
        "manifest_gitignore must read the same entries with and without jq" || return 1
    # Recorded relative to the receipt dir, like every other recorded path —
    # never as an absolute path uninstall's containment filter would refuse.
    assert_eq ".gitignore" "$with_jq" \
        "the block is recorded relative to the receipt dir" || return 1
    return 0
}

test_p_atl_is_recorded_only_when_pi_is_installed() {
    # The one decision #105 left open. .atl/ is Pi runtime state; the block
    # describes what THIS install writes, so it appears only once Pi is here —
    # and it must APPEAR then, on the same shared project receipt, without a
    # reinstall of the first harness.
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"

    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "claude-code setup exited non-zero"; return 1; }
    if gitignore_block_patterns "$repo/.gitignore" | grep -qxF -- '.atl/'; then
        echo "  .atl/ appeared before Pi was installed"
        return 1
    fi

    bash "$SETUP_SCRIPT" --agent pi --scope project --path "$repo" \
        --without-engram --without-pi-packages --non-interactive > /dev/null 2>&1 \
        || { echo "pi setup exited non-zero"; return 1; }
    if ! gitignore_block_patterns "$repo/.gitignore" | grep -qxF -- '.atl/'; then
        echo "  .atl/ is still missing after a Pi install — Pi runtime state can be committed"
        gitignore_block_patterns "$repo/.gitignore" | awk '{ print "    " $0 }'
        return 1
    fi
    # Still ONE block, still balanced: the second harness updated it in place.
    assert_balanced_gitignore_block "$repo/.gitignore" || return 1
    return 0
}

test_p_update_ensures_the_block_on_an_install_that_predates_it() {
    # An install made before #105 has no block and no gitignore[] entry. The
    # re-sync is how it acquires one — otherwise every existing project install
    # stays exposed until someone reinstalls by hand.
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup exited non-zero"; return 1; }

    # Age the install: drop the block and the receipt key, exactly as a 6.1.2
    # receipt looks. Done with awk so it needs no jq.
    rm -f "$repo/.gitignore"
    local manifest="$repo/.kurama-install-manifest.json" tmp="$TEST_TMPDIR/aged.json"
    awk '
        /^[[:space:]]*"gitignore"[[:space:]]*:[[:space:]]*\[/ { skip = 1; next }
        skip && /^[[:space:]]*\],?[[:space:]]*$/ { skip = 0; next }
        skip { next }
        { print }
    ' "$manifest" > "$tmp" && mv "$tmp" "$manifest"
    if grep -qF '"gitignore"' "$manifest"; then
        echo "  the fixture still carries a gitignore key — this case would prove nothing"
        return 1
    fi

    local output status=0
    output=$(bash "$UPDATE_SCRIPT" --scope project --path "$repo" 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
        echo "update.sh exited $status:"; printf '%s\n' "$output" | tail -8; return 1
    fi
    assert_balanced_gitignore_block "$repo/.gitignore" || return 1
    assert_matches "$output" 'gitignore block ensured' \
        "update.sh reporting that it ensured the block" || return 1
    return 0
}

test_p_doctor_flags_a_tracked_machine_local_file() {
    # The actual damage. A .gitignore rule does NOT untrack a file that is
    # already committed, so a repo can look protected and still be leaking the
    # receipt's absolute paths on every push — which is what the field report
    # found. This is the one finding graded as a hard failure.
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup exited non-zero"; return 1; }

    # Commit the receipt the way a human does: -f, because the block that would
    # have stopped them did not exist when they ran `git add`.
    git -C "$repo" add -f .kurama-install-manifest.json > /dev/null 2>&1
    git -C "$repo" -c commit.gpgsign=false commit -qm "commit the receipt" > /dev/null 2>&1

    local output status=0
    output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" --scope project --path "$repo" 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        echo "doctor graded a repo with a COMMITTED install receipt as healthy"
        return 1
    fi
    assert_matches "$output" 'TRACKED by git' \
        "the finding that a machine-local file is tracked" || return 1
    assert_matches "$output" '\.kurama-install-manifest\.json' \
        "the finding NAMING the tracked file" || return 1
    assert_matches "$output" 'rm --cached' \
        "the fix — a .gitignore rule does not untrack an already-committed file" || return 1
    return 0
}

test_p_doctor_flags_a_missing_gitignore_block() {
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup exited non-zero"; return 1; }
    # Someone deleted it, or the install predates #105.
    rm -f "$repo/.gitignore"

    local output
    output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" --scope project --path "$repo" 2>&1) || true
    assert_matches "$output" 'NOT gitignored|recorded but gone' \
        "the finding that machine-local files are not ignored in this repo" || return 1
    assert_matches "$output" 'update\.sh|setup\.sh' \
        "the fix naming the script that writes the block" || return 1
    # A missing block is a risk, not damage: it must not turn a healthy install
    # into a failing one, or every fresh non-git-repo trial would exit 1.
    assert_not_matches "$output" 'All checks passed' \
        "a green grade over a repo whose machine-local files are unprotected" || return 1
    return 0
}

test_p_doctor_flags_installed_but_never_initialized() {
    # #101's second half. The field repo had a valid receipt, the right commit,
    # balanced markers, working hooks — and no openspec/ at all, because
    # sdd-init never ran. doctor called that healthy. An install with no
    # settings bundle has no artifact_store.mode, no execution_mode and no
    # tdd.enabled: structurally complete, functionally inert.
    local shim="$TEST_TMPDIR/doctorbin"
    make_doctor_shims "$shim"
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup exited non-zero"; return 1; }
    [ -e "$repo/openspec" ] && { echo "setup created openspec/ — sdd-init is what does that"; return 1; }

    local output
    output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" --scope project --path "$repo" 2>&1) || true
    assert_matches "$output" 'installed, never initialized' \
        "the finding that the install exists but no SDD phase can run" || return 1
    assert_matches "$output" 'sdd-init' \
        "the fix naming the phase that has never run" || return 1
    assert_not_matches "$output" 'All checks passed' \
        "a green grade over an install that cannot run a single SDD phase" || return 1

    # And it clears once init has actually happened, in EITHER settings home:
    # openspec/config.yaml for openspec/hybrid, .kurama/ for engram mode.
    write_sdd_init_config "$repo" neutral
    output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" --scope project --path "$repo" 2>&1) || true
    assert_not_matches "$output" 'installed, never initialized' \
        "the finding persisting after openspec/config.yaml exists" || return 1

    # #106 moved this line. .kurama/skill-registry.md used to be the engram-mode
    # proof that init had run, because only sdd-init Step 4 produced it. setup.sh
    # builds it at install time now, so accepting it would grade every FRESH
    # install "initialized" — the exact false green this case exists to catch.
    # The registry is already on disk from the setup above, and the finding above
    # fired anyway, which is that half of the contract.
    rm -rf "$repo/openspec"
    assert_file_exists "$repo/.kurama/skill-registry.md" || return 1

    # Everything ELSE under .kurama/ is still sdd-init's (or a cycle's) own
    # output and still clears the finding. The three cycle markers land under
    # .kurama/sdd/<change>/ in EVERY mode, engram included — see
    # _shared/persistence-contract.md — so they are the on-disk evidence a
    # markdown-less engram project actually has.
    mkdir -p "$repo/.kurama/sdd/demo-change"
    printf 'phase: init\n' > "$repo/.kurama/sdd/demo-change/state.md"
    output=$(PATH="$shim:$PATH" bash "$DOCTOR_SCRIPT" --scope project --path "$repo" 2>&1) || true
    assert_not_matches "$output" 'installed, never initialized' \
        "the finding persisting once .kurama/ carries something a cycle wrote" || return 1
    return 0
}

test_p_homebrew_engram_is_written_as_the_bare_command() {
    # #105's root cause, measured. `command -v engram` returns the Homebrew
    # SYMLINK (/opt/homebrew/bin/engram), never the Cellar path it points at, so
    # the */Cellar/engram/* case never fired and a machine-specific absolute
    # path was written into a project .mcp.json the whole team shares.
    # jq-present on purpose: engram_merge_json is jq-only by contract.
    if ! command -v jq >/dev/null 2>&1; then
        echo "  jq is absent — the MCP merge is jq-only by contract, so this case cannot run"
        return 1
    fi
    local brewbin
    brewbin="$(make_brew_engram "$TEST_TMPDIR/opt/homebrew")"
    # The link must really be a link, or this case proves nothing.
    [ -L "$brewbin/engram" ] || { echo "the fixture engram is not a symlink"; return 1; }

    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    PATH="$brewbin:$PATH" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --with-engram --non-interactive > /dev/null 2>&1 \
        || { echo "setup exited non-zero"; return 1; }

    assert_file_exists "$repo/.mcp.json" || return 1
    local cmd
    cmd="$(jq -r '.mcpServers.engram.command // ""' "$repo/.mcp.json")"
    assert_eq "engram" "$cmd" \
        "a Homebrew engram must be written as the bare command, never an absolute path" || return 1
    if grep -qF '/homebrew/' "$repo/.mcp.json"; then
        echo "  .mcp.json still carries a machine-specific Homebrew path:"
        grep -nF '/homebrew/' "$repo/.mcp.json" | head -3 | awk '{ print "    " $0 }'
        return 1
    fi

    # The other half of the fix: a brew prefix that is NOT literally
    # ".../homebrew/bin" is caught by RESOLVING the symlink to its Cellar
    # target — the readlink loop, since macOS has no readlink -f.
    local otherbin
    otherbin="$(make_brew_engram "$TEST_TMPDIR/custombrew" 9.9.9)"
    local repo2="$TEST_TMPDIR/proj2"
    make_git_repo "$repo2"
    PATH="$otherbin:$PATH" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo2" \
        --with-engram --non-interactive > /dev/null 2>&1 \
        || { echo "second setup exited non-zero"; return 1; }
    assert_eq "engram" "$(jq -r '.mcpServers.engram.command // ""' "$repo2/.mcp.json")" \
        "a Cellar target reached through a non-'homebrew' prefix must still collapse to 'engram'" || return 1

    # And a NON-brew engram keeps its absolute path on purpose: a GUI-launched
    # client does not always inherit the shell PATH, and there is no stable bare
    # name to fall back on outside brew.
    local plainbin="$TEST_TMPDIR/plainbin"
    mkdir -p "$plainbin"
    printf '#!/usr/bin/env bash\necho engram\n' > "$plainbin/engram"
    chmod +x "$plainbin/engram"
    local repo3="$TEST_TMPDIR/proj3"
    make_git_repo "$repo3"
    PATH="$plainbin:$PATH" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo3" \
        --with-engram --non-interactive > /dev/null 2>&1 \
        || { echo "third setup exited non-zero"; return 1; }
    assert_eq "$plainbin/engram" "$(jq -r '.mcpServers.engram.command // ""' "$repo3/.mcp.json")" \
        "a non-Homebrew engram must keep its absolute path" || return 1
    return 0
}

test_p_setup_names_a_pre_existing_workflow_in_the_prompt() {
    # #101, measured at the one moment a human is watching. The repo's own
    # workflow is committed and complete; Kurama's block lands below it; the
    # installer must say both things exist and which one wins — without
    # refusing, and without editing a byte of theirs.
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    cat > "$repo/CLAUDE.md" <<'PROMPT'
# octo-pon-api

## Workflow

Every change follows this, no exceptions:

1. Open an issue describing the problem.
2. Refine the spec together — run the brainstorming skill.
3. Update the issue with the agreed PRD: the issue body is the source of truth.
4. Implement against the issue.
5. Close the issue in the PR description.
PROMPT
    local theirs; theirs="$(cat "$repo/CLAUDE.md")"

    local output status=0
    output=$(PATH="$bindir" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
        echo "setup must NEVER refuse over a pre-existing workflow, got exit $status:"
        printf '%s\n' "$output" | tail -5
        return 1
    fi

    assert_matches "$output" 'Two workflows now live in .*CLAUDE\.md' \
        "the notice naming the file two workflows now share" || return 1
    assert_matches "$output" 'the heading "## Workflow"' \
        "what the heuristic actually found, quoted back to the project" || return 1
    assert_matches "$output" 'numbered step list' \
        "the second signal — a numbered list of steps describing a pipeline" || return 1
    assert_matches "$output" "project's own instructions take precedence" \
        "the precedence statement: the project's committed instructions outrank Kurama's block" || return 1
    assert_matches "$output" 'lines [0-9]+-[0-9]+' \
        "WHERE the block landed — position is the whole finding of #101" || return 1
    assert_matches "$output" 'sdd-init' \
        "the pointer to the phase that asks how the two coexist" || return 1

    # Their content, untouched and still FIRST. The merge was never the defect.
    assert_balanced_kurama_block "$repo/CLAUDE.md" || return 1
    local kept
    kept="$(awk '/<!-- BEGIN:kurama -->/ { exit } { print }' "$repo/CLAUDE.md")"
    # The append separates their content from the block with one blank line;
    # trim trailing blanks so the comparison is about THEIR bytes, not spacing.
    kept="$(printf '%s\n' "$kept" | awk '
        { l[NR] = $0 }
        END { last = NR; while (last > 0 && l[last] ~ /^[[:space:]]*$/) last--
              for (i = 1; i <= last; i++) print l[i] }')"
    assert_eq "$theirs" "$kept" \
        "setup must not change one byte of the project's own instructions" || return 1
    return 0
}

test_p_no_workflow_notice_when_kurama_owns_the_whole_prompt() {
    # The heuristic must not report the installer to itself. A generated example
    # copied whole into place carries Kurama's own "## SDD Workflow" heading and
    # its own numbered lists — foreign content by shape, ours by provenance.
    local bindir="$TEST_TMPDIR/nojq-bin"
    make_nojq_farm "$bindir"
    assert_farm_has_no_jq "$bindir" || return 1

    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    cp "$REPO_DIR/examples/claude-code/CLAUDE.md" "$repo/CLAUDE.md"
    head -1 "$repo/CLAUDE.md" | grep -qF 'GENERATED FILE' \
        || { echo "the shipped example lost its GENERATED banner — fixture invalid"; return 1; }

    local output
    output=$(PATH="$bindir" bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive 2>&1) \
        || { echo "setup exited non-zero"; return 1; }

    assert_not_matches "$output" 'Two workflows now live' \
        "a workflow notice raised over Kurama's own generated prompt" || return 1
    assert_balanced_kurama_block "$repo/CLAUDE.md" || return 1
    return 0
}

test_p_a_fresh_prompt_file_raises_no_notice() {
    # No pre-existing content, nothing to warn about. Guards the other side of
    # the heuristic: a notice on every install is a notice nobody reads.
    local repo="$TEST_TMPDIR/proj"
    make_git_repo "$repo"
    [ -e "$repo/CLAUDE.md" ] && { echo "fixture already has a prompt file"; return 1; }

    local output
    output=$(bash "$SETUP_SCRIPT" --agent claude-code --scope project --path "$repo" \
        --without-engram --non-interactive 2>&1) \
        || { echo "setup exited non-zero"; return 1; }
    assert_not_matches "$output" 'Two workflows now live|already had content of its own' \
        "a notice raised over a prompt file Kurama created from nothing" || return 1
    return 0
}

test_p_sdd_init_asks_how_the_two_workflows_coexist() {
    # The decision #101 says has no default. sdd-init is where it gets made, and
    # the SKILL.md is the only place that instruction exists.
    local skill="$REPO_DIR/skills/sdd-init/SKILL.md"
    assert_file_exists "$skill" || return 1
    local body; body="$(flatten_file "$skill")"

    assert_matches "$body" 'pre-existing project workflow' \
        "the conditional question about a workflow the project already has" || return 1
    assert_matches "$body" 'OUTSIDE the .{0,20}BEGIN:kurama' \
        "the detection rule: only content outside Kurama's own markers counts" || return 1
    assert_matches "$body" 'sdd_primary' \
        "the option under which the specs stay the source of truth" || return 1
    assert_matches "$body" 'project_primary' \
        "the option under which the project keeps its flow and uses SDD selectively" || return 1
    assert_matches "$body" 'sdd_primary.{0,40}RECOMMENDED' \
        "the recommended option, marked as such rather than left as a coin flip" || return 1
    assert_matches "$body" 'AskUserQuestion' \
        "the native question tool, per the shared rendering convention" || return 1
    assert_matches "$body" 'workflow_coexistence' \
        "the settings key the answer is recorded under" || return 1
    assert_matches "$body" 'NO default|never resolve this by default|No default' \
        "the rule that no side is chosen silently" || return 1
    return 0
}

echo -e "${BOLD}UNIT-P (issues #105, #101): machine-local files + a repo's own workflow${NC}"
run_test "project install writes the managed .gitignore block" test_p_project_install_writes_the_managed_gitignore_block
run_test "a second run leaves .gitignore byte-identical" test_p_second_run_leaves_the_gitignore_byte_identical
run_test "uninstall removes the block, unrelated lines intact" test_p_uninstall_removes_the_block_and_keeps_unrelated_lines
run_test "uninstall removes a .gitignore Kurama created" test_p_uninstall_removes_a_gitignore_kurama_created
run_test "a non-git target is skipped, exit 0" test_p_non_git_target_skips_the_block_and_exits_zero
run_test "the receipt records the block for jq AND awk" test_p_receipt_records_the_block_for_both_parsers
run_test ".atl/ appears only once Pi is installed" test_p_atl_is_recorded_only_when_pi_is_installed
run_test "update ensures the block on a pre-#105 install" test_p_update_ensures_the_block_on_an_install_that_predates_it
run_test "doctor fails on a TRACKED machine-local file" test_p_doctor_flags_a_tracked_machine_local_file
run_test "doctor flags a missing .gitignore block" test_p_doctor_flags_a_missing_gitignore_block
run_test "doctor flags installed-but-never-initialized" test_p_doctor_flags_installed_but_never_initialized
run_test "a Homebrew engram is written as the bare command" test_p_homebrew_engram_is_written_as_the_bare_command
run_test "setup names a pre-existing workflow in the prompt" test_p_setup_names_a_pre_existing_workflow_in_the_prompt
run_test "no notice when Kurama owns the whole prompt" test_p_no_workflow_notice_when_kurama_owns_the_whole_prompt
run_test "a fresh prompt file raises no notice" test_p_a_fresh_prompt_file_raises_no_notice
run_test "sdd-init asks how the two workflows coexist" test_p_sdd_init_asks_how_the_two_workflows_coexist

echo ""

# ============================================================================
# UNIT-V (issues #85, #86): the issue-skill split, and root-cause triage
#
# #85 split one skill that was doing two jobs. `skills/issue-creation` was
# written FOR this repo and installed into EVERY other one: it named Kurama's
# templates, Kurama's `status:needs-review` / `status:approved` gate and
# Kurama's Discussions, then ran `gh issue create` with no `--repo` — so the
# labels were rejected in the host repo and, read the other way, a report about
# Kurama landed in the user's own backlog. Same defect class as the `{file:~}`
# prompt path in #78: a form that was correct where it was written and wrong
# where it executes.
#
# The split is only real if BOTH halves hold, and each half breaks silently:
#
#   * issue-creation must stop carrying the upstream job. A file that still
#     names `myst4/kurama` or Kurama's gate labels ships this repo's house
#     rules into every project that installs Kurama — which is the bug.
#   * issue-creation must DISCOVER the host repo instead of assuming it.
#     `gh issue create --label` fails the whole command on one unknown label,
#     so an assumed taxonomy does not degrade — it loses the issue.
#   * kurama-report must target `myst4/kurama` EXPLICITLY, search first, and
#     stop for a human. It writes into a third-party repo from the user's
#     account; a silent file is not a smaller bug than a wrong one.
#   * kurama-report must never apply `status:approved`. That label is the
#     maintainer's accept signal and the precondition CONTRIBUTING checks
#     before a PR may open — a reporter that sets it approves its own issue.
#   * the reproduction must carry nothing from the user's project. Advice to
#     "be careful" is not a mechanism; the redaction rule is.
#
# #86 adds `systemic-issue-triage`: partition a batch by root cause BEFORE
# writing code, so N issues sharing one cause get ONE fix. This repo's own
# history is the argument — four consecutive waves of issue-by-issue backlog
# closing, and thirty PRs of gates and guards. Two rules carry it and both are
# the kind that get summarized away: the over-engineering test (a fix that adds
# state, a flag or a gate is redesigned; the right fix usually deletes) and
# audit-every-worker-report (Kurama delegates every phase, so what comes back
# is a claim, not evidence).
#
# Neither new skill gets a slash-command line: they are reached by trigger
# through the skill registry, like `sdd-brainstorm`. That is a prompt-budget
# DECISION (omp had 35 B of headroom), so it needs a guard or the next person
# "fixes" it.
# ============================================================================

V_ISSUE_SKILL="$REPO_DIR/skills/issue-creation/SKILL.md"
V_REPORT_SKILL="$REPO_DIR/skills/kurama-report/SKILL.md"
V_TRIAGE_SKILL="$REPO_DIR/skills/systemic-issue-triage/SKILL.md"

# Assert skill $1 is registered the way every shipped skill must be: listed in
# skills/manifest.json (which is what validate_skills.sh walks) and present in
# the AGENTS.md index table. Both, because either alone is invisible — a skill
# missing from the manifest is never installed, and one missing from AGENTS.md
# is installed and unreachable.
v_skill_is_registered() {
    local name="$1"
    grep -q "\"$name\"" "$MANIFEST_FILE" \
        || { echo "  $name is not registered in skills/manifest.json — validate_skills.sh never sees it"; return 1; }
    grep -qF "skills/$name/" "$REPO_DIR/AGENTS.md" \
        || { echo "  $name is missing from the AGENTS.md skill table"; return 1; }
    return 0
}

# Assert skill $1's frontmatter is well formed: a closed fence, a `name:` equal
# to $1, and a `description:` that carries real text (a folded scalar with an
# empty block satisfies a naive "description: is non-empty" check).
v_skill_frontmatter_is_well_formed() {
    local name="$1" src="$2" fm
    skill_frontmatter_fence_closed "$src" \
        || { echo "  skills/$name/SKILL.md: the frontmatter fence never closes"; return 1; }
    fm="$(skill_frontmatter "$src")"
    printf '%s\n' "$fm" | grep -qE "^name:[[:space:]]*${name}[[:space:]]*\$" \
        || { echo "  skills/$name/SKILL.md: frontmatter 'name:' is not $name"; return 1; }
    printf '%s\n' "$fm" | grep -qE '^description:[[:space:]]*[^[:space:]]' \
        || { echo "  skills/$name/SKILL.md: frontmatter 'description:' is missing or empty"; return 1; }
    if printf '%s\n' "$fm" | grep -qE '^description:[[:space:]]*[>|][-+0-9]*[[:space:]]*$'; then
        printf '%s\n' "$fm" | grep -qE '^[[:space:]]+[^[:space:]]' \
            || { echo "  skills/$name/SKILL.md: 'description:' folds into an empty block"; return 1; }
    fi
    return 0
}

test_v_issue_creation_no_longer_reports_upstream() {
    # The negative half of the split. What would make this pass for the wrong
    # reason: an EMPTY or deleted issue-creation matches none of the banned
    # strings, so "it no longer says X" is a vacuous green over a gutted file.
    # Three guards: a byte floor, and two positive controls proving the file is
    # still the kanban entry point it was trimmed to be (the board section and
    # the #109 branch rule both survive).
    assert_file_exists "$V_ISSUE_SKILL" || return 1
    assert_file_not_empty "$V_ISSUE_SKILL" 3000 || return 1

    local flat
    flat="$(flatten_file "$V_ISSUE_SKILL")"

    # Positive controls: the file still does its own job.
    assert_matches "$flat" 'kanban\.enabled' \
        "issue-creation is still the board's entry point (control)" || return 1
    assert_matches "$flat" 'this issue.{0,200}type/\{issue\}-\{slug\}' \
        "the #109 branch rule survived the trim (control)" || return 1

    # The upstream job is gone. Each of these is present on origin/main.
    assert_not_matches "$flat" 'myst4/kurama' \
        "the upstream repo as a filing target — every issue this skill files belongs to the host repo" || return 1
    assert_not_matches "$flat" 'status:needs-review' \
        "Kurama's own intake label, imposed on every host repo that never defined it" || return 1
    assert_not_matches "$flat" 'status:approved' \
        "Kurama's maintainer approval gate, shipped into other people's projects" || return 1
    assert_not_matches "$flat" 'bug_report\.yml' \
        "Kurama's own issue form, which setup.sh never installs into the host repo" || return 1

    # And the routing pointer exists, so a Kurama failure has somewhere to go.
    assert_matches "$flat" 'kurama-report' \
        "the pointer that sends a Kurama failure to the skill that reports it upstream" || return 1
    return 0
}

test_v_issue_creation_discovers_the_host_repo() {
    # The positive half. What would make this pass for the wrong reason: the
    # word "label" appears a dozen times in any issue skill, so a loose grep is
    # green on the unsplit file too. Both PROBES are pinned as commands, the
    # failure mode that makes them mandatory is pinned as a sentence, and the
    # degrade rule is pinned by the action it prescribes — a skill that
    # discovers labels and then sends an unknown one anyway has discovered
    # nothing.
    local flat
    flat="$(flatten_file "$V_ISSUE_SKILL")"

    assert_matches "$flat" 'gh label list' \
        "the label probe — the host repo's taxonomy is read, not assumed" || return 1
    assert_matches "$flat" 'contents/\.github/ISSUE_TEMPLATE' \
        "the template probe — the host repo's issue forms are read, not assumed" || return 1
    assert_matches "$flat" 'fails the whole command when even one named label does not exist' \
        "why the probes are mandatory: an unknown label loses the issue, it does not lose the label" || return 1
    assert_matches "$flat" 'Never create a label to satisfy a command' \
        "the degrade rule: drop the label, never invent the taxonomy" || return 1
    assert_matches "$flat" 'No forms.{0,200}generic sections' \
        "the no-template branch — a repo with no issue forms still gets a usable issue" || return 1
    return 0
}

test_v_kurama_report_targets_upstream_and_stops_for_a_human() {
    # kurama-report's two structural properties. What would make this pass for
    # the wrong reason: a skill that says "ask the user" somewhere in its prose
    # while its example command files unconditionally. So the gate is pinned by
    # its BLOCKING clause, and the auto-mode carve-out is pinned separately —
    # an `execution_mode: auto` run skipping the gate is the exact regression,
    # and it is the one a prose-level "asks first" would not prevent.
    assert_file_exists "$V_REPORT_SKILL" || return 1
    assert_file_not_empty "$V_REPORT_SKILL" 4000 || return 1

    local flat
    flat="$(flatten_file "$V_REPORT_SKILL")"

    assert_matches "$flat" 'gh issue create --repo myst4/kurama' \
        "the filing command names the upstream repo EXPLICITLY — no --repo means the user's own backlog" || return 1
    assert_matches "$flat" 'gh issue list --repo myst4/kurama.{0,120}--search' \
        "search upstream before filing — every user hitting one harness bug files the same issue" || return 1
    assert_matches "$flat" 'Nothing is created before an explicit yes' \
        "the approval gate as a blocking clause, not as advice" || return 1
    assert_matches "$flat" 'execution_mode: auto.{0,20}does not apply' \
        "auto mode does not authorize a write into a third-party repository" || return 1
    assert_matches "$flat" '(Report the URL|report the URL).{0,120}user' \
        "the filed issue's URL goes back to the user — a report they cannot find did not happen" || return 1

    # Gate 1 exists: the skill decides whose failure it is before collecting anything.
    local class
    for class in 'Installer' 'Hook' 'Skill contract' 'Phase envelope'; do
        assert_matches "$flat" "$class" \
            "the ownership table's '$class' row — how a Kurama failure is told apart from the project's" || return 1
    done
    assert_matches "$flat" 'If it is not Kurama.{0,120}issue-creation' \
        "the not-ours branch routes back to the host-repo skill instead of filing anyway" || return 1
    return 0
}

test_v_kurama_report_never_self_approves() {
    # What would make this pass for the wrong reason: a file-wide
    # `assert_not_matches status:approved` is INVERTED here — the skill must
    # discuss the label in order to forbid it, so the file-wide check would fail
    # on the very sentence that closes the hole. The actual `--label` arguments
    # are extracted and checked instead, and the extraction is floor-checked so
    # a renamed flag cannot make "no bad label found" vacuously true.
    local labels count=0 arg
    labels="$(grep -oE -- '--label "[^"]*"' "$V_REPORT_SKILL")"
    while IFS= read -r arg; do
        [ -n "$arg" ] || continue
        count=$((count + 1))
        case "$arg" in
            *status:approved*)
                echo "  kurama-report applies the maintainer's own approval label: $arg"
                return 1
                ;;
        esac
    done <<EOF
$labels
EOF
    if [ "$count" -lt 1 ]; then
        echo "  no --label argument found in kurama-report — the extractor or the skill changed shape,"
        echo "  and 'it never sets status:approved' would be vacuously true"
        return 1
    fi
    case "$labels" in
        *status:needs-review*) ;;
        *) echo "  kurama-report files without status:needs-review — the intake label the maintainer triages on"; return 1 ;;
    esac
    case "$labels" in
        *type:bug*) ;;
        *) echo "  kurama-report files without type:bug — the upstream repo's own bug taxonomy"; return 1 ;;
    esac

    # The rule is also stated, so the next editor knows the omission is deliberate.
    assert_matches "$(flatten_file "$V_REPORT_SKILL")" 'never set .status:approved' \
        "the prohibition written down where a future editor will read it" || return 1
    return 0
}

test_v_kurama_report_sanitizes_the_reproduction() {
    # What would make this pass for the wrong reason: "do not include sensitive
    # information" satisfies any loose grep about privacy and leaks everything.
    # Each forbidden CLASS is pinned by its own literal, and the MECHANISM is
    # pinned separately — advice without a redaction rule is what leaks, and
    # advice without a default direction leaks on every ambiguous fragment.
    local flat
    flat="$(flatten_file "$V_REPORT_SKILL")"

    assert_matches "$flat" '\.kurama-install-manifest\.json' \
        "the receipt is the source of the version/commit, not a guess" || return 1
    assert_matches "$flat" 'version.{0,40}commit.{0,200}scope' \
        "the four receipt fields that travel" || return 1

    assert_matches "$flat" 'path.{0,40}outside the Kurama install' \
        "banned: any path outside Kurama itself" || return 1
    assert_matches "$flat" 'Source code, specs, or diffs from the user' \
        "banned: the user's project source" || return 1
    assert_matches "$flat" 'Tokens, keys' \
        "banned: secrets and auth material" || return 1
    assert_matches "$flat" 'Whole log files' \
        "banned: dumping logs whose contents nobody read" || return 1

    assert_matches "$flat" 'repo root becomes .<repo>.' \
        "the redaction is MECHANICAL — a named substitution, not a judgment call" || return 1
    assert_matches "$flat" 'belongs to the project: leave' \
        "the default direction on an ambiguous fragment: leave it out" || return 1
    return 0
}

test_v_triage_carries_the_over_engineering_test() {
    # #86's load-bearing rule. What would make this pass for the wrong reason: a
    # heading that says "over-engineering test" with nothing testable under it.
    # All five triggers are pinned individually, plus the clause that makes a
    # single yes REJECT the design and the clause naming what a correct fix
    # usually does — without those two the five questions are a checklist you
    # can answer and then proceed anyway.
    assert_file_exists "$V_TRIAGE_SKILL" || return 1
    assert_file_not_empty "$V_TRIAGE_SKILL" 4000 || return 1

    local flat trigger
    flat="$(flatten_file "$V_TRIAGE_SKILL")"

    assert_matches "$flat" 'over-engineering test' \
        "the test is named, so a reader can be pointed at it" || return 1
    for trigger in 'state' 'flag' 'gate' 'verb'; do
        assert_matches "$flat" "new .{0,20}$trigger" \
            "the over-engineering trigger: a new $trigger" || return 1
    done
    # The fifth trigger is not phrased as "a new X" and must not be pattern-matched
    # as one: the thing it forbids is a SECOND copy of a fact that already exists,
    # which is the one of the five that reads as harmless.
    assert_matches "$flat" 'second representation.{0,4}of a fact' \
        "the over-engineering trigger: a second representation of an existing truth" || return 1
    assert_matches "$flat" 'Any yes rejects the design' \
        "one yes is enough to send the design back — otherwise the test is advisory" || return 1
    assert_matches "$flat" 'correct fix usually' \
        "what a fix that found the cause looks like: it deletes" || return 1
    return 0
}

test_v_triage_audits_every_worker_report() {
    # The rule ported from the sibling skill, and the one that matters more here
    # than upstream: Kurama delegates EVERY phase to a sub-agent whose
    # transcript the orchestrator never sees.
    #
    # What would make this pass for the wrong reason: "audit worker reports" as
    # a slogan. The three executable checks are pinned individually — re-run the
    # verification, read the diff, break the new guard — because a slogan with
    # no verb produces exactly the behavior it warns against.
    local flat
    flat="$(flatten_file "$V_TRIAGE_SKILL")"

    assert_matches "$flat" 'claim.{0,200}not evidence|is a .{0,20}claim' \
        "a self-report is a claim, not evidence" || return 1
    assert_matches "$flat" 'Re-run its verification yourself' \
        "check 1: run the worker's own verification command" || return 1
    assert_matches "$flat" 'Read the diff it produced' \
        "check 2: read the diff, not the summary of the diff" || return 1
    assert_matches "$flat" 'Break its new guard on purpose' \
        "check 3: a guard that does not fail on the planted shape is not a guard" || return 1
    assert_matches "$flat" 'Re-derive the numbers' \
        "check 4: counts and totals are claims too" || return 1
    return 0
}

test_v_triage_groups_by_root_and_ranks_by_removal() {
    # The partition itself, and the ladder that orders the fixes. What would
    # make this pass for the wrong reason: a class table with no one-fix-per-
    # root rule is just a labelling exercise — the N-patches outcome survives
    # it untouched. So the rule is pinned alongside the table, and the ladder is
    # pinned by its top and bottom rungs (delete first, new surface last).
    local flat class rung
    flat="$(flatten_file "$V_TRIAGE_SKILL")"

    for class in 'Already resolved' 'Shares a root' 'New root' 'Not a defect' 'Unreproducible'; do
        assert_matches "$flat" "$class" \
            "root class: $class" || return 1
    done
    assert_matches "$flat" 'N issues never justify N patches' \
        "the rule the table exists to serve: one root, one fix" || return 1
    assert_matches "$flat" 'mechanism.{0,40}is a hypothesis' \
        "the stated mechanism is a hypothesis; only the symptom is evidence" || return 1

    for rung in 'Delete the mechanism' 'Relax an over-strict rule' 'Add a static guard'; do
        assert_matches "$flat" "$rung" \
            "solution ladder rung: $rung" || return 1
    done
    assert_matches "$flat" '(flag, a state, a gate|Last resort)' \
        "new runtime surface is the LAST rung, and needs a written reason" || return 1
    assert_matches "$flat" 'one .sdd-new. cycle per root' \
        "the handoff: one cycle per root, never one per issue" || return 1
    return 0
}

test_v_both_skills_are_reachable_by_trigger_with_no_command_line() {
    # The routing decision, both halves. A skill nobody can invoke is installed
    # and dead; a slash-command line in five prompts costs bytes this repo does
    # not have (omp ships with 35 B of headroom), so both are reached by trigger
    # through the skill registry, exactly like sdd-brainstorm.
    #
    # What would make this pass for the wrong reason: a missing or truncated
    # prompt matches nothing, so "no /kurama-report anywhere" reads as a pass
    # over an empty file. Two guards, the same pair #104 used: every prompt is
    # size-floored, and `/sdd-learn` is asserted PRESENT as a positive control —
    # it is an optional-group skill that DOES carry a command line, so the grep
    # provably finds one when there is one.
    local f flat trig fm_flat

    for f in "$REPO_DIR/examples/claude-code/CLAUDE.md" \
             "$REPO_DIR/examples/pi/AGENTS.md" \
             "$REPO_DIR/examples/codex/agents.md" \
             "$REPO_DIR/examples/opencode/AGENTS.md" \
             "$REPO_DIR/examples/omp/AGENTS.md"; do
        assert_file_exists "$f" || return 1
        assert_file_not_empty "$f" 15000 || return 1
        flat="$(flatten_file "$f")"
        assert_matches "$flat" '/sdd-learn' \
            "${f##*/examples/}: the /sdd-learn command line (control for the two bans below)" || return 1
        assert_not_matches "$flat" '/kurama-report' \
            "${f##*/examples/}: a /kurama-report command line — the prompt budget has no room for one" || return 1
        assert_not_matches "$flat" '/systemic-issue-triage' \
            "${f##*/examples/}: a /systemic-issue-triage command line — same budget decision" || return 1
    done

    # Reached by trigger instead, which means the DESCRIPTION carries the phrases
    # a user actually says. Without them the skill is installed and unreachable.
    fm_flat="$(printf '%s\n' "$(skill_frontmatter "$V_TRIAGE_SKILL")" | tr '\n' ' ')"
    for trig in 'triage these issues' 'clasificá estos issues' 'root cause' 'sdd-new'; do
        case "$fm_flat" in
            *"$trig"*) ;;
            *) echo "  systemic-issue-triage: the description is missing the \"$trig\" trigger"; return 1 ;;
        esac
    done

    fm_flat="$(printf '%s\n' "$(skill_frontmatter "$V_REPORT_SKILL")" | tr '\n' ' ')"
    for trig in 'report this to kurama' 'reportá esto a kurama' 'the installer failed' 'issue-creation'; do
        case "$fm_flat" in
            *"$trig"*) ;;
            *) echo "  kurama-report: the description is missing the \"$trig\" trigger"; return 1 ;;
        esac
    done
    return 0
}

test_v_both_skills_are_well_formed_registered_and_default_on() {
    # Installed is not the same as loadable, and loadable is not the same as
    # reached. validate_skills.sh is the shipped gate for the first, so it is
    # RUN here rather than reimplemented — but running it proves nothing about
    # either new skill unless both are registered in the manifest it walks,
    # which is asserted first.
    #
    # What would make this pass for the wrong reason: asserting the directories
    # exist, which an empty leftover directory satisfies. Both files are byte-
    # floored and the total is pinned to EXPECTED_SKILLS, so adding a skill
    # without moving the counts cannot slip through.
    v_skill_is_registered "kurama-report" || return 1
    v_skill_is_registered "systemic-issue-triage" || return 1
    v_skill_frontmatter_is_well_formed "kurama-report" "$V_REPORT_SKILL" || return 1
    v_skill_frontmatter_is_well_formed "systemic-issue-triage" "$V_TRIAGE_SKILL" || return 1

    # Both join the `optional` group, which is in setup.sh's default active set,
    # so a plain install ships them with no flag.
    bash "$INSTALL_SCRIPT" --agent claude-code > /dev/null 2>&1
    local base="$HOME/.claude/skills"
    assert_file_not_empty "$base/kurama-report/SKILL.md" 4000 || return 1
    assert_file_not_empty "$base/systemic-issue-triage/SKILL.md" 4000 || return 1
    assert_eq "${#EXPECTED_SKILLS[@]}" "$(count_skill_files "$base")" \
        "the default set must be exactly the EXPECTED_SKILLS list, both new skills included" || return 1

    local output status=0
    output=$(bash "$VALIDATE_SCRIPT" 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
        echo "validate_skills.sh exited $status with the two new skills registered:"
        printf '%s\n' "$output" | grep -a 'FAIL' | head -5
        return 1
    fi
    return 0
}

echo -e "${BOLD}UNIT-V (issues #85, #86): the issue-skill split + root-cause triage${NC}"
run_test "issue-creation no longer reports Kurama's failures upstream" test_v_issue_creation_no_longer_reports_upstream
run_test "issue-creation discovers the host repo's templates and labels" test_v_issue_creation_discovers_the_host_repo
run_test "kurama-report targets myst4/kurama and stops for a human" test_v_kurama_report_targets_upstream_and_stops_for_a_human
run_test "kurama-report never applies status:approved" test_v_kurama_report_never_self_approves
run_test "kurama-report's reproduction carries nothing of the user's" test_v_kurama_report_sanitizes_the_reproduction
run_test "systemic-issue-triage carries the over-engineering test" test_v_triage_carries_the_over_engineering_test
run_test "systemic-issue-triage audits every worker's report" test_v_triage_audits_every_worker_report
run_test "systemic-issue-triage groups by root and ranks by removal" test_v_triage_groups_by_root_and_ranks_by_removal
run_test "no command line for either skill; both reached by trigger" test_v_both_skills_are_reachable_by_trigger_with_no_command_line
run_test "both are well-formed, registered and install by default" test_v_both_skills_are_well_formed_registered_and_default_on

echo ""

# ============================================================================
# UNIT-R (issue #109): the branch name carries the linked issue number
#
# `type/{issue}-{slug}` whenever a GitHub issue is in play — a kanban card, an
# issue `skills/issue-creation` filed, or a PR that will carry `Closes #N`. The
# rule is pure documentation: no script reads a branch name, so the shipped TEXT
# is the whole enforcement surface, and it breaks silently — a table row loses
# its issue-linked example, the chain section drifts back to naming the change
# instead of the issue, or `kanban-github`/`issue-creation` go on sending a
# reader to a branch name with no number in it. Nothing else in this file reads
# these four documents.
#
# The regex does NOT change — it always admitted digits — which is exactly why a
# regex-only check is worthless here: `feat/user-login` and `feat/104-gate` are
# both valid, so validity cannot tell whether the rule landed. Every case below
# pins the RULE and its examples instead; the one case that does use the regex
# takes it from the shipped doc and requires the issue-linked form to be among
# the names that doc actually shows.
#
# Mutation-checked: every case here fails against `git show origin/main:<file>`.
# ============================================================================

BRANCH_PR_SKILL="$REPO_DIR/skills/branch-pr/SKILL.md"
KANBAN_SKILL="$REPO_DIR/skills/kanban-github/SKILL.md"
ISSUE_SKILL="$REPO_DIR/skills/issue-creation/SKILL.md"
CONTRIBUTING_DOC="$REPO_DIR/CONTRIBUTING.md"

# The 11 types the branch regex admits, in the order the Branch Naming table
# lists them. The table is checked row by row against this list, so one surviving
# issue-linked example somewhere cannot stand in for the column.
BRANCH_TYPES=(feat fix chore docs style refactor perf test build ci revert)

# Print the body of the markdown section of file $1 whose heading line is exactly
# $2, up to the next `##`-level heading. Fenced blocks are tracked because the
# Chain Strategy section SHOWS a `### Chain` heading inside a ```markdown fence —
# a fence-blind scan would cut the section in half there and assert over the
# wrong text. Empty when the heading is gone, which every caller size-checks.
md_section() {
    local file="$1" heading="$2"
    [ -f "$file" ] || return 0
    awk -v h="$heading" '
        /^```/                                 { fence = !fence }
        !fence && $0 == h                      { f = 1; next }
        f && !fence && substr($0, 1, 2) == "##" { exit }
        f                                      { print }
    ' "$file"
}

# Fail unless $1 is a real section body rather than the empty string a renamed or
# deleted heading yields — every assertion over an empty haystack passes. $2 names
# the section, $3 is the byte floor.
assert_section_is_substantial() {
    local body="$1" what="$2" floor="$3"
    local bytes
    bytes=$(printf '%s' "$body" | wc -c | tr -d ' ')
    if [ "$bytes" -lt "$floor" ]; then
        echo "  $what came back ${bytes}B (floor ${floor}B) — the heading is gone or"
        echo "  renamed, and every assertion below it would pass over an empty string"
        return 1
    fi
    return 0
}

# Print every branch name the file $1 shows: one of the published types, a slash,
# then a non-blank run. Deliberately LOOSER than the branch regex — an extractor
# built from the regex's own character class could only ever yield names that
# match it, making "every example matches" true by construction. Backticks,
# quotes, commas and parens are blanked first so markup bounds a name, and
# placeholder forms (`{issue}`, `<description>`) are dropped: they are patterns,
# not names.
branch_names_shown() {
    [ -f "$1" ] || return 0
    sed "s/[\`\"'(),]/ /g" "$1" \
        | grep -oE '(feat|fix|chore|docs|style|refactor|perf|test|build|ci|revert)/[^[:space:]]+' \
        | grep -v '[{<]' || true
}

# Print the branch regex the doc $1 publishes, so the fixtures below exercise what
# ships instead of a copy that can drift away from it. The doc escapes the slash
# for readers (`\/`); POSIX leaves `\/` undefined inside an ERE, so it is
# unescaped here before any grep is handed the pattern.
published_branch_regex() {
    [ -f "$1" ] || return 0
    awk '
        index($0, "^(feat|fix|chore|docs|style|refactor|perf|test|build|ci|revert)") == 1 {
            sub(/\\\//, "/"); print; exit
        }
    ' "$1"
}

test_r_branch_pr_publishes_the_issue_linked_rule() {
    # Wrong-reason pass this guards against: "issue number" appears in prose all
    # over this file, so a whole-file grep for the words would stay green while
    # the table still showed nothing but issue-less examples. Everything here is
    # scoped to the Branch Naming section, and the table is checked one type row
    # at a time — the Chain or Commands section cannot answer for the column.
    local section
    section="$(md_section "$BRANCH_PR_SKILL" "## Branch Naming")"
    assert_section_is_substantial "$section" "branch-pr's Branch Naming section" 800 || return 1

    assert_matches "$section" 'type/\{issue\}-\{slug\}' \
        "the issue-linked branch form itself" || return 1
    assert_matches "$section" 'closes #n|refs #n' \
        "the trigger: the PR will carry Closes/Refs" || return 1
    assert_matches "$section" 'kanban card|issue-creation' \
        "the other two triggers: a kanban card, or skills/issue-creation" || return 1
    assert_matches "$section" 'type/\{slug\}' \
        "the unchanged no-issue form" || return 1

    # #99's rule applies to every grep in this section: herestring in, never a
    # pipe — `grep -q` exits on its first match and the writer takes SIGPIPE.
    local t missing=""
    for t in "${BRANCH_TYPES[@]}"; do
        if ! grep -Eq "\`$t/[0-9]+-[a-z0-9._-]+\`" <<<"$section"; then
            missing="$missing $t"
        fi
    done
    if [ -n "$missing" ]; then
        echo "  the examples table shows no issue-linked example for:$missing"
        return 1
    fi
    return 0
}

test_r_chain_units_are_numbered_by_their_issue() {
    # Wrong-reason pass this guards against: deleting the Chain Strategy section
    # outright would satisfy "it no longer says feat/{change}-{n}-{slug}". So the
    # section is size-checked before the negative assertion runs, and the form
    # that REPLACED it is asserted positively — together with the `{n}` fallback,
    # which survives only for a chain shipping under one issue.
    local section
    section="$(md_section "$BRANCH_PR_SKILL" "## Chain Strategy")"
    assert_section_is_substantial "$section" "branch-pr's Chain Strategy section" 1200 || return 1

    assert_not_matches "$section" 'feat/\{change\}-\{n\}-\{slug\}' \
        "the old chain pattern, which named the change instead of the issue" || return 1
    assert_not_matches "$section" 'authflow' \
        "the old change-id example branches" || return 1
    assert_matches "$section" 'one branch per work unit.*type/\{issue\}-\{slug\}' \
        "the chain's primary form: one unit, one issue, one number" || return 1
    assert_matches "$section" 'type/\{issue\}-\{n\}-\{slug\}' \
        "the {n} fallback, kept only for a chain shipping under ONE issue" || return 1
    assert_matches "$section" 'git checkout -b feat/[0-9]+-' \
        "the worked example, branching from a real issue number" || return 1
    return 0
}

test_r_pr_body_requires_branch_and_closes_to_agree() {
    # Wrong-reason pass this guards against: "branch" appears dozens of times in
    # this file — `--delete-branch`, "base branch", "rebased branch" — so a
    # whole-file grep for branch-plus-agreement would pass on the Post-approval
    # flow. The assertion is scoped to the Linked Issue subsection, where the rule
    # has to live to be read at PR-body time.
    local section
    section="$(md_section "$BRANCH_PR_SKILL" "### 1. Linked Issue (REQUIRED)")"
    assert_section_is_substantial "$section" "branch-pr's Linked Issue subsection" 400 || return 1

    assert_matches "$section" 'branch.*(agree|same|match)' \
        "the agreement rule: the branch number and the closing keyword are one issue" || return 1
    assert_matches "$section" 'type/\{issue\}-\{slug\}' \
        "the branch form the rule is about, named where the rule is stated" || return 1
    return 0
}

test_r_the_rule_reaches_every_doc_that_names_a_branch() {
    # Wrong-reason pass this guards against: three bare greps for the literal form
    # would each go green on a file that merely links to skills/branch-pr. Each
    # file is asserted to carry the form together with the context that makes it
    # actionable THERE — the card's number for kanban, THIS issue's number for
    # issue-creation, a concrete issue-linked example for CONTRIBUTING.
    local f
    for f in "$KANBAN_SKILL" "$ISSUE_SKILL" "$CONTRIBUTING_DOC"; do
        if [ ! -f "$f" ]; then
            echo "  missing document: $f"
            return 1
        fi
    done

    # Flattened: every rule below is a wrapped markdown bullet, so a line-oriented
    # match would miss it for a reason that has nothing to do with the rule.
    local kanban issue contributing
    kanban="$(flatten_file "$KANBAN_SKILL")"
    issue="$(flatten_file "$ISSUE_SKILL")"
    contributing="$(flatten_file "$CONTRIBUTING_DOC")"

    assert_matches "$kanban" 'card.{0,200}type/\{issue\}-\{slug\}' \
        "kanban-github: work taken from a card branches with the card's issue number" || return 1
    assert_matches "$issue" 'this issue.{0,200}type/\{issue\}-\{slug\}' \
        "issue-creation: the branch that follows carries the issue just filed" || return 1
    assert_matches "$contributing" 'type/\{issue\}-\{slug\}' \
        "CONTRIBUTING: the format a contributor is told to use" || return 1
    assert_matches "$contributing" '(feat|fix|docs)/[0-9]+-[a-z0-9._-]+' \
        "CONTRIBUTING: a concrete issue-linked example, not just the pattern" || return 1
    return 0
}

test_r_every_branch_example_matches_the_published_regex() {
    # Wrong-reason pass this guards against: an extractor that finds nothing makes
    # "every example matches" vacuously true, and the regex itself is unchanged by
    # #109 — so passing it is no evidence the rule landed. Both holes are closed:
    # the harvest is floor-checked, and at least one harvested name must be in the
    # issue-linked form, which is what origin/main has none of.
    local re
    re="$(published_branch_regex "$BRANCH_PR_SKILL")"
    if ! grep -q '^\^(feat|fix|chore' <<<"$re"; then
        echo "  the Branch Naming regex is no longer published where it was: '$re'"
        return 1
    fi

    # The four fixtures from #109, run against the regex the doc actually ships.
    local good bad
    for good in "fix/123-slug" "feat/104-2-second-unit"; do
        if ! grep -Eq "$re" <<<"$good"; then
            echo "  the published regex rejects the issue-linked form: $good"
            return 1
        fi
    done
    for bad in "Fix/123" "feat/123 slug"; do
        if grep -Eq "$re" <<<"$bad"; then
            echo "  the published regex accepts a malformed branch: $bad"
            return 1
        fi
    done

    local names count=0 issue_linked=0 offenders=""
    names="$(branch_names_shown "$BRANCH_PR_SKILL"; branch_names_shown "$CONTRIBUTING_DOC")"
    local n
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        count=$((count + 1))
        if ! grep -Eq "$re" <<<"$n"; then
            offenders="$offenders $n"
        fi
        if grep -Eq '^[a-z]+/[0-9]+-' <<<"$n"; then
            issue_linked=$((issue_linked + 1))
        fi
    done <<<"$names"

    if [ "$count" -lt 15 ]; then
        echo "  only $count branch names harvested from the two docs — the docs or the"
        echo "  extractor changed shape, and 'every example matches' would be vacuous"
        return 1
    fi
    if [ -n "$offenders" ]; then
        echo "  branch examples that do NOT match the published regex:$offenders"
        return 1
    fi
    if [ "$issue_linked" -lt 1 ]; then
        echo "  $count branch names shown and not one is type/{issue}-{slug} — the docs"
        echo "  publish a rule they never illustrate"
        return 1
    fi
    return 0
}

echo -e "${BOLD}UNIT-R (issue #109): branch names carry the linked issue number${NC}"
run_test "branch-pr publishes type/{issue}-{slug} + an issue-linked example per type" test_r_branch_pr_publishes_the_issue_linked_rule
run_test "chain units are numbered by their issue, not by the change" test_r_chain_units_are_numbered_by_their_issue
run_test "the PR body's branch number and Closes #N must agree" test_r_pr_body_requires_branch_and_closes_to_agree
run_test "the rule reaches kanban-github, issue-creation and CONTRIBUTING" test_r_the_rule_reaches_every_doc_that_names_a_branch
run_test "every branch example shown matches the published regex" test_r_every_branch_example_matches_the_published_regex

echo ""

# ============================================================================
# ===== UNIT-X (issue #90) =====
# Enforcement tiers: the two deterministic gates existed on Claude Code and
# nowhere else, and the four other harnesses got the same rules as prose. Two
# things are pinned here.
#
# 1. THE PORT. OpenCode's `tool.execute.before` can veto a tool call (throwing
#    aborts it), so both gates now reach OpenCode through a plugin. The plugin is
#    a THIN ADAPTER over the SAME two bash scripts — if it ever grows its own
#    copy of the active-cycle detection, the path exemptions or the verdict
#    parser, the two harnesses start enforcing two different contracts under one
#    name. So the tests below assert PARITY (identical block/allow decisions on
#    the same scenarios) rather than re-asserting the decisions themselves, plus
#    one structural test that the adapter has not absorbed the logic.
#
# 2. THE TIER STATEMENT. Where no veto primitive ships, the gap must be visible
#    BEFORE install — a per-harness row naming all five harnesses in README.md
#    and docs/hooks.md, each saying enforced or advisory. Those assertions are
#    mutation-checked against origin/main: the same check must FAIL on the
#    pre-change file, or it is not testing anything.
# ============================================================================

OPENCODE_PLUGIN="$REPO_DIR/examples/opencode/plugins/kurama-sdd-gates.ts"

# The driver that loads the shipped plugin and reports its decision. Written to a
# temp dir rather than committed: it is scaffolding for this suite, not an
# installed artifact. It fakes exactly the two things OpenCode supplies —
# `PluginInput.directory`, and a `client.session.get` that answers with (or
# without) a `parentID`, which is that harness's own subagent marker.
write_parity_driver() {
    cat > "$1" <<'PARITY_DRIVER'
import { pathToFileURL } from "node:url"

const [pluginPath, directory, kind, argsJson, parentID] = process.argv.slice(2)

const client = {
  session: {
    get: async () => ({ data: parentID ? { id: "s1", parentID } : { id: "s1" } }),
  },
}

let hooks
try {
  const mod = await import(pathToFileURL(pluginPath).href)
  const factory = mod.default ?? mod.KuramaSddGates
  hooks = await factory({ client, directory, project: {}, worktree: directory })
} catch (error) {
  console.error(`driver: ${error?.stack ?? error}`)
  process.exit(3)
}

const args = JSON.parse(argsJson)
try {
  if (kind === "command") {
    await hooks["command.execute.before"]({ command: args.command, sessionID: "s1", arguments: "" })
  } else {
    const tool = kind === "task" ? "task" : (args.__tool ?? "write")
    delete args.__tool
    await hooks["tool.execute.before"]({ tool, sessionID: "s1", callID: "c1" }, { args })
  }
  console.log("ALLOW")
} catch {
  console.log("BLOCK")
}
PARITY_DRIVER
}

# Node loads the plugin's TypeScript natively from 22.6 (behind
# --experimental-strip-types) and by default from 22.18/23. Probe once for a
# working invocation; an empty NODE_TS_CMD means "cannot run here", and the
# section below then reports a SKIP with the reason rather than a silent pass.
NODE_TS_CMD=()
PARITY_DRIVER_PATH=""
PARITY_DRIVER_DIR=""
probe_node_ts() {
    command -v node >/dev/null 2>&1 || return 0
    local probe="${TMPDIR:-/tmp}/kurama-ts-probe-$$.ts"
    printf 'const n: number = 1\nprocess.stdout.write(String(n))\n' > "$probe"
    if node --no-warnings "$probe" >/dev/null 2>&1; then
        NODE_TS_CMD=(node --no-warnings)
    elif node --no-warnings --experimental-strip-types "$probe" >/dev/null 2>&1; then
        NODE_TS_CMD=(node --no-warnings --experimental-strip-types)
    fi
    rm -f "$probe"
    return 0
}

# The plugin's decision for one scenario: "ALLOW" or "BLOCK".
#   $1 repo  $2 kind (write|task|command)  $3 args JSON  $4 optional parentID
plugin_decides() {
    local repo="$1" kind="$2" args="$3" parent="${4:-}"
    KURAMA_HOOKS_DIR="$REPO_DIR/examples/claude-code/hooks" \
        "${NODE_TS_CMD[@]}" "$PARITY_DRIVER_PATH" "$OPENCODE_PLUGIN" "$repo" "$kind" "$args" "$parent" \
        2>/dev/null | head -n 1
}

# The bash gate's decision for the SAME scenario, in the same two words, so the
# two sides are compared on one vocabulary.
bash_decides() {
    local hook="$1" payload="$2"
    run_hook "$hook" "$payload"
    if [ "$HOOK_STATUS" -eq 2 ]; then printf 'BLOCK'; else printf 'ALLOW'; fi
}

test_x_write_guard_parity_between_the_plugin_and_the_bash_hook() {
    # The four scenarios the bash write-guard tests already pin, driven through
    # the OpenCode plugin. What would make this pass for the wrong reason: a
    # plugin (or a driver) that answers ALLOW to everything — so each case also
    # pins what the bash side must say, and the mutation test below proves the
    # comparison can produce two different answers at all.
    local repo="$TEST_TMPDIR/x-guard"
    make_active_cycle_repo "$repo"

    local expected actual
    # (a) main-thread write to repository code, cycle active -> blocked.
    expected="$(bash_decides "$WRITE_GUARD_HOOK" "$(edit_payload "$repo" "src/widget.ts")")"
    actual="$(plugin_decides "$repo" write '{"__tool":"edit","filePath":"src/widget.ts"}')"
    assert_eq "BLOCK" "$expected" "precondition: the bash guard must block this write" || return 1
    assert_eq "$expected" "$actual" "plugin and bash guard must agree on a main-thread code write" || return 1

    # (b) the same write from a subagent -> allowed. On Claude Code the marker is
    #     a root agent_id; on OpenCode it is the session's parentID.
    expected="$(bash_decides "$WRITE_GUARD_HOOK" "$(edit_payload "$repo" "src/widget.ts" "agent_7")")"
    actual="$(plugin_decides "$repo" write '{"__tool":"edit","filePath":"src/widget.ts"}' "parent_1")"
    assert_eq "ALLOW" "$expected" "precondition: a subagent write must pass the bash guard" || return 1
    assert_eq "$expected" "$actual" "plugin and bash guard must agree on a delegated write" || return 1

    # (c) the SDD artifact paths stay writable mid-cycle.
    expected="$(bash_decides "$WRITE_GUARD_HOOK" "$(edit_payload "$repo" ".kurama/sdd/add-widget/state.md")")"
    actual="$(plugin_decides "$repo" write '{"__tool":"write","filePath":".kurama/sdd/add-widget/state.md"}')"
    assert_eq "ALLOW" "$expected" "precondition: the marker path must stay writable" || return 1
    assert_eq "$expected" "$actual" "plugin and bash guard must agree on an exempt path" || return 1

    # (d) no active cycle -> nothing is guarded at all.
    local clean="$TEST_TMPDIR/x-guard-clean"
    make_git_repo "$clean"
    mkdir -p "$clean/src"
    printf 'x\n' > "$clean/src/app.ts"
    expected="$(bash_decides "$WRITE_GUARD_HOOK" "$(edit_payload "$clean" "src/app.ts")")"
    actual="$(plugin_decides "$clean" write '{"__tool":"write","filePath":"src/app.ts"}')"
    assert_eq "ALLOW" "$expected" "precondition: a repo with no cycle must not be guarded" || return 1
    assert_eq "$expected" "$actual" "plugin and bash guard must agree when no cycle is active" || return 1
    return 0
}

test_x_archive_gate_parity_between_the_plugin_and_the_bash_hook() {
    # The gate reads the INVOKED IDENTITY (skill / subagent_type / description)
    # out of tool_input, so the adapter has to forward those exact fields —
    # OpenCode's task args for the Task spelling, the command name for the Skill
    # spelling. A field the gate does not read reads as "no identity at all", and
    # then every archive sails through while the tier table still says enforced.
    local repo="$TEST_TMPDIR/x-gate"
    make_active_cycle_repo "$repo"

    local expected actual
    # (a) no verify report -> the archive is refused (fails closed).
    expected="$(bash_decides "$ARCHIVE_GATE_HOOK" "$(skill_payload "$repo" sdd-archive)")"
    actual="$(plugin_decides "$repo" task '{"subagent_type":"sdd-archive"}')"
    assert_eq "BLOCK" "$expected" "precondition: no report means the bash gate is shut" || return 1
    assert_eq "$expected" "$actual" "plugin and bash gate must agree with no verify report" || return 1

    # (b) the slash-command door, which single-mode OpenCode uses instead of task.
    actual="$(plugin_decides "$repo" command '{"command":"sdd-archive"}')"
    assert_eq "$expected" "$actual" "the command path must reach the same gate as the task path" || return 1

    # (c) a PASS verdict opens it.
    write_verify_report "$repo" add-widget "PASS WITH WARNINGS"
    expected="$(bash_decides "$ARCHIVE_GATE_HOOK" "$(skill_payload "$repo" sdd-archive)")"
    actual="$(plugin_decides "$repo" task '{"subagent_type":"sdd-archive"}')"
    assert_eq "ALLOW" "$expected" "precondition: a PASS verdict must open the bash gate" || return 1
    assert_eq "$expected" "$actual" "plugin and bash gate must agree on a PASS verdict" || return 1

    # (d) a FAIL verdict shuts it again.
    write_verify_report "$repo" add-widget "FAIL"
    expected="$(bash_decides "$ARCHIVE_GATE_HOOK" "$(skill_payload "$repo" sdd-archive)")"
    actual="$(plugin_decides "$repo" task '{"subagent_type":"sdd-archive"}')"
    assert_eq "BLOCK" "$expected" "precondition: a FAIL verdict must shut the bash gate" || return 1
    assert_eq "$expected" "$actual" "plugin and bash gate must agree on a FAIL verdict" || return 1

    # (e) every other launch is none of the gate's business.
    expected="$(bash_decides "$ARCHIVE_GATE_HOOK" "$(skill_payload "$repo" sdd-apply)")"
    actual="$(plugin_decides "$repo" task '{"subagent_type":"sdd-apply"}')"
    assert_eq "ALLOW" "$expected" "precondition: an sdd-apply launch is not gated" || return 1
    assert_eq "$expected" "$actual" "plugin and bash gate must agree on a non-archive launch" || return 1
    return 0
}

test_x_the_parity_harness_can_actually_fail() {
    # The mutation check. Everything above compares two values; if the driver
    # returned a constant, or the plugin never reached the scripts, the
    # comparisons would agree for the wrong reason. So flip ONE input that must
    # change the decision — the same write, once as the main thread and once as a
    # subagent — and require the two answers to DIFFER. A harness that cannot
    # produce two different answers was never testing anything.
    local repo="$TEST_TMPDIR/x-mutation"
    make_active_cycle_repo "$repo"
    local main_thread subagent
    main_thread="$(plugin_decides "$repo" write '{"__tool":"edit","filePath":"src/widget.ts"}')"
    subagent="$(plugin_decides "$repo" write '{"__tool":"edit","filePath":"src/widget.ts"}' "parent_1")"
    assert_eq "BLOCK" "$main_thread" "the plugin must block a main-thread write during a cycle" || return 1
    assert_eq "ALLOW" "$subagent" "the plugin must allow the same write from a subagent" || return 1
    [ "$main_thread" != "$subagent" ] || {
        echo "the parity harness returns the same answer for both inputs — it is vacuous"; return 1; }
    return 0
}

test_x_the_plugin_is_an_adapter_not_a_second_implementation() {
    # The whole reason the port shells out: two implementations of these gates
    # drift, and the drift is silent because both harnesses go on reporting
    # "enforced". This test is the tripwire, and it needs no node.
    assert_file_exists "$OPENCODE_PLUGIN" || return 1
    local flat
    flat="$(flatten_file "$OPENCODE_PLUGIN")"

    assert_matches "$flat" 'orchestrator-write-guard\.sh' \
        "the plugin naming the write-guard script it delegates to" || return 1
    assert_matches "$flat" 'archive-gate\.sh' \
        "the plugin naming the archive-gate script it delegates to" || return 1
    assert_matches "$flat" 'spawn' \
        "the plugin running the gate as a process instead of reimplementing it" || return 1
    assert_matches "$flat" 'parentID' \
        "the OpenCode subagent marker the write guard needs" || return 1

    # And it must NOT carry a private copy of any gate decision. Each literal
    # below is load-bearing in exactly one of the two scripts; finding one here
    # means the logic has begun migrating out of them.
    local forbidden
    for forbidden in 'state\.yaml' 'archive-report\.md' 'Tree-Hash' 'PASS WITH WARNINGS' 'write-tree' 'openspec/changes'; do
        assert_not_matches "$flat" "$forbidden" \
            "a private copy of gate logic ($forbidden) — the decision stays in the bash scripts" || return 1
    done
    return 0
}

# --- the tier statement -----------------------------------------------------
# A doc assertion is only worth running if it would have failed before the
# change, so each one runs against origin/main's copy of the same file first.
# `git show` failing (a shallow clone, no origin) is REPORTED, never skipped
# silently — a missing baseline would turn the mutation check into a free pass.

# Every harness must have a row that both names it and assigns it a tier, on the
# SAME line. Matching the two words anywhere in the file would pass on prose that
# happens to use them; a per-harness row is the thing a reader actually acts on.
tier_rows_are_complete() {
    local file="$1" harness
    grep -qiE 'enforced' "$file" 2>/dev/null || return 1
    grep -qiE 'advisory' "$file" 2>/dev/null || return 1
    for harness in 'Claude Code' 'OpenCode' 'Codex' '(^|[^A-Za-z])Pi([^A-Za-z]|$)' '(^|[^A-Za-z])omp([^A-Za-z]|$)'; do
        grep -E "$harness" "$file" 2>/dev/null | grep -qiE 'enforced|advisory' || return 1
    done
    return 0
}

# Resolve a ref for main's tip and echo it, or echo nothing. `origin/main` is the
# local spelling; a CI checkout has none — actions/checkout fetches only the PR
# ref, so the mutation check had no baseline and the three tests below failed on
# ubuntu while passing locally. Fall back through the spellings that might exist,
# then fetch one commit. Resolved once and cached, since a fetch is not free.
BASELINE_REF=""
BASELINE_REF_RESOLVED=0
baseline_ref() {
    if [ "$BASELINE_REF_RESOLVED" -eq 0 ]; then
        BASELINE_REF_RESOLVED=1
        local ref
        for ref in origin/main refs/remotes/origin/main main; do
            if git -C "$REPO_DIR" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
                BASELINE_REF="$ref"
                break
            fi
        done
        if [ -z "$BASELINE_REF" ] \
            && git -C "$REPO_DIR" fetch --no-tags --depth=1 origin main >/dev/null 2>&1 \
            && git -C "$REPO_DIR" rev-parse --verify --quiet FETCH_HEAD >/dev/null 2>&1; then
            BASELINE_REF="FETCH_HEAD"
        fi
    fi
    printf '%s' "$BASELINE_REF"
}

assert_tier_rows_are_new_in() {
    local rel="$1"
    tier_rows_are_complete "$REPO_DIR/$rel" || {
        echo "$rel has no enforced/advisory row for all five harnesses"; return 1; }

    local ref
    ref="$(baseline_ref)"
    [ -n "$ref" ] || {
        echo "no ref for main's tip (tried origin/main, main, a shallow fetch) — the mutation check has no baseline"
        return 1; }

    local baseline
    baseline="$TEST_TMPDIR/baseline-$(basename "$rel")"
    if ! git -C "$REPO_DIR" show "$ref:$rel" > "$baseline" 2>/dev/null; then
        echo "could not read $ref:$rel — the mutation check has no baseline"
        return 1
    fi
    [ -s "$baseline" ] || {
        echo "$ref:$rel is empty — the mutation check has no baseline"; return 1; }
    if tier_rows_are_complete "$baseline"; then
        echo "$ref:$rel already satisfies this assertion — it does not test the change"
        return 1
    fi
    return 0
}

test_x_readme_states_the_enforcement_tier_per_harness() {
    # A user choosing a harness has to see, BEFORE installing, whether the two
    # gates are mechanism or prose there. The support matrix is where they look.
    assert_tier_rows_are_new_in "README.md" || return 1
    return 0
}

test_x_hooks_doc_states_the_enforcement_tier_per_harness() {
    # docs/hooks.md is the page that explains what the gates guarantee, so it is
    # the page that has to say where they do not.
    assert_tier_rows_are_new_in "docs/hooks.md" || return 1
    return 0
}

test_x_the_tier_statement_gives_a_reason_per_harness() {
    # A table of verdicts with no reasons is one nobody can act on or re-check.
    # Each tier has to name the primitive it was decided on — that is the claim a
    # future reader verifies against the harness when it ships a new version.
    local flat
    flat="$(flatten_file "$REPO_DIR/docs/hooks.md")"
    assert_matches "$flat" 'tool\.execute\.before' \
        "the OpenCode primitive the port rests on" || return 1
    assert_matches "$flat" 'tool_call' \
        "the Pi/omp primitive, named as verified even though no port ships yet" || return 1
    assert_matches "$flat" 'SessionStart' \
        "the Codex hook surface, named as the reason its tier is advisory" || return 1
    return 0
}

test_x_no_prompt_bytes_were_spent_on_the_tier_statement() {
    # The five generated orchestrator prompts are at their byte budget (omp has
    # tens of bytes of headroom), so the tier statement lives in docs and nowhere
    # else. This pins that it stayed there.
    local ref
    ref="$(baseline_ref)"
    [ -n "$ref" ] || {
        echo "no ref for main's tip — cannot tell whether a prompt changed"; return 1; }
    local f
    for f in "examples/omp/AGENTS.md" "examples/pi/AGENTS.md" "examples/opencode/AGENTS.md" \
             "examples/claude-code/CLAUDE.md" "examples/codex/agents.md" "examples/_templates"; do
        if ! git -C "$REPO_DIR" diff --quiet "$ref" -- "$f"; then
            echo "$f changed — the prompt budget is exhausted; the tier statement belongs in docs"
            return 1
        fi
    done
    return 0
}

echo -e "${BOLD}UNIT-X (issue #90): enforcement tiers${NC}"
run_test "the plugin is an adapter, not a second implementation" test_x_the_plugin_is_an_adapter_not_a_second_implementation
run_test "README states the enforcement tier per harness" test_x_readme_states_the_enforcement_tier_per_harness
run_test "docs/hooks.md states the enforcement tier per harness" test_x_hooks_doc_states_the_enforcement_tier_per_harness
run_test "each tier names the primitive it was decided on" test_x_the_tier_statement_gives_a_reason_per_harness
run_test "the tier statement cost zero prompt bytes" test_x_no_prompt_bytes_were_spent_on_the_tier_statement

probe_node_ts
if [ "${#NODE_TS_CMD[@]}" -gt 0 ]; then
    PARITY_DRIVER_DIR="$(mktemp -d)"
    PARITY_DRIVER_PATH="$PARITY_DRIVER_DIR/parity-driver.mjs"
    write_parity_driver "$PARITY_DRIVER_PATH"
    run_test "write guard: plugin and bash hook decide alike" test_x_write_guard_parity_between_the_plugin_and_the_bash_hook
    run_test "archive gate: plugin and bash hook decide alike" test_x_archive_gate_parity_between_the_plugin_and_the_bash_hook
    run_test "the parity harness can actually fail" test_x_the_parity_harness_can_actually_fail
    rm -rf "$PARITY_DRIVER_DIR"
else
    echo -e "  ${YELLOW}SKIP${NC} OpenCode plugin parity — node here cannot load TypeScript (needs node >= 22.6); the bash gates stay covered above"
fi

echo ""

# ============================================================================
# UNIT-Q (issues #87, #100): the envelope's Key Learnings closing, and reaping
# the sub-agent that sent it
#
# Two halves of the same cycle, both fixed in `skills/_shared/` — the contracts
# every generated orchestrator prompt already points at, so neither costs a byte
# of the 24000-byte prompt budget the omp prompt has 35 bytes left of.
#
# #87: Section D of sdd-phase-common.md is the ONE return contract every phase
# reads, and it ended at `skill_resolution` — so the gotchas a phase discovered
# died with its context. The closing `## Key Learnings` section is extracted
# VERBATIM by a memory engine, which is why its shape is pinned rather than left
# to taste.
#
# #100: the same contract said how to LAUNCH a sub-agent and never how to close
# it, so a finished agent stayed alive holding its whole context — observed an
# hour after it reported. Both the reap step AND its keep-alive exception are
# pinned, because a reap rule without the exception is a regression, not a fix.
# ============================================================================

test_q_envelope_closes_with_key_learnings() {
    # #87. Section D is the ONLY return contract every SDD phase reads, and it used to end at
    # `skill_resolution` — so every gotcha a phase discovered died with that phase's context.
    # The closing `## Key Learnings` section is what a memory engine extracts VERBATIM, with no
    # model re-reading it, which is why the shape is pinned here instead of left to taste: the
    # >= 20-character / >= 4-word floors are Engram's extraction thresholds, and an item under
    # either one is dropped in silence. The three rules that keep the section honest are pinned
    # for the same reason — each is a distinct failure mode. Omit-when-empty is what stops the
    # section from becoming padding that dilutes the real learnings; no-secrets/no-absolute-paths
    # is what stops passive capture from becoming a leak, since these lines are persisted and
    # re-read on other machines. And the two-store sentence is what stops the next reader from
    # "deduplicating" this against `sdd-learn`: Engram captures it passively for one developer,
    # `sdd-learn` curates the team's committed MEMORY.md from it — the section feeds both and
    # replaces neither.
    local common="$REPO_DIR/skills/_shared/sdd-phase-common.md"
    local docs="$REPO_DIR/docs/sub-agents.md"
    assert_file_exists "$common" || return 1
    assert_file_exists "$docs" || return 1

    # The literal heading a phase is told to emit. Anything else and the extractor's pattern
    # stops matching, which is exactly the silent failure this contract exists to prevent.
    grep -qF '## Key Learnings' "$common" \
        || { echo "sdd-phase-common.md never names the '## Key Learnings' closing section"; return 1; }

    # It has to live in Section D — the envelope contract — not in some section a phase agent
    # reading its return format would never reach.
    local d_line kl_line
    d_line=$(grep -n '^## D\. Return Envelope' "$common" | head -1 | cut -d: -f1 || true)
    kl_line=$(grep -n 'Key Learnings' "$common" | head -1 | cut -d: -f1 || true)
    if [ -z "$d_line" ]; then
        echo "sdd-phase-common.md lost its '## D. Return Envelope' heading — this test is stale"; return 1
    fi
    if [ -z "$kl_line" ] || [ "$kl_line" -le "$d_line" ]; then
        echo "Key Learnings does not sit inside Section D (envelope at line $d_line, learnings at ${kl_line:-none})"
        return 1
    fi

    # Everything from the contract's own subsection to the end of the file, flattened: every
    # rule below is a wrapped markdown bullet, and a line-oriented match would miss it for a
    # reason that has nothing to do with the contract.
    local kl
    kl=$(awk '/^### Key Learnings/ { f = 1 } f' "$common" | tr '\n' ' ')
    local kl_bytes
    kl_bytes=$(printf '%s' "$kl" | wc -c | tr -d ' ')
    if [ "$kl_bytes" -lt 400 ]; then
        echo "the Key Learnings subsection is ${kl_bytes}B — every assertion below would pass over nothing"
        return 1
    fi

    # The extraction thresholds, stated AS thresholds so nobody "simplifies" them later.
    case "$kl" in
        *"20 characters and 4 words"*) ;;
        *) echo "the Key Learnings contract dropped Engram's 20-character / 4-word extraction thresholds"; return 1 ;;
    esac
    case "$kl" in
        *"extraction threshold"*) ;;
        *) echo "the two numbers are stated without saying they are extraction thresholds"; return 1 ;;
    esac

    # Rule 1 — omit the section entirely when there is nothing non-obvious.
    case "$kl" in
        *"Omit the whole section"*) ;;
        *) echo "the Key Learnings contract lost the omit-when-empty rule"; return 1 ;;
    esac
    # Rule 2 — never restate what executive_summary already said.
    case "$kl" in
        *"Never restate the phase"*) ;;
        *) echo "the Key Learnings contract lost the do-not-restate-the-main-output rule"; return 1 ;;
    esac
    # Rule 3 — no secrets, no absolute machine paths.
    case "$kl" in
        *"secret"*) ;;
        *) echo "the Key Learnings contract no longer forbids writing secrets"; return 1 ;;
    esac
    case "$kl" in
        *"absolute machine path"*) ;;
        *) echo "the Key Learnings contract no longer forbids absolute machine paths"; return 1 ;;
    esac

    # Both memory stores, and the boundary between them, named where the phase reads it.
    case "$kl" in
        *"Engram"*) ;;
        *) echo "the Key Learnings contract never says Engram captures the section passively"; return 1 ;;
    esac
    case "$kl" in
        *"sdd-learn"*) ;;
        *) echo "the Key Learnings contract never names sdd-learn as the other consumer"; return 1 ;;
    esac
    case "$kl" in
        *"MEMORY.md"*) ;;
        *) echo "the Key Learnings contract never names the team file sdd-learn curates"; return 1 ;;
    esac
    case "$kl" in
        *"docs/persistence.md"*) ;;
        *) echo "the Key Learnings contract does not point at the four-store boundary table"; return 1 ;;
    esac

    # The docs describe the envelope too, and a contract documented in only one of the two
    # places is the drift this repo keeps a docs gate for.
    local docs_flat
    docs_flat=$(tr '\n' ' ' < "$docs")
    case "$docs_flat" in
        *"Key Learnings"*) ;;
        *) echo "docs/sub-agents.md describes the envelope without its Key Learnings closing"; return 1 ;;
    esac
    case "$docs_flat" in
        *"omitted entirely"*) ;;
        *) echo "docs/sub-agents.md never states the omit-when-empty rule"; return 1 ;;
    esac
    case "$docs_flat" in
        *"sdd-learn"*) ;;
        *) echo "docs/sub-agents.md never relates Key Learnings to sdd-learn"; return 1 ;;
    esac
    return 0
}

test_q_delegation_contract_reaps_finished_subagents() {
    # #100. The delegation contract told the orchestrator how to LAUNCH a sub-agent and never
    # how to close it, so a finished agent stayed alive holding its whole context — observed an
    # hour after it reported. That is a leak by omission which gets worse the better the
    # orchestrator pattern works: eight correctly delegated phases end the session with eight
    # idle agents, and the bookkeeping lands back on the user.
    #
    # The fix is contract-level and harness-agnostic, which is why it is asserted in
    # `skill-resolver.md` — the canonical file every generated prompt already points at — and
    # not in the prompts, whose 24000-byte budget has no room left.
    #
    # BOTH halves are asserted on purpose. A reap rule without its exception is a regression,
    # not a fix: resuming an agent preserves the context it built, and an orchestrator that
    # kills every agent on sight has to re-derive that context in a fresh one. The exception is
    # bounded by an INTENT the orchestrator states out loud when it takes it — "might need it
    # later" is not one — so the two assertions have to travel together.
    local resolver="$REPO_DIR/skills/_shared/skill-resolver.md"
    assert_file_exists "$resolver" || return 1

    local flat
    flat=$(tr '\n' ' ' < "$resolver")

    # Half 1 — the reap step itself, as a step of the launch/return cycle.
    grep -qi '^### Step 5.*Reap' "$resolver" \
        || { echo "skill-resolver.md has no Step 5 that reaps the sub-agent"; return 1; }
    case "$flat" in
        *"delegation is not complete"*) ;;
        *) echo "skill-resolver.md never says the delegation is incomplete until the agent is shut down"; return 1 ;;
    esac
    # The Claude Code primitive, named — a contract that says "close it somehow" closes nothing.
    case "$flat" in
        *"shutdown request to"*) ;;
        *) echo "skill-resolver.md does not name the Claude Code shutdown request to the teammate"; return 1 ;;
    esac
    # And the harnesses that have no primitive: the reap is holding no reference, said out loud.
    case "$flat" in
        *"no such primitive"*) ;;
        *) echo "skill-resolver.md has no branch for harnesses without a termination primitive"; return 1 ;;
    esac
    case "$flat" in
        *"hold no reference"*) ;;
        *) echo "skill-resolver.md never defines the reap on a harness that cannot terminate an agent"; return 1 ;;
    esac

    # Half 2 — the keep-alive exception. Without this the resume pattern is banned outright.
    case "$flat" in
        *"The one exception"*) ;;
        *) echo "skill-resolver.md states a reap rule with no keep-alive exception — this bans resuming an agent"; return 1 ;;
    esac
    case "$flat" in
        *"follow-up"*) ;;
        *) echo "the keep-alive exception never names the intended follow-up that justifies it"; return 1 ;;
    esac
    case "$flat" in
        *"name the intent"*) ;;
        *) echo "the keep-alive exception is unbounded — the orchestrator never has to state the intent"; return 1 ;;
    esac

    # The three meta-skills are the surfaces that actually delegate a phase; each must close the
    # cycle it opens and point at the one canonical home instead of restating the rule.
    local skill f
    for skill in sdd-new sdd-ff sdd-continue; do
        f="$REPO_DIR/skills/$skill/SKILL.md"
        assert_file_exists "$f" || return 1
        grep -qi 'reap' "$f" \
            || { echo "$skill/SKILL.md delegates a phase and never reaps the agent"; return 1; }
        grep -qF 'skill-resolver.md' "$f" \
            || { echo "$skill/SKILL.md restates the reap rule instead of pointing at skill-resolver.md"; return 1; }
        grep -qF 'Step 5' "$f" \
            || { echo "$skill/SKILL.md does not point at the reap step by name"; return 1; }
    done
    return 0
}

echo -e "${BOLD}UNIT-Q (issues #87, #100): Key Learnings + sub-agent reaping${NC}"
run_test "the envelope closes with Key Learnings (#87)" test_q_envelope_closes_with_key_learnings
run_test "the delegation contract reaps finished agents (#100)" test_q_delegation_contract_reaps_finished_subagents

echo ""

# ============================================================================
# Summary
# ============================================================================

echo -e "${BOLD}════════════════════════════════════════════${NC}"
echo -e "${BOLD}Results: $TESTS_PASSED/$TESTS_RUN passed${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "${RED}${BOLD}$TESTS_FAILED test(s) failed:${NC}${FAILURES}"
    exit 1
fi
echo -e "${GREEN}${BOLD}All tests passed!${NC}"
echo ""
