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
# Optional Cargo compatibility matrix runner.
#
# Projects can add .rs-ci-cargo-matrix.json in the project root to request
# additional feature or dependency compatibility checks beyond the default CI
# selection.
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

# Feature-matrix runs intentionally use a target directory separate from the
# main CI build.  The matrix exercises mutually exclusive feature sets, and
# sharing artifacts with the preceding all-feature test can leave rustdoc
# resolving an incompatible dependency artifact (for example, rlib vs rmeta).
if [ -z "${RS_CI_FEATURE_MATRIX_TARGET_DIR:-}" ]; then
    if [ -n "${CARGO_TARGET_DIR:-}" ]; then
        RS_CI_FEATURE_MATRIX_TARGET_DIR="$CARGO_TARGET_DIR/feature-matrix"
    else
        RS_CI_FEATURE_MATRIX_TARGET_DIR="$PROJECT_ROOT/target/rs-ci-feature-matrix"
    fi
fi
MATRIX_TARGET_ROOT="$RS_CI_FEATURE_MATRIX_TARGET_DIR"
export CARGO_TARGET_DIR="$MATRIX_TARGET_ROOT"

LOCK_FILE="$PROJECT_ROOT/Cargo.lock"
LOCK_BACKUP=""
LOCK_BASELINE_READY=false
LOCK_FILE_EXISTED=false

restore_lockfile() {
    if [ "$LOCK_BASELINE_READY" != "true" ]; then
        return
    fi
    if [ "$LOCK_FILE_EXISTED" = "true" ]; then
        command cp "$LOCK_BACKUP" "$LOCK_FILE"
    elif [ -f "$LOCK_FILE" ]; then
        command rm -f "$LOCK_FILE"
    fi
}

cleanup() {
    restore_lockfile
    if [ -n "$LOCK_BACKUP" ] && [ -f "$LOCK_BACKUP" ]; then
        command rm -f "$LOCK_BACKUP"
    fi
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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
            and ((.packages // []) | type == "array" and all(.[]; type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]*$")))
            and ((.packages // []) | length == (unique | length))
            and ((has("packages") | not) or (.packages | length > 0))
            and ((if has("defaultFeatures") then .defaultFeatures else true end) | type == "boolean")
            and ((if has("allFeatures") then .allFeatures else false end) | type == "boolean")
            and (
                ((if has("allFeatures") then .allFeatures else false end) == false)
                or (
                    ((.features // []) | length) == 0
                    and ((if has("defaultFeatures") then .defaultFeatures else true end) == true)
                )
            )
            and (
                (has("dependency") | not)
                or (
                    (.dependency | type == "object")
                    and (.dependency.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]*$"))
                    and (
                        (
                            .dependency.resolution == "precise"
                            and (.dependency.version | type == "string" and test("^[0-9A-Za-z][0-9A-Za-z.+_-]*$"))
                        )
                        or (
                            .dependency.resolution == "latest"
                            and (.dependency | has("version") | not)
                        )
                    )
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
    local package

    all_features=$(jq -r --argjson index "$index" '.checks[$index] | if has("allFeatures") then .allFeatures else false end' "$CONFIG_FILE")
    default_features=$(jq -r --argjson index "$index" '.checks[$index] | if has("defaultFeatures") then .defaultFeatures else true end' "$CONFIG_FILE")
    features=$(jq -r --argjson index "$index" '(.checks[$index].features // []) | join(",")' "$CONFIG_FILE")

    FEATURE_ARGS=()
    PACKAGE_ARGS=()
    while IFS= read -r package; do
        [ -n "$package" ] && PACKAGE_ARGS+=(--package "$package")
    done < <(jq -r --argjson index "$index" '.checks[$index].packages[]?' "$CONFIG_FILE")
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

capture_lockfile_baseline() {
    if [ "$LOCK_BASELINE_READY" = "true" ]; then
        return
    fi
    LOCK_BACKUP=$(mktemp -t rs-ci-cargo-matrix-lock.XXXXXX)
    if [ -f "$LOCK_FILE" ]; then
        command cp "$LOCK_FILE" "$LOCK_BACKUP"
        LOCK_FILE_EXISTED=true
    fi
    LOCK_BASELINE_READY=true
}

prepare_dependency() {
    local index="$1"
    local dependency_name
    local expected_version
    local resolution
    local resolved_versions=()

    CARGO_LOCK_ARGS=()
    export CARGO_TARGET_DIR="$MATRIX_TARGET_ROOT"
    restore_lockfile
    if [ "$(jq -r --argjson index "$index" '.checks[$index] | has("dependency")' "$CONFIG_FILE")" != "true" ]; then
        return
    fi

    capture_lockfile_baseline
    dependency_name=$(jq -r --argjson index "$index" '.checks[$index].dependency.name' "$CONFIG_FILE")
    resolution=$(jq -r --argjson index "$index" '.checks[$index].dependency.resolution' "$CONFIG_FILE")
    export CARGO_TARGET_DIR="$MATRIX_TARGET_ROOT/dependency-$index"

    if [ "$resolution" = "precise" ]; then
        expected_version=$(jq -r --argjson index "$index" '.checks[$index].dependency.version' "$CONFIG_FILE")
        cargo +"$RS_CI_BUILD_TOOLCHAIN" update -p "$dependency_name" --precise "$expected_version"
    else
        cargo +"$RS_CI_BUILD_TOOLCHAIN" update -p "$dependency_name"
    fi

    while IFS= read -r resolved_version; do
        [ -n "$resolved_version" ] && resolved_versions+=("$resolved_version")
    done < <(
        cargo +"$RS_CI_BUILD_TOOLCHAIN" metadata --locked --format-version 1 |
            jq -r --arg dependency "$dependency_name" \
                '[.packages[] | select(.name == $dependency) | .version] | unique[]'
    )
    if [ "${#resolved_versions[@]}" -ne 1 ]; then
        echo "error: expected exactly one resolved version of $dependency_name, found ${#resolved_versions[@]}" >&2
        exit 1
    fi
    if [ "$resolution" = "precise" ] && [ "${resolved_versions[0]}" != "$expected_version" ]; then
        echo "error: expected $dependency_name $expected_version, resolved ${resolved_versions[0]}" >&2
        exit 1
    fi
    echo "Resolved dependency $dependency_name ${resolved_versions[0]}"
    CARGO_LOCK_ARGS=(--locked)
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

    echo "==> Cargo compatibility matrix: $name ($feature_summary)"
}

run_cargo_command() {
    local command="$1"

    case "$command" in
        check)
            cargo +"$RS_CI_BUILD_TOOLCHAIN" check "${PACKAGE_ARGS[@]+${PACKAGE_ARGS[@]}}" "${FEATURE_ARGS[@]+${FEATURE_ARGS[@]}}" "${CARGO_LOCK_ARGS[@]+${CARGO_LOCK_ARGS[@]}}" --verbose
            ;;
        build)
            cargo +"$RS_CI_BUILD_TOOLCHAIN" build "${PACKAGE_ARGS[@]+${PACKAGE_ARGS[@]}}" "${FEATURE_ARGS[@]+${FEATURE_ARGS[@]}}" "${CARGO_LOCK_ARGS[@]+${CARGO_LOCK_ARGS[@]}}" --verbose
            ;;
        test)
            cargo +"$RS_CI_BUILD_TOOLCHAIN" test "${PACKAGE_ARGS[@]+${PACKAGE_ARGS[@]}}" "${FEATURE_ARGS[@]+${FEATURE_ARGS[@]}}" "${CARGO_LOCK_ARGS[@]+${CARGO_LOCK_ARGS[@]}}" --verbose
            ;;
        doc)
            RUSTDOCFLAGS="-D warnings" cargo +"$RS_CI_BUILD_TOOLCHAIN" doc --no-deps "${PACKAGE_ARGS[@]+${PACKAGE_ARGS[@]}}" "${FEATURE_ARGS[@]+${FEATURE_ARGS[@]}}" "${CARGO_LOCK_ARGS[@]+${CARGO_LOCK_ARGS[@]}}" --verbose
            ;;
        doc-test)
            cargo +"$RS_CI_BUILD_TOOLCHAIN" test --doc "${PACKAGE_ARGS[@]+${PACKAGE_ARGS[@]}}" "${FEATURE_ARGS[@]+${FEATURE_ARGS[@]}}" "${CARGO_LOCK_ARGS[@]+${CARGO_LOCK_ARGS[@]}}" --verbose
            ;;
        clippy)
            cargo +"$RS_CI_CLIPPY_TOOLCHAIN" clippy --all-targets "${PACKAGE_ARGS[@]+${PACKAGE_ARGS[@]}}" "${FEATURE_ARGS[@]+${FEATURE_ARGS[@]}}" "${CARGO_LOCK_ARGS[@]+${CARGO_LOCK_ARGS[@]}}" -- -D warnings
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
    prepare_dependency "$index"
    while IFS= read -r command; do
        commands+=("$command")
    done < <(jq -r --argjson index "$index" '.checks[$index].commands[]' "$CONFIG_FILE")
    for command in "${commands[@]}"; do
        if [ "$command" = "clippy" ]; then
            echo "==> cargo +$RS_CI_CLIPPY_TOOLCHAIN $command ${FEATURE_ARGS[*]} ${CARGO_LOCK_ARGS[*]}"
        else
            echo "==> cargo +$RS_CI_BUILD_TOOLCHAIN $command ${FEATURE_ARGS[*]} ${CARGO_LOCK_ARGS[*]}"
        fi
        run_cargo_command "$command"
    done
}

run_all_checks() {
    local count
    local index

    if ! has_config; then
        echo "No Cargo compatibility matrix config found at $CONFIG_FILE; skipping optional matrix checks."
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
            echo "No Cargo compatibility matrix config found at $CONFIG_FILE."
            exit 0
        fi
        validate_config
        echo "Cargo compatibility matrix config is valid: $CONFIG_FILE"
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
