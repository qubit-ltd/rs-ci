# Conditional cargo-fuzz CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run a bounded cargo-fuzz smoke check automatically for Rust projects
that declare a standard cargo-fuzz package, without changing checks for other
projects.

**Architecture:** Add `cargo-fuzz-check.sh` as the single detector and runner.
`ci-check.sh`, the reusable GitHub workflow, and the CircleCI template invoke
the helper rather than duplicate detection or target execution. The helper
uses a temporary writable corpus and optional committed seed corpus so smoke
checks do not dirty repositories.

**Tech Stack:** Bash, Python standard-library `unittest`, GitHub Actions YAML,
CircleCI YAML, cargo-fuzz/libFuzzer.

## Global Constraints

- Detect only `<project-root>/fuzz/Cargo.toml` containing package-metadata
  `cargo-fuzz = true`.
- Default to `RS_CI_FUZZ_MODE=smoke` and
  `RS_CI_FUZZ_SECONDS_PER_TARGET=10`.
- Support exactly `smoke`, `build-only`, and `disabled` modes.
- In `disabled` mode, bypass cargo-fuzz toolchain and executable setup.
- Use `RS_CI_FUZZ_TOOLCHAIN`, defaulting to the pinned lint nightly; never use
  the stable `RS_CI_BUILD_TOOLCHAIN` for cargo-fuzz.
- Build every target from `cargo fuzz list`; in smoke mode run every target
  with `-max_total_time`.
- Keep generated corpus data temporary and retain crash artifacts in
  `fuzz/artifacts/`.
- Run fuzz smoke only on Linux hosted CI; do not add a scheduled long campaign.
- Do not create a Git commit unless separately authorized.

---

### Task 1: Define the cargo-fuzz helper contract with failing tests

**Files:**

- Create: `tests/cargo_fuzz_check_tests.py`
- Create: `cargo-fuzz-check.sh`

**Interfaces:**

- Consumes: `RS_CI_PROJECT_ROOT`, `RS_CI_FUZZ_MODE`,
  `RS_CI_FUZZ_SECONDS_PER_TARGET`, and `RS_CI_FUZZ_TOOLCHAIN`.
- Produces: exit status zero for disabled or non-cargo-fuzz projects; nonzero
  for enabled-project configuration/tool/build/run failures.
- Provides: `--is-configured`, which exits zero only when the standard
  cargo-fuzz marker is present and lets callers avoid unnecessary tool setup.

- [ ] **Step 1: Write failing helper-contract tests**

Create a Python `unittest` fixture that creates a temporary project root and
places fake `cargo` and `cargo-fuzz` executables in a temporary `PATH`. The
fake cargo must append every received argument list to a log and answer
`cargo +nightly fuzz list` with the `FAKE_FUZZ_TARGETS` environment value.

```python
def run_check(project_root: Path, *, targets: str = "", mode: str = "smoke") -> subprocess.CompletedProcess[str]:
    env = os.environ | {
        "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
        "RS_CI_PROJECT_ROOT": str(project_root),
        "RS_CI_FUZZ_MODE": mode,
        "RS_CI_FUZZ_TOOLCHAIN": "nightly-test",
        "RS_CI_FUZZ_SECONDS_PER_TARGET": "3",
        "FAKE_FUZZ_TARGETS": targets,
    }
    return subprocess.run([str(SCRIPT)], text=True, capture_output=True, env=env, check=False)

def test_skips_project_without_fuzz_manifest(self) -> None:
    result = run_check(self.project_root)
    self.assertEqual(0, result.returncode)
    self.assertIn("cargo-fuzz is not configured", result.stdout)

def test_smoke_builds_and_runs_each_target(self) -> None:
    write_fuzz_manifest(self.project_root)
    result = run_check(self.project_root, targets="alpha\nbeta\n")
    self.assertEqual(0, result.returncode)
    log = self.command_log.read_text(encoding="utf-8")
    self.assertIn("+nightly-test fuzz build alpha", log)
    self.assertIn("+nightly-test fuzz run beta", log)
    self.assertIn("-max_total_time=3", log)
```

Add independent tests for a manifest without the marker, `disabled`, invalid
mode, duration `0`, missing `cargo-fuzz`, empty target output, `build-only`,
build failure, and run failure. Add a seed-corpus test asserting that the run
command receives a temporary corpus first and `fuzz/corpus/alpha` second.

- [ ] **Step 2: Run the new tests and verify RED**

Run: `python3 -m unittest tests.cargo_fuzz_check_tests`

Expected: FAIL because `cargo-fuzz-check.sh` does not exist.

- [ ] **Step 3: Implement the helper minimally**

Create an executable Bash script with these functions and control flow:

```bash
has_cargo_fuzz_manifest() {
    local manifest="$PROJECT_ROOT/fuzz/Cargo.toml"
    [ -f "$manifest" ] \
        && awk '
            /^\[package\.metadata\]$/ { metadata = 1; next }
            /^\[/ { metadata = 0 }
            metadata && /^[[:space:]]*cargo-fuzz[[:space:]]*=[[:space:]]*true[[:space:]]*(#.*)?$/ { found = 1 }
            END { exit(found ? 0 : 1) }
        ' "$manifest"
}

run_target() {
    local target="$1"
    cargo +"$RS_CI_FUZZ_TOOLCHAIN" fuzz build "$target"
    [ "$RS_CI_FUZZ_MODE" = "build-only" ] && return 0
    local writable_corpus="$TEMP_CORPUS/$target"
    mkdir -p "$writable_corpus"
    local seed_corpus="$PROJECT_ROOT/fuzz/corpus/$target"
    if [ -d "$seed_corpus" ]; then
        cargo +"$RS_CI_FUZZ_TOOLCHAIN" fuzz run "$target" "$writable_corpus" "$seed_corpus" -- \
            "-max_total_time=$RS_CI_FUZZ_SECONDS_PER_TARGET"
    else
        cargo +"$RS_CI_FUZZ_TOOLCHAIN" fuzz run "$target" "$writable_corpus" -- \
            "-max_total_time=$RS_CI_FUZZ_SECONDS_PER_TARGET"
    fi
}
```

Use `set -euo pipefail`; validate the mode and duration before invoking tools;
use `command -v cargo-fuzz` only after marker detection; use `mapfile -t` to
read nonempty target names; reject an empty list; and use `mktemp -d` plus an
EXIT trap to remove only the temporary corpus directory.

- [ ] **Step 4: Run the helper-contract tests and verify GREEN**

Run: `python3 -m unittest tests.cargo_fuzz_check_tests`

Expected: all helper-contract tests pass.

- [ ] **Step 5: Run shell syntax validation**

Run: `bash -n cargo-fuzz-check.sh`

Expected: exit status 0.

### Task 2: Integrate the helper into local full CI

**Files:**

- Modify: `ci-check.sh`
- Modify: `tests/ci_check_script_tests.py`
- Create: `tests/cargo_fuzz_check_tests.py` (from Task 1)

**Interfaces:**

- Consumes: the helper from Task 1 and the existing `ensure_toolchain` /
  `require_executable_file` functions.
- Produces: a twelfth local CI step that skips non-fuzz projects and otherwise
  runs the helper after ordinary tests.

- [ ] **Step 1: Write the failing integration assertions**

Extend `CiCheckScriptTests` with assertions that the script declares and
exports `RS_CI_FUZZ_TOOLCHAIN`, invokes `ensure_toolchain
"$RS_CI_FUZZ_TOOLCHAIN"` only in the fuzz step, requires
`cargo-fuzz-check.sh`, and contains a `6/12` cargo-fuzz step before the
documentation `7/12` step.

```python
def test_ci_check_runs_conditional_cargo_fuzz_after_tests(self) -> None:
    script = CI_CHECK_SCRIPT.read_text(encoding="utf-8")
    self.assertIn('RS_CI_FUZZ_TOOLCHAIN="${RS_CI_FUZZ_TOOLCHAIN:-$RS_CI_DEFAULT_LINT_TOOLCHAIN}"', script)
    self.assertIn('print_step "6/12 Running conditional cargo-fuzz smoke checks"', script)
    self.assertIn('ensure_toolchain "$RS_CI_FUZZ_TOOLCHAIN"', script)
    self.assertIn('"$SCRIPT_DIR/cargo-fuzz-check.sh"', script)
    self.assertIn('print_step "7/12 Building all-feature documentation', script)
```

- [ ] **Step 2: Run the focused assertion and verify RED**

Run: `python3 -m unittest tests.ci_check_script_tests.CiCheckScriptTests.test_ci_check_runs_conditional_cargo_fuzz_after_tests`

Expected: FAIL because the current script has only 11 steps and no fuzz helper.

- [ ] **Step 3: Add the local CI step**

Add the exported fuzz toolchain setting beside the existing toolchain settings.
After the normal test step, insert:

```bash
print_step "6/12 Running conditional cargo-fuzz smoke checks"
require_executable_file "$SCRIPT_DIR/cargo-fuzz-check.sh"
if RS_CI_PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT_DIR/cargo-fuzz-check.sh" --is-configured; then
    ensure_toolchain "$RS_CI_FUZZ_TOOLCHAIN"
fi
RS_CI_PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT_DIR/cargo-fuzz-check.sh"
print_success "Conditional cargo-fuzz checks passed"
```

Renumber the documentation, README, matrix, package, coverage, and audit
steps from 6–11 to 7–12. Use the helper preflight before `ensure_toolchain` so
projects without the marker complete the step without either a toolchain or a
`cargo-fuzz` installation requirement.

- [ ] **Step 4: Run focused local-CI tests and verify GREEN**

Run: `python3 -m unittest tests.ci_check_script_tests tests.cargo_fuzz_check_tests`

Expected: all focused tests pass.

### Task 3: Add parity to GitHub Actions and CircleCI

**Files:**

- Modify: `.github/workflows/rust-ci.yml`
- Modify: `.circleci/config.yml`
- Create: `tests/fuzz_workflow_tests.py`

**Interfaces:**

- Consumes: `cargo-fuzz-check.sh` and its environment contract from Task 1.
- Produces: Linux-only hosted smoke checks that install cargo-fuzz only for
  detected projects and upload crash artifacts on failure.

- [ ] **Step 1: Write failing workflow-definition tests**

Add text-level tests that load both YAML files and assert they reference
`cargo-fuzz-check.sh`, `RS_CI_FUZZ_TOOLCHAIN`, `CARGO_FUZZ_VERSION`,
`RS_CI_FUZZ_SECONDS_PER_TARGET`, `cargo install --locked`, and
`fuzz/artifacts`.

```python
def test_github_workflow_has_conditional_fuzz_smoke_job(self) -> None:
    workflow = GITHUB_WORKFLOW.read_text(encoding="utf-8")
    self.assertIn("fuzz_smoke:", workflow)
    self.assertIn("cargo-fuzz-check.sh", workflow)
    self.assertIn("cargo install --locked", workflow)
    self.assertIn("fuzz/artifacts", workflow)
```

- [ ] **Step 2: Run the workflow tests and verify RED**

Run: `python3 -m unittest tests.fuzz_workflow_tests`

Expected: FAIL because neither hosted template contains cargo-fuzz support.

- [ ] **Step 3: Implement GitHub Actions parity**

Add reusable workflow inputs `cargo_fuzz_version`, `cargo_fuzz_toolchain`,
`cargo_fuzz_mode`, and `cargo_fuzz_seconds_per_target`, with defaults `0.13.2`,
the pinned nightly, `smoke`, and `10`. Add a Linux `fuzz_smoke` job that:

1. checks out source and submodules;
2. detects the standard marker and writes `enabled=true|false` to
   `GITHUB_OUTPUT`;
3. installs the configured nightly only when enabled;
4. installs `cargo-fuzz` with `cargo install --locked --version` only when
   enabled;
5. invokes the helper with the configured environment;
6. uploads `fuzz/artifacts` on failure when enabled.

Use an Actions cache key that includes `cargo_fuzz_version`, the fuzz
toolchain, and `fuzz/Cargo.lock`.

- [ ] **Step 4: Implement CircleCI parity**

Add a Linux `fuzz_smoke` job that checks out the repository, inspects the
marker, exits successfully when absent, installs the pinned nightly and
`cargo-fuzz` only when present, invokes the helper, and stores
`fuzz/artifacts` with `when: on_fail`. Cache `~/.cargo/bin/cargo-fuzz` using a
key that includes its pinned version.

- [ ] **Step 5: Run workflow tests and verify GREEN**

Run: `python3 -m unittest tests.fuzz_workflow_tests`

Expected: all workflow-definition tests pass.

### Task 4: Document adoption and validate the shared scripts

**Files:**

- Modify: `README.md`
- Modify: `README.zh_CN.md`
- Modify: `docs/superpowers/specs/2026-07-16-conditional-cargo-fuzz-ci-design.md`

**Interfaces:**

- Consumes: environment names and modes established in Tasks 1–3.
- Produces: synchronized English and Chinese adoption and configuration
  documentation.

- [ ] **Step 1: Write failing documentation assertions**

Extend `tests/fuzz_workflow_tests.py` to require both READMEs to mention
`cargo-fuzz-check.sh`, `RS_CI_FUZZ_MODE`, `RS_CI_FUZZ_TOOLCHAIN`, and
`RS_CI_FUZZ_SECONDS_PER_TARGET`.

- [ ] **Step 2: Run the documentation assertion and verify RED**

Run: `python3 -m unittest tests.fuzz_workflow_tests.FuzzWorkflowTests.test_readmes_document_conditional_cargo_fuzz`

Expected: FAIL because the current READMEs do not describe cargo-fuzz support.

- [ ] **Step 3: Update both READMEs**

Add `cargo-fuzz-check.sh` to the file and copy-command inventories. Document
the marker-based skip behavior, modes, pinned nightly requirement, local
installation command, per-target default duration, Linux-only hosted smoke
coverage, crash artifact location, and the rule that long campaigns remain
separate from normal CI.

- [ ] **Step 4: Run the full rs-ci script test suite**

Run: `python3 -m unittest discover -s tests -p '*_tests.py'`

Expected: all script and documentation tests pass.

- [ ] **Step 5: Run static validation**

Run:

```bash
bash -n cargo-fuzz-check.sh ci-check.sh
python3 -m py_compile tests/cargo_fuzz_check_tests.py tests/fuzz_workflow_tests.py
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 6: Execute downstream project validation**

Run the shared script against a Rust project root, for example:

```bash
RS_CI_PROJECT_ROOT=<project-root> ./ci-check.sh
```

Expected: a project without the standard marker reports a successful
cargo-fuzz skip and completes its remaining checks; an enabled project builds
and runs every target within the configured smoke duration.
