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
        function sanitize(text,    output, length_, i, character, next_character, j, hashes, matched, k, escaped) {
            output = ""
            length_ = length(text)
            i = 1
            while (i <= length_) {
                character = substr(text, i, 1)
                next_character = substr(text, i + 1, 1)

                if (block_comment_depth > 0) {
                    if (character == "/" && next_character == "*") {
                        block_comment_depth++
                        i += 2
                    } else if (character == "*" && next_character == "/") {
                        block_comment_depth--
                        i += 2
                    } else {
                        i++
                    }
                    continue
                }

                if (in_raw_string) {
                    if (character == "\"") {
                        matched = 1
                        for (k = 1; k <= raw_string_hashes; k++) {
                            if (substr(text, i + k, 1) != "#") {
                                matched = 0
                                break
                            }
                        }
                        if (matched) {
                            in_raw_string = 0
                            i += raw_string_hashes + 1
                            continue
                        }
                    }
                    i++
                    continue
                }

                if (in_string) {
                    if (escaped) {
                        escaped = 0
                    } else if (character == "\\") {
                        escaped = 1
                    } else if (character == "\"") {
                        in_string = 0
                    }
                    i++
                    continue
                }

                if (character == "/" && next_character == "/") {
                    break
                }
                if (character == "/" && next_character == "*") {
                    block_comment_depth = 1
                    i += 2
                    continue
                }

                j = 0
                if (character == "r") {
                    j = i + 1
                } else if (character == "b" && next_character == "r") {
                    j = i + 2
                }
                if (j > 0) {
                    hashes = 0
                    while (substr(text, j + hashes, 1) == "#") {
                        hashes++
                    }
                    if (substr(text, j + hashes, 1) == "\"") {
                        in_raw_string = 1
                        raw_string_hashes = hashes
                        i = j + hashes + 1
                        continue
                    }
                }

                if (character == "\"") {
                    in_string = 1
                    escaped = 0
                    i++
                    continue
                }

                if (character == "\047") {
                    j = i + 1
                    escaped = 0
                    while (j <= length_) {
                        next_character = substr(text, j, 1)
                        if (escaped) {
                            escaped = 0
                        } else if (next_character == "\\") {
                            escaped = 1
                        } else if (next_character == "\047") {
                            i = j + 1
                            break
                        }
                        j++
                    }
                    if (j <= length_) {
                        continue
                    }
                }

                output = output character
                i++
            }
            return output
        }

        /^[[:space:]]*#\[[[:space:]]*cfg[[:space:]]*\([[:space:]]*test[[:space:]]*\)[[:space:]]*\][[:space:]]*$/ {
            pending_test_module = 1
            next
        }
        /^[[:space:]]*#\[[[:space:]]*proc_macro(_attribute|_derive)?([[:space:](]|$)/ {
            proc_macro_entrypoint = 1
            next
        }
        /^[[:space:]]*#/ {
            next
        }

        {
            raw = sanitize($0)
            opens = gsub(/\{/, "{", raw)
            closes = gsub(/\}/, "}", raw)

            if (pending_test_module && $0 ~ /^[[:space:]]*mod[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\{/) {
                test_module_depth = depth + opens
                pending_test_module = 0
            } else if (pending_test_module && $0 !~ /^[[:space:]]*$/) {
                pending_test_module = 0
            }

            inside_test_module = test_module_depth > 0 && depth >= test_module_depth
            if (!inside_test_module && $0 ~ /^[[:space:]]*(pub([[:space:]]*\([^)]*\))?[[:space:]]+)?(async[[:space:]]+fn|fn|struct|enum|trait|type|const|static|impl|macro_rules!)([[:space:]<{!(]|$)/) {
                if (proc_macro_entrypoint && $0 ~ /^[[:space:]]*(pub([[:space:]]*\([^)]*\))?[[:space:]]+)?(async[[:space:]]+)?fn([[:space:]<{(]|$)/) {
                    proc_macro_entrypoint = 0
                } else {
                    line = $0
                    sub(/^[[:space:]]*/, "", line)
                    print FNR ":" line
                    proc_macro_entrypoint = 0
                }
            }

            depth += opens - closes
            if (test_module_depth > 0 && depth < test_module_depth) {
                test_module_depth = 0
            }
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
        rel_path="${file#"$PROJECT_ROOT"/}"
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
        rel_path="${file#"$PROJECT_ROOT"/}"
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
