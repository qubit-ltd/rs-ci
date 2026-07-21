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

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=toolchains.sh
source "$SCRIPT_DIR/toolchains.sh"
configure_rs_ci_toolchains

RUN_COVERAGE_CFG_CLIPPY="${RUN_COVERAGE_CFG_CLIPPY:-0}"
RUN_COVERAGE_IN_ALIGN="${RUN_COVERAGE_IN_ALIGN:-0}"

require_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        echo "error: required command '$1' was not found" >&2
        exit 1
    fi
}

ensure_toolchain() {
    local toolchain="$1"
    shift

    if ! rustup toolchain list | grep -q "^${toolchain}" || ! cargo +"$toolchain" --version > /dev/null 2>&1; then
        echo "==> installing Rust toolchain: $toolchain"
        rustup toolchain install "$toolchain" --profile minimal
    fi

    if [ "${RS_CI_UPDATE_TOOLCHAINS:-0}" = "1" ]; then
        echo "==> updating Rust toolchain: $toolchain"
        if ! rustup toolchain update "$toolchain"; then
            echo "warning: rustup toolchain update failed; continuing with installed toolchain" >&2
        fi
    fi

    if [ "$#" -gt 0 ]; then
        echo "==> ensuring components for $toolchain: $*"
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

RUSTFMT_CONFIG="${RS_CI_RUSTFMT_CONFIG:-$SCRIPT_DIR/rustfmt.toml}"
PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$SCRIPT_DIR}"

# shellcheck source=cargo-env.sh
source "$SCRIPT_DIR/cargo-env.sh"
configure_rs_ci_cargo_home "$PROJECT_ROOT"

require_command cargo
require_command rustup

cd "$PROJECT_ROOT"

if [ ! -f "$RUSTFMT_CONFIG" ]; then
    echo "error: rustfmt config '$RUSTFMT_CONFIG' was not found" >&2
    exit 1
fi

echo "Build toolchain: $RS_CI_BUILD_TOOLCHAIN"
echo "Rustfmt toolchain: $RS_CI_FMT_TOOLCHAIN"
echo "Clippy toolchain: $RS_CI_CLIPPY_TOOLCHAIN"
if [ "${RS_CI_CARGO_HOME_MODE:-project}" = "project" ]; then
    echo "Cargo home: $CARGO_HOME"
fi

ensure_lint_toolchains
print_rs_ci_lint_versions

echo "==> cargo +$RS_CI_FMT_TOOLCHAIN fmt -- --config-path $RUSTFMT_CONFIG"
cargo +"$RS_CI_FMT_TOOLCHAIN" fmt -- --config-path "$RUSTFMT_CONFIG"

echo "==> cargo +$RS_CI_CLIPPY_TOOLCHAIN clippy --fix (all targets / features)"
cargo +"$RS_CI_CLIPPY_TOOLCHAIN" clippy --fix --allow-dirty --allow-staged --all-targets --all-features

echo "==> cargo +$RS_CI_CLIPPY_TOOLCHAIN clippy (verify, -D warnings)"
cargo +"$RS_CI_CLIPPY_TOOLCHAIN" clippy --all-targets --all-features -- -D warnings

if [ "$RUN_COVERAGE_CFG_CLIPPY" = "1" ]; then
    echo "==> RUSTFLAGS=--cfg coverage cargo +$RS_CI_CLIPPY_TOOLCHAIN clippy"
    RUSTFLAGS="--cfg coverage" cargo +"$RS_CI_CLIPPY_TOOLCHAIN" clippy --all-targets --all-features -- -D warnings
fi

if [ "$RUN_COVERAGE_IN_ALIGN" = "1" ]; then
    require_command cargo-llvm-cov
    require_command jq
    ensure_toolchain "$RS_CI_BUILD_TOOLCHAIN" llvm-tools-preview

    echo "==> ./coverage.sh json"
    RS_CI_PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT_DIR/coverage.sh" json
else
    echo "==> skipping ./coverage.sh json by default; set RUN_COVERAGE_IN_ALIGN=1 to enable it"
fi

echo "Done. CI-style checks should pass; run ./ci-check.sh for the full pipeline."
