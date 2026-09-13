#!/bin/bash
# Resolve a project-owned rs-ci config while preserving the legacy filename.

rs_ci_config_path() {
    local project_root="$1"
    local preferred="$2"
    local legacy="$3"
    local override="${4:-}"

    if [ -n "$override" ]; then
        if [[ "$override" = /* ]]; then
            printf '%s\n' "$override"
        else
            printf '%s\n' "$project_root/$override"
        fi
    elif [ -f "$project_root/$preferred" ]; then
        printf '%s\n' "$project_root/$preferred"
    elif [ -f "$project_root/$legacy" ]; then
        echo "warning: $legacy is deprecated; move it to $preferred" >&2
        printf '%s\n' "$project_root/$legacy"
    else
        printf '%s\n' "$project_root/$preferred"
    fi
}
