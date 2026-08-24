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

cd "$PROJECT_ROOT"
for config in "${CONFIGS[@]}"; do
    package=$(jq -r '.name' <<< "$config")
    TEST_ARGS=()
    while IFS= read -r -d '' argument; do
        TEST_ARGS+=("$argument")
    done < <(jq -j '.test_args[] | . + "\u0000"' <<< "$config")
    echo "Running Miri for package '$package'"
    PROPTEST_DISABLE_FAILURE_PERSISTENCE=1 \
    PROPTEST_CASES=8 \
    MIRIFLAGS="${MIRIFLAGS:+$MIRIFLAGS }-Zmiri-disable-isolation" \
    cargo +"$RS_CI_MIRI_TOOLCHAIN" miri test \
        --all-features \
        --package "$package" \
        "${TEST_ARGS[@]}"
done
