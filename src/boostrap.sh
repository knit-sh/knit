#!/bin/bash

_KNIT_PREFIX="$(pwd)/.knit"

# ------------------------------------------------------------------------------
__knit_bootstrap_on_exit() {
    if [ -z "${__KNIT_BOOTSTRAP_COMPLETED}" ]; then
        knit_warning "Bootstrap did not complete successfully, deleting ${_KNIT_PREFIX}"
        rm -rf "${_KNIT_PREFIX}" > ${_KNIT_TRACE_FILE} 2>&1
    fi
}

# ------------------------------------------------------------------------------
# Bootstrap the Knit framework.
#
# @param ... Arguments for bootstrap.
# ------------------------------------------------------------------------------
knit_register _knit_bootstrap "bootstrap" "Bootstrap the Knit framework."
knit_with_flag "spack" "Whether to download spack."
knit_with_optional "project" "" "Name of the project to use when submitting jobs."
_knit_bootstrap() {
    # Create directory
    if [ -d "${_KNIT_PREFIX}" ]; then
        knit_fatal "Knit is already bootstrapped."
    fi
    knit_trace "Creating ${_KNIT_PREFIX} directory"
    mkdir "${_KNIT_PREFIX}" > ${_KNIT_TRACE_FILE} 2>&1
    trap __knit_bootstrap_on_exit EXIT

    knit_trace "Checking whether we need spack..."
    local need_spack=$(knit_get_parameter "spack" "$@")
    if [[ "${need_spack}" == "true" ]]; then
        knit_trace "Spack is needed, version ${KNIT_SPACK_VERSION} will be installed."
        _knit_bootstrap_spack
    else
        knit_trace "Spack is not needed."
    fi

    knit_trace "Bootstrapping sqlite..."
    _knit_bootstrap_sqlite

    # Bootstrap completed successfully
    __KNIT_BOOTSTRAP_COMPLETED="true"
}
knit_done
