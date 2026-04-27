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

RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-nightly}"
RUN_COVERAGE_CFG_CLIPPY="${RUN_COVERAGE_CFG_CLIPPY:-0}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TEMP_FILES=()
cleanup() {
    local file
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

ensure_toolchain_components() {
    if ! rustup toolchain list | grep -q "^${RUST_TOOLCHAIN}"; then
        print_warning "Rust toolchain '$RUST_TOOLCHAIN' not found; installing"
        rustup toolchain install "$RUST_TOOLCHAIN"
    fi

    rustup component add rustfmt clippy --toolchain "$RUST_TOOLCHAIN"
}

ensure_llvm_tools() {
    local active_toolchain
    local sysroot
    local host
    local bindir
    local profdata
    local cov

    active_toolchain=$(rustup show active-toolchain 2>/dev/null | awk '{print $1; exit}' || true)
    if [ -n "$active_toolchain" ]; then
        sysroot=$(rustup run "$active_toolchain" rustc --print sysroot 2>/dev/null || true)
        host=$(rustup run "$active_toolchain" rustc -vV 2>/dev/null | sed -n 's/^host: //p' || true)
    else
        sysroot=$(rustc --print sysroot 2>/dev/null || true)
        host=$(rustc -vV 2>/dev/null | sed -n 's/^host: //p' || true)
    fi

    if [ -z "$sysroot" ] || [ -z "$host" ]; then
        print_warning "Unable to detect Rust sysroot; cargo-llvm-cov will report any missing tool details"
        return
    fi

    bindir="$sysroot/lib/rustlib/$host/bin"
    profdata="$bindir/llvm-profdata"
    cov="$bindir/llvm-cov"
    if [ ! -f "$profdata" ] || [ ! -f "$cov" ]; then
        print_warning "llvm-tools-preview is missing for active toolchain; installing"
        if [ -n "$active_toolchain" ]; then
            rustup component add llvm-tools-preview --toolchain "$active_toolchain"
        else
            rustup component add llvm-tools-preview
        fi
    fi
}

run_clippy() {
    local log_file
    log_file=$(mktemp -t rs-ci-clippy.XXXXXX)
    TEMP_FILES+=("$log_file")

    if cargo +"$RUST_TOOLCHAIN" clippy --all-targets --all-features -- -D warnings 2>&1 | tee "$log_file"; then
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

    if cargo audit 2>&1 | tee "$audit_log"; then
        print_success "Security audit passed, no known vulnerabilities found"
        return
    fi

    if grep -qi "couldn't fetch advisory database\\|failed to fetch advisory database\\|failed to prepare fetch\\|error sending request" "$audit_log"; then
        print_warning "cargo audit could not fetch the RustSec advisory database; retrying with cached data"
        if cargo audit --no-fetch --stale; then
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
    echo "  2. View details: cargo audit"
    echo "  3. If unable to fix immediately, temporarily ignore in .cargo-audit.toml"
    exit 1
}

require_command cargo
require_command rustup

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$SCRIPT_DIR}"
cd "$PROJECT_ROOT"

echo "Starting local CI checks"
echo ""

print_step "1/7 Checking code format (cargo +$RUST_TOOLCHAIN fmt)"
ensure_toolchain_components
if cargo +"$RUST_TOOLCHAIN" fmt -- --check > /dev/null 2>&1; then
    print_success "Code format check passed"
else
    print_error "Code format check failed"
    echo ""
    echo "Please run:"
    echo "  ./align-ci.sh"
    exit 1
fi
echo ""

print_step "2/7 Running Clippy checks (cargo +$RUST_TOOLCHAIN clippy)"
run_clippy
if [ "$RUN_COVERAGE_CFG_CLIPPY" = "1" ]; then
    print_step "2b/7 Running Clippy checks with RUSTFLAGS=--cfg coverage"
    RUSTFLAGS="--cfg coverage" cargo +"$RUST_TOOLCHAIN" clippy --all-targets --all-features -- -D warnings
    print_success "Coverage cfg clippy checks passed"
fi
echo ""

print_step "3/7 Building project"
if cargo build --verbose > /dev/null 2>&1; then
    print_success "Debug build succeeded"
else
    print_error "Debug build failed"
    cargo build --verbose
    exit 1
fi

if cargo build --release --verbose > /dev/null 2>&1; then
    print_success "Release build succeeded"
else
    print_error "Release build failed"
    cargo build --release --verbose
    exit 1
fi
echo ""

print_step "4/7 Running tests (cargo test --all-features)"
if cargo test --all-features --verbose; then
    print_success "All tests passed"
else
    print_error "Tests failed"
    exit 1
fi
echo ""

print_step "5/7 Building documentation with warnings denied"
if RUSTDOCFLAGS="-D warnings" cargo doc --no-deps --verbose > /dev/null 2>&1; then
    print_success "Documentation build passed"
else
    print_error "Documentation build failed"
    RUSTDOCFLAGS="-D warnings" cargo doc --no-deps --verbose
    exit 1
fi
echo ""

print_step "6/7 Generating and checking JSON coverage report"
require_command cargo-llvm-cov
require_command jq
ensure_llvm_tools
RS_CI_PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT_DIR/coverage.sh" json
print_success "Coverage report passed thresholds"
echo ""

print_step "7/7 Running security audit"
require_command cargo-audit
run_security_audit
echo ""

echo "All checks passed."
echo "Your code is ready to commit."
