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
