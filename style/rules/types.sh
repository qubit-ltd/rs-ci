#!/bin/bash
################################################################################
#
#    Copyright (c) 2026.
#    Haixing Hu, Qubit Co. Ltd.
#
#    All rights reserved.
#
################################################################################

# Purpose: Extract top-level Rust type declarations from one file.
scan_top_level_types() {
    local file="$1"
    local visibility="$2"
    local include_type_aliases="$3"

    awk -v visibility="$visibility" -v include_aliases="$include_type_aliases" '
        function emit_if_type(line, line_no) {
            kind_pattern = include_aliases == "1" ? "(struct|enum|trait|type)" : "(struct|enum|trait)"
            if (line ~ "^" kind_pattern "[[:space:]]+[A-Z][A-Za-z0-9_]*") {
                split(line, parts, /[[:space:]]+/)
                type_name = parts[2]
                sub(/[<({;:].*/, "", type_name)
                print line_no ":" parts[1] ":" type_name
            }
        }

        {
            line = $0
            sub(/^[[:space:]]*/, "", line)

            if (visibility == "public") {
                if (line !~ /^pub([[:space:]]*\([^)]*\))?[[:space:]]+/) {
                    next
                }
                sub(/^pub([[:space:]]*\([^)]*\))?[[:space:]]+/, "", line)
                emit_if_type(line, FNR)
                next
            }

            sub(/^pub([[:space:]]*\([^)]*\))?[[:space:]]+/, "", line)
            emit_if_type(line, FNR)
        }
    ' "$file"
}

# Purpose: Enforce one-type-per-file and type-name-to-file-name alignment rules.
check_public_type_files() {
    local source_root="$1"
    local file
    local rel_path
    local base_name
    local stem
    local entries
    local count
    local first_entry
    local line
    local kind
    local type_name
    local expected_stem
    local type_summary

    [ "$STYLE_ENFORCE_PUBLIC_TYPE_FILES" = "1" ] || return 0
    if [ "$STYLE_TYPE_VISIBILITY" != "public" ] && [ "$STYLE_TYPE_VISIBILITY" != "all" ]; then
        echo "error: STYLE_TYPE_VISIBILITY must be 'public' or 'all'" >&2
        exit 1
    fi
    if [ ! -d "$source_root" ]; then
        echo "warning: source directory '$source_root' does not exist; skipping type layout checks"
        return 0
    fi

    while IFS= read -r file; do
        rel_path="${file#$PROJECT_ROOT/}"
        is_extra_excluded "$rel_path" && continue
        [[ "$rel_path" =~ $STYLE_SKIP_TYPE_PATH_REGEX ]] && continue
        has_style_allow "$file" "public-type-layout" && continue

        entries=$(scan_top_level_types "$file" "$STYLE_TYPE_VISIBILITY" "$STYLE_INCLUDE_TYPE_ALIASES")
        [ -n "$entries" ] || continue

        count=$(printf '%s\n' "$entries" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')
        if [ "$count" -gt 1 ]; then
            if ! has_approved_style_allow "$file" "$rel_path" "multiple-public-types"; then
                type_summary=$(printf '%s\n' "$entries" | awk -F: '{ printf "%s %s at line %s; ", $2, $3, $1 }')
                report_error "$rel_path" "0" \
                    "file contains multiple ${STYLE_TYPE_VISIBILITY} top-level types; split them or add both '// qubit-style: allow multiple-public-types' and a reviewed STYLE_ALLOWLIST_FILE entry. Inline allow comments alone are not accepted for this rule. Found: $type_summary"
            fi
            continue
        fi

        has_style_allow "$file" "type-file-name" && continue

        first_entry="$entries"
        line="${first_entry%%:*}"
        first_entry="${first_entry#*:}"
        kind="${first_entry%%:*}"
        type_name="${first_entry#*:}"
        expected_stem=$(snake_case_type_name "$type_name")
        base_name=$(basename "$file")
        stem="${base_name%.rs}"

        if [ "$stem" != "$expected_stem" ]; then
            report_error "$rel_path" "$line" \
                "$kind '$type_name' should live in '${expected_stem}.rs', not '$base_name'"
        fi
    done < <(list_rs_files "$source_root")
}
