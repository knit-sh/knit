#!/bin/bash

## @file sqlite.sh

# ------------------------------------------------------------------------------
# @var _KNIT_SQLITE_SOURCE_NAME
#
# Name of the SQLite source archive.
# ------------------------------------------------------------------------------
declare -g _KNIT_SQLITE_SOURCE_NAME
_KNIT_SQLITE_SOURCE_NAME="sqlite-autoconf-3480000"

# ------------------------------------------------------------------------------
# @var _KNIT_SQLITE_SOURCE_URL
#
# URL to download the SQLite source archive.
# ------------------------------------------------------------------------------
declare -g _KNIT_SQLITE_SOURCE_URL
_KNIT_SQLITE_SOURCE_URL="https://www.sqlite.org/2025/${_KNIT_SQLITE_SOURCE_NAME}.tar.gz"

# ------------------------------------------------------------------------------
# @var _KNIT_SQLITE_EXE
#
# Path to the SQLite executable.
# ------------------------------------------------------------------------------
declare -g _KNIT_SQLITE_EXE
_KNIT_SQLITE_EXE="${_KNIT_PREFIX}/sqlite/bin/sqlite3"

# ------------------------------------------------------------------------------
# @var _KNIT_DATABASE
#
# Path to the Knit database file.
# ------------------------------------------------------------------------------
declare -g _KNIT_DATABASE
_KNIT_DATABASE="${_KNIT_PREFIX}/knit.db"

# ------------------------------------------------------------------------------
# Busy timeout (milliseconds) applied to every sqlite3 invocation. If another
# writer holds the database lock, sqlite retries for up to this long before
# giving up with "database is locked". A second line of defence behind the
# write lock taken by _knit_sqlite3_write. Honours an inherited value so a
# high-concurrency path (or a test) can raise it without editing this file.
# ------------------------------------------------------------------------------
_KNIT_SQLITE_BUSY_TIMEOUT_MS="${_KNIT_SQLITE_BUSY_TIMEOUT_MS:-10000}"

# ------------------------------------------------------------------------------
# @fn _knit_sqlite_framed_run()
#
# Run a command with its combined stdout/stderr written to _KNIT_TRACE_FILE and,
# when KNIT_LOG_LEVEL is trace, also displayed live in a 10-line frame.
# Returns the exit status of the command.
#
# @param[in] title Title shown on the frame's top border.
# @param[in] ... Command and arguments to execute.
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
# Make an sqlite3 program available at _KNIT_SQLITE_EXE. Knit uses only the
# sqlite3 CLI (it links no SQLite library). By default sqlite3 is built from
# source into the .knit directory, so the install is self-contained: an HPC
# compute node often differs from the login node (a login-only system binary, or
# a symlink to one, is absent or dangling there), so a built binary is the
# portable default. With use_system the system sqlite3 is symlinked instead when
# its CLI is on PATH (no development files needed), falling back to a source build
# when none is found. The metadata and provenance tables are created in either
# case.
#
# @param[in] use_system When "true", symlink the system sqlite3 if one is on PATH
#        instead of building from source.
# ------------------------------------------------------------------------------
_knit_bootstrap_sqlite() {
    local use_system="${1:-false}"
    local system_sqlite=""
    if [[ "${use_system}" == "true" ]]; then
        system_sqlite="$(_knit_command_path sqlite3)"
    fi

    if [[ -n "${system_sqlite}" ]]; then
        knit_info "Using system sqlite at ${system_sqlite} (symlinked)."
        mkdir -p "$(dirname "${_KNIT_SQLITE_EXE}")"
        ln -s "${system_sqlite}" "${_KNIT_SQLITE_EXE}"
    else
        knit_info "Building sqlite from source.."
        _knit_build_sqlite
    fi

    knit_info "Creating database and tables..."
    _knit_create_metadata_table
    _knit_prov_create_table
    _knit_artifacts_create_table
    _knit_history_create_table

    # Apply the journal mode chosen at bootstrap (no-op for the default "delete";
    # a persistent "PRAGMA journal_mode=WAL" for "wal"). The marker is already
    # written, so _knit_db_apply_journal_mode resolves the right mode.
    _knit_db_apply_journal_mode
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_update_sqlite()
#
# Update-mode handler for --use-system-sqlite. The flag matters only when the
# current sqlite install is a from-source build and a system sqlite3 is on PATH:
# it replaces the build with a symlink to the system binary. An install that is
# already a system symlink is what the flag asks for, so it is a no-op; so is an
# untyped flag or an absent system binary.
#
# @param[in] ... Raw argument tokens of this invocation (see
#            _KNIT_INVOCATION_RAW_ARGS), used to tell a typed flag from a
#            defaulted one.
# @return 0 when sqlite was switched to a system symlink, 1 when nothing changed.
# ------------------------------------------------------------------------------
_knit_bootstrap_update_sqlite() {
    _knit_arg_was_provided "use-system-sqlite" "$@" || return 1
    [[ -L "${_KNIT_SQLITE_EXE}" ]] && return 1
    local system_sqlite; system_sqlite="$(_knit_command_path sqlite3)"
    [[ -n "${system_sqlite}" ]] || return 1
    knit_info "Using system sqlite at ${system_sqlite} (symlinked)."
    rm -rf "${_KNIT_PREFIX}/sqlite"
    mkdir -p "$(dirname "${_KNIT_SQLITE_EXE}")"
    ln -s "${system_sqlite}" "${_KNIT_SQLITE_EXE}"
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_build_sqlite()
#
# Provision Sqlite3 into the .knit directory. A built-binary cache hit (matched to
# this version, platform, and toolchain) is installed with no compile; otherwise
# sqlite is downloaded (through the source cache) and built, and the fresh build
# is published to the cache for next time.
# ------------------------------------------------------------------------------
_knit_build_sqlite() {
    local version="${_KNIT_SQLITE_SOURCE_NAME##*-}"
    if _knit_tool_cache_install sqlite "${version}" "${_KNIT_PREFIX}/sqlite" \
            bin/sqlite3 --version; then
        return 0
    fi

    knit_pushd "${_KNIT_PREFIX}"

    knit_trace "Downloading sqlite source..."
    local src
    if ! _knit_tool_cache_fetch_source src sqlite "${version}" \
            "${_KNIT_SQLITE_SOURCE_NAME}.tar.gz" "" \
            "${_KNIT_SQLITE_SOURCE_URL}" "sqlite: download" ; then
        knit_fatal "Could not download sqlite sources. See ${_KNIT_TRACE_FILE} for more information."
    fi

    knit_trace "Extracting sqlite source..."
    if ! _knit_sqlite_framed_run "sqlite: extract" \
            tar -xvf "${src}" ; then
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

    _knit_tool_cache_publish_built sqlite "${version}" "${_KNIT_PREFIX}/sqlite"
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
# @param[out] __knit_ret Name of the variable to hold the escaped string.
# @param[in] value String to escape.
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
# @param[out] __knit_ret Name of the variable to hold the quoted identifier.
# @param[in] name Identifier to quote.
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
# sqlite3 is self-contained: a from-source build carries an rpath to Knit's
# private libsqlite3 and a system build uses the default search paths, so it
# needs nothing from the caller's environment. `env` replaces itself with the
# target binary, so this adds no extra process.
#
# @param[in] ... Command and arguments to execute.
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
# _knit_sqlite3_write so they are also serialized by the write lock.
#
# @param[in] ... Parameters to forward to the sqlite3 command.
# ------------------------------------------------------------------------------
_knit_sqlite3() {
    _knit_run_isolated "${_KNIT_SQLITE_EXE}" \
        -cmd ".timeout ${_KNIT_SQLITE_BUSY_TIMEOUT_MS}" \
        "${_KNIT_DATABASE}" "$@"
}

# ------------------------------------------------------------------------------
# @var _KNIT_DB_LOCK_TIMEOUT_S
#
# How long (seconds) a "mkdir"-mode writer tries to acquire the database lock
# before giving up. A writer that cannot acquire the directory lock within this
# long fails (knit_fatal) rather than hanging, on the assumption that the holder
# died without releasing it (an untrappable SIGKILL leaves the lock behind).
# Honours an inherited value so tests can shrink it.
# ------------------------------------------------------------------------------
declare -g _KNIT_DB_LOCK_TIMEOUT_S
_KNIT_DB_LOCK_TIMEOUT_S="${_KNIT_DB_LOCK_TIMEOUT_S:-60}"

# ------------------------------------------------------------------------------
# @var _KNIT_DB_LOCK_MODE
#
# Process-level cache for _knit_db_lock_mode(): the resolved database write-lock
# mechanism ("flock", "mkdir", or "none"). Empty means "not yet resolved".
# ------------------------------------------------------------------------------
declare -g _KNIT_DB_LOCK_MODE
_KNIT_DB_LOCK_MODE=""

# ------------------------------------------------------------------------------
# @fn _knit_db_lock_mode()
#
# Resolve the database write-lock mechanism chosen at bootstrap and cache it for
# the rest of the process. The mode is read from the plain marker file
# "${_KNIT_PREFIX}/db-lock" (written by bootstrap before the first database
# write, so the mechanism is knowable without touching the database it guards).
# A missing or unreadable marker resolves to "flock", the pre-feature default, so
# a database created before this feature — or a .knit copied without the marker —
# keeps working. An unrecognized value warns and also falls back to "flock".
#
# @param[out] out Name of the variable to receive the mode (nameref output).
# ------------------------------------------------------------------------------
_knit_db_lock_mode() {
    local -n __knit_ret=$1
    if [[ -n "${_KNIT_DB_LOCK_MODE}" ]]; then
        __knit_ret="${_KNIT_DB_LOCK_MODE}"
        return 0
    fi
    # Named __knit_mode (not "mode") so it cannot shadow a caller that passes its
    # own "mode" variable as the output argument: such a shadow would make the
    # __knit_ret nameref write to this local instead of the caller's variable.
    local __knit_mode="flock"
    local marker="${_KNIT_PREFIX}/db-lock"
    if [[ -f "${marker}" ]]; then
        local content
        content="$(<"${marker}")"
        case "${content}" in
            flock|mkdir|none) __knit_mode="${content}" ;;
            *) knit_warning "Unknown database lock mode \"%s\" in %s; using \"flock\"." \
                   "${content}" "${marker}" ;;
        esac
    fi
    _KNIT_DB_LOCK_MODE="${__knit_mode}"
    __knit_ret="${__knit_mode}"
}

# ------------------------------------------------------------------------------
# @var _KNIT_DB_JOURNAL_MODE
#
# Process-level cache for _knit_db_journal_mode(): the resolved database journal
# mode ("delete" or "wal"). Empty means "not yet resolved".
# ------------------------------------------------------------------------------
declare -g _KNIT_DB_JOURNAL_MODE
_KNIT_DB_JOURNAL_MODE=""

# ------------------------------------------------------------------------------
# @fn _knit_db_journal_mode()
#
# Resolve the database journal mode chosen at bootstrap and cache it for the rest
# of the process. The mode is read from the plain marker file
# "${_KNIT_PREFIX}/db-journal" (written by bootstrap before the first database
# write, like the db-lock marker). A missing or unreadable marker resolves to
# "delete", SQLite's default rollback journal, so a database created before this
# feature — or a .knit copied without the marker — keeps today's behavior. An
# unrecognized value warns and also falls back to "delete".
#
# @param[out] out Name of the variable to receive the mode (nameref output).
# ------------------------------------------------------------------------------
_knit_db_journal_mode() {
    local -n __knit_ret=$1
    if [[ -n "${_KNIT_DB_JOURNAL_MODE}" ]]; then
        __knit_ret="${_KNIT_DB_JOURNAL_MODE}"
        return 0
    fi
    # Named __knit_mode (not "mode") so it cannot shadow a caller that passes its
    # own "mode" variable as the output argument; see _knit_db_lock_mode.
    local __knit_mode="delete"
    local marker="${_KNIT_PREFIX}/db-journal"
    if [[ -f "${marker}" ]]; then
        local content
        content="$(<"${marker}")"
        case "${content}" in
            delete|wal) __knit_mode="${content}" ;;
            *) knit_warning "Unknown database journal mode \"%s\" in %s; using \"delete\"." \
                   "${content}" "${marker}" ;;
        esac
    fi
    _KNIT_DB_JOURNAL_MODE="${__knit_mode}"
    __knit_ret="${__knit_mode}"
}

# ------------------------------------------------------------------------------
# @fn _knit_db_apply_journal_mode()
#
# Apply the resolved database journal mode to the database. "delete" is SQLite's
# default rollback journal, so it is a no-op. "wal" is a persistent, database-
# level property: setting "PRAGMA journal_mode=WAL" once writes the database
# header, and every later connection then reads in WAL mode from that header, so
# it is applied here (at bootstrap, and when switched in update mode) rather than
# on every connection. The write is routed through _knit_sqlite3_write so it is
# serialized by the write lock like any other write.
#
# WAL requires that every process touching the database run on the same host (it
# coordinates readers and the writer through a memory-mapped shared-memory file),
# so "wal" is an explicit single-host opt-in, never the default.
# ------------------------------------------------------------------------------
_knit_db_apply_journal_mode() {
    local mode
    _knit_db_journal_mode mode
    [[ "${mode}" == "wal" ]] || return 0
    _knit_sqlite3_write "PRAGMA journal_mode=WAL;" >/dev/null
}

# shellcheck disable=SC2120
# ------------------------------------------------------------------------------
# @fn _knit_sqlite3_write()
#
# Run a database write (INSERT/UPDATE/CREATE/migrate) while serializing writes
# across the independent processes that may touch the same database at once (e.g.
# many jobs finishing simultaneously on compute nodes). The serialization
# mechanism is chosen at bootstrap and resolved by _knit_db_lock_mode:
#
#   - "flock" (default): an advisory flock on a lock file next to the database.
#     Needs a filesystem that supports flock.
#   - "mkdir": an atomic directory lock that works on filesystems without flock
#     (e.g. NERSC DVS-projected home); see _knit_sqlite3_write_mkdir.
#   - "none": no lock at all — only safe when no two Knit writes ever overlap.
#
# The busy timeout set by _knit_sqlite3 remains a second line of defence under
# "flock"/"mkdir" (and the only one under "none"). Standard input is inherited,
# so heredoc-fed statements work unchanged in every mode.
#
# @param[in] ... Parameters to forward to _knit_sqlite3.
# ------------------------------------------------------------------------------
_knit_sqlite3_write() {
    local mode
    _knit_db_lock_mode mode
    case "${mode}" in
        none)  _knit_sqlite3 "$@" ;;
        mkdir) _knit_sqlite3_write_mkdir "$@" ;;
        *)     _knit_sqlite3_write_flock "$@" ;;
    esac
}

# shellcheck disable=SC2120
# ------------------------------------------------------------------------------
# @fn _knit_sqlite3_write_flock()
#
# "flock" write-lock mode. Take an advisory flock on a lock file next to the
# database; flock blocks until it is acquired, so writers queue rather than
# collide, and the kernel releases the lock automatically when the holder exits.
# Standard input is inherited by the subshell, so heredoc-fed statements work
# unchanged.
#
# @param[in] ... Parameters to forward to _knit_sqlite3.
# ------------------------------------------------------------------------------
_knit_sqlite3_write_flock() {
    local lock="${_KNIT_DATABASE}.lock"
    ( flock 9 || knit_fatal "Could not acquire database lock \"${lock}\"."
      _knit_sqlite3 "$@" ) 9>"${lock}"
}

# shellcheck disable=SC2120
# ------------------------------------------------------------------------------
# @fn _knit_sqlite3_write_mkdir()
#
# "mkdir" write-lock mode, for filesystems whose flock/fcntl locking is
# unsupported (NERSC DVS-projected home, some NFS/Lustre/GPFS mounts). The lock
# is a directory next to the database: "mkdir" is atomic (exactly one racer
# succeeds, the rest get EEXIST), and that atomicity survives on the filesystems
# where flock does not, because the metadata operation is forwarded to the
# backing server while the separate advisory-lock protocol is not.
#
# A writer spins on "mkdir" until it wins or _KNIT_DB_LOCK_TIMEOUT_S elapses; on
# timeout it fails (knit_fatal) and tells the user to remove a stray lock by
# hand. Knit NEVER removes a lock it did not create — auto-breaking a still-held
# lock is the only route back to concurrent writers and therefore to corruption,
# so that path does not exist; a stranded lock (only an untrappable SIGKILL can
# leave one) surfaces as the timeout message instead. The lock is released on
# normal completion and on a trappable INT/TERM.
#
# @param[in] ... Parameters to forward to _knit_sqlite3.
# ------------------------------------------------------------------------------
_knit_sqlite3_write_mkdir() {
    local lockdir="${_KNIT_DATABASE}.lock.d"
    local owner="${lockdir}.owner"
    local deadline=$(( SECONDS + _KNIT_DB_LOCK_TIMEOUT_S ))
    while ! mkdir "${lockdir}" 2>/dev/null; do
        if (( SECONDS >= deadline )); then
            local held_note=""
            if [[ -r "${owner}" ]]; then
                local held
                held="$(<"${owner}")"
                [[ -n "${held}" ]] && held_note=" Last held by ${held}."
            fi
            knit_fatal "Could not acquire database lock \"%s\" after %ss.%s\nIf no Knit process is running, the lock is stale; remove it by hand:\n  rmdir %s" \
                "${lockdir}" "${_KNIT_DB_LOCK_TIMEOUT_S}" "${held_note}" "${lockdir}"
        fi
        sleep 0.2
    done
    # The write runs in a subshell so the lock is released on the subshell's exit:
    # the EXIT trap covers normal completion and a knit_fatal inside the write,
    # and the INT/TERM traps route those signals through it. Only an untrappable
    # SIGKILL leaves the lock behind, which the timeout above surfaces. Standard
    # input is inherited, so heredoc-fed statements work unchanged.
    (
        trap 'rmdir "${lockdir}" 2>/dev/null; rm -f "${owner}"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        printf '%s @ %s (%s)\n' "$$" "${HOSTNAME:-$(hostname 2>/dev/null)}" \
            "$(date 2>/dev/null)" > "${owner}" 2>/dev/null || true
        _knit_sqlite3 "$@"
    )
}
