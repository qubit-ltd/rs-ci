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
# Resolves package-scoped rs-ci configuration from Cargo metadata.
#

set -euo pipefail

print_usage() {
    echo "Usage: ./rs-ci-metadata.sh miri-packages" >&2
    echo "       ./rs-ci-metadata.sh sanitizer-packages address" >&2
}

require_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        echo "error: required command '$1' was not found" >&2
        exit 1
    fi
}

if [ "$#" -eq 1 ] && [ "$1" = "miri-packages" ]; then
    COMMAND="miri-packages"
    SANITIZER=""
elif [ "$#" -eq 2 ] && [ "$1" = "sanitizer-packages" ]; then
    COMMAND="sanitizer-packages"
    SANITIZER="$2"
    if [ "$SANITIZER" != "address" ]; then
        echo "error: unsupported sanitizer '$SANITIZER'" >&2
        exit 2
    fi
else
    print_usage
    exit 2
fi

require_command cargo
require_command jq

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$SCRIPT_DIR}"
MANIFEST_PATH="$PROJECT_ROOT/Cargo.toml"

if [ ! -f "$MANIFEST_PATH" ]; then
    echo "error: Cargo.toml not found at '$MANIFEST_PATH'" >&2
    exit 2
fi

set +e
RAW_METADATA=$(cargo metadata \
    --no-deps \
    --format-version 1 \
    --manifest-path "$MANIFEST_PATH")
METADATA_STATUS=$?
set -e
if [ "$METADATA_STATUS" -ne 0 ]; then
    echo "error: cargo metadata failed for '$MANIFEST_PATH'" >&2
    exit "$METADATA_STATUS"
fi

NORMALIZED_METADATA=$(jq -c '
    . as $root
    | if (($root.packages | type) != "array") then
        error("cargo metadata packages must be an array")
      elif (($root.workspace_members | type) != "array") then
        error("cargo metadata workspace_members must be an array")
      else
        [
          $root.packages[]
          | select(
              .id as $id
              | (($root.workspace_members | index($id)) != null)
            )
          | . as $package
          | (
              if $package.metadata == null then
                {}
              elif ($package.metadata | type) == "object" then
                ($package.metadata["rs-ci"] // {})
              else
                error(
                  "package \($package.name): metadata must be an object"
                )
              end
            ) as $config
          | if (($config | type) != "object") then
              error(
                "package \($package.name): package.metadata.rs-ci must be an object"
              )
            else
              .
            end
          | (
              if ($config | has("miri")) then
                $config.miri
              else
                false
              end
            ) as $miri
          | if (($miri | type) != "boolean") then
              error(
                "package \($package.name): rs-ci.miri must be a boolean"
              )
            else
              .
            end
          | (
              if ($config | has("sanitizers")) then
                $config.sanitizers
              else
                []
              end
            ) as $sanitizers
          | if (($sanitizers | type) != "array") then
              error(
                "package \($package.name): rs-ci.sanitizers must be an array"
              )
            elif (all($sanitizers[]; type == "string") | not) then
              error(
                "package \($package.name): rs-ci.sanitizers entries must be strings"
              )
            elif (($sanitizers | unique | length) != ($sanitizers | length)) then
              error(
                "package \($package.name): rs-ci.sanitizers contains a duplicate entry"
              )
            elif (($sanitizers - ["address"]) | length) != 0 then
              error(
                "package \($package.name): rs-ci.sanitizers contains an unsupported sanitizer"
              )
            else
              {
                name: $package.name,
                manifest_path: $package.manifest_path,
                miri: $miri,
                sanitizers: $sanitizers
              }
            end
        ]
      end
    ' <<< "$RAW_METADATA")

case "$COMMAND" in
    miri-packages)
        jq -r '.[] | select(.miri) | .name' <<< "$NORMALIZED_METADATA"
        ;;
    sanitizer-packages)
        jq -r \
            --arg sanitizer "$SANITIZER" \
            '.[] | select(.sanitizers | index($sanitizer)) | .name' \
            <<< "$NORMALIZED_METADATA"
        ;;
esac
