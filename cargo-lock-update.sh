#!/bin/bash
################################################################################
#
#    Copyright (c) 2025 - 2026 Haixing Hu.
#
#    SPDX-License-Identifier: Apache-2.0
#
#    Licensed under the Apache License, Version 2.0.
#
################################################################################
#
# Keeps the project and supported auxiliary Cargo.lock files in sync with their
# manifests. The root lockfile covers workspace packages such as Loom tests;
# independent helper crates (for example fuzz/) have their own lockfile.
#

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$SCRIPT_DIR}"
MODE="update"

usage() {
    cat <<'EOF_USAGE'
Usage: ./cargo-lock-update.sh [--check|--update]

Validate or regenerate Cargo.lock files for the project root, the conventional
fuzz/ and loom/ auxiliary crates, and manifests listed in
RS_CI_AUXILIARY_MANIFESTS (one path per line). Relative paths are resolved
against RS_CI_PROJECT_ROOT.

Options:
  --check   Fail when a lockfile is missing or stale; do not modify files.
  --update  Regenerate missing or stale lockfiles (the default).
  -h, --help
EOF_USAGE
}

die() {
    echo "error: $*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check)
            MODE="check"
            ;;
        --update)
            MODE="update"
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            die "unknown option '$1'"
            ;;
    esac
    shift
done

if [ ! -f "$PROJECT_ROOT/Cargo.toml" ]; then
    die "Cargo.toml was not found at '$PROJECT_ROOT/Cargo.toml'"
fi

cd "$PROJECT_ROOT"

MANIFESTS=()
add_manifest() {
    local manifest="$1"
    local existing

    [ -f "$manifest" ] || die "Cargo manifest '$manifest' was not found"
    for existing in "${MANIFESTS[@]}"; do
        [ "$existing" != "$manifest" ] || return
    done
    MANIFESTS+=("$manifest")
}

add_manifest "$PROJECT_ROOT/Cargo.toml"
for auxiliary_dir in fuzz loom; do
    if [ -f "$PROJECT_ROOT/$auxiliary_dir/Cargo.toml" ]; then
        add_manifest "$PROJECT_ROOT/$auxiliary_dir/Cargo.toml"
    fi
done

if [ -n "${RS_CI_AUXILIARY_MANIFESTS:-}" ]; then
    while IFS= read -r auxiliary_manifest; do
        [ -n "$auxiliary_manifest" ] || continue
        if [[ "$auxiliary_manifest" != /* ]]; then
            auxiliary_manifest="$PROJECT_ROOT/$auxiliary_manifest"
        fi
        add_manifest "$auxiliary_manifest"
    done <<< "$RS_CI_AUXILIARY_MANIFESTS"
fi

run_cargo() {
    if [ -n "${RS_CI_LOCKFILE_TOOLCHAIN:-${RS_CI_BUILD_TOOLCHAIN:-}}" ]; then
        cargo "+${RS_CI_LOCKFILE_TOOLCHAIN:-${RS_CI_BUILD_TOOLCHAIN}}" "$@"
    else
        cargo "$@"
    fi
}

lockfile_is_current() {
    local manifest="$1"

    run_cargo metadata \
        --manifest-path "$manifest" \
        --locked \
        --format-version 1 > /dev/null 2>&1
}

for manifest in "${MANIFESTS[@]}"; do
    if lockfile_is_current "$manifest"; then
        echo "Cargo.lock is current for $manifest"
        continue
    fi

    if [ "$MODE" = "check" ]; then
        echo "error: Cargo.lock is missing or stale for $manifest" >&2
        echo "       run ./align-ci.sh to regenerate supported lockfiles" >&2
        exit 1
    fi

    echo "==> cargo generate-lockfile --manifest-path $manifest"
    run_cargo generate-lockfile --manifest-path "$manifest"
    if ! lockfile_is_current "$manifest"; then
        die "Cargo.lock remains stale after updating '$manifest'"
    fi
done

echo "Cargo lockfiles are synchronized."
