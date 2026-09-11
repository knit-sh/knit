#!/bin/bash

## @file cypher.sh

# ------------------------------------------------------------------------------
# Version of knit-cypher-to-sql to provision.
# ------------------------------------------------------------------------------
_KNIT_CYPHER_TO_SQL_VERSION="0.1.0"

# ------------------------------------------------------------------------------
# Path to the knit-cypher-to-sql executable.
# ------------------------------------------------------------------------------
_KNIT_CYPHER_TO_SQL_EXE="${_KNIT_PREFIX}/knit-cypher-to-sql/bin/knit-cypher-to-sql"

# ------------------------------------------------------------------------------
# @fn _knit_cypher_to_sql_framed_run()
#
# Run a command with its combined stdout/stderr written to _KNIT_TRACE_FILE and,
# when KNIT_LOG_LEVEL is trace, also displayed live in a 10-line frame.
# Returns the exit status of the command.
#
# @param[in] title Title shown on the frame's top border.
# @param[in] ... Command and arguments to execute.
# ------------------------------------------------------------------------------
_knit_cypher_to_sql_framed_run() {
    local title="$1"
    shift
    _knit_ensure_trace_file
    "$@" 2>&1 | tee "${_KNIT_TRACE_FILE}" | \
        knit_framed 10 -1 --title "${title}" --log-level trace --cleanup
    local -a pipe_status=("${PIPESTATUS[@]}")
    return "${pipe_status[0]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_cypher_to_sql_url()
#
# Print the download URL for a knit-cypher-to-sql release tarball given its
# version. The release tag is the version prefixed with "v" and the asset is
# named after the version, e.g. version 0.1.0 ->
# .../download/v0.1.0/knit-cypher-to-sql-0.1.0.tar.gz.
#
# @param[in] version knit-cypher-to-sql release version (without the leading "v").
# ------------------------------------------------------------------------------
_knit_cypher_to_sql_url() {
    local version="$1"
    printf 'https://github.com/knit-sh/knit-cypher-to-sql/releases/download/v%s/knit-cypher-to-sql-%s.tar.gz' \
        "${version}" "${version}"
}

# ------------------------------------------------------------------------------
# @fn _knit_build_cypher_to_sql()
#
# Download the knit-cypher-to-sql release tarball, build it, and install it under
# .knit/knit-cypher-to-sql. The transpiler links nothing from SQLite, so the
# build needs no SQLite development files (no --with-sqlite3). The release tarball
# ships the pre-generated parser/scanner and configure script, so only a C
# compiler is needed (no autotools/bison/flex).
#
# @param[in] version knit-cypher-to-sql release version to build.
# @param[in] url URL of the knit-cypher-to-sql release tarball.
# ------------------------------------------------------------------------------
_knit_build_cypher_to_sql() {
    local version="$1"
    local url="$2"
    local srcname="knit-cypher-to-sql-${version}"
    local tarball="${srcname}.tar.gz"

    knit_pushd "${_KNIT_PREFIX}"

    knit_trace "Downloading knit-cypher-to-sql source..."
    # -f makes an HTTP error status (e.g. a rate-limited GitHub response) a clean
    # failure instead of a saved error body that would later fail to extract;
    # --retry rides out a transient network error. A GITHUB_TOKEN/GH_TOKEN, when
    # set, lifts the low anonymous rate limit that CI runners share by address.
    local -a curl_args=(-fL --retry 3 --retry-delay 2 -o "${tarball}")
    local gh_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    [[ -n "${gh_token}" ]] && curl_args+=(-H "Authorization: Bearer ${gh_token}")
    if ! _knit_cypher_to_sql_framed_run "knit-cypher-to-sql: download" \
            curl "${curl_args[@]}" "${url}" ; then
        knit_fatal "Could not download knit-cypher-to-sql from ${url}. See ${_KNIT_TRACE_FILE} for more information."
    fi

    knit_trace "Extracting knit-cypher-to-sql source..."
    if ! _knit_cypher_to_sql_framed_run "knit-cypher-to-sql: extract" \
            tar -xzf "${tarball}" ; then
        knit_fatal "Could not extract knit-cypher-to-sql sources. See ${_KNIT_TRACE_FILE} for more information."
    fi

    knit_trace "Building knit-cypher-to-sql..."
    mkdir "${srcname}/build"
    knit_pushd "${srcname}/build"
    if ! _knit_cypher_to_sql_framed_run "knit-cypher-to-sql: configure" \
            ../configure --prefix="${_KNIT_PREFIX}/knit-cypher-to-sql" ; then
        knit_fatal "Could not configure knit-cypher-to-sql. See ${_KNIT_TRACE_FILE} for more information."
    fi
    if ! _knit_cypher_to_sql_framed_run "knit-cypher-to-sql: make" \
            make ; then
        knit_fatal "Could not build knit-cypher-to-sql. See ${_KNIT_TRACE_FILE} for more information."
    fi
    if ! _knit_cypher_to_sql_framed_run "knit-cypher-to-sql: make install" \
            make install ; then
        knit_fatal "Could not install knit-cypher-to-sql. See ${_KNIT_TRACE_FILE} for more information."
    fi
    knit_popd # from "${srcname}/build"

    knit_trace "Deleting knit-cypher-to-sql sources and archive..."
    rm -rf "${srcname}" "${tarball}" 2>"${_KNIT_TRACE_FILE}"

    knit_popd # from "${_KNIT_PREFIX}"
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_cypher_to_sql()
#
# Provision knit-cypher-to-sql at _KNIT_CYPHER_TO_SQL_EXE. Resolves the version
# (the pinned default when empty) and the download URL (derived from the version
# when empty), builds and installs the transpiler, and records provenance
# metadata (the version and URL provisioned). The transpiler needs no SQLite, so
# this is independent of the sqlite provisioning.
#
# @param[in] version knit-cypher-to-sql version to provision; empty uses the pinned default.
# @param[in] url Override URL for the release tarball; empty derives it from the version.
# ------------------------------------------------------------------------------
_knit_bootstrap_cypher_to_sql() {
    local version="${1:-}"
    local url="${2:-}"
    if [[ -z "${version}" ]]; then
        version="${_KNIT_CYPHER_TO_SQL_VERSION}"
    fi
    if [[ -z "${url}" ]]; then
        url="$(_knit_cypher_to_sql_url "${version}")"
    fi

    _knit_build_cypher_to_sql "${version}" "${url}"

    knit_trace "Storing knit-cypher-to-sql provenance metadata..."
    knit metadata store --key "__knit_cypher_to_sql_version__" --value "${version}"
    knit metadata store --key "__knit_cypher_to_sql_url__"     --value "${url}"
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_update_cypher_to_sql()
#
# Update-mode handler for --knit-cypher-to-sql-version/--knit-cypher-to-sql-url.
# When a typed option differs from the stored value, remove the install, rebuild
# it at the effective version/URL, and update the stored provenance
# (__knit_cypher_to_sql_version__/__knit_cypher_to_sql_url__). A typed version
# with no explicit URL re-derives the URL from that version, so a version bump
# also moves the download. A typed option equal to the stored value, or an
# untyped option, is a no-op.
#
# @param[in] version Value typed for --knit-cypher-to-sql-version.
# @param[in] url Value typed for --knit-cypher-to-sql-url.
# @param[in] ... Raw argument tokens of this invocation (see
#                _KNIT_INVOCATION_RAW_ARGS), used to tell a typed option from a
#                defaulted one.
# @return 0 when knit-cypher-to-sql was re-provisioned, 1 when nothing changed.
# ------------------------------------------------------------------------------
_knit_bootstrap_update_cypher_to_sql() {
    local version="$1"
    local url="$2"
    shift 2

    local version_typed="false" url_typed="false"
    _knit_arg_was_provided "knit-cypher-to-sql-version" "$@" && version_typed="true"
    _knit_arg_was_provided "knit-cypher-to-sql-url" "$@" && url_typed="true"
    [[ "${version_typed}" == "false" && "${url_typed}" == "false" ]] && return 1

    local stored_version stored_url
    _knit_metadata_get stored_version "__knit_cypher_to_sql_version__"
    _knit_metadata_get stored_url "__knit_cypher_to_sql_url__"

    local eff_version="${stored_version}" eff_url="${stored_url}"
    local differs="false"
    if [[ "${version_typed}" == "true" && "${version}" != "${stored_version}" ]]; then
        eff_version="${version}"
        differs="true"
    fi
    if [[ "${url_typed}" == "true" ]]; then
        if [[ "${url}" != "${stored_url}" ]]; then
            eff_url="${url}"
            differs="true"
        fi
    elif [[ "${differs}" == "true" ]]; then
        # Version changed and no explicit URL: re-derive it from the new version.
        eff_url="$(_knit_cypher_to_sql_url "${eff_version}")"
    fi

    [[ "${differs}" == "false" ]] && return 1

    knit_info "Re-provisioning knit-cypher-to-sql..."
    rm -rf "${_KNIT_PREFIX}/knit-cypher-to-sql"
    _knit_build_cypher_to_sql "${eff_version}" "${eff_url}"
    knit metadata store --key "__knit_cypher_to_sql_version__" --value "${eff_version}" --force
    knit metadata store --key "__knit_cypher_to_sql_url__"     --value "${eff_url}" --force
    return 0
}

# shellcheck disable=SC2120
# ------------------------------------------------------------------------------
# @fn _knit_cypher_to_sql()
#
# Invoke Knit's knit-cypher-to-sql installation. The dynamic-linker environment
# is scrubbed (via _knit_run_isolated) so an active user environment cannot
# perturb the transpiler. It reads the flat schema on stdin, so callers pipe the
# schema in; stdin is passed through untouched.
#
# @param[in] ... Parameters to forward to the knit-cypher-to-sql command.
# ------------------------------------------------------------------------------
_knit_cypher_to_sql() {
    _knit_run_isolated "${_KNIT_CYPHER_TO_SQL_EXE}" "$@"
}
