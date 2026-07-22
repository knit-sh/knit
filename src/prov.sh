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
# directed relationship between two invocations, "source --edge_type--> target":
# a "call" edge (source invoked target) or a "uses" edge (target references a
# setup, which is the source, built by an earlier invocation). The source is
# always the antecedent (the caller, the setup) and the target the dependent (the
# callee, the consumer). Node identity is the pair (id, name); the timestamps are
# REAL epoch seconds and are NULL for "uses" edges. Called at bootstrap alongside
# the metadata table.
# ------------------------------------------------------------------------------
_knit_prov_create_table() {
    local prov_ident
    _knit_db_sql_ident prov_ident "${_KNIT_PROV_TABLE}"
    _knit_sqlite3_write <<EOF
CREATE TABLE IF NOT EXISTS ${prov_ident} (
    source_id    TEXT,
    source_name  TEXT,
    target_id    TEXT,
    target_name  TEXT,
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
        local esc
        _knit_sql_escape esc "${value}"
        printf "'%s'" "${esc}"
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
# @param source_id   UUID of the source (caller for "call"; setup for "uses");
#                    empty for a root invocation.
# @param source_name Demangled command name of the source (empty for a root).
# @param target_id   UUID of the target (callee for "call"; consumer for "uses").
# @param target_name Demangled command name of the target.
# @param edge_type   "call" (source invoked target) or "uses" (target references
#                    a setup, which is the source).
# @param start_time  Epoch seconds when the call started (empty -> NULL).
# @param end_time    Epoch seconds when the call returned (empty -> NULL).
# ------------------------------------------------------------------------------
_knit_prov_edge_sql() {
    local source_id="$1"
    local source_name="$2"
    local target_id="$3"
    local target_name="$4"
    local edge_type="$5"
    local start_time="$6"
    local end_time="$7"

    local tbl esc_sid esc_sname esc_tid esc_tname esc_etype
    _knit_db_sql_ident tbl "${_KNIT_PROV_TABLE}"
    _knit_sql_escape esc_sid "${source_id}"
    _knit_sql_escape esc_sname "${source_name}"
    _knit_sql_escape esc_tid "${target_id}"
    _knit_sql_escape esc_tname "${target_name}"
    _knit_sql_escape esc_etype "${edge_type}"

    printf 'INSERT INTO %s (source_id, source_name, target_id, target_name, edge_type, start_time, end_time) VALUES (%s, %s, %s, %s, %s, %s, %s);' \
        "${tbl}" \
        "'${esc_sid}'" \
        "'${esc_sname}'" \
        "'${esc_tid}'" \
        "'${esc_tname}'" \
        "'${esc_etype}'" \
        "$(_knit_prov_timestamp_literal "${start_time}")" \
        "$(_knit_prov_timestamp_literal "${end_time}")"
}

# ------------------------------------------------------------------------------
# @fn _knit_prov_record_edge()
#
# Insert a single provenance edge into the edge table, serialized through the
# advisory-locked writer. Used on its own for a target that records no data row
# (a table-less command) and for "uses" edges; a target that also records a data
# row writes both in one transaction via _knit_db_record_invocation instead.
#
# @param source_id   See _knit_prov_edge_sql.
# @param source_name See _knit_prov_edge_sql.
# @param target_id   See _knit_prov_edge_sql.
# @param target_name See _knit_prov_edge_sql.
# @param edge_type   See _knit_prov_edge_sql.
# @param start_time  See _knit_prov_edge_sql.
# @param end_time    See _knit_prov_edge_sql.
# ------------------------------------------------------------------------------
_knit_prov_record_edge() {
    _knit_sqlite3_write "$(_knit_prov_edge_sql "$@")"
}
