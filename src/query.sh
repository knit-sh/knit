#!/bin/bash

## @file query.sh

# ------------------------------------------------------------------------------
# @fn _knit_query_read_output_opts()
#
# Read the OUTPUT-OPTS shared by `knit query graph` and `knit query sql` out of a
# command invocation into three caller-named variables. Factored here so both
# query engines parse `--format`/`--header`/`--separator` identically; each then
# translates the values into its own backend's flags (knit-graph's `-<mode>` for
# graph, sqlite3 dot-commands for sql). The format defaults to `list` and the
# header defaults OFF (query output is most often piped elsewhere, where a header
# is noise); the separator defaults to empty (the backend's own default).
#
# @param __knit_ret1 Name of the variable to hold the format value.
# @param __knit_ret2 Name of the variable to hold the header flag ("true"/"false").
# @param __knit_ret3 Name of the variable to hold the separator value.
# @param ... The command invocation arguments to read the options from.
# ------------------------------------------------------------------------------
_knit_query_read_output_opts() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    local -n __knit_ret3=$3
    shift 3
    __knit_ret1="$(knit_get_parameter "format" "$@")"    || __knit_ret1="list"
    __knit_ret2="$(knit_get_parameter "header" "$@")"    || __knit_ret2="false"
    __knit_ret3="$(knit_get_parameter "separator" "$@")" || __knit_ret3=""
}

# ------------------------------------------------------------------------------
# @fn _knit_query_table_alias()
#
# Return, through a caller-named variable, the command name a table is registered
# under when it differs from the table name, or the empty string otherwise. A
# command that overrides its table with knit_with_table (e.g. `submit` -> `jobs`,
# `submit:montecarlo` -> `montecarlo`) has a distinct command-name alias; a
# command whose table is its own name (setups, downloads, plain commands) has
# none. Read from the live registration state (_KNIT_DB_REGISTERED_TABLES), so
# it can never go stale.
#
# @param __knit_ret Name of the variable to hold the alias (empty if none).
# @param table The table name to look up.
# ------------------------------------------------------------------------------
_knit_query_table_alias() {
    local -n __knit_ret=$1
    local table="$2"
    __knit_ret=""
    if [[ -v _KNIT_DB_REGISTERED_TABLES["${table}"] ]]; then
        local cmd="${_KNIT_DB_REGISTERED_TABLES["${table}"]}"
        if [[ "${cmd}" != "${table}" ]]; then
            __knit_ret="${cmd}"
        fi
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_query_annotate_catalog()
#
# Filter a knit-graph `--catalog` listing read from standard input, annotating
# each `table <name>` line whose table has a distinct command-name alias with
# " (command: <name>)" so users discover both spellings of a label. Every other
# line (including the `  column <name>` lines and a TABLE.COLUMN validation line)
# is passed through unchanged.
# ------------------------------------------------------------------------------
_knit_query_annotate_catalog() {
    local line table alias
    while IFS= read -r line; do
        if [[ "${line}" == "table "* ]]; then
            table="${line#table }"
            _knit_query_table_alias alias "${table}"
            if [[ -n "${alias}" ]]; then
                printf 'table %s (command: %s)\n' "${table}" "${alias}"
                continue
            fi
        fi
        printf '%s\n' "${line}"
    done
}

# ------------------------------------------------------------------------------
# Registration of the query command group.
#
# `query` commands read the experiment database, so they are NOT usable before
# bootstrap: the central runtime guard refuses them uniformly until the
# experiment is bootstrapped. They are read-only and never recorded (builtins,
# knit_without_provenance, no knit_with_table).
# ------------------------------------------------------------------------------
knit_register knit_empty query \
    "Query the experiment's provenance database (Cypher or SQL)."
_knit_is_builtin
knit_without_provenance
knit_done

# ------------------------------------------------------------------------------
# Registration of 'query catalog'.
# ------------------------------------------------------------------------------
knit_register _knit_query_catalog "query:catalog" \
    "List the database's tables and columns, or validate a reference."
_knit_is_builtin
knit_without_provenance
knit_with_extra "Optional TABLE or TABLE.COLUMN reference to show or validate."
# ------------------------------------------------------------------------------
# @fn _knit_query_catalog()
#
# Body of 'query catalog': forward to knit-graph's `--catalog` mode on the
# experiment database and annotate the listing with command-name aliases. With no
# extra argument it lists every table and its columns; with a TABLE or
# TABLE.COLUMN reference (passed after `--`) it shows that table or validates the
# column, propagating knit-graph's non-zero exit on an unknown reference. Runs on
# the read-only knit-graph binary; the query itself is not recorded.
#
# @param ... A single optional TABLE[.COLUMN] reference after `--`.
# @return The exit status of knit-graph.
# ------------------------------------------------------------------------------
_knit_query_catalog() {
    local args=("$@")
    local extra_index
    extra_index=$(knit_extra_index "${args[@]}")
    local extra=("${args[@]:extra_index}")

    local -a cat_args=(--catalog "${_KNIT_DATABASE}")
    (( ${#extra[@]} > 0 )) && cat_args+=("${extra[0]}")

    local output
    output="$(_knit_knit_graph "${cat_args[@]}")" || return "$?"
    _knit_query_annotate_catalog <<< "${output}"
}
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_query_build_names()
#
# Build the name<->table map knit-graph needs (its `--names` SPEC) from the live
# registration state, returned through a caller-named variable. Every registered
# table contributes one `table=command` entry (the command being the demangled
# name knit stores in the provenance `*_name` columns); knit-graph resolves a
# node label through this map to the table it JOINs and the `*_name` value its
# edges carry (see the design's name<->table section). The map is rebuilt on
# every invocation and never persisted, so it can never go stale. Entries are
# sorted for a stable, traceable SPEC. Empty when no table is registered.
#
# @param __knit_ret Name of the variable to hold the newline-separated SPEC.
# ------------------------------------------------------------------------------
_knit_query_build_names() {
    local -n __knit_ret=$1
    local -a entries=()
    local table
    for table in "${!_KNIT_DB_REGISTERED_TABLES[@]}"; do
        entries+=("${table}=${_KNIT_DB_REGISTERED_TABLES[${table}]}")
    done
    if (( ${#entries[@]} == 0 )); then
        __knit_ret=""
        return 0
    fi
    __knit_ret="$(printf '%s\n' "${entries[@]}" | LC_ALL=C sort)"
}

# ------------------------------------------------------------------------------
# @fn _knit_query_graph_output_flags()
#
# Translate the shared OUTPUT-OPTS (format/header/separator) into the knit-graph
# output flags, filled into a caller-named array. The format value is a
# query_format enum value that maps 1:1 onto knit-graph's `-<mode>` flag, so no
# lookup table is needed. Header is emitted explicitly (`-header`/`-noheader`)
# because knit-graph defaults it on while knit query defaults it off; a non-empty
# separator adds `-separator <sep>`.
#
# @param __knit_ret Name of the array variable to fill with the knit-graph flags.
# @param format The query_format enum value (e.g. "list", "json").
# @param header "true" to emit a header row, anything else to suppress it.
# @param separator Optional column separator.
# ------------------------------------------------------------------------------
_knit_query_graph_output_flags() {
    local -n __knit_ret=$1
    local format="$2"
    local header="$3"
    local separator="$4"

    __knit_ret=("-${format}")
    if [[ "${header}" == "true" ]]; then
        __knit_ret+=(-header)
    else
        __knit_ret+=(-noheader)
    fi
    [[ -n "${separator}" ]] && __knit_ret+=(-separator "${separator}")
    return 0
}

# ------------------------------------------------------------------------------
# Registration of the query_format enum shared by 'query graph' and 'query sql'.
#
# The values are the output modes both backends understand (knit-graph's
# `-<mode>` flags and sqlite3's `.mode` names); `list` is the script-friendly
# default.
# ------------------------------------------------------------------------------
knit_define_enum "query_format" \
    "list" "json" "box" "csv" "markdown" "table" "line" "html" \
    "ascii" "column" "tabs"
_knit_is_builtin

# ------------------------------------------------------------------------------
# Registration of 'query graph'.
# ------------------------------------------------------------------------------
knit_register _knit_query_graph "query:graph" \
    "Run a read-only Cypher query against the provenance database via knit-graph."
_knit_is_builtin
knit_without_provenance
knit_with_required "exec:string" \
    "The Cypher statement to run (passed verbatim to knit-graph)."
knit_with_optional "format:query_format" "list" \
    "Output mode: list, json, box, csv, markdown, table, line, html, ascii, column, tabs."
knit_with_flag "header" \
    "Add a header row (off by default)."
knit_with_optional "separator:string" "" \
    "Column separator (defaults to knit-graph's default)."
knit_with_flag "explain" \
    "Print the generated SQL without running it."
knit_with_flag "ast" \
    "Print the parsed syntax tree (no database needed)."
knit_with_extra "Extra arguments forwarded verbatim to knit-graph after --."
# ------------------------------------------------------------------------------
# @fn _knit_query_graph()
#
# Body of 'query graph': run the --exec Cypher statement through knit-graph,
# augmented with the live name<->table map (so a node label may be written as
# either its table name or its command name) and the resolved output flags. With
# --explain knit-graph prints the generated SQL instead of running it; with --ast
# it prints the parse tree (no database, map, or output flags needed).
# --explain and --ast are mutually exclusive. Anything after a trailing `--` is
# forwarded to knit-graph verbatim. knit-graph's exit status is propagated.
#
# @param ... The command invocation arguments, plus optional knit-graph args
#        after `--`.
# @return The exit status of knit-graph.
# ------------------------------------------------------------------------------
_knit_query_graph() {
    local args=("$@")

    local exec_query explain ast
    exec_query="$(knit_get_parameter "exec" "${args[@]}")"
    explain="$(knit_get_parameter "explain" "${args[@]}")" || explain="false"
    ast="$(knit_get_parameter "ast" "${args[@]}")"         || ast="false"

    if [[ "${explain}" == "true" && "${ast}" == "true" ]]; then
        knit_fatal "knit query graph: --explain and --ast are mutually exclusive."
    fi

    local extra_index
    extra_index=$(knit_extra_index "${args[@]}")
    local extra=("${args[@]:extra_index}")

    # --ast needs neither the database nor the name map nor output flags.
    if [[ "${ast}" == "true" ]]; then
        _knit_knit_graph --ast "${exec_query}" "${extra[@]}"
        return "$?"
    fi

    local fmt hdr sep
    _knit_query_read_output_opts fmt hdr sep "${args[@]}"

    local names_spec
    _knit_query_build_names names_spec

    local -a out_flags=()
    _knit_query_graph_output_flags out_flags "${fmt}" "${hdr}" "${sep}"

    local -a kg_args=()
    [[ "${explain}" == "true" ]] && kg_args+=(--explain)
    [[ -n "${names_spec}" ]] && kg_args+=(--names "${names_spec}")
    kg_args+=("${out_flags[@]}")
    kg_args+=("${_KNIT_DATABASE}" "${exec_query}")
    kg_args+=("${extra[@]}")

    _knit_knit_graph "${kg_args[@]}"
}
knit_done

# ------------------------------------------------------------------------------
# Registration of 'query sql'.
# ------------------------------------------------------------------------------
knit_register _knit_query_sql "query:sql" \
    "Run a read-only SQL query against the provenance database."
_knit_is_builtin
knit_without_provenance
knit_with_required "exec:string" \
    "The SQL statement to run (must be read-only)."
knit_with_optional "format:query_format" "list" \
    "Output mode: list, json, box, csv, markdown, table, line, html, ascii, column, tabs."
knit_with_flag "header" \
    "Add a header row (off by default)."
knit_with_optional "separator:string" "" \
    "Column separator (defaults to sqlite3's default)."
# ------------------------------------------------------------------------------
# @fn _knit_query_sql()
#
# Body of 'query sql': run the --exec SQL statement on knit's own read path
# (_knit_sqlite3) with the shared output options shaping the result. The
# statement is rejected unless it is read-only (leading SELECT/WITH/EXPLAIN/PRAGMA
# and no write keyword, via the shared guard) so a query can never mutate the
# provenance database. Output opts are read with the shared reader and translated
# to sqlite3 `.mode`/`.headers`/`.separator` dot-commands by the same helper
# `ai query` uses, so SQL and Cypher results present identically. sqlite3's exit
# status is propagated.
#
# @param ... The command invocation arguments.
# @return The exit status of sqlite3, or fatal on a non-read-only statement.
# ------------------------------------------------------------------------------
_knit_query_sql() {
    local args=("$@")

    local exec_sql
    exec_sql="$(knit_get_parameter "exec" "${args[@]}")"

    if ! _knit_ai_sql_is_readonly "${exec_sql}"; then
        knit_fatal "knit query sql: only read-only statements are allowed (leading SELECT/WITH/EXPLAIN/PRAGMA, no write keywords)."
    fi

    local fmt hdr sep
    _knit_query_read_output_opts fmt hdr sep "${args[@]}"

    local no_header="true"
    [[ "${hdr}" == "true" ]] && no_header="false"

    local -a mode_args=()
    _knit_ai_query_mode_args mode_args "${fmt}" "${no_header}" "${sep}"

    _knit_sqlite3 "${mode_args[@]}" "${exec_sql}"
}
knit_done
