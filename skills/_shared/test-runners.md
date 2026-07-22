# Test Runner Detection (shared across SDD skills)

The ONE canonical map from an ecosystem's detection file to its test commands.
`sdd-apply`, `sdd-verify`, and the `tdd` module all read this table instead of
carrying their own detection chains — one source, zero drift.

Each row gives three things:

- **Full-suite command** — run everything. Used by `sdd-verify` (Step 5b) for
  behavioral validation.
- **Single-test command** — run ONE test or file. Critical for the TDD RED cycle:
  a fast single-test run is what keeps RED → GREEN tight. Used by `sdd-apply` in
  TDD mode and by the "run ONLY the relevant test/suite" rule.
- **Golden-file update flag** — how to regenerate snapshot/golden fixtures where
  the ecosystem (or a common plugin) supports it. Blank = not standard.

## Resolution precedence

1. **Configured / propagated command wins.** If `rules.verify.test_command` is set
   (in `openspec/config.yaml` or propagated by the orchestrator in the phase
   prompt), use it as the full-suite command. If `tdd.single_test_command` is set,
   use it as the single-test command. A propagated value beats a stale file value,
   same as every other pipeline setting.
2. **Otherwise detect** from the table below (first matching file wins).
3. **Nothing detected → report "no runner detected". NEVER guess a command.**
   `sdd-verify` maps this to WARNING in `static` mode and CRITICAL in `behavioral`
   mode; `sdd-apply` reports that tests could not be run automatically.

## Runner table

| Detection file | Ecosystem | Full-suite command | Single-test command | Golden / snapshot update |
|----------------|-----------|--------------------|--------------------|--------------------------|
| `go.mod` | Go | `go test ./...` | `go test -run TestName ./path/to/pkg` | `go test -run TestName ./path/to/pkg -update` (project's `-update` flag convention) |
| `package.json` (Vitest) | Node / Vitest | `vitest run` | `vitest run path/to/file.test.ts -t "test name"` | `vitest run -u` (`--update`) |
| `package.json` (Jest) | Node / Jest | `jest` | `jest path/to/file.test.ts -t "test name"` | `jest -u` (`--updateSnapshot`) |
| `package.json` (`scripts.test`) | Node (generic) | `npm test` | `npm test -- path/to/file.test.ts` (runner-dependent) | runner-dependent |
| `pyproject.toml` / `pytest.ini` / `setup.cfg` | Python / pytest | `pytest` | `pytest path/to/test_x.py::TestClass::test_name` (or `-k "name"`) | `pytest --snapshot-update` (syrupy) — plugin-dependent |
| `Cargo.toml` | Rust | `cargo test` | `cargo test test_name` | `cargo insta review` / `INSTA_UPDATE=always` (insta) — plugin-dependent |
| `build.gradle` / `build.gradle.kts` | JVM / Gradle | `./gradlew test` | `./gradlew test --tests "com.pkg.ClassTest.method"` | — |
| `pom.xml` | JVM / Maven | `mvn test` | `mvn test -Dtest=ClassTest#method` | — |
| `mix.exs` | Elixir | `mix test` | `mix test path/to/test.exs:LINE` | — |
| `Makefile` (has a `test` target) | Make wrapper | `make test` | (no standard single-test target — fall through to the underlying runner if one is detectable, else run the suite) | — |
| _none of the above_ | Fallback | **report "no runner detected"** | **report "no runner detected"** | — |

## Notes

- `Makefile` is a wrapper, not an ecosystem: prefer a concrete runner detected
  above it when both exist; use `make test` only when it is the sole signal.
- `package.json` can match more than one row — inspect `devDependencies` /
  `scripts.test` to pick Vitest vs Jest before falling back to the generic
  `npm test`.
- Golden/snapshot flags marked "plugin-dependent" only apply when that plugin is
  actually in use; do not assume it. When unsure, do not run an update flag —
  regenerating fixtures blindly can mask a real regression.
- Single-test commands are for the tight TDD loop (`skills/tdd/SKILL.md`); the
  full-suite command is what `sdd-verify` executes for behavioral evidence.
