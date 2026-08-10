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
# @var _KNIT_SQLITE_PREFIX
#
# Installation prefix of the SQLite that knit-graph is built against, set by
# _knit_bootstrap_sqlite: the from-source install prefix (_KNIT_PREFIX/sqlite)
# when SQLite is built from source, or empty when the system SQLite is used (its
# development files are on the compiler's default search paths, so knit-graph
# needs no --with-sqlite3). Read by _knit_build_knitgraph.
# ------------------------------------------------------------------------------
declare -g _KNIT_SQLITE_PREFIX
_KNIT_SQLITE_PREFIX=""

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
# Make an sqlite3 program available at _KNIT_SQLITE_EXE. The system sqlite3 is
# symlinked into the .knit directory only when both its CLI is on PATH and its
# development files (header + library) are usable -- knit-graph links against
# those, and a symlinked CLI alone does not guarantee they exist. Otherwise
# sqlite3 is downloaded and built from source, which lays down both the CLI and
# the development files. Sets _KNIT_SQLITE_PREFIX to the install prefix knit-graph
# must build against (empty for the system, where the dev files are on the default
# search paths). The metadata and provenance tables are created in either case.
#
# @param ignore_system When "true", always build from source even if a usable
#        system sqlite3 is present.
# ------------------------------------------------------------------------------
_knit_bootstrap_sqlite() {
    local ignore_system="${1:-false}"
    local system_sqlite=""
    if [[ "${ignore_system}" != "true" ]]; then
        system_sqlite="$(_knit_command_path sqlite3)"
    fi

    if [[ -n "${system_sqlite}" ]] && _knit_detect_sqlite_dev; then
        knit_info "Using system sqlite3 at ${system_sqlite} (symlinked)."
        mkdir -p "$(dirname "${_KNIT_SQLITE_EXE}")"
        ln -s "${system_sqlite}" "${_KNIT_SQLITE_EXE}"
        _KNIT_SQLITE_PREFIX=""
    else
        knit_info "Building sqlite3 from source.."
        _knit_build_sqlite
        _KNIT_SQLITE_PREFIX="${_KNIT_PREFIX}/sqlite"
    fi

    knit_info "Creating database and tables..."
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

    knit_info "Downloading sqlite source..."
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

# ------------------------------------------------------------------------------
# @fn _knit_run_isolated()
#
# Execute a command with the dynamic-linker environment variables scrubbed
# (LD_LIBRARY_PATH, LD_PRELOAD, LD_AUDIT) so that an active user environment -- a
# Spack environment, an environment module, or a manually exported
# LD_LIBRARY_PATH -- cannot make a Knit-provisioned binary load a shared library
# (most importantly libsqlite3) other than the one it was built against. Knit's
# sqlite3 and knit-graph are self-contained: a from-source build carries an rpath
# to Knit's private libsqlite3 and a system build uses the default search paths,
# so neither needs anything from the caller's environment. `env` replaces itself
# with the target binary, so this adds no extra process.
#
# @param ... Command and arguments to execute.
# ------------------------------------------------------------------------------
_knit_run_isolated() {
    env -u LD_LIBRARY_PATH -u LD_PRELOAD -u LD_AUDIT "$@"
}

# shellcheck disable=SC2120
# ------------------------------------------------------------------------------
# @fn _knit_sqlite3()
#
# Invoke Knit's sqlite3-installed program on the main database. Every invocation
# sets a busy timeout so that a concurrent writer only causes a bounded wait
# rather than an immediate "database is locked" failure. The dynamic-linker
# environment is scrubbed (via _knit_run_isolated) so an active user environment
# cannot swap in a different libsqlite3. Use this for reads; route writes through
# _knit_sqlite3_write so they are also serialized by the advisory lock.
#
# @param ... Parameters to forward to the sqlite3 command.
# ------------------------------------------------------------------------------
_knit_sqlite3() {
    _knit_run_isolated "${_KNIT_SQLITE_EXE}" \
        -cmd ".timeout ${_KNIT_SQLITE_BUSY_TIMEOUT_MS}" \
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
