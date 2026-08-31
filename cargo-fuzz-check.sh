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
# shellcheck source=toolchains.sh
source "$SCRIPT_DIR/toolchains.sh"
configure_rs_ci_toolchains

PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$SCRIPT_DIR}"
RS_CI_FUZZ_MODE="${RS_CI_FUZZ_MODE:-smoke}"
RS_CI_FUZZ_SECONDS_PER_TARGET="${RS_CI_FUZZ_SECONDS_PER_TARGET:-10}"
RS_CI_FUZZ_MAX_LEN="${RS_CI_FUZZ_MAX_LEN:-4096}"
TEMP_WORKSPACE=""

cleanup() {
    if [ -n "$TEMP_WORKSPACE" ] && [ -d "$TEMP_WORKSPACE" ]; then
        command rm -rf "$TEMP_WORKSPACE"
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

leak_detection_disabled_asan_options() {
    if [ -n "${ASAN_OPTIONS:-}" ]; then
        printf '%s:detect_leaks=0' "$ASAN_OPTIONS"
    else
        printf '%s' 'detect_leaks=0'
    fi
}

run_target() {
    local target="$1"
    local writable_corpus
    local seed_corpus="$PROJECT_ROOT/fuzz/corpus/$target"
    local artifact_prefix
    local run_log
    local run_status
    local retry_asan_options
    local -a corpus_arguments

    echo "==> cargo fuzz build $target"
    cargo +"$RS_CI_FUZZ_TOOLCHAIN" fuzz build "$target"

    if [ "$RS_CI_FUZZ_MODE" = "build-only" ]; then
        return
    fi

    writable_corpus="$TEMP_WORKSPACE/corpus/$target"
    artifact_prefix="$TEMP_WORKSPACE/artifacts/$target"
    run_log="$TEMP_WORKSPACE/logs/$target.log"
    mkdir -p "$writable_corpus"
    mkdir -p "$artifact_prefix"
    mkdir -p "$(dirname "$run_log")"
    corpus_arguments=("$target" "$writable_corpus")
    if [ -d "$seed_corpus" ]; then
        corpus_arguments+=("$seed_corpus")
    fi
    echo "==> cargo fuzz run $target for ${RS_CI_FUZZ_SECONDS_PER_TARGET}s"
    if cargo +"$RS_CI_FUZZ_TOOLCHAIN" fuzz run "${corpus_arguments[@]}" -- \
            "-max_total_time=$RS_CI_FUZZ_SECONDS_PER_TARGET" \
            "-max_len=$RS_CI_FUZZ_MAX_LEN" \
            "-artifact_prefix=$artifact_prefix/" 2>&1 | tee "$run_log"; then
        return
    fi
    run_status=${PIPESTATUS[0]}
    if ! grep -Fq 'LeakSanitizer does not work under ptrace' "$run_log"; then
        return "$run_status"
    fi

    retry_asan_options=$(leak_detection_disabled_asan_options)
    echo "warning: cargo-fuzz target '$target' cannot run LeakSanitizer under ptrace; retrying with LeakSanitizer disabled" >&2
    ASAN_OPTIONS="$retry_asan_options" cargo +"$RS_CI_FUZZ_TOOLCHAIN" fuzz run "${corpus_arguments[@]}" -- \
        "-max_total_time=$RS_CI_FUZZ_SECONDS_PER_TARGET" \
        "-max_len=$RS_CI_FUZZ_MAX_LEN" \
        "-artifact_prefix=$artifact_prefix/"
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
targets=()
while IFS= read -r target; do
    if [ -n "$target" ]; then
        targets+=("$target")
    fi
done < <(printf '%s\n' "$targets_output" | awk 'NF')
if [ "${#targets[@]}" -eq 0 ]; then
    die "cargo-fuzz is configured but reported no fuzz targets"
fi

if [ "$RS_CI_FUZZ_MODE" = "smoke" ]; then
    TEMP_WORKSPACE=$(mktemp -d "${TMPDIR:-/tmp}/rs-ci-fuzz.XXXXXX")
fi

for target in "${targets[@]}"; do
    run_target "$target"
done

echo "cargo-fuzz $RS_CI_FUZZ_MODE checks passed."
