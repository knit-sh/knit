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
