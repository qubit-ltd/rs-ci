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
# Optional Cargo feature matrix runner.
#
# Projects can add .rs-ci-cargo-matrix.json in the project root to request
# additional Cargo checks beyond the default CI feature selection.
#

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=toolchains.sh
source "$SCRIPT_DIR/toolchains.sh"
configure_rs_ci_toolchains

CONFIG_FILE_NAME="${RS_CI_CARGO_MATRIX_CONFIG:-.rs-ci-cargo-matrix.json}"

if [ -n "${RS_CI_PROJECT_ROOT:-}" ]; then
    PROJECT_ROOT="$RS_CI_PROJECT_ROOT"
elif [ "$(basename "$SCRIPT_DIR")" = ".rs-ci" ]; then
    PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
else
    PROJECT_ROOT="$SCRIPT_DIR"
fi

if [[ "$CONFIG_FILE_NAME" = /* ]]; then
    CONFIG_FILE="$CONFIG_FILE_NAME"
else
    CONFIG_FILE="$PROJECT_ROOT/$CONFIG_FILE_NAME"
fi

print_usage() {
    echo "Usage: ./cargo-feature-check.sh [run-all|run-index <index>|github-matrix|validate|help]"
    echo ""
    echo "Environment:"
    echo "  RS_CI_BUILD_TOOLCHAIN=${RS_CI_BUILD_TOOLCHAIN}"
    echo "  RS_CI_CLIPPY_TOOLCHAIN=${RS_CI_CLIPPY_TOOLCHAIN}"
    echo "  RS_CI_PROJECT_ROOT=${PROJECT_ROOT}"
    echo "  RS_CI_CARGO_MATRIX_CONFIG=${CONFIG_FILE_NAME}"
}

require_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        echo "error: required command '$1' was not found" >&2
        exit 1
    fi
}

has_config() {
    [ -f "$CONFIG_FILE" ]
}

validate_config() {
    require_command jq

    jq -e '
        def allowed_command:
            . as $command
            | ["check", "build", "test", "doc", "doc-test", "clippy"]
            | index($command) != null;

        type == "object"
        and (.version == 1)
        and (.checks | type == "array" and length > 0)
        and ([.checks[].name] | length == (unique | length))
        and all(.checks[];
            type == "object"
            and (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
            and ((.commands // []) | type == "array" and length > 0 and all(.[]; type == "string" and allowed_command))
            and ((.features // []) | type == "array" and all(.[]; type == "string" and test("^[A-Za-z0-9_+./-]+$") and (contains(",") | not)))
            and ((if has("defaultFeatures") then .defaultFeatures else true end) | type == "boolean")
            and ((if has("allFeatures") then .allFeatures else false end) | type == "boolean")
            and (
                ((if has("allFeatures") then .allFeatures else false end) == false)
                or (
                    ((.features // []) | length) == 0
                    and ((if has("defaultFeatures") then .defaultFeatures else true end) == true)
                )
            )
        )
    ' "$CONFIG_FILE" > /dev/null
}

emit_github_matrix() {
    if ! has_config; then
        printf '%s\n' '{"include":[{"index":-1,"name":"no-configured-feature-matrix","enabled":false}]}'
        return
    fi

    validate_config
    jq -c '{
        include: [
            .checks
            | to_entries[]
            | {
                index: .key,
                name: .value.name,
                enabled: true
              }
        ]
    }' "$CONFIG_FILE"
}

build_feature_args() {
    local index="$1"
    local all_features
    local default_features
    local features

    all_features=$(jq -r --argjson index "$index" '.checks[$index] | if has("allFeatures") then .allFeatures else false end' "$CONFIG_FILE")
    default_features=$(jq -r --argjson index "$index" '.checks[$index] | if has("defaultFeatures") then .defaultFeatures else true end' "$CONFIG_FILE")
    features=$(jq -r --argjson index "$index" '(.checks[$index].features // []) | join(",")' "$CONFIG_FILE")

    FEATURE_ARGS=()
    if [ "$all_features" = "true" ]; then
        FEATURE_ARGS+=(--all-features)
    else
        if [ "$default_features" = "false" ]; then
            FEATURE_ARGS+=(--no-default-features)
        fi
        if [ -n "$features" ]; then
            FEATURE_ARGS+=(--features "$features")
        fi
    fi
}

print_check_header() {
    local index="$1"
    local name
    local feature_summary

    name=$(jq -r --argjson index "$index" '.checks[$index].name' "$CONFIG_FILE")
    build_feature_args "$index"
    if [ "${#FEATURE_ARGS[@]}" -eq 0 ]; then
        feature_summary="default feature selection"
    else
        feature_summary="${FEATURE_ARGS[*]}"
    fi

    echo "==> Cargo feature matrix: $name ($feature_summary)"
}

run_cargo_command() {
    local command="$1"

    case "$command" in
        check)
            cargo +"$RS_CI_BUILD_TOOLCHAIN" check "${FEATURE_ARGS[@]}" --verbose
            ;;
        build)
            cargo +"$RS_CI_BUILD_TOOLCHAIN" build "${FEATURE_ARGS[@]}" --verbose
            ;;
        test)
            cargo +"$RS_CI_BUILD_TOOLCHAIN" test "${FEATURE_ARGS[@]}" --verbose
            ;;
        doc)
            RUSTDOCFLAGS="-D warnings" cargo +"$RS_CI_BUILD_TOOLCHAIN" doc --no-deps "${FEATURE_ARGS[@]}" --verbose
            ;;
        doc-test)
            cargo +"$RS_CI_BUILD_TOOLCHAIN" test --doc "${FEATURE_ARGS[@]}" --verbose
            ;;
        clippy)
            cargo +"$RS_CI_CLIPPY_TOOLCHAIN" clippy --all-targets "${FEATURE_ARGS[@]}" -- -D warnings
            ;;
        *)
            echo "error: unsupported command '$command'" >&2
            exit 1
            ;;
    esac
}

run_check_index() {
    local index="$1"
    local count
    local command
    local commands=()

    validate_config
    count=$(jq -r '.checks | length' "$CONFIG_FILE")
    if ! [[ "$index" =~ ^[0-9]+$ ]] || [ "$index" -ge "$count" ]; then
        echo "error: cargo feature matrix index out of range: $index" >&2
        exit 1
    fi

    cd "$PROJECT_ROOT"
    print_check_header "$index"
    while IFS= read -r command; do
        commands+=("$command")
    done < <(jq -r --argjson index "$index" '.checks[$index].commands[]' "$CONFIG_FILE")
    for command in "${commands[@]}"; do
        if [ "$command" = "clippy" ]; then
            echo "==> cargo +$RS_CI_CLIPPY_TOOLCHAIN $command ${FEATURE_ARGS[*]}"
        else
            echo "==> cargo +$RS_CI_BUILD_TOOLCHAIN $command ${FEATURE_ARGS[*]}"
        fi
        run_cargo_command "$command"
    done
}

run_all_checks() {
    local count
    local index

    if ! has_config; then
        echo "No Cargo feature matrix config found at $CONFIG_FILE; skipping optional feature matrix checks."
        return
    fi

    validate_config
    count=$(jq -r '.checks | length' "$CONFIG_FILE")
    for ((index = 0; index < count; index++)); do
        run_check_index "$index"
    done
}

COMMAND="${1:-run-all}"
case "$COMMAND" in
    run-all)
        run_all_checks
        ;;
    run-index)
        if [ "$#" -ne 2 ]; then
            echo "error: run-index requires an index argument" >&2
            print_usage
            exit 1
        fi
        run_check_index "$2"
        ;;
    github-matrix)
        emit_github_matrix
        ;;
    validate)
        if ! has_config; then
            echo "No Cargo feature matrix config found at $CONFIG_FILE."
            exit 0
        fi
        validate_config
        echo "Cargo feature matrix config is valid: $CONFIG_FILE"
        ;;
    help|--help|-h)
        print_usage
        ;;
    *)
        echo "error: unknown command '$COMMAND'" >&2
        print_usage
        exit 1
        ;;
esac
