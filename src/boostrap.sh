#!/bin/bash

## @file boostrap.sh

# ------------------------------------------------------------------------------
# Prefix directory for Knit's local installation.
# ------------------------------------------------------------------------------
declare -g _KNIT_PREFIX
# Honour an inherited _KNIT_PREFIX so a submitted job, whose batch script cd's
# into its (deep) job directory before re-entering the experiment, can still
# locate the experiment's .knit rather than deriving a wrong one from its cwd.
# A normal invocation leaves it unset and defaults to <cwd>/.knit.
_KNIT_PREFIX="${_KNIT_PREFIX:-$(pwd)/.knit}"

# ------------------------------------------------------------------------------
# @var _KNIT_IS_BOOTSTRAPPED
#
# Cache for _knit_is_bootstrapped(). Empty means "not yet checked"; "1" means
# the positive result has been confirmed and the filesystem need not be
# re-checked.
# ------------------------------------------------------------------------------
declare -g _KNIT_IS_BOOTSTRAPPED
_KNIT_IS_BOOTSTRAPPED=""

# ------------------------------------------------------------------------------
# @fn _knit_is_bootstrapped()
#
# Return 0 if the experiment has been bootstrapped (i.e. _KNIT_PREFIX exists),
# 1 otherwise.
#
# The positive result is cached in _KNIT_IS_BOOTSTRAPPED so that repeated
# calls within the same session avoid redundant filesystem accesses.  The
# negative result is never cached: the directory may be created at any moment
# by a bootstrap invocation in the same session.
# ------------------------------------------------------------------------------
_knit_is_bootstrapped() {
    if [[ "${_KNIT_IS_BOOTSTRAPPED}" == "1" ]]; then
        return 0
    fi
    if [[ -d "${_KNIT_PREFIX}" ]]; then
        _KNIT_IS_BOOTSTRAPPED="1"
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# @fn __knit_bootstrap_on_exit()
#
# Clean up on exit if bootstrap did not complete successfully.
# ------------------------------------------------------------------------------
__knit_bootstrap_on_exit() {
    if [ -z "${__KNIT_BOOTSTRAP_COMPLETED}" ]; then
        knit_warning "Bootstrap did not complete successfully, deleting ${_KNIT_PREFIX}"
        rm -rf "${_KNIT_PREFIX}" > "${_KNIT_TRACE_FILE}" 2>&1
    fi
}

# ------------------------------------------------------------------------------
# Bootstrap the Knit framework.
#
# @param ... Arguments for bootstrap.
# ------------------------------------------------------------------------------
knit_define_enum "__scheduler__" "auto" "slurm" "pbs" "local"
knit_define_enum "__launcher__"  "auto" "openmpi" "mpich" "pals"
knit_register _knit_bootstrap "bootstrap" "Bootstrap the Knit framework."
knit_with_flag "spack" "Whether to download spack."
knit_with_optional "project:string" "" "Name of the project to use when submitting jobs."
knit_with_optional "profile:string" "" \
    "Machine profile name (e.g. polaris). Prepopulates scheduler, launcher, and hardware defaults."
knit_with_optional "scheduler:__scheduler__" "auto" \
    "Batch job scheduler. One of: auto, slurm, pbs. With auto the scheduler is detected automatically."
knit_with_optional "launcher:__launcher__" "auto" \
    "MPI launcher. One of: auto, openmpi, mpich, pals. With auto the launcher is detected automatically."
# ------------------------------------------------------------------------------
# @fn _knit_bootstrap()
#
# Bootstrap the Knit framework.
#
# @param ... Arguments for bootstrap.
# ------------------------------------------------------------------------------
_knit_bootstrap() {
    local project
    local need_spack
    local profile
    local scheduler
    local launcher
    project="$(knit_get_parameter "project" "$@")"
    need_spack="$(knit_get_parameter "spack" "$@")"
    profile="$(knit_get_parameter "profile" "$@")"
    scheduler="$(knit_get_parameter "scheduler" "$@")"
    launcher="$(knit_get_parameter "launcher" "$@")"

    if [[ -n "${profile}" ]] && ! knit_profile_exists "${profile}"; then
        knit_fatal "Unknown profile: ${profile}. Run 'knit profile list' to see available profiles."
    fi

    # Create directory
    if [ -d "${_KNIT_PREFIX}" ]; then
        knit_fatal "Knit is already bootstrapped."
    fi
    knit_trace "Creating ${_KNIT_PREFIX} directory"
    mkdir "${_KNIT_PREFIX}" > "${_KNIT_TRACE_FILE}" 2>&1
    trap __knit_bootstrap_on_exit EXIT

    if [[ "${need_spack}" == "true" ]]; then
        knit_trace "Bootstrapping spack..."
        _knit_bootstrap_spack
    fi

    knit_trace "Bootstrapping sqlite..."
    _knit_bootstrap_sqlite

    knit_trace "Bootstrapping jq..."
    _knit_bootstrap_jq

    # Load profile defaults (jq is now available).
    local default_queue=""
    local default_scheduler_args=""
    local default_launcher_args=""
    local node_ncpus=""
    local node_ngpus=""
    if [[ -n "${profile}" ]]; then
        knit_trace "Loading profile ${profile}..."
        _knit_load_profile "${profile}"
        default_queue="${_KNIT_PROFILE_SCHEDULER_DEFAULT_QUEUE}"
        default_scheduler_args="${_KNIT_PROFILE_SCHEDULER_DEFAULT_ARGS}"
        default_launcher_args="${_KNIT_PROFILE_LAUNCHER_DEFAULT_ARGS}"
        node_ncpus="${_KNIT_PROFILE_CORES_PER_NODE}"
        node_ngpus="${_KNIT_PROFILE_GPUS_PER_NODE}"
        # Use profile values as defaults when explicit args are "auto".
        if [[ "${scheduler}" == "auto" && -n "${_KNIT_PROFILE_SCHEDULER_TYPE}" ]]; then
            scheduler="${_KNIT_PROFILE_SCHEDULER_TYPE}"
        fi
        if [[ "${launcher}" == "auto" && -n "${_KNIT_PROFILE_LAUNCHER_TYPE}" ]]; then
            launcher="${_KNIT_PROFILE_LAUNCHER_TYPE}"
        fi
    fi

    if [[ "${scheduler}" == "auto" ]]; then
        scheduler="$(_knit_detect_job_manager)"
        if [[ "${scheduler}" == "none" ]]; then
            knit_warning "No job scheduler detected; using local process execution." \
                "Pass --scheduler local to suppress this warning."
            scheduler="local"
        fi
    fi
    if [[ "${launcher}" == "auto" ]]; then
        launcher="$(_knit_detect_launcher)"
    fi

    knit_trace "Writing initial metadata..."
    knit metadata store --key "__project__"                --value "${project}"
    knit metadata store --key "__profile__"                --value "${profile}"
    knit metadata store --key "__scheduler__"              --value "${scheduler}"
    knit metadata store --key "__launcher__"               --value "${launcher}"
    knit metadata store --key "__default_queue__"          --value "${default_queue}"
    knit metadata store --key "__default_scheduler_args__" --value "${default_scheduler_args}"
    knit metadata store --key "__default_launcher_args__"  --value "${default_launcher_args}"
    knit metadata store --key "__node_ncpus__"             --value "${node_ncpus}"
    knit metadata store --key "__node_ngpus__"             --value "${node_ngpus}"

    # Bootstrap completed successfully
    __KNIT_BOOTSTRAP_COMPLETED="true"
}
knit_done
