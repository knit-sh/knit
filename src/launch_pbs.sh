#!/bin/bash

## @file launch_pbs.sh

# ------------------------------------------------------------------------------
# The "pbs" launcher backend places an app's ranks with the PBS mpiexec wrapper
# (Hydra-based, as shipped with PBS Pro / OpenPBS). Unlike the MPI-native
# backends (openmpi/mpich), it is scheduler-integrated: the PBS mpiexec wrapper
# reads $PBS_NODEFILE from the surrounding allocation. It is never auto-detected
# — it is selectable only via --launcher pbs, the __launcher__ metadata, or a
# machine profile. It translates knit's minimal placement options into Hydra
# flags:
#
#   --procs N          -> -n N
#   --procs-per-node M -> -ppn M
#   --hostnames h0,h1  -> -hosts h0,h1
#   --bind V           -> -bind-to <V>   (V normalized by _knit_launch_bind_value)
#   --launcher-args …  -> appended verbatim after the placement flags
#
# The Hydra-based wrapper has no native flag for CPUs-per-rank (--cpus-per-proc)
# or GPU placement (--gpus-per-proc / --gpu-bind), so those are warned about and
# skipped; reach them through --launcher-args.
#
# Placement is resolved and validated upstream by the run dispatcher; this
# backend only formats the resolved triple into an argument vector. The wrapper
# runs inside the surrounding job's allocation and forwards its environment to
# every rank, so the ranks inherit the job's KNIT_* variables and the setup env.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# @fn _knit_launch_pbs_cmdline()
#
# Build the launcher argument vector for the pbs backend (the mpiexec executable
# followed by its placement flags) into a caller-provided array, passed by name.
# Each placement flag is added only when the corresponding option is set; any
# --launcher-args string is word-split and appended verbatim.
#
# @param[out] argv_name Name of the array to fill with the launcher argument vector.
# @param[in] opts_name Name of the resolved placement-options associative array
#                  (keys: procs, procs-per-node, hostnames, launcher-args).
# ------------------------------------------------------------------------------
_knit_launch_pbs_cmdline() {
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

    _launch_argv=(mpiexec)
    [[ -n "${procs}" ]] && _launch_argv+=(-n "${procs}")
    [[ -n "${ppn}" ]] && _launch_argv+=(-ppn "${ppn}")
    [[ -n "${hosts}" ]] && _launch_argv+=(-hosts "${hosts}")
    [[ -n "${cpp}" ]] && \
        knit_warning "pbs: --cpus-per-proc has no native Hydra flag; ignoring (use --launcher-args)."
    if [[ -n "${bind}" ]]; then
        local __bind_val
        _knit_launch_bind_value __bind_val pbs "${bind}"
        _launch_argv+=(-bind-to "${__bind_val}")
    fi
    [[ -n "${gpp}" ]] && \
        knit_warning "pbs: --gpus-per-proc has no native Hydra flag; ignoring (use --launcher-args)."
    [[ -n "${gbind}" ]] && \
        knit_warning "pbs: --gpu-bind has no native Hydra flag; ignoring (use --launcher-args)."
    if [[ -n "${extra}" ]]; then
        local -a extra_args
        read -r -a extra_args <<< "${extra}"
        _launch_argv+=("${extra_args[@]}")
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_launch_pbs_exec()
#
# Run the PBS mpiexec wrapper with the translated placement flags followed by the
# worker command, and return its exit status. The worker command is everything
# after a literal "--". The launcher argv is built by _knit_launch_pbs_cmdline.
#
# @param[in] arr_name Name of the resolved placement-options associative array.
# @param[in] --       Literal separator.
# @param[in] ...      The worker command and its arguments.
# ------------------------------------------------------------------------------
_knit_launch_pbs_exec() {
    local arr_name="$1"
    shift
    [[ "$1" == "--" ]] && shift

    local -a launcher
    _knit_launch_pbs_cmdline launcher "${arr_name}"
    "${launcher[@]}" "$@"
}
