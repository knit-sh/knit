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

# ------------------------------------------------------------------------------
# @fn _knit_sched_local_submit_cmdline()
#
# Build the local backend's submission command into a caller-provided array,
# passed by name: "bash <script>". The local backend runs this in the background
# via _knit_submit_local, which adds stdout/stderr redirection and an optional
# walltime cap; those are knit-managed conveniences rather than part of the job
# command, so the recorded/traced command is the bare "bash <script>".
#
# @param argv_name Name of the array to fill with the submission argv.
# @param arr_name  Name of the resolved-options associative array (unused).
# @param script    Path to the batch script to run.
# ------------------------------------------------------------------------------
_knit_sched_local_submit_cmdline() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n _submit_argv="$1"
    local script="$3"
    _submit_argv=(bash "${script}")
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_local_wait()
#
# Block until a locally-launched job process exits. The `job wait` command runs
# in a different process than the `submit` that launched the job, so the pid is
# not a child of this shell and the `wait` builtin cannot be used; instead poll
# `kill -0` (a liveness probe that sends no signal) every
# _KNIT_SCHED_POLL_INTERVAL seconds until the process is gone. A pid that is not
# a positive integer, or is already gone, returns immediately.
#
# @param pid Process id recorded in the job's .job.id by the local backend.
# ------------------------------------------------------------------------------
_knit_sched_local_wait() {
    local pid="$1"
    [[ "${pid}" =~ ^[0-9]+$ ]] || return 0
    while kill -0 "${pid}" 2>/dev/null; do
        sleep "${_KNIT_SCHED_POLL_INTERVAL}"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_local_cancel()
#
# Cancel a locally-launched job by sending SIGTERM to its process. SIGTERM (not
# SIGKILL) is used deliberately: the running job installs a handler for it (see
# _knit_job_killed_trap) so it can record itself "killed" before exiting. A pid
# that is not a positive integer, or a process that is already gone, is treated
# as nothing to do.
#
# @param pid Process id recorded in the job's .job.id by the local backend.
# ------------------------------------------------------------------------------
_knit_sched_local_cancel() {
    local pid="$1"
    [[ "${pid}" =~ ^[0-9]+$ ]] || return 0
    kill "${pid}" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_local_hostfile()
#
# Print the host list for the local backend. A local run has no scheduler and no
# node allocation, so it runs on a single host: print this machine's hostname.
# ------------------------------------------------------------------------------
_knit_sched_local_hostfile() {
    hostname
}
