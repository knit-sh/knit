#!/bin/bash

## @file db.sh

# ------------------------------------------------------------------------------
# @var _KNIT_DB_REGISTERED_TABLES
#
# Associative array mapping table name to the demangled command name that
# registered it. Used to detect duplicate table use across commands.
# ------------------------------------------------------------------------------
declare -gA _KNIT_DB_REGISTERED_TABLES

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
# @fn __knit_db_type_default()
#
# Return a sensible default value string for a given Knit type. Used when
# migrating a table to provide a back-fill value for newly added columns that
# do not have a user-supplied default.
#
# Example:
# ```
# __knit_db_type_default "integer"  # prints: 0
# __knit_db_type_default "boolean"  # prints: false
# __knit_db_type_default "string"   # prints: (empty)
# ```
#
# @param type Knit type name or alias.
# ------------------------------------------------------------------------------
__knit_db_type_default() {
    local type="$1"
    local resolved
    resolved=$(__knit_type_resolve_alias "${type}") || resolved="${type}"
    case "${resolved}" in
        integer) printf '0' ;;
        real)    printf '0' ;;
        boolean) printf 'false' ;;
        *)       printf '' ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_db_create_table()
#
# Create a new table in the Knit database. Each column specification must be of
# the form "name:type" where type is a valid Knit type. Column names are
# normalized (hyphens converted to underscores). Fails with a fatal error if
# the table already exists, if no columns are specified, if a column spec is
# malformed, or if a type is unknown.
#
# Example:
# ```
# _knit_db_create_table "runs" "id:uuid" "duration:real" "label:string"
# ```
#
# @param table_name Name of the table to create.
# @param ...specs   One or more "column-name:type" specifications.
# ------------------------------------------------------------------------------
_knit_db_create_table() {
    local table_name="$1"
    shift

    if [[ $# -eq 0 ]]; then
        knit_fatal "_knit_db_create_table requires at least one column specification."
    fi

    local exists
    exists=$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$(_knit_sql_escape "${table_name}")';" )
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
# @fn _knit_db_check_table()
#
# Check whether a table exists in the Knit database and matches the given
# column specifications exactly (count, names, types, and order). Returns 0 if
# the table exists and matches, 1 if the table does not exist, or 2 if the
# table exists but the schema differs from what was specified.
#
# Example:
# ```
# _knit_db_check_table "runs" "id:uuid" "duration:real"
# # returns 0, 1, or 2
# ```
#
# @param table_name Name of the table to check.
# @param ...specs   One or more "column-name:type" specifications.
# @return 0 if the table matches, 1 if absent, 2 if schema differs.
# ------------------------------------------------------------------------------
_knit_db_check_table() {
    local table_name="$1"
    shift

    local exists
    exists=$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$(_knit_sql_escape "${table_name}")';" )
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
    done < <(_knit_sqlite3 "PRAGMA table_info('$(_knit_sql_escape "${table_name}")');" )

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

# ------------------------------------------------------------------------------
# @fn _knit_db_migrate_table()
#
# Migrate an existing table to a new column schema. Each column specification
# may be "name:type" (for columns that already exist or are being retyped) or
# "name:type=default" (required for columns not present in the current schema,
# so that existing rows can be back-filled with the given default value).
# Columns absent from the new spec are dropped. Column names are normalized
# (hyphens converted to underscores). If the current schema already matches the
# desired schema the function returns 0 without touching the database.
#
# The default value is always treated as a SQL string literal; SQLite's type
# affinity coercion handles integer/real columns correctly.
#
# Example:
# ```
# _knit_db_migrate_table "runs" "id:uuid" "count:integer=0" "label:string"
# ```
#
# @param table_name Name of the table to migrate.
# @param ...specs   One or more "name:type" or "name:type=default" specs.
# @return 0 if the migration was applied or no migration was needed.
# ------------------------------------------------------------------------------
_knit_db_migrate_table() {
    local table_name="$1"
    shift

    if [[ $# -eq 0 ]]; then
        knit_fatal "_knit_db_migrate_table requires at least one column specification."
    fi

    # Check table exists
    local exists
    exists=$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$(_knit_sql_escape "${table_name}")';" )
    if [[ "${exists}" -eq 0 ]]; then
        knit_fatal "Table \"${table_name}\" does not exist in the database."
    fi

    # Parse desired specs
    local desired_names=()
    local desired_knit_types=()
    local desired_sqlite_types=()
    local desired_defaults=()
    local desired_has_default=()
    local spec col_name rest col_type col_default has_def sqlite_type
    for spec in "$@"; do
        if [[ "${spec}" != *:* ]]; then
            knit_fatal "Column specification \"${spec}\" is missing a type (expected \"name:type\" or \"name:type=default\")."
        fi
        col_name="${spec%%:*}"
        rest="${spec#*:}"
        if [[ "${rest}" == *=* ]]; then
            col_type="${rest%%=*}"
            col_default="${rest#*=}"
            has_def="1"
        else
            col_type="${rest}"
            col_default=""
            has_def="0"
        fi
        col_name=$(_knit_str_hyphens_to_underscores "${col_name}")
        sqlite_type=$(__knit_type_to_sqlite "${col_type}") \
            || knit_fatal "Column \"${col_name}\" has unknown type \"${col_type}\"."
        desired_names+=("${col_name}")
        desired_knit_types+=("${col_type}")
        desired_sqlite_types+=("${sqlite_type}")
        desired_defaults+=("${col_default}")
        desired_has_default+=("${has_def}")
    done

    # Get current column names
    local current_names=()
    while IFS='|' read -r _cid col_name _rest; do
        current_names+=("${col_name}")
    done < <(_knit_sqlite3 "PRAGMA table_info('$(_knit_sql_escape "${table_name}")');" )

    # Validate: new columns must have defaults; record which columns are new
    local i is_new cur
    local new_columns=()
    for (( i = 0; i < ${#desired_names[@]}; i++ )); do
        is_new=1
        for cur in "${current_names[@]}"; do
            if [[ "${cur}" == "${desired_names[$i]}" ]]; then
                is_new=0
                break
            fi
        done
        if [[ "${is_new}" -eq 1 && "${desired_has_default[$i]}" == "0" ]]; then
            knit_fatal "New column \"${desired_names[$i]}\" requires a default value (use \"name:type=default\")."
        fi
        new_columns+=("${is_new}")
    done

    # Check if migration is actually needed (use clean name:knit_type specs)
    local clean_specs=()
    for (( i = 0; i < ${#desired_names[@]}; i++ )); do
        clean_specs+=("${desired_names[$i]}:${desired_knit_types[$i]}")
    done
    if _knit_db_check_table "${table_name}" "${clean_specs[@]}"; then
        knit_trace "Table \"${table_name}\" already matches desired schema; no migration needed."
        return 0
    fi

    # Log dropped columns
    local found
    for cur in "${current_names[@]}"; do
        found=0
        for (( i = 0; i < ${#desired_names[@]}; i++ )); do
            if [[ "${desired_names[$i]}" == "${cur}" ]]; then
                found=1; break
            fi
        done
        if [[ "${found}" -eq 0 ]]; then
            knit_trace "Dropping column \"${cur}\" from table \"${table_name}\"."
        fi
    done

    # Build column definitions for CREATE TABLE
    local col_defs=()
    for (( i = 0; i < ${#desired_names[@]}; i++ )); do
        col_defs+=("$(__knit_db_sql_ident "${desired_names[$i]}") ${desired_sqlite_types[$i]}")
    done

    # Build INSERT column list and SELECT expressions
    local insert_cols=()
    local select_exprs=()
    for (( i = 0; i < ${#desired_names[@]}; i++ )); do
        insert_cols+=("$(__knit_db_sql_ident "${desired_names[$i]}")")
        if [[ "${new_columns[$i]}" == "0" ]]; then
            select_exprs+=("$(__knit_db_sql_ident "${desired_names[$i]}")")
        else
            knit_trace "Adding column \"${desired_names[$i]}\" with default \"${desired_defaults[$i]}\" to table \"${table_name}\"."
            select_exprs+=("'$(_knit_sql_escape "${desired_defaults[$i]}")'")
        fi
    done

    local cols_sql insert_cols_sql select_exprs_sql tmp_name
    cols_sql=$(IFS=', '; printf '%s' "${col_defs[*]}")
    insert_cols_sql=$(IFS=', '; printf '%s' "${insert_cols[*]}")
    select_exprs_sql=$(IFS=', '; printf '%s' "${select_exprs[*]}")
    tmp_name="${table_name}__knit_tmp"

    _knit_sqlite3 <<EOF
BEGIN;
ALTER TABLE $(__knit_db_sql_ident "${table_name}") RENAME TO $(__knit_db_sql_ident "${tmp_name}");
CREATE TABLE $(__knit_db_sql_ident "${table_name}") (${cols_sql});
INSERT INTO $(__knit_db_sql_ident "${table_name}") (${insert_cols_sql}) SELECT ${select_exprs_sql} FROM $(__knit_db_sql_ident "${tmp_name}");
DROP TABLE $(__knit_db_sql_ident "${tmp_name}");
COMMIT;
EOF
}

# ------------------------------------------------------------------------------
# @fn _knit_db_setup_table()
#
# Done callback installed by knit_with_table. Inspects the registered
# parameters, flags, and outputs of the command and ensures the database table
# matches that schema — creating it if absent or migrating it if the schema has
# changed.
#
# Column order: "id" (uuid) first, then required parameters, optional
# parameters, flags, and outputs, each group sorted alphabetically.
#
# For migration defaults:
# - Optional parameters use their declared default value.
# - Outputs use their declared default value.
# - Required parameters and flags use a type-based default (0, false, or "").
#
# @param cmd        Mangled command name (as used in _KNIT_CMD_* variables).
# @param table_name Name of the database table to create or migrate.
# ------------------------------------------------------------------------------
_knit_db_setup_table() {
    # Called at knit_done time, which may be before bootstrap has run.
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi

    local cmd="$1"
    local table_name="$2"

    local check_specs=()
    local migrate_specs=()
    local param type_var type default default_var

    # Always-present id column
    check_specs+=("id:uuid")
    migrate_specs+=("id:uuid=")

    # Required parameters (no declared default — use type-based fallback)
    while IFS= read -r param; do
        type_var="_KNIT_CMD_${cmd}_2_${param}_type"
        type="${!type_var}"
        default=$(__knit_db_type_default "${type}")
        check_specs+=("${param}:${type}")
        migrate_specs+=("${param}:${type}=${default}")
    done < <(_knit_set_iter "_KNIT_CMD_${cmd}_required" | sort)

    # Optional parameters (use declared default)
    while IFS= read -r param; do
        type_var="_KNIT_CMD_${cmd}_2_${param}_type"
        type="${!type_var}"
        default_var="_KNIT_CMD_${cmd}_2_${param}_default"
        default="${!default_var}"
        check_specs+=("${param}:${type}")
        migrate_specs+=("${param}:${type}=${default}")
    done < <(_knit_set_iter "_KNIT_CMD_${cmd}_optional" | sort)

    # Flags (always boolean; default is false)
    while IFS= read -r param; do
        check_specs+=("${param}:boolean")
        migrate_specs+=("${param}:boolean=false")
    done < <(_knit_set_iter "_KNIT_CMD_${cmd}_flags" | sort)

    # Outputs (use declared default)
    while IFS= read -r param; do
        type_var="_KNIT_CMD_${cmd}_3_${param}_type"
        type="${!type_var}"
        default_var="_KNIT_CMD_${cmd}_3_${param}_default"
        default="${!default_var}"
        check_specs+=("${param}:${type}")
        migrate_specs+=("${param}:${type}=${default}")
    done < <(_knit_set_iter "_KNIT_CMD_${cmd}_outputs" | sort)

    local check_result=0
    _knit_db_check_table "${table_name}" "${check_specs[@]}" || check_result=$?
    case "${check_result}" in
        0) knit_trace "Table \"${table_name}\" is already up-to-date." ;;
        1) _knit_db_create_table "${table_name}" "${check_specs[@]}" ;;
        2) _knit_db_migrate_table "${table_name}" "${migrate_specs[@]}" ;;
    esac
}
