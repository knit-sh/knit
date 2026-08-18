#!/bin/bash

## @file detect.sh

# ------------------------------------------------------------------------------
# @var _KNIT_DETECTED_JOB_MANAGER
#
# Cache for _knit_detect_job_manager(). Empty means "not yet detected"; one of
# "flux", "slurm", "pbs", or "<unknown>" after the first successful detection
# call.
# ------------------------------------------------------------------------------
declare -g _KNIT_DETECTED_JOB_MANAGER
_KNIT_DETECTED_JOB_MANAGER=""

# ------------------------------------------------------------------------------
# @var _KNIT_DETECTED_MPI
#
# Cache for _knit_detect_mpi(). Empty means "not yet detected"; one of
# "openmpi", "mpich", or "<unknown>" after the first successful detection call.
# ------------------------------------------------------------------------------
declare -g _KNIT_DETECTED_MPI
_KNIT_DETECTED_MPI=""

# ------------------------------------------------------------------------------
# @fn _knit_detect_job_manager()
#
# Detect which batch job manager is available in the current environment.
#
# Outputs one of the following strings to stdout and returns 0:
#   - "flux"      — FLUX_URI names a live Flux instance that owns this shell
#   - "slurm"     — sbatch is present in PATH
#   - "pbs"       — qsub is present in PATH (and sbatch is not)
#   - "flux"      — flux is present in PATH (and no sbatch/qsub)
#   - "<unknown>" — none of the above
#
# The result is cached in _KNIT_DETECTED_JOB_MANAGER so that subsequent calls
# within the same session return immediately without re-probing the PATH.
#
# FLUX_URI is tested first because Flux is often deployed inside a Slurm or PBS
# allocation, so flux, sbatch, and qsub can all be on PATH at once. A live
# FLUX_URI means a Flux instance owns this shell, so Flux is the right backend;
# without it a Flux-under-Slurm login shell still detects as Slurm. When both
# sbatch and qsub are present (but no FLUX_URI), Slurm takes priority. A system
# flux with no live instance is the last resort before <unknown>.
# ------------------------------------------------------------------------------
_knit_detect_job_manager() {
    if [[ -n "${_KNIT_DETECTED_JOB_MANAGER}" ]]; then
        echo "${_KNIT_DETECTED_JOB_MANAGER}"
        return 0
    fi

    if [[ -n "${FLUX_URI:-}" ]]; then
        _KNIT_DETECTED_JOB_MANAGER="flux"
    elif command -v sbatch &>/dev/null; then
        _KNIT_DETECTED_JOB_MANAGER="slurm"
    elif command -v qsub &>/dev/null; then
        _KNIT_DETECTED_JOB_MANAGER="pbs"
    elif command -v flux &>/dev/null; then
        _KNIT_DETECTED_JOB_MANAGER="flux"
    else
        _KNIT_DETECTED_JOB_MANAGER="<unknown>"
    fi

    knit_trace "Detected job manager: ${_KNIT_DETECTED_JOB_MANAGER}"
    echo "${_KNIT_DETECTED_JOB_MANAGER}"
}

# ------------------------------------------------------------------------------
# @fn _knit_detect_mpi()
#
# Detect which MPI implementation is available in the current environment.
#
# Outputs one of the following strings to stdout and returns 0:
#   - "openmpi"   — mpirun is present and its --version output contains "Open MPI"
#   - "mpich"     — mpirun is present and its --version output contains "HYDRA"
#   - "<unknown>" — mpirun is absent or its version string is not recognised
#
# The result is cached in _KNIT_DETECTED_MPI so that subsequent calls within
# the same session return immediately without re-running mpirun.
# ------------------------------------------------------------------------------
_knit_detect_mpi() {
    if [[ -n "${_KNIT_DETECTED_MPI}" ]]; then
        echo "${_KNIT_DETECTED_MPI}"
        return 0
    fi

    if ! command -v mpirun &>/dev/null; then
        _KNIT_DETECTED_MPI="<unknown>"
    else
        local version_output
        version_output=$(mpirun --version 2>&1)
        if [[ "${version_output}" == *"Open MPI"* ]]; then
            _KNIT_DETECTED_MPI="openmpi"
        elif [[ "${version_output}" == *"HYDRA"* ]]; then
            _KNIT_DETECTED_MPI="mpich"
        else
            _KNIT_DETECTED_MPI="<unknown>"
        fi
    fi

    knit_trace "Detected MPI: ${_KNIT_DETECTED_MPI}"
    echo "${_KNIT_DETECTED_MPI}"
}

# ------------------------------------------------------------------------------
# @var _KNIT_DETECTED_LAUNCHER
#
# Cache for _knit_detect_launcher(). Empty means "not yet detected"; one of
# "pals", "openmpi", "mpich", "flux", or "<unknown>" after the first successful
# detection call.
# ------------------------------------------------------------------------------
declare -g _KNIT_DETECTED_LAUNCHER
_KNIT_DETECTED_LAUNCHER=""

# ------------------------------------------------------------------------------
# @fn _knit_detect_launcher()
#
# Detect which MPI launcher is available in the current environment.
#
# Outputs one of the following strings to stdout and returns 0:
#   - "pals"    — mpiexec is present and its --help output starts with
#                 "Parallel Application Launch Service"
#   - "openmpi" — mpirun is present and its --version output contains "Open MPI"
#   - "mpich"   — mpirun is present and its --version output contains "HYDRA"
#   - "flux"    — no MPI-native launcher, but FLUX_URI is set or flux is in PATH
#   - "<unknown>" — no recognised launcher found
#
# PALS is checked first because PALS provides mpiexec but not mpirun; OpenMPI
# and MPICH also provide mpiexec as an alias so the first-line check
# distinguishes them. Flux is the last resort: an MPI-native launcher (openmpi,
# mpich, pals) always wins when present, so Flux is chosen only after those
# probes find nothing.
#
# The result is cached in _KNIT_DETECTED_LAUNCHER so that subsequent calls
# within the same session return immediately without re-probing the PATH.
# ------------------------------------------------------------------------------
_knit_detect_launcher() {
    if [[ -n "${_KNIT_DETECTED_LAUNCHER}" ]]; then
        echo "${_KNIT_DETECTED_LAUNCHER}"
        return 0
    fi

    _KNIT_DETECTED_LAUNCHER="<unknown>"

    if command -v mpiexec &>/dev/null; then
        local first_line
        first_line=$(mpiexec --help 2>&1 | head -1)
        if [[ "${first_line}" == *"Parallel Application Launch Service"* ]]; then
            _KNIT_DETECTED_LAUNCHER="pals"
        fi
    fi

    if [[ "${_KNIT_DETECTED_LAUNCHER}" == "<unknown>" ]] \
        && command -v mpirun &>/dev/null; then
        local version_output
        version_output=$(mpirun --version 2>&1)
        if [[ "${version_output}" == *"Open MPI"* ]]; then
            _KNIT_DETECTED_LAUNCHER="openmpi"
        elif [[ "${version_output}" == *"HYDRA"* ]]; then
            _KNIT_DETECTED_LAUNCHER="mpich"
        fi
    fi

    # No MPI-native launcher found: fall back to Flux when a Flux instance owns
    # this shell (FLUX_URI) or a system flux is on PATH.
    if [[ "${_KNIT_DETECTED_LAUNCHER}" == "<unknown>" ]] \
        && { [[ -n "${FLUX_URI:-}" ]] || command -v flux &>/dev/null; }; then
        _KNIT_DETECTED_LAUNCHER="flux"
    fi

    knit_trace "Detected launcher: ${_KNIT_DETECTED_LAUNCHER}"
    echo "${_KNIT_DETECTED_LAUNCHER}"
}

# ------------------------------------------------------------------------------
# @var _KNIT_DETECTED_NODE_NCPUS
#
# Cache for _knit_detect_node_ncpus(). Empty means "not yet detected" (or
# undetectable); a positive integer once detection succeeds.
# ------------------------------------------------------------------------------
declare -g _KNIT_DETECTED_NODE_NCPUS
_KNIT_DETECTED_NODE_NCPUS=""

# ------------------------------------------------------------------------------
# @fn _knit_detect_node_ncpus()
#
# Detect the per-node core count of the current cluster by querying the detected
# batch scheduler and taking the modal (most common) value across its nodes:
#   - slurm: `sinfo -h -N -o '%c'` (one line per node)
#   - pbs:   `pbsnodes -a` resources_available.ncpus lines
#   - flux:  `flux resource list` total cores divided by total nodes
#
# Counting is node-weighted (-N on Slurm; one entry per node on PBS), so a
# minority outlier such as a login node listed alongside the compute nodes is
# ignored in favour of the value the bulk of the nodes report.
#
# Prints the detected core count (a positive integer) to stdout, or nothing when
# the query yields no usable value. Knit allocates whole nodes, so this feeds
# __node_ncpus__ (cpus-per-node) on machines that have no profile. When there is
# no batch scheduler the count of the local machine (nproc, or getconf as a
# portable fallback) is used so that __node_ncpus__ is still populated on a
# workstation. The result is cached in _KNIT_DETECTED_NODE_NCPUS.
#
# The local fallback is deliberately confined to the no-scheduler case: on a
# machine with a scheduler the login node's core count is not representative of
# the compute nodes, so a failed scheduler query returns nothing rather than the
# (misleading) local value.
# ------------------------------------------------------------------------------
_knit_detect_node_ncpus() {
    if [[ -n "${_KNIT_DETECTED_NODE_NCPUS}" ]]; then
        echo "${_KNIT_DETECTED_NODE_NCPUS}"
        return 0
    fi

    local ncpus=""
    case "$(_knit_detect_job_manager)" in
        slurm)
            if command -v sinfo &>/dev/null; then
                ncpus="$(sinfo -h -N -o '%c' 2>/dev/null \
                    | grep -E '^[0-9]+$' \
                    | sort | uniq -c | sort -rn | head -n1 | awk '{print $2}')"
            fi
            ;;
        pbs)
            if command -v pbsnodes &>/dev/null; then
                ncpus="$(pbsnodes -a 2>/dev/null \
                    | awk -F= '/resources_available.ncpus/ {gsub(/ /, "", $2); print $2}' \
                    | grep -E '^[0-9]+$' \
                    | sort | uniq -c | sort -rn | head -n1 | awk '{print $2}')"
            fi
            ;;
        flux)
            # flux resource list reports aggregate node and core counts; a
            # homogeneous cluster's per-node count is cores/nodes. A non-integer
            # or zero result leaves __node_ncpus__ empty (whole-node-exclusive
            # sizing still applies).
            if command -v flux &>/dev/null; then
                local counts nnodes ncores
                counts="$(flux resource list -s all -no '{nnodes} {ncores}' 2>/dev/null)"
                read -r nnodes ncores <<< "${counts}"
                if [[ "${nnodes}" =~ ^[0-9]+$ && "${ncores}" =~ ^[0-9]+$ \
                    && "${nnodes}" -gt 0 ]]; then
                    ncpus="$(( ncores / nnodes ))"
                    [[ "${ncpus}" -gt 0 ]] || ncpus=""
                fi
            fi
            ;;
        *)
            # No batch scheduler: report the local machine's core count. nproc
            # comes from coreutils; getconf is POSIX and covers systems without
            # it.
            if command -v nproc &>/dev/null; then
                ncpus="$(nproc 2>/dev/null)"
            elif command -v getconf &>/dev/null; then
                ncpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null)"
            fi
            # Keep only a positive integer; discard anything unexpected.
            [[ "${ncpus}" =~ ^[0-9]+$ ]] || ncpus=""
            ;;
    esac

    _KNIT_DETECTED_NODE_NCPUS="${ncpus}"
    knit_trace "Detected node ncpus: ${_KNIT_DETECTED_NODE_NCPUS:-<none>}"
    echo "${_KNIT_DETECTED_NODE_NCPUS}"
}

# ------------------------------------------------------------------------------
# @fn _knit_command_path()
#
# Print the absolute path to a system executable if it exists on PATH, or
# nothing when it is absent. Thin wrapper around `command -v` that gives the
# bootstrap a single, easily stubbable resolution point for the system
# binaries (sqlite3, jq) it may symlink instead of building from source.
#
# @param name Name of the executable to look up.
# ------------------------------------------------------------------------------
_knit_command_path() {
    command -v "$1" 2>/dev/null
}

# ------------------------------------------------------------------------------
# @fn _knit_detect_sqlite_dev()
#
# Return 0 if the system provides usable SQLite3 development files (the sqlite3.h
# header and the libsqlite3 library) on the C compiler's default search paths,
# 1 otherwise. Verified by compiling and linking a tiny probe program against
# libsqlite3 -- exactly what knit-graph's build does -- so a positive result
# means knit-graph can be built against the system SQLite without a from-source
# build. The compiler is the one named by CC (default "cc"); returns 1 when no
# compiler is available or the probe fails to build.
# ------------------------------------------------------------------------------
_knit_detect_sqlite_dev() {
    local cc="${CC:-cc}"
    command -v "${cc}" &>/dev/null || return 1

    local tmpdir
    tmpdir="$(mktemp -d)" || return 1
    printf '#include <sqlite3.h>\nint main(void){return sqlite3_libversion_number()>0?0:1;}\n' \
        > "${tmpdir}/probe.c"
    local status=1
    if "${cc}" "${tmpdir}/probe.c" -o "${tmpdir}/probe" -lsqlite3 &>/dev/null; then
        status=0
    fi
    rm -rf "${tmpdir}"
    return "${status}"
}
