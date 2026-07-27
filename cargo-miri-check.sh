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
PACKAGE_OUTPUT=$(RS_CI_PROJECT_ROOT="$PROJECT_ROOT" \
    "$METADATA_SCRIPT" miri-packages)
METADATA_STATUS=$?
set -e
if [ "$METADATA_STATUS" -ne 0 ]; then
    exit "$METADATA_STATUS"
fi

PACKAGES=()
while IFS= read -r package; do
    if [ -n "$package" ]; then
        PACKAGES+=("$package")
    fi
done <<< "$PACKAGE_OUTPUT"

if [ "${#PACKAGES[@]}" -eq 0 ]; then
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
for package in "${PACKAGES[@]}"; do
    echo "Running Miri for package '$package'"
    cargo +"$RS_CI_MIRI_TOOLCHAIN" miri test \
        --all-features \
        --package "$package"
done
