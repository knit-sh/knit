#!/bin/bash

## @file job.sh

# ------------------------------------------------------------------------------
# @var _KNIT_JOBS
#
# Associative array mapping registered job names to 1. Used to validate that
# a job names passed to `knit submit` is known.
# ------------------------------------------------------------------------------
declare -A _KNIT_JOBS

knit_register __knit_submit "submit" "Submit a job."
knit_with_required "setup:path" "Path to the setup to use for the job."
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
    local setup_path
    setup_path=$(knit_get_parameter "setup" "$@")

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

    # Validate args for the job subcommand (knit_fatal on bad args)
    local subcmd
    subcmd=$(__knit_command_mangle "submit:${job_name}")
    _knit_check_command_arguments "${subcmd}" "${job_args[@]}"

    # Create the job directory <setup_path>/jobs/<uuid> with a time-ordered
    # uuidv7 name.
    local uuid jobdir
    uuid=$(_knit_uuidv7)
    jobdir="${setup_path}/jobs/${uuid}"
    mkdir -p "${jobdir}"

    # Resolve the submission options (explicit args -> metadata -> profile ->
    # hard-coded) into an associative array. Note: the name "opts" must differ
    # from the nameref names used inside the sched_* helpers to avoid bash
    # circular-reference errors.
    # shellcheck disable=SC2034 # populated and read by name via the sched_* helpers
    declare -A opts
    _knit_sched_resolve opts "$@"

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

    # Record the submission: the bare scheduler id in .job.id and the full
    # resolved options in .job.meta.
    printf '%s\n' "${jobid}" > "${jobdir}/.job.id"
    _knit_sched_write_jobmeta "${jobdir}" opts "${backend}" "${jobid}"

    printf '%s\n' "${jobid}"
}
knit_done

# ------------------------------------------------------------------------------
# @fn __knit_job_before_cb()
#
# Before-callback installed on every setup subcommand by knit_register_job.
# Verifies that KNIT_JOB_PREFIX is set, ensuring the job was invoked
# through `knit submit` rather than called directly.
# ------------------------------------------------------------------------------
__knit_job_before_cb() {
    if [[ ! -v KNIT_JOB_PREFIX ]]; then
        knit_fatal "Job commands must be invoked via \"knit submit\", not directly."
    fi
    # shellcheck disable=SC1091
    source "${KNIT_SETUP_PREFIX}/.activate.sh"
}

# ------------------------------------------------------------------------------
# @fn __knit_job_after_cb()
#
# After-callback installed on every submit subcommand by knit_register_job.
# ------------------------------------------------------------------------------
__knit_job_after_cb() {
    :
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
