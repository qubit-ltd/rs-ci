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
# Rust project style checks that are not covered by rustfmt or Clippy.
#

set -euo pipefail

STYLE_SOURCE_DIR="${STYLE_SOURCE_DIR:-src}"
STYLE_TEST_DIR="${STYLE_TEST_DIR:-tests}"
STYLE_ENFORCE_INLINE_TESTS="${STYLE_ENFORCE_INLINE_TESTS:-1}"
STYLE_ENFORCE_TEST_FILE_NAMES="${STYLE_ENFORCE_TEST_FILE_NAMES:-1}"
STYLE_ENFORCE_SOURCE_TEST_PAIRS="${STYLE_ENFORCE_SOURCE_TEST_PAIRS:-1}"
STYLE_ENFORCE_PUBLIC_TYPE_FILES="${STYLE_ENFORCE_PUBLIC_TYPE_FILES:-1}"
STYLE_ENFORCE_EXPLICIT_IMPORTS="${STYLE_ENFORCE_EXPLICIT_IMPORTS:-1}"
STYLE_ENFORCE_AGGREGATION_FILES="${STYLE_ENFORCE_AGGREGATION_FILES:-1}"
STYLE_ENFORCE_COVERAGE_CFG="${STYLE_ENFORCE_COVERAGE_CFG:-1}"
STYLE_TYPE_VISIBILITY="${STYLE_TYPE_VISIBILITY:-public}"
STYLE_INCLUDE_TYPE_ALIASES="${STYLE_INCLUDE_TYPE_ALIASES:-0}"
STYLE_EXTRA_EXCLUDE_REGEX="${STYLE_EXTRA_EXCLUDE_REGEX:-}"
STYLE_ALLOWLIST_FILE="${STYLE_ALLOWLIST_FILE:-}"
STYLE_SKIP_TYPE_PATH_REGEX="${STYLE_SKIP_TYPE_PATH_REGEX:-(^|/)(lib|main|mod|macros)\\.rs$}"
STYLE_SKIP_SOURCE_TEST_PAIR_PATH_REGEX="${STYLE_SKIP_SOURCE_TEST_PAIR_PATH_REGEX:-(^|/)(lib|main|mod|macros)\\.rs$}"
STYLE_TEST_SUPPORT_DIR_REGEX="${STYLE_TEST_SUPPORT_DIR_REGEX:-(^|/)(support|common|fixtures|coverage_support)(/|$)}"

FAILURES=0

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/style/common.sh"
source "$script_dir/style/rules/tests.sh"
source "$script_dir/style/rules/types.sh"
source "$script_dir/style/rules/aggregation_imports.sh"
source "$script_dir/style/rules/coverage.sh"

# Purpose: Print CLI usage, environment toggles, and allow-comment conventions.
print_usage() {
    echo "Usage: ./style-check.sh [options]"
    echo ""
    echo "Options:"
    echo "  help       Show this help information"
    echo ""
    echo "Environment:"
    echo "  RS_CI_PROJECT_ROOT=${RS_CI_PROJECT_ROOT:-<script directory>}"
    echo "  STYLE_SOURCE_DIR=${STYLE_SOURCE_DIR}"
    echo "  STYLE_TEST_DIR=${STYLE_TEST_DIR}"
    echo "  STYLE_ENFORCE_INLINE_TESTS=${STYLE_ENFORCE_INLINE_TESTS}"
    echo "  STYLE_ENFORCE_TEST_FILE_NAMES=${STYLE_ENFORCE_TEST_FILE_NAMES}"
    echo "  STYLE_ENFORCE_SOURCE_TEST_PAIRS=${STYLE_ENFORCE_SOURCE_TEST_PAIRS}"
    echo "  STYLE_ENFORCE_PUBLIC_TYPE_FILES=${STYLE_ENFORCE_PUBLIC_TYPE_FILES}"
    echo "  STYLE_ENFORCE_EXPLICIT_IMPORTS=${STYLE_ENFORCE_EXPLICIT_IMPORTS}"
    echo "  STYLE_ENFORCE_AGGREGATION_FILES=${STYLE_ENFORCE_AGGREGATION_FILES}"
    echo "  STYLE_ENFORCE_COVERAGE_CFG=${STYLE_ENFORCE_COVERAGE_CFG}"
    echo "  STYLE_TYPE_VISIBILITY=${STYLE_TYPE_VISIBILITY}      # public or all"
    echo "  STYLE_INCLUDE_TYPE_ALIASES=${STYLE_INCLUDE_TYPE_ALIASES}"
    echo "  STYLE_EXTRA_EXCLUDE_REGEX=${STYLE_EXTRA_EXCLUDE_REGEX}"
    echo "  STYLE_ALLOWLIST_FILE=${STYLE_ALLOWLIST_FILE:-<project root>/.qubit-style-allowlist}"
    echo "  STYLE_SKIP_TYPE_PATH_REGEX=${STYLE_SKIP_TYPE_PATH_REGEX}"
    echo "  STYLE_SKIP_SOURCE_TEST_PAIR_PATH_REGEX=${STYLE_SKIP_SOURCE_TEST_PAIR_PATH_REGEX}"
    echo "  STYLE_TEST_SUPPORT_DIR_REGEX=${STYLE_TEST_SUPPORT_DIR_REGEX}"
    echo ""
    echo "File-level allow comments:"
    echo "  // qubit-style: allow all"
    echo "  // qubit-style: allow inline-tests"
    echo "  // qubit-style: allow test-file-name"
    echo "  // qubit-style: allow source-test-pair"
    echo "  // qubit-style: allow public-type-layout"
    echo "  // qubit-style: allow multiple-public-types"
    echo "  // qubit-style: allow type-file-name"
    echo "  // qubit-style: allow explicit-imports"
    echo "  // qubit-style: allow coverage-cfg"
    echo ""
    echo "The multiple-public-types allow comment also requires a project-level"
    echo "allowlist entry in STYLE_ALLOWLIST_FILE using this format:"
    echo "  multiple-public-types | src/example.rs | Reason for keeping types together"
    echo ""
    echo "The coverage-cfg allow comment also requires a project-level"
    echo "allowlist entry in STYLE_ALLOWLIST_FILE using this format:"
    echo "  coverage-cfg | src/example.rs | Reason why coverage cfg is unavoidable"
}

# Purpose: Parse arguments, initialize context, and run all configured style rules.
main() {
    local arg="${1:-}"
    local source_root
    local test_root

    case "$arg" in
        "" )
            ;;
        help | --help | -h )
            print_usage
            exit 0
            ;;
        * )
            echo "error: unknown argument '$arg'" >&2
            print_usage >&2
            exit 1
            ;;
    esac

    require_command awk
    require_command basename
    require_command find
    require_command grep
    require_command sed
    require_command tr
    require_command wc

    PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$script_dir}"
    if [ -z "$STYLE_ALLOWLIST_FILE" ]; then
        STYLE_ALLOWLIST_FILE="$PROJECT_ROOT/.qubit-style-allowlist"
    fi
    cd "$PROJECT_ROOT"

    source_root="$PROJECT_ROOT/$STYLE_SOURCE_DIR"
    test_root="$PROJECT_ROOT/$STYLE_TEST_DIR"

    echo "Running Rust style checks in $PROJECT_ROOT"
    echo ""

    check_inline_tests "$source_root"
    check_test_file_names "$test_root"
    check_source_test_pairs "$source_root" "$test_root"
    check_public_type_files "$source_root"
    check_aggregation_files "$source_root" "$test_root"
    check_explicit_imports "$source_root" "$test_root"
    check_coverage_cfg "$source_root"

    echo ""
    if [ "$FAILURES" -gt 0 ]; then
        echo "Rust style checks failed with $FAILURES issue(s)."
        exit 1
    fi

    echo "Rust style checks passed."
}

main "$@"
