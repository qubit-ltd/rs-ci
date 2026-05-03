# Rust CI Scripts

[中文](README.zh_CN.md)

Shared scripts and CircleCI configuration for checking Rust code in CI.

## Files

- `align-ci.sh`: local auto-fix script for formatting and clippy.
- `ci-check.sh`: local full CI parity check.
- `style-check.sh`: project-specific Rust source layout checks that rustfmt and clippy do not cover.
- `coverage.sh`: local coverage report generator and threshold checker.
- `rustfmt.toml`: shared rustfmt configuration used by the local scripts and CI.
- `.circleci/config.yml`: optimized CircleCI template.

## Recommended Adoption

Copy these files into the root of a Rust project:

```bash
command cp align-ci.sh ci-check.sh style-check.sh coverage.sh rustfmt.toml <project-root>/
command cp .circleci/config.yml <project-root>/.circleci/config.yml
```

Then run:

```bash
cd <project-root>
chmod +x align-ci.sh ci-check.sh style-check.sh coverage.sh
./style-check.sh
./ci-check.sh
```

## Tunable Environment Variables

- `RUST_TOOLCHAIN`: toolchain used for `fmt` and `clippy`; defaults to `nightly`.
- `RS_CI_PROJECT_ROOT`: Rust project root used when these scripts are run from another directory.
- `RS_CI_RUSTFMT_CONFIG`: rustfmt configuration path; defaults to `rustfmt.toml` beside the running CI script.
- `RUN_COVERAGE_CFG_CLIPPY`: set to `1` to run clippy with `RUSTFLAGS="--cfg coverage"`.
- `RUN_COVERAGE_IN_ALIGN`: set to `1` to run `coverage.sh json` from `align-ci.sh`; defaults to `0`.
- `STYLE_SOURCE_DIR`: source directory checked by `style-check.sh`; defaults to `src`.
- `STYLE_TEST_DIR`: test directory checked by `style-check.sh`; defaults to `tests`.
- `STYLE_ENFORCE_INLINE_TESTS`: set to `0` to allow `#[cfg(test)]` or `#[test]` in source files; defaults to `1`.
- `STYLE_ENFORCE_TEST_FILE_NAMES`: set to `0` to disable test file naming checks; defaults to `1`.
- `STYLE_ENFORCE_PUBLIC_TYPE_FILES`: set to `0` to disable public type file layout checks; defaults to `1`.
- `STYLE_ENFORCE_EXPLICIT_IMPORTS`: set to `0` to allow wildcard imports and aggregation-only `mod.rs` private imports; defaults to `1`.
- `STYLE_ENFORCE_AGGREGATION_FILES`: set to `0` to allow `lib.rs` and `mod.rs` to define items such as structs, traits, functions, impls, or macros; defaults to `1`.
- `STYLE_TYPE_VISIBILITY`: type declarations checked by file layout rules, either `public` or `all`; defaults to `public`.
- `STYLE_INCLUDE_TYPE_ALIASES`: set to `1` to include public `type` aliases in file layout checks; defaults to `0`.
- `STYLE_EXTRA_EXCLUDE_REGEX`: extra regex for files skipped by `style-check.sh`.
- `STYLE_ALLOWLIST_FILE`: project-level reviewed style exception allowlist; defaults to `<project-root>/.qubit-style-allowlist`.
- `COVERAGE_ENFORCE_THRESHOLDS`: set to `0` to disable per-source coverage thresholds; defaults to `1`.
- `COVERAGE_ALL_FEATURES`: set to `0` to use Cargo's default feature selection for coverage; defaults to `1`.
- `MIN_FUNCTION_COVERAGE`: per-source function coverage threshold; defaults to `100`.
- `MIN_LINE_COVERAGE`: per-source line coverage threshold; defaults to `95`, interpreted as `> 95`.
- `MIN_REGION_COVERAGE`: per-source region coverage threshold; defaults to `95`, interpreted as `> 95`.
- `COVERAGE_SOURCE_DIR`: source directory checked by per-source thresholds; defaults to `src`.
- `COVERAGE_EXTRA_EXCLUDE_REGEX`: extra regex alternation appended to the coverage exclude pattern.
- `COVERAGE_OPEN_HTML`: set to `0` to stop `coverage.sh html` from opening the browser.

## Notes

The scripts are intentionally self-contained so Rust projects can keep familiar
root-level command names. Project-specific behavior should be configured with
environment variables instead of editing the scripts for one project only.

Use file-level `qubit-style: allow ...` comments only for deliberate exceptions,
such as a small public helper type that must stay beside its owner.
The `multiple-public-types` exception also requires a matching reviewed entry
in the project-level `STYLE_ALLOWLIST_FILE`; an inline comment alone is not
accepted for that rule. Keep this file outside `.rs-ci` when `.rs-ci` is a
shared scripts checkout.

`lib.rs` and `mod.rs` are treated as aggregation files. They should declare
modules and re-export items only; concrete item definitions belong in dedicated
source files.
