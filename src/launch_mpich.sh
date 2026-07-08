#!/bin/bash

## @file launch_mpich.sh

# ------------------------------------------------------------------------------
# The "mpich" launcher backend places an app's ranks with MPICH's mpiexec (the
# Hydra process manager). It translates knit's minimal placement options into
# Hydra flags:
#
#   --procs N          -> -n N
#   --procs-per-node M -> -ppn M
#   --hostnames h0,h1  -> -hosts h0,h1
#   --launcher-args …  -> appended verbatim after the placement flags
#
# Placement is resolved and validated upstream by the run dispatcher; this
# backend only formats the resolved triple into an argument vector. Hydra
# forwards the submitting environment to every rank by default, so the ranks
# inherit the surrounding job's environment (KNIT_* variables and the setup env).
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# @fn _knit_launch_mpich_cmdline()
#
# Build the launcher argument vector for the mpich backend (the mpiexec
# executable followed by its placement flags) into a caller-provided array,
# passed by name. Each placement flag is added only when the corresponding
# option is set; any --launcher-args string is word-split and appended verbatim.
#
# @param opts_name Name of the resolved placement-options associative array
#                  (keys: procs, procs-per-node, hostnames, launcher-args).
# @param argv_name Name of the array to fill with the launcher argument vector.
# ------------------------------------------------------------------------------
_knit_launch_mpich_cmdline() {
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
# @fn _knit_launch_mpich_exec()
#
# Run mpiexec with the translated placement flags followed by the worker command,
# and return its exit status. The worker command is everything after a literal
# "--". The launcher argv is built by _knit_launch_mpich_cmdline.
#
# @param arr_name Name of the resolved placement-options associative array.
# @param --       Literal separator.
# @param ...      The worker command and its arguments.
# ------------------------------------------------------------------------------
_knit_launch_mpich_exec() {
    local arr_name="$1"
    shift
    [[ "$1" == "--" ]] && shift

    local -a launcher
    _knit_launch_mpich_cmdline "${arr_name}" launcher
    "${launcher[@]}" "$@"
}
