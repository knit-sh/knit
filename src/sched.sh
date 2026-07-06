#!/bin/bash

## @file sched.sh

# ------------------------------------------------------------------------------
# Seconds before the walltime limit at which a scheduler is asked to warn the
# job (Slurm --signal). The warning lets the job record itself as "killed"
# before it is hard-killed (see _knit_job_killed_trap).
# ------------------------------------------------------------------------------
_KNIT_SCHED_KILL_WARNING_SEC="60"

# ------------------------------------------------------------------------------
# Seconds between polls when a backend has to wait for a job by polling its
# scheduler (Slurm squeue, PBS qstat — neither offers a reliable blocking
# "wait for completion" primitive). Overridable, chiefly so tests can drive the
# poll loops quickly.
# ------------------------------------------------------------------------------
declare _KNIT_SCHED_POLL_INTERVAL
_KNIT_SCHED_POLL_INTERVAL="${_KNIT_SCHED_POLL_INTERVAL:-5}"

# ------------------------------------------------------------------------------
# @fn _knit_uuidv7()
#
# Generate a version-7 UUID (RFC 9562) and print it to stdout.
#
# A uuidv7 encodes a 48-bit big-endian Unix millisecond timestamp in its leading
# bits, so lexically sorting uuidv7 strings orders them by creation time. This is
# why job directories are named with one: they sort chronologically.
#
# Layout (hex digits, formatted 8-4-4-4-12):
#   - digits  1-12 : 48-bit millisecond timestamp
#   - digit  13    : version nibble, always "7"
#   - digits 14-16 : random
#   - digit  17    : variant nibble, one of 8, 9, a, b
#   - digits 18-32 : random
#
# Randomness comes from /dev/urandom when available, falling back to the bash
# ${RANDOM} generator; the timestamp prefix guarantees ordering and near
# uniqueness even in the fallback case. The millisecond clock falls back to
# whole-second precision when `date` lacks nanosecond (%N) support.
# ------------------------------------------------------------------------------
_knit_uuidv7() {
    local ms
    ms="$(date +%s%3N 2>/dev/null)"
    if [[ ! "${ms}" =~ ^[0-9]+$ ]]; then
        ms=$(( $(date +%s) * 1000 ))
    fi

    local ts_hex
    ts_hex="$(printf '%012x' "${ms}")"
    # Keep the low 48 bits (12 hex digits) in case of an unexpectedly wide value.
    ts_hex="${ts_hex: -12}"

    local rand
    rand="$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null \
        | tr -d ' \n')"
    while [[ "${#rand}" -lt 32 ]]; do
        rand+="$(printf '%04x' "$(( RANDOM ))")"
    done

    # Variant nibble: top two bits "10" -> one of 8, 9, a, b.
    local variant
    variant=$(( (16#${rand:3:1} & 0x3) | 0x8 ))

    printf '%s-%s-7%s-%x%s-%s\n' \
        "${ts_hex:0:8}" "${ts_hex:8:4}" "${rand:0:3}" \
        "${variant}" "${rand:4:3}" "${rand:7:12}"
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_profile_field()
#
# Print a field from a machine profile's JSON, or nothing when the profile name
# is empty or unknown. A thin guard around knit_get_profile_field so callers can
# request a field unconditionally without emitting an "unknown profile" error.
#
# @param profile Profile name (may be empty).
# @param jq_path jq path expression, e.g. '.scheduler.default_queue'.
# ------------------------------------------------------------------------------
_knit_sched_profile_field() {
    local profile="$1"
    local jq_path="$2"
    if [[ -n "${profile}" ]] && knit_profile_exists "${profile}"; then
        knit_get_profile_field "${profile}" "${jq_path}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_resolve()
#
# Resolve the submission options for a job into a caller-provided associative
# array. For each option the value is resolved by precedence:
#
#   explicit CLI argument -> bootstrap metadata -> machine profile -> hard-coded
#
# The array is keyed by canonical option name (job-name, account, project,
# queue, nodes, cpus-per-node, walltime, gpus-per-node, wait) plus "extra-args"
# for the site-mandatory scheduler arguments captured at bootstrap. The per-node
# core count (cpus-per-node) is derived rather than requested (knit allocates
# whole nodes). Job stdout/stderr are fixed to <job-dir>/.stdout and
# <job-dir>/.stderr by the backend, so they are not resolved here.
#
# @param out_array Name of an associative array to populate (passed by name).
# @param ...       The submission CLI arguments (everything before "--").
# ------------------------------------------------------------------------------
_knit_sched_resolve() {
    local -n resolved="$1"
    shift
    local -a cli=("$@")

    local profile
    profile="$(_knit_metadata_load --key "__profile__")"

    local v

    # Identity ------------------------------------------------------------------
    v="$(knit_get_parameter "job-name" "${cli[@]}")" || v=""
    [[ -z "${v}" ]] && v="${KNIT_SCRIPT_NAME}"
    resolved["job-name"]="${v}"

    v="$(knit_get_parameter "account" "${cli[@]}")" || v=""
    [[ -z "${v}" ]] && v="$(_knit_metadata_load --key "__account__")"
    resolved["account"]="${v}"

    v="$(knit_get_parameter "project" "${cli[@]}")" || v=""
    [[ -z "${v}" ]] && v="$(_knit_metadata_load --key "__project__")"
    resolved["project"]="${v}"

    v="$(knit_get_parameter "queue" "${cli[@]}")" || v=""
    [[ -z "${v}" ]] && v="$(_knit_metadata_load --key "__default_queue__")"
    [[ -z "${v}" ]] && v="$(_knit_sched_profile_field "${profile}" '.scheduler.default_queue')"
    resolved["queue"]="${v}"

    # Resources -----------------------------------------------------------------
    v="$(knit_get_parameter "nodes" "${cli[@]}")" || v=""
    [[ -z "${v}" ]] && v="1"
    resolved["nodes"]="${v}"

    # Per-node core count is derived, not requested: knit allocates whole nodes,
    # so this comes from the bootstrap-detected/profile value. It drives ncpus and
    # mpiprocs on PBS and --ntasks-per-node on Slurm. Empty when unknown (no
    # profile and no detection); the backend then omits the per-node CPU directive.
    v="$(_knit_metadata_load --key "__node_ncpus__")"
    [[ -z "${v}" ]] && v="$(_knit_sched_profile_field "${profile}" '.hardware.cores_per_node')"
    resolved["cpus-per-node"]="${v}"

    v="$(knit_get_parameter "gpus-per-node" "${cli[@]}")" || v=""
    [[ -z "${v}" ]] && v="0"
    resolved["gpus-per-node"]="${v}"

    # Walltime falls back to the resolved queue's profile cap, then to one hour.
    v="$(knit_get_parameter "walltime" "${cli[@]}")" || v=""
    [[ -z "${v}" ]] && v="$(_knit_metadata_load --key "__default_walltime__")"
    if [[ -z "${v}" && -n "${resolved["queue"]}" ]]; then
        v="$(_knit_sched_profile_field "${profile}" \
            ".scheduler.queues.\"${resolved["queue"]}\".max_walltime")"
    fi
    [[ -z "${v}" ]] && v="01:00:00"
    resolved["walltime"]="${v}"

    # Behaviour -----------------------------------------------------------------
    v="$(knit_get_parameter "wait" "${cli[@]}")" || v="false"
    resolved["wait"]="${v}"

    # Site-mandatory scheduler arguments captured at bootstrap ------------------
    v="$(_knit_metadata_load --key "__default_scheduler_args__")"
    [[ -z "${v}" ]] && v="$(_knit_sched_profile_field "${profile}" \
        '(.scheduler.default_args // []) | join(" ")')"
    resolved["extra-args"]="${v}"
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_validate_caps()
#
# Fail fast, on the login node, when a resolved request exceeds the caps a
# machine profile declares for its target queue. This catches over-limit
# submissions before a batch script is written or handed to the scheduler.
#
# Caps come from the profile named by the "__profile__" metadata (nothing is
# checked when no profile or queue resolves, or when a given queue declares no
# cap). Walltime is compared in seconds via _knit_walltime_to_seconds; nodes as
# integers. Either breach is fatal.
#
# @param arr_name Name of the resolved-options associative array.
# ------------------------------------------------------------------------------
_knit_sched_validate_caps() {
    # shellcheck disable=SC2178 # nameref to the caller's associative array
    local -n resolved="$1"

    local profile
    profile="$(_knit_metadata_load --key "__profile__")"
    [[ -z "${profile}" ]] && return 0

    local queue="${resolved[queue]}"
    [[ -z "${queue}" ]] && return 0

    local max_walltime
    max_walltime="$(_knit_sched_profile_field "${profile}" \
        ".scheduler.queues.\"${queue}\".max_walltime")"
    if [[ -n "${max_walltime}" ]]; then
        local req_s cap_s
        req_s="$(_knit_walltime_to_seconds "${resolved[walltime]}")"
        cap_s="$(_knit_walltime_to_seconds "${max_walltime}")"
        if (( req_s > cap_s )); then
            knit_fatal "Requested walltime ${resolved[walltime]} exceeds the ${max_walltime} limit of queue \"${queue}\"."
        fi
    fi

    local max_nodes
    max_nodes="$(_knit_sched_profile_field "${profile}" \
        ".scheduler.queues.\"${queue}\".max_nodes")"
    if [[ -n "${max_nodes}" ]]; then
        local req_nodes="${resolved[nodes]}"
        if (( req_nodes > max_nodes )); then
            knit_fatal "Requested ${req_nodes} nodes exceeds the ${max_nodes}-node limit of queue \"${queue}\"."
        fi
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_directives()
#
# Dispatch to the configured backend's directive generator, printing the batch
# scheduler directive lines (e.g. "#SBATCH ..." / "#PBS ...") for the resolved
# options. The local and none backends print nothing.
#
# @param backend  Scheduler backend name ("local", "none", "slurm", "pbs").
# @param arr_name Name of the resolved-options associative array.
# @param jobdir   Job directory (used by backends for --output/--error paths).
# ------------------------------------------------------------------------------
_knit_sched_directives() {
    local backend="$1"
    local arr_name="$2"
    local jobdir="$3"
    case "${backend}" in
        local) _knit_sched_local_directives "${arr_name}" "${jobdir}" ;;
        none)  _knit_sched_none_directives "${arr_name}" "${jobdir}" ;;
        slurm) _knit_sched_slurm_directives "${arr_name}" "${jobdir}" ;;
        pbs)   _knit_sched_pbs_directives "${arr_name}" "${jobdir}" ;;
        *) knit_fatal "Scheduler backend not implemented: ${backend}" ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_submit()
#
# Dispatch to the configured backend's submission function, which submits the
# already-written batch script and prints the resulting scheduler job id (or, for
# the local/none backend, the process id) to stdout.
#
# @param backend  Scheduler backend name ("local", "none", "slurm", "pbs").
# @param arr_name Name of the resolved-options associative array.
# @param script   Path to the batch script to submit.
# @param jobdir   Job directory (holds .stdout/.stderr for local/none backends).
# ------------------------------------------------------------------------------
_knit_sched_submit() {
    local backend="$1"
    local arr_name="$2"
    local script="$3"
    local jobdir="$4"
    case "${backend}" in
        local) _knit_sched_local_submit "${arr_name}" "${script}" "${jobdir}" ;;
        none)  _knit_sched_none_submit "${arr_name}" "${script}" "${jobdir}" ;;
        slurm) _knit_sched_slurm_submit "${arr_name}" "${script}" "${jobdir}" ;;
        pbs)   _knit_sched_pbs_submit "${arr_name}" "${script}" "${jobdir}" ;;
        *) knit_fatal "Scheduler backend not implemented: ${backend}" ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_cancel()
#
# Dispatch to the configured backend's cancel function, which asks the scheduler
# to terminate a running job. Each backend uses its native primitive (local:
# kill, slurm: scancel, pbs: qdel). Cancelling a job that is already gone is not
# an error. Knit's terminal state (killed) is recorded by the caller.
#
# @param backend Scheduler backend name ("local", "none", "slurm", "pbs").
# @param jobid   Backend job id (scheduler id, or a PID for local/none backends).
# ------------------------------------------------------------------------------
_knit_sched_cancel() {
    local backend="$1"
    local jobid="$2"
    case "${backend}" in
        local) _knit_sched_local_cancel "${jobid}" ;;
        none)  _knit_sched_none_cancel "${jobid}" ;;
        slurm) _knit_sched_slurm_cancel "${jobid}" ;;
        pbs)   _knit_sched_pbs_cancel "${jobid}" ;;
        *) knit_fatal "Scheduler backend not implemented: ${backend}" ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_backend()
#
# Resolve which scheduler backend to use: bootstrap metadata (__scheduler__),
# else live detection. Detection's "<unknown>" (no batch scheduler present) means
# the workstation case and maps to the local background-process backend. An
# explicit "none" in metadata is a real, deliberate backend (a user-owned
# cluster driven without a scheduler) and flows through untouched. Prints one of
# "local", "none", "slurm", "pbs".
# ------------------------------------------------------------------------------
_knit_sched_backend() {
    local backend
    backend="$(_knit_metadata_load --key "__scheduler__")"
    [[ -z "${backend}" ]] && backend="$(_knit_detect_job_manager)"
    [[ "${backend}" == "<unknown>" ]] && backend="local"
    printf '%s\n' "${backend}"
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_wait()
#
# Dispatch to the configured backend's blocking wait, which returns once the
# scheduler no longer considers the job active. Each backend blocks using the
# native mechanism its scheduler actually provides (see the per-backend
# functions); knit's own terminal state (completed/killed) is read from the jobs
# table afterwards, so this only has to unblock when the job stops running.
#
# @param backend Scheduler backend name ("local", "none", "slurm", "pbs").
# @param jobid   Backend job id (scheduler id, or a PID for local/none backends).
# ------------------------------------------------------------------------------
_knit_sched_wait() {
    local backend="$1"
    local jobid="$2"
    case "${backend}" in
        local) _knit_sched_local_wait "${jobid}" ;;
        none)  _knit_sched_none_wait "${jobid}" ;;
        slurm) _knit_sched_slurm_wait "${jobid}" ;;
        pbs)   _knit_sched_pbs_wait "${jobid}" ;;
        *) knit_fatal "Scheduler backend not implemented: ${backend}" ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_hostfile()
#
# Print, one per line, the raw host entries a job is running on, as the current
# backend's scheduler reports them. Unlike the other dispatchers this resolves
# the backend itself (via _knit_sched_backend): it is meant to be called at
# runtime from inside a job body, where no backend has been resolved by a caller.
#
# The output is the "raw" host list: hostnames may be repeated (once per slot,
# e.g. PBS's $PBS_NODEFILE) or carry trailing ":N" info. Callers that want a
# deduplicated, cleaned list post-process it (see knit_job_hostnames).
# ------------------------------------------------------------------------------
_knit_sched_hostfile() {
    local backend
    backend="$(_knit_sched_backend)"
    case "${backend}" in
        local) _knit_sched_local_hostfile ;;
        none)  _knit_sched_none_hostfile ;;
        slurm) _knit_sched_slurm_hostfile ;;
        pbs)   _knit_sched_pbs_hostfile ;;
        *) knit_fatal "Scheduler backend not implemented: ${backend}" ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_sched_write_jobscript()
#
# Write the batch script that a scheduler runs on the compute node. The script
# carries the backend's directives, exports the job/setup prefixes, cd's into the
# job directory, and re-enters the experiment script to run the job body via
# `exp.sh submit <job-name> <args>`. Arguments are %q-quoted so they survive the
# round-trip through the batch script unchanged.
#
# @param script_path Path of the batch script to create.
# @param backend     Scheduler backend name.
# @param arr_name    Name of the resolved-options associative array.
# @param setup_path  Setup directory (exported as KNIT_SETUP_PREFIX; empty for
#                    a setup-less job, in which case KNIT_SETUP_PREFIX is not
#                    exported).
# @param jobdir      Job directory (exported as KNIT_JOB_PREFIX; the cd target).
# @param job_name    Registered job name to run.
# @param ...         Arguments to pass to the job.
# ------------------------------------------------------------------------------
_knit_sched_write_jobscript() {
    local script_path="$1"
    local backend="$2"
    local arr_name="$3"
    local setup_path="$4"
    local jobdir="$5"
    local job_name="$6"
    shift 6
    local -a job_args=("$@")

    {
        printf '#!/bin/bash\n'
        _knit_sched_directives "${backend}" "${arr_name}" "${jobdir}"
        printf 'export KNIT_JOB_PREFIX=%q\n' "${jobdir}"
        # Setup-less jobs (no knit_with_setup) carry no setup directory.
        if [[ -n "${setup_path}" ]]; then
            printf 'export KNIT_SETUP_PREFIX=%q\n' "${setup_path}"
            # Source the setup environment before re-entering the experiment.
            # Optional parameter defaults written as ENV[...] are resolved during
            # argument expansion, which happens before the job's before-callback
            # sources the environment, so the setup's exported variables must
            # already be present in this shell. They survive the exec below
            # because they are exported.
            printf 'source %q\n' "${setup_path}/.activate.sh"
        fi
        # Pass the experiment's .knit down: the cd below moves the compute-side
        # cwd away from the experiment root, so it can no longer be derived.
        printf 'export _KNIT_PREFIX=%q\n' "${_KNIT_PREFIX}"
        printf 'cd %q\n' "${jobdir}"
        printf 'exec %q submit %q' "${KNIT_SCRIPT_PATH}" "${job_name}"
        local arg
        for arg in "${job_args[@]}"; do
            printf ' %q' "${arg}"
        done
        printf '\n'
    } > "${script_path}"
}
