# The jq-less fallbacks actually work

Date: 2026-08-10
Status: approved, ready for implementation

## Problem

`README.md:313` advertises Kurama as zero-dependency. Measured on v6.0.0 with a PATH that
contains everything except `jq`, three scripts exit non-zero:

| Script | Result without jq |
| --- | --- |
| `setup.sh` | `✗ No skills resolved from …/skills/manifest.json — is this a complete clone?`, exit 1 |
| `install.sh` | `✗ No skills selected — could not read …/skills/manifest.json`, exit 1 |
| `validate_skills.sh` | `[FAIL] skills/manifest.json has no skills[] entries`, exit 1 |

All three share one defect. `manifest_skill_lines()` falls back to an awk that only prints when
it finds `"name"` **and** `"group"` on the same line — its own comment says so. But
`skills/manifest.json` is pretty-printed with them on separate lines, so the awk emits 0 skills
where jq emits 25. The diagnosis each script then prints blames the user's checkout.

The failure is invisible to whoever develops this: macOS has shipped `jq` in `/usr/bin` since
macOS 15, so the awk branch never runs on a Mac. It bites on Linux without jq.

A second defect shares the cause — an awk branch nothing ever exercised. The receipt array
parser opens with `{ inarr = 1; next }`, which skips the closing-bracket check on the opening
line, so a single-line `"key": []` makes it consume the rest of the file. Measured against a
real receipt mutated to `"files": []`:

```
jq:  (no output)
awk: settings: [
     .claude/settings.json
```

It emits the *next key's declaration line* as if it were a path, then paths belonging to that
other key. `uninstall.sh` drives `rm` from `files[]` and `finalize_receipt` merges what it reads
back, so the shape of this failure is `.claude/settings.json` migrating from `settings[]` into
`files[]` — turning a surgical hooks-block strip into deleting the user's settings.json. No
writer in this repo emits a single-line array, so it is latent; it is fixed here because the
blast radius is data loss and the fix is three lines.

`install_test.sh` has no jq-absent coverage. It has three restricted-PATH symlink farms and
every one of them deliberately links `jq` in. The pattern for proving a missing dependency is
well established there — `# Deliberately DO NOT link pi (or npm) into the farm.`,
`# Deliberately DO NOT link git into the farm.` — jq was simply never the subject. That absence
is why both defects shipped.

## Design

### The canonical skills-manifest parser

`manifest_skill_lines()` is replaced in all three copies with a parser that tracks object
boundaries instead of assuming one line per skill. All three copies must be byte-identical —
there is no shared library, and the copies are kept in sync by comment convention.

```awk
awk '
    !inarr && /"skills"[[:space:]]*:[[:space:]]*\[/ { inarr = 1; next }
    inarr && /^[[:space:]]*\]/                      { inarr = 0; next }
    inarr && /\{/                                   { name = ""; group = "" }
    inarr {
        if (match($0, /"name"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
            s = substr($0, RSTART, RLENGTH); sub(/.*:[[:space:]]*"/, "", s); sub(/".*/, "", s); name = s
        }
        if (match($0, /"group"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
            g = substr($0, RSTART, RLENGTH); sub(/.*:[[:space:]]*"/, "", g); sub(/".*/, "", g); group = g
        }
    }
    inarr && /\}/ {
        if (name != "" && group != "") print name " " group
        name = ""; group = ""
    }
' "$MANIFEST_FILE"
```

Three properties matter and must be preserved by anyone editing it:

- **`!inarr` on the opening rule.** `skills/manifest.json` also has `groups` and `targets`
  objects; without the guard a nested `"skills"` key elsewhere would re-open the array.
- **The closing rule anchors on a line that is only `]`.** A bare `/\]/` would also match a `]`
  inside a value.
- **Rule order handles a one-line object.** For `{"name":"x","group":"y"}` the reset, the
  capture and the print all fire on that single line, in that order.

### The receipt array parser

The opening rule must handle a `]` on the same line. In all copies — `setup.sh`, `update.sh`,
`doctor.sh`, `uninstall.sh`, `setup-tui.sh` — the opening rule becomes:

```awk
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
```

The rest of each parser is unchanged. `!inarr` is added for the same reason as above.

### The diagnosis

`setup.sh:691`, `install.sh` and `validate_skills.sh` currently blame the checkout. Each gains a
jq-aware branch: when the manifest exists and is non-empty but no skills were resolved **and**
`jq` is absent, say so and name jq, rather than accusing the user's clone. When jq *is* present
the existing message is correct and stays.

### Shellcheck

`shellcheck scripts/*.sh` exits non-zero on any finding, so the CI check has been red on every
PR including #8, #9 and #10. Four findings stand between it and green:

- `SC2034` — `OS` assigned and never read, in `doctor.sh:54`, `uninstall.sh:42`, `update.sh:51`
- `SC2015` — `[ -n "$src" ] && [ -f "$src" ] || continue` in `doctor.sh:265` (introduced by #11)

Both are fixed here. The `OS` variable is either used or removed, whichever the surrounding code
makes honest; the `A && B || C` becomes an explicit `if`.

### Coverage

New cases in `install_test.sh` built on the farm pattern the file already uses, with `jq`
deliberately omitted and a guard asserting `command -v jq` is empty under it:

- `setup.sh --agent claude-code --scope project` installs cleanly without jq: exit 0, all skills
  present, receipt written
- the same for `--agent opencode`
- `validate_skills.sh` exits 0 without jq
- the receipt array parser returns nothing for a single-line `"files": []` — the regression that
  would otherwise migrate `settings.json` into `files[]`

## Out of scope — found by the audit, filed separately

These are real and measured, but they are not the jq parser defect and each deserves its own
change:

1. **`doctor.sh` cannot detect an unconfigured opencode install.** A global opencode install with
   no `opencode.json` — zero agents registered, 9 commands pointing at agents that do not exist —
   produces output byte-identical to a healthy one, `Healthy with 1 warning(s)`, exit 0. doctor
   catches the equivalent for claude-code. It has no opencode registration check at all.
2. **An aborted install strands files.** `setup.sh` copies `_shared` before it can fail on skill
   resolution and writes no receipt, leaving 8 orphan files that no Kurama tooling can reach,
   since `uninstall.sh` is receipt-driven.
3. **`orchestrator-write-guard.sh` changes behavior without jq.** Its `agent_id` extraction falls
   back to `sed 's/"tool_input".*//'`, which depends on `agent_id` being serialized before
   `tool_input` — JSON key order is not guaranteed. Measured: a subagent payload with the keys in
   the other order is blocked where jq would allow it. It fails closed, so not a security hole,
   but on a jq-less machine it could deadlock every delegated writer. `archive-gate.sh` shares the
   helper and may diverge the same way; that was not executed.
4. **A receipt can record a file setup never created** — global claude-code without jq degrades
   the hooks merge correctly but still writes `"settings": ["../settings.json"]` for a file that
   does not exist. doctor does not notice because it checks `files[]`, not `settings[]`.
5. **`--with-engram` without jq writes `{"engram":"yes","engram_mcp":[]}`** and the summary still
   prints `Engram: enabled … (MCP registered per client)` when nothing was registered. `doctor.sh`
   is already self-aware here; the summary is not.
6. **`README.md:313`** should stop saying zero-dependency, or say what jq buys.
