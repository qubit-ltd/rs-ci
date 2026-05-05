#!/bin/bash
################################################################################
#
#    Copyright (c) 2026.
#    Haixing Hu, Qubit Co. Ltd.
#
#    All rights reserved.
#
################################################################################

# Purpose: Scan one Rust file for test attributes that must stay out of src/.
scan_test_attributes() {
    local file="$1"

    awk '
        /^[[:space:]]*#\[[[:space:]]*cfg[[:space:]]*\([[:space:]]*test[[:space:]]*\)[[:space:]]*\]/ {
            print FNR ":#[cfg(test)]"
        }
        /^[[:space:]]*#\[[[:space:]]*test([[:space:]]*\([^]]*\))?[[:space:]]*\]/ {
            print FNR ":#[test]"
        }
        /^[[:space:]]*#\[[[:space:]]*([[:alnum:]_]+::)+test([[:space:]]*\([^]]*\))?[[:space:]]*\]/ {
            print FNR ":#[...::test]"
        }
    ' "$file"
}

# Purpose: Enforce that source files do not contain inline test attributes.
check_inline_tests() {
    local source_root="$1"
    local file
    local rel_path
    local hit
    local line
    local attr

    [ "$STYLE_ENFORCE_INLINE_TESTS" = "1" ] || return 0
    if [ ! -d "$source_root" ]; then
        echo "warning: source directory '$source_root' does not exist; skipping inline test checks"
        return 0
    fi

    while IFS= read -r file; do
        rel_path="${file#$PROJECT_ROOT/}"
        is_extra_excluded "$rel_path" && continue
        has_style_allow "$file" "inline-tests" && continue

        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            line="${hit%%:*}"
            attr="${hit#*:}"
            report_error "$rel_path" "$line" \
                "test code must live under '$STYLE_TEST_DIR/'; found $attr in source"
        done < <(scan_test_attributes "$file")
    done < <(list_rs_files "$source_root")
}

# Purpose: Enforce naming conventions for files under the tests directory.
check_test_file_names() {
    local test_root="$1"
    local file
    local rel_path
    local base_name

    [ "$STYLE_ENFORCE_TEST_FILE_NAMES" = "1" ] || return 0
    [ -d "$test_root" ] || return 0

    while IFS= read -r file; do
        rel_path="${file#$PROJECT_ROOT/}"
        is_extra_excluded "$rel_path" && continue
        [[ "$rel_path" =~ $STYLE_TEST_SUPPORT_DIR_REGEX ]] && continue
        has_style_allow "$file" "test-file-name" && continue

        base_name=$(basename "$file")
        case "$base_name" in
            mod.rs | *_tests.rs)
                ;;
            *)
                report_error "$rel_path" "0" \
                    "test files should be named '*_tests.rs' or 'mod.rs'"
                ;;
        esac
    done < <(list_rs_files "$test_root")
}

# Purpose: Detect type-alias-only files eligible for test-pair exemption.
is_type_alias_only_file() {
    local file="$1"

    awk '
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            if (line ~ /^\/\// || line == "") {
                next
            }

            sub(/^pub([[:space:]]*\([^)]*\))?[[:space:]]+/, "", line)

            if (line ~ /^type[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/) {
                has_type_alias = 1
                next
            }

            if (line ~ /^(async[[:space:]]+fn|fn|struct|enum|trait|const|static|impl|macro_rules!|macro)([[:space:]<{!(]|$)/) {
                has_non_alias_item = 1
            }
        }

        END {
            exit (has_type_alias && !has_non_alias_item) ? 0 : 1
        }
    ' "$file"
}

# Purpose: Enforce that each concrete source file has a matching xxx_tests.rs file.
check_source_test_pairs() {
    local source_root="$1"
    local test_root="$2"
    local file
    local rel_path
    local src_rel_path
    local base_name
    local stem
    local src_dir
    local expected_test_rel
    local expected_test_file
    local expected_test_name
    local matched_test
    local source_sibling_test

    [ "$STYLE_ENFORCE_SOURCE_TEST_PAIRS" = "1" ] || return 0
    [ -d "$source_root" ] || return 0
    [ -d "$test_root" ] || return 0

    while IFS= read -r file; do
        rel_path="${file#$PROJECT_ROOT/}"
        is_extra_excluded "$rel_path" && continue
        [[ "$rel_path" =~ $STYLE_SKIP_SOURCE_TEST_PAIR_PATH_REGEX ]] && continue
        has_style_allow "$file" "source-test-pair" && continue
        is_type_alias_only_file "$file" && continue

        src_rel_path="${file#$source_root/}"
        base_name=$(basename "$src_rel_path")
        case "$base_name" in
            *_tests.rs)
                continue
                ;;
        esac
        stem="${base_name%.rs}"

        src_dir="${src_rel_path%/*}"
        if [ "$src_dir" = "$src_rel_path" ]; then
            expected_test_rel="${stem}_tests.rs"
        else
            expected_test_rel="${src_dir}/${stem}_tests.rs"
        fi

        expected_test_file="$test_root/$expected_test_rel"
        expected_test_name="${stem}_tests.rs"
        matched_test=""
        while IFS= read -r test_file; do
            if [ "$(basename "$test_file")" = "$expected_test_name" ]; then
                matched_test="$test_file"
                break
            fi
        done < <(list_rs_files "$test_root")
        source_sibling_test="${file%.rs}_tests.rs"
        if [ ! -f "$expected_test_file" ] && [ -z "$matched_test" ] && [ ! -f "$source_sibling_test" ]; then
            report_error "$rel_path" "0" \
                "missing corresponding test file '${STYLE_TEST_DIR}/${expected_test_rel}' (or any '${expected_test_name}' under '${STYLE_TEST_DIR}/', or source sibling '${source_sibling_test#$PROJECT_ROOT/}')"
        fi
    done < <(list_rs_files "$source_root")
}
