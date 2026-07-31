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
# @fn _knit_bootstrap_on_exit()
#
# Clean up on exit if bootstrap did not complete successfully.
# ------------------------------------------------------------------------------
_knit_bootstrap_on_exit() {
    if [ -z "${_KNIT_BOOTSTRAP_COMPLETED}" ]; then
        knit_warning "Bootstrap did not complete successfully, deleting ${_KNIT_PREFIX}"
        _knit_ensure_trace_file
        rm -rf "${_KNIT_PREFIX}" > "${_KNIT_TRACE_FILE}" 2>&1
    fi
}

# ------------------------------------------------------------------------------
# Bootstrap the Knit framework.
#
# @param ... Arguments for bootstrap.
# ------------------------------------------------------------------------------
knit_define_enum "__scheduler__" "auto" "slurm" "pbs" "local" "none"
_knit_is_builtin
knit_define_enum "__launcher__"  "auto" "openmpi" "mpich" "pals"
_knit_is_builtin
knit_register _knit_bootstrap "bootstrap" "Bootstrap the Knit framework."
_knit_is_builtin
knit_usable_before_bootstrap
knit_with_optional "spack:string" "" \
    "Spack git ref (tag, branch, or commit) to provision. Empty uses the latest release. Provisioning also happens automatically when a setup declares a Spack environment."
knit_with_optional "spack-packages:string" "" \
    "spack-packages git ref (tag, branch, or commit) to provision. Empty uses the latest release."
knit_with_optional "project:string" "" "Name of the project to use when submitting jobs."
knit_with_optional "profile:string" "" \
    "Machine profile name (e.g. polaris). Prepopulates scheduler, launcher, and hardware defaults."
knit_with_optional "scheduler:__scheduler__" "auto" \
    "Batch job scheduler. One of: auto, slurm, pbs, local, none. With auto the scheduler is detected automatically. Use none for a self-managed cluster (no scheduler); pair it with --default-nodefile."
knit_with_optional "launcher:__launcher__" "auto" \
    "MPI launcher. One of: auto, openmpi, mpich, pals. With auto the launcher is detected automatically."
knit_with_optional "account:string" "" \
    "Account/allocation to charge submitted jobs to."
knit_with_optional "default-walltime:string" "" \
    "Default job wall-clock limit as HH:MM:SS (default: the profile's default-queue cap)."
knit_with_optional "default-cpus-per-node:string" "" \
    "Cores per node for whole-node allocation (default: profile hardware, else live detection)."
knit_with_optional "default-nodefile:string" "" \
    "Path to a file listing cluster nodes (one host per line). Used by the 'none' scheduler to report a job's allocation."
knit_with_flag "ignore-system-sqlite" \
    "Build sqlite from source even if a system sqlite3 is available."
knit_with_flag "ignore-system-jq" \
    "Download jq even if a system jq is available."
knit_with_optional "knit-graph-version:string" "" \
    "knit-graph release version to provision. Empty uses the pinned default."
knit_with_optional "knit-graph-url:string" "" \
    "URL of the knit-graph release tarball. Empty derives it from the version."
# The --ai-* options mirror 'ai init' and are stored via the same shared helper.
# The base-url default below must stay in sync with _KNIT_AI_DEFAULT_BASE_URL in
# src/ai.sh (loaded after this file, so it cannot be referenced here).
knit_with_optional "ai-api-key-env:string" "" \
    "Name of the env var holding the AI provider API key. Configures AI when given."
knit_with_optional "ai-base-url-env:string" "" \
    "Name of the env var holding the AI endpoint base URL."
knit_with_optional "ai-model-env:string" "" \
    "Name of the env var holding the AI model id."
knit_with_optional "ai-base-url:string" "https://api.openai.com/v1" \
    "Literal fallback AI base URL used when the base-url env var is unset."
knit_with_optional "ai-model:string" "" \
    "Literal fallback AI model id used when the model env var is unset."
# ------------------------------------------------------------------------------
# @fn _knit_bootstrap()
#
# Bootstrap the Knit framework.
#
# @param ... Arguments for bootstrap.
# ------------------------------------------------------------------------------
_knit_bootstrap() {
    local project
    local spack_ref
    local spack_packages_ref
    local profile
    local scheduler
    local launcher
    local account
    local default_walltime
    local cpus_flag
    local default_nodefile
    local ignore_system_sqlite
    local ignore_system_jq
    local knitgraph_version
    local knitgraph_url
    local ai_api_key_env
    local ai_base_url_env
    local ai_model_env
    local ai_base_url
    local ai_model
    project="$(knit_get_parameter "project" "$@")"
    spack_ref="$(knit_get_parameter "spack" "$@")"
    spack_packages_ref="$(knit_get_parameter "spack-packages" "$@")"
    profile="$(knit_get_parameter "profile" "$@")"
    scheduler="$(knit_get_parameter "scheduler" "$@")"
    launcher="$(knit_get_parameter "launcher" "$@")"
    account="$(knit_get_parameter "account" "$@")"
    default_walltime="$(knit_get_parameter "default-walltime" "$@")"
    cpus_flag="$(knit_get_parameter "default-cpus-per-node" "$@")"
    default_nodefile="$(knit_get_parameter "default-nodefile" "$@")"
    ignore_system_sqlite="$(knit_get_parameter "ignore-system-sqlite" "$@")"
    ignore_system_jq="$(knit_get_parameter "ignore-system-jq" "$@")"
    knitgraph_version="$(knit_get_parameter "knit-graph-version" "$@")"
    knitgraph_url="$(knit_get_parameter "knit-graph-url" "$@")"
    ai_api_key_env="$(knit_get_parameter "ai-api-key-env" "$@")"
    ai_base_url_env="$(knit_get_parameter "ai-base-url-env" "$@")"
    ai_model_env="$(knit_get_parameter "ai-model-env" "$@")"
    ai_base_url="$(knit_get_parameter "ai-base-url" "$@")"
    ai_model="$(knit_get_parameter "ai-model" "$@")"

    # Create directory
    if [ -d "${_KNIT_PREFIX}" ]; then
        knit_fatal "Knit is already bootstrapped."
    fi
    knit_trace "Creating ${_KNIT_PREFIX} directory"
    _knit_ensure_trace_file
    mkdir "${_KNIT_PREFIX}" > "${_KNIT_TRACE_FILE}" 2>&1
    trap _knit_bootstrap_on_exit EXIT

    # knit-graph (always provisioned below) links against Knit's sqlite
    # development files. _knit_bootstrap_sqlite uses the system sqlite only when
    # those dev files are usable and otherwise builds from source, recording the
    # prefix knit-graph must build against in _KNIT_SQLITE_PREFIX.
    knit_trace "Bootstrapping sqlite..."
    _knit_bootstrap_sqlite "${ignore_system_sqlite}"

    knit_trace "Bootstrapping jq..."
    _knit_bootstrap_jq "${ignore_system_jq}"

    knit_trace "Bootstrapping knit-graph..."
    _knit_bootstrap_knitgraph "${knitgraph_version}" "${knitgraph_url}"

    # Provision Spack after sqlite/jq: resolving the latest release needs jq, and
    # recording provenance metadata needs the (sqlite-backed) metadata table.
    if _knit_bootstrap_need_spack "${spack_ref}" "${spack_packages_ref}"; then
        knit_trace "Bootstrapping spack..."
        _knit_bootstrap_spack "${spack_ref}" "${spack_packages_ref}"
    fi

    # Load profile defaults (jq is now available). The profile is resolved and
    # downloaded here (URL / local file / /etc/knit / GitHub shorthand) and frozen
    # into metadata so nothing at run time re-opens the source.
    local default_queue=""
    local default_scheduler_args=""
    local default_launcher_args=""
    local node_ncpus=""
    local node_ngpus=""
    local profile_json=""
    local profile_label=""
    if [[ -n "${profile}" ]]; then
        knit_trace "Resolving profile ${profile}..."
        _knit_resolve_profile profile_json profile_label "${profile}"
        _knit_load_profile "${profile_json}"
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
        if [[ "${scheduler}" == "<unknown>" ]]; then
            knit_warning "No job scheduler detected; using local process execution." \
                "Pass --scheduler local to suppress this warning."
            scheduler="local"
        fi
    fi
    if [[ "${launcher}" == "auto" ]]; then
        launcher="$(_knit_detect_launcher)"
    fi

    # Default walltime: explicit flag, else the profile's default-queue cap. Read
    # from the in-memory profile JSON: __profile_json__ metadata is not written
    # until below, so _knit_sched_profile_field would find nothing here.
    if [[ -z "${default_walltime}" && -n "${profile_json}" && -n "${default_queue}" ]]; then
        default_walltime="$(printf '%s' "${profile_json}" \
            | _knit_jq -r ".scheduler.queues.\"${default_queue}\".max_walltime // empty")"
    fi

    # Per-node core count precedence: explicit flag -> profile -> live detection.
    if [[ -n "${cpus_flag}" ]]; then
        node_ncpus="${cpus_flag}"
    elif [[ -z "${node_ncpus}" ]]; then
        node_ncpus="$(_knit_detect_node_ncpus)"
    fi

    # Default nodefile: resolve to an absolute path so it survives the compute-side
    # cd into the job directory (the none scheduler reads it at job runtime). Warn
    # (non-fatal) when the none scheduler has no nodefile — it will report only the
    # local hostname — and when a given nodefile is not currently readable (it may
    # appear later).
    if [[ -n "${default_nodefile}" ]]; then
        default_nodefile="$(realpath -m "${default_nodefile}" 2>/dev/null \
            || printf '%s' "${default_nodefile}")"
        if [[ ! -r "${default_nodefile}" ]]; then
            knit_warning "Default nodefile \"${default_nodefile}\" is not readable; the 'none' scheduler will report only the local hostname until it exists."
        fi
    elif [[ "${scheduler}" == "none" ]]; then
        knit_warning "The 'none' scheduler was selected without --default-nodefile; jobs will report only the local hostname."
    fi

    knit_trace "Writing initial metadata..."
    knit metadata store --key "__project__"                --value "${project}"
    knit metadata store --key "__account__"                --value "${account}"
    knit metadata store --key "__profile__"                --value "${profile_label}"
    knit metadata store --key "__profile_json__"           --value "${profile_json}"
    knit metadata store --key "__scheduler__"              --value "${scheduler}"
    knit metadata store --key "__launcher__"               --value "${launcher}"
    knit metadata store --key "__default_queue__"          --value "${default_queue}"
    knit metadata store --key "__default_walltime__"       --value "${default_walltime}"
    knit metadata store --key "__default_scheduler_args__" --value "${default_scheduler_args}"
    knit metadata store --key "__default_launcher_args__"  --value "${default_launcher_args}"
    knit metadata store --key "__node_ncpus__"             --value "${node_ncpus}"
    knit metadata store --key "__node_ngpus__"             --value "${node_ngpus}"
    knit metadata store --key "__default_nodefile__"       --value "${default_nodefile}"

    # AI provider config: written only when an API-key env var name is supplied
    # (the one required field of a usable config). Overwrite is on since bootstrap
    # is writing fresh metadata.
    if [[ -n "${ai_api_key_env}" ]]; then
        knit_trace "Writing AI provider metadata..."
        _knit_ai_store_config "${ai_api_key_env}" "${ai_base_url_env}" \
            "${ai_model_env}" "${ai_base_url}" "${ai_model}" "true"
    fi

    # Bootstrap completed successfully
    _KNIT_BOOTSTRAP_COMPLETED="true"
}
knit_done
