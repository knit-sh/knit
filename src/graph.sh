#!/bin/bash

## @file graph.sh

# ------------------------------------------------------------------------------
# Version of knit-graph to provision.
# ------------------------------------------------------------------------------
_KNIT_KNITGRAPH_VERSION="0.2.1"

# ------------------------------------------------------------------------------
# Path to the knit-graph executable.
# ------------------------------------------------------------------------------
_KNIT_KNITGRAPH_EXE="${_KNIT_PREFIX}/knit-graph/bin/knit-graph"

# ------------------------------------------------------------------------------
# @fn _knit_knitgraph_framed_run()
#
# Run a command with its combined stdout/stderr written to _KNIT_TRACE_FILE and,
# when KNIT_LOG_LEVEL is trace, also displayed live in a 10-line frame.
# Returns the exit status of the command.
#
# @param title Title shown on the frame's top border.
# @param ... Command and arguments to execute.
# ------------------------------------------------------------------------------
_knit_knitgraph_framed_run() {
    local title="$1"
    shift
    _knit_ensure_trace_file
    "$@" 2>&1 | tee "${_KNIT_TRACE_FILE}" | \
        knit_framed 10 -1 --title "${title}" --log-level trace --cleanup
    local -a pipe_status=("${PIPESTATUS[@]}")
    return "${pipe_status[0]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_knitgraph_url()
#
# Print the download URL for a knit-graph release tarball given its version. The
# release tag is the version prefixed with "v" and the asset is named after the
# version, e.g. version 0.2.0 -> .../download/v0.2.0/knit-graph-0.2.0.tar.gz.
#
# @param version knit-graph release version (without the leading "v").
# ------------------------------------------------------------------------------
_knit_knitgraph_url() {
    local version="$1"
    printf 'https://github.com/knit-sh/knit-graph/releases/download/v%s/knit-graph-%s.tar.gz' \
        "${version}" "${version}"
}

# ------------------------------------------------------------------------------
# @fn _knit_build_knitgraph()
#
# Download the knit-graph release tarball, build it against the SQLite that
# _knit_bootstrap_sqlite provisioned, and install it under .knit/knit-graph. The
# release tarball ships the pre-generated parser/scanner, so only a C compiler and
# the sqlite development files are needed (no autotools/bison/flex). When SQLite
# was built from source (_KNIT_SQLITE_PREFIX set), the build is pointed at it with
# --with-sqlite3, which adds the include/lib paths and an rpath so the installed
# binary finds libsqlite3 at runtime; when the system SQLite is used
# (_KNIT_SQLITE_PREFIX empty) its dev files are on the default search paths, so no
# --with-sqlite3 is passed.
#
# @param version knit-graph release version to build.
# @param url URL of the knit-graph release tarball.
# ------------------------------------------------------------------------------
_knit_build_knitgraph() {
    local version="$1"
    local url="$2"
    local srcname="knit-graph-${version}"
    local tarball="${srcname}.tar.gz"

    knit_pushd "${_KNIT_PREFIX}"

    knit_trace "Downloading knit-graph source..."
    # -f makes an HTTP error status (e.g. a rate-limited GitHub response) a clean
    # failure instead of a saved error body that would later fail to extract;
    # --retry rides out a transient network error. A GITHUB_TOKEN/GH_TOKEN, when
    # set, lifts the low anonymous rate limit that CI runners share by address.
    local -a curl_args=(-fL --retry 3 --retry-delay 2 -o "${tarball}")
    local gh_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    [[ -n "${gh_token}" ]] && curl_args+=(-H "Authorization: Bearer ${gh_token}")
    if ! _knit_knitgraph_framed_run "knit-graph: download" \
            curl "${curl_args[@]}" "${url}" ; then
        knit_fatal "Could not download knit-graph from ${url}. See ${_KNIT_TRACE_FILE} for more information."
    fi

    knit_trace "Extracting knit-graph source..."
    if ! _knit_knitgraph_framed_run "knit-graph: extract" \
            tar -xzf "${tarball}" ; then
        knit_fatal "Could not extract knit-graph sources. See ${_KNIT_TRACE_FILE} for more information."
    fi

    knit_trace "Building knit-graph..."
    mkdir "${srcname}/build"
    knit_pushd "${srcname}/build"
    local -a configure_args=( --prefix="${_KNIT_PREFIX}/knit-graph" )
    if [[ -n "${_KNIT_SQLITE_PREFIX}" ]]; then
        configure_args+=( --with-sqlite3="${_KNIT_SQLITE_PREFIX}" )
    fi
    if ! _knit_knitgraph_framed_run "knit-graph: configure" \
            ../configure "${configure_args[@]}" ; then
        knit_fatal "Could not configure knit-graph. See ${_KNIT_TRACE_FILE} for more information."
    fi
    if ! _knit_knitgraph_framed_run "knit-graph: make" \
            make ; then
        knit_fatal "Could not build knit-graph. See ${_KNIT_TRACE_FILE} for more information."
    fi
    if ! _knit_knitgraph_framed_run "knit-graph: make install" \
            make install ; then
        knit_fatal "Could not install knit-graph. See ${_KNIT_TRACE_FILE} for more information."
    fi
    knit_popd # from "${srcname}/build"

    knit_trace "Deleting knit-graph sources and archive..."
    rm -rf "${srcname}" "${tarball}" 2>"${_KNIT_TRACE_FILE}"

    knit_popd # from "${_KNIT_PREFIX}"
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_knitgraph()
#
# Provision knit-graph at _KNIT_KNITGRAPH_EXE. Resolves the version (the pinned
# default when empty) and the download URL (derived from the version when empty),
# builds and installs knit-graph, and records provenance metadata (the version
# and URL provisioned). knit-graph links against Knit's own sqlite, so the caller
# must have built sqlite from source first.
#
# @param version knit-graph version to provision; empty uses the pinned default.
# @param url Override URL for the release tarball; empty derives it from version.
# ------------------------------------------------------------------------------
_knit_bootstrap_knitgraph() {
    local version="${1:-}"
    local url="${2:-}"
    if [[ -z "${version}" ]]; then
        version="${_KNIT_KNITGRAPH_VERSION}"
    fi
    if [[ -z "${url}" ]]; then
        url="$(_knit_knitgraph_url "${version}")"
    fi

    _knit_build_knitgraph "${version}" "${url}"

    knit_trace "Storing knit-graph provenance metadata..."
    knit metadata store --key "__knit_graph_version__" --value "${version}"
    knit metadata store --key "__knit_graph_url__"     --value "${url}"
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_update_knitgraph()
#
# Update-mode handler for --knit-graph-version/--knit-graph-url. When a typed
# option differs from the stored value, remove the knit-graph install, rebuild it
# at the effective version/URL, and update the stored provenance
# (__knit_graph_version__/__knit_graph_url__). A typed version with no explicit
# URL re-derives the URL from that version, so a version bump also moves the
# download. A typed option equal to the stored value, or an untyped option, is a
# no-op.
#
# knit-graph links against Knit's own sqlite, so the sqlite build prefix is
# reconstructed from the current install (a symlink means the system sqlite, a
# real file the from-source build) before rebuilding.
#
# @param version Value typed for --knit-graph-version.
# @param url     Value typed for --knit-graph-url.
# @param ...     Raw argument tokens of this invocation (see
#                _KNIT_INVOCATION_RAW_ARGS), used to tell a typed option from a
#                defaulted one.
# @return 0 when knit-graph was re-provisioned, 1 when nothing changed.
# ------------------------------------------------------------------------------
_knit_bootstrap_update_knitgraph() {
    local version="$1"
    local url="$2"
    shift 2

    local version_typed="false" url_typed="false"
    _knit_arg_was_provided "knit-graph-version" "$@" && version_typed="true"
    _knit_arg_was_provided "knit-graph-url" "$@" && url_typed="true"
    [[ "${version_typed}" == "false" && "${url_typed}" == "false" ]] && return 1

    local stored_version stored_url
    _knit_metadata_get stored_version "__knit_graph_version__"
    _knit_metadata_get stored_url "__knit_graph_url__"

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
        eff_url="$(_knit_knitgraph_url "${eff_version}")"
    fi

    [[ "${differs}" == "false" ]] && return 1

    # Reconstruct the sqlite build prefix knit-graph must link against: a symlink
    # means the system sqlite (dev files on default paths, no --with-sqlite3), a
    # real file the from-source install.
    if [[ -L "${_KNIT_SQLITE_EXE}" ]]; then
        _KNIT_SQLITE_PREFIX=""
    else
        _KNIT_SQLITE_PREFIX="${_KNIT_PREFIX}/sqlite"
    fi

    knit_info "Re-provisioning knit-graph..."
    rm -rf "${_KNIT_PREFIX}/knit-graph"
    _knit_build_knitgraph "${eff_version}" "${eff_url}"
    knit metadata store --key "__knit_graph_version__" --value "${eff_version}" --force
    knit metadata store --key "__knit_graph_url__"     --value "${eff_url}" --force
    return 0
}

# shellcheck disable=SC2120
# ------------------------------------------------------------------------------
# @fn _knit_knit_graph()
#
# Invoke Knit's knit-graph installation. The dynamic-linker environment is
# scrubbed (via _knit_run_isolated) so an active user environment cannot make
# knit-graph load a different libsqlite3 than the one it was built against.
#
# @param ... Parameters to forward to the knit-graph command.
# ------------------------------------------------------------------------------
_knit_knit_graph() {
    _knit_run_isolated "${_KNIT_KNITGRAPH_EXE}" "$@"
}
