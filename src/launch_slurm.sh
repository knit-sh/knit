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
#   --cpus-per-proc N  -> --cpus-per-task N
#   --bind V           -> --cpu-bind=<V>   (V normalized by _knit_launch_bind_value)
#   --gpus-per-proc N  -> --gpus-per-task N
#   --gpu-bind V       -> --gpu-bind=V     (value passed through verbatim)
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
# @param[out] argv_name Name of the array to fill with the launcher argument vector.
# @param[in] opts_name Name of the resolved placement-options associative array
#                  (keys: procs, procs-per-node, hostnames, launcher-args).
# ------------------------------------------------------------------------------
_knit_launch_slurm_cmdline() {
    local -n _launch_argv="$1"
    # shellcheck disable=SC2178 # nameref to the caller's associative array
    local -n _launch_opts="$2"

    local procs="${_launch_opts[procs]:-}"
    local ppn="${_launch_opts[procs-per-node]:-}"
    local hosts="${_launch_opts[hostnames]:-}"
    local cpp="${_launch_opts[cpus-per-proc]:-}"
    local bind="${_launch_opts[bind]:-}"
    local gpp="${_launch_opts[gpus-per-proc]:-}"
    local gbind="${_launch_opts[gpu-bind]:-}"
    local extra="${_launch_opts[launcher-args]:-}"

    _launch_argv=(srun)
    [[ -n "${procs}" ]] && _launch_argv+=(--ntasks "${procs}")
    [[ -n "${ppn}" ]] && _launch_argv+=(--ntasks-per-node "${ppn}")
    if [[ -n "${hosts}" ]]; then
        local -a host_list
        IFS=',' read -r -a host_list <<< "${hosts}"
        _launch_argv+=(--nodelist "${hosts}" --nodes "${#host_list[@]}")
    fi
    [[ -n "${cpp}" ]] && _launch_argv+=(--cpus-per-task "${cpp}")
    if [[ -n "${bind}" ]]; then
        local __bind_val
        _knit_launch_bind_value __bind_val slurm "${bind}"
        _launch_argv+=("--cpu-bind=${__bind_val}")
    fi
    [[ -n "${gpp}" ]] && _launch_argv+=(--gpus-per-task "${gpp}")
    [[ -n "${gbind}" ]] && _launch_argv+=("--gpu-bind=${gbind}")
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
# @param[in] arr_name Name of the resolved placement-options associative array.
# @param[in] --       Literal separator.
# @param[in] ...      The worker command and its arguments.
# ------------------------------------------------------------------------------
_knit_launch_slurm_exec() {
    local arr_name="$1"
    shift
    [[ "$1" == "--" ]] && shift

    local -a launcher
    _knit_launch_slurm_cmdline launcher "${arr_name}"
    "${launcher[@]}" "$@"
}
