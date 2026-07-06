#!/bin/bash

## @file sched_slurm.sh

# ------------------------------------------------------------------------------
# @fn _knit_sched_slurm_directives()
#
# Emit the #SBATCH directive lines for a resolved job. Knit allocates whole nodes
# exclusively, so --exclusive is always set and --ntasks-per-node is pinned to the
# derived per-node core count (when known) so every core is a launchable slot.
# Job stdout/stderr are fixed to <jobdir>/.stdout and <jobdir>/.stderr. Optional
# fields (account, project/wckey, partition, gpus) are emitted only when set.
#
# @param arr_name Name of the resolved-options associative array.
# @param jobdir   Job directory (for the --output/--error paths).
# ------------------------------------------------------------------------------
_knit_sched_slurm_directives() {
    local -n resolved="$1"
    local jobdir="$2"

    printf '#SBATCH --job-name=%s\n' "${resolved[job-name]}"
    if [[ -n "${resolved[account]}" ]]; then
        printf '#SBATCH --account=%s\n' "${resolved[account]}"
    fi
    if [[ -n "${resolved[project]}" ]]; then
        printf '#SBATCH --wckey=%s\n' "${resolved[project]}"
    fi
    if [[ -n "${resolved[queue]}" ]]; then
        printf '#SBATCH --partition=%s\n' "${resolved[queue]}"
    fi
    printf '#SBATCH --nodes=%s\n' "${resolved[nodes]}"
    if [[ -n "${resolved[cpus-per-node]}" ]]; then
        printf '#SBATCH --ntasks-per-node=%s\n' "${resolved[cpus-per-node]}"
    fi
    printf '#SBATCH --time=%s\n' "${resolved[walltime]}"
    # Warn the batch shell before the walltime kill so the job can record itself
    # as "killed" (see _knit_job_killed_trap). B: targets the batch shell;
    # @<sec> is how many seconds before the limit to deliver the signal.
    printf '#SBATCH --signal=B:USR1@%s\n' "${_KNIT_SCHED_KILL_WARNING_SEC}"
    if [[ "${resolved[gpus-per-node]}" != "0" ]]; then
        printf '#SBATCH --gpus-per-node=%s\n' "${resolved[gpus-per-node]}"
    fi
    printf '#SBATCH --exclusive\n'
    printf '#SBATCH --output=%s\n' "${jobdir}/.stdout"
    printf '#SBATCH --error=%s\n' "${jobdir}/.stderr"
    if [[ -n "${resolved[extra-args]}" ]]; then
        printf '#SBATCH %s\n' "${resolved[extra-args]}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_slurm_parse_jobid()
#
# Extract the numeric job id from sbatch's output line
# "Submitted batch job <N>". Falls back to the last whitespace-separated token.
#
# @param raw Raw stdout captured from sbatch.
# ------------------------------------------------------------------------------
_knit_sched_slurm_parse_jobid() {
    local raw="$1"
    if [[ "${raw}" =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "${raw##* }"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_slurm_submit()
#
# Submit an already-written batch script with sbatch and print the resulting job
# id. When the resolved "wait" flag is "true", sbatch is run with --wait so it
# blocks until the job completes (its exit status becomes sbatch's). The
# --output/--error redirection is carried by the script's directives, so the job
# directory is not needed here.
#
# @param arr_name Name of the resolved-options associative array.
# @param script   Path to the batch script to submit.
# @param jobdir   Job directory (unused; redirection is set via directives).
# ------------------------------------------------------------------------------
_knit_sched_slurm_submit() {
    local -n resolved="$1"
    local script="$2"

    local -a cmd=(sbatch)
    if [[ "${resolved[wait]}" == "true" ]]; then
        cmd+=(--wait)
    fi
    cmd+=("${script}")

    local out
    out="$("${cmd[@]}")" || return 1
    _knit_sched_slurm_parse_jobid "${out}"
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_slurm_wait()
#
# Block until Slurm no longer lists the job as active. Slurm has no reliable
# blocking "wait for completion" primitive after submission: `scontrol wait_job`
# returns as soon as the job is allocated (not when it finishes), and `sbatch
# --wait` only applies at submit time. So poll `squeue` for the job id every
# _KNIT_SCHED_POLL_INTERVAL seconds until it produces no rows, which is true
# once the job has completed, failed, or been cancelled (a running or completing
# CG job still lists). The job's knit terminal state is read from the DB by the
# caller afterwards.
#
# @param jobid Slurm job id (from the job's .job.id).
# ------------------------------------------------------------------------------
_knit_sched_slurm_wait() {
    local jobid="$1"
    while squeue -h -j "${jobid}" -o '%T' 2>/dev/null | grep -q .; do
        sleep "${_KNIT_SCHED_POLL_INTERVAL}"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_slurm_cancel()
#
# Cancel a Slurm job with scancel. scancel sends SIGTERM (then SIGKILL after a
# grace period), which lets the batch shell's pre-termination handler record the
# job "killed" (see _knit_job_killed_trap). scancel exits 0 even for a job that
# has already finished, so no special-casing is needed here.
#
# @param jobid Slurm job id (from the job's .job.id).
# ------------------------------------------------------------------------------
_knit_sched_slurm_cancel() {
    local jobid="$1"
    scancel "${jobid}"
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_slurm_hostfile()
#
# Print the host list for a Slurm job, one hostname per line. Slurm exposes the
# allocation as a compressed nodelist ($SLURM_JOB_NODELIST, e.g. "node[01-03]")
# rather than a hostfile, so expand it with `scontrol show hostnames`, which
# prints one hostname per allocated node. This is a per-node list (not per-task):
# Slurm has no native per-slot hostfile, so a raw request yields the same
# per-node entries. If the nodelist is unset or the expansion fails (e.g. not
# running inside a Slurm job), warn and fall back to this machine's hostname.
# ------------------------------------------------------------------------------
_knit_sched_slurm_hostfile() {
    local nodelist="${SLURM_JOB_NODELIST:-${SLURM_NODELIST:-}}"
    local hosts
    if [[ -n "${nodelist}" ]] \
    && hosts="$(scontrol show hostnames "${nodelist}" 2>/dev/null)" \
    && [[ -n "${hosts}" ]]; then
        printf '%s\n' "${hosts}"
    else
        knit_warning "Slurm nodelist is unavailable; reporting the local hostname only."
        hostname
    fi
}
