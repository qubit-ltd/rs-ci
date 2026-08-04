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
# Runs supported sanitizers only for workspace packages that explicitly opt in.
#

set -euo pipefail

print_usage() {
    echo "Usage: ./cargo-sanitizer-check.sh" >&2
    echo "       ./cargo-sanitizer-check.sh --is-configured [address]" >&2
}

if [ "$#" -eq 0 ]; then
    DETECT_ONLY=0
    SANITIZER="address"
elif [ "$#" -eq 1 ] && [ "$1" = "--is-configured" ]; then
    DETECT_ONLY=1
    SANITIZER="address"
elif [ "$#" -eq 2 ] \
    && [ "$1" = "--is-configured" ] \
    && [ "$2" = "address" ]; then
    DETECT_ONLY=1
    SANITIZER="$2"
else
    print_usage
    exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$SCRIPT_DIR}"
METADATA_SCRIPT="$SCRIPT_DIR/rs-ci-metadata.sh"

if [ ! -x "$METADATA_SCRIPT" ]; then
    echo "error: required executable '$METADATA_SCRIPT' was not found" >&2
    exit 2
fi

# shellcheck source=toolchains.sh
source "$SCRIPT_DIR/toolchains.sh"
configure_rs_ci_toolchains

set +e
PACKAGE_OUTPUT=$(RS_CI_PROJECT_ROOT="$PROJECT_ROOT" \
    "$METADATA_SCRIPT" sanitizer-packages "$SANITIZER")
METADATA_STATUS=$?
set -e
if [ "$METADATA_STATUS" -ne 0 ]; then
    exit "$METADATA_STATUS"
fi

PACKAGES=()
while IFS= read -r package; do
    if [ -n "$package" ]; then
        PACKAGES+=("$package")
    fi
done <<< "$PACKAGE_OUTPUT"

if [ "${#PACKAGES[@]}" -eq 0 ]; then
    if [ "$DETECT_ONLY" -eq 1 ]; then
        exit 1
    fi
    echo "Cargo sanitizers are not configured; skipping."
    exit 0
fi

if [ "$DETECT_ONLY" -eq 1 ]; then
    exit 0
fi

HOST_SYSTEM=$(uname -s)
HOST_MACHINE=$(uname -m)
case "$HOST_SYSTEM:$HOST_MACHINE" in
    Linux:x86_64)
        SANITIZER_TARGET="x86_64-unknown-linux-gnu"
        ;;
    Darwin:arm64)
        SANITIZER_TARGET="aarch64-apple-darwin"
        ;;
    Darwin:x86_64)
        SANITIZER_TARGET="x86_64-apple-darwin"
        ;;
    *)
        echo "AddressSanitizer is not supported on ${HOST_SYSTEM} ${HOST_MACHINE}; skipping."
        exit 0
        ;;
esac

SANITIZER_RUSTFLAGS="${RUSTFLAGS:-}"
SANITIZER_RUSTDOCFLAGS="${RUSTDOCFLAGS:-}"
if [ -n "$SANITIZER_RUSTFLAGS" ]; then
    SANITIZER_RUSTFLAGS+=" "
fi
if [ -n "$SANITIZER_RUSTDOCFLAGS" ]; then
    SANITIZER_RUSTDOCFLAGS+=" "
fi
SANITIZER_RUSTFLAGS+="-Zsanitizer=address"
SANITIZER_RUSTDOCFLAGS+="-Zsanitizer=address"

cd "$PROJECT_ROOT"
for package in "${PACKAGES[@]}"; do
    echo "Running AddressSanitizer for package '$package' on $SANITIZER_TARGET"
    RUSTFLAGS="$SANITIZER_RUSTFLAGS" \
        RUSTDOCFLAGS="$SANITIZER_RUSTDOCFLAGS" \
        cargo +"$RS_CI_SANITIZER_TOOLCHAIN" test \
        -Zbuild-std \
        --target "$SANITIZER_TARGET" \
        --all-features \
        --package "$package"
done
