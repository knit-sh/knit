#!/bin/bash

## @file sched_pbs.sh

# ------------------------------------------------------------------------------
# @fn _knit_sched_pbs_directives()
#
# Emit the #PBS directive lines for a resolved job. Knit allocates whole nodes
# exclusively: the resource request is one chunk per node (-l select=<nodes>)
# with -l place=excl. When the per-node core count is known it pins ncpus and
# mpiprocs on the chunk (mpiprocs is what populates $PBS_NODEFILE, i.e. the
# launchable slots); otherwise the chunk takes the site defaults. Job
# stdout/stderr are fixed to <jobdir>/.stdout and <jobdir>/.stderr. Optional
# fields (account, project, queue, gpus) are emitted only when set.
#
# @param arr_name Name of the resolved-options associative array.
# @param jobdir   Job directory (for the -o/-e paths).
# ------------------------------------------------------------------------------
_knit_sched_pbs_directives() {
    local -n resolved="$1"
    local jobdir="$2"

    printf '#PBS -N %s\n' "${resolved[job-name]}"
    if [[ -n "${resolved[account]}" ]]; then
        printf '#PBS -A %s\n' "${resolved[account]}"
    fi
    if [[ -n "${resolved[project]}" ]]; then
        printf '#PBS -P %s\n' "${resolved[project]}"
    fi
    if [[ -n "${resolved[queue]}" ]]; then
        printf '#PBS -q %s\n' "${resolved[queue]}"
    fi

    local chunk="select=${resolved[nodes]}"
    if [[ -n "${resolved[cpus-per-node]}" ]]; then
        chunk+=":ncpus=${resolved[cpus-per-node]}:mpiprocs=${resolved[cpus-per-node]}"
    fi
    if [[ "${resolved[gpus-per-node]}" != "0" ]]; then
        chunk+=":ngpus=${resolved[gpus-per-node]}"
    fi
    printf '#PBS -l %s\n' "${chunk}"

    printf '#PBS -l walltime=%s\n' "${resolved[walltime]}"
    printf '#PBS -l place=excl\n'
    printf '#PBS -o %s\n' "${jobdir}/.stdout"
    printf '#PBS -e %s\n' "${jobdir}/.stderr"
    if [[ -n "${resolved[extra-args]}" ]]; then
        printf '#PBS %s\n' "${resolved[extra-args]}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_pbs_parse_jobid()
#
# Reduce a qsub job id to its bare sequence number by keeping the first output
# line and stripping the server suffix, e.g. "98765.pbsserver" -> "98765".
#
# @param raw Raw stdout captured from qsub.
# ------------------------------------------------------------------------------
_knit_sched_pbs_parse_jobid() {
    local raw="$1"
    raw="${raw%%$'\n'*}"
    printf '%s\n' "${raw%%.*}"
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_pbs_submit()
#
# Submit an already-written batch script with qsub and print the resulting job
# id. When the resolved "wait" flag is "true", qsub is run with "-W block=true"
# so it blocks until the job completes (its exit status becomes qsub's). The
# -o/-e redirection is carried by the script's directives, so the job directory
# is not needed here.
#
# @param arr_name Name of the resolved-options associative array.
# @param script   Path to the batch script to submit.
# @param jobdir   Job directory (unused; redirection is set via directives).
# ------------------------------------------------------------------------------
_knit_sched_pbs_submit() {
    local -n resolved="$1"
    local script="$2"

    local -a cmd=(qsub)
    if [[ "${resolved[wait]}" == "true" ]]; then
        cmd+=(-W block=true)
    fi
    cmd+=("${script}")

    local out
    out="$("${cmd[@]}")" || return 1
    _knit_sched_pbs_parse_jobid "${out}"
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_pbs_wait()
#
# Block until PBS no longer runs the job. OpenPBS ships no `qwait`, so poll
# `qstat` every _KNIT_SCHED_POLL_INTERVAL seconds. `-x` also reports finished
# jobs from history when it is enabled. A job that is gone (unknown/purged, so no
# job_state line) is treated as finished; a job whose job_state is "E" (exiting,
# its Exit_status is already set) or "F" (finished) is terminal. "E" is treated
# as terminal because a job can linger in it after its script has stopped
# running, and waiting for "F" would then block far longer than the job runs.
# The job's knit terminal state is read from the DB by the caller afterwards.
#
# @param jobid PBS job id (from the job's .job.id).
# ------------------------------------------------------------------------------
_knit_sched_pbs_wait() {
    local jobid="$1"
    local state
    while true; do
        state="$(qstat -x -f "${jobid}" 2>/dev/null \
            | awk -F'=' '/job_state/ { gsub(/ /, "", $2); print $2; exit }')"
        [[ -z "${state}" ]] && return 0
        [[ "${state}" == "E" || "${state}" == "F" ]] && return 0
        sleep "${_KNIT_SCHED_POLL_INTERVAL}"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_pbs_cancel()
#
# Cancel a PBS job with qdel. qdel sends SIGTERM then SIGKILL, letting the batch
# shell's pre-termination handler record the job "killed" (see
# _knit_job_killed_trap). A qdel of an already-finished/unknown job may print a
# diagnostic; that is not treated as a knit-level failure since the job is gone.
#
# @param jobid PBS job id (from the job's .job.id).
# ------------------------------------------------------------------------------
_knit_sched_pbs_cancel() {
    local jobid="$1"
    qdel "${jobid}" 2>/dev/null || true
}
