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
#   - openmpi — mpirun (Open MPI)
#   - mpich   — mpiexec/Hydra (MPICH)
#   - slurm   — srun (scheduler-integrated)
#   - pbs     — the PBS mpiexec wrapper
#   - pals    — mpiexec (HPE Cray PALS)
#   - flux    — flux run (scheduler-integrated)
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
# except that a hardware thread is spelled hwthread. Flux's -o cpu-affinity is a
# distribution policy (off | per-task | map:LIST), not a granularity, so all four
# levels map to per-task and none maps to off. An unrecognized value is not an
# error — it is passed through verbatim (with a warning) so a user can still reach
# a launcher-specific binding this vocabulary does not cover. Returns the
# translated value.
#
# @param[out] __knit_ret Name of the variable to hold the translated value.
# @param[in] backend Launcher backend name ("openmpi", "mpich", "slurm", "pals",
#                "flux").
# @param[in] value   The knit --bind value to translate.
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
        flux)
            # Flux's -o cpu-affinity is a distribution policy (off|per-task|
            # map:LIST), not a granularity, so knit's four levels all bind each
            # rank to its assigned cores via per-task; none disables affinity.
            # Reach exact placement with --launcher-args -o cpu-affinity=map:LIST.
            case "${__value}" in
                none) __out="off" ;;
                core|socket|numa|thread) __out="per-task" ;;
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
#   per-run --launcher  ->  concrete __launcher__ metadata  ->
#   KNIT_PROVIDED_LAUNCHER (a setup's frozen contract)  ->  none
#
# Every launcher value is frozen ahead of the run — no run-time detection. The
# __launcher__ metadata is the launcher integrated into the machine, resolved
# once at bootstrap from the profile or bootstrap-time detection; it is preferred
# over a setup's contract because a site's launcher cooperates with the resource
# manager as intended (§3 of the design). A "<unknown>" __launcher__ (detection
# found no MPI at bootstrap, no profile) or an explicit "none" (the machine was
# told it offers no integrated launcher, via `bootstrap --launcher none` or a
# profile launcher.type of "none") is skipped so a providing setup's frozen
# KNIT_PROVIDED_LAUNCHER — set by knit_provides_launcher when the setup built or
# module-loaded its own MPI — is used instead. When nothing is configured, the
# "none" backend runs the app as a single rank-0 process. This mirrors how
# _knit_sched_backend degrades an undetected scheduler to the local
# background-process backend. Note that a run-time --launcher of "none" (the
# override argument, tier 1) is the opposite: an explicit, terminal choice of the
# "none" backend that does NOT fall through to a setup contract.
# Returns one of "none", "openmpi", "mpich", "pals", "slurm", "pbs", "flux".
#
# @param[out] __knit_ret Name of the variable to hold the resolved backend name.
# @param[in] override Optional explicit launcher name (a per-run --launcher value);
#                 empty to fall back to the metadata then the setup contract.
# ------------------------------------------------------------------------------
_knit_launch_backend() {
    local -n __knit_ret=$1
    local backend="$2"
    if [[ -z "${backend}" ]]; then
        _knit_metadata_get backend "__launcher__"
        # A "<unknown>" __launcher__ (detection found no machine launcher) or an
        # explicit "none" (the machine declares it offers none) is skipped so the
        # setup contract below can supply one.
        [[ "${backend}" == "<unknown>" || "${backend}" == "none" ]] && backend=""
    fi
    [[ -z "${backend}" ]] && backend="${KNIT_PROVIDED_LAUNCHER:-}"
    [[ -z "${backend}" ]] && backend="none"
    __knit_ret="${backend}"
}

# ------------------------------------------------------------------------------
# @fn _knit_launch_cmdline()
#
# Dispatch to the configured backend's command-line builder, which fills a
# caller-provided array (passed by name) with the launcher argument vector (the
# launcher executable and its placement flags) for the resolved placement
# options. The "none" backend has no launcher, so it leaves the array empty.
#
# @param[in] backend   Launcher backend name ("none", "openmpi", "mpich", ...).
# @param[in] opts_name Name of the resolved placement-options associative array
#                  (keys: procs, procs-per-node, hostnames, launcher-args).
# @param[in] argv_name Name of the array to fill with the launcher argument vector.
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
        flux) _knit_launch_flux_cmdline "${argv_name}" "${opts_name}" ;;
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
# @param[in] backend  Launcher backend name ("none", "openmpi", "mpich", ...).
# @param[in] arr_name Name of the resolved placement-options associative array.
# @param[in] --       Literal separator.
# @param[in] ...      The worker command and its arguments.
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
        flux) _knit_launch_flux_exec "${arr_name}" -- "$@" ;;
        *) knit_fatal "Launcher backend not implemented: ${backend}" ;;
    esac
}
