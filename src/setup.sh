#!/bin/bash

## @file setup.sh

# ------------------------------------------------------------------------------
# @var _KNIT_SETUPS
#
# Associative array mapping registered setup names to 1. Used to validate that
# a setup name passed to `knit setup` is known.
# ------------------------------------------------------------------------------
declare -A _KNIT_SETUPS

knit_register _knit_setup "setup" "Setup an environment"
_knit_is_builtin
knit_with_required "path:path" "Path to the setup"
knit_with_dispatch "setup" "User-provided setup command to execute"
knit_with_subcommand_title "Setups"
# ------------------------------------------------------------------------------
# @fn _knit_setup()
#
# Entry point for the `setup` CLI command. Creates a directory at the given
# path, exports `KNIT_SETUP_PREFIX` to that directory, invokes the named setup
# subcommand inside it, and saves the resulting environment to
# `$KNIT_SETUP_PREFIX/.activate.sh`. On success the setup name is also recorded
# in `$KNIT_SETUP_PREFIX/.setup.type` so `knit submit` can validate a job's
# knit_with_setup requirement, and the setup body's row id in
# `$KNIT_SETUP_PREFIX/.setup.id` so a consumer can record a "uses" edge to it.
# Removes the directory and fatals on failure.
#
# Usage:
# ```
# ./exp.sh setup --path </path/to/setup> -- <setup-name> [args...]
# ```
# ------------------------------------------------------------------------------
_knit_setup() {
    local path
    path=$(knit_get_parameter "path" "$@")

    # Extract extra args (after --)
    local args=("$@")
    local extra_index
    extra_index=$(knit_extra_index "${args[@]}")
    local extra=("${args[@]:extra_index}")

    if [[ ${#extra[@]} -eq 0 ]]; then
        knit_fatal "setup requires a setup name (pass it after --)."
    fi

    local setup_name="${extra[0]}"
    local setup_args=("${extra[@]:1}")

    # Check path does not already exist
    if [[ -e "${path}" ]]; then
        knit_fatal "Path \"${path}\" already exists."
    fi

    # Check setup name is registered
    if [[ ! -v _KNIT_SETUPS["${setup_name}"] ]]; then
        knit_fatal "Unknown setup \"${setup_name}\"."
    fi

    # Validate args for the setup subcommand (knit_fatal on bad args)
    local subcmd
    subcmd=$(_knit_command_mangle "setup:${setup_name}")
    _knit_check_command_arguments "${subcmd}" "${setup_args[@]}"

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
        knit_fatal "Setup \"${setup_name}\" failed; removed \"${path}\"."
    fi

    # Record the setup type that built this directory so that `knit submit` can
    # check a job's knit_with_setup requirement against it.
    printf '%s\n' "${setup_name}" > "${path}/.setup.type"

    # Record the setup body's row id so a later consumer can record a "uses" edge
    # to this setup by id (robust) rather than by matching directory paths. Only
    # written when the body recorded a row (i.e. the experiment is bootstrapped);
    # a setup directory without this marker simply yields no "uses" edge.
    if [[ -n "${body_row_id}" ]]; then
        printf '%s\n' "${body_row_id}" > "${path}/.setup.id"
    fi
}
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_setup_before_cb()
#
# Before-callback installed on every setup subcommand by knit_register_setup.
# Verifies that KNIT_SETUP_PREFIX is set, ensuring the setup was invoked
# through `knit setup` rather than called directly.
# ------------------------------------------------------------------------------
_knit_setup_before_cb() {
    if [[ ! -v KNIT_SETUP_PREFIX ]]; then
        knit_fatal "Setup commands must be invoked via \"knit setup [OPTIONS] -- <setup> [OPTIONS]\", not directly."
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_setup_after_cb()
#
# After-callback installed on every setup subcommand by knit_register_setup.
# Dumps all exported environment variables into
# `$KNIT_SETUP_PREFIX/.activate.sh` so that jobs depending on this setup can
# source that file to reproduce the build environment.
#
# Dynamic bash internals (BASH_*, SHLVL, _, OLDPWD, PPID, RANDOM, LINENO,
# SECONDS, KNIT_SETUP_PREFIX) are excluded from the dump.
# ------------------------------------------------------------------------------
_knit_setup_after_cb() {
    local activate="${KNIT_SETUP_PREFIX}/.activate.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf '# Generated by knit\n'
        local var
        while IFS= read -r var; do
            case "${var}" in
                BASH_*|SHLVL|_|OLDPWD|PPID|RANDOM|LINENO|SECONDS|KNIT_SETUP_PREFIX)
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
# @param name        Short name for the setup (used as the subcommand name).
# @param fn          Name of the Bash function implementing the setup.
# @param description One-line description shown in `--help`.
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
    knit_register "${fn}" "setup:${name}" "${description}"
    knit_with_table
    _KNIT_SETUPS["${name}"]=1
    _knit_run_before _knit_setup_before_cb
    _knit_run_after  _knit_setup_after_cb
}

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
# @param setup_path Path to the setup directory to check.
# @param required   Setup type the directory must have been built by.
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
# @fn _knit_setup_dep_before_cb()
#
# Before-callback installed by knit_with_setup on a plain command or an app. It
# resolves the setup directory the command depends on, checks its type, and
# sources its .activate.sh so the command body runs in the setup's environment.
# Jobs do not use this callback: their setup is resolved at submit time
# (_knit_submit) and re-sourced on the compute node (_knit_job_before_cb). Setups
# and wrappers cannot declare knit_with_setup at all (knit_with_setup rejects them).
#
# The setup directory comes from the command's --setup option; when that is
# absent it falls back to an already-set KNIT_SETUP_PREFIX (e.g. an app running
# inside a job inherits the job's setup).
#
# @param required Setup type the dependency must have been built by. Remaining
#                 arguments are the command's own runtime arguments, scanned for
#                 --setup.
# ------------------------------------------------------------------------------
_knit_setup_dep_before_cb() {
    local required="$1"
    shift
    local setup_path
    setup_path=$(knit_get_parameter "setup" "$@") || setup_path=""
    if [[ -z "${setup_path}" ]]; then
        setup_path="${KNIT_SETUP_PREFIX:-}"
    fi
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
# @fn _knit_setup_record_uses_edge()
#
# Record a "uses" provenance edge from the setup built at <setup_path> to a
# consuming invocation. The edge's source is the setup (its row id read from the
# setup directory's .setup.id marker, its name "setup:<type>" from .setup.type);
# its target is the consumer. A "uses" edge has no duration, so both timestamps
# are NULL. Shared by `knit submit` (jobs) and by the generic setup-dependency
# after-callback (plain commands and apps).
#
# Best-effort and gated with the other provenance writes: it records nothing when
# recording is disabled, on a suppressed rank, before bootstrap, when the target
# does not participate in the graph, or when the setup directory has no .setup.id
# (e.g. it was built before provenance shipped).
#
# @param setup_path  Path to the setup directory the consumer references.
# @param target_cmd  Mangled command name of the consumer (the edge target).
# @param target_id   Resolved row id of the consumer (the edge target).
# ------------------------------------------------------------------------------
_knit_setup_record_uses_edge() {
    local setup_path="$1"
    local target_cmd="$2"
    local target_id="$3"
    [[ "${KNIT_DISABLE_RECORDING:-}" == "true" ]] && return 0
    [[ -n "${_KNIT_RECORDING_SUPPRESSED}" ]] && return 0
    _knit_is_bootstrapped || return 0
    _knit_provenance_enabled "${target_cmd}" || return 0
    local id_file="${setup_path}/.setup.id"
    [[ -f "${id_file}" ]] || return 0
    local setup_id=""
    IFS= read -r setup_id < "${id_file}" || setup_id=""
    [[ -z "${setup_id}" ]] && return 0
    local setup_type=""
    IFS= read -r setup_type < "${setup_path}/.setup.type" 2>/dev/null || setup_type=""
    _knit_prov_ensure_table
    _knit_prov_record_edge "${setup_id}" "setup:${setup_type}" \
        "${target_id}" "$(_knit_command_demangle "${target_cmd}")" "uses" "" ""
}

# ------------------------------------------------------------------------------
# @fn _knit_setup_dep_after_cb()
#
# After-callback installed by knit_with_setup on a plain command or an app,
# alongside _knit_setup_dep_before_cb. It records a "uses" edge from the setup the
# command depends on to the command itself. It runs as an after-callback (not the
# before-callback that sources the environment) because the consumer's frame is on
# the executing stacks only from push time onward, so the consumer's resolved row
# id — the edge target — is available here but not in the before-callback.
#
# It resolves the same setup directory the before-callback used (the --setup
# option, else the ambient KNIT_SETUP_PREFIX), so the two always agree. All
# arguments are the command's own runtime arguments, scanned for --setup.
# ------------------------------------------------------------------------------
_knit_setup_dep_after_cb() {
    local setup_path
    setup_path=$(knit_get_parameter "setup" "$@") || setup_path=""
    if [[ -z "${setup_path}" ]]; then
        setup_path="${KNIT_SETUP_PREFIX:-}"
    fi
    [[ -z "${setup_path}" ]] && return 0
    setup_path="$(realpath "${setup_path}" 2>/dev/null)" || return 0
    [[ ${#_KNIT_EXECUTING_COMMAND[@]} -gt 0 ]] || return 0
    _knit_setup_record_uses_edge "${setup_path}" \
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
# @param type Name of the required setup type.
# ------------------------------------------------------------------------------
knit_with_setup() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_with_setup must be called between a knit_register* call and knit_done."
    fi
    if [[ "${_KNIT_CURRENT_COMMAND_DEMANGLED}" == setup:* ]]; then
        knit_fatal "knit_with_setup cannot be used on a setup (setups cannot depend on other setups)."
    fi
    _knit_wrapper_reject_declaration "knit_with_setup"
    local setup_type="$1"
    if ! _knit_name_is_valid "${setup_type}"; then
        knit_fatal "Setup type \"${setup_type}\" is not a valid name."
    fi
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local marker_var="_KNIT_CMD_${cmd}_setup"
    if [[ -n "${!marker_var:-}" ]]; then
        knit_fatal "knit_with_setup may be called at most once per command."
    fi
    printf -v "${marker_var}" '%s' "${setup_type}"
    knit_trace "Command \"${_KNIT_CURRENT_COMMAND_DEMANGLED}\" requires a \"${setup_type}\" setup."

    # Advertise the requirement in the command's `--help` output (see the
    # "Requirements" section rendered by _knit_print_command_usage).
    # shellcheck disable=SC2178 # nameref to the command's notes array
    local -n _notes_ref="_KNIT_CMD_${cmd}_notes"
    _notes_ref+=("Requires a --setup built by the \"${setup_type}\" setup.")

    # Jobs resolve and enforce the setup at submit time (see _knit_submit) and
    # re-source it on the compute node (_knit_job_before_cb): no local --setup
    # option or before-callback is added here.
    if [[ "${_KNIT_CURRENT_COMMAND_DEMANGLED}" == submit:* ]]; then
        return 0
    fi

    # Plain commands and apps get a --setup option, a before-callback that
    # validates and activates it, and an after-callback that records the "uses"
    # edge (the consumer's row id, the edge target, is resolved only from push
    # time on, so the edge is emitted after the body rather than in the
    # before-callback).
    knit_with_optional "setup:path" "" \
        "Path to a setup built by the \"${setup_type}\" setup."
    _knit_run_before _knit_setup_dep_before_cb "${setup_type}"
    _knit_run_after  _knit_setup_dep_after_cb
}

# ------------------------------------------------------------------------------
# @fn _knit_setup_spack_env_before_cb()
#
# Before-callback installed by knit_with_spack_env. Runs as the setup's first
# step (before-cbs execute in the setup's own shell, so the activated environment
# persists into the setup body and into the after-callbacks). It materializes the
# environment manifest to ${KNIT_SETUP_PREFIX}/spack.yaml, builds the Spack
# environment at ${KNIT_SETUP_PREFIX}/spack-env, and activates it in the current
# shell so the setup body builds against the installed packages.
#
# The manifest source is captured at registration time and carried in the
# callback arguments (mode + source); trailing arguments are the setup's own
# runtime arguments and are ignored.
#
# @param mode   "file" (source is an absolute path to copy) or "stdin" (source
#               is the literal manifest content captured from a here-doc).
# @param source Manifest path (mode=file) or manifest content (mode=stdin).
# ------------------------------------------------------------------------------
_knit_setup_spack_env_before_cb() {
    local mode="$1"
    local source="$2"
    local yaml="${KNIT_SETUP_PREFIX}/spack.yaml"
    local env_dir="${KNIT_SETUP_PREFIX}/spack-env"
    if [[ "${mode}" == "file" ]]; then
        cp "${source}" "${yaml}"
    else
        printf '%s\n' "${source}" > "${yaml}"
    fi
    _knit_spack_env_install "${env_dir}" "${yaml}"
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
# @param file Optional path to a spack.yaml manifest. If omitted, the manifest
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
# @param ... One or more Spack specs.
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
