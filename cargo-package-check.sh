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
packages=()
while IFS= read -r package; do
    [ -n "$package" ] && packages+=("$package")
done < <(
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

# Local sibling crates may have versions that have not been published to
# crates.io yet. Patch those path dependencies for each package verification
# command while keeping the packaged manifest registry-compatible. Keeping the
# patch set package-specific avoids Cargo warnings for unused patches.
for package in "${packages[@]}"; do
    package_config_args=()
    declare -A patched_dependencies=()
    while IFS=$'\t' read -r dependency_name dependency_path; do
        [ -n "$dependency_name" ] || continue
        [ -n "$dependency_path" ] || continue
        [ -d "$dependency_path" ] || continue
        if [ -z "${patched_dependencies[$dependency_name]+x}" ]; then
            package_config_args+=(
                --config
                "patch.crates-io.${dependency_name}.path=\"$dependency_path\""
            )
            patched_dependencies["$dependency_name"]="$dependency_path"
        fi
    done < <(
        jq -r --arg package "$package" '
            .packages[]
            | select(.name == $package)
            | .dependencies[]
            | select(.path != null)
            | [.name, .path]
            | @tsv
        ' <<< "$metadata"
    )

    cargo +"$RS_CI_BUILD_TOOLCHAIN" "${package_config_args[@]}" package \
        --package "$package" \
        --allow-dirty || {
        status=$?
        echo "Cargo package verification failed for package '$package'." >&2
        exit "$status"
    }
done
echo "Cargo package verification passed for ${#packages[@]} workspace package(s)."
