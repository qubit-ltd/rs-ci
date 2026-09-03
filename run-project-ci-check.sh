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
# Runs an optional project-owned CI hook from the project root.
#

set -euo pipefail

PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$PWD}"
PROJECT_HOOK="$PROJECT_ROOT/project-ci-check.sh"

if [ ! -e "$PROJECT_HOOK" ]; then
    echo "No project-specific CI hook found; skipping."
    exit 0
fi

if [ ! -f "$PROJECT_HOOK" ]; then
    echo "Project-specific CI hook '$PROJECT_HOOK' is not a regular file" >&2
    exit 1
fi

if [ ! -x "$PROJECT_HOOK" ]; then
    echo "Project-specific CI hook '$PROJECT_HOOK' is not executable" >&2
    echo "Please run: chmod +x $PROJECT_HOOK" >&2
    exit 1
fi

cd "$PROJECT_ROOT"
"$PROJECT_HOOK"

