#!/bin/bash

## @file job.sh

# ------------------------------------------------------------------------------
# @var _KNIT_JOBS
#
# Associative array mapping registered job names to 1. Used to validate that
# a job names passed to `knit submit` is known.
# ------------------------------------------------------------------------------
declare -A _KNIT_JOBS

# ------------------------------------------------------------------------------
# @var _KNIT_JOB_SETUP
#
# Associative array mapping a job name to the setup type it requires (as declared
# with knit_with_setup). A job with no entry requires no setup, in which case
# `knit submit --setup` is optional for it.
# ------------------------------------------------------------------------------
declare -A _KNIT_JOB_SETUP

# ------------------------------------------------------------------------------
# Name of the table recording every submission and its lifecycle state. The row
# id is the job UUID; the "state" column moves submitted -> running -> completed,
# or -> killed when the scheduler terminates a job before it finishes.
# ------------------------------------------------------------------------------
__KNIT_SUBMISSIONS_TABLE="submissions"

knit_register __knit_submit "submit" "Submit a job."
knit_with_optional "setup:path" "" \
    "Path to the setup to use (required if the job declares a setup type)."
# Identity. Empty defaults are the "not set" sentinel: _knit_sched_resolve fills
# them from bootstrap metadata, the machine profile, or a hard-coded fallback.
knit_with_optional "job-name:string" "" \
    "Job name (default: the experiment script name)."
knit_with_optional "account:string" "" \
    "Account (default: the __account__ metadata)."
knit_with_optional "project:string" "" \
    "Project name (default: the __project__ metadata)."
knit_with_optional "queue:string" "" \
    "Queue/partition (default: the site default queue)."
# Resources. Knit allocates whole nodes exclusively: the per-node core count is
# taken from the machine profile (or bootstrap detection), not requested per
# submit, so there is no CPU option here.
knit_with_optional "nodes:integer" "1" "Number of nodes."
knit_with_optional "walltime:string" "" \
    "Wall-clock limit as HH:MM:SS (default: the site default)."
knit_with_optional "gpus-per-node:integer" "0" "GPUs per node."
# Behaviour. Job stdout/stderr are always written to <job-dir>/.stdout and
# <job-dir>/.stderr, so there are no output/error options.
knit_with_flag "wait" "Block until the job completes; return its exit code."
knit_with_extra "User-provided job command to execute"
knit_with_subcommand_title "Jobs"
# Record every submission as a row in the "submissions" table. The row id is the
# job UUID (set in __knit_submit); these outputs track the job and its state.
knit_with_table "${__KNIT_SUBMISSIONS_TABLE}"
knit_with_output "job:string" "" "Name of the submitted job (the token after --)."
knit_with_output "state:string" "submitted" "Lifecycle state of the submitted job."

# ------------------------------------------------------------------------------
# @fn __knit_submit()
#
# Entry point for the `submit` CLI command.
#
# Usage:
# ```
# ./exp.sh submit --setup /path/to/setup [sched-args...] -- job-name [args...]
# ```
# ------------------------------------------------------------------------------
__knit_submit() {
    # --setup is optional: it is required only for jobs that declare a setup
    # type (see knit_with_setup), so a missing value is not an error here.
    local setup_path
    setup_path=$(knit_get_parameter "setup" "$@") || setup_path=""

    # Extract extra args (after --): the job name and its arguments.
    local args=("$@")
    local extra_index
    extra_index=$(knit_extra_index "${args[@]}")
    local extra=("${args[@]:extra_index}")

    if [[ ${#extra[@]} -eq 0 ]]; then
        knit_fatal "submit requires a job name (pass it after --)."
    fi

    local job_name="${extra[0]}"
    local job_args=("${extra[@]:1}")

    # Check job name is registered
    if [[ ! -v _KNIT_JOBS["${job_name}"] ]]; then
        knit_fatal "Unknown job \"${job_name}\"."
    fi

    # Enforce the job's setup requirement (knit_with_setup). A job that declares
    # a setup type must be given a --setup built by that type; a job that
    # declares none makes --setup optional.
    local required_setup="${_KNIT_JOB_SETUP[${job_name}]:-}"
    if [[ -n "${required_setup}" && -z "${setup_path}" ]]; then
        knit_fatal "Job \"${job_name}\" requires a --setup of type \"${required_setup}\"."
    fi

    # Resolve the setup path (if any) to an absolute path. The generated batch
    # script cd's into the job directory before re-entering the experiment, so
    # every path baked into it (KNIT_SETUP_PREFIX, KNIT_JOB_PREFIX, the cd
    # target, and the backend's .stdout/.stderr paths, all derived from these)
    # must be absolute to survive that cd.
    if [[ -n "${setup_path}" ]]; then
        setup_path="$(realpath -m "${setup_path}" 2>/dev/null \
            || printf '%s' "${setup_path}")"
    fi

    # When the job requires a setup type, check the setup directory was built by
    # that type. `knit setup` records the type in a .setup.type marker.
    if [[ -n "${required_setup}" ]]; then
        local marker="${setup_path}/.setup.type"
        if [[ ! -f "${marker}" ]]; then
            knit_fatal "Setup at \"${setup_path}\" has no recorded type; job \"${job_name}\" requires a \"${required_setup}\" setup."
        fi
        local actual_setup=""
        IFS= read -r actual_setup < "${marker}" || true
        if [[ "${actual_setup}" != "${required_setup}" ]]; then
            knit_fatal "Job \"${job_name}\" requires a \"${required_setup}\" setup, but \"${setup_path}\" was built by \"${actual_setup}\"."
        fi
    fi

    # Validate args for the job subcommand (knit_fatal on bad args)
    local subcmd
    subcmd=$(__knit_command_mangle "submit:${job_name}")
    _knit_check_command_arguments "${subcmd}" "${job_args[@]}"

    # Create the job directory with a time-ordered uuidv7 name: under the setup
    # (<setup_path>/jobs/<uuid>) when a setup is used, else jobs/<uuid> in the
    # experiment directory.
    local uuid jobdir
    uuid=$(_knit_uuidv7)
    if [[ -n "${setup_path}" ]]; then
        jobdir="${setup_path}/jobs/${uuid}"
    else
        jobdir="$(realpath -m "jobs/${uuid}" 2>/dev/null \
            || printf '%s' "${PWD}/jobs/${uuid}")"
    fi
    mkdir -p "${jobdir}"

    # Record this submission: the recorded row's id is the canonical job
    # UUID, and the submissions table tracks the job name and lifecycle state.
    _knit_set_row_id "${uuid}"
    knit_output "job" "${job_name}"
    knit_output "state" "submitted"

    # Resolve the submission options (explicit args -> metadata -> profile ->
    # hard-coded) into an associative array. Note: the name "opts" must differ
    # from the nameref names used inside the sched_* helpers to avoid bash
    # circular-reference errors.
    # shellcheck disable=SC2034 # populated and read by name via the sched_* helpers
    declare -A opts
    _knit_sched_resolve opts "$@"

    # Fail fast if the request exceeds the target queue's profile caps, before
    # writing a script or contacting the scheduler.
    _knit_sched_validate_caps opts

    # Persist the submissions row now, before dispatching. This must precede a
    # blocking --wait submission: the job then runs (on this host for the local
    # backend, or on a compute node) and transitions this row's "state" while it
    # executes, so the row has to exist first. The automatic post-invocation
    # recording is idempotent and will not duplicate it.
    _knit_record_row_now "$@"

    # Pick the scheduler backend: bootstrap metadata, else live detection, with
    # "none" mapping to the local (no-scheduler) backend.
    local backend
    backend="$(_knit_metadata_load --key "__scheduler__")"
    [[ -z "${backend}" ]] && backend="$(_knit_detect_job_manager)"
    [[ "${backend}" == "none" ]] && backend="local"

    # Generate the batch script and submit it. The generated script exports
    # KNIT_JOB_PREFIX/KNIT_SETUP_PREFIX, cd's into the job directory, then calls
    # `path/to/exp.sh submit <job-name> [args...]` on the compute node.
    #
    # Note: `knit submit ... -- <job-name>` calls __knit_submit, while
    # `knit submit <job-name> [args]` is an actual invocation of the job's
    # registered function.
    local script="${jobdir}/.job.sh"
    _knit_sched_write_jobscript "${script}" "${backend}" opts \
        "${setup_path}" "${jobdir}" "${job_name}" "${job_args[@]}"

    local jobid
    jobid="$(_knit_sched_submit "${backend}" opts "${script}" "${jobdir}")"

    # Record the implementation-dependent launcher id in .job.id. The full
    # submission record lives in the "submissions" table (see M10/M11 recording).
    printf '%s\n' "${jobid}" > "${jobdir}/.job.id"

    # Return the job UUID (the canonical, scheduler-independent identifier). The
    # implementation-dependent launcher id lives only in .job.id.
    printf '%s\n' "${uuid}"
}
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_job_set_state()
#
# Update the lifecycle state of the running job's submissions row. Called on the
# compute side, where the experiment's .knit is shared over the parallel file
# system, so the row inserted by knit submit on the login node can be updated in
# place. The row id is the job UUID, i.e. the basename of KNIT_JOB_PREFIX (the
# job directory). Best-effort: status tracking must never take down the job
# itself, so a failure is downgraded to a warning.
#
# @param state New state value (e.g. running, completed, killed).
# ------------------------------------------------------------------------------
_knit_job_set_state() {
    local state="$1"
    [[ -v KNIT_JOB_PREFIX ]] || return 0
    _knit_is_bootstrapped || return 0
    local uuid
    uuid="$(basename "${KNIT_JOB_PREFIX}")"
    _knit_db_update_row "${__KNIT_SUBMISSIONS_TABLE}" "${uuid}" "state=${state}" \
        2>/dev/null \
        || knit_warning "Could not update job \"${uuid}\" state to \"${state}\"."
}

# ------------------------------------------------------------------------------
# @fn __knit_job_killed_trap()
#
# Signal handler installed while a job runs on the compute node. Schedulers warn
# a job before killing it: Slurm can send a chosen signal a configurable time
# before the walltime limit (requested via --signal in the batch directives) and
# sends SIGTERM before SIGKILL; PBS likewise sends SIGTERM before SIGKILL. This
# handler records the job as "killed" so its row does not stay stuck at
# "running", then exits so the after-callback (which would mark it "completed")
# does not run.
# ------------------------------------------------------------------------------
__knit_job_killed_trap() {
    _knit_job_set_state "killed"
    exit 143
}

# ------------------------------------------------------------------------------
# @fn __knit_job_before_cb()
#
# Before-callback installed on every setup subcommand by knit_register_job.
# Verifies that KNIT_JOB_PREFIX is set, ensuring the job was invoked through
# `knit submit` rather than called directly, installs the pre-termination signal
# handler, marks the job "running", and sources the setup environment when the
# job uses one.
# ------------------------------------------------------------------------------
__knit_job_before_cb() {
    if [[ ! -v KNIT_JOB_PREFIX ]]; then
        knit_fatal "Job commands must be invoked via \"knit submit\", not directly."
    fi
    # Catch the scheduler's pre-termination signal so an out-of-time or cancelled
    # job records "killed" before it is hard-killed (see __knit_job_killed_trap).
    trap '__knit_job_killed_trap' TERM USR1
    _knit_job_set_state "running"
    # Setup-less jobs (no knit_with_setup) run without a KNIT_SETUP_PREFIX, so
    # there is no environment to source.
    if [[ -n "${KNIT_SETUP_PREFIX:-}" ]]; then
        # shellcheck disable=SC1091
        source "${KNIT_SETUP_PREFIX}/.activate.sh"
    fi
}

# ------------------------------------------------------------------------------
# @fn __knit_job_after_cb()
#
# After-callback installed on every submit subcommand by knit_register_job.
# Marks the job "completed" once its body has returned normally.
# ------------------------------------------------------------------------------
__knit_job_after_cb() {
    _knit_job_set_state "completed"
}

# ------------------------------------------------------------------------------
# @fn knit_with_setup()
#
# Declare that the job currently being registered requires a setup of a given
# type. Must be called between knit_register_job and knit_done. The type is the
# name of a registered setup (as passed to knit_register_setup); `knit submit`
# then rejects a --setup directory that was not built by that setup, and makes
# --setup mandatory for the job. A job without any knit_with_setup declaration
# requires no setup, so --setup is optional for it.
#
# Example:
# ```
# knit_register_job "montecarlo" _montecarlo_job "Estimate pi as a job."
# knit_with_setup "mcenv"   # requires a setup built by the "mcenv" setup
# _montecarlo_job() { ... }
# knit_done
# ```
#
# @param type Name of the required setup type.
# ------------------------------------------------------------------------------
knit_with_setup() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]] \
    || [[ "${_KNIT_CURRENT_COMMAND_DEMANGLED}" != submit:* ]]; then
        knit_fatal "knit_with_setup must be called between knit_register_job and knit_done."
    fi
    local setup_type="$1"
    if ! __knit_name_is_valid "${setup_type}"; then
        knit_fatal "Setup type \"${setup_type}\" is not a valid name."
    fi
    local job_name
    job_name=$(__knit_command_get_last "${_KNIT_CURRENT_COMMAND_DEMANGLED}")
    knit_trace "Job \"${job_name}\" requires a \"${setup_type}\" setup."
    _KNIT_JOB_SETUP["${job_name}"]="${setup_type}"
}

# ------------------------------------------------------------------------------
# @fn knit_register_job()
#
# Register a job, i.e. a subcommand of the "submit" command that executes as a
# job sumitted on the supercomputer.
#
# A call to this function must be followed by any knit_with_* declarations,
# the definition of <fn>, and a call to knit_done.
#
# @param name        Short name for the job (used as the subcommand name).
# @param fn          Name of the Bash function implementing the job.
# @param description One-line description shown in `--help`.
#
# Example:
# ```
# knit_register_job "hello" "hello_fn" "Hello world job script."
# knit_with_optional "name:string" "Matthieu" "Name of the person to greet."
# hello_fn() {
#   ...
# }
# knit_done
# ```
# ------------------------------------------------------------------------------
knit_register_job() {
    local name="$1"
    local fn="$2"
    local description="$3"
    knit_register "${fn}" "submit:${name}" "${description}"
    knit_with_table
    _KNIT_JOBS["${name}"]=1
    _knit_run_before __knit_job_before_cb
    _knit_run_after  __knit_job_after_cb
}
