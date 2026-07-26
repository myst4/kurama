# Project Commands (shared across SDD skills)

The ONE canonical home for the project's test and build commands. `sdd-apply`,
`sdd-verify`, and the `tdd` module all resolve commands through this file instead
of carrying their own detection chains — one source, zero drift.

## The commands are CONFIGURED, not detected

Kurama is stack-agnostic: it knows the SHAPE of the contract, never the values.
Four commands steer the cycle, and their home is the project config
(`rules.verify.test_command`, `rules.verify.build_command`,
`tdd.single_test_command`) plus whatever the orchestrator propagates:

| Command | Used by | Purpose |
|---------|---------|---------|
| Full suite | `sdd-verify` Step 5b | behavioral validation of every MUST scenario |
| Single test | `sdd-apply` (TDD mode), `tdd` | one test/file — keeps the RED → GREEN loop tight |
| Build / type-check | `sdd-verify` Step 5c | compile and type errors the suite may not surface |
| Golden / snapshot update | `sdd-apply` | regenerate fixtures, only where the project supports it |

`sdd-init` ASKS the user for these and records them. That question is the primary
path — the same doctrine as `tdd.enabled` and `execution_mode`: an explicit answer,
never a silent inference. Any stack works, including one this file has never heard
of, because the harness carries no list of supported ecosystems.

## Resolution precedence

1. **Configured / propagated command wins.** A value propagated in the phase prompt
   beats a stale file value, same as every other pipeline setting. Otherwise read it
   from the project config.
2. **Nothing configured → report "no command configured". NEVER guess.**
   `sdd-verify` maps a missing test command to WARNING in `static` mode and CRITICAL
   in `behavioral` mode; a missing build command is always WARNING. `sdd-apply`
   reports that tests could not be run automatically. The fix is always the same:
   re-run `/sdd-init` (or set the key directly) — never a guessed command, which
   fails opaquely or, worse, runs the wrong thing.

## Suggestion table (defaults offered at init — NOT a supported-stack list)

`sdd-init` MAY consult this table to PRE-FILL its question with a likely default
when a detection file is present. It is a convenience for the common cases and
carries no authority: the user's answer always wins, an absent row is not an error,
and NO phase may resolve a command from this table on its own.

SWAP 29.=43:
| Detection file | Ecosystem | Full-suite | Single test | Build / type-check | Golden / snapshot |
|----------------|-----------|------------|-------------|--------------------|-------------------|
| `go.mod` | Go | `go test ./...` | `go test -run TestName ./path/to/pkg` | `go build ./...` (`go vet ./...`) | `-update` (project's flag convention) |
| `package.json` (Vitest) | Node / Vitest | `vitest run` | `vitest run path/to/file.test.ts -t "test name"` | `scripts.build`; `tsc --noEmit` with a `tsconfig.json` | `vitest run -u` |
| `package.json` (Jest) | Node / Jest | `jest` | `jest path/to/file.test.ts -t "test name"` | `scripts.build`; `tsc --noEmit` with a `tsconfig.json` | `jest -u` |
| `package.json` (`scripts.test`) | Node (generic) | `npm test` | `npm test -- path/to/file.test.ts` | `npm run build` | runner-dependent |
| `pyproject.toml` / `pytest.ini` / `setup.cfg` | Python / pytest | `pytest` | `pytest path/to/test_x.py::TestClass::test_name` | `python -m build`; `mypy .` where configured | `pytest --snapshot-update` (syrupy) |
| `Cargo.toml` | Rust | `cargo test` | `cargo test test_name` | `cargo build` (`cargo check`) | `cargo insta review` (insta) |
| `Gemfile` (RSpec) | Ruby / RSpec | `bundle exec rspec` | `bundle exec rspec path/to/spec.rb:LINE` | — (`bundle exec rubocop` where configured) | — |
| `Gemfile` (Rails / minitest) | Ruby / minitest | `bin/rails test` | `bin/rails test path/to/test.rb:LINE` | `bin/rails zeitwerk:check` where available | — |
| `build.gradle` / `build.gradle.kts` | JVM / Gradle | `./gradlew test` | `./gradlew test --tests "com.pkg.ClassTest.method"` | `./gradlew build` | — |
| `pom.xml` | JVM / Maven | `mvn test` | `mvn test -Dtest=ClassTest#method` | `mvn package` | — |
| `mix.exs` | Elixir | `mix test` | `mix test path/to/test.exs:LINE` | `mix compile --warnings-as-errors` | — |
| `composer.json` | PHP | `composer test` (or `vendor/bin/phpunit`) | `vendor/bin/phpunit --filter testName` | — (`vendor/bin/phpstan` where configured) | — |
| `*.csproj` / `*.sln` | .NET | `dotnet test` | `dotnet test --filter FullyQualifiedName~Name` | `dotnet build` | — |
| `Makefile` (has a `test` target) | Make wrapper | `make test` | (no standard single-test target) | `make build` where the target exists | — |
| _anything else_ | Any stack | **ask the user** | **ask the user** | **ask the user** | **ask the user** |

## Notes

- The suggestion table is a courtesy, not a contract. A stack that is absent from it
  is fully supported — its commands come from the user's answer at `sdd-init` like
  every other stack's. NEVER treat an absent row as "unsupported" or as a reason to
  fail a phase.
- `Makefile` is a wrapper, not an ecosystem: prefer a concrete runner detected above
  it when both exist; suggest `make test` only when it is the sole signal.
- A detection file can match more than one row (`package.json` → Vitest vs Jest,
  `Gemfile` → RSpec vs minitest). Inspect the manifest to pick the likelier default,
  and let the user correct it — that is what the question is for.
- Blank cells mean the ecosystem has no single conventional command, not that the
  step is skipped. Ask instead of inventing one.
- Golden/snapshot flags apply only when that plugin is actually in use; do not assume
  it. When unsure, do not run an update flag — regenerating fixtures blindly can mask
  a real regression.
- Single-test commands serve the tight TDD loop (`skills/tdd/SKILL.md`); the
  full-suite command is what `sdd-verify` executes for behavioral evidence.
