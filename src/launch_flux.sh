#!/bin/bash

## @file launch_flux.sh

# ------------------------------------------------------------------------------
# The "flux" launcher backend places an app's ranks with Flux's `flux run`. Like
# the slurm/pbs backends — and unlike the MPI-native openmpi/mpich/pals backends —
# it is scheduler-integrated: `flux run` places tasks in the surrounding Flux
# instance directly. It is auto-detectable when a Flux instance owns the shell
# (FLUX_URI is set). `flux run` is task-based, which matches knit's normalized
# placement options directly:
#
#   --procs N          -> -n N               (--ntasks)
#   --procs-per-node M -> -N <nnodes>        (nnodes = ceil(procs / M))
#   --cpus-per-proc N  -> -c N               (--cores-per-task, native)
#   --gpus-per-proc N  -> -g N               (--gpus-per-task, native)
#   --hostnames h0,h1  -> --requires=host:h0,h1
#   --bind V           -> -o cpu-affinity=<v>   (V normalized by _knit_launch_bind_value)
#   --gpu-bind V       -> -o gpu-affinity=<V>   (value passed through verbatim)
#   --launcher-args …  -> appended verbatim after the placement flags
#
# `flux run` splits its placement flags into two families that must not be mixed:
# per-task (-n/-c/-g) and per-resource (--tasks-per-node/--gpus-per-node). knit
# keeps the per-task family so cpus-per-proc and gpus-per-proc stay native, and
# expresses procs-per-node as a node count (-N) instead of --tasks-per-node:
# with -n tasks over -N nodes, `flux run` fills the nodes evenly, so the ranks
# per node equal procs-per-node. nnodes is ceil(procs / procs-per-node).
#
# `flux run` is a strong launcher fit: cpus-per-proc and gpus-per-proc are both
# native, where the Hydra-family backends warn and skip them. Binding is coarser:
# Flux's -o cpu-affinity is a distribution policy (off | per-task | map:LIST), not
# a granularity, so knit's core/socket/numa/thread all map to per-task (see
# _knit_launch_bind_value); reach exact placement through
# --launcher-args -o cpu-affinity=map:LIST.
#
# Placement is resolved and validated upstream by the run dispatcher; this backend
# only formats the resolved triple into an argument vector. `flux run` executes
# inside the surrounding job's Flux instance and forwards its environment to every
# task, so the ranks inherit the job's KNIT_* variables and the setup env.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# @fn _knit_launch_flux_cmdline()
#
# Build the launcher argument vector for the flux backend (the `flux run`
# executable followed by its placement flags) into a caller-provided array,
# passed by name. Each placement flag is added only when the corresponding option
# is set; any --launcher-args string is word-split and appended verbatim.
#
# @param argv_name Name of the array to fill with the launcher argument vector.
# @param opts_name Name of the resolved placement-options associative array
#                  (keys: procs, procs-per-node, hostnames, launcher-args).
# ------------------------------------------------------------------------------
_knit_launch_flux_cmdline() {
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

    _launch_argv=(flux run)
    [[ -n "${procs}" ]] && _launch_argv+=(-n "${procs}")
    # Express procs-per-node as a node count so the per-task family (-n/-c/-g)
    # stays usable: flux forbids -n together with --tasks-per-node. With -n
    # tasks over -N nodes, flux fills the nodes evenly.
    if [[ -n "${ppn}" && -n "${procs}" ]]; then
        _launch_argv+=(-N "$(( (procs + ppn - 1) / ppn ))")
    fi
    [[ -n "${cpp}" ]] && _launch_argv+=(-c "${cpp}")
    [[ -n "${gpp}" ]] && _launch_argv+=(-g "${gpp}")
    [[ -n "${hosts}" ]] && _launch_argv+=("--requires=host:${hosts}")
    if [[ -n "${bind}" ]]; then
        local __bind_val
        _knit_launch_bind_value __bind_val flux "${bind}"
        _launch_argv+=(-o "cpu-affinity=${__bind_val}")
    fi
    [[ -n "${gbind}" ]] && _launch_argv+=(-o "gpu-affinity=${gbind}")
    if [[ -n "${extra}" ]]; then
        local -a extra_args
        read -r -a extra_args <<< "${extra}"
        _launch_argv+=("${extra_args[@]}")
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_launch_flux_exec()
#
# Run `flux run` with the translated placement flags followed by the worker
# command, and return its exit status. The worker command is everything after a
# literal "--". The launcher argv is built by _knit_launch_flux_cmdline.
#
# @param arr_name Name of the resolved placement-options associative array.
# @param --       Literal separator.
# @param ...      The worker command and its arguments.
# ------------------------------------------------------------------------------
_knit_launch_flux_exec() {
    local arr_name="$1"
    shift
    [[ "$1" == "--" ]] && shift

    local -a launcher
    _knit_launch_flux_cmdline launcher "${arr_name}"
    "${launcher[@]}" "$@"
}
