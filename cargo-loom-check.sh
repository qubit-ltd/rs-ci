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
# Conditionally runs Loom model tests for projects declaring a Loom dev dependency.
#

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=toolchains.sh
source "$SCRIPT_DIR/toolchains.sh"
configure_rs_ci_toolchains

PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$SCRIPT_DIR}"

die() {
    echo "error: $*" >&2
    exit 1
}

has_loom_dev_dependency() {
    local manifest="$PROJECT_ROOT/Cargo.toml"

    [ -f "$manifest" ] || return 1
    awk '
        /^\[dev-dependencies\]$/ { dependencies = 1; next }
        /^\[/ { dependencies = 0 }
        dependencies && /^[[:space:]]*loom[[:space:]]*=/ { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$manifest"
}

if [ "${1:-}" = "--is-configured" ]; then
    has_loom_dev_dependency
    exit $?
fi

if [ "$#" -ne 0 ]; then
    die "usage: cargo-loom-check.sh [--is-configured]"
fi

if ! has_loom_dev_dependency; then
    echo "loom is not configured; skipping."
    exit 0
fi

cd "$PROJECT_ROOT"
echo "==> RUSTFLAGS=--cfg loom cargo +$RS_CI_BUILD_TOOLCHAIN test --release --all-features --verbose"
RUSTFLAGS="--cfg loom" cargo +"$RS_CI_BUILD_TOOLCHAIN" test --release --all-features --verbose
echo "Loom model checks passed."
