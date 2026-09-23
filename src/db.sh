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
# Check whether a table exists and already carries every declared column.
# Returns 0 if the table exists and every desired column is present, 1 if the
# table does not exist, or 2 if the table exists but is missing one or more of
# the desired columns.
#
# The match is a superset test: columns present in the table but absent from the
# desired specification (e.g. a parameter later removed from the command) are
# ignored, and so are column order and column type. Migration is additive only
# (see _knit_db_migrate_table), so a present column of any type is treated as
# satisfying the specification and never triggers a change.
#
# Example:
# ```
# _knit_db_check_table "runs" "id:uuid" "duration:real"
# # returns 0, 1, or 2
# ```
#
# @param[in] table_name Name of the table to check.
# @param[in] ...specs   One or more "column-name:type" specifications.
# @return 0 if every desired column is present, 1 if absent, 2 if any is missing.
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

    local desired_names=()
    local spec col_name
    for spec in "$@"; do
        if [[ "${spec}" != *:* ]]; then
            knit_fatal "Column specification \"${spec}\" is missing a type (expected \"name:type\")."
        fi
        col_name="${spec%%:*}"
        _knit_str_hyphens_to_underscores col_name "${col_name}"
        desired_names+=("${col_name}")
    done

    local -A actual=()
    local name
    while IFS='|' read -r _cid name _rest; do
        actual["${name}"]=1
    done < <(_knit_sqlite3 "PRAGMA table_info('${esc_table}');" )

    for name in "${desired_names[@]}"; do
        if [[ -z "${actual[$name]:-}" ]]; then
            return 2
        fi
    done

    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_db_migrate_table()
#
# Migrate an existing table so it carries every declared column. Migration is
# additive only: each desired "name:type" column that the table does not already
# have is appended with "ALTER TABLE ... ADD COLUMN". A column already present is
# left untouched (its type is never changed), and a column present in the table
# but absent from the specification (e.g. a parameter later removed from the
# command) is kept, preserving the values recorded for it. Column names are
# normalized (hyphens converted to underscores).
#
# A newly added column carries no SQL default: existing rows read NULL for it
# (the run predates the column) and a future row that does not record the column
# is NULL too, rather than a stale copy of some default value. Dropping a column
# is never automatic; that is an explicit, separate operation.
#
# Example:
# ```
# _knit_db_migrate_table "runs" "id:uuid" "count:integer" "label:string"
# ```
#
# @param[in] table_name Name of the table to migrate.
# @param[in] ...specs   One or more "name:type" specifications.
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

    # Column names already present in the table.
    local -A present=()
    local name
    while IFS='|' read -r _cid name _rest; do
        present["${name}"]=1
    done < <(_knit_sqlite3 "PRAGMA table_info('${esc_table}');" )

    # Append each declared column that is missing. New columns land at the end of
    # the table, so physical column order reflects when columns were added, not
    # the declared order.
    local q_table col_ident
    _knit_db_sql_ident q_table "${table_name}"
    local spec col_name col_type sqlite_type
    local stmts=()
    for spec in "$@"; do
        if [[ "${spec}" != *:* ]]; then
            knit_fatal "Column specification \"${spec}\" is missing a type (expected \"name:type\")."
        fi
        col_name="${spec%%:*}"
        col_type="${spec#*:}"
        _knit_str_hyphens_to_underscores col_name "${col_name}"
        [[ -n "${present[${col_name}]:-}" ]] && continue
        _knit_type_to_sqlite sqlite_type "${col_type}" \
            || knit_fatal "Column \"${col_name}\" has unknown type \"${col_type}\"."
        _knit_db_sql_ident col_ident "${col_name}"
        knit_trace "Adding column \"${col_name}\" to table \"${table_name}\"."
        stmts+=("ALTER TABLE ${q_table} ADD COLUMN ${col_ident} ${sqlite_type};")
    done

    if [[ "${#stmts[@]}" -eq 0 ]]; then
        knit_trace "Table \"${table_name}\" already carries every declared column; no migration needed."
        return 0
    fi

    local body
    body=$(printf '%s\n' "${stmts[@]}")
    _knit_sqlite3_write <<EOF
BEGIN;
${body}COMMIT;
EOF
}

# ------------------------------------------------------------------------------
# @fn _knit_db_command_has_exit_status()
#
# Decide whether a command's table carries the reserved "__exit_status__" column.
# A command has it unless it opted out of recording a failed invocation
# (knit_no_record_on_failure — it records only successes, so the status would
# always be 0) or its status is tracked another way (_knit_without_exit_status,
# e.g. the submissions "jobs" table's "state"). This is the single predicate used
# by both the schema builder (_knit_db_setup_table) and the row recorder
# (_knit_db_record_invocation) so the column set and the recorded columns cannot
# diverge.
#
# @param[in] cmd Mangled command name.
# @return 0 if the table has the column, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_db_command_has_exit_status() {
    local cmd="$1"
    local no_fail_var="_KNIT_CMD_${cmd}_no_record_on_failure"
    local no_exit_var="_KNIT_CMD_${cmd}_no_exit_status"
    [[ "${!no_fail_var:-}" != "true" && "${!no_exit_var:-}" != "true" ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_db_setup_table()
#
# Done callback installed by knit_with_table. Inspects the registered
# parameters, flags, and outputs of the command and ensures the database table
# carries a column for each — creating the table if absent or adding any missing
# columns if the schema has grown.
#
# Column order at creation: "id" (uuid) first, the reserved "__exit_status__"
# column (unless the command opted out, see _knit_db_command_has_exit_status),
# then required parameters, optional parameters, flags, and outputs, each group
# sorted alphabetically. Migration is additive only (see _knit_db_migrate_table):
# a later-added column lands at the end of the table, and a column for a parameter
# that was removed from the command is kept, so physical column order need not
# match this declared order over the life of a table.
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

    local specs=()
    local param type_var type

    # Reserved "__exit_status__" column, recorded right after "id" for a command
    # whose table has it (see _knit_db_command_has_exit_status).
    local include_exit_status=0
    _knit_db_command_has_exit_status "${cmd}" && include_exit_status=1

    # A wrapper declares no parameters or outputs: its table records only the id,
    # the exit status, and the whole forwarded command line in a single "args"
    # column.
    if _knit_command_is_wrapper "${cmd}"; then
        specs=("id:uuid")
        if [[ "${include_exit_status}" -eq 1 ]]; then
            specs+=("__exit_status__:integer")
        fi
        specs+=("args:string")
        _knit_db_ensure_table "${table_name}" "${specs[@]}"
        return 0
    fi

    # Always-present id column
    specs+=("id:uuid")

    # Reserved exit-status column (see the note above), right after "id".
    if [[ "${include_exit_status}" -eq 1 ]]; then
        specs+=("__exit_status__:integer")
    fi

    # Required parameters
    while IFS= read -r param; do
        type_var="_KNIT_CMD_${cmd}_2_${param}_type"
        type="${!type_var}"
        specs+=("${param}:${type}")
    done < <(_knit_set_iter "_KNIT_CMD_${cmd}_required" | sort)

    # Optional parameters
    while IFS= read -r param; do
        type_var="_KNIT_CMD_${cmd}_2_${param}_type"
        type="${!type_var}"
        specs+=("${param}:${type}")
    done < <(_knit_set_iter "_KNIT_CMD_${cmd}_optional" | sort)

    # Flags (always boolean)
    while IFS= read -r param; do
        specs+=("${param}:boolean")
    done < <(_knit_set_iter "_KNIT_CMD_${cmd}_flags" | sort)

    # Outputs. An artifact is not an output column: it is recorded in the
    # artifacts table with a "produced" edge and is kept out of the outputs set
    # (in the artifacts set instead), so this loop never sees one.
    while IFS= read -r param; do
        type_var="_KNIT_CMD_${cmd}_3_${param}_type"
        type="${!type_var}"
        specs+=("${param}:${type}")
    done < <(_knit_set_iter "_KNIT_CMD_${cmd}_outputs" | sort)

    _knit_db_ensure_table "${table_name}" "${specs[@]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_db_ensure_table()
#
# Ensure a table exists and carries every column in the given "name:type"
# specification: create it if absent, add any missing columns if present, or do
# nothing if it is already a superset of the specification. This is the shared
# create-or-migrate step used by _knit_db_setup_table for both wrapper and
# ordinary command tables.
#
# @param[in] table_name Name of the table to ensure.
# @param[in] ...specs   One or more "name:type" specifications.
# ------------------------------------------------------------------------------
_knit_db_ensure_table() {
    local table_name="$1"
    shift
    local check_result=0
    _knit_db_check_table "${table_name}" "$@" || check_result=$?
    case "${check_result}" in
        0) knit_trace "Table \"${table_name}\" is already up-to-date." ;;
        1) _knit_db_create_table "${table_name}" "$@" ;;
        2) _knit_db_migrate_table "${table_name}" "$@" ;;
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
# @param[in] exit_status Body exit status for the reserved "__exit_status__"
#                        column; empty leaves it NULL (the outcome is not yet
#                        known, e.g. the eager record path). Ignored for a
#                        command whose table has no such column.
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
    local exit_status="${10}"
    shift 10
    local -a args=("$@")

    local -a cols=() vals=()
    local col_ident val_esc
    _knit_db_sql_ident col_ident "id"
    cols+=("${col_ident}")
    _knit_sql_escape val_esc "${id}"
    vals+=("'${val_esc}'")

    # Reserved "__exit_status__" column, right after "id", for a command whose
    # table has it and when a status is known. A known status includes 0
    # (success), so test for a non-empty value, not truthiness. When the value is
    # empty (the eager record path, before the outcome is known) the column is
    # omitted from the INSERT and stays NULL, to be filled in later.
    if [[ -n "${exit_status}" ]] && _knit_db_command_has_exit_status "${cmd}"; then
        _knit_db_sql_ident col_ident "__exit_status__"
        cols+=("${col_ident}")
        _knit_sql_escape val_esc "${exit_status}"
        vals+=("'${val_esc}'")
    fi

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
        # default. An artifact is not an output column (it is recorded in the
        # artifacts table with a "produced" edge and kept out of the outputs set),
        # so this loop never sees one.
        # shellcheck disable=SC2178 # nameref to the command's output-value array
        local -n outvals="_KNIT_CMD_${cmd}_output_value"
        while IFS= read -r name; do
            [[ -z "${name}" ]] && continue
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
        _knit_name_normalize name "${name}"
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
