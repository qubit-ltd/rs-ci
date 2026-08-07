#!/bin/bash
################################################################################
#
#    Copyright (c) 2026.
#    Haixing Hu, Qubit Co. Ltd.
#
#    All rights reserved.
#
################################################################################

# Purpose: Find allow attributes that hide unused imports.
scan_unused_import_allows() {
    local file="$1"

    awk '
        /^[[:space:]]*#\[[[:space:]]*allow[[:space:]]*\([^]]*unused_imports[^]]*\)[[:space:]]*\]/ {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            print FNR ":" line
        }
    ' "$file"
}

# Purpose: Find use declarations that import more than one object.
scan_grouped_imports() {
    local file="$1"

    awk '
        function is_use_start(line) {
            return line ~ /^[[:space:]]*(pub([[:space:]]*\([^)]*\))?[[:space:]]+)?use[[:space:]]+/
        }

        {
            if (!in_use && is_use_start($0)) {
                in_use = 1
                start_line = FNR
                has_brace = ($0 ~ /\{/) ? 1 : 0
            } else if (in_use && $0 ~ /\{/) {
                has_brace = 1
            }

            if (in_use && $0 ~ /;/) {
                if (has_brace) {
                    print start_line ":use declarations must import one object; brace lists are not allowed"
                }
                in_use = 0
                has_brace = 0
            }
        }
    ' "$file"
}

# Purpose: Check import group order, blank separators, and lexical ordering.
scan_import_order() {
    local file="$1"

    LC_ALL=C awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }

        function import_group(path) {
            if (path ~ /^(crate|self|super)(::|$)/) {
                return 2
            }
            if (path ~ /^(std|core|alloc)(::|$)/) {
                return 0
            }
            return 1
        }

        function is_simple_use(line) {
            return line ~ /^[[:space:]]*(pub([[:space:]]*\([^)]*\))?[[:space:]]+)?use[[:space:]]+[^{};]+;[[:space:]]*$/
        }

        function is_use_attribute(line) {
            return line ~ /^[[:space:]]*#\[[[:space:]]*(cfg|cfg_attr|allow|deny|warn|expect)[[:space:]]*[(:]/
        }

        function sort_key(path, group) {
            if (group == 2) {
                if (path ~ /^self(::|$)/) {
                    return "0:" path
                }
                if (path ~ /^super(::|$)/) {
                    return "1:" path
                }
                return "2:" path
            }
            return path
        }

        {
            if (is_simple_use($0)) {
                text = $0
                sub(/^[[:space:]]*(pub([[:space:]]*\([^)]*\))?[[:space:]]+)?use[[:space:]]+/, "", text)
                sub(/[[:space:]]*;[[:space:]]*$/, "", text)
                path = text
                sub(/[[:space:]]+as[[:space:]]+[A-Za-z_][A-Za-z0-9_]*$/, "", path)
                path = trim(path)
                group = import_group(path)
                order_key = sort_key(path, group)

                if (have_import && group < last_group) {
                    print FNR ":standard-library imports must precede external imports, and external imports must precede current-crate imports"
                }
                if (have_import && group != last_group && blank_lines != 1) {
                    print FNR ":import groups must be separated by exactly one blank line"
                }
                if (have_import && group == last_group && order_key < last_order_key) {
                    print FNR ":imports within each group must be sorted lexicographically"
                }

                have_import = 1
                last_group = group
                last_order_key = order_key
                blank_lines = 0
                next
            }

            if ($0 ~ /^[[:space:]]*$/) {
                if (have_import) {
                    blank_lines++
                }
            } else if (have_import && !is_use_attribute($0)) {
                have_import = 0
                blank_lines = 0
            }
        }
    ' "$file"
}

# Purpose: Find fully qualified external-crate paths used outside use declarations.
scan_qualified_external_paths() {
    local file="$1"

    awk '
        function is_use_line(line) {
            return line ~ /^[[:space:]]*(pub([[:space:]]*\([^)]*\))?[[:space:]]+)?use[[:space:]]+/
        }

        {
            lines[FNR] = $0
            if (is_use_line($0)) {
                text = $0
                sub(/^[[:space:]]*(pub([[:space:]]*\([^)]*\))?[[:space:]]+)?use[[:space:]]+/, "", text)
                root = text
                sub(/::.*/, "", root)
                if (root !~ /^(crate|self|super|std|core|alloc)$/) {
                    external_roots[root] = 1
                }
            }
        }

        END {
            for (line_number = 1; line_number <= FNR; line_number++) {
                line = lines[line_number]
                if (is_use_line(line) || line ~ /^[[:space:]]*\/\//) {
                    continue
                }

                if (line ~ /(^|[^[:alnum:]_])qubit[[:alnum:]_]*::/) {
                    print line_number ":fully qualified external crate path found; import the object with use"
                    continue
                }

                for (root in external_roots) {
                    pattern = "(^|[^[:alnum:]_])" root "::"
                    if (line ~ pattern) {
                        print line_number ":fully qualified external crate path found; import the object with use"
                        break
                    }
                }
            }
        }
    ' "$file"
}

# Purpose: Find Rustdoc comments placed after attributes.
scan_misordered_rustdoc() {
    local file="$1"

    awk '
        /^[[:space:]]*#\[[[:space:]]*doc[[:space:]]*=/ {
            previous_attribute = 0
            next
        }
        /^[[:space:]]*#\[/ {
            previous_attribute = 1
            next
        }
        /^[[:space:]]*\/\/\/|^[[:space:]]*\/\/!/ {
            if (previous_attribute) {
                print FNR ":Rustdoc comments must precede attributes"
            }
            previous_attribute = 0
            next
        }
        /^[[:space:]]*$/ {
            previous_attribute = 0
            next
        }
        {
            previous_attribute = 0
        }
    ' "$file"
}

# Purpose: Run import and Rustdoc ordering checks for one root.
check_rust_style_in_root() {
    local root="$1"
    local file
    local rel_path
    local hit
    local line
    local message

    [ -d "$root" ] || return 0

    while IFS= read -r file; do
        rel_path="${file#"$PROJECT_ROOT"/}"
        is_extra_excluded "$rel_path" && continue

        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            line="${hit%%:*}"
            message="${hit#*:}"
            report_error "$rel_path" "$line" "$message"
        done < <(scan_unused_import_allows "$file")

        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            line="${hit%%:*}"
            message="${hit#*:}"
            report_error "$rel_path" "$line" "$message"
        done < <(scan_grouped_imports "$file")

        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            line="${hit%%:*}"
            message="${hit#*:}"
            report_error "$rel_path" "$line" "$message"
        done < <(scan_import_order "$file")

        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            line="${hit%%:*}"
            message="${hit#*:}"
            report_error "$rel_path" "$line" "$message"
        done < <(scan_qualified_external_paths "$file")

        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            line="${hit%%:*}"
            message="${hit#*:}"
            report_error "$rel_path" "$line" "$message"
        done < <(scan_misordered_rustdoc "$file")

    done < <(list_rs_files "$root")
}

# Purpose: Run Rust style checks across source and test roots.
check_rust_style() {
    local source_root="$1"
    local test_root="$2"

    [ "$STYLE_ENFORCE_EXPLICIT_IMPORTS" = "1" ] || return 0
    check_rust_style_in_root "$source_root"
    check_rust_style_in_root "$test_root"
}
