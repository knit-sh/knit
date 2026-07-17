#!/bin/bash

## @file db_cli.sh

# ------------------------------------------------------------------------------
# Registration of the db command group.
# ------------------------------------------------------------------------------
knit_register knit_empty db "Inspect the experiment database."
_knit_is_builtin
knit_done

# ------------------------------------------------------------------------------
# Query a table in the experiment database.
# ------------------------------------------------------------------------------
knit_register _knit_db_query "db:query" "Run a read-only query against the experiment database."
_knit_is_builtin
knit_with_optional "select:string" "*" "Columns to select (SQL expression list)."
knit_with_optional "from:string" "" "Table to select from (required unless --sql is given)."
knit_with_optional "where:string" "" "Row filter, without the leading WHERE keyword."
knit_with_optional "order-by:string" "" "Ordering, without the leading ORDER BY keyword."
knit_with_optional "limit:integer" "" "Maximum number of rows to return."
knit_with_optional "sql:string" "" "Raw SQL statement to run instead of building one from the other options."
knit_with_flag "header" "Print a header row with the column names."
knit_with_flag "column" "Render the results as aligned columns."
# ------------------------------------------------------------------------------
# @fn _knit_db_query()
#
# Run a read-only query and print its results. By default the statement is built
# from the --select/--from/--where/--order-by/--limit options; --sql overrides
# this with a verbatim statement for cases the builder cannot express (joins,
# aggregates, etc.). The --header and --column flags map to the sqlite3 output
# options of the same name. The query runs through _knit_sqlite3 (no write lock);
# it is the caller's responsibility to keep it read-only.
# ------------------------------------------------------------------------------
_knit_db_query() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi

    local select from where order_by limit sql header column
    select=$(knit_get_parameter "select" "$@")
    from=$(knit_get_parameter "from" "$@")
    where=$(knit_get_parameter "where" "$@")
    order_by=$(knit_get_parameter "order-by" "$@")
    limit=$(knit_get_parameter "limit" "$@")
    sql=$(knit_get_parameter "sql" "$@")
    header=$(knit_get_parameter "header" "$@")
    column=$(knit_get_parameter "column" "$@")

    local -a flags=()
    [[ "${header}" == "true" ]] && flags+=("-header")
    [[ "${column}" == "true" ]] && flags+=("-column")

    local statement
    if [[ -n "${sql}" ]]; then
        statement="${sql}"
    else
        [[ -n "${from}" ]] \
            || knit_fatal "db query requires --from <table> (or --sql <statement>)."
        # Quote --from as a SQL identifier so a nested command's default table
        # name (e.g. "aaa:bbb", which contains a colon) can be passed verbatim,
        # without the user having to add SQL quotes themselves.
        statement="SELECT ${select} FROM $(_knit_sql_quote_identifier "${from}")"
        [[ -n "${where}" ]] && statement="${statement} WHERE ${where}"
        [[ -n "${order_by}" ]] && statement="${statement} ORDER BY ${order_by}"
        [[ -n "${limit}" ]] && statement="${statement} LIMIT ${limit}"
        statement="${statement};"
    fi

    _knit_sqlite3 "${flags[@]}" "${statement}"
}
knit_done

# ------------------------------------------------------------------------------
# List the tables of the experiment database.
# ------------------------------------------------------------------------------
knit_register _knit_db_tables "db:tables" "List the tables in the experiment database."
_knit_is_builtin
# ------------------------------------------------------------------------------
# @fn _knit_db_tables()
#
# Print the names of the user-visible tables in the experiment database, one per
# line, sorted alphabetically. Internal sqlite bookkeeping tables (those whose
# name starts with "sqlite_") are omitted.
# ------------------------------------------------------------------------------
_knit_db_tables() {
    if ! _knit_is_bootstrapped; then
        [[ "${_KNIT_IS_BOOTSTRAPPING}" == "true" ]] && return 0
        knit_fatal "This command requires a bootstrapped experiment. Run: ./${KNIT_SCRIPT_NAME} bootstrap"
    fi
    _knit_sqlite3 \
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
}
knit_done
