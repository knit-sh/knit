#!/bin/bash

## @file launch.sh

# ------------------------------------------------------------------------------
# The launcher layer is the app-side mirror of the scheduler layer (src/sched.sh).
# Where the scheduler places a *job* on an allocation, the launcher places the
# *ranks* of an app across the nodes of that allocation (MPI-style). A launcher
# is a separate axis from the scheduler: a Slurm job may run its ranks under
# OpenMPI's mpirun, under srun, etc. Each launcher backend lives in its own
# src/launch_<name>.sh with the same function set, dispatched here by name.
#
# Backends:
#   - none    — run the worker directly, no launcher: a single rank-0 process.
#   - openmpi — mpirun (Open MPI)                     [M2]
#   - mpich   — mpiexec/Hydra (MPICH)                 [M2]
#   - slurm   — srun (scheduler-integrated)           [M3]
#   - pbs     — the PBS mpiexec wrapper               [M3]
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# @fn _knit_launch_backend()
#
# Resolve which launcher backend to use, by precedence:
#
#   per-run --launcher argument -> metadata __launcher__ -> _knit_detect_launcher
#
# The MPI-native launchers (openmpi/mpich/pals) are the only ones autodetection
# yields; the scheduler-integrated launchers (slurm/srun, the PBS mpiexec
# wrapper) are selected only via an explicit --launcher or the __launcher__
# metadata, never auto-picked. When nothing is configured and no launcher is
# detected, detection reports "<unknown>" and this maps to the "none" backend:
# the app runs as a single rank-0 process. This mirrors how _knit_sched_backend
# degrades an undetected scheduler to the local background-process backend.
# Prints one of "none", "openmpi", "mpich", "pals", "slurm", "pbs".
#
# @param override Optional explicit launcher name (a per-run --launcher value);
#                 empty to fall back to metadata then detection.
# ------------------------------------------------------------------------------
_knit_launch_backend() {
    local backend="$1"
    [[ -z "${backend}" ]] && backend="$(_knit_metadata_load --key "__launcher__")"
    [[ -z "${backend}" ]] && backend="$(_knit_detect_launcher)"
    # Detection's "<unknown>" (no MPI launcher present), or an __launcher__
    # seeded with it at bootstrap, means the no-launcher case -> none.
    [[ "${backend}" == "<unknown>" ]] && backend="none"
    printf '%s\n' "${backend}"
}

# ------------------------------------------------------------------------------
# @fn _knit_launch_cmdline()
#
# Dispatch to the configured backend's command-line builder, which fills a
# caller-provided array (passed by name) with the launcher argument vector (the
# launcher executable and its placement flags) for the resolved placement
# options. The "none" backend has no launcher, so it leaves the array empty.
#
# @param backend   Launcher backend name ("none", "openmpi", "mpich", ...).
# @param opts_name Name of the resolved placement-options associative array
#                  (keys: procs, procs-per-node, hostnames, launcher-args).
# @param argv_name Name of the array to fill with the launcher argument vector.
# ------------------------------------------------------------------------------
_knit_launch_cmdline() {
    local backend="$1"
    local opts_name="$2"
    local argv_name="$3"
    case "${backend}" in
        none) _knit_launch_none_cmdline "${opts_name}" "${argv_name}" ;;
        openmpi) _knit_launch_openmpi_cmdline "${opts_name}" "${argv_name}" ;;
        mpich) _knit_launch_mpich_cmdline "${opts_name}" "${argv_name}" ;;
        *) knit_fatal "Launcher backend not implemented: ${backend}" ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_launch_exec()
#
# Dispatch to the configured backend's exec function, which runs the launcher
# with the translated placement flags followed by the worker command, and
# returns the launcher's exit status. The worker command is everything after a
# literal "--". The "none" backend runs the worker command directly, with no
# launcher.
#
# @param backend  Launcher backend name ("none", "openmpi", "mpich", ...).
# @param arr_name Name of the resolved placement-options associative array.
# @param --       Literal separator.
# @param ...      The worker command and its arguments.
# ------------------------------------------------------------------------------
_knit_launch_exec() {
    local backend="$1"
    local arr_name="$2"
    shift 2
    [[ "$1" == "--" ]] && shift
    case "${backend}" in
        none) _knit_launch_none_exec "${arr_name}" -- "$@" ;;
        openmpi) _knit_launch_openmpi_exec "${arr_name}" -- "$@" ;;
        mpich) _knit_launch_mpich_exec "${arr_name}" -- "$@" ;;
        *) knit_fatal "Launcher backend not implemented: ${backend}" ;;
    esac
}
