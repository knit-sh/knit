#!/bin/bash

## @file launch_none.sh

# ------------------------------------------------------------------------------
# The "none" launcher backend is the graceful-degradation case: no MPI launcher
# is detected or configured, so an app runs as a single rank-0 / size-1 process
# directly on the host, with no launcher in front of it. It is not a standalone
# path — a run is always inside a job's allocation — it just means "this
# allocation has no launcher, run one rank here."
#
# Because it can only ever run one rank on the local host, it rejects any
# placement that asks for more: the only accepted request is a single local
# rank (procs 1, procs-per-node 1, hostnames = this host), or the equivalent
# with the options left to their defaults. Anything else (a second rank, a
# remote host) is a configuration error the user should see immediately rather
# than have silently collapsed to one local rank.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# @fn _knit_launch_none_validate()
#
# Fail fast unless the resolved placement is a single rank on the local host.
# The none backend has no launcher and cannot spread ranks, so a request for
# more than one process, more than one process per node, or a host other than
# this machine is fatal. Empty (defaulted) options are accepted — they resolve
# to the single local rank the backend runs. --launcher-args is ignored (there
# is no launcher to pass it to).
#
# @param arr_name Name of the resolved placement-options associative array
#                 (keys: procs, procs-per-node, hostnames).
# ------------------------------------------------------------------------------
_knit_launch_none_validate() {
    # shellcheck disable=SC2178 # nameref to the caller's associative array
    local -n _launch_opts="$1"

    local procs="${_launch_opts[procs]:-}"
    local ppn="${_launch_opts[procs-per-node]:-}"
    local hosts="${_launch_opts[hostnames]:-}"

    if [[ -n "${procs}" && "${procs}" != "1" ]]; then
        knit_fatal "The 'none' launcher runs a single process; --procs ${procs} is not supported (use --procs 1 or omit it)."
    fi
    if [[ -n "${ppn}" && "${ppn}" != "1" ]]; then
        knit_fatal "The 'none' launcher runs a single process; --procs-per-node ${ppn} is not supported (use --procs-per-node 1 or omit it)."
    fi
    if [[ -n "${hosts}" && "${hosts}" != "$(hostname)" ]]; then
        knit_fatal "The 'none' launcher runs on the local host only; --hostnames ${hosts} is not supported."
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_launch_none_cmdline()
#
# Build the launcher argument vector for the none backend into a caller-provided
# array, passed by name. There is no launcher, so the array is left empty. The
# placement is validated first so an over-specified request is still rejected on
# this path.
#
# @param argv_name Name of the array to fill with the launcher argument vector.
# @param opts_name Name of the resolved placement-options associative array.
# ------------------------------------------------------------------------------
_knit_launch_none_cmdline() {
    local -n _launch_argv="$1"
    _knit_launch_none_validate "$2"
    _launch_argv=()
}

# ------------------------------------------------------------------------------
# @fn _knit_launch_none_exec()
#
# Run the worker command directly, with no launcher, yielding a single rank-0 /
# size-1 process. The worker command is everything after a literal "--". The
# placement is validated first (single local rank only). Returns the worker's
# exit status.
#
# @param arr_name Name of the resolved placement-options associative array.
# @param --       Literal separator.
# @param ...      The worker command and its arguments.
# ------------------------------------------------------------------------------
_knit_launch_none_exec() {
    _knit_launch_none_validate "$1"
    shift
    [[ "$1" == "--" ]] && shift
    "$@"
}
