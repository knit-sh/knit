#!/bin/bash

## @file db.sh

# ------------------------------------------------------------------------------
# @fn __knit_db_sql_ident()
#
# Wrap an SQL identifier (table or column name) in double quotes, escaping any
# embedded double-quote characters by doubling them, per the SQL standard.
#
# Example:
# ```
# __knit_db_sql_ident "my_table"   # prints: "my_table"
# __knit_db_sql_ident 'a"b'        # prints: "a""b"
# ```
#
# @param name Identifier to quote.
# ------------------------------------------------------------------------------
__knit_db_sql_ident() {
    printf '"%s"' "${1//\"/\"\"}"
}

# ------------------------------------------------------------------------------
# @fn __knit_db_create_table()
#
# Create a new table in the Knit database. Each column specification must be of
# the form "name:type" where type is a valid Knit type. Column names are
# normalized (hyphens converted to underscores). Fails with a fatal error if
# the table already exists, if no columns are specified, if a column spec is
# malformed, or if a type is unknown.
#
# Example:
# ```
# __knit_db_create_table "runs" "id:uuid" "duration:real" "label:string"
# ```
#
# @param table_name Name of the table to create.
# @param ...specs   One or more "column-name:type" specifications.
# ------------------------------------------------------------------------------
__knit_db_create_table() {
    local table_name="$1"
    shift

    if [[ $# -eq 0 ]]; then
        knit_fatal "__knit_db_create_table requires at least one column specification."
    fi

    local exists
    exists=$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$(__knit_sql_escape "${table_name}")';" )
    if [[ "${exists}" -ne 0 ]]; then
        knit_fatal "Table \"${table_name}\" already exists in the database."
    fi

    local col_defs=()
    local spec
    for spec in "$@"; do
        if [[ "${spec}" != *:* ]]; then
            knit_fatal "Column specification \"${spec}\" is missing a type (expected \"name:type\")."
        fi
        local col_name="${spec%%:*}"
        local col_type="${spec#*:}"
        col_name=$(_knit_str_hyphens_to_underscores "${col_name}")
        local sqlite_type
        sqlite_type=$(__knit_type_to_sqlite "${col_type}") \
            || knit_fatal "Column \"${col_name}\" has unknown type \"${col_type}\"."
        col_defs+=("$(__knit_db_sql_ident "${col_name}") ${sqlite_type}")
    done

    local cols_sql
    cols_sql=$(IFS=', '; printf '%s' "${col_defs[*]}")
    _knit_sqlite3 "CREATE TABLE $(__knit_db_sql_ident "${table_name}") (${cols_sql});"
}

# ------------------------------------------------------------------------------
# @fn __knit_db_check_table()
#
# Check whether a table exists in the Knit database and matches the given
# column specifications exactly (count, names, types, and order). Returns 0 if
# the table exists and matches, 1 if the table does not exist, or 2 if the
# table exists but the schema differs from what was specified.
#
# Example:
# ```
# __knit_db_check_table "runs" "id:uuid" "duration:real"
# # returns 0, 1, or 2
# ```
#
# @param table_name Name of the table to check.
# @param ...specs   One or more "column-name:type" specifications.
# @return 0 if the table matches, 1 if absent, 2 if schema differs.
# ------------------------------------------------------------------------------
__knit_db_check_table() {
    local table_name="$1"
    shift

    local exists
    exists=$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$(__knit_sql_escape "${table_name}")';" )
    if [[ "${exists}" -eq 0 ]]; then
        return 1
    fi

    local expected_names=()
    local expected_types=()
    local spec
    for spec in "$@"; do
        if [[ "${spec}" != *:* ]]; then
            knit_fatal "Column specification \"${spec}\" is missing a type (expected \"name:type\")."
        fi
        local col_name="${spec%%:*}"
        local col_type="${spec#*:}"
        col_name=$(_knit_str_hyphens_to_underscores "${col_name}")
        local sqlite_type
        sqlite_type=$(__knit_type_to_sqlite "${col_type}") || return 2
        expected_names+=("${col_name}")
        expected_types+=("${sqlite_type}")
    done

    local actual_names=()
    local actual_types=()
    while IFS='|' read -r _cid col_name col_type _rest; do
        actual_names+=("${col_name}")
        actual_types+=("${col_type}")
    done < <(_knit_sqlite3 "PRAGMA table_info('$(__knit_sql_escape "${table_name}")');" )

    if [[ "${#expected_names[@]}" -ne "${#actual_names[@]}" ]]; then
        return 2
    fi

    local i
    for (( i = 0; i < ${#expected_names[@]}; i++ )); do
        if [[ "${expected_names[$i]}" != "${actual_names[$i]}" ]] \
        || [[ "${expected_types[$i]}" != "${actual_types[$i]}" ]]; then
            return 2
        fi
    done

    return 0
}
