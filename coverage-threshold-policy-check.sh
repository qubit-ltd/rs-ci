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
# Guardrail: rs-ci must keep coverage thresholds enabled in every entry point.
# Run from ci-check.sh before coverage collection so accidental downgrades fail fast.
#

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

fail() {
    echo "error: coverage threshold policy violation: $1" >&2
    echo "Do not disable COVERAGE_ENFORCE_THRESHOLDS in rs-ci scripts or CI templates." >&2
    echo "For proc-macro or instrumentation gaps, use .rs-ci-coverage.json threshold_exempt_files." >&2
    exit 1
}

require_file() {
    local file="$1"

    if [ ! -f "$file" ]; then
        fail "required file '$file' was not found"
    fi
}

require_file "$SCRIPT_DIR/ci-check.sh"
require_file "$SCRIPT_DIR/coverage.sh"

if grep -Eq '(^|[[:space:]])COVERAGE_ENFORCE_THRESHOLDS=0([[:space:]]|\\|$)' \
    "$SCRIPT_DIR/ci-check.sh"; then
    fail "ci-check.sh must not set COVERAGE_ENFORCE_THRESHOLDS=0"
fi

if ! grep -q \
    'COVERAGE_ENFORCE_THRESHOLDS="${COVERAGE_ENFORCE_THRESHOLDS:-1}"' \
    "$SCRIPT_DIR/coverage.sh"; then
    fail 'coverage.sh must default COVERAGE_ENFORCE_THRESHOLDS to 1'
fi

if ! grep -q 'require_coverage_threshold_enforcement' "$SCRIPT_DIR/coverage.sh"; then
    fail "coverage.sh must call require_coverage_threshold_enforcement"
fi

workflow="$SCRIPT_DIR/.github/workflows/rust-ci.yml"
if [ -f "$workflow" ]; then
    if grep -A4 'coverage_enforce_thresholds:' "$workflow" | grep -q 'default: "0"'; then
        fail 'rust-ci.yml must default coverage_enforce_thresholds to "1"'
    fi
fi

circleci="$SCRIPT_DIR/.circleci/config.yml"
if [ -f "$circleci" ] \
    && grep -Eq '(^|[[:space:]])COVERAGE_ENFORCE_THRESHOLDS=0([[:space:]]|$)' \
        "$circleci"; then
    fail ".circleci/config.yml must not set COVERAGE_ENFORCE_THRESHOLDS=0"
fi

echo "Coverage threshold policy check passed"
