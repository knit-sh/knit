#!/bin/bash

## @file app.sh

# ------------------------------------------------------------------------------
# @var _KNIT_APPS
#
# Associative array mapping registered app names to 1. Used to validate that an
# app name passed to `knit run` is known. Mirrors _KNIT_JOBS for jobs.
# ------------------------------------------------------------------------------
declare -gA _KNIT_APPS

# ------------------------------------------------------------------------------
# @var _KNIT_RUNS_TABLE
#
# Name of the table recording every run: the app launched, the requested
# placement, and the launcher. The row id is the run's own UUID. The parent job
# and the rank-0 per-app row are linked through the provenance graph — the
# "submit:<job> -> run" and "run -> run:<app>" call edges — not through a stored
# column or a shared id (each mints its own distinct UUID).
# ------------------------------------------------------------------------------
declare -g _KNIT_RUNS_TABLE
_KNIT_RUNS_TABLE="runs"

knit_register "run" _knit_run "Run an application (MPI launch) inside a job."
_knit_is_builtin
# Placement (all optional). Empty means "not set": _knit_run_resolve_placement
# fills the missing values from the job's allocation and the per-node core count.
knit_with_optional "procs:integer" "" "Total number of ranks (MPI processes)."
knit_with_optional "procs-per-node:integer" "" "Ranks per node."
knit_with_optional "hostnames:string" "" \
    "Comma-separated subset of the job's allocated hosts to place on."
knit_with_optional "launcher:string" "" \
    "Override the launcher backend (none, openmpi, mpich, slurm, pbs, pals, flux)."
knit_with_optional "launcher-args:string" "" \
    "Extra arguments passed verbatim to the launcher."
# Per-rank resource placement (all optional; translated per backend, best-effort;
# a backend with no native flag warns and skips). --bind uses a normalized
# vocabulary (none, core, socket, numa, thread); other values pass through.
knit_with_optional "cpus-per-proc:integer" "" \
    "CPUs (hardware threads) reserved per rank."
knit_with_optional "bind:string" "" \
    "CPU binding policy (none, core, socket, numa, thread; other values pass through)."
knit_with_optional "gpus-per-proc:integer" "" \
    "GPUs reserved per rank."
knit_with_optional "gpu-bind:string" "" \
    "GPU binding policy (launcher-specific value, passed through)."
knit_with_dispatch "app" "User-provided app command to execute"
knit_with_subcommand_title "Apps"
# Record every run as a row in the "runs" table. The placement options above are
# recorded as-requested columns; the "app" output records the launched app name.
knit_with_table "${_KNIT_RUNS_TABLE}"
knit_with_output "app:string" "" "Name of the app that was run (the token after --)."
knit_with_output "native-cmd:string" "" \
    "The resolved launcher command that was issued (launcher flags plus worker)."

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

    # Usability pre-check (login side): fail fast before launching if the app
    # declares knit_usable_if predicates that do not hold. The per-rank re-entry
    # catches this too, but only after the launcher has spawned.
    local usable_reason=""
    if ! _knit_command_check_usable usable_reason "${subcmd}"; then
        knit_fatal "Command \"run:${app_name}\" cannot run: ${usable_reason}"
    fi

    _knit_check_command_arguments "${subcmd}" "${app_args[@]}"

    # Verify existence of, and hash, the app's checksummed file/directory inputs
    # once here, before any ranks are launched: a missing input fails fast, and
    # each input is hashed exactly once (never per rank). The bare digests are
    # forwarded to rank 0 through the launcher environment below so the app's row
    # records them without any rank touching the filesystem.
    declare -A input_digests=()
    if _knit_set_exists "_KNIT_CMD_${subcmd}_fileparams"; then
        local -a expanded_app_args
        readarray -d '' -t expanded_app_args \
            < <(_knit_expand_command_arguments "${subcmd}" "${app_args[@]}")
        _knit_run_checksum_inputs input_digests "${subcmd}" "${expanded_app_args[@]}"
    fi

    # Resolve placement into the launcher options (procs, procs-per-node,
    # hostnames), then add the raw --launcher-args passthrough. This single array
    # is exactly what the launcher backend reads (by name, in _knit_launch_exec).
    declare -A launch_opts
    _knit_run_resolve_placement launch_opts "$@"
    local launcher_args
    launcher_args=$(knit_get_parameter "launcher-args" "$@") || launcher_args=""
    # shellcheck disable=SC2034 # array is read by name in _knit_launch_exec
    launch_opts["launcher-args"]="${launcher_args}"

    # Per-rank resource placement, passed straight through to the launcher backend
    # (each backend translates or warns+skips per its capabilities). These are
    # orthogonal to the rank-count triple, so the resolver above ignores them.
    local cpus_per_proc bind_policy gpus_per_proc gpu_bind
    cpus_per_proc=$(knit_get_parameter "cpus-per-proc" "$@") || cpus_per_proc=""
    bind_policy=$(knit_get_parameter "bind" "$@") || bind_policy=""
    gpus_per_proc=$(knit_get_parameter "gpus-per-proc" "$@") || gpus_per_proc=""
    gpu_bind=$(knit_get_parameter "gpu-bind" "$@") || gpu_bind=""
    # shellcheck disable=SC2034 # array is read by name in _knit_launch_exec
    launch_opts["cpus-per-proc"]="${cpus_per_proc}"
    # shellcheck disable=SC2034 # array is read by name in _knit_launch_exec
    launch_opts["bind"]="${bind_policy}"
    # shellcheck disable=SC2034 # array is read by name in _knit_launch_exec
    launch_opts["gpus-per-proc"]="${gpus_per_proc}"
    # shellcheck disable=SC2034 # array is read by name in _knit_launch_exec
    launch_opts["gpu-bind"]="${gpu_bind}"

    # Record this run in the runs table under a fresh uuid, the run's id. The app
    # runs in the job's directory, so there is no run directory to create.
    local uuid
    uuid=$(_knit_uuidv7)
    _knit_set_row_id "${uuid}"
    knit_output "app" "${app_name}"

    # Resolve the launcher backend (per-run --launcher override -> concrete
    # __launcher__ metadata -> a providing setup's KNIT_PROVIDED_LAUNCHER, with
    # the no-launcher case mapping to none). The resolved backend overwrites the
    # runs row's as-requested "launcher" column below, alongside the resolved
    # placement.
    local launcher_override resolved_backend
    launcher_override=$(knit_get_parameter "launcher" "$@") || launcher_override=""
    _knit_launch_backend resolved_backend "${launcher_override}"

    # Build the exact command that will run: the launcher argv (the launcher plus
    # the translated placement flags) followed by the per-rank worker re-entry.
    # This is what _knit_launch_exec runs below; it is built here as well so the
    # resolved command can be recorded in the runs table and logged before it is
    # issued (building it twice is cheap and keeps the exec path unchanged).
    local -a launch_argv=()
    _knit_launch_cmdline "${resolved_backend}" launch_opts launch_argv
    launch_argv+=("${KNIT_SCRIPT_PATH}" _run -- "${app_name}" "${app_args[@]}")
    local native_cmd
    native_cmd=$(_knit_str_render_cmd launch_argv)
    knit_output "native-cmd" "${native_cmd}"

    # Persist the runs row now, before launching, so even a failed launch leaves a
    # trace. The row first records the placement options as requested; then the
    # placement columns and the launcher are overwritten with the resolved values
    # (a bare `knit run -- app` requests nothing, but the row must record what
    # actually ran). The native command is recorded as resolved above. The
    # automatic post-invocation recording is idempotent and will not duplicate
    # this row.
    _knit_record_row_now "$@"
    if _knit_is_bootstrapped; then
        _knit_db_update_row "${_KNIT_RUNS_TABLE}" "${uuid}" \
            "procs=${launch_opts["procs"]}" \
            "procs-per-node=${launch_opts["procs-per-node"]}" \
            "hostnames=${launch_opts["hostnames"]}" \
            "launcher=${resolved_backend}"
    fi

    # Log the resolved command before issuing it, then launch the per-rank worker
    # under the resolved backend and return its status. The worker re-enters this
    # experiment as the hidden `_run` verb; the launcher forwards the job's
    # exported KNIT_* environment to every rank.
    knit_trace "Running app \"${app_name}\": ${native_cmd}"

    # Launch in a subshell so the exported context is scoped to the launcher and
    # the ranks it spawns: the launcher forwards it to every rank. Every
    # invocation now mints its own distinct row id, so KNIT_RUN_ID no longer
    # serves as the per-app row id; it is retained for env forwarding and rank
    # gating. KNIT_SOURCE_ID / KNIT_SOURCE_COMMAND carry this run as the source
    # context so the rank-0 per-app body records a call edge run -> run:<app>
    # (the app body has no in-process caller across the launcher, so it reads
    # these carriers). Exporting in a subshell keeps them out of the job body.
    local run_status
    (
        export KNIT_RUN_ID="${uuid}"
        export KNIT_SOURCE_ID="${uuid}"
        export KNIT_SOURCE_COMMAND=run
        # Forward each input's precomputed digest so rank 0 records it verbatim
        # (KNIT_CHECKSUM_<param> = bare 64-hex; the recorder re-applies the
        # sha256: prefix). Exported inside this subshell so the digests reach the
        # ranks through the launcher but never leak into the job body.
        local _digest_param
        for _digest_param in "${!input_digests[@]}"; do
            export "KNIT_CHECKSUM_${_digest_param}=${input_digests[${_digest_param}]}"
        done
        # Re-enter each rank from the directory holding the experiment script
        # (and knit.sh) so a bare `source knit.sh` resolves, then have the
        # framework jump back to the run's cwd once sourcing completes (see
        # _KNIT_JUMP_TO_DIR). Using $PWD (not KNIT_JOB_PREFIX) preserves "ranks
        # run where knit run was called" even for a top-level run outside a job.
        # This is scoped to the launcher subshell, so the job body's cwd is
        # untouched. It must be exported so the launcher forwards it to every
        # rank: main.sh consumes and unsets _KNIT_JUMP_TO_DIR on the job body's
        # own re-entry, and unset strips the export attribute, so its -gx
        # declaration no longer applies here.
        export _KNIT_JUMP_TO_DIR="${PWD}"
        cd "$(dirname "${KNIT_SCRIPT_PATH}")" \
            || knit_fatal "cannot cd to the experiment script directory"
        _knit_launch_exec "${resolved_backend}" launch_opts -- \
            "${KNIT_SCRIPT_PATH}" _run -- "${app_name}" "${app_args[@]}"
    )
    run_status=$?

    # After the launcher returns, on a successful run, verify existence of and
    # hash the app's checksummed outputs once here (never on a rank) and update
    # rank 0's per-app row. Rank 0 recorded only the output paths; hashing after
    # launch keeps it off every rank and out of every measured duration.
    if [[ "${run_status}" -eq 0 ]]; then
        _knit_run_checksum_outputs "${subcmd}" "${app_name}" "${uuid}"
    fi
    return "${run_status}"
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
# @param[out] out_name Name of the associative array to fill.
# @param[in] ...      The dispatcher's invocation arguments (read via knit_get_parameter).
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
    _knit_metadata_get c "__node_ncpus__"

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
# @fn _knit_run_checksum_inputs()
#
# Verify existence of, and hash, every checksummed file/directory input of an app
# once, on the login side, before it is launched. A missing input then fails fast
# — before an allocation is used or ranks are spawned — and each input is hashed
# exactly once rather than once per rank. The bare digests are returned by name
# (param -> 64-hex); the dispatcher forwards them to rank 0 through the launcher
# environment (KNIT_CHECKSUM_<param>) so the app's row records the same digest
# without any rank touching the filesystem. Existence is checked for every
# file/directory input, even one that opted out of the digest with --no-checksum;
# only a checksummed input is hashed.
#
# @param[out] out_name Name of the associative array to fill (param -> bare 64-hex).
# @param[in] subcmd   Mangled app command name (run:<app>).
# @param[in] ...      The app's expanded invocation arguments.
# ------------------------------------------------------------------------------
_knit_run_checksum_inputs() {
    # shellcheck disable=SC2178 # nameref to the caller's associative array
    local -n _digests="$1"
    shift
    local subcmd="$1"
    shift
    local -a app_args=("$@")
    local demangled
    demangled=$(_knit_command_demangle "${subcmd}")
    local param
    while IFS= read -r param; do
        [[ -z "${param}" ]] && continue
        local marker_var="_KNIT_CMD_${subcmd}_fileparam_${param}"
        local marker="${!marker_var:-}"
        [[ "${marker}" == input:* ]] || continue
        local rest="${marker#input:}"
        local kind="${rest%%:*}"
        local checksum="${rest##*:}"
        local value
        value="$(knit_get_parameter "${param}" "${app_args[@]}")" || value=""
        # An absent optional input records no checksum and is not checked.
        [[ -z "${value}" ]] && continue
        _knit_checksum_require_exists "${demangled}" input "${param}" "${kind}" "${value}"
        [[ "${checksum}" == "yes" ]] || continue
        local hex
        _knit_sha256 hex "${value}"
        # shellcheck disable=SC2034 # written through the nameref
        _digests["${param}"]="${hex}"
    done < <(_knit_set_iter "_KNIT_CMD_${subcmd}_fileparams")
}

# ------------------------------------------------------------------------------
# @fn _knit_run_checksum_outputs()
#
# Verify existence of, and hash, every checksummed file/directory output of an
# app once, on the login side, after the launcher returns — never on a rank. An
# app's body runs on every rank, but only rank 0 records the per-app row, and it
# records only the output paths (the checksum columns are left empty by the M4
# output hook, which no-ops in an app worker). Hashing here, after launch, keeps
# it off every rank and out of every measured duration: hashing on rank 0 would
# keep the launcher blocked while the other ranks idle at finalize, inflating the
# run's measured wall-clock.
#
# Rank 0's per-app row is found through the provenance graph: the "run -> run:app"
# call edge (source_id is this run's UUID) points at the row's id. For each
# checksummed output, the recorded path is read back from that row, its existence
# verified (a missing output on a successful run is fatal), the digest computed,
# and the row's companion "<param>_checksum" column updated. An output left with
# no value, or one that opted out with --no-checksum, is skipped. When nothing
# was recorded (recording disabled, or no such row) this is a no-op.
#
# @param[in] subcmd   Mangled app command name (run:<app>).
# @param[in] app_name The app name (its table is named after it).
# @param[in] run_uuid This run's UUID (source of the provenance edge to the row).
# ------------------------------------------------------------------------------
_knit_run_checksum_outputs() {
    local subcmd="$1"
    local app_name="$2"
    local run_uuid="$3"
    _knit_is_bootstrapped || return 0
    _knit_set_exists "_KNIT_CMD_${subcmd}_fileparams" || return 0

    local demangled
    demangled=$(_knit_command_demangle "${subcmd}")

    # Locate rank 0's per-app row via the run -> run:<app> call edge. Its target
    # is the row's id; absent when nothing was recorded (e.g. recording disabled).
    local sid_esc tname_esc row_id
    _knit_sql_escape sid_esc "${run_uuid}"
    _knit_sql_escape tname_esc "${demangled}"
    row_id=$(_knit_sqlite3 \
        "SELECT target_id FROM ${_KNIT_PROV_TABLE} WHERE source_id='${sid_esc}' AND target_name='${tname_esc}' AND edge_type='call' LIMIT 1;" \
        2>/dev/null) || row_id=""
    [[ -n "${row_id}" ]] || return 0

    local table_ident id_ident rid_esc
    _knit_db_sql_ident table_ident "${app_name}"
    _knit_db_sql_ident id_ident "id"
    _knit_sql_escape rid_esc "${row_id}"

    local param
    while IFS= read -r param; do
        [[ -z "${param}" ]] && continue
        local marker_var="_KNIT_CMD_${subcmd}_fileparam_${param}"
        local marker="${!marker_var:-}"
        [[ "${marker}" == output:* ]] || continue
        local rest="${marker#output:}"
        local kind="${rest%%:*}"
        local checksum="${rest##*:}"
        [[ "${checksum}" == "yes" ]] || continue
        # Read the recorded path back from rank 0's row.
        local col_ident value
        _knit_db_sql_ident col_ident "${param}"
        value=$(_knit_sqlite3 \
            "SELECT ${col_ident} FROM ${table_ident} WHERE ${id_ident}='${rid_esc}';" \
            2>/dev/null) || value=""
        # An output left with no value has no path to check or hash.
        [[ -z "${value}" ]] && continue
        _knit_checksum_require_exists "${demangled}" output "${param}" "${kind}" "${value}"
        local hex
        _knit_sha256 hex "${value}"
        _knit_db_update_row "${app_name}" "${row_id}" "${param}_checksum=sha256:${hex}"
    done < <(_knit_set_iter "_KNIT_CMD_${subcmd}_fileparams")
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
# (OpenMPI -> MPICH/PMI -> Slurm srun -> PALS -> Flux), falling back to a single
# rank-0 / size-1 process when none are present (the `none` backend). Called once
# per rank by the worker, before forwarding to the app body.
# ------------------------------------------------------------------------------
_knit_run_normalize_mpi_env() {
    export KNIT_MPI_RANK="${OMPI_COMM_WORLD_RANK:-${PMI_RANK:-${SLURM_PROCID:-${PALS_RANKID:-${FLUX_TASK_RANK:-0}}}}}"
    export KNIT_MPI_SIZE="${OMPI_COMM_WORLD_SIZE:-${PMI_SIZE:-${SLURM_NTASKS:-${FLUX_JOB_SIZE:-1}}}}"
    export KNIT_MPI_LOCAL_RANK="${OMPI_COMM_WORLD_LOCAL_RANK:-${PMI_LOCAL_RANK:-${SLURM_LOCALID:-${PALS_LOCAL_RANKID:-${FLUX_TASK_LOCAL_ID:-0}}}}}"
}

knit_register "_run" _knit_run_worker "Per-rank worker for \`knit run\` (internal)."
_knit_is_builtin
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
# (via _knit_run_normalize_mpi_env) before forwarding to the app, and every rank
# but rank 0 sets _KNIT_RECORDING_SUPPRESSED so a run's outputs and per-app row
# are recorded exactly once.
#
# By default an app has no setup of its own: it inherits the surrounding job's
# setup environment (forwarded by the launcher). An app may still declare
# knit_with_setup to explicitly depend on and re-source a setup (see
# knit_register_app).
# ------------------------------------------------------------------------------
_knit_run_worker() {
    # The dispatcher exports KNIT_RUN_ID (the run UUID) and the run's provenance
    # context (KNIT_SOURCE_ID / KNIT_SOURCE_COMMAND) into the launcher's
    # environment; the launcher forwards them to every rank. Rank 0 records the
    # per-app row under a fresh distinct id and a provenance edge from the run
    # (read from the exported context) links it back to the runs-table row.
    # Rejecting a direct invocation that bypasses the dispatcher (KNIT_RUN_ID
    # absent) is deferred to a later hardening pass; the app before-callback
    # guards KNIT_JOB_PREFIX.
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

    # Every rank re-enters run:<app>, but only rank 0 records: its outputs, its
    # per-app row, and the provenance call edge run -> run:<app> (the source
    # context comes from the KNIT_SOURCE_* env the dispatcher exported). Suppress
    # recording on all other ranks via the generic CLI flag (knit_output no-ops,
    # and _knit_record_invocation writes neither row nor edge when set). We may
    # later allow non-zero ranks to record per-rank rows/edges; for now a run is
    # a single logical invocation recorded once.
    if [[ "${KNIT_MPI_RANK}" != "0" ]]; then
        _KNIT_RECORDING_SUPPRESSED="1"
    fi

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
# installs a before-callback asserting the run context. An app inherits the
# ambient setup of the surrounding job by default, but may declare knit_with_setup
# to explicitly depend on and re-source a setup. There is no after-callback.
#
# A call to this function must be followed by any knit_with_* declarations, the
# definition of <fn>, and a call to knit_done.
#
# @param[in] name        Short name for the app (used as the subcommand name).
# @param[in] fn          Name of the Bash function implementing the app.
# @param[in] description One-line description shown in `--help`.
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
    knit_register "run:${name}" "${fn}" "${description}"
    # Record each app's invocations in a table named after the app itself (not
    # the "run:<name>" command name), so the table reads naturally and needs no
    # SQL quoting of the colon.
    knit_with_table "${name}"
    _KNIT_APPS["${name}"]=1
    printf -v "_KNIT_CMD_${_KNIT_CURRENT_COMMAND}_type" '%s' 'app'
    _knit_run_before _knit_app_before_cb
}
