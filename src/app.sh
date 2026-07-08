#!/bin/bash

## @file app.sh

# ------------------------------------------------------------------------------
# @var _KNIT_APPS
#
# Associative array mapping registered app names to 1. Used to validate that an
# app name passed to `knit run` is known. Mirrors _KNIT_JOBS for jobs.
# ------------------------------------------------------------------------------
declare -A _KNIT_APPS

# ------------------------------------------------------------------------------
# Name of the table recording every run: the app launched, the parent job, the
# requested placement, and the launcher. The row id is the run UUID, shared with
# the rank-0 per-app row so the two tables join; the "job" column references the
# parent job's UUID so runs can be traced back to the job that issued them.
# ------------------------------------------------------------------------------
_KNIT_RUNS_TABLE="runs"

knit_register _knit_run "run" "Run an application (MPI launch) inside a job."
# Placement (all optional). Empty means "not set": _knit_run_resolve_placement
# fills the missing values from the job's allocation and the per-node core count.
knit_with_optional "procs:integer" "" "Total number of ranks (MPI processes)."
knit_with_optional "procs-per-node:integer" "" "Ranks per node."
knit_with_optional "hostnames:string" "" \
    "Comma-separated subset of the job's allocated hosts to place on."
knit_with_optional "launcher:string" "" \
    "Override the launcher backend (none, openmpi, mpich, slurm, pbs)."
knit_with_optional "launcher-args:string" "" \
    "Extra arguments passed verbatim to the launcher."
knit_with_dispatch "app" "User-provided app command to execute"
knit_with_subcommand_title "Apps"
# Record every run as a row in the "runs" table. The placement options above are
# recorded as-requested columns; the "app" output records the launched app name.
knit_with_table "${_KNIT_RUNS_TABLE}"
knit_with_output "app:string" "" "Name of the app that was run (the token after --)."
knit_with_output "job:string" "" \
    "UUID of the parent job that issued this run (basename of KNIT_JOB_PREFIX)."

# ------------------------------------------------------------------------------
# @fn _knit_run()
#
# Entry point for the `run` CLI command: the user-facing dispatcher that launches
# an app across a subset of the surrounding job's allocation. A run has no meaning
# outside a job (the job supplies the node list the launcher places ranks on), so
# this fails fast when invoked outside one (KNIT_JOB_PREFIX unset), analogous to
# how job and setup commands reject direct invocation.
#
# It validates the app name and its arguments, resolves the placement options into
# a concrete (procs, procs-per-node, hosts) triple, resolves the launcher backend,
# and execs the per-rank worker (`_run`) under that launcher. The app runs in the
# context of the job's directory (there is no separate run directory); the run's
# UUID serves only as its id in the runs table. Its exit status is the launcher's.
#
# Usage:
# ```
# ./exp.sh run [placement-opts...] -- app-name [args...]   (inside a job)
# ```
# ------------------------------------------------------------------------------
_knit_run() {
    # A run only makes sense inside a job allocation; fail fast otherwise.
    if [[ ! -v KNIT_JOB_PREFIX ]]; then
        knit_fatal "\"run\" must be invoked from inside a job (KNIT_JOB_PREFIX is unset); call it from a job body submitted with \"knit submit\"."
    fi

    # Extract extra args (after --): the app name and its arguments.
    local args=("$@")
    local extra_index
    extra_index=$(knit_extra_index "${args[@]}")
    local extra=("${args[@]:extra_index}")

    if [[ ${#extra[@]} -eq 0 ]]; then
        knit_fatal "run requires an app name (pass it after --)."
    fi

    local app_name="${extra[0]}"
    local app_args=("${extra[@]:1}")

    # Check app name is registered.
    if [[ ! -v _KNIT_APPS["${app_name}"] ]]; then
        knit_fatal "Unknown app \"${app_name}\"."
    fi

    # Validate args for the app subcommand (knit_fatal on bad args).
    local subcmd
    subcmd=$(_knit_command_mangle "run:${app_name}")
    _knit_check_command_arguments "${subcmd}" "${app_args[@]}"

    # Resolve placement into the launcher options (procs, procs-per-node,
    # hostnames), then add the raw --launcher-args passthrough. This single array
    # is exactly what the launcher backend reads (by name, in _knit_launch_exec).
    declare -A launch_opts
    _knit_run_resolve_placement launch_opts "$@"
    local launcher_args
    launcher_args=$(knit_get_parameter "launcher-args" "$@") || launcher_args=""
    # shellcheck disable=SC2034 # array is read by name in _knit_launch_exec
    launch_opts["launcher-args"]="${launcher_args}"

    # Record this run in the runs table under a fresh uuid, the run's id. The app
    # runs in the job's directory, so there is no run directory to create.
    local uuid
    uuid=$(_knit_uuidv7)
    _knit_set_row_id "${uuid}"
    knit_output "app" "${app_name}"
    # Reference back to the parent job (the run has no meaning without it).
    knit_output "job" "$(basename "${KNIT_JOB_PREFIX}")"

    # Resolve the launcher backend (per-run --launcher override -> metadata
    # __launcher__ -> live detection, with the no-launcher case mapping to none),
    # then launch the per-rank worker under it and return its status. The worker
    # re-enters this experiment as the hidden `_run` verb; the launcher forwards
    # the job's exported KNIT_* environment to every rank.
    local launcher_override backend
    launcher_override=$(knit_get_parameter "launcher" "$@") || launcher_override=""
    backend="$(_knit_launch_backend "${launcher_override}")"
    _knit_launch_exec "${backend}" launch_opts -- \
        "${KNIT_SCRIPT_PATH}" _run -- "${app_name}" "${app_args[@]}"
}
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_run_resolve_placement()
#
# Resolve the three placement options (--procs, --procs-per-node, --hostnames)
# into a concrete (procs, procs-per-node, hosts) triple, stored by name into the
# caller's associative array (keys: procs, procs-per-node, hostnames). procs is
# always set; procs-per-node may be left empty (the launcher's default
# distribution applies); hostnames is always set to a comma-separated list.
#
# Let A be the job's allocated unique hosts (knit_job_hostnames), a = |A|; c the
# per-node core count (__node_ncpus__ metadata, may be unknown); n = --procs,
# p = --procs-per-node, H = --hostnames (k = |H|). Resolution:
#
#   1. Hosts. If --hostnames is given, each entry must be one of A (fatal
#      otherwise); else H defaults to A.
#   2/3. procs / procs-per-node. If both n and p are given they are used as-is
#      (see the consistency checks). If only n is given, H is respected; if H was
#      explicit, p is derived as n/k. If only p is given, n is derived as p*k. If
#      neither is given, n = c*k with p = c when c is known, else n = k (one rank
#      per node) with a warning.
#   4. Consistency (fatal on conflict): n and p given => require n%p==0
#      (kreq=n/p); with explicit H require k==kreq, else require kreq<=a and take
#      the first kreq hosts of A. n given without p but with explicit H => require
#      n%k==0 (p=n/k).
#
# @param out_name Name of the associative array to fill.
# @param ...      The dispatcher's invocation arguments (read via knit_get_parameter).
# ------------------------------------------------------------------------------
_knit_run_resolve_placement() {
    # shellcheck disable=SC2178 # nameref to the caller's associative array
    local -n _place="$1"
    shift

    local n p hosts
    n=$(knit_get_parameter "procs" "$@") || n=""
    p=$(knit_get_parameter "procs-per-node" "$@") || p=""
    hosts=$(knit_get_parameter "hostnames" "$@") || hosts=""

    # Allocation A: the deduplicated unique hosts of the surrounding job.
    local -a alloc=()
    mapfile -t alloc < <(knit_job_hostnames)
    local a="${#alloc[@]}"

    # Per-node core count c (empty means unknown: no profile and no detection).
    local c
    c="$(_knit_metadata_load --key "__node_ncpus__")"

    # Step 1: resolve the host list H.
    local -a host_list=()
    local hosts_explicit=0
    if [[ -n "${hosts}" ]]; then
        hosts_explicit=1
        IFS=',' read -r -a host_list <<< "${hosts}"
        local h ah in_alloc
        for h in "${host_list[@]}"; do
            in_alloc=0
            for ah in "${alloc[@]}"; do
                [[ "${ah}" == "${h}" ]] && { in_alloc=1; break; }
            done
            (( in_alloc )) || \
                knit_fatal "Placement error: host \"${h}\" is not in the job's allocation."
        done
    else
        host_list=("${alloc[@]}")
    fi
    local k="${#host_list[@]}"

    # Steps 2-4: resolve procs and procs-per-node, with consistency checks.
    if [[ -n "${n}" && -n "${p}" ]]; then
        (( n % p == 0 )) || \
            knit_fatal "Placement conflict: --procs ${n} is not divisible by --procs-per-node ${p}."
        local kreq=$(( n / p ))
        if (( hosts_explicit )); then
            (( k == kreq )) || \
                knit_fatal "Placement conflict: --procs ${n} with --procs-per-node ${p} needs ${kreq} nodes, but --hostnames lists ${k}."
        else
            (( kreq <= a )) || \
                knit_fatal "Placement conflict: --procs ${n} with --procs-per-node ${p} needs ${kreq} nodes, but the allocation has ${a}."
            host_list=("${alloc[@]:0:kreq}")
            k="${kreq}"
        fi
    elif [[ -n "${n}" && -z "${p}" ]]; then
        if (( hosts_explicit )); then
            (( n % k == 0 )) || \
                knit_fatal "Placement conflict: --procs ${n} is not divisible by the ${k} hosts in --hostnames."
            p=$(( n / k ))
        fi
        # Otherwise n is given over the default allocation; leave p unset so the
        # launcher applies its own distribution.
    elif [[ -z "${n}" && -n "${p}" ]]; then
        n=$(( p * k ))
    else
        # Nothing given: fill the allocation by the per-node core count when it is
        # known, else fall back to one rank per node.
        if [[ -n "${c}" ]]; then
            n=$(( c * k ))
            p="${c}"
        else
            n="${k}"
            knit_warning "Per-node core count unknown; placing one rank per node (${k} rank(s))."
        fi
    fi

    _place["procs"]="${n}"
    _place["procs-per-node"]="${p}"
    local joined=""
    if (( ${#host_list[@]} )); then
        printf -v joined '%s,' "${host_list[@]}"
        joined="${joined%,}"
    fi
    _place["hostnames"]="${joined}"
}

# ------------------------------------------------------------------------------
# @fn _knit_run_normalize_mpi_env()
#
# Normalize the launcher-native MPI environment into the launcher-agnostic
# KNIT_MPI_* variables the app body reads, and export them so every subprocess of
# the rank inherits them:
#
#   KNIT_MPI_RANK        rank in MPI_COMM_WORLD
#   KNIT_MPI_SIZE        size of MPI_COMM_WORLD
#   KNIT_MPI_LOCAL_RANK  node-local rank
#
# Each is taken from the first launcher that set it, by precedence
# (OpenMPI -> MPICH/PMI -> Slurm srun -> PALS), falling back to a single
# rank-0 / size-1 process when none are present (the `none` backend). Called once
# per rank by the worker, before forwarding to the app body.
# ------------------------------------------------------------------------------
_knit_run_normalize_mpi_env() {
    export KNIT_MPI_RANK="${OMPI_COMM_WORLD_RANK:-${PMI_RANK:-${SLURM_PROCID:-${PALS_RANKID:-0}}}}"
    export KNIT_MPI_SIZE="${OMPI_COMM_WORLD_SIZE:-${PMI_SIZE:-${SLURM_NTASKS:-1}}}"
    export KNIT_MPI_LOCAL_RANK="${OMPI_COMM_WORLD_LOCAL_RANK:-${PMI_LOCAL_RANK:-${SLURM_LOCALID:-${PALS_LOCAL_RANKID:-0}}}}"
}

knit_register _knit_run_worker "_run" "Per-rank worker for \`knit run\` (internal)."
knit_hidden
knit_with_extra "The app name and its arguments (after --)."
# ------------------------------------------------------------------------------
# @fn _knit_run_worker()
#
# Hidden per-rank worker executed once per rank under the launcher. The `run`
# dispatcher translates placement once and execs
# `<launcher> [flags] ./exp.sh _run -- <app> [app opts]`; this worker runs on
# every rank, then forwards to the app body by re-entering the command machinery
# as `run:<app>` (both tokens are non-"--", so this routes to the app, never back
# to the `run` dispatcher — there is no recursion).
#
# Each rank normalizes the launcher-native MPI environment into KNIT_MPI_*
# (via _knit_run_normalize_mpi_env) before forwarding to the app. Rank-0
# recording gating (M6) and re-sourcing the ambient setup environment (M8) are
# added in later milestones.
# ------------------------------------------------------------------------------
_knit_run_worker() {
    # TODO (M5/M7): fail here if this worker was reached by a direct invocation
    # (`knit _run <app>` or `knit run <app>` with no `--`) rather than through the
    # `run` dispatcher launching `... _run -- <app>`. The dispatcher should export
    # a per-invocation marker (e.g. KNIT_RUN_ID, forwarded to every rank by the
    # launcher) that the proper path always carries; its absence means a bypass of
    # the launcher/placement and must be rejected. That same marker also carries
    # the run uuid to rank 0 for the per-app row (see the M7 note in job.sh's
    # recording path).
    local args=("$@")
    local extra_index
    extra_index=$(knit_extra_index "${args[@]}")
    local extra=("${args[@]:extra_index}")

    if [[ ${#extra[@]} -eq 0 ]]; then
        knit_fatal "_run requires an app name (pass it after --)."
    fi

    local app_name="${extra[0]}"
    local app_args=("${extra[@]:1}")

    # Normalize this rank's launcher-native MPI environment into KNIT_MPI_* so the
    # app body reads a single, launcher-agnostic set of variables.
    _knit_run_normalize_mpi_env

    _knit_invoke_command "run" "${app_name}" "${app_args[@]}"
}
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_app_before_cb()
#
# Before-callback installed on every app subcommand by knit_register_app. Verifies
# that KNIT_JOB_PREFIX is set: an app only runs inside a job (launched by the
# `run` dispatcher and forwarded to each rank by the launcher), so its absence
# means the app command was invoked directly. Mirrors _knit_setup_before_cb /
# _knit_job_before_cb.
# ------------------------------------------------------------------------------
_knit_app_before_cb() {
    if [[ ! -v KNIT_JOB_PREFIX ]]; then
        knit_fatal "App commands must be invoked via \"knit run [OPTIONS] -- <app> [OPTIONS]\" inside a job, not directly."
    fi
}

# ------------------------------------------------------------------------------
# @fn knit_register_app()
#
# Register an app, i.e. a subcommand of the "run" command that executes as an MPI
# launch inside a job. Mirrors knit_register_job: it registers `run:<name>`, backs
# it with a per-app table named after the app, records the name in _KNIT_APPS, and
# installs a before-callback asserting the run context. Apps have no setup of
# their own (an app inherits the ambient setup of the surrounding job), so there
# is no knit_with_setup and no after-callback.
#
# A call to this function must be followed by any knit_with_* declarations, the
# definition of <fn>, and a call to knit_done.
#
# @param name        Short name for the app (used as the subcommand name).
# @param fn          Name of the Bash function implementing the app.
# @param description One-line description shown in `--help`.
#
# Example:
# ```
# knit_register_app "hello" "hello_fn" "Hello world MPI app."
# knit_with_optional "n:integer" "100" "Problem size."
# hello_fn() {
#   ...
# }
# knit_done
# ```
# ------------------------------------------------------------------------------
knit_register_app() {
    local name="$1"
    local fn="$2"
    local description="$3"
    knit_register "${fn}" "run:${name}" "${description}"
    # Record each app's invocations in a table named after the app itself (not
    # the "run:<name>" command name), so the table reads naturally and needs no
    # SQL quoting of the colon.
    knit_with_table "${name}"
    _KNIT_APPS["${name}"]=1
    _knit_run_before _knit_app_before_cb
}
