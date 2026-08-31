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
# Runs Miri only for workspace packages that explicitly opt in.
#

set -euo pipefail

print_usage() {
    echo "Usage: ./cargo-miri-check.sh [--is-configured]" >&2
}

if [ "$#" -eq 0 ]; then
    DETECT_ONLY=0
elif [ "$#" -eq 1 ] && [ "$1" = "--is-configured" ]; then
    DETECT_ONLY=1
else
    print_usage
    exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$SCRIPT_DIR}"
METADATA_SCRIPT="$SCRIPT_DIR/rs-ci-metadata.sh"

if [ ! -x "$METADATA_SCRIPT" ]; then
    echo "error: required executable '$METADATA_SCRIPT' was not found" >&2
    exit 2
fi

# shellcheck source=toolchains.sh
source "$SCRIPT_DIR/toolchains.sh"
configure_rs_ci_toolchains

set +e
CONFIG_OUTPUT=$(RS_CI_PROJECT_ROOT="$PROJECT_ROOT" \
    "$METADATA_SCRIPT" miri-configs)
METADATA_STATUS=$?
set -e
if [ "$METADATA_STATUS" -ne 0 ]; then
    exit "$METADATA_STATUS"
fi

CONFIGS=()
while IFS= read -r config; do
    if [ -n "$config" ]; then
        CONFIGS+=("$config")
    fi
done <<< "$CONFIG_OUTPUT"

if [ "${#CONFIGS[@]}" -eq 0 ]; then
    if [ "$DETECT_ONLY" -eq 1 ]; then
        exit 1
    fi
    echo "Miri is not configured; skipping."
    exit 0
fi

if [ "$DETECT_ONLY" -eq 1 ]; then
    exit 0
fi

miri_target_dir() {
    local base="${CARGO_TARGET_DIR:-$PROJECT_ROOT/target/rs-ci}"
    printf '%s/miri' "$base"
}

compute_miri_input_stamp() {
    {
        printf 'toolchain=%s\n' "$RS_CI_MIRI_TOOLCHAIN"
        if [ -f "$PROJECT_ROOT/Cargo.lock" ]; then
            cat "$PROJECT_ROOT/Cargo.lock"
        else
            printf 'missing-lock\n'
        fi
    }
}

ensure_fresh_miri_target_cache() {
    local miri_target="$1"
    local stamp_file="$miri_target/.rs-ci-miri-input-stamp"

    if [ -f "$stamp_file" ] && cmp -s <(compute_miri_input_stamp) "$stamp_file"; then
        return 0
    fi

    if [ -d "$miri_target" ]; then
        echo "Miri build inputs changed; clearing '$miri_target'"
        rm -rf "$miri_target"
    fi

    mkdir -p "$miri_target"
    compute_miri_input_stamp > "$stamp_file"
}

cd "$PROJECT_ROOT"
ensure_fresh_miri_target_cache "$(miri_target_dir)"
for config in "${CONFIGS[@]}"; do
    package=$(jq -r '.name' <<< "$config")
    TEST_ARGS=()
    while IFS= read -r -d '' argument; do
        TEST_ARGS+=("$argument")
    done < <(jq -j '.test_args[] | . + "\u0000"' <<< "$config")
    echo "Running Miri for package '$package'"
    miri_args=(
        --all-features
        --package "$package"
    )
    if [ ${#TEST_ARGS[@]} -gt 0 ]; then
        miri_args+=("${TEST_ARGS[@]}")
    fi
    PROPTEST_DISABLE_FAILURE_PERSISTENCE=1 \
    PROPTEST_CASES=8 \
    MIRIFLAGS="${MIRIFLAGS:+$MIRIFLAGS }-Zmiri-disable-isolation" \
    cargo +"$RS_CI_MIRI_TOOLCHAIN" miri test "${miri_args[@]}"
done
