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
# directed relationship, "source --edge_type--> target", of one of three kinds:
# a "call" edge (source invoked target), a "used_by" edge (target references a
# setup or resource, which is the source, built by an earlier invocation), or a
# "produced" edge (source invocation produced target, an artifacts-table row).
# The source is always the antecedent (the caller, the setup, the producer) and
# the target the dependent (the callee, the consumer, the artifact). Node identity
# is the pair (id, name); the timestamps are REAL epoch seconds and are NULL for
# "used_by" and "produced" edges. The nullable "alias" column holds the call-site
# name recorded by knit_as (NULL for a plain edge). Called at bootstrap alongside
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
    end_time     REAL,
    alias        TEXT
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
# @fn _knit_prov_nullable_literal()
#
# Render an argument as a SQL literal for a nullable column: an empty argument
# becomes a bare NULL; a non-empty argument becomes a single-quoted, escaped
# literal. Used for the two REAL timestamp columns (empty for "used_by" edges,
# which have no duration; SQLite's type affinity coerces the quoted number to a
# REAL) and for the TEXT "alias" column (empty for a plain, unaliased edge).
#
# @param[in] value Column value, or empty for NULL.
# ------------------------------------------------------------------------------
_knit_prov_nullable_literal() {
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
# @param[in] source_id   UUID of the source (caller for "call"; setup for "used_by");
#                    empty for a root invocation.
# @param[in] source_name Demangled command name of the source (empty for a root).
# @param[in] target_id   UUID of the target (callee for "call"; consumer for
#                    "used_by").
# @param[in] target_name Demangled command name of the target.
# @param[in] edge_type   "call" (source invoked target), "used_by" (target
#                    references a setup/resource, which is the source), or
#                    "produced" (source produced target, an artifact).
# @param[in] start_time  Epoch seconds when the call started (empty -> NULL).
# @param[in] end_time    Epoch seconds when the call returned (empty -> NULL).
# @param[in] alias       Call-site name from knit_as (empty -> NULL).
# ------------------------------------------------------------------------------
_knit_prov_edge_sql() {
    local source_id="$1"
    local source_name="$2"
    local target_id="$3"
    local target_name="$4"
    local edge_type="$5"
    local start_time="$6"
    local end_time="$7"
    local alias="$8"

    local tbl esc_sid esc_sname esc_tid esc_tname esc_etype
    _knit_db_sql_ident tbl "${_KNIT_PROV_TABLE}"
    _knit_sql_escape esc_sid "${source_id}"
    _knit_sql_escape esc_sname "${source_name}"
    _knit_sql_escape esc_tid "${target_id}"
    _knit_sql_escape esc_tname "${target_name}"
    _knit_sql_escape esc_etype "${edge_type}"

    printf 'INSERT INTO %s (source_id, source_name, target_id, target_name, edge_type, start_time, end_time, alias) VALUES (%s, %s, %s, %s, %s, %s, %s, %s);' \
        "${tbl}" \
        "'${esc_sid}'" \
        "'${esc_sname}'" \
        "'${esc_tid}'" \
        "'${esc_tname}'" \
        "'${esc_etype}'" \
        "$(_knit_prov_nullable_literal "${start_time}")" \
        "$(_knit_prov_nullable_literal "${end_time}")" \
        "$(_knit_prov_nullable_literal "${alias}")"
}

# ------------------------------------------------------------------------------
# @fn _knit_produced_edge_sql()
#
# Build (print, without executing) the INSERT for a "produced" provenance edge:
# a producing invocation (the source) produced an artifact (the target, a row of
# the artifacts table). It is a thin wrapper over _knit_prov_edge_sql that bakes
# in the produced-edge shape: the target_name is the artifacts node label, the
# edge_type is "produced", and — a produced edge has no duration and no call site
# — the two timestamps and the alias are NULL. Meant to be composed into the
# producing invocation's record-time transaction (see the artifacts write path).
#
# @param[in] source_id   UUID of the producing invocation (empty for a root).
# @param[in] source_name Demangled command name of the producer.
# @param[in] artifact_id UUID of the produced artifact (the artifacts row id).
# ------------------------------------------------------------------------------
_knit_produced_edge_sql() {
    local source_id="$1"
    local source_name="$2"
    local artifact_id="$3"
    _knit_prov_edge_sql "${source_id}" "${source_name}" \
        "${artifact_id}" "${_KNIT_ARTIFACTS_TABLE}" "produced" "" "" ""
}

# ------------------------------------------------------------------------------
# @fn _knit_prov_record_edge()
#
# Insert a single provenance edge into the edge table, serialized through the
# advisory-locked writer. Used on its own for a target that records no data row
# (a table-less command) and for "used_by" edges; a target that also records a
# data row writes both in one transaction via _knit_db_record_invocation instead.
#
# @param[in] source_id   See _knit_prov_edge_sql.
# @param[in] source_name See _knit_prov_edge_sql.
# @param[in] target_id   See _knit_prov_edge_sql.
# @param[in] target_name See _knit_prov_edge_sql.
# @param[in] edge_type   See _knit_prov_edge_sql.
# @param[in] start_time  See _knit_prov_edge_sql.
# @param[in] end_time    See _knit_prov_edge_sql.
# ------------------------------------------------------------------------------
_knit_prov_record_edge() {
    _knit_sqlite3_write "$(_knit_prov_edge_sql "$@")"
}

# ------------------------------------------------------------------------------
# @fn _knit_record_used_by_edge()
#
# Record a "used_by" provenance edge from an already-resolved source node (a
# setup or a resource instance) to a consuming invocation (the target). A
# "used_by" edge has no duration, so both timestamps are NULL. Shared by the
# setup-dependency after-callback (setup:<type> source) and the resource-
# dependency after-callback (resource:<type> source); each caller reads its own
# on-disk id/type markers and passes the resolved node identity here.
#
# Best-effort and gated with the other provenance writes: it records nothing when
# recording is disabled, on a suppressed rank, before bootstrap, when the target
# does not participate in the graph, or when the source id is empty (e.g. a setup
# or resource materialized before provenance shipped).
#
# @param[in] source_id   Resolved row id of the source node (empty -> no edge).
# @param[in] source_name Node name of the source ("setup:<type>" / "resource:<type>").
# @param[in] target_cmd  Mangled command name of the consumer (the edge target).
# @param[in] target_id   Resolved row id of the consumer (the edge target).
# ------------------------------------------------------------------------------
_knit_record_used_by_edge() {
    local source_id="$1"
    local source_name="$2"
    local target_cmd="$3"
    local target_id="$4"
    [[ "${KNIT_DISABLE_RECORDING:-}" == "true" ]] && return 0
    [[ -n "${_KNIT_RECORDING_SUPPRESSED}" ]] && return 0
    _knit_is_bootstrapped || return 0
    _knit_provenance_enabled "${target_cmd}" || return 0
    [[ -z "${source_id}" ]] && return 0
    _knit_prov_ensure_table
    _knit_prov_record_edge "${source_id}" "${source_name}" \
        "${target_id}" "$(_knit_command_demangle "${target_cmd}")" "used_by" "" ""
}
