#!/bin/bash

_KNIT_SPACK_VERSION="v0.23.0"

export SPACK_DISABLE_LOCAL_CONFIG=true
export SPACK_USER_CACHE_PATH=/tmp/spack

# ------------------------------------------------------------------------------
# Clone Spack from Github and checkout the specified ref (commit hash or tag).
#
# @param ref Commit hash or tag (default to _KNIT_SPACK_VERSION).
# ------------------------------------------------------------------------------
_knit_spack_clone() {
    knit_info "Cloning Spack repository..."
    git clone https://github.com/spack/spack.git ${_KNIT_PREFIX}/spack > ${_KNIT_TRACE_FILE} 2>&1
    local ref=${1:-${_KNIT_SPACK_VERSION}}
    knit_pushd ${_KNIT_PREFIX}/spack
    knit_info "Checking out ${ref}..."
    git checkout $ref > ${_KNIT_TRACE_FILE} 2>&1
    knit_popd
}

_knit_spack_install() {
    (
        source ${_KNIT_PREFIX}/spack/share/spack/setup-env.sh
        for arg in "$@"; do
            knit_info "Installing package ${arg}..."
            _knit_framed "spack install ${arg}"
        done
    )
}
