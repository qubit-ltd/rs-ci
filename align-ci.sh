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
# One-shot auto-fix to match local CI.
# Run from repo root: ./align-ci.sh
#

set -euo pipefail

RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-nightly}"
RUN_COVERAGE_CFG_CLIPPY="${RUN_COVERAGE_CFG_CLIPPY:-0}"

require_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        echo "error: required command '$1' was not found" >&2
        exit 1
    fi
}

ensure_toolchain_components() {
    if ! rustup toolchain list | grep -q "^${RUST_TOOLCHAIN}"; then
        echo "==> installing Rust toolchain: $RUST_TOOLCHAIN"
        rustup toolchain install "$RUST_TOOLCHAIN"
    fi

    echo "==> ensuring rustfmt and clippy components for $RUST_TOOLCHAIN"
    rustup component add rustfmt clippy --toolchain "$RUST_TOOLCHAIN"
}

require_command cargo
require_command rustup

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$SCRIPT_DIR}"
cd "$PROJECT_ROOT"

ensure_toolchain_components

echo "==> cargo +$RUST_TOOLCHAIN fmt"
cargo +"$RUST_TOOLCHAIN" fmt

echo "==> cargo +$RUST_TOOLCHAIN clippy --fix (all targets / features)"
cargo +"$RUST_TOOLCHAIN" clippy --fix --allow-dirty --allow-staged --all-targets --all-features

echo "==> cargo +$RUST_TOOLCHAIN clippy (verify, -D warnings)"
cargo +"$RUST_TOOLCHAIN" clippy --all-targets --all-features -- -D warnings

if [ "$RUN_COVERAGE_CFG_CLIPPY" = "1" ]; then
    echo "==> RUSTFLAGS=--cfg coverage cargo +$RUST_TOOLCHAIN clippy"
    RUSTFLAGS="--cfg coverage" cargo +"$RUST_TOOLCHAIN" clippy --all-targets --all-features -- -D warnings
fi

if command -v cargo-llvm-cov > /dev/null 2>&1 && command -v jq > /dev/null 2>&1; then
    echo "==> ./coverage.sh json"
    RS_CI_PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT_DIR/coverage.sh" json
else
    echo "==> skipping ./coverage.sh json because cargo-llvm-cov or jq is not installed"
fi

echo "Done. CI-style checks should pass; run ./ci-check.sh for the full pipeline."
