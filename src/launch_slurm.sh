#!/bin/bash

## @file launch_slurm.sh

# ------------------------------------------------------------------------------
# The "slurm" launcher backend places an app's ranks with Slurm's srun. Unlike
# the MPI-native backends (openmpi/mpich), it is scheduler-integrated: srun talks
# to the surrounding Slurm allocation directly. It is never auto-detected — it is
# selectable only via --launcher slurm, the __launcher__ metadata, or a machine
# profile. It translates knit's minimal placement options into srun flags:
#
#   --procs N          -> --ntasks N
#   --procs-per-node M -> --ntasks-per-node M
#   --hostnames h0,h1  -> --nodelist h0,h1 --nodes k   (k = number of hosts)
#   --launcher-args …  -> appended verbatim after the placement flags
#
# Placement is resolved and validated upstream by the run dispatcher; this
# backend only formats the resolved triple into an argument vector. srun runs
# inside the surrounding job's allocation and forwards its environment to every
# task, so the ranks inherit the job's KNIT_* variables and the setup env.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# @fn _knit_launch_slurm_cmdline()
#
# Build the launcher argument vector for the slurm backend (the srun executable
# followed by its placement flags) into a caller-provided array, passed by name.
# Each placement flag is added only when the corresponding option is set. When
# --hostnames is given, the node count for --nodes is derived from the number of
# comma-separated hosts. Any --launcher-args string is word-split and appended
# verbatim.
#
# @param opts_name Name of the resolved placement-options associative array
#                  (keys: procs, procs-per-node, hostnames, launcher-args).
# @param argv_name Name of the array to fill with the launcher argument vector.
# ------------------------------------------------------------------------------
_knit_launch_slurm_cmdline() {
    # shellcheck disable=SC2178 # nameref to the caller's associative array
    local -n _launch_opts="$1"
    local -n _launch_argv="$2"

    local procs="${_launch_opts[procs]:-}"
    local ppn="${_launch_opts[procs-per-node]:-}"
    local hosts="${_launch_opts[hostnames]:-}"
    local extra="${_launch_opts[launcher-args]:-}"

    _launch_argv=(srun)
    [[ -n "${procs}" ]] && _launch_argv+=(--ntasks "${procs}")
    [[ -n "${ppn}" ]] && _launch_argv+=(--ntasks-per-node "${ppn}")
    if [[ -n "${hosts}" ]]; then
        local -a host_list
        IFS=',' read -r -a host_list <<< "${hosts}"
        _launch_argv+=(--nodelist "${hosts}" --nodes "${#host_list[@]}")
    fi
    if [[ -n "${extra}" ]]; then
        local -a extra_args
        read -r -a extra_args <<< "${extra}"
        _launch_argv+=("${extra_args[@]}")
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_launch_slurm_exec()
#
# Run srun with the translated placement flags followed by the worker command,
# and return its exit status. The worker command is everything after a literal
# "--". The launcher argv is built by _knit_launch_slurm_cmdline.
#
# @param arr_name Name of the resolved placement-options associative array.
# @param --       Literal separator.
# @param ...      The worker command and its arguments.
# ------------------------------------------------------------------------------
_knit_launch_slurm_exec() {
    local arr_name="$1"
    shift
    [[ "$1" == "--" ]] && shift

    local -a launcher
    _knit_launch_slurm_cmdline "${arr_name}" launcher
    "${launcher[@]}" "$@"
}
