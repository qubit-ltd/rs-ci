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
# Code coverage testing script.
# Uses cargo-llvm-cov to generate coverage reports.
#

set -euo pipefail

MIN_FUNCTION_COVERAGE="${MIN_FUNCTION_COVERAGE:-100}"
MIN_LINE_COVERAGE="${MIN_LINE_COVERAGE:-95}"
MIN_REGION_COVERAGE="${MIN_REGION_COVERAGE:-95}"
COVERAGE_SOURCE_DIR="${COVERAGE_SOURCE_DIR:-src}"
COVERAGE_EXTRA_EXCLUDE_REGEX="${COVERAGE_EXTRA_EXCLUDE_REGEX:-}"
COVERAGE_OPEN_HTML="${COVERAGE_OPEN_HTML:-1}"
COVERAGE_ENFORCE_THRESHOLDS="${COVERAGE_ENFORCE_THRESHOLDS:-1}"

print_usage() {
    echo "Usage: ./coverage.sh [format] [options]"
    echo ""
    echo "Format options:"
    echo "  html       Generate HTML report and open it in a browser by default"
    echo "  text       Output text format report to terminal and target/llvm-cov/coverage.txt"
    echo "  lcov       Generate LCOV format report"
    echo "  json       Generate JSON report and enforce per-source thresholds"
    echo "  cobertura  Generate Cobertura XML format report"
    echo "  all        Generate all report formats and enforce per-source thresholds"
    echo "  help       Show this help information"
    echo ""
    echo "Options:"
    echo "  --clean    Clean old coverage data before running"
    echo ""
    echo "Environment:"
    echo "  MIN_FUNCTION_COVERAGE=${MIN_FUNCTION_COVERAGE}"
    echo "  MIN_LINE_COVERAGE=${MIN_LINE_COVERAGE}     # required: > value"
    echo "  MIN_REGION_COVERAGE=${MIN_REGION_COVERAGE} # required: > value"
    echo "  COVERAGE_SOURCE_DIR=${COVERAGE_SOURCE_DIR}"
    echo "  COVERAGE_OPEN_HTML=${COVERAGE_OPEN_HTML}"
    echo "  COVERAGE_ENFORCE_THRESHOLDS=${COVERAGE_ENFORCE_THRESHOLDS}"
}

require_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        echo "error: required command '$1' was not found" >&2
        exit 1
    fi
}

detect_package_name() {
    awk -F'"' '/^[[:space:]]*name[[:space:]]*=/ { print $2; exit }' Cargo.toml
}

build_exclude_pattern() {
    local current_crate_name="$1"
    local workspace_root="$2"
    local other_crates=""
    local crate_dir
    local crate_name

    for crate_dir in "$workspace_root"/*/; do
        [ -d "$crate_dir" ] || continue
        [ -f "$crate_dir/Cargo.toml" ] || continue
        crate_name=$(basename "$crate_dir")
        if [ "$crate_name" != "$current_crate_name" ]; then
            if [ -z "$other_crates" ]; then
                other_crates="$crate_name"
            else
                other_crates="$other_crates|$crate_name"
            fi
        fi
    done

    local pattern="(\.cargo/registry|\.rustup/"
    if [ -n "$other_crates" ]; then
        pattern="$pattern|/($other_crates)/"
    fi
    if [ -n "$COVERAGE_EXTRA_EXCLUDE_REGEX" ]; then
        pattern="$pattern|$COVERAGE_EXTRA_EXCLUDE_REGEX"
    fi
    pattern="$pattern)"

    printf '%s\n' "$pattern"
}

check_json_coverage() {
    local coverage_json="$1"
    local source_prefix="$2"
    local failures

    require_command jq

    if [ ! -f "$coverage_json" ]; then
        echo "error: coverage JSON not found: $coverage_json" >&2
        exit 1
    fi

    failures=$(jq -r \
        --arg source_prefix "$source_prefix" \
        --argjson min_functions "$MIN_FUNCTION_COVERAGE" \
        --argjson min_lines "$MIN_LINE_COVERAGE" \
        --argjson min_regions "$MIN_REGION_COVERAGE" \
        '
        .data[].files[]
        | select(.filename | startswith($source_prefix))
        | .filename as $file
        | .summary as $summary
        | select(
            (($summary.functions.count > 0) and ($summary.functions.percent < $min_functions))
            or (($summary.lines.count > 0) and ($summary.lines.percent <= $min_lines))
            or (($summary.regions.count > 0) and ($summary.regions.percent <= $min_regions))
        )
        | "\($file): functions=\($summary.functions.percent)% (\($summary.functions.covered)/\($summary.functions.count)), lines=\($summary.lines.percent)% (\($summary.lines.covered)/\($summary.lines.count)), regions=\($summary.regions.percent)% (\($summary.regions.covered)/\($summary.regions.count))"
        ' "$coverage_json")

    if [ -n "$failures" ]; then
        echo "error: per-source coverage thresholds failed" >&2
        echo "$failures" >&2
        echo "" >&2
        echo "required: functions >= ${MIN_FUNCTION_COVERAGE}%, lines > ${MIN_LINE_COVERAGE}%, regions > ${MIN_REGION_COVERAGE}%" >&2
        exit 1
    fi

    echo "Coverage thresholds satisfied:"
    echo "  functions >= ${MIN_FUNCTION_COVERAGE}%"
    echo "  lines > ${MIN_LINE_COVERAGE}%"
    echo "  regions > ${MIN_REGION_COVERAGE}%"
}

maybe_check_json_coverage() {
    local coverage_json="$1"
    local source_prefix="$2"

    if [ "$COVERAGE_ENFORCE_THRESHOLDS" = "1" ]; then
        check_json_coverage "$coverage_json" "$source_prefix"
    else
        echo "Coverage threshold enforcement is disabled"
        echo "Set COVERAGE_ENFORCE_THRESHOLDS=1 to enforce per-source thresholds"
    fi
}

CLEAN_FLAG=""
FORMAT_ARG=""
for arg in "$@"; do
    case "$arg" in
        --clean)
            CLEAN_FLAG="yes"
            ;;
        help|--help|-h)
            print_usage
            exit 0
            ;;
        *)
            if [ -n "$FORMAT_ARG" ]; then
                echo "error: multiple formats specified ('$FORMAT_ARG' and '$arg')" >&2
                print_usage
                exit 1
            fi
            FORMAT_ARG="$arg"
            ;;
    esac
done
FORMAT_ARG="${FORMAT_ARG:-html}"

case "$FORMAT_ARG" in
    html|text|lcov|json|cobertura|all)
        ;;
    *)
        echo "error: unknown format '$FORMAT_ARG'" >&2
        print_usage
        exit 1
        ;;
esac

if [ "$FORMAT_ARG" = "json" ] || [ "$FORMAT_ARG" = "all" ]; then
    require_command jq
fi

require_command cargo
require_command cargo-llvm-cov

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$SCRIPT_DIR}"
cd "$PROJECT_ROOT"

if [ ! -f Cargo.toml ]; then
    echo "error: Cargo.toml not found in current directory" >&2
    exit 1
fi

PACKAGE_NAME=$(detect_package_name)
if [ -z "$PACKAGE_NAME" ]; then
    echo "error: unable to detect package name from Cargo.toml" >&2
    exit 1
fi

CURRENT_CRATE_DIR=$(pwd)
CURRENT_CRATE_NAME=$(basename "$CURRENT_CRATE_DIR")
WORKSPACE_ROOT=$(cd "$PROJECT_ROOT/.." && pwd)
EXCLUDE_PATTERN=$(build_exclude_pattern "$CURRENT_CRATE_NAME" "$WORKSPACE_ROOT")
SOURCE_PREFIX="$CURRENT_CRATE_DIR/$COVERAGE_SOURCE_DIR/"

echo "Starting code coverage testing"
echo "Package: $PACKAGE_NAME"
echo "Coverage source prefix: $SOURCE_PREFIX"
echo "Exclude pattern: $EXCLUDE_PATTERN"

if [ "$CLEAN_FLAG" = "yes" ]; then
    echo "Cleaning old coverage data"
    cargo llvm-cov clean
else
    echo "Using cached build data; pass --clean to clean first"
fi

mkdir -p target/llvm-cov

case "$FORMAT_ARG" in
    html)
        echo "Generating HTML coverage report"
        html_open_args=()
        if [ "$COVERAGE_OPEN_HTML" = "1" ]; then
            html_open_args=(--open)
        fi
        cargo llvm-cov --package "$PACKAGE_NAME" --html --output-dir target/llvm-cov \
            "${html_open_args[@]}" \
            --ignore-filename-regex "$EXCLUDE_PATTERN"
        echo "HTML report: target/llvm-cov/html/index.html"
        ;;

    text)
        echo "Generating text coverage report"
        cargo llvm-cov --package "$PACKAGE_NAME" \
            --ignore-filename-regex "$EXCLUDE_PATTERN" \
            | tee target/llvm-cov/coverage.txt
        echo "Text report: target/llvm-cov/coverage.txt"
        ;;

    lcov)
        echo "Generating LCOV coverage report"
        cargo llvm-cov --package "$PACKAGE_NAME" --lcov --output-path target/llvm-cov/lcov.info \
            --ignore-filename-regex "$EXCLUDE_PATTERN"
        echo "LCOV report: target/llvm-cov/lcov.info"
        ;;

    json)
        echo "Generating JSON coverage report"
        cargo llvm-cov --package "$PACKAGE_NAME" --json --output-path target/llvm-cov/coverage.json \
            --ignore-filename-regex "$EXCLUDE_PATTERN"
        maybe_check_json_coverage target/llvm-cov/coverage.json "$SOURCE_PREFIX"
        echo "JSON report: target/llvm-cov/coverage.json"
        ;;

    cobertura)
        echo "Generating Cobertura XML coverage report"
        cargo llvm-cov --package "$PACKAGE_NAME" --cobertura --output-path target/llvm-cov/cobertura.xml \
            --ignore-filename-regex "$EXCLUDE_PATTERN"
        echo "Cobertura report: target/llvm-cov/cobertura.xml"
        ;;

    all)
        echo "Generating all coverage reports from one test run"

        echo "  - collecting coverage data"
        cargo llvm-cov --package "$PACKAGE_NAME" --no-report \
            --ignore-filename-regex "$EXCLUDE_PATTERN"

        echo "  - HTML"
        cargo llvm-cov report --package "$PACKAGE_NAME" --html --output-dir target/llvm-cov \
            --ignore-filename-regex "$EXCLUDE_PATTERN"

        echo "  - LCOV"
        cargo llvm-cov report --package "$PACKAGE_NAME" --lcov --output-path target/llvm-cov/lcov.info \
            --ignore-filename-regex "$EXCLUDE_PATTERN"

        echo "  - JSON"
        cargo llvm-cov report --package "$PACKAGE_NAME" --json --output-path target/llvm-cov/coverage.json \
            --ignore-filename-regex "$EXCLUDE_PATTERN"
        maybe_check_json_coverage target/llvm-cov/coverage.json "$SOURCE_PREFIX"

        echo "  - Cobertura"
        cargo llvm-cov report --package "$PACKAGE_NAME" --cobertura --output-path target/llvm-cov/cobertura.xml \
            --ignore-filename-regex "$EXCLUDE_PATTERN"

        echo "  - text"
        cargo llvm-cov report --package "$PACKAGE_NAME" --text \
            --ignore-filename-regex "$EXCLUDE_PATTERN" \
            | tee target/llvm-cov/coverage.txt

        echo "Reports:"
        echo "  HTML:      target/llvm-cov/html/index.html"
        echo "  LCOV:      target/llvm-cov/lcov.info"
        echo "  JSON:      target/llvm-cov/coverage.json"
        echo "  Cobertura: target/llvm-cov/cobertura.xml"
        echo "  Text:      target/llvm-cov/coverage.txt"
        ;;
esac

echo "Code coverage testing completed"
