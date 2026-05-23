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
# Sync and update Git submodules from the repository root.
# Run from repo root: ./update-submodule.sh
# By default, updates submodules to the latest commit on their remote tracking
# branches.
#

set -euo pipefail

usage() {
    cat <<'EOF_USAGE'
Usage: ./update-submodule.sh [options]

Run git submodule sync / update from the repository root; updates all submodules
to their remote tracking branch by default.

Options:
  --shallow     Shallow clone (passes --depth 1 to git submodule update)
  --no-remote   Use the commits recorded by the superproject instead of remote tracking branches
  -h, --help    Show this help

Environment:
  GIT_SUBMODULE_DEPTH   If set to 1, same as --shallow
EOF_USAGE
}

require_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        echo "error: required command '$1' was not found" >&2
        exit 1
    fi
}

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$PROJECT_ROOT"

shallow=0
remote=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --shallow)
            shallow=1
            ;;
        --no-remote)
            remote=0
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

if [ "${GIT_SUBMODULE_DEPTH:-}" = "1" ]; then
    shallow=1
fi

require_command git

if [ ! -f .gitmodules ]; then
    echo "error: .gitmodules not found in the current directory; cannot update submodules" >&2
    exit 1
fi

echo "==> git submodule sync --recursive"
git submodule sync --recursive

update_args=(submodule update --init --recursive)
if [ "$shallow" -eq 1 ]; then
    update_args+=(--depth 1)
fi
if [ "$remote" -eq 1 ]; then
    update_args+=(--remote)
fi

echo "==> git ${update_args[*]}"
git "${update_args[@]}"

echo "Done."
