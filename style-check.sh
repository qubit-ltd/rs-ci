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

STYLE_SOURCE_DIR_EXPLICIT="${STYLE_SOURCE_DIR+x}"
STYLE_TEST_DIR_EXPLICIT="${STYLE_TEST_DIR+x}"
STYLE_SOURCE_DIR="${STYLE_SOURCE_DIR:-src}"
STYLE_TEST_DIR="${STYLE_TEST_DIR:-tests}"
STYLE_ENFORCE_INLINE_TESTS="${STYLE_ENFORCE_INLINE_TESTS:-0}"
STYLE_ENFORCE_TEST_FILE_NAMES="${STYLE_ENFORCE_TEST_FILE_NAMES:-1}"
STYLE_ENFORCE_TEST_REDIRECTS="${STYLE_ENFORCE_TEST_REDIRECTS:-1}"
STYLE_ENFORCE_SOURCE_TEST_PAIRS="${STYLE_ENFORCE_SOURCE_TEST_PAIRS:-0}"
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

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=toolchains.sh
source "$script_dir/toolchains.sh"
configure_rs_ci_toolchains
source "$script_dir/style/common.sh"
source "$script_dir/style/rules/tests.sh"
source "$script_dir/style/rules/types.sh"
source "$script_dir/style/rules/aggregation_imports.sh"
source "$script_dir/style/rules/rust_style.sh"
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
    echo "  STYLE_ENFORCE_TEST_REDIRECTS=${STYLE_ENFORCE_TEST_REDIRECTS}"
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

# Purpose: Check whether a crate root test-gates its src/tests module tree.
has_cfg_test_module_declaration() {
    local source_root="$1"
    local crate_root

    for crate_root in "$source_root/lib.rs" "$source_root/main.rs"; do
        [ -f "$crate_root" ] || continue
        awk '
            /^[[:space:]]*#\[[[:space:]]*cfg[[:space:]]*\([[:space:]]*test[[:space:]]*\)[[:space:]]*\][[:space:]]*$/ {
                pending_cfg_test = 1
                next
            }
            pending_cfg_test \
                && /^[[:space:]]*mod[[:space:]]+tests[[:space:]]*;[[:space:]]*$/ {
                found = 1
                next
            }
            pending_cfg_test \
                && (/^[[:space:]]*$/ || /^[[:space:]]*\/\// || /^[[:space:]]*#\[/) {
                next
            }
            { pending_cfg_test = 0 }
            END {
                exit found ? 0 : 1
            }
        ' "$crate_root" && return 0
    done
    return 1
}

# Purpose: Run all configured rules for one Cargo package or explicit directory set.
run_style_checks() {
    local source_root="$1"
    local test_root="$2"
    local internal_test_root="$3"
    local original_extra_exclude_regex="$STYLE_EXTRA_EXCLUDE_REGEX"
    local internal_test_rel
    local internal_test_regex

    internal_test_rel="${internal_test_root#"$PROJECT_ROOT"/}"
    if [ -d "$internal_test_root" ]; then
        if has_cfg_test_module_declaration "$source_root"; then
            internal_test_regex="^${internal_test_rel}(/|$)"
            if [ -n "$STYLE_EXTRA_EXCLUDE_REGEX" ]; then
                STYLE_EXTRA_EXCLUDE_REGEX="(${STYLE_EXTRA_EXCLUDE_REGEX})|(${internal_test_regex})"
            else
                STYLE_EXTRA_EXCLUDE_REGEX="$internal_test_regex"
            fi
        else
            report_error "$internal_test_rel" "0" \
                "src/tests must be connected from the crate root with #[cfg(test)] mod tests;"
        fi
    fi

    # Production-only rules must not classify src/tests as production source.
    check_inline_tests "$source_root"
    check_source_test_pairs "$source_root" "$test_root"
    check_public_type_files "$source_root"
    check_coverage_cfg "$source_root"
    if [ "$STYLE_ENFORCE_AGGREGATION_FILES" = "1" ]; then
        check_aggregation_files_in_root "$source_root"
    fi
    if [ "$STYLE_ENFORCE_EXPLICIT_IMPORTS" = "1" ]; then
        check_explicit_imports_in_root "$source_root"
        check_rust_style_in_root "$source_root"
    fi

    STYLE_EXTRA_EXCLUDE_REGEX="$original_extra_exclude_regex"

    # External and crate-internal test trees share test-code conventions.
    check_test_file_names "$test_root"
    check_test_file_names "$internal_test_root"
    check_test_redirects "$test_root"
    check_test_redirects "$internal_test_root"
    if [ "$STYLE_ENFORCE_AGGREGATION_FILES" = "1" ]; then
        check_aggregation_files_in_root "$test_root"
        check_aggregation_files_in_root "$internal_test_root"
    fi
    if [ "$STYLE_ENFORCE_EXPLICIT_IMPORTS" = "1" ]; then
        check_explicit_imports_in_root "$test_root"
        check_explicit_imports_in_root "$internal_test_root"
        check_rust_style_in_root "$test_root"
        check_rust_style_in_root "$internal_test_root"
    fi
}

# Purpose: Run style rules for every Cargo workspace member.
run_workspace_style_checks() {
    local metadata
    local package_rows
    local package_name
    local manifest_path
    local package_root
    local source_root
    local test_root
    local internal_test_root

    require_command cargo
    require_command jq
    metadata=$(cargo +"$RS_CI_BUILD_TOOLCHAIN" metadata --no-deps --format-version 1)
    package_rows=$(jq -r '
        . as $metadata
        | .workspace_members[] as $member_id
        | .packages[]
        | select(.id == $member_id)
        | [.name, .manifest_path]
        | @tsv
    ' <<< "$metadata")
    if [ -z "$package_rows" ]; then
        echo "error: Cargo metadata did not report any workspace default members" >&2
        exit 1
    fi

    while IFS=$'\t' read -r package_name manifest_path; do
        package_root=$(dirname "$manifest_path")
        source_root="$package_root/src"
        test_root="$package_root/tests"
        internal_test_root="$package_root/src/tests"
        STYLE_SOURCE_DIR="${source_root#"$PROJECT_ROOT"/}"
        STYLE_TEST_DIR="${test_root#"$PROJECT_ROOT"/}"
        echo "Checking Cargo package: $package_name"
        run_style_checks "$source_root" "$test_root" "$internal_test_root"
    done <<< "$package_rows"
}

# Purpose: Parse arguments, initialize context, and run all configured style rules.
main() {
    local arg="${1:-}"
    local source_root
    local test_root
    local internal_test_root

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
    require_command dirname
    require_command find
    require_command grep
    require_command sed
    require_command tr
    require_command wc

    PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$script_dir}"
    # Resolve symlinks so paths from cargo metadata and find share one root.
    PROJECT_ROOT=$(cd "$PROJECT_ROOT" && pwd -P)
    if [ -z "$STYLE_ALLOWLIST_FILE" ]; then
        STYLE_ALLOWLIST_FILE="$PROJECT_ROOT/.qubit-style-allowlist"
    fi
    cd "$PROJECT_ROOT"

    echo "Running Rust style checks in $PROJECT_ROOT"
    echo ""

    if [ -n "$STYLE_SOURCE_DIR_EXPLICIT" ] || [ -n "$STYLE_TEST_DIR_EXPLICIT" ]; then
        source_root="$PROJECT_ROOT/$STYLE_SOURCE_DIR"
        test_root="$PROJECT_ROOT/$STYLE_TEST_DIR"
        internal_test_root="$source_root/tests"
        run_style_checks "$source_root" "$test_root" "$internal_test_root"
    else
        run_workspace_style_checks
    fi

    echo ""
    if [ "$FAILURES" -gt 0 ]; then
        echo "Rust style checks failed with $FAILURES issue(s)."
        exit 1
    fi

    echo "Rust style checks passed."
}

main "$@"
