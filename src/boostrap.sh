#!/bin/bash

## @file boostrap.sh

# ------------------------------------------------------------------------------
# Prefix directory for Knit's local installation.
# ------------------------------------------------------------------------------
_KNIT_PREFIX="$(pwd)/.knit"

# ------------------------------------------------------------------------------
# @var _KNIT_IS_BOOTSTRAPPED
#
# Cache for _knit_is_bootstrapped(). Empty means "not yet checked"; "1" means
# the positive result has been confirmed and the filesystem need not be
# re-checked.
# ------------------------------------------------------------------------------
declare -g _KNIT_IS_BOOTSTRAPPED
_KNIT_IS_BOOTSTRAPPED=""

# ------------------------------------------------------------------------------
# @fn _knit_is_bootstrapped()
#
# Return 0 if the experiment has been bootstrapped (i.e. _KNIT_PREFIX exists),
# 1 otherwise.
#
# The positive result is cached in _KNIT_IS_BOOTSTRAPPED so that repeated
# calls within the same session avoid redundant filesystem accesses.  The
# negative result is never cached: the directory may be created at any moment
# by a bootstrap invocation in the same session.
# ------------------------------------------------------------------------------
_knit_is_bootstrapped() {
    if [[ "${_KNIT_IS_BOOTSTRAPPED}" == "1" ]]; then
        return 0
    fi
    if [[ -d "${_KNIT_PREFIX}" ]]; then
        _KNIT_IS_BOOTSTRAPPED="1"
        return 0
    fi
    return 1
}

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
knit_with_optional "project:string" "" "Name of the project to use when submitting jobs."
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
