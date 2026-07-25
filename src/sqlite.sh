#!/bin/bash

## @file sqlite.sh

# ------------------------------------------------------------------------------
# Name of the SQLite source archive.
# ------------------------------------------------------------------------------
_KNIT_SQLITE_SOURCE_NAME="sqlite-autoconf-3480000"

# ------------------------------------------------------------------------------
# URL to download the SQLite source archive.
# ------------------------------------------------------------------------------
_KNIT_SQLITE_SOURCE_URL="https://www.sqlite.org/2025/${_KNIT_SQLITE_SOURCE_NAME}.tar.gz"

# ------------------------------------------------------------------------------
# Path to the SQLite executable.
# ------------------------------------------------------------------------------
_KNIT_SQLITE_EXE="${_KNIT_PREFIX}/sqlite/bin/sqlite3"

# ------------------------------------------------------------------------------
# Path to the Knit database file.
# ------------------------------------------------------------------------------
_KNIT_DATABASE="${_KNIT_PREFIX}/knit.db"

# ------------------------------------------------------------------------------
# Busy timeout (milliseconds) applied to every sqlite3 invocation. If another
# writer holds the database lock, sqlite retries for up to this long before
# giving up with "database is locked". A second line of defence behind the
# advisory flock taken by _knit_sqlite3_write.
# ------------------------------------------------------------------------------
_KNIT_SQLITE_BUSY_TIMEOUT_MS="10000"

# ------------------------------------------------------------------------------
# @fn _knit_sqlite_framed_run()
#
# Run a command with its combined stdout/stderr written to _KNIT_TRACE_FILE and,
# when KNIT_LOG_LEVEL is trace, also displayed live in a 10-line frame.
# Returns the exit status of the command.
#
# @param title Title shown on the frame's top border.
# @param ... Command and arguments to execute.
# ------------------------------------------------------------------------------
_knit_sqlite_framed_run() {
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
# Make an sqlite3 program available at _KNIT_SQLITE_EXE. When a system sqlite3
# is found on PATH and the caller did not request otherwise, symlink it into the
# .knit directory instead of building from source; otherwise download and build
# sqlite3 from source. The metadata table is created in either case.
#
# @param ignore_system When "true", always build from source even if a system
#        sqlite3 is present.
# ------------------------------------------------------------------------------
_knit_bootstrap_sqlite() {
    local ignore_system="${1:-false}"
    local system_sqlite=""
    if [[ "${ignore_system}" != "true" ]]; then
        system_sqlite="$(_knit_command_path sqlite3)"
    fi

    if [[ -n "${system_sqlite}" ]]; then
        knit_info "Using system sqlite3 at ${system_sqlite} (symlinked)."
        mkdir -p "$(dirname "${_KNIT_SQLITE_EXE}")"
        ln -s "${system_sqlite}" "${_KNIT_SQLITE_EXE}"
    else
        _knit_build_sqlite
    fi

    knit_trace "Creating database and tables..."
    _knit_create_metadata_table
    _knit_prov_create_table
}

# ------------------------------------------------------------------------------
# @fn _knit_build_sqlite()
#
# Download and build Sqlite3, and install it in the .knit directory.
# ------------------------------------------------------------------------------
_knit_build_sqlite() {
    knit_pushd "${_KNIT_PREFIX}"

    knit_trace "Downloading sqlite source..."
    if ! _knit_sqlite_framed_run "sqlite: download" \
            curl -L -O "${_KNIT_SQLITE_SOURCE_URL}" ; then
        knit_fatal "Could not download sqlite sources. See ${_KNIT_TRACE_FILE} for more information."
    fi

    knit_trace "Extracting sqlite source..."
    if ! _knit_sqlite_framed_run "sqlite: extract" \
            tar -xvf "${_KNIT_SQLITE_SOURCE_NAME}.tar.gz" ; then
        knit_fatal "Could not extract sqlite sources. See ${_KNIT_TRACE_FILE} for more information."
    fi

    knit_trace "Building sqlite..."
    mkdir "${_KNIT_SQLITE_SOURCE_NAME}/build"
    knit_pushd "${_KNIT_SQLITE_SOURCE_NAME}/build"
    if ! _knit_sqlite_framed_run "sqlite: configure" \
            ../configure --prefix="${_KNIT_PREFIX}/sqlite" ; then
        knit_fatal "Could not configure sqlite sources. See ${_KNIT_TRACE_FILE} for more information."
    fi
    if ! _knit_sqlite_framed_run "sqlite: make" \
            make ; then
        knit_fatal "Could not build sqlite sources. See ${_KNIT_TRACE_FILE} for more information."
    fi
    if ! _knit_sqlite_framed_run "sqlite: make install" \
            make install ; then
        knit_fatal "Could not install sqlite. See ${_KNIT_TRACE_FILE} for more information."
    fi
    knit_popd # from "${_KNIT_SQLITE_SOURCE_NAME}/build"

    knit_trace "Deleting sqlite sources and archive..."
    rm -rf "${_KNIT_SQLITE_SOURCE_NAME}" "${_KNIT_SQLITE_SOURCE_NAME}.tar.gz" 2>"${_KNIT_TRACE_FILE}"

    knit_popd # from "${_KNIT_PREFIX}"
}

# ------------------------------------------------------------------------------
# @fn _knit_create_metadata_table()
#
# Create the metadata key/value table in the main database if it does not
# already exist. Factored out of the bootstrap so tests (and any other code that
# needs a metadata table) can create one without duplicating the schema.
# ------------------------------------------------------------------------------
_knit_create_metadata_table() {
    _knit_sqlite3_write <<'EOF'
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
# local escaped; _knit_sql_escape escaped "it's"   # escaped == it''s
# ```
#
# @param __knit_ret Name of the variable to hold the escaped string.
# @param value String to escape.
# ------------------------------------------------------------------------------
_knit_sql_escape() {
    local -n __knit_ret=$1
    __knit_ret="${2//\'/\'\'}"
}

# ------------------------------------------------------------------------------
# @fn _knit_sql_quote_identifier()
#
# Quote a SQL identifier (e.g. a table or column name) so it can be interpolated
# safely into a statement. The name is wrapped in double quotes and every
# embedded double quote is doubled, per the SQL standard. This lets an
# identifier that would otherwise be invalid unquoted -- such as a nested
# command's default table name "aaa:bbb", which contains a colon -- be used
# without the caller having to add quotes by hand.
#
# Example:
# ```
# local quoted; _knit_sql_quote_identifier quoted "aaa:bbb"   # quoted == "aaa:bbb"
# ```
#
# @param __knit_ret Name of the variable to hold the quoted identifier.
# @param name Identifier to quote.
# ------------------------------------------------------------------------------
_knit_sql_quote_identifier() {
    local -n __knit_ret=$1
    printf -v __knit_ret '"%s"' "${2//\"/\"\"}"
}

# shellcheck disable=SC2120
# ------------------------------------------------------------------------------
# @fn _knit_sqlite3()
#
# Invoke Knit's sqlite3-installed program on the main database. Every invocation
# sets a busy timeout so that a concurrent writer only causes a bounded wait
# rather than an immediate "database is locked" failure. Use this for reads;
# route writes through _knit_sqlite3_write so they are also serialized by the
# advisory lock.
#
# @param ... Parameters to forward to the sqlite3 command.
# ------------------------------------------------------------------------------
_knit_sqlite3() {
    ${_KNIT_SQLITE_EXE} -cmd ".timeout ${_KNIT_SQLITE_BUSY_TIMEOUT_MS}" \
        "${_KNIT_DATABASE}" "$@"
}

# shellcheck disable=SC2120
# ------------------------------------------------------------------------------
# @fn _knit_sqlite3_write()
#
# Run a database write (INSERT/UPDATE/CREATE/migrate) while holding an advisory
# lock, serializing writes across the independent processes that may touch the
# same database at once (e.g. many jobs finishing simultaneously on compute
# nodes). The lock is a file next to the database; flock blocks until it is
# acquired, so writers queue rather than collide. The busy timeout set by
# _knit_sqlite3 remains as a second line of defence. Standard input is inherited
# by the subshell, so heredoc-fed statements work unchanged.
#
# @param ... Parameters to forward to _knit_sqlite3.
# ------------------------------------------------------------------------------
_knit_sqlite3_write() {
    local lock="${_KNIT_DATABASE}.lock"
    ( flock 9 || knit_fatal "Could not acquire database lock \"${lock}\"."
      _knit_sqlite3 "$@" ) 9>"${lock}"
}

# ------------------------------------------------------------------------------
# Register the "knit sql" wrapper: forwards every argument verbatim to the
# knit-private sqlite3, opened on the experiment database. This is a convenience
# for running ad hoc queries or edits by hand; unlike "knit db query" it is not
# restricted to read-only statements. It goes through _knit_sqlite3 (busy
# timeout, no held write lock) so concurrent knit writers are not blocked while
# an interactive session is open. The central runtime guard refuses it before
# bootstrap (the database does not exist yet), so no in-body check is needed.
# ------------------------------------------------------------------------------
knit_register_wrapper "sql" "_knit_sql" \
    "Run the knit-private sqlite3 on the experiment database, forwarding all arguments verbatim."
_knit_is_builtin
knit_without_provenance
# ------------------------------------------------------------------------------
# @fn _knit_sql()
#
# Body of the "knit sql" wrapper command. Forwards all arguments verbatim to
# the knit-private sqlite3 running on the experiment database.
#
# @param ... Arguments forwarded verbatim to sqlite3 (including --help).
# @return The exit status of sqlite3.
# ------------------------------------------------------------------------------
_knit_sql() {
    _knit_sqlite3 "$@"
}
knit_done
