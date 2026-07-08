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
#   --launcher-args …  -> appended verbatim after the placement flags
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
# @param opts_name Name of the resolved placement-options associative array
#                  (keys: procs, procs-per-node, hostnames, launcher-args).
# @param argv_name Name of the array to fill with the launcher argument vector.
# ------------------------------------------------------------------------------
_knit_launch_pbs_cmdline() {
    # shellcheck disable=SC2178 # nameref to the caller's associative array
    local -n _launch_opts="$1"
    local -n _launch_argv="$2"

    local procs="${_launch_opts[procs]:-}"
    local ppn="${_launch_opts[procs-per-node]:-}"
    local hosts="${_launch_opts[hostnames]:-}"
    local extra="${_launch_opts[launcher-args]:-}"

    _launch_argv=(mpiexec)
    [[ -n "${procs}" ]] && _launch_argv+=(-n "${procs}")
    [[ -n "${ppn}" ]] && _launch_argv+=(-ppn "${ppn}")
    [[ -n "${hosts}" ]] && _launch_argv+=(-hosts "${hosts}")
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
# @param arr_name Name of the resolved placement-options associative array.
# @param --       Literal separator.
# @param ...      The worker command and its arguments.
# ------------------------------------------------------------------------------
_knit_launch_pbs_exec() {
    local arr_name="$1"
    shift
    [[ "$1" == "--" ]] && shift

    local -a launcher
    _knit_launch_pbs_cmdline "${arr_name}" launcher
    "${launcher[@]}" "$@"
}
