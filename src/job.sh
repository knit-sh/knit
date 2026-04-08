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
knit_with_extra "User-provided job command to execute"
knit_with_subcommand_title "Jobs"
# ------------------------------------------------------------------------------
# @fn __knit_submit()
#
# Entry point for the `submit` CLI command.
#
# Usage:
# ```
# ./exp.sh submit --setup </path/to/setup> -- <job-name> [args...]
# ```
# ------------------------------------------------------------------------------
__knit_submit() {
    local setup_path
    setup_path=$(knit_get_parameter "setup" "$@")

    # Extract extra args (after --)
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

    # TODO Create directory in the setup path
    # The directory name should be <setup_path>/jobs/<uuid>
    # where <uuid> is a randomly generate uuid string.

    # TODO In the job's newly created directory, create a job script
    # adapted to the platform's job manager (SLURM or PBS Pro)
    

    # TODO Export KNIT_JOB_PREFIX so jobs functions and callbacks can read it

    # TODO Export KNIT_SETUP_PREFIX from setup_path

    # Invoke the setup subcommand and capture its return value
    local ret=0
    _knit_invoke_command "submit" "${job_name}" "${job_args[@]}" || ret=$?

    # Get out of KNIT_JOB_PREFIX
    knit_popd
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
    # TODO save the environment before sourcing $KNIT_SETUP_PREFIX/.activate.sh
    source $KNIT_SETUP_PREFIX/.activate.sh
}

# ------------------------------------------------------------------------------
# @fn __knit_job_after_cb()
#
# After-callback installed on every submit subcommand by knit_register_job.
# ------------------------------------------------------------------------------
__knit_job_after_cb() {
    # TODO restore the environment as it was before
    # $KNIT_SETUP_PREFIX/.activate.sh was sourced
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
