#!/bin/bash
################################################################################
#
#    Copyright (c) 2026.
#    Haixing Hu, Qubit Co. Ltd.
#
#    All rights reserved.
#
################################################################################

# Purpose: Scan for coverage-related cfg/cfg_attr attributes in source files.
scan_coverage_cfg_attributes() {
    local file="$1"

    awk '
        /^[[:space:]]*#\[[[:space:]]*cfg[[:space:]]*\([^]]*coverage[^]]*\)[[:space:]]*\]/ {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            print FNR ":" line
        }
        /^[[:space:]]*#\[[[:space:]]*cfg_attr[[:space:]]*\([^]]*coverage[^]]*\)[[:space:]]*\]/ {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            print FNR ":" line
        }
    ' "$file"
}

# Purpose: Enforce that coverage-specific cfg attributes are not used in source.
check_coverage_cfg() {
    local source_root="$1"
    local file
    local rel_path
    local hit
    local line
    local attr_text

    [ "$STYLE_ENFORCE_COVERAGE_CFG" = "1" ] || return 0
    if [ ! -d "$source_root" ]; then
        echo "warning: source directory '$source_root' does not exist; skipping coverage cfg checks"
        return 0
    fi

    while IFS= read -r file; do
        rel_path="${file#$PROJECT_ROOT/}"
        is_extra_excluded "$rel_path" && continue
        has_approved_style_allow "$file" "$rel_path" "coverage-cfg" && continue

        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            line="${hit%%:*}"
            attr_text="${hit#*:}"
            report_error "$rel_path" "$line" \
                "coverage-specific cfg is not allowed in source; found '$attr_text'. Replace coverage-only code with behavior tests, or add both '// qubit-style: allow coverage-cfg' and a reviewed STYLE_ALLOWLIST_FILE entry."
        done < <(scan_coverage_cfg_attributes "$file")
    done < <(list_rs_files "$source_root")
}
