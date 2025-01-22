#!/bin/bash

_KNIT_PREFIX="$(pwd)/.knit"

# ------------------------------------------------------------------------------
# Bootstrap the Knit framework.
#
# @param ... Arguments for bootstrap.
# ------------------------------------------------------------------------------
_knit_bootstrap() {
    # Check if the first argument is -h or --help
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        _knit_print_bootstrap_usage
        exit 0
    fi
    # Create directory
    if [ -d "${_KNIT_PREFIX}" ]; then
        knit_fatal "Knit is already bootstrapped."
    fi
    knit_trace "Creating ${_KNIT_PREFIX} directory"
    mkdir "${_KNIT_PREFIX}" > ${_KNIT_TRACE_FILE} 2>&1

    _knit_bootstrap_spack
    _knit_bootstrap_jq
}
