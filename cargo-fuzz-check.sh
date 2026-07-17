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
# Conditionally builds and smoke-tests cargo-fuzz targets.
#

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$SCRIPT_DIR}"
RS_CI_FUZZ_MODE="${RS_CI_FUZZ_MODE:-smoke}"
RS_CI_FUZZ_TOOLCHAIN="${RS_CI_FUZZ_TOOLCHAIN:-${RS_CI_FMT_TOOLCHAIN:-${RUST_TOOLCHAIN:-nightly-2026-06-05}}}"
RS_CI_FUZZ_SECONDS_PER_TARGET="${RS_CI_FUZZ_SECONDS_PER_TARGET:-10}"
RS_CI_FUZZ_MAX_LEN="${RS_CI_FUZZ_MAX_LEN:-4096}"
TEMP_CORPUS=""

cleanup() {
    if [ -n "$TEMP_CORPUS" ] && [ -d "$TEMP_CORPUS" ]; then
        command rm -rf "$TEMP_CORPUS"
    fi
}
trap cleanup EXIT

die() {
    echo "error: $*" >&2
    exit 1
}

has_cargo_fuzz_manifest() {
    local manifest="$PROJECT_ROOT/fuzz/Cargo.toml"

    [ -f "$manifest" ] || return 1
    awk '
        /^\[package\.metadata\]$/ { metadata = 1; next }
        /^\[/ { metadata = 0 }
        metadata && /^[[:space:]]*cargo-fuzz[[:space:]]*=[[:space:]]*true[[:space:]]*(#.*)?$/ { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$manifest"
}

validate_configuration() {
    case "$RS_CI_FUZZ_MODE" in
        smoke | build-only | disabled) ;;
        *) die "RS_CI_FUZZ_MODE must be smoke, build-only, or disabled" ;;
    esac

    if [ "$RS_CI_FUZZ_MODE" = "smoke" ] \
        && ! [[ "$RS_CI_FUZZ_SECONDS_PER_TARGET" =~ ^[1-9][0-9]*$ ]]; then
        die "RS_CI_FUZZ_SECONDS_PER_TARGET must be a positive integer"
    fi
    if [ "$RS_CI_FUZZ_MODE" = "smoke" ] \
        && ! [[ "$RS_CI_FUZZ_MAX_LEN" =~ ^[1-9][0-9]*$ ]]; then
        die "RS_CI_FUZZ_MAX_LEN must be a positive integer"
    fi
}

require_cargo_fuzz() {
    if ! command -v cargo-fuzz > /dev/null 2>&1; then
        die "cargo-fuzz is required; install it with: cargo install cargo-fuzz"
    fi
}

run_target() {
    local target="$1"
    local writable_corpus
    local seed_corpus="$PROJECT_ROOT/fuzz/corpus/$target"

    echo "==> cargo fuzz build $target"
    cargo +"$RS_CI_FUZZ_TOOLCHAIN" fuzz build "$target"

    if [ "$RS_CI_FUZZ_MODE" = "build-only" ]; then
        return
    fi

    writable_corpus="$TEMP_CORPUS/$target"
    mkdir -p "$writable_corpus"
    echo "==> cargo fuzz run $target for ${RS_CI_FUZZ_SECONDS_PER_TARGET}s"
    if [ -d "$seed_corpus" ]; then
        cargo +"$RS_CI_FUZZ_TOOLCHAIN" fuzz run "$target" "$writable_corpus" "$seed_corpus" -- \
            "-max_total_time=$RS_CI_FUZZ_SECONDS_PER_TARGET" \
            "-max_len=$RS_CI_FUZZ_MAX_LEN"
    else
        cargo +"$RS_CI_FUZZ_TOOLCHAIN" fuzz run "$target" "$writable_corpus" -- \
            "-max_total_time=$RS_CI_FUZZ_SECONDS_PER_TARGET" \
            "-max_len=$RS_CI_FUZZ_MAX_LEN"
    fi
}

if [ "${1:-}" = "--is-configured" ]; then
    has_cargo_fuzz_manifest
    exit $?
fi

if [ "$#" -ne 0 ]; then
    die "usage: cargo-fuzz-check.sh [--is-configured]"
fi

if ! has_cargo_fuzz_manifest; then
    echo "cargo-fuzz is not configured; skipping."
    exit 0
fi

validate_configuration

if [ "$RS_CI_FUZZ_MODE" = "disabled" ]; then
    echo "cargo-fuzz checks are disabled; skipping."
    exit 0
fi

require_cargo_fuzz
cd "$PROJECT_ROOT"

targets_output=$(cargo +"$RS_CI_FUZZ_TOOLCHAIN" fuzz list)
mapfile -t targets < <(printf '%s\n' "$targets_output" | awk 'NF')
if [ "${#targets[@]}" -eq 0 ]; then
    die "cargo-fuzz is configured but reported no fuzz targets"
fi

if [ "$RS_CI_FUZZ_MODE" = "smoke" ]; then
    TEMP_CORPUS=$(mktemp -d "${TMPDIR:-/tmp}/rs-ci-fuzz.XXXXXX")
fi

for target in "${targets[@]}"; do
    run_target "$target"
done

echo "cargo-fuzz $RS_CI_FUZZ_MODE checks passed."
