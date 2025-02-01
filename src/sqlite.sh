__KNIT_SQLITE_SOURCE_NAME="sqlite-autoconf-3480000"
__KNIT_SQLITE_SOURCE_URL="https://www.sqlite.org/2025/${__KNIT_SQLITE_SOURCE_NAME}.tar.gz"

# ------------------------------------------------------------------------------
# Download and build Sqlite3, and install it in the .knit directory.
# ------------------------------------------------------------------------------
_knit_bootstrap_sqlite() {
    knit_pushd "${_KNIT_PREFIX}"

    knit_trace "Downloading sqlite source..."
    curl -L -O "${__KNIT_SQLITE_SOURCE_URL}" > ${_KNIT_TRACE_FILE} 2>&1
    if [ "$?" -ne "0" ]; then
        knit_fatal "Could not download sqlite sources. See ${_KNIT_TRACE_FILE} for more information."
    fi

    knit_trace "Extracting sqlite source..."
    tar -xvf "${__KNIT_SQLITE_SOURCE_NAME}.tar.gz" > ${_KNIT_TRACE_FILE} 2>&1
    if [ "$?" -ne "0" ]; then
        knit_fatal "Could not extract sqlite sources. See ${_KNIT_TRACE_FILE} for more information."
    fi

    knit_trace "Building sqlite..."
    mkdir "${__KNIT_SQLITE_SOURCE_NAME}/build"
    knit_pushd "${__KNIT_SQLITE_SOURCE_NAME}/build"
    ../configure --prefix="${_KNIT_PREFIX}/sqlite" > ${_KNIT_TRACE_FILE} 2>&1
    if [ "$?" -ne "0" ]; then
        knit_fatal "Could not configure sqlite sources. See ${_KNIT_TRACE_FILE} for more information."
    fi
    make > ${_KNIT_TRACE_FILE} 2>&1
    if [ "$?" -ne "0" ]; then
        knit_fatal "Could not build sqlite sources. See ${_KNIT_TRACE_FILE} for more information."
    fi
    make install > ${_KNIT_TRACE_FILE} 2>&1
    if [ "$?" -ne "0" ]; then
        knit_fatal "Could not install sqlite. See ${_KNIT_TRACE_FILE} for more information."
    fi
    knit_popd # from "${__KNIT_SQLITE_SOURCE_NAME}/build"

    knit_trace "Deleting sqlite sources and archive..."
    rm -rf "${__KNIT_SQLITE_SOURCE_NAME}" "${__KNIT_SQLITE_SOURCE_NAME}.tar.gz" > ${_KNIT_TRACE_FILE} 2>&1

    knit_popd # from "${_KNIT_PREFIX}"
}
