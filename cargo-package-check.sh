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
# Verify that the project can be packaged and that the packaged crate builds
# against its published dependency versions.
#

set -euo pipefail

RS_CI_BUILD_TOOLCHAIN="${RS_CI_BUILD_TOOLCHAIN:-1.94.0}"
PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$(pwd)}"
cd "$PROJECT_ROOT"

if ! command -v jq > /dev/null 2>&1; then
    echo "error: required command 'jq' was not found" >&2
    exit 1
fi

metadata=$(cargo +"$RS_CI_BUILD_TOOLCHAIN" metadata --no-deps --format-version 1)
mapfile -t packages < <(
    jq -r '
        . as $metadata
        | .workspace_members[] as $member_id
        | .packages[]
        | select(.id == $member_id)
        | select((.publish == null) or (.publish | length > 0))
        | .name
    ' <<< "$metadata"
)

if [ "${#packages[@]}" -eq 0 ]; then
    echo "No publishable workspace packages found; skipping Cargo package verification."
    exit 0
fi

for package in "${packages[@]}"; do
    if cargo +"$RS_CI_BUILD_TOOLCHAIN" package \
        --package "$package" \
        --allow-dirty; then
        continue
    else
        status=$?
        echo "Cargo package verification failed for $package." >&2
        exit "$status"
    fi
done
echo "Cargo package verification passed for ${#packages[@]} workspace package(s)."
