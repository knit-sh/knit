#!/bin/bash

## @file sched_local.sh

# ------------------------------------------------------------------------------
# @fn _knit_sched_local_directives()
#
# Emit the batch directives for the local backend. The local backend runs the
# job as a background process with no scheduler, so there are no directives and
# this prints nothing. It exists so every backend honours the same contract.
#
# @param arr_name Name of the resolved-options associative array (unused).
# @param jobdir   Job directory (unused).
# ------------------------------------------------------------------------------
_knit_sched_local_directives() {
    :
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_local_submit()
#
# Submit a batch script on a machine with no scheduler by running it as a
# detached background process via _knit_submit_local. Job stdout/stderr are
# redirected to <jobdir>/.stdout and <jobdir>/.stderr, and the resolved walltime
# (if any) caps the run. When the resolved "wait" flag is "true", block until the
# process finishes. Prints the process id to stdout.
#
# @param arr_name Name of the resolved-options associative array.
# @param script   Path to the batch script to run.
# @param jobdir   Job directory holding .stdout/.stderr.
# ------------------------------------------------------------------------------
_knit_sched_local_submit() {
    local -n resolved="$1"
    local script="$2"
    local jobdir="$3"

    local -a launch_args=(
        --stdout "${jobdir}/.stdout"
        --stderr "${jobdir}/.stderr"
    )
    if [[ -n "${resolved[walltime]}" ]]; then
        launch_args+=(--walltime "${resolved[walltime]}")
    fi

    local pid
    pid="$(_knit_submit_local "${launch_args[@]}" -- bash "${script}")"

    if [[ "${resolved[wait]}" == "true" ]]; then
        _knit_wait_local "${pid}"
    fi

    printf '%s\n' "${pid}"
}
