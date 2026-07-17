#!/bin/bash
################################################################################
#
#    Copyright (c) 2026.
#    Haixing Hu, Qubit Co. Ltd.
#
#    All rights reserved.
#
################################################################################
#
# Local CI check script.
# Run this script before committing code to ensure it passes CI-style checks.
#

set -euo pipefail

RS_CI_DEFAULT_LINT_TOOLCHAIN="${RUST_TOOLCHAIN:-nightly-2026-06-05}"
RS_CI_BUILD_TOOLCHAIN="${RS_CI_BUILD_TOOLCHAIN:-1.94.0}"
RS_CI_FMT_TOOLCHAIN="${RS_CI_FMT_TOOLCHAIN:-$RS_CI_DEFAULT_LINT_TOOLCHAIN}"
RS_CI_CLIPPY_TOOLCHAIN="${RS_CI_CLIPPY_TOOLCHAIN:-$RS_CI_DEFAULT_LINT_TOOLCHAIN}"
RS_CI_FUZZ_TOOLCHAIN="${RS_CI_FUZZ_TOOLCHAIN:-$RS_CI_DEFAULT_LINT_TOOLCHAIN}"
RUN_COVERAGE_CFG_CLIPPY="${RUN_COVERAGE_CFG_CLIPPY:-0}"

export RS_CI_BUILD_TOOLCHAIN
export RS_CI_FMT_TOOLCHAIN
export RS_CI_CLIPPY_TOOLCHAIN
export RS_CI_FUZZ_TOOLCHAIN

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TEMP_FILES=()
cleanup() {
    local file
    if [ "${#TEMP_FILES[@]}" -eq 0 ]; then
        return
    fi
    for file in "${TEMP_FILES[@]}"; do
        [ -n "$file" ] && [ -f "$file" ] && command rm -f "$file"
    done
}
trap cleanup EXIT

print_step() {
    echo -e "${BLUE}==>${NC} $1"
}

print_success() {
    echo -e "${GREEN}[OK] $1${NC}"
}

print_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

require_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        print_error "Required command '$1' was not found"
        exit 1
    fi
}

require_executable_file() {
    local file="$1"

    if [ ! -f "$file" ]; then
        print_error "Required script '$file' was not found"
        exit 1
    fi
    if [ ! -x "$file" ]; then
        print_error "Required script '$file' is not executable"
        echo ""
        echo "Please run:"
        echo "  chmod +x $file"
        exit 1
    fi
}

ensure_toolchain() {
    local toolchain="$1"
    shift

    if ! rustup toolchain list | grep -q "^${toolchain}" || ! cargo +"$toolchain" --version > /dev/null 2>&1; then
        print_warning "Rust toolchain '$toolchain' not found or incomplete; installing"
        rustup toolchain install "$toolchain" --profile minimal
    fi

    if [ "${RS_CI_UPDATE_TOOLCHAINS:-0}" = "1" ]; then
        print_step "Updating Rust toolchain '$toolchain'"
        if ! rustup toolchain update "$toolchain"; then
            print_warning "rustup toolchain update failed; continuing with the already-installed toolchain"
        fi
    fi

    if [ "$#" -gt 0 ]; then
        rustup component add "$@" --toolchain "$toolchain"
    fi
}

ensure_lint_toolchains() {
    ensure_toolchain "$RS_CI_FMT_TOOLCHAIN" rustfmt
    if [ "$RS_CI_CLIPPY_TOOLCHAIN" = "$RS_CI_FMT_TOOLCHAIN" ]; then
        rustup component add clippy --toolchain "$RS_CI_CLIPPY_TOOLCHAIN"
    else
        ensure_toolchain "$RS_CI_CLIPPY_TOOLCHAIN" clippy
    fi
}

ensure_build_toolchain() {
    ensure_toolchain "$RS_CI_BUILD_TOOLCHAIN"
}

ensure_llvm_tools() {
    rustup component add llvm-tools-preview --toolchain "$RS_CI_BUILD_TOOLCHAIN"
}

run_clippy() {
    local log_file
    log_file=$(mktemp -t rs-ci-clippy.XXXXXX)
    TEMP_FILES+=("$log_file")

    if cargo +"$RS_CI_CLIPPY_TOOLCHAIN" clippy --all-targets --all-features -- -D warnings 2>&1 | tee "$log_file"; then
        print_success "Clippy checks passed"
    else
        print_error "Clippy found issues"
        cat "$log_file"
        echo ""
        echo "Please try:"
        echo "  ./align-ci.sh"
        exit 1
    fi
}

run_security_audit() {
    local audit_log
    audit_log=$(mktemp -t rs-ci-audit.XXXXXX)
    TEMP_FILES+=("$audit_log")

    if cargo +"$RS_CI_BUILD_TOOLCHAIN" audit 2>&1 | tee "$audit_log"; then
        print_success "Security audit passed, no known vulnerabilities found"
        return
    fi

    if grep -qi "couldn't fetch advisory database\\|failed to fetch advisory database\\|failed to prepare fetch\\|error sending request" "$audit_log"; then
        print_warning "cargo audit could not fetch the RustSec advisory database; retrying with cached data"
        if cargo +"$RS_CI_BUILD_TOOLCHAIN" audit --no-fetch --stale; then
            print_success "Security audit passed using cached advisory data"
            print_warning "CI should still verify against the latest advisory database"
            return
        fi
    fi

    print_error "Security audit found issues"
    cat "$audit_log"
    echo ""
    echo "Please review the security issues and consider:"
    echo "  1. Update dependencies: cargo update"
    echo "  2. View details: cargo +$RS_CI_BUILD_TOOLCHAIN audit"
    echo "  3. If unable to fix immediately, temporarily ignore in .cargo-audit.toml"
    exit 1
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUSTFMT_CONFIG="${RS_CI_RUSTFMT_CONFIG:-$SCRIPT_DIR/rustfmt.toml}"
PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$SCRIPT_DIR}"

# shellcheck source=cargo-env.sh
source "$SCRIPT_DIR/cargo-env.sh"
configure_rs_ci_cargo_home "$PROJECT_ROOT"

require_command cargo
require_command rustup

cd "$PROJECT_ROOT"

if [ ! -f "$RUSTFMT_CONFIG" ]; then
    print_error "Rustfmt config '$RUSTFMT_CONFIG' was not found"
    exit 1
fi

echo "Starting local CI checks"
echo "Build toolchain: $RS_CI_BUILD_TOOLCHAIN"
echo "Rustfmt toolchain: $RS_CI_FMT_TOOLCHAIN"
echo "Clippy toolchain: $RS_CI_CLIPPY_TOOLCHAIN"
echo "Fuzz toolchain: $RS_CI_FUZZ_TOOLCHAIN"
if [ "${RS_CI_CARGO_HOME_MODE:-project}" = "project" ]; then
    echo "Cargo home: $CARGO_HOME"
fi
echo ""

print_step "1/12 Checking code format (cargo +$RS_CI_FMT_TOOLCHAIN fmt -- --check --config-path $RUSTFMT_CONFIG)"
ensure_lint_toolchains
if cargo +"$RS_CI_FMT_TOOLCHAIN" fmt -- --check --config-path "$RUSTFMT_CONFIG" > /dev/null 2>&1; then
    print_success "Code format check passed"
else
    print_error "Code format check failed"
    echo ""
    echo "Please run:"
    echo "  ./align-ci.sh"
    exit 1
fi
echo ""

print_step "2/12 Running Clippy checks (cargo +$RS_CI_CLIPPY_TOOLCHAIN clippy)"
run_clippy
if [ "$RUN_COVERAGE_CFG_CLIPPY" = "1" ]; then
    print_step "2b/12 Running Clippy checks with RUSTFLAGS=--cfg coverage"
    RUSTFLAGS="--cfg coverage" cargo +"$RS_CI_CLIPPY_TOOLCHAIN" clippy --all-targets --all-features -- -D warnings
    print_success "Coverage cfg clippy checks passed"
fi
echo ""

print_step "3/12 Running Rust style checks"
require_executable_file "$SCRIPT_DIR/style-check.sh"
RS_CI_PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT_DIR/style-check.sh"
print_success "Rust style checks passed"
echo ""

print_step "4/12 Building project (cargo +$RS_CI_BUILD_TOOLCHAIN)"
ensure_build_toolchain
if cargo +"$RS_CI_BUILD_TOOLCHAIN" build --verbose > /dev/null 2>&1; then
    print_success "Debug build succeeded"
else
    print_error "Debug build failed"
    cargo +"$RS_CI_BUILD_TOOLCHAIN" build --verbose
    exit 1
fi

if cargo +"$RS_CI_BUILD_TOOLCHAIN" build --release --verbose > /dev/null 2>&1; then
    print_success "Release build succeeded"
else
    print_error "Release build failed"
    cargo +"$RS_CI_BUILD_TOOLCHAIN" build --release --verbose
    exit 1
fi
echo ""

print_step "5/12 Running tests (cargo +$RS_CI_BUILD_TOOLCHAIN test --all-features)"
if cargo +"$RS_CI_BUILD_TOOLCHAIN" test --all-features --verbose; then
    print_success "All tests passed"
else
    print_error "Tests failed"
    exit 1
fi
echo ""

print_step "6/12 Running conditional cargo-fuzz smoke checks"
require_executable_file "$SCRIPT_DIR/cargo-fuzz-check.sh"
if [ "${RS_CI_FUZZ_MODE:-smoke}" != "disabled" ] \
    && RS_CI_PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT_DIR/cargo-fuzz-check.sh" --is-configured; then
    ensure_toolchain "$RS_CI_FUZZ_TOOLCHAIN"
fi
RS_CI_PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT_DIR/cargo-fuzz-check.sh"
print_success "Conditional cargo-fuzz checks passed"
echo ""

print_step "7/12 Building all-feature documentation with warnings and missing docs denied"
if RUSTDOCFLAGS="-D warnings -D missing-docs" cargo +"$RS_CI_BUILD_TOOLCHAIN" doc --all-features --no-deps --verbose > /dev/null 2>&1; then
    print_success "Documentation build passed"
else
    print_error "Documentation build failed"
    RUSTDOCFLAGS="-D warnings -D missing-docs" cargo +"$RS_CI_BUILD_TOOLCHAIN" doc --all-features --no-deps --verbose
    exit 1
fi
echo ""

print_step "8/12 Checking README dependency versions"
require_command python3
require_executable_file "$SCRIPT_DIR/readme-version-check.py"
RS_CI_PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT_DIR/readme-version-check.py"
print_success "README dependency versions passed"
echo ""

print_step "9/12 Running configured Cargo feature matrix"
MATRIX_CONFIG_NAME="${RS_CI_CARGO_MATRIX_CONFIG:-.rs-ci-cargo-matrix.json}"
if [[ "$MATRIX_CONFIG_NAME" = /* ]]; then
    MATRIX_CONFIG_FILE="$MATRIX_CONFIG_NAME"
else
    MATRIX_CONFIG_FILE="$PROJECT_ROOT/$MATRIX_CONFIG_NAME"
fi
if [ -x "$SCRIPT_DIR/cargo-feature-check.sh" ]; then
    RS_CI_PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT_DIR/cargo-feature-check.sh" run-all
elif [ -f "$MATRIX_CONFIG_FILE" ]; then
    print_error "Cargo feature matrix config exists, but cargo-feature-check.sh was not found"
    exit 1
else
    echo "No Cargo feature matrix config found; using the default CI feature behavior."
fi
print_success "Configured Cargo feature matrix checks passed"
echo ""

print_step "10/12 Verifying Cargo package"
require_executable_file "$SCRIPT_DIR/cargo-package-check.sh"
RS_CI_PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT_DIR/cargo-package-check.sh"
print_success "Cargo package verification passed"
echo ""

print_step "11/12 Generating and checking JSON coverage report"
require_command cargo-llvm-cov
require_command jq
ensure_llvm_tools
RS_CI_PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT_DIR/coverage.sh" json
print_success "Coverage report passed thresholds"
echo ""

print_step "12/12 Running security audit"
require_command cargo-audit
run_security_audit
echo ""

echo "All checks passed."
echo "Your code is ready to commit."
