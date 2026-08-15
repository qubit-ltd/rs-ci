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

Initialize every configured first-level submodule when needed, then switch it
to its configured local branch and update it to the latest remote commit.

Options:
  --shallow     Shallow clone (passes --depth 1 to git submodule update)
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
while [ "$#" -gt 0 ]; do
    case "$1" in
        --shallow)
            shallow=1
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

mapfile -t submodule_path_keys < <(
    git config --file .gitmodules --name-only --get-regexp \
        '^submodule\..*\.path$'
)
if [ "${#submodule_path_keys[@]}" -eq 0 ]; then
    echo "error: .gitmodules does not define any submodules" >&2
    exit 1
fi

declare -a submodule_paths=()
declare -a submodule_branches=()
for path_key in "${submodule_path_keys[@]}"; do
    submodule_section="${path_key%.path}"
    submodule_path=$(git config --file .gitmodules --get "$path_key")
    submodule_branch=$(git config --file .gitmodules --get \
        "$submodule_section.branch" 2> /dev/null || true)
    if [ -z "$submodule_branch" ]; then
        echo "error: submodule '$submodule_path' has no branch configuration" >&2
        exit 1
    fi
    submodule_paths+=("$submodule_path")
    submodule_branches+=("$submodule_branch")
done

update_submodule() {
    local submodule_path="$1"
    local submodule_branch="$2"
    local submodule_git_dir="$PROJECT_ROOT/$submodule_path"
    local remote_ref="refs/remotes/origin/$submodule_branch"
    local local_ref="refs/heads/$submodule_branch"
    local remote_commit
    local local_commit

    if ! git -C "$submodule_git_dir" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        update_args=(submodule update --init --recursive)
        if [ "$shallow" -eq 1 ]; then
            update_args+=(--depth 1)
        fi
        update_args+=("$submodule_path")
        echo "==> git ${update_args[*]}"
        git "${update_args[@]}"
    else
        echo "==> submodule '$submodule_path' is already initialized"
    fi

    if ! git -C "$submodule_git_dir" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        echo "error: submodule '$submodule_path' is not a Git working tree after initialization" >&2
        return 1
    fi

    if [ -n "$(git -C "$submodule_git_dir" status --porcelain --untracked-files=all)" ]; then
        echo "error: submodule '$submodule_path' has uncommitted changes; refusing to switch or update it" >&2
        return 1
    fi

    echo "==> git -C $submodule_path fetch --prune origin $submodule_branch"
    git -C "$submodule_git_dir" fetch --prune origin \
        "+refs/heads/$submodule_branch:$remote_ref"

    if ! git -C "$submodule_git_dir" show-ref --verify --quiet "$remote_ref"; then
        echo "error: submodule '$submodule_path' remote 'origin' has no '$submodule_branch' branch" >&2
        return 1
    fi

    remote_commit=$(git -C "$submodule_git_dir" rev-parse "$remote_ref")
    if git -C "$submodule_git_dir" show-ref --verify --quiet "$local_ref"; then
        local_commit=$(git -C "$submodule_git_dir" rev-parse "$local_ref")
        if ! git -C "$submodule_git_dir" merge-base --is-ancestor "$local_commit" "$remote_commit"; then
            if git -C "$submodule_git_dir" merge-base --is-ancestor "$remote_commit" "$local_commit"; then
                echo "error: submodule '$submodule_path' local '$submodule_branch' is ahead of origin/$submodule_branch; refusing to discard local commits" >&2
            else
                echo "error: submodule '$submodule_path' local '$submodule_branch' has diverged from origin/$submodule_branch; resolve the history manually" >&2
            fi
            return 1
        fi

        echo "==> git -C $submodule_path switch $submodule_branch"
        git -C "$submodule_git_dir" switch "$submodule_branch"
        git -C "$submodule_git_dir" branch \
            --set-upstream-to="origin/$submodule_branch" "$submodule_branch"
        if [ "$local_commit" != "$remote_commit" ]; then
            echo "==> git -C $submodule_path merge --ff-only origin/$submodule_branch"
            git -C "$submodule_git_dir" merge --ff-only "origin/$submodule_branch"
        fi
    else
        echo "==> git -C $submodule_path switch --create $submodule_branch --track origin/$submodule_branch"
        git -C "$submodule_git_dir" switch --create "$submodule_branch" \
            --track "origin/$submodule_branch"
    fi

    echo "==> git -C $submodule_path submodule update --init --recursive"
    git -C "$submodule_git_dir" submodule update --init --recursive
}

for index in "${!submodule_paths[@]}"; do
    update_submodule "${submodule_paths[$index]}" "${submodule_branches[$index]}"
done

echo "Done."
