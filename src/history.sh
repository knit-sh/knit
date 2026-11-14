#!/bin/bash

## @file history.sh

# ------------------------------------------------------------------------------
# @var _KNIT_HISTORY_TABLE
#
# Name of the framework-owned table that records the top-level commands the user
# invoked (the root invocations), time-ordered by their UUIDv7 ids, for replay
# and audit. The "__" prefix/suffix marks it as reserved (not a user-provided
# command table), like other reserved names.
# ------------------------------------------------------------------------------
declare -g _KNIT_HISTORY_TABLE
_KNIT_HISTORY_TABLE="__history__"

# ------------------------------------------------------------------------------
# @var _KNIT_HISTORY_TABLE_ENSURED
#
# Set to "1" once the history table has been ensured in this process (see
# _knit_history_ensure_table), so the idempotent CREATE runs at most once per run.
# ------------------------------------------------------------------------------
declare -g _KNIT_HISTORY_TABLE_ENSURED
_KNIT_HISTORY_TABLE_ENSURED=""

# ------------------------------------------------------------------------------
# @fn _knit_history_create_table()
#
# Create the history table if it does not already exist. Each row is one
# top-level user invocation (a root command, with no provenance source): a stable
# "id" (the invocation's uuidv7, whose embedded timestamp orders rows in time),
# the demangled "command" name in colon notation ("submit", "submit:drain",
# "metadata:store"), the command line in two forms -- "invoked" (the raw tokens
# the user typed) and "resolved" (the same after optional defaults, flags, and
# "ENV[...]" defaults are expanded) -- each a JSON array of tokens, the
# "start_time"/"end_time" as REAL epoch seconds, and the body's "exit_status"
# (NULL when unknown, e.g. a command that opts out of exit tracking). Called at
# bootstrap alongside the metadata and __provenance__ tables.
# ------------------------------------------------------------------------------
_knit_history_create_table() {
    local history_ident
    _knit_db_sql_ident history_ident "${_KNIT_HISTORY_TABLE}"
    _knit_sqlite3_write <<EOF
CREATE TABLE IF NOT EXISTS ${history_ident} (
    id           TEXT,
    command      TEXT,
    invoked      TEXT,
    resolved     TEXT,
    start_time   REAL,
    end_time     REAL,
    exit_status  INTEGER
);
EOF
}

# ------------------------------------------------------------------------------
# @fn _knit_history_ensure_table()
#
# Ensure the history table exists before a history row is written, creating it
# lazily on first use. A freshly bootstrapped experiment already has the table
# (created at bootstrap); a database bootstrapped before this feature shipped does
# not, so ensuring it here lets a new invocation record history rather than
# failing. The create is idempotent and runs at most once per process, guarded by
# _KNIT_HISTORY_TABLE_ENSURED. Mirrors _knit_prov_ensure_table.
# ------------------------------------------------------------------------------
_knit_history_ensure_table() {
    [[ -n "${_KNIT_HISTORY_TABLE_ENSURED}" ]] && return 0
    _knit_history_create_table
    _KNIT_HISTORY_TABLE_ENSURED="1"
}
