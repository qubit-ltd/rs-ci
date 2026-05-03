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
# Rust project style checks that are not covered by rustfmt or Clippy.
#

set -euo pipefail

STYLE_SOURCE_DIR="${STYLE_SOURCE_DIR:-src}"
STYLE_TEST_DIR="${STYLE_TEST_DIR:-tests}"
STYLE_ENFORCE_INLINE_TESTS="${STYLE_ENFORCE_INLINE_TESTS:-1}"
STYLE_ENFORCE_TEST_FILE_NAMES="${STYLE_ENFORCE_TEST_FILE_NAMES:-1}"
STYLE_ENFORCE_PUBLIC_TYPE_FILES="${STYLE_ENFORCE_PUBLIC_TYPE_FILES:-1}"
STYLE_ENFORCE_EXPLICIT_IMPORTS="${STYLE_ENFORCE_EXPLICIT_IMPORTS:-1}"
STYLE_ENFORCE_AGGREGATION_FILES="${STYLE_ENFORCE_AGGREGATION_FILES:-1}"
STYLE_ENFORCE_COVERAGE_CFG="${STYLE_ENFORCE_COVERAGE_CFG:-1}"
STYLE_TYPE_VISIBILITY="${STYLE_TYPE_VISIBILITY:-public}"
STYLE_INCLUDE_TYPE_ALIASES="${STYLE_INCLUDE_TYPE_ALIASES:-0}"
STYLE_EXTRA_EXCLUDE_REGEX="${STYLE_EXTRA_EXCLUDE_REGEX:-}"
STYLE_ALLOWLIST_FILE="${STYLE_ALLOWLIST_FILE:-}"
STYLE_SKIP_TYPE_PATH_REGEX="${STYLE_SKIP_TYPE_PATH_REGEX:-(^|/)(lib|main|mod|macros)\\.rs$}"
STYLE_TEST_SUPPORT_DIR_REGEX="${STYLE_TEST_SUPPORT_DIR_REGEX:-(^|/)(support|common|fixtures|coverage_support)(/|$)}"

FAILURES=0

print_usage() {
    echo "Usage: ./style-check.sh [options]"
    echo ""
    echo "Options:"
    echo "  help       Show this help information"
    echo ""
    echo "Environment:"
    echo "  RS_CI_PROJECT_ROOT=${RS_CI_PROJECT_ROOT:-<script directory>}"
    echo "  STYLE_SOURCE_DIR=${STYLE_SOURCE_DIR}"
    echo "  STYLE_TEST_DIR=${STYLE_TEST_DIR}"
    echo "  STYLE_ENFORCE_INLINE_TESTS=${STYLE_ENFORCE_INLINE_TESTS}"
    echo "  STYLE_ENFORCE_TEST_FILE_NAMES=${STYLE_ENFORCE_TEST_FILE_NAMES}"
    echo "  STYLE_ENFORCE_PUBLIC_TYPE_FILES=${STYLE_ENFORCE_PUBLIC_TYPE_FILES}"
    echo "  STYLE_ENFORCE_EXPLICIT_IMPORTS=${STYLE_ENFORCE_EXPLICIT_IMPORTS}"
    echo "  STYLE_ENFORCE_AGGREGATION_FILES=${STYLE_ENFORCE_AGGREGATION_FILES}"
    echo "  STYLE_ENFORCE_COVERAGE_CFG=${STYLE_ENFORCE_COVERAGE_CFG}"
    echo "  STYLE_TYPE_VISIBILITY=${STYLE_TYPE_VISIBILITY}      # public or all"
    echo "  STYLE_INCLUDE_TYPE_ALIASES=${STYLE_INCLUDE_TYPE_ALIASES}"
    echo "  STYLE_EXTRA_EXCLUDE_REGEX=${STYLE_EXTRA_EXCLUDE_REGEX}"
    echo "  STYLE_ALLOWLIST_FILE=${STYLE_ALLOWLIST_FILE:-<project root>/.qubit-style-allowlist}"
    echo "  STYLE_SKIP_TYPE_PATH_REGEX=${STYLE_SKIP_TYPE_PATH_REGEX}"
    echo "  STYLE_TEST_SUPPORT_DIR_REGEX=${STYLE_TEST_SUPPORT_DIR_REGEX}"
    echo ""
    echo "File-level allow comments:"
    echo "  // qubit-style: allow all"
    echo "  // qubit-style: allow inline-tests"
    echo "  // qubit-style: allow test-file-name"
    echo "  // qubit-style: allow public-type-layout"
    echo "  // qubit-style: allow multiple-public-types"
    echo "  // qubit-style: allow type-file-name"
    echo "  // qubit-style: allow explicit-imports"
    echo "  // qubit-style: allow coverage-cfg"
    echo ""
    echo "The multiple-public-types allow comment also requires a project-level"
    echo "allowlist entry in STYLE_ALLOWLIST_FILE using this format:"
    echo "  multiple-public-types | src/example.rs | Reason for keeping types together"
    echo ""
    echo "The coverage-cfg allow comment also requires a project-level"
    echo "allowlist entry in STYLE_ALLOWLIST_FILE using this format:"
    echo "  coverage-cfg | src/example.rs | Reason why coverage cfg is unavoidable"
}

require_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        echo "error: required command '$1' was not found" >&2
        exit 1
    fi
}

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

has_style_allow() {
    local file="$1"
    local rule="$2"

    grep -Fq "qubit-style: allow all" "$file" \
        || grep -Fq "qubit-style: allow $rule" "$file"
}

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

is_extra_excluded() {
    local rel_path="$1"

    [ -n "$STYLE_EXTRA_EXCLUDE_REGEX" ] && [[ "$rel_path" =~ $STYLE_EXTRA_EXCLUDE_REGEX ]]
}

snake_case_type_name() {
    local type_name="$1"

    printf '%s' "$type_name" \
        | sed -E 's/([A-Z]+)([A-Z][a-z])/\1_\2/g; s/([a-z0-9])([A-Z])/\1_\2/g' \
        | tr '[:upper:]' '[:lower:]'
}

list_rs_files() {
    local dir="$1"

    [ -d "$dir" ] || return 0
    find "$dir" -type f -name '*.rs' ! -path '*/target/*' -print | LC_ALL=C sort
}

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

is_aggregation_file() {
    local file="$1"
    local base_name

    base_name=$(basename "$file")
    [ "$base_name" = "lib.rs" ] || [ "$base_name" = "mod.rs" ]
}

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

check_aggregation_files() {
    local source_root="$1"
    local test_root="$2"

    [ "$STYLE_ENFORCE_AGGREGATION_FILES" = "1" ] || return 0
    check_aggregation_files_in_root "$source_root"
    check_aggregation_files_in_root "$test_root"
}

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

check_explicit_imports() {
    local source_root="$1"
    local test_root="$2"

    [ "$STYLE_ENFORCE_EXPLICIT_IMPORTS" = "1" ] || return 0
    check_explicit_imports_in_root "$source_root"
    check_explicit_imports_in_root "$test_root"
}

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

main() {
    local arg="${1:-}"
    local script_dir
    local source_root
    local test_root

    case "$arg" in
        "" )
            ;;
        help | --help | -h )
            print_usage
            exit 0
            ;;
        * )
            echo "error: unknown argument '$arg'" >&2
            print_usage >&2
            exit 1
            ;;
    esac

    require_command awk
    require_command basename
    require_command find
    require_command grep
    require_command sed
    require_command tr
    require_command wc

    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    PROJECT_ROOT="${RS_CI_PROJECT_ROOT:-$script_dir}"
    if [ -z "$STYLE_ALLOWLIST_FILE" ]; then
        STYLE_ALLOWLIST_FILE="$PROJECT_ROOT/.qubit-style-allowlist"
    fi
    cd "$PROJECT_ROOT"

    source_root="$PROJECT_ROOT/$STYLE_SOURCE_DIR"
    test_root="$PROJECT_ROOT/$STYLE_TEST_DIR"

    echo "Running Rust style checks in $PROJECT_ROOT"
    echo ""

    check_inline_tests "$source_root"
    check_test_file_names "$test_root"
    check_public_type_files "$source_root"
    check_aggregation_files "$source_root" "$test_root"
    check_explicit_imports "$source_root" "$test_root"
    check_coverage_cfg "$source_root"

    echo ""
    if [ "$FAILURES" -gt 0 ]; then
        echo "Rust style checks failed with $FAILURES issue(s)."
        exit 1
    fi

    echo "Rust style checks passed."
}

main "$@"
