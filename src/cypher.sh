#!/bin/bash

## @file cypher.sh

# ------------------------------------------------------------------------------
# Source ref (tag, branch, or commit) of knit-cypher-to-sql to build. This is a
# transitional, source-based provisioning: knit-cypher-to-sql has no published
# release of the pure transpiler yet, so it is built from a pinned ref of its
# repository. Once a release is cut, provisioning switches to the release
# tarball (as knit-graph is consumed today).
# ------------------------------------------------------------------------------
_KNIT_CYPHER_TO_SQL_REF="main"

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
# Print the download URL for a knit-cypher-to-sql source tarball given a ref.
# GitHub serves any tag, branch, or commit at archive/<ref>.tar.gz.
#
# @param[in] ref knit-cypher-to-sql source ref (tag, branch, or commit).
# ------------------------------------------------------------------------------
_knit_cypher_to_sql_url() {
    local ref="$1"
    printf 'https://github.com/knit-sh/knit-cypher-to-sql/archive/%s.tar.gz' \
        "${ref}"
}

# ------------------------------------------------------------------------------
# @fn _knit_build_cypher_to_sql()
#
# Download a knit-cypher-to-sql source tarball, build it, and install it under
# .knit/knit-cypher-to-sql. The transpiler links nothing from SQLite, so the
# build needs no SQLite development files (no --with-sqlite3). A source tarball
# ships no generated parser/scanner or configure script, so the build first runs
# autoreconf (autoconf/automake/bison/flex) before configure/make/make install.
#
# @param[in] ref knit-cypher-to-sql source ref to build.
# @param[in] url URL of the knit-cypher-to-sql source tarball.
# ------------------------------------------------------------------------------
_knit_build_cypher_to_sql() {
    local ref="$1"
    local url="$2"
    local srcdir="${_KNIT_PREFIX}/knit-cypher-to-sql-src"
    local tarball="${_KNIT_PREFIX}/knit-cypher-to-sql-src.tar.gz"

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
    # --strip-components=1 drops the single "knit-cypher-to-sql-<ref>/" top-level
    # directory GitHub archives carry, so files land directly under srcdir.
    rm -rf "${srcdir}"
    mkdir "${srcdir}"
    if ! _knit_cypher_to_sql_framed_run "knit-cypher-to-sql: extract" \
            tar -xzf "${tarball}" -C "${srcdir}" --strip-components=1 ; then
        knit_fatal "Could not extract knit-cypher-to-sql sources. See ${_KNIT_TRACE_FILE} for more information."
    fi

    knit_trace "Building knit-cypher-to-sql..."
    knit_pushd "${srcdir}"
    if ! _knit_cypher_to_sql_framed_run "knit-cypher-to-sql: autoreconf" \
            autoreconf -i ; then
        knit_fatal "Could not autoreconf knit-cypher-to-sql. See ${_KNIT_TRACE_FILE} for more information."
    fi
    mkdir build
    knit_pushd build
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
    knit_popd # from build
    knit_popd # from srcdir

    knit_trace "Deleting knit-cypher-to-sql sources and archive..."
    rm -rf "${srcdir}" "${tarball}" 2>"${_KNIT_TRACE_FILE}"

    knit_popd # from "${_KNIT_PREFIX}"
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_cypher_to_sql()
#
# Provision knit-cypher-to-sql at _KNIT_CYPHER_TO_SQL_EXE. Resolves the ref (the
# pinned default when empty) and the download URL (derived from the ref when
# empty), builds and installs the transpiler, and records provenance metadata
# (the ref and URL provisioned). The transpiler needs no SQLite, so this is
# independent of the sqlite provisioning.
#
# @param[in] ref knit-cypher-to-sql ref to provision; empty uses the pinned default.
# @param[in] url Override URL for the source tarball; empty derives it from the ref.
# ------------------------------------------------------------------------------
_knit_bootstrap_cypher_to_sql() {
    local ref="${1:-}"
    local url="${2:-}"
    if [[ -z "${ref}" ]]; then
        ref="${_KNIT_CYPHER_TO_SQL_REF}"
    fi
    if [[ -z "${url}" ]]; then
        url="$(_knit_cypher_to_sql_url "${ref}")"
    fi

    _knit_build_cypher_to_sql "${ref}" "${url}"

    knit_trace "Storing knit-cypher-to-sql provenance metadata..."
    knit metadata store --key "__knit_cypher_to_sql_ref__" --value "${ref}"
    knit metadata store --key "__knit_cypher_to_sql_url__" --value "${url}"
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_update_cypher_to_sql()
#
# Update-mode handler for --knit-cypher-to-sql-ref/--knit-cypher-to-sql-url. When
# a typed option differs from the stored value, remove the install, rebuild it at
# the effective ref/URL, and update the stored provenance
# (__knit_cypher_to_sql_ref__/__knit_cypher_to_sql_url__). A typed ref with no
# explicit URL re-derives the URL from that ref, so a ref change also moves the
# download. A typed option equal to the stored value, or an untyped option, is a
# no-op.
#
# @param[in] ref Value typed for --knit-cypher-to-sql-ref.
# @param[in] url Value typed for --knit-cypher-to-sql-url.
# @param[in] ... Raw argument tokens of this invocation (see
#                _KNIT_INVOCATION_RAW_ARGS), used to tell a typed option from a
#                defaulted one.
# @return 0 when knit-cypher-to-sql was re-provisioned, 1 when nothing changed.
# ------------------------------------------------------------------------------
_knit_bootstrap_update_cypher_to_sql() {
    local ref="$1"
    local url="$2"
    shift 2

    local ref_typed="false" url_typed="false"
    _knit_arg_was_provided "knit-cypher-to-sql-ref" "$@" && ref_typed="true"
    _knit_arg_was_provided "knit-cypher-to-sql-url" "$@" && url_typed="true"
    [[ "${ref_typed}" == "false" && "${url_typed}" == "false" ]] && return 1

    local stored_ref stored_url
    _knit_metadata_get stored_ref "__knit_cypher_to_sql_ref__"
    _knit_metadata_get stored_url "__knit_cypher_to_sql_url__"

    local eff_ref="${stored_ref}" eff_url="${stored_url}"
    local differs="false"
    if [[ "${ref_typed}" == "true" && "${ref}" != "${stored_ref}" ]]; then
        eff_ref="${ref}"
        differs="true"
    fi
    if [[ "${url_typed}" == "true" ]]; then
        if [[ "${url}" != "${stored_url}" ]]; then
            eff_url="${url}"
            differs="true"
        fi
    elif [[ "${differs}" == "true" ]]; then
        # Ref changed and no explicit URL: re-derive it from the new ref.
        eff_url="$(_knit_cypher_to_sql_url "${eff_ref}")"
    fi

    [[ "${differs}" == "false" ]] && return 1

    knit_info "Re-provisioning knit-cypher-to-sql..."
    rm -rf "${_KNIT_PREFIX}/knit-cypher-to-sql"
    _knit_build_cypher_to_sql "${eff_ref}" "${eff_url}"
    knit metadata store --key "__knit_cypher_to_sql_ref__" --value "${eff_ref}" --force
    knit metadata store --key "__knit_cypher_to_sql_url__" --value "${eff_url}" --force
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
