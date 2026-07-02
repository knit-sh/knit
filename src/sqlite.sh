#!/bin/bash

## @file sqlite.sh

# ------------------------------------------------------------------------------
# Name of the SQLite source archive.
# ------------------------------------------------------------------------------
__KNIT_SQLITE_SOURCE_NAME="sqlite-autoconf-3480000"

# ------------------------------------------------------------------------------
# URL to download the SQLite source archive.
# ------------------------------------------------------------------------------
__KNIT_SQLITE_SOURCE_URL="https://www.sqlite.org/2025/${__KNIT_SQLITE_SOURCE_NAME}.tar.gz"

# ------------------------------------------------------------------------------
# Path to the SQLite executable.
# ------------------------------------------------------------------------------
__KNIT_SQLITE_EXE="${_KNIT_PREFIX}/sqlite/bin/sqlite3"

# ------------------------------------------------------------------------------
# Path to the Knit database file.
# ------------------------------------------------------------------------------
__KNIT_DATABASE="${_KNIT_PREFIX}/knit.db"

# ------------------------------------------------------------------------------
# @fn __knit_sqlite_framed_run()
#
# Run a command with its combined stdout/stderr written to _KNIT_TRACE_FILE and,
# when KNIT_LOG_LEVEL is trace, also displayed live in a 10-line frame.
# Returns the exit status of the command.
#
# @param title Title shown on the frame's top border.
# @param ... Command and arguments to execute.
# ------------------------------------------------------------------------------
__knit_sqlite_framed_run() {
    local title="$1"
    shift
    _knit_ensure_trace_file
    "$@" 2>&1 | tee "${_KNIT_TRACE_FILE}" | \
        knit_framed 10 -1 --title "${title}" --log-level trace --cleanup
    local -a pipe_status=("${PIPESTATUS[@]}")
    return "${pipe_status[0]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_sqlite()
#
# Download and build Sqlite3, and install it in the .knit directory.
# ------------------------------------------------------------------------------
_knit_bootstrap_sqlite() {
    knit_pushd "${_KNIT_PREFIX}"

    knit_trace "Downloading sqlite source..."
    if ! __knit_sqlite_framed_run "sqlite: download" \
            curl -L -O "${__KNIT_SQLITE_SOURCE_URL}" ; then
        knit_fatal "Could not download sqlite sources. See ${_KNIT_TRACE_FILE} for more information."
    fi

    knit_trace "Extracting sqlite source..."
    if ! __knit_sqlite_framed_run "sqlite: extract" \
            tar -xvf "${__KNIT_SQLITE_SOURCE_NAME}.tar.gz" ; then
        knit_fatal "Could not extract sqlite sources. See ${_KNIT_TRACE_FILE} for more information."
    fi

    knit_trace "Building sqlite..."
    mkdir "${__KNIT_SQLITE_SOURCE_NAME}/build"
    knit_pushd "${__KNIT_SQLITE_SOURCE_NAME}/build"
    if ! __knit_sqlite_framed_run "sqlite: configure" \
            ../configure --prefix="${_KNIT_PREFIX}/sqlite" ; then
        knit_fatal "Could not configure sqlite sources. See ${_KNIT_TRACE_FILE} for more information."
    fi
    if ! __knit_sqlite_framed_run "sqlite: make" \
            make ; then
        knit_fatal "Could not build sqlite sources. See ${_KNIT_TRACE_FILE} for more information."
    fi
    if ! __knit_sqlite_framed_run "sqlite: make install" \
            make install ; then
        knit_fatal "Could not install sqlite. See ${_KNIT_TRACE_FILE} for more information."
    fi
    knit_popd # from "${__KNIT_SQLITE_SOURCE_NAME}/build"

    knit_trace "Deleting sqlite sources and archive..."
    rm -rf "${__KNIT_SQLITE_SOURCE_NAME}" "${__KNIT_SQLITE_SOURCE_NAME}.tar.gz" 2>"${_KNIT_TRACE_FILE}"

    knit_popd # from "${_KNIT_PREFIX}"

    knit_trace "Creating database and tables..."
    _knit_create_metadata_table

}

# ------------------------------------------------------------------------------
# @fn _knit_create_metadata_table()
#
# Create the metadata key/value table in the main database if it does not
# already exist. Factored out of the bootstrap so tests (and any other code that
# needs a metadata table) can create one without duplicating the schema.
# ------------------------------------------------------------------------------
_knit_create_metadata_table() {
    _knit_sqlite3 <<'EOF'
CREATE TABLE IF NOT EXISTS metadata (
    key TEXT PRIMARY KEY,
    value TEXT
);
EOF
}

# ------------------------------------------------------------------------------
# @fn _knit_sql_escape()
#
# Escape a string for safe interpolation into a SQL single-quoted literal by
# replacing every single quote with two single quotes, per the SQL standard.
#
# Example:
# ```
# _knit_sql_escape "it's"   # prints: it''s
# ```
#
# @param value String to escape.
# ------------------------------------------------------------------------------
_knit_sql_escape() {
    printf '%s' "${1//\'/\'\'}"
}

# shellcheck disable=SC2120
# ------------------------------------------------------------------------------
# @fn _knit_sqlite3()
#
# Invoke Knit's sqlite3-installed program on the main database.
#
# @param ... Parameters to forward to the sqlite3 command.
# ------------------------------------------------------------------------------
_knit_sqlite3() {
    ${__KNIT_SQLITE_EXE} "${__KNIT_DATABASE}" "$@"
}
