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
# Shared Rust toolchain contract for local scripts and CI templates.
#

RS_CI_DEFAULT_BUILD_TOOLCHAIN="1.94.0"
RS_CI_DEFAULT_FMT_TOOLCHAIN="nightly-2026-06-05"
RS_CI_DEFAULT_CLIPPY_TOOLCHAIN="nightly-2026-06-05"
RS_CI_DEFAULT_FUZZ_TOOLCHAIN="nightly-2026-06-05"
RS_CI_DEFAULT_MIRI_TOOLCHAIN="nightly-2026-06-05"
RS_CI_DEFAULT_SANITIZER_TOOLCHAIN="nightly-2026-06-05"
RS_CI_DEFAULT_CARGO_LLVM_COV_VERSION="0.8.6"
RS_CI_DEFAULT_CARGO_FUZZ_VERSION="0.13.2"

validate_rs_ci_toolchain() {
    local variable_name="$1"
    local toolchain="$2"

    if [[ "$toolchain" = nightly* ]] \
        && ! [[ "$toolchain" =~ ^nightly-[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "error: $variable_name must pin nightly to nightly-YYYY-MM-DD; got '$toolchain'" >&2
        return 1
    fi
}

configure_rs_ci_toolchains() {
    RS_CI_BUILD_TOOLCHAIN="${RS_CI_BUILD_TOOLCHAIN:-$RS_CI_DEFAULT_BUILD_TOOLCHAIN}"
    RS_CI_FMT_TOOLCHAIN="${RS_CI_FMT_TOOLCHAIN:-$RS_CI_DEFAULT_FMT_TOOLCHAIN}"
    RS_CI_CLIPPY_TOOLCHAIN="${RS_CI_CLIPPY_TOOLCHAIN:-$RS_CI_DEFAULT_CLIPPY_TOOLCHAIN}"
    RS_CI_FUZZ_TOOLCHAIN="${RS_CI_FUZZ_TOOLCHAIN:-$RS_CI_DEFAULT_FUZZ_TOOLCHAIN}"
    RS_CI_MIRI_TOOLCHAIN="${RS_CI_MIRI_TOOLCHAIN:-$RS_CI_DEFAULT_MIRI_TOOLCHAIN}"
    RS_CI_SANITIZER_TOOLCHAIN="${RS_CI_SANITIZER_TOOLCHAIN:-$RS_CI_DEFAULT_SANITIZER_TOOLCHAIN}"
    CARGO_LLVM_COV_VERSION="${CARGO_LLVM_COV_VERSION:-$RS_CI_DEFAULT_CARGO_LLVM_COV_VERSION}"
    CARGO_FUZZ_VERSION="${CARGO_FUZZ_VERSION:-$RS_CI_DEFAULT_CARGO_FUZZ_VERSION}"

    validate_rs_ci_toolchain RS_CI_BUILD_TOOLCHAIN "$RS_CI_BUILD_TOOLCHAIN" || return 1
    validate_rs_ci_toolchain RS_CI_FMT_TOOLCHAIN "$RS_CI_FMT_TOOLCHAIN" || return 1
    validate_rs_ci_toolchain RS_CI_CLIPPY_TOOLCHAIN "$RS_CI_CLIPPY_TOOLCHAIN" || return 1
    validate_rs_ci_toolchain RS_CI_FUZZ_TOOLCHAIN "$RS_CI_FUZZ_TOOLCHAIN" || return 1
    validate_rs_ci_toolchain RS_CI_MIRI_TOOLCHAIN "$RS_CI_MIRI_TOOLCHAIN" || return 1
    validate_rs_ci_toolchain RS_CI_SANITIZER_TOOLCHAIN "$RS_CI_SANITIZER_TOOLCHAIN" || return 1

    export RS_CI_BUILD_TOOLCHAIN
    export RS_CI_FMT_TOOLCHAIN
    export RS_CI_CLIPPY_TOOLCHAIN
    export RS_CI_FUZZ_TOOLCHAIN
    export RS_CI_MIRI_TOOLCHAIN
    export RS_CI_SANITIZER_TOOLCHAIN
    export CARGO_LLVM_COV_VERSION
    export CARGO_FUZZ_VERSION
}

require_rs_ci_cargo_llvm_cov() {
    local installed_version

    if ! installed_version=$(cargo +"$RS_CI_BUILD_TOOLCHAIN" llvm-cov --version 2> /dev/null); then
        echo "error: cargo-llvm-cov $CARGO_LLVM_COV_VERSION is required" >&2
        return 1
    fi
    if [[ "$installed_version" != "cargo-llvm-cov $CARGO_LLVM_COV_VERSION"* ]]; then
        echo "error: cargo-llvm-cov $CARGO_LLVM_COV_VERSION is required; found $installed_version" >&2
        return 1
    fi
}

print_rs_ci_lint_versions() {
    echo "Rustfmt version: $(rustup run "$RS_CI_FMT_TOOLCHAIN" rustfmt --version)"
    echo "Clippy version: $(rustup run "$RS_CI_CLIPPY_TOOLCHAIN" clippy-driver --version)"
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    configure_rs_ci_toolchains
    echo "Build toolchain: $RS_CI_BUILD_TOOLCHAIN"
    echo "Rustfmt toolchain: $RS_CI_FMT_TOOLCHAIN"
    echo "Clippy toolchain: $RS_CI_CLIPPY_TOOLCHAIN"
    echo "Fuzz toolchain: $RS_CI_FUZZ_TOOLCHAIN"
    echo "Miri toolchain: $RS_CI_MIRI_TOOLCHAIN"
    echo "Sanitizer toolchain: $RS_CI_SANITIZER_TOOLCHAIN"
    echo "cargo-llvm-cov version: $CARGO_LLVM_COV_VERSION"
    echo "cargo-fuzz version: $CARGO_FUZZ_VERSION"
fi
