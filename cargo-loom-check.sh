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

load_loom_packages() {
    local metadata

    if ! command -v jq > /dev/null 2>&1; then
        die "required command 'jq' was not found"
    fi
    cd "$PROJECT_ROOT"
    metadata=$(cargo +"$RS_CI_BUILD_TOOLCHAIN" metadata --no-deps --format-version 1)
    mapfile -t LOOM_PACKAGES < <(
        jq -r '
            . as $metadata
            | .workspace_members[] as $member_id
            | .packages[]
            | select(.id == $member_id)
            | select(any(.dependencies[]; .name == "loom"))
            | .name
        ' <<< "$metadata"
    )
}

has_loom_dependency() {
    load_loom_packages
    [ "${#LOOM_PACKAGES[@]}" -gt 0 ]
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
for package in "${LOOM_PACKAGES[@]}"; do
    echo "==> discovering Loom model tests for $package"
    model_list=$(
        RUSTFLAGS="--cfg loom" cargo +"$RS_CI_BUILD_TOOLCHAIN" \
            test --package "$package" --release --all-features loom -- --list
    )
    model_count=$(printf '%s\n' "$model_list" | awk '
        /: test$/ { count += 1 }
        END { print count + 0 }
    ')
    if [ "$model_count" -eq 0 ]; then
        die "no Loom model tests were discovered for $package; model test names must contain 'loom'"
    fi
    printf '%s\n' "$model_list"
    echo "==> running $model_count Loom model test(s) for $package"
    RUSTFLAGS="--cfg loom" cargo +"$RS_CI_BUILD_TOOLCHAIN" \
        test --package "$package" --release --all-features --verbose loom
done
echo "Loom model checks passed."
