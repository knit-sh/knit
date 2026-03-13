#!/bin/bash

# ------------------------------------------------------------------------------
# Prefix directory for Knit's local installation.
# ------------------------------------------------------------------------------
_KNIT_PREFIX="$(pwd)/.knit"

# ------------------------------------------------------------------------------
# @fn __knit_bootstrap_on_exit()
#
# Clean up on exit if bootstrap did not complete successfully.
# ------------------------------------------------------------------------------
__knit_bootstrap_on_exit() {
    if [ -z "${__KNIT_BOOTSTRAP_COMPLETED}" ]; then
        knit_warning "Bootstrap did not complete successfully, deleting ${_KNIT_PREFIX}"
        rm -rf "${_KNIT_PREFIX}" > "${_KNIT_TRACE_FILE}" 2>&1
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
# ------------------------------------------------------------------------------
# @fn _knit_bootstrap()
#
# Bootstrap the Knit framework.
#
# @param ... Arguments for bootstrap.
# ------------------------------------------------------------------------------
_knit_bootstrap() {
    local project
    local need_spack
    project="$(knit_get_parameter "project" "$@")"
    need_spack="$(knit_get_parameter "spack" "$@")"

    # Create directory
    if [ -d "${_KNIT_PREFIX}" ]; then
        knit_fatal "Knit is already bootstrapped."
    fi
    knit_trace "Creating ${_KNIT_PREFIX} directory"
    mkdir "${_KNIT_PREFIX}" > "${_KNIT_TRACE_FILE}" 2>&1
    trap __knit_bootstrap_on_exit EXIT

    if [[ "${need_spack}" == "true" ]]; then
        knit_trace "Bootstrapping spack..."
        _knit_bootstrap_spack
    fi

    knit_trace "Bootstrapping sqlite..."
    _knit_bootstrap_sqlite

    knit_trace "Writing initial metadata..."
    knit metadata store --key "__project__" --value "${project}"

    # Bootstrap completed successfully
    __KNIT_BOOTSTRAP_COMPLETED="true"
}
knit_done
