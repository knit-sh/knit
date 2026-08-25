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
# @fn _knit_highlight_if_not_bootstrapped()
#
# Highlight predicate (see knit_highlight_if) for the builtin "bootstrap"
# command: return 0 ("highlight") while the experiment has not been bootstrapped,
# non-zero once it has. This bolds "bootstrap" in the root "--help" on a fresh
# checkout — the one command to run first — and leaves it plain afterwards.
#
# @param cmd The demangled command name (unused; the predicate is state-only).
# ------------------------------------------------------------------------------
_knit_highlight_if_not_bootstrapped() {
    ! _knit_is_bootstrapped
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_warn_absolute_root()
#
# Warn (non-fatal) when a bootstrap path-root option was given an absolute value.
# Absolute setup/job roots pin the experiment to this machine's filesystem and
# hurt reproducibility on another machine or by another user; a relative value
# resolves against the experiment root and stays portable. A no-op for relative
# values. Factored out of _knit_bootstrap so it can be unit-tested directly.
#
# @param label The option name to name in the warning (e.g. "--setup-path").
# @param value The value the user supplied for that option.
# ------------------------------------------------------------------------------
_knit_bootstrap_warn_absolute_root() {
    local label="$1"
    local value="$2"
    if [[ "${value}" == /* ]]; then
        knit_warning "Absolute ${label} \"${value}\" makes the experiment harder to reproduce on another machine or by another user."
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_check_prerequisites()
#
# Verify the external tools that Knit needs at run time but does not itself
# provision are present on PATH, and fail bootstrap early (with a clear message)
# when one is missing. Currently checks sha256sum, which content checksums for
# file/directory parameters and outputs depend on. Uses _knit_command_path so it
# is stubbable in tests.
# ------------------------------------------------------------------------------
_knit_bootstrap_check_prerequisites() {
    if [[ -z "$(_knit_command_path sha256sum)" ]]; then
        knit_fatal "sha256sum is required by Knit but was not found on PATH." \
            "It is normally part of GNU coreutils; install coreutils and retry."
    fi
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
# @fn _knit_bootstrap_update_meta()
#
# Update-mode handler for a "free to update" bootstrap option: one stored as
# metadata with no constraint (project, platform, account, ...). When the option
# was typed on this bootstrap call, overwrite its stored value with
# "metadata store --force" and report that a change was made; when the option was
# not typed, do nothing and keep the stored value.
#
# @param opt   Option name as typed, without the leading "--" (e.g. "project").
# @param key   Metadata key to write (e.g. "__project__").
# @param value Resolved value to store for that option.
# @param ...   Raw argument tokens of this invocation (see
#              _KNIT_INVOCATION_RAW_ARGS), used to tell a typed option from a
#              defaulted one.
# @return 0 when the option was typed and its value written, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_bootstrap_update_meta() {
    local opt="$1"
    local key="$2"
    local value="$3"
    shift 3
    _knit_arg_was_provided "${opt}" "$@" || return 1
    knit metadata store --key "${key}" --value "${value}" --force
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_jobs_recorded()
#
# Return 0 when the "jobs" table exists and holds at least one row, non-zero
# otherwise. Used by update-mode --job-path relocation to refuse moving a
# job root that already holds submitted jobs. The table is created lazily on the
# first submission, so an experiment that never submitted a job has no "jobs"
# table at all; a missing table reports "no jobs".
# ------------------------------------------------------------------------------
_knit_bootstrap_jobs_recorded() {
    local esc_table exists
    _knit_sql_escape esc_table "${_KNIT_JOBS_TABLE}"
    exists="$(_knit_sqlite3 \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='${esc_table}';")"
    [[ "${exists}" -eq 0 ]] && return 1
    local count
    count="$(_knit_sqlite3 "SELECT COUNT(*) FROM ${_KNIT_JOBS_TABLE};")"
    [[ "${count}" -gt 0 ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_dir_has_subdir()
#
# Return 0 when the given directory holds at least one subdirectory, non-zero
# otherwise (including when the directory itself is absent). Used by update-mode
# --resource-path relocation to refuse moving a resource root that already holds
# fetched resource instances (each is a subdirectory).
#
# @param dir Directory to scan.
# ------------------------------------------------------------------------------
_knit_bootstrap_dir_has_subdir() {
    local dir="$1"
    [[ -d "${dir}" ]] || return 1
    local entry
    for entry in "${dir}"/*/; do
        [[ -d "${entry}" ]] && return 0
    done
    return 1
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_relocate_path()
#
# Update-mode handler for a path-root option (--setup-path, --job-path,
# --resource-path). When the option is typed and its value differs from the
# stored one, relocate the root — but only when the current root holds no
# artifacts of its kind, since setups, jobs, and resources are not movable:
#
#   - setup:    no user setup exists (the builtin "default" does not count).
#   - job:      no job row is recorded in the "jobs" table.
#   - resource: no resource instance directory exists under the root.
#
# A non-empty root is a hard stop (fatal). On an allowed relocation it stores the
# new value, recreates the builtin "default" setup under the new root (setup kind
# only), and removes the old root directory (which, for the setup kind, still
# holds the old "default", so a plain rmdir would not suffice). An untyped option
# or a value equal to the stored one is a no-op.
#
# @param kind      One of "setup", "job", "resource".
# @param new_value Resolved value typed for the option.
# @param ...       Raw argument tokens of this invocation (see
#                  _KNIT_INVOCATION_RAW_ARGS), used to tell a typed option from a
#                  defaulted one.
# @return 0 when the root was relocated, 1 when nothing changed.
# ------------------------------------------------------------------------------
_knit_bootstrap_relocate_path() {
    local kind="$1"
    local new_value="$2"
    shift 2

    local opt key root_fn label
    case "${kind}" in
        setup)    opt="setup-path";    key="__setup_path__";    root_fn=_knit_setup_root;    label="--setup-path" ;;
        job)      opt="job-path";      key="__job_path__";      root_fn=_knit_job_root;      label="--job-path" ;;
        resource) opt="resource-path"; key="__resource_path__"; root_fn=_knit_resource_root; label="--resource-path" ;;
    esac

    _knit_arg_was_provided "${opt}" "$@" || return 1

    local stored
    _knit_metadata_get stored "${key}"
    [[ "${new_value}" == "${stored}" ]] && return 1

    # Resolve the current (old) root from the still-stored value before it is
    # overwritten, both to run the emptiness check against it and to remove it.
    local old_root
    "${root_fn}" old_root

    case "${kind}" in
        setup)
            if _knit_has_user_setup "${old_root}"; then
                knit_fatal "Cannot relocate --setup-path: a user setup exists under %s.\nRelocation is only possible while no setup other than \"default\" has been created." \
                    "${old_root}"
            fi
            ;;
        job)
            if _knit_bootstrap_jobs_recorded; then
                knit_fatal "Cannot relocate --job-path: jobs are recorded in the database.\nRelocation is only possible while no job has been submitted."
            fi
            ;;
        resource)
            if _knit_bootstrap_dir_has_subdir "${old_root}"; then
                knit_fatal "Cannot relocate --resource-path: a resource exists under %s.\nRelocation is only possible while no resource has been fetched." \
                    "${old_root}"
            fi
            ;;
    esac

    _knit_bootstrap_warn_absolute_root "${label}" "${new_value}"
    knit metadata store --key "${key}" --value "${new_value}" --force

    # Recreate the builtin "default" setup under the new root (subshell so its
    # exported KNIT_SETUP_PREFIX does not leak), then drop the old tree.
    if [[ "${kind}" == "setup" ]]; then
        ( knit setup --name default -- default )
    fi
    rm -rf "${old_root}"
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_update_profile()
#
# Update-mode handler for --profile. Changing the machine profile is out of scope
# for the re-runnable bootstrap: a typed profile that differs from the stored one
# is a hard stop (fatal), while a typed profile equal to the stored one (or an
# untyped profile) is a no-op. The stored profile is the resolved profile label
# recorded at first bootstrap (__profile__).
#
# @param profile Value typed for --profile.
# @param ...     Raw argument tokens of this invocation (see
#                _KNIT_INVOCATION_RAW_ARGS), used to tell a typed option from a
#                defaulted one.
# @return 1 when there is nothing to do (a differing profile fatals instead).
# ------------------------------------------------------------------------------
_knit_bootstrap_update_profile() {
    local profile="$1"
    shift
    _knit_arg_was_provided "profile" "$@" || return 1
    local stored
    _knit_metadata_get stored "__profile__"
    [[ "${profile}" == "${stored}" ]] && return 1
    knit_fatal "Changing the profile is not supported yet (stored: %s, requested: %s).\nRe-create the experiment to change its profile." \
        "${stored:-<none>}" "${profile}"
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_update()
#
# Run bootstrap in update mode on an experiment that is already bootstrapped. It
# changes only the options the user typed on this call and leaves the database
# and every other setting untouched; it installs no destructive exit trap. A
# .knit/ directory without a database is malformed and fatals with a hint to
# remove it.
#
# It handles the free-to-update options (project, platform, account, default
# walltime, default cpus-per-node, default nodefile, scheduler, launcher), the
# AI provider options (--ai-*), each written per key so one AI field can change
# without clearing the rest, and the path-root options (--setup-path, --job-path,
# --resource-path), which relocate only when the current root is empty of its
# kind. It also handles the constrained options: --spack/--spack-packages (add
# Spack when absent, or re-provision on a changed ref only while no environment
# is built) and --profile (a changed profile is out of scope and fatals). When no
# handled option was typed, it reports that there is nothing to update and
# succeeds.
#
# @param raw_args Name of an array holding the raw, pre-expansion argument tokens
#                 (the caller's copy of _KNIT_INVOCATION_RAW_ARGS).
# @param ...      The expanded argument list (defaults injected), as read with
#                 knit_get_parameter.
# ------------------------------------------------------------------------------
_knit_bootstrap_update() {
    local -n __knit_raw=$1
    shift

    if [[ ! -f "${_KNIT_DATABASE}" ]]; then
        knit_fatal "Found %s but no Knit database at %s.\nThe directory looks incomplete. Remove it and bootstrap again:\n  rm -rf %s" \
            "${_KNIT_PREFIX}" "${_KNIT_DATABASE}" "${_KNIT_PREFIX}"
    fi

    local project platform account default_walltime cpus_flag
    local default_nodefile scheduler launcher
    local setup_path_opt job_path_opt resource_path_opt
    local spack_ref spack_packages_ref profile
    local ai_api_key_env ai_base_url_env ai_model_env ai_base_url ai_model
    project="$(knit_get_parameter "project" "$@")"
    platform="$(knit_get_parameter "platform" "$@")"
    account="$(knit_get_parameter "account" "$@")"
    default_walltime="$(knit_get_parameter "default-walltime" "$@")"
    cpus_flag="$(knit_get_parameter "default-cpus-per-node" "$@")"
    default_nodefile="$(knit_get_parameter "default-nodefile" "$@")"
    scheduler="$(knit_get_parameter "scheduler" "$@")"
    launcher="$(knit_get_parameter "launcher" "$@")"
    setup_path_opt="$(knit_get_parameter "setup-path" "$@")"
    job_path_opt="$(knit_get_parameter "job-path" "$@")"
    resource_path_opt="$(knit_get_parameter "resource-path" "$@")"
    spack_ref="$(knit_get_parameter "spack" "$@")"
    spack_packages_ref="$(knit_get_parameter "spack-packages" "$@")"
    profile="$(knit_get_parameter "profile" "$@")"
    ai_api_key_env="$(knit_get_parameter "ai-api-key-env" "$@")"
    ai_base_url_env="$(knit_get_parameter "ai-base-url-env" "$@")"
    ai_model_env="$(knit_get_parameter "ai-model-env" "$@")"
    ai_base_url="$(knit_get_parameter "ai-base-url" "$@")"
    ai_model="$(knit_get_parameter "ai-model" "$@")"

    # Changing the profile is out of scope: a differing --profile fatals before
    # any other option is written, so a rejected update mutates nothing.
    _knit_bootstrap_update_profile "${profile}" "${__knit_raw[@]}"

    local updated="false"

    # Free-to-update metadata options: overwrite each one the user typed.
    _knit_bootstrap_update_meta "project"               "__project__"          "${project}"          "${__knit_raw[@]}" && updated="true"
    _knit_bootstrap_update_meta "platform"              "__platform__"         "${platform}"         "${__knit_raw[@]}" && updated="true"
    _knit_bootstrap_update_meta "account"               "__account__"          "${account}"          "${__knit_raw[@]}" && updated="true"
    _knit_bootstrap_update_meta "default-walltime"      "__default_walltime__" "${default_walltime}" "${__knit_raw[@]}" && updated="true"
    _knit_bootstrap_update_meta "default-cpus-per-node" "__node_ncpus__"       "${cpus_flag}"        "${__knit_raw[@]}" && updated="true"

    # --default-nodefile is stored as an absolute path, as at first bootstrap.
    if _knit_arg_was_provided "default-nodefile" "${__knit_raw[@]}"; then
        if [[ -n "${default_nodefile}" ]]; then
            default_nodefile="$(realpath -m "${default_nodefile}" 2>/dev/null \
                || printf '%s' "${default_nodefile}")"
        fi
        knit metadata store --key "__default_nodefile__" --value "${default_nodefile}" --force
        updated="true"
    fi

    # --scheduler: an explicit "auto" re-runs detection (an undetected scheduler
    # maps to local, as at first bootstrap), then stores the resolved value.
    if _knit_arg_was_provided "scheduler" "${__knit_raw[@]}"; then
        if [[ "${scheduler}" == "auto" ]]; then
            scheduler="$(_knit_detect_job_manager)"
            if [[ "${scheduler}" == "<unknown>" ]]; then
                knit_warning "No job scheduler detected; using local process execution.\nPass --scheduler local to suppress this warning."
                scheduler="local"
            fi
        fi
        knit metadata store --key "__scheduler__" --value "${scheduler}" --force
        updated="true"
    fi

    # --launcher: an explicit "auto" re-runs detection, then stores the resolved
    # value.
    if _knit_arg_was_provided "launcher" "${__knit_raw[@]}"; then
        if [[ "${launcher}" == "auto" ]]; then
            launcher="$(_knit_detect_launcher)"
        fi
        knit metadata store --key "__launcher__" --value "${launcher}" --force
        updated="true"
    fi

    # AI provider options: each ai.* key is written on its own, so a single field
    # (e.g. the model) can change without clearing the rest. First bootstrap keeps
    # its all-or-nothing behaviour; update mode is per key.
    _knit_bootstrap_update_meta "ai-api-key-env"  "ai.api_key_env"  "${ai_api_key_env}"  "${__knit_raw[@]}" && updated="true"
    _knit_bootstrap_update_meta "ai-base-url-env" "ai.base_url_env" "${ai_base_url_env}" "${__knit_raw[@]}" && updated="true"
    _knit_bootstrap_update_meta "ai-model-env"    "ai.model_env"    "${ai_model_env}"    "${__knit_raw[@]}" && updated="true"
    _knit_bootstrap_update_meta "ai-base-url"     "ai.base_url"     "${ai_base_url}"     "${__knit_raw[@]}" && updated="true"
    _knit_bootstrap_update_meta "ai-model"        "ai.model"        "${ai_model}"        "${__knit_raw[@]}" && updated="true"

    # Path roots relocate only when the current root is empty of its kind; a
    # non-empty root is a hard stop inside the handler.
    _knit_bootstrap_relocate_path "setup"    "${setup_path_opt}"    "${__knit_raw[@]}" && updated="true"
    _knit_bootstrap_relocate_path "job"      "${job_path_opt}"      "${__knit_raw[@]}" && updated="true"
    _knit_bootstrap_relocate_path "resource" "${resource_path_opt}" "${__knit_raw[@]}" && updated="true"

    # Spack: add it when absent, or re-provision on a changed ref only while no
    # environment is built (a built environment freezes the version, and fatals).
    _knit_bootstrap_update_spack "${spack_ref}" "${spack_packages_ref}" "${__knit_raw[@]}" && updated="true"

    if [[ "${updated}" == "false" ]]; then
        knit_info "Knit is already bootstrapped; no updatable option was given, nothing to update."
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Bootstrap the Knit framework.
#
# @param ... Arguments for bootstrap.
# ------------------------------------------------------------------------------
knit_define_enum "__scheduler__" "auto" "slurm" "pbs" "flux" "local" "none"
_knit_is_builtin
knit_define_enum "__launcher__"  "auto" "openmpi" "mpich" "pals" "flux" "slurm" "pbs" "none"
_knit_is_builtin
knit_register "bootstrap" _knit_bootstrap "Bootstrap the Knit framework."
_knit_is_builtin
knit_usable_before_bootstrap
knit_highlight_if _knit_highlight_if_not_bootstrapped
knit_with_optional "spack:string" "" \
    "Spack git ref (tag, branch, or commit) to provision. Empty uses the latest release. Provisioning also happens automatically when a setup declares a Spack environment."
knit_with_optional "spack-packages:string" "" \
    "spack-packages git ref (tag, branch, or commit) to provision. Empty uses the latest release."
knit_with_optional "project:string" "" "Name of the project to use when submitting jobs."
knit_with_optional "setup-path:string" "setups" \
    "Root directory under which setups live. Relative values resolve against the experiment root (portable); an absolute path is used as-is. Default: setups."
knit_with_optional "job-path:string" "jobs" \
    "Root directory under which jobs live. Relative values resolve against the experiment root (portable); an absolute path is used as-is. Default: jobs."
knit_with_optional "resource-path:string" "resources" \
    "Root directory under which fetched resources live. Relative values resolve against the experiment root (portable); an absolute path is used as-is. Default: resources."
knit_with_optional "profile:string" "" \
    "Machine profile name (e.g. polaris). Prepopulates scheduler, launcher, and hardware defaults."
knit_with_optional "platform:string" "" \
    "Human-facing platform name recorded in metadata and returned by knit_platform_name. Defaults to the profile's name when --profile is given and this is omitted."
knit_with_optional "scheduler:__scheduler__" "auto" \
    "Batch job scheduler. One of: auto, slurm, pbs, flux, local, none. With auto the scheduler is detected automatically. Use none for a self-managed cluster (no scheduler); pair it with --default-nodefile."
knit_with_optional "launcher:__launcher__" "auto" \
    "MPI launcher. One of: auto, openmpi, mpich, pals, flux, slurm, pbs, none. With auto an MPI-native launcher (openmpi, mpich, or pals) is detected automatically; if none is found and a batch scheduler is present, auto falls back to that scheduler's integrated launcher (slurm=srun, pbs=the PBS mpiexec, flux=flux run). Select slurm/pbs/flux explicitly to force the scheduler-integrated launcher even when an MPI-native one is present. Use none to declare the machine offers no integrated launcher, so a setup's knit_provides_launcher supplies one."
knit_with_optional "account:string" "" \
    "Account/allocation to charge submitted jobs to."
knit_with_optional "default-walltime:string" "" \
    "Project-wide default job wall-clock limit as HH:MM:SS. Empty (the default) lets each submission fall back to the selected queue's profile default_walltime."
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
# The --ai-* options configure the AI provider (env-var names and non-secret
# defaults). The base-url default below must stay in sync with
# _KNIT_AI_DEFAULT_BASE_URL in src/ai.sh (loaded after this file, so it cannot be
# referenced here).
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
    # Copy the raw, pre-expansion arguments immediately. _KNIT_INVOCATION_RAW_ARGS
    # is overwritten by every nested command (the "metadata store" and "setup"
    # calls below), so update mode must read what the user typed before the first
    # nested call. This is the copy-immediately contract of that global.
    # shellcheck disable=SC2034 # read by name (nameref) in _knit_bootstrap_update
    local -a raw_args=("${_KNIT_INVOCATION_RAW_ARGS[@]}")

    local project
    local setup_path_opt
    local job_path_opt
    local resource_path_opt
    local spack_ref
    local spack_packages_ref
    local profile
    local platform
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
    setup_path_opt="$(knit_get_parameter "setup-path" "$@")"
    job_path_opt="$(knit_get_parameter "job-path" "$@")"
    resource_path_opt="$(knit_get_parameter "resource-path" "$@")"
    spack_ref="$(knit_get_parameter "spack" "$@")"
    spack_packages_ref="$(knit_get_parameter "spack-packages" "$@")"
    profile="$(knit_get_parameter "profile" "$@")"
    platform="$(knit_get_parameter "platform" "$@")"
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

    # Fail early on a missing run-time prerequisite (before creating .knit), so a
    # fresh checkout does not appear bootstrapped when a required tool is absent.
    _knit_bootstrap_check_prerequisites

    # A present .knit/ means an earlier bootstrap finished (the first-bootstrap
    # exit trap removes .knit/ on any failure), so re-running bootstrap enters
    # update mode instead of failing. Update mode changes only the options typed
    # on this call and leaves the database and every other setting untouched. A
    # .knit/ that holds no database is malformed, so it fatals with a hint to
    # remove it. Update mode installs no destructive exit trap, so a failed
    # update never deletes a good experiment.
    if [ -d "${_KNIT_PREFIX}" ]; then
        _knit_bootstrap_update raw_args "$@"
        return $?
    fi

    knit_info "Creating ${_KNIT_PREFIX} directory"
    _knit_ensure_trace_file
    mkdir "${_KNIT_PREFIX}" > "${_KNIT_TRACE_FILE}" 2>&1
    trap _knit_bootstrap_on_exit EXIT

    # knit-graph (always provisioned below) links against Knit's sqlite
    # development files. _knit_bootstrap_sqlite uses the system sqlite only when
    # those dev files are usable and otherwise builds from source, recording the
    # prefix knit-graph must build against in _KNIT_SQLITE_PREFIX.
    knit_info "Bootstrapping sqlite..."
    _knit_bootstrap_sqlite "${ignore_system_sqlite}"

    knit_info "Bootstrapping jq..."
    _knit_bootstrap_jq "${ignore_system_jq}"

    knit_info "Bootstrapping knit-graph..."
    _knit_bootstrap_knitgraph "${knitgraph_version}" "${knitgraph_url}"

    # Provision Spack after sqlite/jq: resolving the latest release needs jq, and
    # recording provenance metadata needs the (sqlite-backed) metadata table.
    if _knit_bootstrap_need_spack "${spack_ref}" "${spack_packages_ref}"; then
        knit_info "Bootstrapping spack..."
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
        knit_info "Resolving profile ${profile}..."
        _knit_resolve_profile profile_json profile_label "${profile}"
        _knit_load_profile "${profile_json}"
        # Materialize the platform artifacts (.knit/platform.sh, spack-config.json)
        # from the resolved profile; either is absent when its fields are omitted.
        _knit_render_platform_files "${profile_json}"
        # Platform name defaults to the profile's own "name" field when the user
        # did not pass --platform, so a profile-based experiment self-identifies.
        if [[ -z "${platform}" ]]; then
            platform="$(printf '%s' "${profile_json}" | _knit_jq -r '.name // empty')"
        fi
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
        # Fallback: when no MPI-native launcher (mpirun/mpiexec) is on PATH but the
        # machine has a batch scheduler, use the scheduler-integrated launcher
        # (srun under Slurm, the PBS mpiexec wrapper under PBS, flux run under
        # Flux) rather than degrading to no launcher. Detection cannot probe
        # these — all are a property of the surrounding allocation, not a binary
        # on PATH — so this is a last resort only: a detected MPI-native launcher
        # always wins, and this merely fills the gap where detection found
        # nothing.
        if [[ "${launcher}" == "<unknown>" ]]; then
            case "${scheduler}" in
                slurm|pbs|flux)
                    launcher="${scheduler}"
                    knit_debug "No MPI-native launcher detected; falling back to the %s scheduler-integrated launcher." "${scheduler}"
                    ;;
            esac
        fi
    fi

    # Default walltime is left empty unless the user set it with the flag. It is
    # deliberately NOT auto-filled from the default queue's cap: that froze one
    # queue's (often 24h) limit as a queue-agnostic default, so a later
    # `--queue debug` inherited it and the scheduler rejected the oversized
    # request. Walltime is instead resolved per selected queue at submit time
    # (see _knit_sched_resolve), which reads each queue's default_walltime from
    # the profile. An explicit --default-walltime remains an honored project-wide
    # default with no per-queue second-guessing.

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

    # Setup/job/resource roots are stored verbatim (as the user typed them) and
    # resolved late (see _knit_setup_root / _knit_job_root / _knit_resource_root):
    # a relative value stays portable, an absolute value is honored as-is. Warn —
    # but do not fail — on an absolute value, which pins the experiment to this
    # machine's filesystem.
    _knit_bootstrap_warn_absolute_root "--setup-path" "${setup_path_opt}"
    _knit_bootstrap_warn_absolute_root "--job-path" "${job_path_opt}"
    _knit_bootstrap_warn_absolute_root "--resource-path" "${resource_path_opt}"

    knit_trace "Writing initial metadata..."
    knit metadata store --key "__project__"                --value "${project}"
    knit metadata store --key "__setup_path__"             --value "${setup_path_opt}"
    knit metadata store --key "__job_path__"               --value "${job_path_opt}"
    knit metadata store --key "__resource_path__"          --value "${resource_path_opt}"
    knit metadata store --key "__account__"                --value "${account}"
    knit metadata store --key "__profile__"                --value "${profile_label}"
    knit metadata store --key "__platform__"               --value "${platform}"
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

    # Auto-instantiate the builtin "default" setup so a job that declares no setup
    # still runs inside one and inherits the platform environment. It is a normal
    # setup in the DB and provenance graph (row and .setup.id recorded like any
    # other), but carries only the platform activation — empty when there is no
    # profile. Run in a subshell so its exported KNIT_SETUP_PREFIX does not leak
    # into the rest of bootstrap.
    knit_info "Instantiating the default setup..."
    ( knit setup --name default -- default )

    # AI provider config: written only when an API-key env var name is supplied
    # (the one required field of a usable config). Overwrite is on since bootstrap
    # is writing fresh metadata.
    if [[ -n "${ai_api_key_env}" ]]; then
        knit_info "Writing AI provider metadata..."
        _knit_ai_store_config "${ai_api_key_env}" "${ai_base_url_env}" \
            "${ai_model_env}" "${ai_base_url}" "${ai_model}" "true"
    fi

    # Bootstrap completed successfully
    _KNIT_BOOTSTRAP_COMPLETED="true"
}
knit_done
