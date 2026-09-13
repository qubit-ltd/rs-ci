#!/bin/bash
# Infer the consuming project root from either supported rs-ci tool location.

rs_ci_project_root() {
    local script_dir="$1"

    if [ -n "${RS_CI_PROJECT_ROOT:-}" ]; then
        printf '%s\n' "$RS_CI_PROJECT_ROOT"
    elif [[ "$script_dir" = */.infra/tools/rs-ci ]]; then
        (cd "$script_dir/../../.." && pwd -P)
    elif [[ "$script_dir" = */.rs-ci ]]; then
        (cd "$script_dir/.." && pwd -P)
    else
        printf '%s\n' "$script_dir"
    fi
}
