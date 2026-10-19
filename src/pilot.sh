#!/bin/bash

## @file pilot.sh

# ------------------------------------------------------------------------------
# Version of knit-pilotd to provision.
# ------------------------------------------------------------------------------
_KNIT_PILOTD_VERSION="0.1.0"

# ------------------------------------------------------------------------------
# Path to the knit-pilotd executable.
# ------------------------------------------------------------------------------
_KNIT_PILOTD_EXE="${_KNIT_PREFIX}/knit-pilotd/bin/knit-pilotd"

# ------------------------------------------------------------------------------
# @fn _knit_pilotd_url()
#
# Print the download URL for a knit-pilotd release tarball given its version. The
# release tag is the version prefixed with "v" and the asset is named after the
# version, e.g. version 0.1.0 ->
# .../download/v0.1.0/knit-pilotd-0.1.0.tar.gz.
#
# @param[in] version knit-pilotd release version (without the leading "v").
# ------------------------------------------------------------------------------
_knit_pilotd_url() {
    local version="$1"
    printf 'https://github.com/knit-sh/knit-pilotd/releases/download/v%s/knit-pilotd-%s.tar.gz' \
        "${version}" "${version}"
}

# ------------------------------------------------------------------------------
# @fn _knit_build_pilotd()
#
# Download the knit-pilotd release tarball, build it, and install it under
# .knit/knit-pilotd. The daemon is a single dependency-free POSIX C file, so the
# build needs only a C compiler: the release tarball ships a hand-written
# configure script (no autotools), built out of tree with
# "../configure --prefix=... && make && make install".
#
# @param[in] version knit-pilotd release version to build.
# @param[in] url URL of the knit-pilotd release tarball.
# ------------------------------------------------------------------------------
_knit_build_pilotd() {
    local version="$1"
    local url="$2"
    local srcname="knit-pilotd-${version}"
    local tarball="${srcname}.tar.gz"

    knit_pushd "${_KNIT_PREFIX}"

    knit_trace "Downloading knit-pilotd source..."
    # -f makes an HTTP error status (e.g. a rate-limited GitHub response) a clean
    # failure instead of a saved error body that would later fail to extract;
    # --retry rides out a transient network error. A GITHUB_TOKEN/GH_TOKEN, when
    # set, lifts the low anonymous rate limit that CI runners share by address.
    local -a curl_args=(-fL --retry 3 --retry-delay 2 -o "${tarball}")
    local gh_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    [[ -n "${gh_token}" ]] && curl_args+=(-H "Authorization: Bearer ${gh_token}")
    if ! knit_framed_run "knit-pilotd: download" \
            curl "${curl_args[@]}" "${url}" ; then
        knit_fatal "Could not download knit-pilotd from ${url}. See ${_KNIT_TRACE_FILE} for more information."
    fi

    knit_trace "Extracting knit-pilotd source..."
    if ! knit_framed_run "knit-pilotd: extract" \
            tar -xzf "${tarball}" ; then
        knit_fatal "Could not extract knit-pilotd sources. See ${_KNIT_TRACE_FILE} for more information."
    fi

    knit_trace "Building knit-pilotd..."
    mkdir "${srcname}/build"
    knit_pushd "${srcname}/build"
    if ! knit_framed_run "knit-pilotd: configure" \
            ../configure --prefix="${_KNIT_PREFIX}/knit-pilotd" ; then
        knit_fatal "Could not configure knit-pilotd. See ${_KNIT_TRACE_FILE} for more information."
    fi
    if ! knit_framed_run "knit-pilotd: make" \
            make ; then
        knit_fatal "Could not build knit-pilotd. See ${_KNIT_TRACE_FILE} for more information."
    fi
    if ! knit_framed_run "knit-pilotd: make install" \
            make install ; then
        knit_fatal "Could not install knit-pilotd. See ${_KNIT_TRACE_FILE} for more information."
    fi
    knit_popd # from "${srcname}/build"

    knit_trace "Deleting knit-pilotd sources and archive..."
    rm -rf "${srcname}" "${tarball}" 2>"${_KNIT_TRACE_FILE}"

    knit_popd # from "${_KNIT_PREFIX}"
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_pilotd()
#
# Provision knit-pilotd at _KNIT_PILOTD_EXE. Resolves the version (the pinned
# default when empty) and the download URL (derived from the version when empty),
# builds and installs the daemon, and records provenance metadata (the version
# and URL provisioned). The daemon links no libraries, so this is independent of
# the other provisioning steps.
#
# @param[in] version knit-pilotd version to provision; empty uses the pinned default.
# @param[in] url Override URL for the release tarball; empty derives it from the version.
# ------------------------------------------------------------------------------
_knit_bootstrap_pilotd() {
    local version="${1:-}"
    local url="${2:-}"
    if [[ -z "${version}" ]]; then
        version="${_KNIT_PILOTD_VERSION}"
    fi
    if [[ -z "${url}" ]]; then
        url="$(_knit_pilotd_url "${version}")"
    fi

    _knit_build_pilotd "${version}" "${url}"

    knit_trace "Storing knit-pilotd provenance metadata..."
    knit metadata store --key "__knit_pilotd_version__" --value "${version}"
    knit metadata store --key "__knit_pilotd_url__"     --value "${url}"
}
