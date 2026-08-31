#!/bin/bash

## @file setup.sh

# ------------------------------------------------------------------------------
# @var _KNIT_SETUPS
#
# Associative array mapping registered setup names to 1. Used to validate that
# a setup name passed to `knit setup` is known. Declared global (-g) so the
# builtin "default" entry, populated at load time, survives even when knit.sh is
# sourced from within a function (as the bats tests do).
# ------------------------------------------------------------------------------
declare -gA _KNIT_SETUPS

# ------------------------------------------------------------------------------
# @fn _knit_has_user_setup()
#
# Return 0 when at least one user setup instance exists directly under the given
# setup root, non-zero otherwise. A setup instance is a subdirectory of the root;
# the builtin "default" instance is not a user setup and is ignored, so a root
# that holds only "default" (or nothing) reports "no user setup". A missing root
# also reports "no user setup".
#
# @param[in] root Absolute setup root to scan (see _knit_setup_root).
# ------------------------------------------------------------------------------
_knit_has_user_setup() {
    local root="$1"
    [[ -d "${root}" ]] || return 1
    local entry base
    for entry in "${root}"/*/; do
        [[ -d "${entry}" ]] || continue
        base="${entry%/}"
        base="${base##*/}"
        [[ "${base}" == "default" ]] && continue
        return 0
    done
    return 1
}

# ------------------------------------------------------------------------------
# @fn _knit_highlight_if_no_user_setup()
#
# Highlight predicate (see knit_highlight_if) for the builtin "setup" command:
# return 0 ("highlight") when the experiment is bootstrapped but no setup other
# than the builtin "default" has been instantiated yet, non-zero otherwise. This
# bolds "setup" in the root "--help" once bootstrap is done — pointing at the
# natural next step — and leaves it plain as soon as the user has built a setup.
# Before bootstrap it never highlights (the setup root does not exist yet, and
# the command is filtered from "--help" anyway).
#
# @param[in] cmd The demangled command name (unused; the predicate is state-only).
# ------------------------------------------------------------------------------
_knit_highlight_if_no_user_setup() {
    _knit_is_bootstrapped || return 1
    local root
    _knit_setup_root root
    _knit_has_user_setup "${root}" && return 1
    return 0
}

knit_register "setup" _knit_setup "Setup an environment"
_knit_is_builtin
knit_with_required "name:string" "Name for the setup instance"
knit_with_dispatch "setup" "User-provided setup command to execute"
knit_with_subcommand_title "Setups"
knit_highlight_if _knit_highlight_if_no_user_setup
# ------------------------------------------------------------------------------
# @fn _knit_setup()
#
# Entry point for the `setup` CLI command. Materializes a setup instance named
# `--name` under the experiment's setup root (`<setup-root>/<name>`), exports
# `KNIT_SETUP_PREFIX` to that directory, invokes the named setup subcommand
# inside it, and saves the resulting environment to
# `$KNIT_SETUP_PREFIX/.activate.sh`. On success the setup type is also recorded
# in `$KNIT_SETUP_PREFIX/.setup.type` so `knit submit` can validate a job's
# knit_with_setup requirement, and the setup body's row id in
# `$KNIT_SETUP_PREFIX/.setup.id` so a consumer can record a "used_by" edge to it.
# Removes the directory and fatals on failure.
#
# The instance name must be a single path component (validated) and is idempotent
# by name: re-running with the same name rebuilds the same directory. The name
# "default" is reserved for the builtin default setup type.
#
# Usage:
# ```
# ./exp.sh setup --name <name> -- <setup-type> [args...]
# ```
# ------------------------------------------------------------------------------
_knit_setup() {
    local name
    name=$(knit_get_parameter "name" "$@")

    # Extract extra args (after --)
    local args=("$@")
    local extra_index
    extra_index=$(knit_extra_index "${args[@]}")
    local extra=("${args[@]:extra_index}")

    if [[ ${#extra[@]} -eq 0 ]]; then
        knit_fatal "setup requires a setup name (pass it after --)."
    fi

    # The setup type as typed (kept for the "unknown" error) and its canonical
    # (underscore) form, which drives lookup, the subcommand name, the recorded
    # .setup.type marker, and the data row. Hyphens and underscores are
    # interchangeable; the registered spelling is restored for display below.
    local setup_name_typed="${extra[0]}"
    local setup_name
    setup_name=$(_knit_name_normalize "${setup_name_typed}")
    local setup_args=("${extra[@]:1}")

    # Validate the instance name (a single path component).
    _knit_validate_instance_name "${name}"

    # Reserve the name "default": it is allowed only for the builtin "default"
    # setup type, so bootstrap's own "knit setup --name default -- default" still
    # works while a user cannot shadow it with an unrelated setup.
    if [[ "${name}" == "default" && "${setup_name}" != "default" ]]; then
        knit_fatal "The setup name \"default\" is reserved for the builtin default setup."
    fi

    # Check setup name is registered
    if [[ ! -v _KNIT_SETUPS["${setup_name}"] ]]; then
        knit_fatal "Unknown setup \"${setup_name_typed}\"."
    fi

    # Validate args for the setup subcommand (knit_fatal on bad args)
    local subcmd
    subcmd=$(_knit_command_mangle "setup:${setup_name}")

    # Registered spelling of the setup, for human-facing messages.
    local setup_display_var="_KNIT_CMD_${subcmd}_display"
    local setup_display="${!setup_display_var:-${setup_name}}"

    # Usability pre-check (login side): fail fast before creating the instance
    # directory if the setup declares knit_usable_if predicates that do not hold.
    # The _knit_invoke_command re-entry below catches this too, but only after the
    # directory has been created.
    local usable_reason=""
    if ! _knit_command_check_usable usable_reason "${subcmd}"; then
        knit_fatal "Command \"setup:${setup_display}\" cannot run: ${usable_reason}"
    fi

    _knit_check_command_arguments "${subcmd}" "${setup_args[@]}"

    # Resolve the instance directory under the experiment's setup root. Idempotent
    # by name: remove any existing instance of the same name so the setup rebuilds
    # at its stable location rather than erroring or leaving a stale mix.
    local setup_root
    _knit_setup_root setup_root
    local path="${setup_root}/${name}"
    rm -rf "${path}"

    # Create directory and enter it
    mkdir -p "${path}"
    knit_pushd "${path}"

    # Export KNIT_SETUP_PREFIX so setup functions and callbacks can read it
    export KNIT_SETUP_PREFIX="${PWD}"

    # Invoke the setup subcommand and capture its return value. Clear the
    # last-recorded row id first so we only pick up an id the body itself
    # recorded (it stays empty when the experiment is not bootstrapped).
    local ret=0
    _KNIT_LAST_ROW_ID=""
    _knit_invoke_command "setup" "${setup_name}" "${setup_args[@]}" || ret=$?
    local body_row_id="${_KNIT_LAST_ROW_ID}"

    knit_popd

    # Clean up on failure
    if [[ "${ret}" -ne 0 ]]; then
        rm -rf "${path}"
        knit_fatal "Setup \"${setup_display}\" failed; removed \"${path}\"."
    fi

    # Record the setup type that built this directory so that `knit submit` can
    # check a job's knit_with_setup requirement against it.
    printf '%s\n' "${setup_name}" > "${path}/.setup.type"

    # Record the setup body's row id so a later consumer can record a "used_by" edge
    # to this setup by id (robust) rather than by matching directory paths. Only
    # written when the body recorded a row (i.e. the experiment is bootstrapped);
    # a setup directory without this marker simply yields no "used_by" edge. When
    # a row was recorded, also complete it with the instance name and directory so
    # the row identifies the instance (used to resolve `knit remove --name`).
    if [[ -n "${body_row_id}" ]]; then
        printf '%s\n' "${body_row_id}" > "${path}/.setup.id"
        _knit_db_update_row "setup:${setup_name}" "${body_row_id}" \
            "name=${name}" "directory=${path}"
    fi
}
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_setup_source_platform()
#
# Source the materialized platform fragment (${_KNIT_PREFIX}/platform.sh) into the
# current shell so a setup builds with the platform's modules and environment
# (e.g. mpicc/cmake from modules) already active. A guarded no-op when the file is
# absent (no profile, or the profile declared neither modules nor environment).
# Shared by the generic setup before-callback and the Spack-env before-callback.
# ------------------------------------------------------------------------------
_knit_setup_source_platform() {
    local platform="${_KNIT_PREFIX}/platform.sh"
    if [[ -f "${platform}" ]]; then
        # Sourcing runs the profile's module init and `module load`, which for
        # Lmod / Environment Modules print informational chatter ("Lmod is
        # automatically replacing ...", "the following have been reloaded ...")
        # to stderr. Redirect the sourcing's output to the trace file so it does
        # not pollute the user's terminal; the exports still take effect in this
        # shell (redirecting a `source` does not affect the shell's environment),
        # and any genuine module failure is preserved in the trace file.
        _knit_ensure_trace_file
        # shellcheck disable=SC1090 # dynamic, generated at bootstrap
        source "${platform}" >> "${_KNIT_TRACE_FILE}" 2>&1
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_setup_before_cb()
#
# Before-callback installed on every setup subcommand by knit_register_setup.
# Verifies that KNIT_SETUP_PREFIX is set, ensuring the setup was invoked
# through `knit setup` rather than called directly, then sources the platform
# environment so the setup body builds against the platform's modules and env.
# ------------------------------------------------------------------------------
_knit_setup_before_cb() {
    if [[ ! -v KNIT_SETUP_PREFIX ]]; then
        knit_fatal "Setup commands must be invoked via \"knit setup [OPTIONS] -- <setup> [OPTIONS]\", not directly."
    fi
    _knit_setup_source_platform
}

# ------------------------------------------------------------------------------
# @fn _knit_setup_write_activate_header()
#
# Print the header of a setup's .activate.sh to stdout: the shebang, a generated
# marker, and — when the materialized platform fragment (${_KNIT_PREFIX}/platform.sh)
# exists — its contents inlined. Inlining (rather than sourcing) keeps .activate.sh
# self-contained and re-initializes the module system for consumers. When there is
# no profile the platform fragment is absent and only the shebang/marker are
# emitted. Shared by the generic setup after-callback (which appends an environment
# dump) and the builtin "default" setup's after-callback (which emits nothing more).
# ------------------------------------------------------------------------------
_knit_setup_write_activate_header() {
    local platform="${_KNIT_PREFIX}/platform.sh"
    printf '#!/usr/bin/env bash\n'
    printf '# Generated by knit\n'
    if [[ -f "${platform}" ]]; then
        printf '\n# Platform activation (inlined from %s)\n' "${platform}"
        cat "${platform}"
        printf '\n'
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_setup_after_cb()
#
# After-callback installed on every setup subcommand by knit_register_setup.
# Inlines the platform activation (${_KNIT_PREFIX}/platform.sh) at the top of
# `$KNIT_SETUP_PREFIX/.activate.sh`, then dumps all exported environment variables
# so that jobs depending on this setup can source that file to reproduce the build
# environment. Inlining (rather than sourcing) keeps .activate.sh self-contained
# and re-initializes the module system for consumers, above the env dump.
#
# Dynamic bash internals (BASH_*, SHLVL, _, OLDPWD, PPID, RANDOM, LINENO,
# SECONDS, KNIT_SETUP_PREFIX) are excluded from the dump. FLUX_URI is also
# excluded: it is a per-instance handle to the Flux instance that owns the
# current shell, so a job that runs under "flux batch" (its own sub-instance)
# must keep the FLUX_URI that Flux gives it, not the one the setup captured on
# the login node.
# ------------------------------------------------------------------------------
_knit_setup_after_cb() {
    local activate="${KNIT_SETUP_PREFIX}/.activate.sh"
    {
        _knit_setup_write_activate_header
        local var
        while IFS= read -r var; do
            case "${var}" in
                BASH_*|SHLVL|_|OLDPWD|PPID|RANDOM|LINENO|SECONDS|KNIT_SETUP_PREFIX|FLUX_URI)
                    continue ;;
            esac
            # Skip readonly variables (e.g. KNIT_VERSION): re-exporting them when
            # a job sources .activate.sh fails with "readonly variable".
            local decl flags
            decl="$(declare -p "${var}" 2>/dev/null)"
            flags="${decl#declare -}"
            flags="${flags%% *}"
            [[ "${flags}" == *r* ]] && continue
            printf 'export %s=%s\n' "${var}" "$(printf '%q' "${!var}")"
        done < <(compgen -e)
    } > "${activate}"
    chmod +x "${activate}"
}

# ------------------------------------------------------------------------------
# @fn knit_register_setup()
#
# Register a setup, i.e. a subcommand of the "setup" command that builds
# software and records the resulting environment. The setup is automatically
# backed by a database table named "setup:<name>". A before-callback checks
# that KNIT_SETUP_PREFIX is set; an after-callback saves the environment to
# `$KNIT_SETUP_PREFIX/.activate.sh`.
#
# A call to this function must be followed by any knit_with_* declarations,
# the definition of <fn>, and a call to knit_done.
#
# @param[in] name        Short name for the setup (used as the subcommand name).
# @param[in] fn          Name of the Bash function implementing the setup.
# @param[in] description One-line description shown in `--help`.
#
# Example:
# ```
# knit_register_setup "hello" "hello_fn" "Builds the hello program."
# knit_with_optional "version:string" "main" "Branch or tag to check out."
# hello_fn() {
#   ...
# }
# knit_done
# ```
# ------------------------------------------------------------------------------
knit_register_setup() {
    local name="$1"
    local fn="$2"
    local description="$3"
    knit_register "setup:${name}" "${fn}" "${description}"
    knit_with_table
    # Every instance records its name and on-disk directory (filled by the `knit
    # setup` dispatcher after the setup body runs), so the row identifies the
    # instance without reconstructing the path from the name — parity with the
    # `fetch` resource dispatcher.
    knit_with_output "name:string" "" "The setup instance name (from knit setup --name)."
    knit_with_output "directory:string" "" "The instance's on-disk directory."
    # Key the registry by the canonical (underscore) name so a later `knit setup
    # -- <name>` resolves the setup whether it is typed with hyphens or
    # underscores (the registered spelling is preserved for display).
    local normalized_name
    normalized_name=$(_knit_name_normalize "${name}")
    _KNIT_SETUPS["${normalized_name}"]=1
    printf -v "_KNIT_CMD_${_KNIT_CURRENT_COMMAND}_type" '%s' 'setup'
    _knit_run_before _knit_setup_before_cb
    _knit_run_after  _knit_setup_after_cb
}

# ------------------------------------------------------------------------------
# @fn _knit_experiment_root()
#
# Store the experiment root — the directory that contains .knit — in the
# caller-named variable. Derived from _KNIT_PREFIX (already absolute) by
# stripping the trailing "/.knit" component, so it stays correct even after a
# compute-side cd into a job directory. Uses parameter expansion (no fork).
#
# @param[out] __knit_ret Name of the variable to hold the experiment root.
# ------------------------------------------------------------------------------
_knit_experiment_root() {
    local -n __knit_ret=$1
    __knit_ret="${_KNIT_PREFIX%/*}"
}

# ------------------------------------------------------------------------------
# @fn _knit_resolve_experiment_path()
#
# Resolve a stored path value into an absolute directory and store it in the
# caller-named variable. An absolute value (starting with "/") is returned
# unchanged; a relative value is resolved against the experiment root, so an
# experiment with relative roots stays portable across machines and clones.
#
# @param[out] __knit_ret Name of the variable to hold the resolved path.
# @param[in] stored     The stored path value (as typed at bootstrap).
# ------------------------------------------------------------------------------
_knit_resolve_experiment_path() {
    local -n __knit_ret=$1
    local stored="$2"
    if [[ "${stored}" == /* ]]; then
        __knit_ret="${stored}"
        return 0
    fi
    local root
    _knit_experiment_root root
    __knit_ret="${root}/${stored}"
}

# ------------------------------------------------------------------------------
# @fn _knit_setup_root()
#
# Store the resolved setup root — the directory under which setup instances live
# — in the caller-named variable. Reads the verbatim __setup_path__ from the
# metadata table (falling back to "setups" when unset, for robustness) and
# resolves it against the experiment root via _knit_resolve_experiment_path.
#
# @param[out] __knit_ret Name of the variable to hold the resolved setup root.
# ------------------------------------------------------------------------------
_knit_setup_root() {
    local -n __knit_ret=$1
    local stored
    _knit_metadata_get stored "__setup_path__"
    [[ -z "${stored}" ]] && stored="setups"
    local resolved
    _knit_resolve_experiment_path resolved "${stored}"
    __knit_ret="${resolved}"
}

# ------------------------------------------------------------------------------
# @fn _knit_job_root()
#
# Store the resolved job root — the directory under which jobs live — in the
# caller-named variable. Reads the verbatim __job_path__ from the metadata table
# (falling back to "jobs" when unset, for robustness) and resolves it against
# the experiment root via _knit_resolve_experiment_path.
#
# @param[out] __knit_ret Name of the variable to hold the resolved job root.
# ------------------------------------------------------------------------------
_knit_job_root() {
    local -n __knit_ret=$1
    local stored
    _knit_metadata_get stored "__job_path__"
    [[ -z "${stored}" ]] && stored="jobs"
    local resolved
    _knit_resolve_experiment_path resolved "${stored}"
    __knit_ret="${resolved}"
}

# ------------------------------------------------------------------------------
# @fn _knit_validate_instance_name()
#
# Validate a setup or job instance name. A name must be a single path component:
# it matches ^[A-Za-z0-9._-]+$ (letters, digits, dot, underscore, hyphen; no
# slashes). Fatals with guidance on anything else; returns normally on a match.
#
# @param[in] name The instance name to validate.
# ------------------------------------------------------------------------------
_knit_validate_instance_name() {
    local name="$1"
    if [[ ! "${name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        knit_fatal "Invalid name \"${name}\": names must match ^[A-Za-z0-9._-]+\$ (letters, digits, dot, underscore, hyphen; no slashes)."
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_setup_name_to_path()
#
# Resolve a setup instance name into its absolute directory under the experiment's
# setup root: `<setup-root>/<name>` (see _knit_setup_root). The name is validated
# as a single path component first (fatal otherwise). This is how a --setup value
# is resolved for jobs, plain commands, and apps: users refer to a setup by the
# name they gave `knit setup --name`, not by its on-disk path.
#
# @param[out] __knit_ret Name of the variable to hold the resolved setup directory.
# @param[in] name       The setup instance name (as passed to --setup).
# ------------------------------------------------------------------------------
_knit_setup_name_to_path() {
    local -n __knit_ret=$1
    local name="$2"
    _knit_validate_instance_name "${name}"
    local root
    _knit_setup_root root
    __knit_ret="${root}/${name}"
}

# ------------------------------------------------------------------------------
# @fn _knit_default_setup_path()
#
# Print the directory where bootstrap instantiates the builtin "default" setup:
# `<setup-root>/default`, i.e. the reserved "default" instance under the
# experiment's setup root (see _knit_setup_root). It travels with the experiment
# (relative setup roots resolve against the experiment root) and survives the
# compute-side cd into a job directory. This is the path knit_with_setup "default"
# and the implicit-default job adoption resolve to when no --setup is given.
# ------------------------------------------------------------------------------
_knit_default_setup_path() {
    local root
    _knit_setup_root root
    printf '%s\n' "${root}/default"
}

# ------------------------------------------------------------------------------
# @fn _knit_setup_default_after_cb()
#
# After-callback for the builtin "default" setup. Unlike the generic setup
# after-callback it does NOT dump the environment: the default setup builds
# nothing, so re-exporting the bootstrap shell's environment would freeze
# unrelated login-node state into every job. It writes only the platform
# activation header, so `.activate.sh` carries the platform modules/environment
# (and is effectively empty when there is no profile).
# ------------------------------------------------------------------------------
_knit_setup_default_after_cb() {
    local activate="${KNIT_SETUP_PREFIX}/.activate.sh"
    _knit_setup_write_activate_header > "${activate}"
    chmod +x "${activate}"
}

# ------------------------------------------------------------------------------
# @fn _knit_default_setup()
#
# Body of the builtin "default" setup. It builds nothing: the setup exists only
# to carry the platform activation (inlined into .activate.sh by
# _knit_setup_default_after_cb) to jobs that declare no setup of their own.
# ------------------------------------------------------------------------------
_knit_default_setup() {
    :
}

# The builtin "default" setup is registered like a user setup (so it has a table
# and participates in the DB/provenance graph) but with the platform-only
# after-callback above rather than the generic environment dump. Bootstrap
# auto-instantiates it into _knit_default_setup_path.
knit_register "setup:default" _knit_default_setup \
    "Builtin setup carrying only the platform activation."
_knit_is_builtin
knit_with_table
# The builtin default setup is a normal setup in the DB, so it records its
# instance name and directory like any user setup (filled by _knit_setup).
knit_with_output "name:string" "" "The setup instance name (from knit setup --name)."
knit_with_output "directory:string" "" "The instance's on-disk directory."
_KNIT_SETUPS["default"]=1
_knit_run_before _knit_setup_before_cb
_knit_run_after  _knit_setup_default_after_cb
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_setup_check_type()
#
# Check that a setup directory was built by the required setup type. `knit setup`
# records the type in a `.setup.type` marker file inside the setup directory.
# Fatals if the marker is missing or its recorded type differs from the required
# one; returns normally on a match. Shared by `knit submit` (jobs) and by the
# generic setup-dependency before-callback used for every other command that
# declares knit_with_setup.
#
# @param[in] setup_path Path to the setup directory to check.
# @param[in] required   Setup type the directory must have been built by.
# ------------------------------------------------------------------------------
_knit_setup_check_type() {
    local setup_path="$1"
    local required="$2"
    local marker="${setup_path}/.setup.type"
    if [[ ! -f "${marker}" ]]; then
        knit_fatal "Setup at \"${setup_path}\" has no recorded type; a \"${required}\" setup is required."
    fi
    local actual=""
    IFS= read -r actual < "${marker}" || true
    if [[ "${actual}" != "${required}" ]]; then
        knit_fatal "A \"${required}\" setup is required, but \"${setup_path}\" was built by \"${actual}\"."
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_setup_dep_resolve_path()
#
# Resolve the setup directory a knit_with_setup command depends on, by precedence:
# the command's --setup option (a setup instance *name*, resolved to
# `<setup-root>/<name>` via _knit_setup_name_to_path), else an already-set
# KNIT_SETUP_PREFIX (an absolute path, e.g. an app running inside a job inherits
# the job's setup), else — only when the required type is the builtin "default" —
# the auto-instantiated default setup path. Prints the resolved path (empty when
# nothing resolves). Shared by the before- and after-callbacks so they always
# agree on which directory is referenced.
#
# @param[in] required Setup type the dependency must have been built by. Remaining
#                 arguments are the command's own runtime arguments, scanned for
#                 --setup.
# ------------------------------------------------------------------------------
_knit_setup_dep_resolve_path() {
    local required="$1"
    shift
    local setup_name
    setup_name=$(knit_get_parameter "setup" "$@") || setup_name=""
    local setup_path=""
    if [[ -n "${setup_name}" ]]; then
        _knit_setup_name_to_path setup_path "${setup_name}"
    else
        setup_path="${KNIT_SETUP_PREFIX:-}"
        if [[ -z "${setup_path}" && "${required}" == "default" ]]; then
            setup_path="$(_knit_default_setup_path)"
        fi
    fi
    printf '%s\n' "${setup_path}"
}

# ------------------------------------------------------------------------------
# @fn _knit_setup_dep_before_cb()
#
# Before-callback installed by knit_with_setup on a plain command or an app. It
# resolves the setup directory the command depends on, checks its type, and
# sources its .activate.sh so the command body runs in the setup's environment.
# Jobs do not use this callback: their setup is resolved at submit time
# (_knit_submit) and re-sourced on the compute node (_knit_job_before_cb). Setups
# and wrappers cannot declare knit_with_setup at all (knit_with_setup rejects them).
#
# The setup directory is resolved by _knit_setup_dep_resolve_path (the --setup
# option, else the ambient KNIT_SETUP_PREFIX, else the builtin default path when
# the required type is "default").
#
# @param[in] required Setup type the dependency must have been built by. Remaining
#                 arguments are the command's own runtime arguments, scanned for
#                 --setup.
# ------------------------------------------------------------------------------
_knit_setup_dep_before_cb() {
    local required="$1"
    shift
    local setup_path
    setup_path=$(_knit_setup_dep_resolve_path "${required}" "$@")
    if [[ -z "${setup_path}" ]]; then
        knit_fatal "This command requires a --setup of type \"${required}\"."
    fi
    if [[ ! -d "${setup_path}" ]]; then
        knit_fatal "Setup path \"${setup_path}\" does not exist."
    fi
    setup_path="$(realpath "${setup_path}")"
    _knit_setup_check_type "${setup_path}" "${required}"
    # Do not clobber an already-set prefix (a job/app ambient prefix); only stand
    # one up for a command that has none.
    if [[ -z "${KNIT_SETUP_PREFIX:-}" ]]; then
        export KNIT_SETUP_PREFIX="${setup_path}"
    fi
    # shellcheck disable=SC1091
    source "${setup_path}/.activate.sh"
}

# ------------------------------------------------------------------------------
# @fn _knit_setup_record_used_by_edge()
#
# Record a "used_by" provenance edge from the setup built at <setup_path> to a
# consuming invocation. The edge's source is the setup (its row id read from the
# setup directory's .setup.id marker, its name "setup:<type>" from .setup.type);
# its target is the consumer. A "used_by" edge has no duration, so both timestamps
# are NULL. Shared by `knit submit` (jobs) and by the generic setup-dependency
# after-callback (plain commands and apps).
#
# It reads the setup directory's .setup.id / .setup.type markers and delegates the
# gated write to _knit_record_used_by_edge (which records nothing when recording is
# disabled, on a suppressed rank, before bootstrap, or when the target does not
# participate in the graph). A setup directory with no .setup.id (e.g. built before
# provenance shipped) yields no edge.
#
# @param[in] setup_path  Path to the setup directory the consumer references.
# @param[in] target_cmd  Mangled command name of the consumer (the edge target).
# @param[in] target_id   Resolved row id of the consumer (the edge target).
# ------------------------------------------------------------------------------
_knit_setup_record_used_by_edge() {
    local setup_path="$1"
    local target_cmd="$2"
    local target_id="$3"
    local id_file="${setup_path}/.setup.id"
    [[ -f "${id_file}" ]] || return 0
    local setup_id=""
    IFS= read -r setup_id < "${id_file}" || setup_id=""
    local setup_type=""
    IFS= read -r setup_type < "${setup_path}/.setup.type" 2>/dev/null || setup_type=""
    _knit_record_used_by_edge "${setup_id}" "setup:${setup_type}" \
        "${target_cmd}" "${target_id}"
}

# ------------------------------------------------------------------------------
# @fn _knit_setup_dep_after_cb()
#
# After-callback installed by knit_with_setup on a plain command or an app,
# alongside _knit_setup_dep_before_cb. It records a "used_by" edge from the setup the
# command depends on to the command itself. It runs as an after-callback (not the
# before-callback that sources the environment) because the consumer's frame is on
# the executing stacks only from push time onward, so the consumer's resolved row
# id — the edge target — is available here but not in the before-callback.
#
# It resolves the same setup directory the before-callback used (via
# _knit_setup_dep_resolve_path), so the two always agree.
#
# @param[in] required Setup type the dependency must have been built by. Remaining
#                 arguments are the command's own runtime arguments, scanned for
#                 --setup.
# ------------------------------------------------------------------------------
_knit_setup_dep_after_cb() {
    local required="$1"
    shift
    local setup_path
    setup_path=$(_knit_setup_dep_resolve_path "${required}" "$@")
    [[ -z "${setup_path}" ]] && return 0
    setup_path="$(realpath "${setup_path}" 2>/dev/null)" || return 0
    [[ ${#_KNIT_EXECUTING_COMMAND[@]} -gt 0 ]] || return 0
    _knit_setup_record_used_by_edge "${setup_path}" \
        "${_KNIT_EXECUTING_COMMAND[-1]}" "${_KNIT_EXECUTING_ROW_ID[-1]}"
}

# ------------------------------------------------------------------------------
# @fn knit_with_setup()
#
# Declare that the command currently being registered requires a setup of a given
# type (the name of a setup registered with knit_register_setup). Must be called
# between a knit_register* call and knit_done, at most once per command.
#
# How the requirement is consumed depends on the kind of command:
#   - Jobs (knit_register_job): `knit submit` makes --setup mandatory, rejects a
#     --setup that was not built by the declared type, and the job re-sources the
#     setup environment on the compute node.
#   - Any other command: knit_with_setup adds a --setup option to the command,
#     and a before-callback validates the given setup's type and sources its
#     .activate.sh so the command body runs in the setup environment.
#
# Setups and wrappers may NOT declare knit_with_setup and are rejected:
#   - a setup's KNIT_SETUP_PREFIX is its own output directory, so chaining setups
#     would make that prefix ambiguous;
#   - a wrapper forwards its arguments verbatim and cannot take a parsed --setup.
#
# Example:
# ```
# knit_register_job "montecarlo" _montecarlo_job "Estimate pi as a job."
# knit_with_setup "mcenv"   # requires a setup built by the "mcenv" setup
# _montecarlo_job() { ... }
# knit_done
# ```
#
# @param[in] type Name of the required setup type.
# ------------------------------------------------------------------------------
knit_with_setup() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_with_setup must be called between a knit_register* call and knit_done."
    fi
    if [[ "${_KNIT_CURRENT_COMMAND_DEMANGLED}" == setup:* ]]; then
        knit_fatal "knit_with_setup cannot be used on a setup (setups cannot depend on other setups)."
    fi
    _knit_wrapper_reject_declaration "knit_with_setup"
    # The required setup type as written (kept for messages) and its canonical
    # (underscore) form, stored in the marker so it matches a setup's recorded
    # .setup.type regardless of the hyphen/underscore spelling on either side.
    local setup_type_typed="$1"
    if ! _knit_name_is_valid "${setup_type_typed}"; then
        knit_fatal "Setup type \"${setup_type_typed}\" is not a valid name."
    fi
    local setup_type
    setup_type=$(_knit_name_normalize "${setup_type_typed}")
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local marker_var="_KNIT_CMD_${cmd}_setup"
    if [[ -n "${!marker_var:-}" ]]; then
        knit_fatal "knit_with_setup may be called at most once per command."
    fi
    local no_setup_var="_KNIT_CMD_${cmd}_no_setup"
    if [[ -n "${!no_setup_var:-}" ]]; then
        knit_fatal "knit_with_setup and knit_without_setup are mutually exclusive."
    fi
    printf -v "${marker_var}" '%s' "${setup_type}"
    knit_trace "Command \"${_KNIT_CURRENT_COMMAND_DEMANGLED}\" requires a \"${setup_type_typed}\" setup."

    # Advertise the requirement in the command's `--help` output (see the
    # "Requirements" section rendered by _knit_print_command_usage).
    # shellcheck disable=SC2178 # nameref to the command's notes array
    local -n _notes_ref="_KNIT_CMD_${cmd}_notes"
    _notes_ref+=("Requires a --setup built by the \"${setup_type_typed}\" setup.")

    # Jobs resolve and enforce the setup at submit time (see _knit_submit) and
    # re-source it on the compute node (_knit_job_before_cb): no local --setup
    # option or before-callback is added here.
    if [[ "${_KNIT_CURRENT_COMMAND_DEMANGLED}" == submit:* ]]; then
        return 0
    fi

    # Plain commands and apps get a --setup option, a before-callback that
    # validates and activates it, and an after-callback that records the "used_by"
    # edge (the consumer's row id, the edge target, is resolved only from push
    # time on, so the edge is emitted after the body rather than in the
    # before-callback).
    knit_with_optional "setup:string" "" \
        "Name of a setup built by the \"${setup_type}\" setup."
    _knit_run_before _knit_setup_dep_before_cb "${setup_type}"
    _knit_run_after  _knit_setup_dep_after_cb "${setup_type}"
}

# ------------------------------------------------------------------------------
# @fn knit_without_setup()
#
# Declare that the job currently being registered opts out of the implicit
# "default" setup. Must be called between a knit_register* call and knit_done.
#
# Jobs that declare neither knit_with_setup nor knit_without_setup run in the
# builtin "default" setup (see _knit_submit), inheriting the platform environment
# with no boilerplate. knit_without_setup makes such a job run with no setup at
# all — no setup directory, no platform activation. It is mutually exclusive with
# knit_with_setup.
#
# Setups and wrappers are rejected. For any non-job command it is a no-op: plain
# commands and apps are already setup-less unless they explicitly declare
# knit_with_setup, so there is no implicit default to opt out of.
# ------------------------------------------------------------------------------
knit_without_setup() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_without_setup must be called between a knit_register* call and knit_done."
    fi
    if [[ "${_KNIT_CURRENT_COMMAND_DEMANGLED}" == setup:* ]]; then
        knit_fatal "knit_without_setup cannot be used on a setup."
    fi
    _knit_wrapper_reject_declaration "knit_without_setup"

    # Only jobs adopt the default setup implicitly, so only jobs have anything to
    # opt out of. For every other command this is a no-op.
    if [[ "${_KNIT_CURRENT_COMMAND_DEMANGLED}" != submit:* ]]; then
        return 0
    fi

    local cmd="${_KNIT_CURRENT_COMMAND}"
    local setup_var="_KNIT_CMD_${cmd}_setup"
    if [[ -n "${!setup_var:-}" ]]; then
        knit_fatal "knit_with_setup and knit_without_setup are mutually exclusive."
    fi
    printf -v "_KNIT_CMD_${cmd}_no_setup" '%s' '1'
    knit_trace "Job \"${_KNIT_CURRENT_COMMAND_DEMANGLED}\" opts out of the default setup."
}

# ------------------------------------------------------------------------------
# @fn _knit_setup_spack_env_before_cb()
#
# Before-callback installed by knit_with_spack_env. Runs as the setup's first
# step (before-cbs execute in the setup's own shell, so the activated environment
# persists into the setup body and into the after-callbacks). It provisions Spack
# on demand if it is missing (see _knit_spack_ensure_provisioned), materializes the
# environment manifest to ${KNIT_SETUP_PREFIX}/spack.yaml, builds the Spack
# environment at ${KNIT_SETUP_PREFIX}/spack-env, and activates it in the current
# shell so the setup body builds against the installed packages.
#
# The manifest source is captured at registration time and carried in the
# callback arguments (mode + source); trailing arguments are the setup's own
# runtime arguments and are ignored.
#
# @param[in] mode   "file" (source is an absolute path to copy) or "stdin" (source
#               is the literal manifest content captured from a here-doc).
# @param[in] source Manifest path (mode=file) or manifest content (mode=stdin).
# ------------------------------------------------------------------------------
_knit_setup_spack_env_before_cb() {
    local mode="$1"
    local source="$2"
    local yaml="${KNIT_SETUP_PREFIX}/spack.yaml"
    local env_dir="${KNIT_SETUP_PREFIX}/spack-env"
    # Source the platform first so the Spack env builds against platform modules
    # and environment (e.g. an external compiler/MPI). Idempotent with the generic
    # setup before-callback, which also sources it.
    _knit_setup_source_platform
    # Provision Spack on demand: a setup may have gained this directive after the
    # experiment was already bootstrapped without Spack, and bootstrap cannot be
    # re-run.
    _knit_spack_ensure_provisioned
    if [[ "${mode}" == "file" ]]; then
        cp "${source}" "${yaml}"
    else
        printf '%s\n' "${source}" > "${yaml}"
    fi
    # Abort the setup if the environment did not install: returning non-zero here
    # propagates through _knit_execute_before_commands so the setup body never
    # runs (it would build against a missing/half-installed environment), and the
    # setup dispatcher removes the directory without recording it. Do not activate
    # a broken environment.
    if ! _knit_spack_env_install "${env_dir}" "${yaml}"; then
        return 1
    fi
    # Activate in the setup's own shell so the body sees the packages. The sourced
    # "spack" function (see _knit_spack_exec) performs the activation in-shell.
    _knit_spack_exec env activate -d "${env_dir}"
}

# ------------------------------------------------------------------------------
# @fn _knit_setup_spack_env_after_cb()
#
# After-callback installed by knit_with_spack_env, registered *after* the generic
# _knit_setup_after_cb so it runs last and its appended block is authoritative
# when a job sources .activate.sh. It (1) appends an explicit re-activation block
# to .activate.sh so a job re-activates the exact environment, and (2) records
# the concrete manifest (spack.yaml) and lockfile (spack.lock) as provenance
# outputs, gzip-compressed and base64-encoded.
#
# The provenance is emitted with knit_output: after-callbacks run while the
# command is still on the executing-command stack (it is popped only afterwards),
# so knit_output resolves and type-checks the outputs normally.
#
# Trailing arguments are the setup's runtime arguments and are ignored.
# ------------------------------------------------------------------------------
_knit_setup_spack_env_after_cb() {
    local env_dir="${KNIT_SETUP_PREFIX}/spack-env"
    local activate="${KNIT_SETUP_PREFIX}/.activate.sh"
    {
        printf '\n# Spack environment re-activation (added by knit_with_spack_env)\n'
        printf 'source %q\n' "${_KNIT_SPACK_ROOT}/share/spack/setup-env.sh"
        printf 'spack env activate -d %q\n' "${env_dir}"
    } >> "${activate}"
    if [[ -f "${env_dir}/spack.yaml" ]]; then
        knit_output "__spack_yaml__" "$(gzip -c "${env_dir}/spack.yaml" | base64 -w0)"
    fi
    if [[ -f "${env_dir}/spack.lock" ]]; then
        knit_output "__spack_lock__" "$(gzip -c "${env_dir}/spack.lock" | base64 -w0)"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_stdin_is_terminal()
#
# Return success if standard input is an interactive terminal. Factored out of
# knit_with_spack_env so tests can stub it: a real terminal is unavailable under
# bats, so the no-manifest guard cannot be exercised without this seam.
# ------------------------------------------------------------------------------
_knit_stdin_is_terminal() {
    [[ -t 0 ]]
}

# shellcheck disable=SC2120 # public API: often called with no args (stdin form)
# ------------------------------------------------------------------------------
# @fn knit_with_spack_env()
#
# Declare that the setup currently being registered needs a Spack environment,
# built as the setup's first step and inherited by jobs via re-activation. Must
# be called between knit_register_setup and knit_done, at most once per setup
# (also mutually exclusive with knit_with_spack_specs, which funnels through
# here).
#
# The environment is described either by a file (non-empty argument, resolved to
# an absolute path at registration) or, when no argument is given, by a here-doc
# / stdin manifest consumed at registration time. In the no-argument form the
# manifest must actually be redirected: if stdin is an interactive terminal (so
# there is nothing to read) the directive fails fast instead of blocking on
# input, and an empty stdin manifest is likewise rejected. The directive installs
# the
# build/activation callbacks, declares the __spack_yaml__ / __spack_lock__
# provenance outputs (which become columns in the setup's table), advertises the
# requirement in --help, and sets _KNIT_SPACK_REQUIRED so bootstrap
# auto-provisions Spack.
#
# Example:
# ```
# knit_register_setup "libs" "libs_fn" "Build deps with Spack."
# knit_with_spack_env "spack.yaml"          # path form
# # --- or ---
# knit_with_spack_env <<'EOF'               # here-doc form
# spack:
#   specs: [hdf5@1.14, fftw]
#   view: true
# EOF
# libs_fn() { ... }
# knit_done
# ```
#
# @param[in] file Optional path to a spack.yaml manifest. If omitted, the manifest
#             is read from stdin.
# ------------------------------------------------------------------------------
knit_with_spack_env() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]] \
    || [[ "${_KNIT_CURRENT_COMMAND_DEMANGLED}" != setup:* ]]; then
        knit_fatal "knit_with_spack_env is valid only for setups; it must be called between knit_register_setup and knit_done."
    fi
    _knit_wrapper_reject_declaration "knit_with_spack_env"
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local marker_var="_KNIT_CMD_${cmd}_spack_env"
    if [[ -n "${!marker_var:-}" ]]; then
        knit_fatal "A setup may declare at most one Spack environment (knit_with_spack_env / knit_with_spack_specs)."
    fi
    printf -v "${marker_var}" '%s' '1'

    local mode source
    if [[ -n "$1" ]]; then
        mode="file"
        source="$(realpath -m "$1" 2>/dev/null || printf '%s' "$1")"
    else
        # No path given: the manifest must arrive on stdin (here-doc, here-string,
        # or pipe). If stdin is an interactive terminal there is nothing to read
        # and "cat" would block forever, so fail fast with guidance rather than
        # hang.
        if _knit_stdin_is_terminal; then
            knit_fatal "knit_with_spack_env: no manifest provided. Give a spack.yaml path, feed one on stdin (here-doc/here-string/pipe), or use knit_with_spack_specs."
        fi
        mode="stdin"
        source="$(cat)"
        if [[ -z "${source//[[:space:]]/}" ]]; then
            knit_fatal "knit_with_spack_env: the manifest read from stdin is empty."
        fi
    fi

    _knit_run_before _knit_setup_spack_env_before_cb "${mode}" "${source}"
    _knit_run_after  _knit_setup_spack_env_after_cb

    knit_with_output "__spack_yaml__:string" "" \
        "gzip+base64 of the environment's concrete spack.yaml manifest."
    knit_with_output "__spack_lock__:string" "" \
        "gzip+base64 of the environment's spack.lock lockfile."

    # shellcheck disable=SC2178 # nameref to the command's notes array
    local -n _notes_ref="_KNIT_CMD_${cmd}_notes"
    _notes_ref+=("Builds a Spack environment before the setup body runs.")
    _KNIT_SPACK_REQUIRED="1"
}

# ------------------------------------------------------------------------------
# @fn knit_with_spack_specs()
#
# Lightweight sugar over knit_with_spack_env for the common "just install these
# specs" case: it synthesizes a minimal spack.yaml (the given specs plus
# "view: true") and feeds it to knit_with_spack_env, so provenance capture,
# activation, and auto-provisioning all apply identically. Must be called between
# knit_register_setup and knit_done, and is mutually exclusive with
# knit_with_spack_env on one setup.
#
# Example:
# ```
# knit_register_setup "libs" "libs_fn" "Build deps."
# knit_with_spack_specs "hdf5@1.14" "fftw" "boost"
# libs_fn() { ... }
# knit_done
# ```
#
# @param[in] ... One or more Spack specs.
# ------------------------------------------------------------------------------
knit_with_spack_specs() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]] \
    || [[ "${_KNIT_CURRENT_COMMAND_DEMANGLED}" != setup:* ]]; then
        knit_fatal "knit_with_spack_specs is valid only for setups; it must be called between knit_register_setup and knit_done."
    fi
    if [[ $# -eq 0 ]]; then
        knit_fatal "knit_with_spack_specs requires at least one spec."
    fi
    local yaml spec
    yaml=$'spack:\n  specs:\n'
    for spec in "$@"; do
        yaml+="    - ${spec}"$'\n'
    done
    yaml+=$'  view: true\n'
    # shellcheck disable=SC2119 # intentional stdin form: manifest fed via here-string
    knit_with_spack_env <<< "${yaml}"
}

# ------------------------------------------------------------------------------
# @fn _knit_setup_provides_launcher_after_cb()
#
# After-callback installed by knit_provides_launcher, registered *after* the
# generic _knit_setup_after_cb (and any Spack re-activation block) so it appends
# to an already-written .activate.sh. It runs in the setup's own process, right
# after the body built and PATH-prepended its MPI, so the launcher is present on
# PATH by construction. It clears the detection cache, detects the launcher once
# against the active PATH, and freezes the concrete result by appending
# `export KNIT_PROVIDED_LAUNCHER=<impl>` to .activate.sh — the contract read by
# the launcher precedence (_knit_launch_backend). The value is also recorded as
# provenance via the __mpi_launcher__ output.
#
# If detection finds no launcher ("<unknown>") the setup declared it may provide
# one but built none reachable on PATH. Whether that is fatal depends on the
# machine: knit_provides_launcher means only "I may supply a launcher where the
# machine has none", and the machine's own launcher (the profile's __launcher__)
# wins over the setup's contract in _knit_launch_backend. So:
#   - When the machine has a concrete launcher (e.g. PALS on a Cray, whose
#     mpiexec comes from a launcher module, not from the MPI the setup builds
#     against), the setup's contract is subordinate and unused; a failed
#     detection is expected and harmless. Skip the contract, record <unknown>
#     provenance, and continue — a portable setup that unconditionally declares
#     knit_provides_launcher is correct here (the profile wins).
#   - When the machine has no launcher (a laptop; __launcher__ is <unknown>,
#     "none", or unset), the setup's contract is the only possible source, so a
#     failed detection is fatal — an early, clear failure rather than a silent
#     degrade to the "none" backend at run time.
#
# Trailing arguments are the setup's runtime arguments and are ignored.
# ------------------------------------------------------------------------------
_knit_setup_provides_launcher_after_cb() {
    local activate="${KNIT_SETUP_PREFIX}/.activate.sh"
    # A setup that provides a launcher always installs an MPI-native launcher, so
    # probe only for those (never "flux"): this after-cb runs on the login node,
    # where a live FLUX_URI would otherwise make _knit_detect_launcher freeze the
    # contract to "flux". Detect against the now-active PATH; clear the cache so a
    # stale bootstrap-time detection does not leak in.
    _KNIT_DETECTED_MPI_LAUNCHER=""
    local impl
    impl="$(_knit_detect_mpi_launcher)"
    if [[ "${impl}" == "<unknown>" ]]; then
        # Mirror the tier-2 skip in _knit_launch_backend: a concrete machine
        # launcher wins over the setup contract, so the setup providing none is
        # only a problem when the machine itself offers none.
        local machine
        _knit_metadata_get machine "__launcher__"
        if [[ -z "${machine}" || "${machine}" == "<unknown>" || "${machine}" == "none" ]]; then
            knit_fatal "knit_provides_launcher: no MPI launcher found on PATH after the setup built. Ensure the setup installs an MPI whose mpirun/mpiexec is on PATH (e.g. knit_with_spack_specs \"mpi\")."
        fi
        knit_debug "knit_provides_launcher: no launcher found on PATH after the setup built; the machine's \"%s\" launcher will be used instead." "${machine}"
        knit_output "__mpi_launcher__" "<unknown>"
        return 0
    fi
    {
        printf '\n# Launcher contract (added by knit_provides_launcher)\n'
        printf 'export KNIT_PROVIDED_LAUNCHER=%q\n' "${impl}"
    } >> "${activate}"
    knit_output "__mpi_launcher__" "${impl}"
}

# ------------------------------------------------------------------------------
# @fn knit_provides_launcher()
#
# Declare that the setup currently being registered may supply an MPI launcher on
# a machine that has none. Must be called between knit_register_setup and
# knit_done, at most once per setup. A bare directive (the only form for now):
# it means "this setup may provide a launcher where the machine offers one of its
# own" — it sits *below* a concrete machine launcher (__launcher__) in the
# precedence, so a profile's launcher still wins (see _knit_launch_backend). A
# deliberate override is future work.
#
# The launcher is detected once at setup-build time (not at run time) by the
# after-callback and frozen into the setup's .activate.sh as
# KNIT_PROVIDED_LAUNCHER; it is recorded as the __mpi_launcher__ provenance output
# (a column in the setup's table). Setups are the only valid target: wrappers and
# non-setup commands are rejected.
#
# Example:
# ```
# knit_register_setup "juliaenv" _juliaenv "Build against MPI."
# knit_with_spack_specs "cmake" "mpi"
# knit_provides_launcher            # may launch where the machine has no MPI
# _juliaenv() { ... }
# knit_done
# ```
# ------------------------------------------------------------------------------
knit_provides_launcher() {
    # Setup-only. This also rejects wrappers (a wrapper is never a "setup:*"
    # command) and any use outside a knit_register* / knit_done pair.
    if [[ ! -v _KNIT_CURRENT_COMMAND ]] \
    || [[ "${_KNIT_CURRENT_COMMAND_DEMANGLED}" != setup:* ]]; then
        knit_fatal "knit_provides_launcher is valid only for setups; it must be called between knit_register_setup and knit_done."
    fi
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local marker_var="_KNIT_CMD_${cmd}_launcher"
    if [[ -n "${!marker_var:-}" ]]; then
        knit_fatal "knit_provides_launcher may be called at most once per setup."
    fi
    printf -v "${marker_var}" '%s' '1'

    _knit_run_after _knit_setup_provides_launcher_after_cb

    knit_with_output "__mpi_launcher__:string" "" \
        "The MPI launcher (openmpi/mpich/pals/flux) this setup detected and froze."

    # shellcheck disable=SC2178 # nameref to the command's notes array
    local -n notes_ref="_KNIT_CMD_${cmd}_notes"
    notes_ref+=("Provides an MPI launcher where the machine has none (knit_provides_launcher).")
}
