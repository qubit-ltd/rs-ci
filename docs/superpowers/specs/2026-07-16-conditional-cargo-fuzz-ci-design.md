# Conditional cargo-fuzz CI Design

## Goal

Add an automatic cargo-fuzz smoke check to the shared Rust CI system while
keeping projects that do not use cargo-fuzz unchanged. The local
`ci-check.sh`, reusable GitHub Actions workflow, and CircleCI template must use
the same detection and execution rules.

## Scope

The change will:

- detect conventional `fuzz/Cargo.toml` packages that declare
  `cargo-fuzz = true` under package metadata;
- compile every target reported by `cargo fuzz list`;
- optionally run every target for a bounded smoke-test duration;
- use a pinned nightly toolchain independently of the stable build toolchain;
- preserve crash artifacts for diagnosis;
- document all configuration and installation requirements;
- add script-level tests that do not invoke a real fuzzer.

The change will not:

- run an unbounded fuzzing campaign from `ci-check.sh`;
- add fuzz coverage to the normal `cargo-llvm-cov` report;
- audit the independent `fuzz/Cargo.lock` as part of this feature;
- run cargo-fuzz on Windows or add a long-running scheduled fuzz job;
- infer non-standard fuzz package locations.

## Detection

The shared check considers a project cargo-fuzz-enabled only when
`<project-root>/fuzz/Cargo.toml` exists and its package metadata contains the
standard `cargo-fuzz = true` marker. A project without that marker exits the
fuzz check successfully with an explicit skip message.

Detection is centralized in a new `cargo-fuzz-check.sh` script so local and
hosted CI cannot drift. The helper accepts `RS_CI_PROJECT_ROOT`, follows the
same Cargo environment established by its caller, and does not modify the
project configuration. Its `--is-configured` preflight exits successfully only
when the standard marker is present, allowing callers to avoid installing the
nightly toolchain and `cargo-fuzz` for projects that do not opt in.

## Execution Modes

`RS_CI_FUZZ_MODE` supports three values:

- `smoke` (default): build and run every fuzz target;
- `build-only`: build every fuzz target without executing libFuzzer;
- `disabled`: explicitly skip cargo-fuzz even when the marker is present.

Disabled mode also bypasses cargo-fuzz toolchain and executable setup in local
and hosted CI.

For `smoke`, `RS_CI_FUZZ_SECONDS_PER_TARGET` defaults to 10 and must be a
positive integer. Each target runs with libFuzzer's `-max_total_time` bound.
Target names come exclusively from `cargo fuzz list` and are passed as quoted
arguments.

The helper creates a temporary writable corpus for every target. When a
project has a committed `fuzz/corpus/<target>` directory, it is supplied as an
additional seed corpus. This prevents normal smoke runs from adding generated
corpus files to the repository. Crash artifacts remain under
`fuzz/artifacts/` so hosted CI can upload them after failure.

An enabled fuzz package with no reported targets is a configuration error.
Compilation failures, target crashes, panics, timeouts reported by libFuzzer,
and invalid configuration all fail the check.

## Toolchains and Tools

`RS_CI_FUZZ_TOOLCHAIN` selects the cargo-fuzz toolchain and defaults to the
same pinned nightly used for linting. It is intentionally independent of
`RS_CI_BUILD_TOOLCHAIN`, because cargo-fuzz requires nightly sanitizer flags.

Local `ci-check.sh` installs or completes the configured Rust toolchain using
the existing `ensure_toolchain` function. It only requires the `cargo-fuzz`
executable after detecting an enabled fuzz package. If the executable is
missing, the check fails with a concise `cargo install cargo-fuzz` instruction;
projects without cargo-fuzz do not acquire this requirement.

Hosted CI installs a pinned cargo-fuzz version only after detection. The
reusable GitHub workflow exposes the version, toolchain, mode, and per-target
duration as workflow inputs. CircleCI uses the same defaults and caches the
installed executable.

## Integration

### Local CI

`ci-check.sh` invokes `cargo-fuzz-check.sh` immediately after the normal test
suite. Its progress labels change from 11 to 12 steps. `align-ci.sh` does not
run fuzzing because it remains an auto-fix-oriented fast path.

### GitHub Actions

The reusable workflow adds a Linux `fuzz_smoke` job. The job checks out the
project, detects the marker, installs the configured nightly and cargo-fuzz
version only when enabled, then invokes the shared helper. A failure uploads
`fuzz/artifacts/` when present. Projects without cargo-fuzz perform only the
lightweight checkout and detection steps.

### CircleCI

The template adds an equivalent Linux fuzz job using the shared helper and a
cache for the pinned cargo-fuzz executable. It skips installation and execution
when detection reports that the project is not cargo-fuzz-enabled.

## Testing

New Python tests exercise `cargo-fuzz-check.sh` with temporary project trees
and fake `cargo`/`cargo-fuzz` executables. They cover:

- no manifest and a manifest without the marker;
- disabled mode;
- missing cargo-fuzz only for enabled projects;
- invalid mode and invalid duration;
- empty target discovery;
- multiple targets built and run with quoted names;
- build-only mode;
- propagation of build and smoke-run failures;
- temporary corpus cleanup and use of committed seed corpora.

Existing CI-script tests will verify that `ci-check.sh` invokes the helper and
that hosted workflow definitions contain conditional detection, installation,
execution, and artifact handling. Documentation tests and the repository's
normal `ci-check.sh` remain part of final validation.

## Documentation

Both READMEs will describe automatic detection, the local installation
requirement, hosted-CI behavior, supported variables, and the distinction
between a bounded smoke check and a long-running fuzz campaign. The recommended
adoption file list will include `cargo-fuzz-check.sh`.
