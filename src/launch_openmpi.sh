#!/bin/bash

## @file launch_openmpi.sh

# ------------------------------------------------------------------------------
# The "openmpi" launcher backend places an app's ranks with Open MPI's mpirun.
# It translates knit's minimal placement options into mpirun flags:
#
#   --procs N          -> -n N
#   --procs-per-node M -> --npernode M
#   --hostnames h0,h1  -> --host h0:S,h1:S   (S = per-host slot count)
#   --launcher-args …  -> appended verbatim after the placement flags
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
# @param opts_name Name of the resolved placement-options associative array
#                  (keys: procs, procs-per-node, hostnames, launcher-args).
# @param argv_name Name of the array to fill with the launcher argument vector.
# ------------------------------------------------------------------------------
_knit_launch_openmpi_cmdline() {
    # shellcheck disable=SC2178 # nameref to the caller's associative array
    local -n _launch_opts="$1"
    local -n _launch_argv="$2"

    local procs="${_launch_opts[procs]:-}"
    local ppn="${_launch_opts[procs-per-node]:-}"
    local hosts="${_launch_opts[hostnames]:-}"
    local extra="${_launch_opts[launcher-args]:-}"

    _launch_argv=(mpirun)
    [[ -n "${procs}" ]] && _launch_argv+=(-n "${procs}")
    [[ -n "${ppn}" ]] && _launch_argv+=(--npernode "${ppn}")
    if [[ -n "${hosts}" ]]; then
        _launch_argv+=(--host \
            "$(_knit_launch_openmpi_host_slots "${hosts}" "${ppn}" "${procs}")")
    fi
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
    _knit_launch_openmpi_cmdline "${arr_name}" launcher
    "${launcher[@]}" "$@"
}
