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

RS_CI_BUILD_TOOLCHAIN="${RS_CI_BUILD_TOOLCHAIN:-1.94.0}"
MIN_FUNCTION_COVERAGE="${MIN_FUNCTION_COVERAGE:-100}"
MIN_LINE_COVERAGE="${MIN_LINE_COVERAGE:-95}"
MIN_REGION_COVERAGE="${MIN_REGION_COVERAGE:-95}"
COVERAGE_SOURCE_DIR="${COVERAGE_SOURCE_DIR:-src}"
COVERAGE_EXTRA_EXCLUDE_REGEX="${COVERAGE_EXTRA_EXCLUDE_REGEX:-}"
COVERAGE_OPEN_HTML="${COVERAGE_OPEN_HTML:-1}"
COVERAGE_ENFORCE_THRESHOLDS="${COVERAGE_ENFORCE_THRESHOLDS:-1}"
COVERAGE_ALL_FEATURES="${COVERAGE_ALL_FEATURES:-1}"
COVERAGE_NO_DEFAULT_FEATURES="${COVERAGE_NO_DEFAULT_FEATURES:-0}"
COVERAGE_FEATURES="${COVERAGE_FEATURES:-}"
RS_CI_COVERAGE_CONFIG="${RS_CI_COVERAGE_CONFIG:-}"

COVERAGE_FEATURE_ARGS=()
if [ "$COVERAGE_ALL_FEATURES" = "1" ]; then
    COVERAGE_FEATURE_ARGS=(--all-features)
else
    if [ "$COVERAGE_NO_DEFAULT_FEATURES" = "1" ]; then
        COVERAGE_FEATURE_ARGS+=(--no-default-features)
    fi
    if [ -n "$COVERAGE_FEATURES" ]; then
        COVERAGE_FEATURE_ARGS+=(--features "$COVERAGE_FEATURES")
    fi
fi

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
    echo "  RS_CI_BUILD_TOOLCHAIN=${RS_CI_BUILD_TOOLCHAIN}"
    echo "  MIN_FUNCTION_COVERAGE=${MIN_FUNCTION_COVERAGE}"
    echo "  MIN_LINE_COVERAGE=${MIN_LINE_COVERAGE}     # required: > value"
    echo "  MIN_REGION_COVERAGE=${MIN_REGION_COVERAGE} # required: > value"
    echo "  COVERAGE_SCOPE=${COVERAGE_SCOPE:-default-members}"
    echo "  COVERAGE_SOURCE_DIR=${COVERAGE_SOURCE_DIR}"
    echo "  RS_CI_COVERAGE_CONFIG=${RS_CI_COVERAGE_CONFIG:-.rs-ci-coverage.json}"
    echo "  COVERAGE_OPEN_HTML=${COVERAGE_OPEN_HTML}"
    echo "  COVERAGE_ENFORCE_THRESHOLDS=${COVERAGE_ENFORCE_THRESHOLDS}"
    echo "  COVERAGE_ALL_FEATURES=${COVERAGE_ALL_FEATURES}"
    echo "  COVERAGE_NO_DEFAULT_FEATURES=${COVERAGE_NO_DEFAULT_FEATURES}"
    echo "  COVERAGE_FEATURES=${COVERAGE_FEATURES}"
}

require_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        echo "error: required command '$1' was not found" >&2
        exit 1
    fi
}

is_executable_tool() {
    local tool="$1"

    case "$tool" in
        */*)
            [ -x "$tool" ]
            ;;
        *)
            command -v "$tool" > /dev/null 2>&1
            ;;
    esac
}

ignore_invalid_llvm_tool_override() {
    local variable_name="$1"
    local tool="${!variable_name:-}"

    if [ -n "$tool" ] && ! is_executable_tool "$tool"; then
        echo "warning: ignoring invalid $variable_name override: $tool" >&2
        unset "$variable_name"
    fi
}

ignore_invalid_llvm_tool_overrides() {
    ignore_invalid_llvm_tool_override LLVM_COV
    ignore_invalid_llvm_tool_override LLVM_PROFDATA
}

build_exclude_pattern() {
    local pattern="(\.cargo/registry|\.rustup/"

    if [ -n "$COVERAGE_EXTRA_EXCLUDE_REGEX" ]; then
        pattern="$pattern|$COVERAGE_EXTRA_EXCLUDE_REGEX"
    fi
    pattern="$pattern)"

    printf '%s\n' "$pattern"
}

shorten_table_path() {
    local value="$1"
    local max_length=56
    local keep_length

    if [ "${#value}" -le "$max_length" ]; then
        printf '%s\n' "$value"
        return
    fi

    keep_length=$((max_length - 3))
    printf '...%s\n' "${value: -$keep_length}"
}

validate_coverage_json() {
    local coverage_json="$1"

    require_command jq

    if [ ! -f "$coverage_json" ]; then
        echo "error: coverage JSON not found: $coverage_json" >&2
        exit 1
    fi

    if ! jq -e \
        '(.data | type) == "array"
         and all(.data[]; (.files | type) == "array")' \
        "$coverage_json" > /dev/null; then
        echo "error: invalid cargo-llvm-cov JSON: $coverage_json" >&2
        exit 1
    fi
}

print_json_coverage_summary() {
    local coverage_json="$1"
    local source_roots_json="$2"
    local rows
    local file
    local functions
    local lines
    local regions
    local display_file

    validate_coverage_json "$coverage_json"

    rows=$(jq -r \
        --argjson source_roots "$source_roots_json" \
        '
        def metric($summary):
            if (($summary.count // 0) == 0) then
                "n/a"
            else
                "\((($summary.percent * 100) | round) / 100)% (\($summary.covered)/\($summary.count))"
            end;

        .data[].files[] as $file
        | (
            [
                $source_roots[] as $source_root
                | select(
                    $file.filename | startswith($source_root.prefix)
                )
                | $source_root
            ]
            | sort_by(.prefix | length)
            | last
          ) as $source_root
        | select($source_root != null)
        | [
            (
                $source_root.display_prefix
                + ($file.filename | ltrimstr($source_root.prefix))
            ),
            metric($file.summary.functions),
            metric($file.summary.lines),
            metric($file.summary.regions)
          ]
        | @tsv
        ' "$coverage_json" | sort)

    echo "Coverage summary:"
    if [ -z "$rows" ]; then
        echo "  No source files matched the configured source roots"
        return
    fi

    printf '  %-56s %18s %18s %18s\n' "Source" "Functions" "Lines" "Regions"
    printf '  %-56s %18s %18s %18s\n' "------" "---------" "-----" "-------"
    while IFS=$'\t' read -r file functions lines regions; do
        display_file=$(shorten_table_path "$file")
        printf '  %-56s %18s %18s %18s\n' \
            "$display_file" "$functions" "$lines" "$regions"
    done <<< "$rows"
    echo ""
}

validate_source_root_matches() {
    local coverage_json="$1"
    local source_roots_json="$2"
    local unmatched_roots

    validate_coverage_json "$coverage_json"

    unmatched_roots=$(jq -r \
        --argjson source_roots "$source_roots_json" \
        '
        [.data[].files[].filename] as $filenames
        | $source_roots[] as $source_root
        | select(
            (
                [
                    $filenames[]
                    | select(startswith($source_root.prefix))
                ]
                | length
            ) == 0
          )
        | $source_root.display_prefix
        ' "$coverage_json")

    if [ -n "$unmatched_roots" ]; then
        while IFS= read -r source_root; do
            echo "error: source root '$source_root' matched no coverage files" >&2
        done <<< "$unmatched_roots"
        exit 1
    fi
}

check_json_coverage() {
    local coverage_json="$1"
    local source_roots_json="$2"
    local failures

    validate_coverage_json "$coverage_json"

    failures=$(jq -r \
        --argjson source_roots "$source_roots_json" \
        --argjson min_functions "$MIN_FUNCTION_COVERAGE" \
        --argjson min_lines "$MIN_LINE_COVERAGE" \
        --argjson min_regions "$MIN_REGION_COVERAGE" \
        '
        .data[].files[] as $file
        | (
            [
                $source_roots[] as $source_root
                | select(
                    $file.filename | startswith($source_root.prefix)
                )
                | $source_root
            ]
            | sort_by(.prefix | length)
            | last
          ) as $source_root
        | select($source_root != null)
        | $file.summary as $summary
        | select(
            (($summary.functions.count > 0) and ($summary.functions.percent < $min_functions))
            or (($summary.lines.count > 0) and ($summary.lines.percent <= $min_lines))
            or (($summary.regions.count > 0) and ($summary.regions.percent <= $min_regions))
        )
        | (
            $source_root.display_prefix
            + ($file.filename | ltrimstr($source_root.prefix))
          ) as $display_file
        | "\($display_file): functions=\($summary.functions.percent)% (\($summary.functions.covered)/\($summary.functions.count)), lines=\($summary.lines.percent)% (\($summary.lines.covered)/\($summary.lines.count)), regions=\($summary.regions.percent)% (\($summary.regions.covered)/\($summary.regions.count))"
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

print_and_validate_json_coverage() {
    local coverage_json="$1"

    print_json_coverage_summary "$coverage_json" "$SOURCE_ROOTS_JSON"
    validate_source_root_matches "$coverage_json" "$SOURCE_ROOTS_JSON"
}

maybe_check_json_coverage() {
    local coverage_json="$1"

    print_and_validate_json_coverage "$coverage_json"

    if [ "$COVERAGE_ENFORCE_THRESHOLDS" = "1" ]; then
        check_json_coverage "$coverage_json" "$SOURCE_ROOTS_JSON"
    else
        echo "Coverage threshold enforcement is disabled"
        echo "Set COVERAGE_ENFORCE_THRESHOLDS=1 to enforce per-source thresholds"
    fi
}

generate_json_coverage_summary() {
    echo "Generating JSON coverage summary"
    cargo +"$RS_CI_BUILD_TOOLCHAIN" llvm-cov report \
        "${CARGO_REPORT_ARGS[@]}" \
        --json --output-path target/llvm-cov/coverage.json \
        --ignore-filename-regex "$EXCLUDE_PATTERN"
    print_and_validate_json_coverage target/llvm-cov/coverage.json
}

build_coverage_plan() {
    local metadata_path="$1"
    local config_path="$2"
    local plan_path="$3"
    local project_manifest="$PROJECT_ROOT/Cargo.toml"

    if ! jq -n \
        --slurpfile metadata "$metadata_path" \
        --slurpfile config "$config_path" \
        --arg scope_override "${COVERAGE_SCOPE:-}" \
        --arg project_manifest "$project_manifest" \
        --arg default_source_dir "$COVERAGE_SOURCE_DIR" \
        '
        def fail($message):
            error("coverage configuration: " + $message);

        def valid_source_path:
            (type == "string")
            and (length > 0)
            and (startswith("/") | not)
            and (test("^[A-Za-z]:[\\\\/]") | not)
            and (split("/") | all(. != ".."))
            and (test("[\u0000-\u001f]") | not);

        ($metadata[0] // null) as $metadata_value
        | if ($metadata_value | type) != "object" then
              fail("cargo metadata did not return an object")
          else
              .
          end
        | if ($metadata_value.packages | type) != "array"
             or ($metadata_value.workspace_members | type) != "array"
             or ($metadata_value.workspace_default_members | type) != "array"
             or ($metadata_value.workspace_root | type) != "string"
          then
              fail("cargo metadata is missing workspace fields")
          else
              .
          end
        | ($config[0] // {}) as $config_value
        | if ($config_value | type) != "object" then
              fail("the configuration root must be an object")
          else
              .
          end
        | (
            ($config_value | keys_unsorted)
            - ["scope", "exclude_packages", "source_dirs"]
          ) as $unknown_keys
        | if ($unknown_keys | length) > 0 then
              fail("unknown key(s): " + ($unknown_keys | join(", ")))
          else
              .
          end
        | if ($config_value | has("scope"))
             and (($config_value.scope | type) != "string")
          then
              fail("scope must be a string")
          else
              .
          end
        | if ($config_value | has("exclude_packages"))
             and (($config_value.exclude_packages | type) != "array")
          then
              fail("exclude_packages must be an array")
          else
              .
          end
        | if ($config_value | has("source_dirs"))
             and (($config_value.source_dirs | type) != "object")
          then
              fail("source_dirs must be an object")
          else
              .
          end
        | ($config_value.exclude_packages // []) as $exclude_names
        | if ($exclude_names | all(type == "string" and length > 0) | not) then
              fail("exclude_packages must contain non-empty strings")
          else
              .
          end
        | if ($exclude_names | unique | length) != ($exclude_names | length) then
              fail("exclude_packages must not contain duplicates")
          else
              .
          end
        | ($config_value.source_dirs // {}) as $source_dirs
        | if (
              $source_dirs
              | to_entries
              | all((.value | type) == "array")
              | not
          ) then
              fail("each source_dirs value must be an array")
          else
              .
          end
        | if (
              $source_dirs
              | to_entries
              | all((.value | length) > 0)
              | not
          ) then
              fail("each source_dirs array must be non-empty")
          else
              .
          end
        | if (
              $source_dirs
              | to_entries
              | all(.value | all(type == "string" and length > 0))
              | not
          ) then
              fail("source_dirs must contain non-empty strings")
          else
              .
          end
        | if (
              $source_dirs
              | to_entries
              | all((.value | unique | length) == (.value | length))
              | not
          ) then
              fail("source_dirs arrays must not contain duplicates")
          else
              .
          end
        | (
            [
                $metadata_value.workspace_members[] as $workspace_id
                | $metadata_value.packages[]
                | select(.id == $workspace_id)
            ]
          ) as $workspace_packages
        | if ($workspace_packages | length)
             != ($metadata_value.workspace_members | length)
          then
              fail("cargo metadata is missing a workspace package")
          else
              .
          end
        | ($workspace_packages | map(.name)) as $workspace_names
        | (
            [
                $exclude_names[] as $exclude_name
                | select(
                    ($workspace_names | index($exclude_name)) == null
                )
                | $exclude_name
            ]
          ) as $unknown_excludes
        | if ($unknown_excludes | length) > 0 then
              fail(
                  "exclude_packages names unknown package(s): "
                  + ($unknown_excludes | join(", "))
              )
          else
              .
          end
        | (
            [
                ($source_dirs | keys[]?) as $source_package
                | select(
                    ($workspace_names | index($source_package)) == null
                )
                | $source_package
            ]
          ) as $unknown_source_packages
        | if ($unknown_source_packages | length) > 0 then
              fail(
                  "source_dirs names unknown package(s): "
                  + ($unknown_source_packages | join(", "))
              )
          else
              .
          end
        | (
            if $scope_override != "" then
                $scope_override
            else
                ($config_value.scope // "default-members")
            end
          ) as $scope
        | if (["default-members", "workspace", "package"] | index($scope))
             == null
          then
              fail(
                  "scope must be one of default-members, workspace, or package"
              )
          else
              .
          end
        | (
            [
                $workspace_packages[]
                | select(.manifest_path == $project_manifest)
            ]
            | first
          ) as $root_package
        | if $scope == "package" and $root_package == null then
              fail("package scope cannot be used from a virtual workspace root")
          else
              .
          end
        | (
            if $scope == "workspace" then
                $workspace_packages
            elif $scope == "default-members" then
                [
                    $metadata_value.workspace_default_members[] as $member_id
                    | $workspace_packages[]
                    | select(.id == $member_id)
                ]
            else
                [$root_package]
            end
          ) as $base_packages
        | (
            [
                $base_packages[] as $base_package
                | select(
                    ($exclude_names | index($base_package.name)) == null
                )
                | $base_package
            ]
          ) as $selected_packages
        | if ($selected_packages | length) == 0 then
              fail("the selected coverage scope contains no packages")
          else
              .
          end
        | ($selected_packages | map(.name)) as $selected_names
        | (
            [
                ($source_dirs | keys[]?) as $source_package
                | select(
                    ($selected_names | index($source_package)) == null
                )
                | $source_package
            ]
          ) as $unselected_source_packages
        | if ($unselected_source_packages | length) > 0 then
              fail(
                  "source_dirs refers to unselected package(s): "
                  + ($unselected_source_packages | join(", "))
              )
          else
              .
          end
        | (
            $selected_packages
            | map(
                . + {
                    source_dirs: (
                        $source_dirs[.name] // [$default_source_dir]
                    )
                }
            )
          ) as $packages_with_sources
        | if (
              [
                  $packages_with_sources[].source_dirs[]
                  | select(valid_source_path | not)
              ]
              | length
          ) > 0 then
              fail("source directories must be relative paths without '..'")
          else
              .
          end
        | (
            [
                $workspace_packages[] as $workspace_package
                | select(
                    ($selected_names | index($workspace_package.name)) == null
                )
                | $workspace_package
            ]
          ) as $excluded_packages
        | {
            scope: $scope,
            workspace_root: $metadata_value.workspace_root,
            packages: $packages_with_sources,
            excluded_packages: ($excluded_packages | map(.name)),
            collection_args: (
                if $scope == "package" then
                    ["--package", $selected_packages[0].name]
                else
                    ["--workspace"]
                    + (
                        [
                            $excluded_packages[].name
                            | ["--exclude", .]
                        ]
                        | add // []
                    )
                end
            ),
            report_args: (
                [
                    $selected_packages[].name
                    | ["--package", .]
                ]
                | add
            )
          }
        ' > "$plan_path"; then
        echo "error: unable to build the coverage plan" >&2
        exit 1
    fi
}

build_source_roots() {
    local plan_path="$1"
    local package_name
    local manifest_path
    local source_dir
    local package_dir
    local source_path
    local display_prefix
    local next_source_roots

    SOURCE_ROOTS_JSON="[]"
    while IFS=$'\t' read -r package_name manifest_path source_dir; do
        package_dir=$(cd "$(dirname "$manifest_path")" && pwd -P)
        source_path="$package_dir/$source_dir"
        if [ ! -d "$source_path" ]; then
            echo "error: coverage source directory does not exist: $source_path" >&2
            exit 1
        fi
        source_path=$(cd "$source_path" && pwd -P)

        case "$source_path" in
            "$WORKSPACE_ROOT")
                display_prefix="./"
                ;;
            "$WORKSPACE_ROOT"/*)
                display_prefix="${source_path#"$WORKSPACE_ROOT"/}/"
                ;;
            *)
                display_prefix="$package_name:$source_dir/"
                ;;
        esac

        if ! next_source_roots=$(jq -c \
            --arg package "$package_name" \
            --arg prefix "$source_path/" \
            --arg display_prefix "$display_prefix" \
            '
            if any(.[]; .prefix == $prefix) then
                error(
                    "duplicate coverage source directory: "
                    + $display_prefix
                )
            else
                . + [{
                    package: $package,
                    prefix: $prefix,
                    display_prefix: $display_prefix
                }]
            end
            ' <<< "$SOURCE_ROOTS_JSON"); then
            echo "error: unable to build coverage source roots" >&2
            exit 1
        fi
        SOURCE_ROOTS_JSON="$next_source_roots"
    done < <(
        jq -r \
            '.packages[] as $package
             | $package.source_dirs[]
             | [$package.name, $package.manifest_path, .]
             | @tsv' \
            "$plan_path"
    )
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

require_command cargo
require_command cargo-llvm-cov
require_command jq
ignore_invalid_llvm_tool_overrides

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$SCRIPT_DIR}"
PROJECT_ROOT=$(cd "$PROJECT_ROOT" && pwd -P)
cd "$PROJECT_ROOT"

if [ ! -f Cargo.toml ]; then
    echo "error: Cargo.toml not found in project root: $PROJECT_ROOT" >&2
    exit 1
fi

COVERAGE_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rs-ci-coverage.XXXXXX")
trap 'rm -rf -- "$COVERAGE_TEMP_DIR"' EXIT
METADATA_PATH="$COVERAGE_TEMP_DIR/metadata.json"
CONFIG_PATH="$COVERAGE_TEMP_DIR/config.json"
PLAN_PATH="$COVERAGE_TEMP_DIR/plan.json"

if ! cargo metadata --no-deps --format-version 1 \
    --manifest-path "$PROJECT_ROOT/Cargo.toml" > "$METADATA_PATH"; then
    echo "error: cargo metadata failed for $PROJECT_ROOT/Cargo.toml" >&2
    exit 1
fi

if [ -n "$RS_CI_COVERAGE_CONFIG" ]; then
    case "$RS_CI_COVERAGE_CONFIG" in
        /*)
            COVERAGE_CONFIG_PATH="$RS_CI_COVERAGE_CONFIG"
            ;;
        *)
            COVERAGE_CONFIG_PATH="$PROJECT_ROOT/$RS_CI_COVERAGE_CONFIG"
            ;;
    esac
    if [ ! -f "$COVERAGE_CONFIG_PATH" ]; then
        echo "error: coverage configuration not found: $COVERAGE_CONFIG_PATH" >&2
        exit 1
    fi
else
    COVERAGE_CONFIG_PATH="$PROJECT_ROOT/.rs-ci-coverage.json"
fi

if [ -f "$COVERAGE_CONFIG_PATH" ]; then
    cp "$COVERAGE_CONFIG_PATH" "$CONFIG_PATH"
else
    printf '{}\n' > "$CONFIG_PATH"
fi

build_coverage_plan "$METADATA_PATH" "$CONFIG_PATH" "$PLAN_PATH"

COVERAGE_SCOPE_RESOLVED=$(jq -r '.scope' "$PLAN_PATH")
WORKSPACE_ROOT=$(jq -r '.workspace_root' "$PLAN_PATH")
WORKSPACE_ROOT=$(cd "$WORKSPACE_ROOT" && pwd -P)
mapfile -t CARGO_COLLECTION_ARGS < <(
    jq -r '.collection_args[]' "$PLAN_PATH"
)
mapfile -t CARGO_REPORT_ARGS < <(jq -r '.report_args[]' "$PLAN_PATH")
mapfile -t SELECTED_PACKAGES < <(jq -r '.packages[].name' "$PLAN_PATH")
mapfile -t EXCLUDED_PACKAGES < <(jq -r '.excluded_packages[]' "$PLAN_PATH")
build_source_roots "$PLAN_PATH"

EXCLUDE_PATTERN=$(build_exclude_pattern)

echo "Starting code coverage testing"
echo "Coverage scope: $COVERAGE_SCOPE_RESOLVED"
echo "Selected packages: ${SELECTED_PACKAGES[*]}"
if [ "${#EXCLUDED_PACKAGES[@]}" -gt 0 ]; then
    echo "Excluded packages: ${EXCLUDED_PACKAGES[*]}"
fi
echo "Cargo toolchain: $RS_CI_BUILD_TOOLCHAIN"
echo "Coverage source roots:"
jq -r '.[] | "  - \(.display_prefix) [\(.package)]"' <<< "$SOURCE_ROOTS_JSON"
echo "Exclude pattern: $EXCLUDE_PATTERN"
if [ "$COVERAGE_ALL_FEATURES" = "1" ]; then
    echo "Cargo features: --all-features"
elif [ "${#COVERAGE_FEATURE_ARGS[@]}" -gt 0 ]; then
    echo "Cargo features: ${COVERAGE_FEATURE_ARGS[*]}"
else
    echo "Cargo features: default feature selection"
fi

if [ "$CLEAN_FLAG" = "yes" ]; then
    echo "Cleaning old coverage data"
    cargo +"$RS_CI_BUILD_TOOLCHAIN" llvm-cov clean
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
        cargo +"$RS_CI_BUILD_TOOLCHAIN" llvm-cov \
            "${CARGO_COLLECTION_ARGS[@]}" \
            "${COVERAGE_FEATURE_ARGS[@]}" \
            --html --output-dir target/llvm-cov \
            "${html_open_args[@]}" \
            --ignore-filename-regex "$EXCLUDE_PATTERN"
        echo "HTML report: target/llvm-cov/html/index.html"
        generate_json_coverage_summary
        ;;

    text)
        echo "Generating text coverage report"
        cargo +"$RS_CI_BUILD_TOOLCHAIN" llvm-cov \
            "${CARGO_COLLECTION_ARGS[@]}" \
            "${COVERAGE_FEATURE_ARGS[@]}" \
            --ignore-filename-regex "$EXCLUDE_PATTERN" \
            | tee target/llvm-cov/coverage.txt
        echo "Text report: target/llvm-cov/coverage.txt"
        generate_json_coverage_summary
        ;;

    lcov)
        echo "Generating LCOV coverage report"
        cargo +"$RS_CI_BUILD_TOOLCHAIN" llvm-cov \
            "${CARGO_COLLECTION_ARGS[@]}" \
            "${COVERAGE_FEATURE_ARGS[@]}" \
            --lcov --output-path target/llvm-cov/lcov.info \
            --ignore-filename-regex "$EXCLUDE_PATTERN"
        echo "LCOV report: target/llvm-cov/lcov.info"
        generate_json_coverage_summary
        ;;

    json)
        echo "Generating JSON coverage report"
        cargo +"$RS_CI_BUILD_TOOLCHAIN" llvm-cov \
            "${CARGO_COLLECTION_ARGS[@]}" \
            "${COVERAGE_FEATURE_ARGS[@]}" \
            --json --output-path target/llvm-cov/coverage.json \
            --ignore-filename-regex "$EXCLUDE_PATTERN"
        maybe_check_json_coverage target/llvm-cov/coverage.json
        echo "JSON report: target/llvm-cov/coverage.json"
        ;;

    cobertura)
        echo "Generating Cobertura XML coverage report"
        cargo +"$RS_CI_BUILD_TOOLCHAIN" llvm-cov \
            "${CARGO_COLLECTION_ARGS[@]}" \
            "${COVERAGE_FEATURE_ARGS[@]}" \
            --cobertura --output-path target/llvm-cov/cobertura.xml \
            --ignore-filename-regex "$EXCLUDE_PATTERN"
        echo "Cobertura report: target/llvm-cov/cobertura.xml"
        generate_json_coverage_summary
        ;;

    all)
        echo "Generating all coverage reports from one test run"

        echo "  - collecting coverage data"
        cargo +"$RS_CI_BUILD_TOOLCHAIN" llvm-cov \
            "${CARGO_COLLECTION_ARGS[@]}" \
            "${COVERAGE_FEATURE_ARGS[@]}" \
            --no-report \
            --ignore-filename-regex "$EXCLUDE_PATTERN"

        echo "  - HTML"
        cargo +"$RS_CI_BUILD_TOOLCHAIN" llvm-cov report \
            "${CARGO_REPORT_ARGS[@]}" \
            --html --output-dir target/llvm-cov \
            --ignore-filename-regex "$EXCLUDE_PATTERN"

        echo "  - LCOV"
        cargo +"$RS_CI_BUILD_TOOLCHAIN" llvm-cov report \
            "${CARGO_REPORT_ARGS[@]}" \
            --lcov --output-path target/llvm-cov/lcov.info \
            --ignore-filename-regex "$EXCLUDE_PATTERN"

        echo "  - JSON"
        cargo +"$RS_CI_BUILD_TOOLCHAIN" llvm-cov report \
            "${CARGO_REPORT_ARGS[@]}" \
            --json --output-path target/llvm-cov/coverage.json \
            --ignore-filename-regex "$EXCLUDE_PATTERN"
        maybe_check_json_coverage target/llvm-cov/coverage.json

        echo "  - Cobertura"
        cargo +"$RS_CI_BUILD_TOOLCHAIN" llvm-cov report \
            "${CARGO_REPORT_ARGS[@]}" \
            --cobertura --output-path target/llvm-cov/cobertura.xml \
            --ignore-filename-regex "$EXCLUDE_PATTERN"

        echo "  - text"
        cargo +"$RS_CI_BUILD_TOOLCHAIN" llvm-cov report \
            "${CARGO_REPORT_ARGS[@]}" \
            --text \
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
