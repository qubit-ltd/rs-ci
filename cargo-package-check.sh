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

PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$(pwd)}"
cd "$PROJECT_ROOT"

if cargo package --allow-dirty; then
    echo "Cargo package verification passed."
else
    status=$?
    echo "Cargo package verification failed." >&2
    exit "$status"
fi
