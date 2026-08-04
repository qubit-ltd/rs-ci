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
# Shared Cargo environment setup for rs-ci entry scripts.
#

configure_rs_ci_cargo_home() {
    local project_root="$1"
    local mode="${RS_CI_CARGO_HOME_MODE:-project}"
    local original_cargo_home
    local cargo_home_root
    local project_name
    local original_cargo_bin

    if [ -n "${CARGO_HOME:-}" ]; then
        original_cargo_home="$CARGO_HOME"
    elif [ -n "${HOME:-}" ]; then
        original_cargo_home="$HOME/.cargo"
    else
        echo "error: HOME is not set and CARGO_HOME was not provided" >&2
        return 1
    fi
    export RS_CI_ORIGINAL_CARGO_HOME="$original_cargo_home"

    case "$mode" in
        "" | shared)
            return 0
            ;;
        project)
            ;;
        *)
            echo "error: unsupported RS_CI_CARGO_HOME_MODE '$mode'; expected 'shared' or 'project'" >&2
            return 2
            ;;
    esac

    project_root=$(cd "$project_root" && pwd)
    project_name=$(basename "$project_root")
    if [ -z "$project_name" ] || [ "$project_name" = "." ] || [ "$project_name" = "/" ]; then
        echo "error: unable to derive project name from '$project_root'" >&2
        return 1
    fi

    if [ -n "${RS_CI_CARGO_HOME_ROOT:-}" ]; then
        cargo_home_root="$RS_CI_CARGO_HOME_ROOT"
    elif [ -n "${XDG_CACHE_HOME:-}" ]; then
        cargo_home_root="$XDG_CACHE_HOME/rs-ci/cargo-home"
    elif [ -n "${HOME:-}" ]; then
        cargo_home_root="$HOME/.cache/rs-ci/cargo-home"
    else
        echo "error: HOME is not set and RS_CI_CARGO_HOME_ROOT was not provided" >&2
        return 1
    fi

    export CARGO_HOME="$cargo_home_root/$project_name"
    mkdir -p "$CARGO_HOME"

    original_cargo_bin="$original_cargo_home/bin"
    case ":${PATH:-}:" in
        *":$original_cargo_bin:"*)
            ;;
        *)
            if [ -n "${PATH:-}" ]; then
                export PATH="$original_cargo_bin:$PATH"
            else
                export PATH="$original_cargo_bin"
            fi
            ;;
    esac
}
