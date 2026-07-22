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
#   - pals    — mpiexec (HPE Cray PALS)               [M12]
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# @fn _knit_launch_bind_value()
#
# Translate knit's normalized --bind vocabulary into the spelling a given backend
# expects. knit defines a small set of portable binding units — none, core,
# socket, numa, thread — and each backend family renders them differently:
# Slurm's --cpu-bind uses the plural/locality-domain spellings (cores, sockets,
# ldoms, threads); PALS's --cpu-bind uses the singular spellings (core, socket,
# numa, thread); the OpenMPI/Hydra family (openmpi, mpich, pbs) matches PALS
# except that a hardware thread is spelled hwthread. An unrecognized value is not
# an error — it is passed through verbatim (with a warning) so a user can still
# reach a launcher-specific binding this vocabulary does not cover. Returns the
# translated value.
#
# @param __knit_ret Name of the variable to hold the translated value.
# @param backend Launcher backend name ("openmpi", "mpich", "slurm", ...).
# @param value   The knit --bind value to translate.
# ------------------------------------------------------------------------------
_knit_launch_bind_value() {
    local -n __knit_ret=$1
    local __backend="$2"
    local __value="$3"
    local __out=""
    case "${__backend}" in
        slurm)
            case "${__value}" in
                none) __out="none" ;;
                core) __out="cores" ;;
                socket) __out="sockets" ;;
                numa) __out="ldoms" ;;
                thread) __out="threads" ;;
            esac
            ;;
        pals)
            case "${__value}" in
                none) __out="none" ;;
                core) __out="core" ;;
                socket) __out="socket" ;;
                numa) __out="numa" ;;
                thread) __out="thread" ;;
            esac
            ;;
        *)
            # openmpi, mpich, pbs — the OpenMPI/Hydra family, which share the same
            # binding vocabulary except that a hardware thread is spelled hwthread.
            case "${__value}" in
                none) __out="none" ;;
                core) __out="core" ;;
                socket) __out="socket" ;;
                numa) __out="numa" ;;
                thread) __out="hwthread" ;;
            esac
            ;;
    esac
    if [[ -z "${__out}" ]]; then
        knit_warning "Unknown --bind value \"${__value}\"; passing it through to the launcher verbatim."
        __out="${__value}"
    fi
    __knit_ret="${__out}"
}

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
# Returns one of "none", "openmpi", "mpich", "pals", "slurm", "pbs".
#
# @param __knit_ret Name of the variable to hold the resolved backend name.
# @param override Optional explicit launcher name (a per-run --launcher value);
#                 empty to fall back to metadata then detection.
# ------------------------------------------------------------------------------
_knit_launch_backend() {
    local -n __knit_ret=$1
    local __backend="$2"
    [[ -z "${__backend}" ]] && _knit_metadata_get __backend "__launcher__"
    [[ -z "${__backend}" ]] && __backend="$(_knit_detect_launcher)"
    # Detection's "<unknown>" (no MPI launcher present), or an __launcher__
    # seeded with it at bootstrap, means the no-launcher case -> none.
    [[ "${__backend}" == "<unknown>" ]] && __backend="none"
    __knit_ret="${__backend}"
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
        none) _knit_launch_none_cmdline "${argv_name}" "${opts_name}" ;;
        openmpi) _knit_launch_openmpi_cmdline "${argv_name}" "${opts_name}" ;;
        mpich) _knit_launch_mpich_cmdline "${argv_name}" "${opts_name}" ;;
        slurm) _knit_launch_slurm_cmdline "${argv_name}" "${opts_name}" ;;
        pbs) _knit_launch_pbs_cmdline "${argv_name}" "${opts_name}" ;;
        pals) _knit_launch_pals_cmdline "${argv_name}" "${opts_name}" ;;
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
        slurm) _knit_launch_slurm_exec "${arr_name}" -- "$@" ;;
        pbs) _knit_launch_pbs_exec "${arr_name}" -- "$@" ;;
        pals) _knit_launch_pals_exec "${arr_name}" -- "$@" ;;
        *) knit_fatal "Launcher backend not implemented: ${backend}" ;;
    esac
}
