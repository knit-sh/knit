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
# @fn _knit_db_sql_ident()
#
# Wrap an SQL identifier (table or column name) in double quotes, escaping any
# embedded double-quote characters by doubling them, per the SQL standard.
#
# Example:
# ```
# local q; _knit_db_sql_ident q "my_table"   # q == "my_table"
# local q; _knit_db_sql_ident q 'a"b'        # q == "a""b"
# ```
#
# @param[out] __knit_ret Name of the variable to hold the quoted identifier.
# @param[in] name Identifier to quote.
# ------------------------------------------------------------------------------
_knit_db_sql_ident() {
    local -n __knit_ret=$1
    printf -v __knit_ret '"%s"' "${2//\"/\"\"}"
}

# ------------------------------------------------------------------------------
# @fn _knit_db_type_default()
#
# Return a sensible default value string for a given Knit type. Used when
# migrating a table to provide a back-fill value for newly added columns that
# do not have a user-supplied default.
#
# Example:
# ```
# local d; _knit_db_type_default d "integer"  # d == 0
# local d; _knit_db_type_default d "boolean"  # d == false
# local d; _knit_db_type_default d "string"   # d == (empty)
# ```
#
# @param[out] __knit_ret Name of the variable to hold the default value.
# @param[in] type Knit type name or alias.
# ------------------------------------------------------------------------------
_knit_db_type_default() {
    local -n __knit_ret=$1
    local type="$2"
    local resolved
    _knit_type_resolve_alias resolved "${type}" || resolved="${type}"
    case "${resolved}" in
        integer) __knit_ret='0' ;;
        real)    __knit_ret='0' ;;
        boolean) __knit_ret='false' ;;
        *)       __knit_ret='' ;;
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
# @param[in] table_name Name of the table to create.
# @param[in] ...specs   One or more "column-name:type" specifications.
# ------------------------------------------------------------------------------
_knit_db_create_table() {
    local table_name="$1"
    shift

    if [[ $# -eq 0 ]]; then
        knit_fatal "_knit_db_create_table requires at least one column specification."
    fi

    local exists esc_table
    _knit_sql_escape esc_table "${table_name}"
    exists=$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='${esc_table}';" )
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
        _knit_str_hyphens_to_underscores col_name "${col_name}"
        local sqlite_type col_ident
        _knit_type_to_sqlite sqlite_type "${col_type}" \
            || knit_fatal "Column \"${col_name}\" has unknown type \"${col_type}\"."
        _knit_db_sql_ident col_ident "${col_name}"
        col_defs+=("${col_ident} ${sqlite_type}")
    done

    local cols_sql table_ident
    cols_sql=$(IFS=', '; printf '%s' "${col_defs[*]}")
    _knit_db_sql_ident table_ident "${table_name}"
    _knit_sqlite3_write "CREATE TABLE ${table_ident} (${cols_sql});"
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
# @param[in] table_name Name of the table to check.
# @param[in] ...specs   One or more "column-name:type" specifications.
# @return 0 if the table matches, 1 if absent, 2 if schema differs.
# ------------------------------------------------------------------------------
_knit_db_check_table() {
    local table_name="$1"
    shift

    local exists esc_table
    _knit_sql_escape esc_table "${table_name}"
    exists=$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='${esc_table}';" )
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
        _knit_str_hyphens_to_underscores col_name "${col_name}"
        local sqlite_type
        _knit_type_to_sqlite sqlite_type "${col_type}" || return 2
        expected_names+=("${col_name}")
        expected_types+=("${sqlite_type}")
    done

    local actual_names=()
    local actual_types=()
    while IFS='|' read -r _cid col_name col_type _rest; do
        actual_names+=("${col_name}")
        actual_types+=("${col_type}")
    done < <(_knit_sqlite3 "PRAGMA table_info('${esc_table}');" )

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
# @param[in] table_name Name of the table to migrate.
# @param[in] ...specs   One or more "name:type" or "name:type=default" specs.
# @return 0 if the migration was applied or no migration was needed.
# ------------------------------------------------------------------------------
_knit_db_migrate_table() {
    local table_name="$1"
    shift

    if [[ $# -eq 0 ]]; then
        knit_fatal "_knit_db_migrate_table requires at least one column specification."
    fi

    # Check table exists
    local exists esc_table
    _knit_sql_escape esc_table "${table_name}"
    exists=$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='${esc_table}';" )
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
        _knit_str_hyphens_to_underscores col_name "${col_name}"
        _knit_type_to_sqlite sqlite_type "${col_type}" \
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
    done < <(_knit_sqlite3 "PRAGMA table_info('${esc_table}');" )

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
    local col_ident
    for (( i = 0; i < ${#desired_names[@]}; i++ )); do
        _knit_db_sql_ident col_ident "${desired_names[$i]}"
        col_defs+=("${col_ident} ${desired_sqlite_types[$i]}")
    done

    # Build INSERT column list and SELECT expressions
    local insert_cols=()
    local select_exprs=()
    local esc_default
    for (( i = 0; i < ${#desired_names[@]}; i++ )); do
        _knit_db_sql_ident col_ident "${desired_names[$i]}"
        insert_cols+=("${col_ident}")
        if [[ "${new_columns[$i]}" == "0" ]]; then
            select_exprs+=("${col_ident}")
        else
            knit_trace "Adding column \"${desired_names[$i]}\" with default \"${desired_defaults[$i]}\" to table \"${table_name}\"."
            _knit_sql_escape esc_default "${desired_defaults[$i]}"
            select_exprs+=("'${esc_default}'")
        fi
    done

    local cols_sql insert_cols_sql select_exprs_sql tmp_name q_table q_tmp
    cols_sql=$(IFS=', '; printf '%s' "${col_defs[*]}")
    insert_cols_sql=$(IFS=', '; printf '%s' "${insert_cols[*]}")
    select_exprs_sql=$(IFS=', '; printf '%s' "${select_exprs[*]}")
    tmp_name="${table_name}_knit_tmp"
    _knit_db_sql_ident q_table "${table_name}"
    _knit_db_sql_ident q_tmp "${tmp_name}"

    _knit_sqlite3_write <<EOF
BEGIN;
ALTER TABLE ${q_table} RENAME TO ${q_tmp};
CREATE TABLE ${q_table} (${cols_sql});
INSERT INTO ${q_table} (${insert_cols_sql}) SELECT ${select_exprs_sql} FROM ${q_tmp};
DROP TABLE ${q_tmp};
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
# @param[in] cmd        Mangled command name (as used in _KNIT_CMD_* variables).
# @param[in] table_name Name of the database table to create or migrate.
# ------------------------------------------------------------------------------
_knit_db_setup_table() {
    # Runs at knit_done time, which may be before bootstrap (e.g. built-in
    # commands are registered while sourcing knit.sh). Defer table creation until
    # the experiment is bootstrapped: it is (re-)ensured lazily on the command's
    # first invocation (see _knit_invoke_command). With no database yet, this is
    # a no-op rather than an error.
    if ! _knit_is_bootstrapped; then
        return 0
    fi

    local cmd="$1"
    local table_name="$2"

    local check_specs=()
    local migrate_specs=()
    local param type_var type default default_var

    # A wrapper declares no parameters or outputs: its table records only the id
    # and the whole forwarded command line in a single "args" column.
    if _knit_command_is_wrapper "${cmd}"; then
        check_specs=("id:uuid" "args:string")
        migrate_specs=("id:uuid=" "args:string=")
        local wrapper_check_result=0
        _knit_db_check_table "${table_name}" "${check_specs[@]}" || wrapper_check_result=$?
        case "${wrapper_check_result}" in
            0) knit_trace "Table \"${table_name}\" is already up-to-date." ;;
            1) _knit_db_create_table "${table_name}" "${check_specs[@]}" ;;
            2) _knit_db_migrate_table "${table_name}" "${migrate_specs[@]}" ;;
        esac
        return 0
    fi

    # Always-present id column
    check_specs+=("id:uuid")
    migrate_specs+=("id:uuid=")

    # Required parameters (no declared default — use type-based fallback)
    while IFS= read -r param; do
        type_var="_KNIT_CMD_${cmd}_2_${param}_type"
        type="${!type_var}"
        _knit_db_type_default default "${type}"
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

    # Outputs (use declared default). An artifact is an output in the set (so
    # describe lists it) but it is recorded in the artifacts table, not as a column
    # here, so it contributes no column to the command's own table. Test the
    # artifacts set only when it exists: _knit_set_find on a missing set would
    # arithmetic-evaluate a subscript that names an in-scope variable (e.g. a
    # column literally called "name"), recursing.
    local has_artifacts=""
    _knit_set_exists "_KNIT_CMD_${cmd}_artifacts" && has_artifacts=1
    while IFS= read -r param; do
        [[ -n "${has_artifacts}" ]] \
            && _knit_set_find "_KNIT_CMD_${cmd}_artifacts" "${param}" && continue
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

# ------------------------------------------------------------------------------
# @fn _knit_db_record_invocation()
#
# Insert one row into a command's table, recording an invocation, and — when a
# provenance edge is requested — the matching edge into the __provenance__ table,
# both in a single transaction. The row is built from the command's declared
# schema: the "id" column (a caller-supplied uuid), then the value of every
# required parameter, optional parameter, and flag (read from the expanded
# invocation arguments), then every output (read from the in-memory
# _KNIT_CMD_<cmd>_output_value store populated by knit_output, falling back to
# the output's declared default). Column names are the normalized (underscored)
# knit names, matching the schema created by _knit_db_setup_table.
#
# The provenance edge, when requested, has the recorded row as its target
# (target_id = id, target_name = the demangled command name). An empty edge_type
# means "record no edge" — the row is inserted on its own, unchanged from before
# provenance existed. A non-empty edge_type (e.g. "call") writes both the row and
# the edge atomically, so a partial state cannot be observed.
#
# @param[in] cmd         Mangled command name (as used in _KNIT_CMD_* variables).
# @param[in] table       Table to insert into.
# @param[in] id          Value for the "id" column (the target's uuid).
# @param[in] source_id   Provenance edge source id (empty for a root); see prov.sh.
# @param[in] source_name Provenance edge source name (empty for a root).
# @param[in] edge_type   Edge type (e.g. "call"), or empty to record no edge.
# @param[in] start_time  Edge start_time (epoch seconds, empty -> NULL).
# @param[in] end_time    Edge end_time (epoch seconds, empty -> NULL).
# @param[in] alias       Edge call-site alias (empty -> NULL); see prov.sh.
# @param[in] ...         The expanded invocation arguments (params/flags to read).
# ------------------------------------------------------------------------------
_knit_db_record_invocation() {
    local cmd="$1"
    local table="$2"
    local id="$3"
    local source_id="$4"
    local source_name="$5"
    local edge_type="$6"
    local start_time="$7"
    local end_time="$8"
    local alias="$9"
    shift 9
    local -a args=("$@")

    local -a cols=() vals=()
    local col_ident val_esc
    _knit_db_sql_ident col_ident "id"
    cols+=("${col_ident}")
    _knit_sql_escape val_esc "${id}"
    vals+=("'${val_esc}'")

    if _knit_command_is_wrapper "${cmd}"; then
        # A wrapper records the whole forwarded command line in a single "args"
        # column (it has no declared parameters or outputs).
        local rendered
        rendered=$(_knit_str_render_cmd args)
        _knit_db_sql_ident col_ident "args"
        cols+=("${col_ident}")
        _knit_sql_escape val_esc "${rendered}"
        vals+=("'${val_esc}'")
    else
        # Parameters and flags: values come from the expanded invocation args.
        local group name value
        for group in required optional flags; do
            while IFS= read -r name; do
                [[ -z "${name}" ]] && continue
                value="$(knit_get_parameter "${name}" "${args[@]}")" || value=""
                _knit_db_sql_ident col_ident "${name}"
                cols+=("${col_ident}")
                _knit_sql_escape val_esc "${value}"
                vals+=("'${val_esc}'")
            done < <(_knit_set_iter "_KNIT_CMD_${cmd}_${group}" | sort)
        done

        # Outputs: values come from the in-memory store, else the declared
        # default.
        # shellcheck disable=SC2178 # nameref to the command's output-value array
        local -n outvals="_KNIT_CMD_${cmd}_output_value"
        # Test the artifacts set only when it exists: _knit_set_find on a missing
        # set would arithmetic-evaluate a subscript that names an in-scope variable
        # (here the loop variable "name"), recursing.
        local has_artifacts=""
        _knit_set_exists "_KNIT_CMD_${cmd}_artifacts" && has_artifacts=1
        while IFS= read -r name; do
            [[ -z "${name}" ]] && continue
            # An artifact output has no column on this table (it is recorded in the
            # artifacts table with a "produced" edge), so it holds no value here.
            [[ -n "${has_artifacts}" ]] \
                && _knit_set_find "_KNIT_CMD_${cmd}_artifacts" "${name}" && continue
            if [[ -v outvals["${name}"] ]]; then
                value="${outvals["${name}"]}"
            else
                _knit_output_default value "${cmd}" "${name}"
            fi
            _knit_db_sql_ident col_ident "${name}"
            cols+=("${col_ident}")
            _knit_sql_escape val_esc "${value}"
            vals+=("'${val_esc}'")
        done < <(_knit_set_iter "_KNIT_CMD_${cmd}_outputs" | sort)
    fi

    local cols_sql vals_sql row_sql table_ident
    cols_sql=$(IFS=', '; printf '%s' "${cols[*]}")
    vals_sql=$(IFS=', '; printf '%s' "${vals[*]}")
    _knit_db_sql_ident table_ident "${table}"
    row_sql="INSERT INTO ${table_ident} (${cols_sql}) VALUES (${vals_sql});"

    # No edge requested: insert the row on its own (pre-provenance behavior). A
    # transparent (out-of-graph) command records no provenance, so it emits no
    # produced-artifact rows or edges either.
    if [[ -z "${edge_type}" ]]; then
        _knit_sqlite3_write "${row_sql}"
        return 0
    fi

    # Edge requested: write the row and its provenance edge atomically, so a
    # reader never sees a row without its edge (or vice versa).
    local target_name edge_sql
    target_name=$(_knit_command_demangle "${cmd}")
    edge_sql=$(_knit_prov_edge_sql \
        "${source_id}" "${source_name}" "${id}" "${target_name}" \
        "${edge_type}" "${start_time}" "${end_time}" "${alias}")

    # A participating command that bound artifacts records each as an artifacts row
    # plus a "produced" edge, in the SAME transaction as this row and its "call"
    # edge. Ensure the artifacts table first, so its INSERTs cannot fail and roll
    # the whole transaction back on a database bootstrapped before artifacts.
    local artifacts_sql
    _knit_artifacts_record_sql artifacts_sql "${cmd}" "${id}" "${target_name}"
    [[ -n "${artifacts_sql}" ]] && _knit_artifacts_ensure_table

    # ".bail on" makes the sqlite3 CLI stop at the first failing statement and
    # roll the open transaction back; without it (the default) a failed edge
    # insert would leave the row committed, defeating atomicity.
    _knit_sqlite3_write <<EOF
.bail on
BEGIN;
${row_sql}
${edge_sql}
${artifacts_sql}COMMIT;
EOF
}

# ------------------------------------------------------------------------------
# @fn _knit_db_update_row()
#
# Update columns of an existing row, identified by its "id". Each assignment is
# a "column=value" string; the column is a knit name (normalized to underscores
# to match the schema). Used to record later state transitions of a recorded
# invocation (e.g. a job moving to "completed").
#
# @param[in] table Table to update.
# @param[in] id    Value of the "id" column identifying the row.
# @param[in] ...   One or more "column=value" assignments.
# ------------------------------------------------------------------------------
_knit_db_update_row() {
    local table="$1"
    local id="$2"
    shift 2

    local -a sets=()
    local pair name value col_ident val_esc
    for pair in "$@"; do
        name="${pair%%=*}"
        value="${pair#*=}"
        name=$(_knit_name_normalize "${name}")
        _knit_db_sql_ident col_ident "${name}"
        _knit_sql_escape val_esc "${value}"
        sets+=("${col_ident}='${val_esc}'")
    done

    local set_sql table_ident id_ident id_esc
    set_sql=$(IFS=', '; printf '%s' "${sets[*]}")
    _knit_db_sql_ident table_ident "${table}"
    _knit_db_sql_ident id_ident "id"
    _knit_sql_escape id_esc "${id}"
    _knit_sqlite3_write \
        "UPDATE ${table_ident} SET ${set_sql} WHERE ${id_ident}='${id_esc}';"
}
