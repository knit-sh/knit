#!/bin/bash

## @file launch_openmpi.sh

# ------------------------------------------------------------------------------
# The "openmpi" launcher backend places an app's ranks with Open MPI's mpirun.
# It translates knit's minimal placement options into mpirun flags:
#
#   --procs N          -> -n N
#   --procs-per-node M -> --npernode M
#   --hostnames h0,h1  -> --host h0:S,h1:S   (S = per-host slot count)
#   --cpus-per-proc N  -> --map-by slot:PE=N
#   --bind V           -> --bind-to <V>      (V normalized by _knit_launch_bind_value)
#   --launcher-args …  -> appended verbatim after the placement flags
#
# GPU placement (--gpus-per-proc / --gpu-bind) has no portable mpirun flag, so it
# is warned about and skipped; reach GPU affinity through --launcher-args. Note
# that --map-by slot:PE=N may conflict with --npernode (--procs-per-node), which
# is itself a mapping directive; this translation is best-effort (there is no live
# CI for it) and --launcher-args is the escape hatch if a site needs a different
# mapping.
#
# The slot suffix on each --host entry is essential: mpirun's bare
# "--host h0,h1" advertises only one slot per host (a documented Open MPI
# default), so "-n 4" over two such hosts fails with "not enough slots" even
# inside a matching Slurm/PBS allocation, because an explicit --host overrides
# the resource manager's slot counts. Annotating each host with S slots
# (S = --procs-per-node when set, else ceil(procs / nhosts)) states the intended
# per-host capacity so the requested rank count fits. This is also what a plain
# SSH/none-scheduler cluster needs, where there is no resource manager to supply
# slots at all.
#
# Exception — Open MPI built with PBS TM integration (--with-tm): inside a PBS
# job Open MPI's tm RAS already knows the allocated nodes and their slot counts,
# and an explicit --host (with or without slot suffixes) conflicts with it — the
# mapper rejects the placement ("requested more processes than the ppr ... can
# support", or "not enough slots"). So when $PBS_NODEFILE is set the --host flag
# is omitted entirely and the allocation is left to TM; -n / --npernode still
# control the rank count and per-node distribution. (Slurm's PLM, by contrast,
# tolerates the redundant --host and needs it to honour a strict host subset, so
# it is kept there.) A strict host *subset* of a PBS allocation via --hostnames
# is therefore not expressible to this backend; use MPICH there.
#
# Placement is resolved and validated upstream by the run dispatcher; this
# backend only formats the resolved triple into an argument vector. mpirun
# forwards the submitting environment to every rank by default, so the ranks
# inherit the surrounding job's environment (KNIT_* variables and the setup env).
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# @fn _knit_launch_openmpi_host_slots()
#
# Build the value of mpirun's --host flag from a comma-separated host list,
# annotating each host with a per-host slot count so the requested rank count
# fits (see the file header for why bare --host is not enough). The slot count
# is --procs-per-node when set; otherwise it is derived as ceil(procs / nhosts)
# so procs ranks spread across the hosts. When neither procs-per-node nor procs
# is known, the hosts are emitted unannotated (nothing to size them by).
#
# @param hosts Comma-separated host list (the resolved --hostnames value).
# @param ppn   Resolved --procs-per-node value (may be empty).
# @param procs Resolved --procs value (may be empty).
# ------------------------------------------------------------------------------
_knit_launch_openmpi_host_slots() {
    local hosts="$1"
    local ppn="$2"
    local procs="$3"

    local -a hlist
    IFS=',' read -r -a hlist <<< "${hosts}"
    local n="${#hlist[@]}"

    local slots="${ppn}"
    if [[ -z "${slots}" && -n "${procs}" && "${n}" -gt 0 ]]; then
        slots=$(( (procs + n - 1) / n ))
    fi

    local out="" h
    for h in "${hlist[@]}"; do
        if [[ -n "${slots}" ]]; then
            out+="${h}:${slots},"
        else
            out+="${h},"
        fi
    done
    printf '%s' "${out%,}"
}

# ------------------------------------------------------------------------------
# @fn _knit_launch_openmpi_cmdline()
#
# Build the launcher argument vector for the openmpi backend (the mpirun
# executable followed by its placement flags) into a caller-provided array,
# passed by name. Each placement flag is added only when the corresponding
# option is set; the --host value is slot-annotated by
# _knit_launch_openmpi_host_slots, and any --launcher-args string is word-split
# and appended verbatim.
#
# @param argv_name Name of the array to fill with the launcher argument vector.
# @param opts_name Name of the resolved placement-options associative array
#                  (keys: procs, procs-per-node, hostnames, launcher-args).
# ------------------------------------------------------------------------------
_knit_launch_openmpi_cmdline() {
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

    _launch_argv=(mpirun)
    [[ -n "${procs}" ]] && _launch_argv+=(-n "${procs}")
    [[ -n "${ppn}" ]] && _launch_argv+=(--npernode "${ppn}")
    # Under a PBS allocation, defer host/slot placement to Open MPI's tm RAS: an
    # explicit --host conflicts with it (see the file header). Elsewhere (Slurm,
    # or a plain SSH/none cluster) the slot-annotated --host is required.
    if [[ -n "${hosts}" && -z "${PBS_NODEFILE:-}" ]]; then
        _launch_argv+=(--host \
            "$(_knit_launch_openmpi_host_slots "${hosts}" "${ppn}" "${procs}")")
    fi
    [[ -n "${cpp}" ]] && _launch_argv+=(--map-by "slot:PE=${cpp}")
    if [[ -n "${bind}" ]]; then
        local __bind_val
        _knit_launch_bind_value __bind_val openmpi "${bind}"
        _launch_argv+=(--bind-to "${__bind_val}")
    fi
    [[ -n "${gpp}" ]] && \
        knit_warning "openmpi: --gpus-per-proc has no portable mpirun flag; ignoring (use --launcher-args)."
    [[ -n "${gbind}" ]] && \
        knit_warning "openmpi: --gpu-bind has no portable mpirun flag; ignoring (use --launcher-args)."
    if [[ -n "${extra}" ]]; then
        local -a extra_args
        read -r -a extra_args <<< "${extra}"
        _launch_argv+=("${extra_args[@]}")
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_launch_openmpi_exec()
#
# Run mpirun with the translated placement flags followed by the worker command,
# and return its exit status. The worker command is everything after a literal
# "--". The launcher argv is built by _knit_launch_openmpi_cmdline.
#
# @param arr_name Name of the resolved placement-options associative array.
# @param --       Literal separator.
# @param ...      The worker command and its arguments.
# ------------------------------------------------------------------------------
_knit_launch_openmpi_exec() {
    local arr_name="$1"
    shift
    [[ "$1" == "--" ]] && shift

    local -a launcher
    _knit_launch_openmpi_cmdline launcher "${arr_name}"
    "${launcher[@]}" "$@"
}
