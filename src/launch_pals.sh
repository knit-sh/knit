#!/bin/bash

## @file launch_pals.sh

# ------------------------------------------------------------------------------
# The "pals" launcher backend places an app's ranks with the HPE Cray PALS
# (Parallel Application Launch Service) mpiexec, as found on ALCF Polaris and
# Aurora. Like openmpi and mpich — and unlike the scheduler-integrated slurm/pbs
# backends — it is MPI-native and auto-detectable (_knit_detect_launcher
# recognises PALS by its mpiexec --help banner). It translates knit's minimal
# placement options into PALS mpiexec flags:
#
#   --procs N          -> -n N
#   --procs-per-node M -> --ppn M
#   --hostnames h0,h1  -> --hosts h0,h1
#   --cpus-per-proc N  -> --depth N
#   --bind V           -> --cpu-bind <V>   (V normalized by _knit_launch_bind_value)
#   --launcher-args …  -> appended verbatim after the placement flags
#
# PALS uses the long spellings --ppn and --hosts (double dash), distinguishing it
# from the Hydra-based mpich/pbs backends that use -ppn/-hosts. To bind each rank
# to the cores reserved by --depth, pass --bind (e.g. --bind core) or
# --launcher-args "--cpu-bind depth"; knit does not auto-inject a --cpu-bind.
# GPU placement (--gpus-per-proc / --gpu-bind) has no PALS mpiexec flag — GPU
# affinity on PALS systems is set by a wrapper script — so it is warned about and
# skipped; reach it through --launcher-args.
#
# Placement is resolved and validated upstream by the run dispatcher; this backend
# only formats the resolved triple into an argument vector. PALS mpiexec forwards
# the submitting environment to every rank by default, so the ranks inherit the
# surrounding job's environment (KNIT_* variables and the setup env).
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# @fn _knit_launch_pals_cmdline()
#
# Build the launcher argument vector for the pals backend (the mpiexec executable
# followed by its placement flags) into a caller-provided array, passed by name.
# Each placement flag is added only when the corresponding option is set; any
# --launcher-args string is word-split and appended verbatim.
#
# @param opts_name Name of the resolved placement-options associative array
#                  (keys: procs, procs-per-node, hostnames, launcher-args).
# @param argv_name Name of the array to fill with the launcher argument vector.
# ------------------------------------------------------------------------------
_knit_launch_pals_cmdline() {
    # shellcheck disable=SC2178 # nameref to the caller's associative array
    local -n _launch_opts="$1"
    local -n _launch_argv="$2"

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
    [[ -n "${ppn}" ]] && _launch_argv+=(--ppn "${ppn}")
    [[ -n "${hosts}" ]] && _launch_argv+=(--hosts "${hosts}")
    [[ -n "${cpp}" ]] && _launch_argv+=(--depth "${cpp}")
    [[ -n "${bind}" ]] && \
        _launch_argv+=(--cpu-bind "$(_knit_launch_bind_value pals "${bind}")")
    [[ -n "${gpp}" ]] && \
        knit_warning "pals: --gpus-per-proc has no mpiexec flag (GPU affinity is a wrapper on PALS systems); ignoring (use --launcher-args)."
    [[ -n "${gbind}" ]] && \
        knit_warning "pals: --gpu-bind has no mpiexec flag (GPU affinity is a wrapper on PALS systems); ignoring (use --launcher-args)."
    if [[ -n "${extra}" ]]; then
        local -a extra_args
        read -r -a extra_args <<< "${extra}"
        _launch_argv+=("${extra_args[@]}")
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_launch_pals_exec()
#
# Run the PALS mpiexec with the translated placement flags followed by the worker
# command, and return its exit status. The worker command is everything after a
# literal "--". The launcher argv is built by _knit_launch_pals_cmdline.
#
# @param arr_name Name of the resolved placement-options associative array.
# @param --       Literal separator.
# @param ...      The worker command and its arguments.
# ------------------------------------------------------------------------------
_knit_launch_pals_exec() {
    local arr_name="$1"
    shift
    [[ "$1" == "--" ]] && shift

    local -a launcher
    _knit_launch_pals_cmdline "${arr_name}" launcher
    "${launcher[@]}" "$@"
}
