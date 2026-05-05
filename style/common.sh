#!/bin/bash
################################################################################
#
#    Copyright (c) 2026.
#    Haixing Hu, Qubit Co. Ltd.
#
#    All rights reserved.
#
################################################################################

# Purpose: Ensure a required external command exists in PATH.
require_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        echo "error: required command '$1' was not found" >&2
        exit 1
    fi
}

# Purpose: Report a style violation and increment the global failure counter.
report_error() {
    local file="$1"
    local line="$2"
    local message="$3"

    if [ "$line" = "0" ]; then
        echo "error: $file: $message"
    else
        echo "error: $file:$line: $message"
    fi
    FAILURES=$((FAILURES + 1))
}

# Purpose: Check whether a file has an inline allow comment for a rule.
has_style_allow() {
    local file="$1"
    local rule="$2"

    grep -Fq "qubit-style: allow all" "$file" \
        || grep -Fq "qubit-style: allow $rule" "$file"
}

# Purpose: Require both inline allow and allowlist entry for restricted exceptions.
has_approved_style_allow() {
    local file="$1"
    local rel_path="$2"
    local rule="$3"

    grep -Fq "qubit-style: allow $rule" "$file" || return 1
    [ -f "$STYLE_ALLOWLIST_FILE" ] || return 1

    awk -v expected_rule="$rule" -v expected_path="$rel_path" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }

        /^[[:space:]]*(#|$)/ {
            next
        }

        {
            field_count = split($0, fields, /\|/)
            if (field_count < 3) {
                next
            }

            rule = trim(fields[1])
            path = trim(fields[2])
            reason = trim(fields[3])
            if (rule == expected_rule && path == expected_path && reason != "") {
                found = 1
            }
        }

        END {
            exit found ? 0 : 1
        }
    ' "$STYLE_ALLOWLIST_FILE"
}

# Purpose: Apply repository-wide extra exclusion regex to a relative path.
is_extra_excluded() {
    local rel_path="$1"

    [ -n "$STYLE_EXTRA_EXCLUDE_REGEX" ] && [[ "$rel_path" =~ $STYLE_EXTRA_EXCLUDE_REGEX ]]
}

# Purpose: Convert a Rust type name from PascalCase to snake_case.
snake_case_type_name() {
    local type_name="$1"

    printf '%s' "$type_name" \
        | sed -E 's/([A-Z]+)([A-Z][a-z])/\1_\2/g; s/([a-z0-9])([A-Z])/\1_\2/g' \
        | tr '[:upper:]' '[:lower:]'
}

# Purpose: List Rust source files under a directory in stable sorted order.
list_rs_files() {
    local dir="$1"

    [ -d "$dir" ] || return 0
    find "$dir" -type f -name '*.rs' ! -path '*/target/*' -print | LC_ALL=C sort
}
