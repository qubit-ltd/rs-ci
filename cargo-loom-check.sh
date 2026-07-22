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
# Conditionally runs discovered Loom model tests for projects declaring Loom.
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

has_loom_dependency() {
    local manifest="$PROJECT_ROOT/Cargo.toml"

    [ -f "$manifest" ] || return 1
    awk '
        /^\[(dev-)?dependencies\]$/ { dependencies = 1; next }
        /^\[/ { dependencies = 0 }
        dependencies && /^[[:space:]]*loom[[:space:]]*=/ { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$manifest"
}

if [ "${1:-}" = "--is-configured" ]; then
    has_loom_dependency
    exit $?
fi

if [ "$#" -ne 0 ]; then
    die "usage: cargo-loom-check.sh [--is-configured]"
fi

if ! has_loom_dependency; then
    echo "loom is not configured; skipping."
    exit 0
fi

cd "$PROJECT_ROOT"
echo "==> discovering Loom model tests"
model_list=$(
    RUSTFLAGS="--cfg loom" cargo +"$RS_CI_BUILD_TOOLCHAIN" \
        test --release --all-features loom -- --list
)
model_count=$(printf '%s\n' "$model_list" | awk '
    /: test$/ { count += 1 }
    END { print count + 0 }
')
if [ "$model_count" -eq 0 ]; then
    die "no Loom model tests were discovered; model test names must contain 'loom'"
fi
printf '%s\n' "$model_list"
echo "==> running $model_count Loom model test(s)"
RUSTFLAGS="--cfg loom" cargo +"$RS_CI_BUILD_TOOLCHAIN" \
    test --release --all-features --verbose loom
echo "Loom model checks passed."
