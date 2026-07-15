#!/bin/bash

## @file prov.sh

# ------------------------------------------------------------------------------
# @var _KNIT_PROV_TABLE
#
# Name of the framework-owned edge table that records the relationships between
# invocations (the provenance graph). The "__" prefix/suffix marks it as
# reserved (not a user-provided command table), like other reserved names.
# ------------------------------------------------------------------------------
declare -g _KNIT_PROV_TABLE
_KNIT_PROV_TABLE="__provenance__"

# ------------------------------------------------------------------------------
# @var _KNIT_PROV_TABLE_ENSURED
#
# Set to "1" once the provenance table has been ensured in this process (see
# _knit_prov_ensure_table), so the idempotent CREATE runs at most once per run.
# ------------------------------------------------------------------------------
declare -g _KNIT_PROV_TABLE_ENSURED
_KNIT_PROV_TABLE_ENSURED=""

# ------------------------------------------------------------------------------
# @fn _knit_prov_now()
#
# Print the current time as a REAL number of seconds since the Unix epoch, at the
# best precision available. Used for a call edge's start_time (captured when the
# frame is pushed) and end_time (captured at record time), so a duration is a
# plain subtraction.
# ------------------------------------------------------------------------------
_knit_prov_now() {
    date +%s.%N
}

# ------------------------------------------------------------------------------
# @fn _knit_prov_create_table()
#
# Create the provenance edge table if it does not already exist. Each row is one
# relationship between two invocations: a "call" edge (parent invoked child) or a
# "uses" edge (child references a setup built by an earlier invocation). Node
# identity is the pair (id, name); the timestamps are REAL epoch seconds and are
# NULL for "uses" edges. Called at bootstrap alongside the metadata table.
# ------------------------------------------------------------------------------
_knit_prov_create_table() {
    _knit_sqlite3_write <<EOF
CREATE TABLE IF NOT EXISTS $(_knit_db_sql_ident "${_KNIT_PROV_TABLE}") (
    parent_id    TEXT,
    parent_name  TEXT,
    child_id     TEXT,
    child_name   TEXT,
    edge_type    TEXT,
    start_time   REAL,
    end_time     REAL
);
EOF
}

# ------------------------------------------------------------------------------
# @fn _knit_prov_ensure_table()
#
# Ensure the provenance edge table exists before an edge is written, creating it
# lazily on first use. A freshly bootstrapped experiment already has the table
# (created at bootstrap), but a database bootstrapped before this feature shipped
# does not; ensuring it here lets a new invocation record edges (and keeps its
# data-row-plus-edge transaction from rolling back) rather than failing. The
# create is idempotent and runs at most once per process, guarded by
# _KNIT_PROV_TABLE_ENSURED.
# ------------------------------------------------------------------------------
_knit_prov_ensure_table() {
    [[ -n "${_KNIT_PROV_TABLE_ENSURED}" ]] && return 0
    _knit_prov_create_table
    _KNIT_PROV_TABLE_ENSURED="1"
}

# ------------------------------------------------------------------------------
# @fn _knit_prov_timestamp_literal()
#
# Render a timestamp argument as a SQL literal for a REAL column: an empty
# argument becomes NULL (used for "uses" edges, which have no duration); a
# non-empty argument becomes a single-quoted, escaped literal, which SQLite's
# type affinity coerces to a REAL.
#
# @param value Timestamp value (epoch seconds) or empty for NULL.
# ------------------------------------------------------------------------------
_knit_prov_timestamp_literal() {
    local value="$1"
    if [[ -z "${value}" ]]; then
        printf 'NULL'
    else
        printf "'%s'" "$(_knit_sql_escape "${value}")"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_prov_edge_sql()
#
# Build (print, without executing) the INSERT statement for one provenance edge.
# The statement is meant to be run through _knit_sqlite3_write, either on its own
# (see _knit_prov_record_edge) or inside a transaction next to a data-row insert
# (see _knit_db_record_invocation). Timestamps are rendered as NULL when empty.
#
# @param parent_id   UUID of the parent (caller for "call"; setup for "uses");
#                    empty for a root invocation.
# @param parent_name Demangled command name of the parent (empty for a root).
# @param child_id    UUID of the child (callee for "call"; consumer for "uses").
# @param child_name  Demangled command name of the child.
# @param edge_type   "call" (parent invoked child) or "uses" (child references a
#                    setup).
# @param start_time  Epoch seconds when the call started (empty -> NULL).
# @param end_time    Epoch seconds when the call returned (empty -> NULL).
# ------------------------------------------------------------------------------
_knit_prov_edge_sql() {
    local parent_id="$1"
    local parent_name="$2"
    local child_id="$3"
    local child_name="$4"
    local edge_type="$5"
    local start_time="$6"
    local end_time="$7"

    printf 'INSERT INTO %s (parent_id, parent_name, child_id, child_name, edge_type, start_time, end_time) VALUES (%s, %s, %s, %s, %s, %s, %s);' \
        "$(_knit_db_sql_ident "${_KNIT_PROV_TABLE}")" \
        "'$(_knit_sql_escape "${parent_id}")'" \
        "'$(_knit_sql_escape "${parent_name}")'" \
        "'$(_knit_sql_escape "${child_id}")'" \
        "'$(_knit_sql_escape "${child_name}")'" \
        "'$(_knit_sql_escape "${edge_type}")'" \
        "$(_knit_prov_timestamp_literal "${start_time}")" \
        "$(_knit_prov_timestamp_literal "${end_time}")"
}

# ------------------------------------------------------------------------------
# @fn _knit_prov_record_edge()
#
# Insert a single provenance edge into the edge table, serialized through the
# advisory-locked writer. Used on its own for a child that records no data row
# (a table-less command) and for "uses" edges; a child that also records a data
# row writes both in one transaction via _knit_db_record_invocation instead.
#
# @param parent_id   See _knit_prov_edge_sql.
# @param parent_name See _knit_prov_edge_sql.
# @param child_id    See _knit_prov_edge_sql.
# @param child_name  See _knit_prov_edge_sql.
# @param edge_type   See _knit_prov_edge_sql.
# @param start_time  See _knit_prov_edge_sql.
# @param end_time    See _knit_prov_edge_sql.
# ------------------------------------------------------------------------------
_knit_prov_record_edge() {
    _knit_sqlite3_write "$(_knit_prov_edge_sql "$@")"
}
