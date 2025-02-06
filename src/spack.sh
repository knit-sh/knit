#!/bin/bash

KNIT_SPACK_VERSION="v0.23.0"
__KNIT_SPACK_ROOT="${_KNIT_PREFIX}/spack"

#export SPACK_DISABLE_LOCAL_CONFIG=true
#export SPACK_USER_CACHE_PATH=/tmp/spack
export SPACK_USER_CONFIG_PATH="${_KNIT_PREFIX}/.spack"

# ------------------------------------------------------------------------------
# Clone Spack from Github and checkout the specified ref (commit hash or tag).
#
# @param ref Commit hash or tag (default to _KNIT_SPACK_VERSION).
# ------------------------------------------------------------------------------
_knit_bootstrap_spack() {
    knit_trace "Cloning spack repository..."
    git clone https://github.com/spack/spack.git "${__KNIT_SPACK_ROOT}" > "${_KNIT_TRACE_FILE}" 2>&1
    local ref="${1:-${KNIT_SPACK_VERSION}}"
    knit_pushd "${_KNIT_PREFIX}/spack"
    knit_trace "Checking out spack ${ref}..."
    git checkout "$ref" > "${_KNIT_TRACE_FILE}" 2>&1
    knit_popd
}

# ------------------------------------------------------------------------------
# Install the specified specs using spack.
#
# @param ... Specs to install.
# ------------------------------------------------------------------------------
_knit_spack_install() {
    (
        # shellcheck disable=SC1091
        source "${__KNIT_SPACK_ROOT}/share/spack/setup-env.sh"
        local spec
        for spec in "$@"; do
            knit_info "Installing package ${spec}..."
            _knit_framed "spack install ${spec}"
        done
    )
}
