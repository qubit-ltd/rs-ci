#!/bin/bash
################################################################################
#
#    Copyright (c) 2026.
#    Haixing Hu, Qubit Co. Ltd.
#
#    All rights reserved.
#
################################################################################

# Purpose: Scan for wildcard imports that hide concrete dependencies.
scan_wildcard_imports() {
    local file="$1"

    awk '
        /^[[:space:]]*use[[:space:]]+/ && /(^|[^[:alnum:]_])\*([[:space:],};]|$)/ {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            print FNR ":" line
        }
    ' "$file"
}

# Purpose: Check whether a mod.rs file declares concrete items itself.
has_mod_rs_own_items() {
    local file="$1"

    awk '
        /^[[:space:]]*(pub([[:space:]]*\([^)]*\))?[[:space:]]+)?(async[[:space:]]+fn|fn|struct|enum|trait|type|const|static|impl|macro_rules!)([[:space:]<{!(]|$)/ {
            found = 1
        }
        END {
            exit found ? 0 : 1
        }
    ' "$file"
}

# Purpose: Scan lib.rs/mod.rs files for concrete item declarations.
scan_aggregation_file_items() {
    local file="$1"

    awk '
        /^[[:space:]]*(pub([[:space:]]*\([^)]*\))?[[:space:]]+)?(async[[:space:]]+fn|fn|struct|enum|trait|type|const|static|impl|macro_rules!)([[:space:]<{!(]|$)/ {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            print FNR ":" line
        }
    ' "$file"
}

# Purpose: Identify whether a file is an aggregation file (lib.rs or mod.rs).
is_aggregation_file() {
    local file="$1"
    local base_name

    base_name=$(basename "$file")
    [ "$base_name" = "lib.rs" ] || [ "$base_name" = "mod.rs" ]
}

# Purpose: Enforce aggregation-file purity for one root directory.
check_aggregation_files_in_root() {
    local root="$1"
    local file
    local rel_path
    local hit
    local line
    local item_text

    [ -d "$root" ] || return 0

    while IFS= read -r file; do
        is_aggregation_file "$file" || continue
        rel_path="${file#$PROJECT_ROOT/}"
        is_extra_excluded "$rel_path" && continue

        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            line="${hit%%:*}"
            item_text="${hit#*:}"
            report_error "$rel_path" "$line" \
                "lib.rs and mod.rs files must only declare modules and re-export items; move '$item_text' into a concrete source file"
        done < <(scan_aggregation_file_items "$file")
    done < <(list_rs_files "$root")
}

# Purpose: Run aggregation-file checks across source and tests roots.
check_aggregation_files() {
    local source_root="$1"
    local test_root="$2"

    [ "$STYLE_ENFORCE_AGGREGATION_FILES" = "1" ] || return 0
    check_aggregation_files_in_root "$source_root"
    check_aggregation_files_in_root "$test_root"
}

# Purpose: Scan mod.rs for private imports that should live in concrete modules.
scan_private_mod_rs_imports() {
    local file="$1"

    awk '
        /^[[:space:]]*pub[[:space:]]+use[[:space:]]+/ {
            next
        }
        /^[[:space:]]*use[[:space:]]+/ {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            print FNR ":" line
        }
    ' "$file"
}

# Purpose: Enforce explicit imports and mod.rs import placement for one root.
check_explicit_imports_in_root() {
    local root="$1"
    local file
    local rel_path
    local hit
    local line
    local import_text

    [ -d "$root" ] || return 0

    while IFS= read -r file; do
        rel_path="${file#$PROJECT_ROOT/}"
        is_extra_excluded "$rel_path" && continue
        has_style_allow "$file" "explicit-imports" && continue

        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            line="${hit%%:*}"
            import_text="${hit#*:}"
            report_error "$rel_path" "$line" \
                "wildcard imports hide dependencies; replace '$import_text' with explicit imports"
        done < <(scan_wildcard_imports "$file")

        if [ "$(basename "$file")" = "mod.rs" ] && ! has_mod_rs_own_items "$file"; then
            while IFS= read -r hit; do
                [ -n "$hit" ] || continue
                line="${hit%%:*}"
                import_text="${hit#*:}"
                report_error "$rel_path" "$line" \
                    "aggregation-only mod.rs files must not collect private imports for child modules; move '$import_text' into the concrete file that uses it"
            done < <(scan_private_mod_rs_imports "$file")
        fi
    done < <(list_rs_files "$root")
}

# Purpose: Run explicit-import checks across source and tests roots.
check_explicit_imports() {
    local source_root="$1"
    local test_root="$2"

    [ "$STYLE_ENFORCE_EXPLICIT_IMPORTS" = "1" ] || return 0
    check_explicit_imports_in_root "$source_root"
    check_explicit_imports_in_root "$test_root"
}
