#!/bin/bash

## @file sched_flux.sh

# ------------------------------------------------------------------------------
# @fn _knit_sched_flux_walltime_fsd()
#
# Convert an HH:MM:SS walltime to a Flux Standard Duration (FSD) in whole
# seconds with a trailing "s", e.g. "01:00:00" -> "3600s". Flux --time-limit
# reads a bare number as minutes, so the explicit "s" suffix avoids that
# ambiguity. A value that is not HH:MM:SS is printed verbatim so a site that
# already writes a valid FSD (e.g. "30m") is passed through unchanged.
#
# @param[in] walltime Walltime string, normally "HH:MM:SS".
# ------------------------------------------------------------------------------
_knit_sched_flux_walltime_fsd() {
    local walltime="$1"
    if [[ "${walltime}" =~ ^([0-9]+):([0-5][0-9]):([0-5][0-9])$ ]]; then
        local h="${BASH_REMATCH[1]}"
        local m="${BASH_REMATCH[2]}"
        local s="${BASH_REMATCH[3]}"
        printf '%ss\n' "$(( 10#${h} * 3600 + 10#${m} * 60 + 10#${s} ))"
    else
        printf '%s\n' "${walltime}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_flux_directives()
#
# Emit the "# flux:" directive lines for a resolved job. A Flux batch directive
# is a comment whose body starts with "flux:", the analogue of "#SBATCH"/"#PBS".
# Knit allocates whole nodes exclusively, so --exclusive is always set with
# --nodes. Job stdout/stderr are fixed to <jobdir>/.stdout and <jobdir>/.stderr.
# The per-node core count is not emitted: the allocation is whole-node
# exclusive, so per-node task sizing belongs to the launcher (flux run), not the
# allocation. Optional fields (bank, queue, gpus) are emitted only when set.
#
# @param[in] arr_name Name of the resolved-options associative array.
# @param[in] jobdir   Job directory (for the --output/--error paths).
# ------------------------------------------------------------------------------
_knit_sched_flux_directives() {
    local -n resolved="$1"
    local jobdir="$2"

    printf '# flux: --job-name=%s\n' "${resolved[job-name]}"
    # Flux accounting maps an account to a bank; emitted only when set so a
    # machine without flux-accounting is unaffected.
    if [[ -n "${resolved[account]}" ]]; then
        printf '# flux: --bank=%s\n' "${resolved[account]}"
    fi
    if [[ -n "${resolved[queue]}" ]]; then
        printf '# flux: --queue=%s\n' "${resolved[queue]}"
    fi
    printf '# flux: --nodes=%s\n' "${resolved[nodes]}"
    printf '# flux: --exclusive\n'

    local fsd
    fsd="$(_knit_sched_flux_walltime_fsd "${resolved[walltime]}")"
    printf '# flux: --time-limit=%s\n' "${fsd}"

    if [[ "${resolved[gpus-per-node]}" != "0" ]]; then
        printf '# flux: --gpus-per-slot=%s\n' "${resolved[gpus-per-node]}"
    fi

    printf '# flux: --output=%s\n' "${jobdir}/.stdout"
    printf '# flux: --error=%s\n' "${jobdir}/.stderr"
    if [[ -n "${resolved[extra-args]}" ]]; then
        printf '# flux: %s\n' "${resolved[extra-args]}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_flux_parse_jobid()
#
# Reduce flux batch output to the bare job id by keeping the first line and
# trimming surrounding whitespace. The id is a single opaque FLUID token (e.g.
# "f2QzoR8xF"), so no further splitting is done.
#
# @param[in] raw Raw stdout captured from flux batch.
# ------------------------------------------------------------------------------
_knit_sched_flux_parse_jobid() {
    local raw="$1"
    raw="${raw%%$'\n'*}"
    # Trim leading and trailing whitespace.
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    printf '%s\n' "${raw}"
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_flux_submit_cmdline()
#
# Build the flux batch submission command into a caller-provided array, passed by
# name: "flux batch <script>". Flux has no submit-time blocking flag (see
# _knit_sched_flux_submit for how the wait option is honoured), so the argv does
# not depend on the resolved "wait" option.
#
# @param[out] argv_name Name of the array to fill with the submission argv.
# @param[in] arr_name  Name of the resolved-options associative array (unused).
# @param[in] script    Path to the batch script to submit.
# ------------------------------------------------------------------------------
_knit_sched_flux_submit_cmdline() {
    # shellcheck disable=SC2178 # nameref to the caller's array
    local -n _submit_argv="$1"
    local script="$3"

    _submit_argv=(flux batch "${script}")
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_flux_submit()
#
# Submit an already-written batch script with flux batch and print the resulting
# job id. Flux has no sbatch --wait equivalent at submit time, so when the
# resolved "wait" flag is "true" the function blocks after submission with
# `flux job status <id>` (a real blocking wait; see _knit_sched_flux_wait). The
# --output/--error redirection is carried by the script's directives, so the job
# directory is not needed here.
#
# @param[in] arr_name Name of the resolved-options associative array.
# @param[in] script   Path to the batch script to submit.
# @param[in] jobdir   Job directory (unused; redirection is set via directives).
# ------------------------------------------------------------------------------
_knit_sched_flux_submit() {
    local arr_name="$1"
    local script="$2"

    local -a cmd=()
    _knit_sched_flux_submit_cmdline cmd "${arr_name}" "${script}"

    local out
    out="$("${cmd[@]}")" || return 1

    local id
    id="$(_knit_sched_flux_parse_jobid "${out}")"

    local -n resolved="${arr_name}"
    if [[ "${resolved[wait]}" == "true" ]]; then
        _knit_sched_flux_wait "${id}" || true
    fi
    printf '%s\n' "${id}"
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_flux_wait()
#
# Block until the Flux job completes. `flux job status <id>` blocks until the job
# reaches a terminal state and exits with the job's largest task exit code. It
# works for any job (it does not need the "waitable" flag), so unlike the
# Slurm/PBS backends this is a single blocking call, not a poll loop. The job's
# knit terminal state is read from the DB by the caller afterwards.
#
# @param[in] jobid Flux job id (from the job's .job.id).
# ------------------------------------------------------------------------------
_knit_sched_flux_wait() {
    local jobid="$1"
    flux job status "${jobid}" 2>/dev/null
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_flux_cancel()
#
# Cancel a Flux job with flux cancel. Flux sends SIGTERM then SIGKILL after a
# grace period, which lets the batch shell's pre-termination handler record the
# job "killed" (see _knit_job_killed_trap). Cancelling an already-finished or
# unknown job may print a diagnostic; that is not treated as a knit-level failure
# since the job is gone.
#
# @param[in] jobid Flux job id (from the job's .job.id).
# ------------------------------------------------------------------------------
_knit_sched_flux_cancel() {
    local jobid="$1"
    flux cancel "${jobid}" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_flux_hostfile()
#
# Print the host list for a Flux job, one hostname per line. `flux hostlist`
# expands a job's hostlist; the source "local" reads the enclosing job from
# $FLUX_JOB_ID, and "-ed '\n'" expands every host with a newline delimiter. This
# is a per-node list. If the call fails (e.g. not running inside a Flux job),
# warn and fall back to this machine's hostname, exactly as the other backends
# do.
# ------------------------------------------------------------------------------
_knit_sched_flux_hostfile() {
    local hosts
    if hosts="$(flux hostlist -ed '\n' local 2>/dev/null)" \
    && [[ -n "${hosts}" ]]; then
        printf '%s\n' "${hosts}"
    else
        knit_warning "Flux hostlist is unavailable; reporting the local hostname only."
        hostname
    fi
}
