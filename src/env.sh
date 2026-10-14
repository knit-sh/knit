#!/bin/bash

## @file env.sh
##
## Manager-agnostic environment-manager layer. A single registration block
## (knit_register_env_manager ... knit_env_* ... knit_env_done) declares how a
## package/environment manager (Spack, and later conda/pixi/uv/easybuild
## plugins) provisions its tool, builds an environment from a manifest inside a
## setup, re-enters that environment, and which lockfile is its reproducibility
## contract. The generic layer owns the bootstrap wiring, the on-disk layout,
## and the provenance; each manager supplies only the tool-specific verbs.
##
## This file (M1) implements the registration API, the registry, the bootstrap
## option declaration, the body-driven provisioning dispatcher, and the lazy
## on-demand provisioner. The setup directives and update-mode handling are
## added in later milestones.

# ------------------------------------------------------------------------------
# @var _KNIT_ENV_MANAGERS
#
# Registry of registered environment managers, holding each manager's
# normalized (underscore) name in registration order. Appended by
# knit_env_done; iterated by the bootstrap provisioning dispatcher. Declared
# global (-g) so it survives knit.sh being sourced from within a function (as
# the bats tests do).
# ------------------------------------------------------------------------------
declare -ga _KNIT_ENV_MANAGERS
_KNIT_ENV_MANAGERS=()

# ------------------------------------------------------------------------------
# @fn _knit_env_require_context()
#
# Guard shared by the knit_env_* setters and knit_env_done: fatal unless a
# manager registration is open (knit_register_env_manager was called and
# knit_env_done has not yet closed it). Returns normally when a context is open.
#
# @param[in] fn Name of the calling function, used in the error message.
# ------------------------------------------------------------------------------
_knit_env_require_context() {
    if [[ ! -v _KNIT_ENV_CURRENT ]]; then
        knit_fatal "%s must be called between knit_register_env_manager and knit_env_done." "$1"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_env_is_registered()
#
# Return 0 when a manager with the given normalized name is in the registry,
# non-zero otherwise.
#
# @param[in] nm Normalized (underscore) manager name.
# ------------------------------------------------------------------------------
_knit_env_is_registered() {
    local m
    for m in "${_KNIT_ENV_MANAGERS[@]}"; do
        [[ "${m}" == "$1" ]] && return 0
    done
    return 1
}

# ------------------------------------------------------------------------------
# @fn knit_register_env_manager()
#
# Open an environment-manager registration. Must be followed by the mandatory
# knit_env_* declarations (provision, install, activate, specs, manifest,
# lockfile) and closed with knit_env_done. A manager's per-registration state is
# kept in _KNIT_ENV_<nm>_* globals, where <nm> is the normalized (underscore)
# name; the as-typed name is preserved in _KNIT_ENV_<nm>_display and is used for
# the on-disk directory (.knit/<name>) and for messages.
#
# Fatal when called inside an already-open registration, when the name is not a
# valid Knit name, or when a manager with the same normalized name is already
# registered.
#
# @param[in] name        Short name for the manager (e.g. "spack", "conda").
# @param[in] description One-line description.
# ------------------------------------------------------------------------------
knit_register_env_manager() {
    local name="$1"
    local description="$2"
    if [[ -v _KNIT_ENV_CURRENT ]]; then
        knit_fatal "knit_register_env_manager was called before the previous knit_env_done."
    fi
    if ! _knit_name_is_valid "${name}"; then
        knit_fatal "Invalid environment-manager name \"%s\"." "${name}"
    fi
    local nm
    _knit_name_normalize nm "${name}"
    if _knit_env_is_registered "${nm}"; then
        knit_fatal "Environment manager \"%s\" is already registered." "${name}"
    fi
    _KNIT_ENV_CURRENT="${nm}"
    printf -v "_KNIT_ENV_${nm}_display"     '%s' "${name}"
    printf -v "_KNIT_ENV_${nm}_description" '%s' "${description}"
    printf -v "_KNIT_ENV_${nm}_provision"   '%s' ""
    printf -v "_KNIT_ENV_${nm}_install"     '%s' ""
    printf -v "_KNIT_ENV_${nm}_activate"    '%s' ""
    printf -v "_KNIT_ENV_${nm}_specs"       '%s' ""
    printf -v "_KNIT_ENV_${nm}_manifest"    '%s' ""
    printf -v "_KNIT_ENV_${nm}_lockfile"    '%s' ""
    printf -v "_KNIT_ENV_${nm}_required"    '%s' ""
    declare -ga "_KNIT_ENV_${nm}_options=()"
    knit_trace "Registering environment manager \"${name}\"."
}

# ------------------------------------------------------------------------------
# @fn knit_env_provision()
#
# Declare the provision verb and, optionally, the bootstrap options it consumes.
# The function is called at bootstrap (and on-demand) to ensure the tool is
# present under .knit/<name>, pinned to the given refs (each empty means
# "latest"). Its arguments are the declared --options values, positional and in
# declared order.
#
# --options is a comma-separated list of "name:type" pairs (Knit's usual
# parameter type annotations). Each pair becomes an optional bootstrap option
# (declared by knit_env_done via knit_extend); the bootstrap provisioning
# dispatcher reads each one back and forwards it to the provision function.
#
# @param[in] fn       Name of the provision function.
# @param[in] --options Optional "name:type,..." list of bootstrap options.
# ------------------------------------------------------------------------------
knit_env_provision() {
    _knit_env_require_context "knit_env_provision"
    local fn="$1"
    shift
    local csv=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --options)   csv="$2"; shift 2 ;;
            --options=*) csv="${1#--options=}"; shift ;;
            *) knit_fatal "knit_env_provision: unexpected argument \"%s\"." "$1" ;;
        esac
    done
    local nm="${_KNIT_ENV_CURRENT}"
    printf -v "_KNIT_ENV_${nm}_provision" '%s' "${fn}"
    declare -ga "_KNIT_ENV_${nm}_options=()"
    if [[ -n "${csv}" ]]; then
        # shellcheck disable=SC2178 # nameref to the manager's options array
        local -n _knit_opts_ref="_KNIT_ENV_${nm}_options"
        local IFS=','
        local entry
        for entry in ${csv}; do
            # Trim surrounding whitespace so "a:int, b:str" is accepted.
            entry="${entry#"${entry%%[![:space:]]*}"}"
            entry="${entry%"${entry##*[![:space:]]}"}"
            [[ -n "${entry}" ]] && _knit_opts_ref+=("${entry}")
        done
    fi
}

# ------------------------------------------------------------------------------
# @fn knit_env_install()
#
# Declare the install verb: `<fn> <env_dir> <manifest_path>` builds the
# environment into <env_dir> from the manifest, returning non-zero on failure.
#
# @param[in] fn Name of the install function.
# ------------------------------------------------------------------------------
knit_env_install() {
    _knit_env_require_context "knit_env_install"
    printf -v "_KNIT_ENV_${_KNIT_ENV_CURRENT}_install" '%s' "$1"
}

# ------------------------------------------------------------------------------
# @fn knit_env_activate()
#
# Declare the activate verb: `<fn> <env_dir>` prints the shell lines that
# re-enter the environment (appended to the setup's .activate.sh).
#
# @param[in] fn Name of the activate function.
# ------------------------------------------------------------------------------
knit_env_activate() {
    _knit_env_require_context "knit_env_activate"
    printf -v "_KNIT_ENV_${_KNIT_ENV_CURRENT}_activate" '%s' "$1"
}

# ------------------------------------------------------------------------------
# @fn knit_env_specs()
#
# Declare the specs verb: `<fn> <spec...>` prints a minimal manifest body for a
# spec list (the sugar backing knit_with_<name>_specs).
#
# @param[in] fn Name of the specs-to-manifest function.
# ------------------------------------------------------------------------------
knit_env_specs() {
    _knit_env_require_context "knit_env_specs"
    printf -v "_KNIT_ENV_${_KNIT_ENV_CURRENT}_specs" '%s' "$1"
}

# ------------------------------------------------------------------------------
# @fn knit_env_manifest()
#
# Declare the basename of the manifest file inside the environment directory
# (e.g. "spack.yaml").
#
# @param[in] filename Manifest basename.
# ------------------------------------------------------------------------------
knit_env_manifest() {
    _knit_env_require_context "knit_env_manifest"
    printf -v "_KNIT_ENV_${_KNIT_ENV_CURRENT}_manifest" '%s' "$1"
}

# ------------------------------------------------------------------------------
# @fn knit_env_lockfile()
#
# Declare the basename of the lockfile (e.g. "spack.lock"): the reproducibility
# contract and the "environment is built" marker.
#
# @param[in] filename Lockfile basename.
# ------------------------------------------------------------------------------
knit_env_lockfile() {
    _knit_env_require_context "knit_env_lockfile"
    printf -v "_KNIT_ENV_${_KNIT_ENV_CURRENT}_lockfile" '%s' "$1"
}

# ------------------------------------------------------------------------------
# @fn knit_env_done()
#
# Close an environment-manager registration. Asserts every mandatory verb and
# scalar was declared (fatal listing any that are missing), appends the manager
# to the registry, and — when the manager declared --options — reopens the
# bootstrap command (knit_extend) to declare each option as an optional with an
# auto-generated description. Clears the registration context.
# ------------------------------------------------------------------------------
knit_env_done() {
    _knit_env_require_context "knit_env_done"
    local nm="${_KNIT_ENV_CURRENT}"
    local display_var="_KNIT_ENV_${nm}_display"
    local display="${!display_var}"

    local missing=()
    local field var
    for field in provision install activate specs manifest lockfile; do
        var="_KNIT_ENV_${nm}_${field}"
        [[ -n "${!var:-}" ]] || missing+=("${field}")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        knit_fatal "Environment manager \"%s\" is incomplete; missing: %s." \
            "${display}" "${missing[*]}"
    fi

    _KNIT_ENV_MANAGERS+=("${nm}")

    # shellcheck disable=SC2178 # nameref to the manager's options array
    local -n _knit_opts_ref="_KNIT_ENV_${nm}_options"
    if [[ ${#_knit_opts_ref[@]} -gt 0 ]]; then
        knit_extend "bootstrap"
        local entry name
        for entry in "${_knit_opts_ref[@]}"; do
            name="${entry%%:*}"
            knit_with_optional "${entry}" "" \
                "${name} ref/version to provision for the ${display} environment manager. Empty uses the latest."
        done
        knit_done
    fi

    unset _KNIT_ENV_CURRENT
}

# ------------------------------------------------------------------------------
# @fn _knit_env_option_names()
#
# Store, in the caller-named array, the declared bootstrap-option names of a
# manager (the "name" half of each "name:type" pair), in declared order.
#
# @param[out] __knit_ret Name of the array to hold the option names.
# @param[in] nm         Normalized (underscore) manager name.
# ------------------------------------------------------------------------------
_knit_env_option_names() {
    local -n __knit_ret=$1
    __knit_ret=()
    # shellcheck disable=SC2178 # nameref to the manager's options array
    local -n _knit_opts_ref="_KNIT_ENV_${2}_options"
    local entry
    for entry in "${_knit_opts_ref[@]}"; do
        __knit_ret+=("${entry%%:*}")
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_env_need_provision()
#
# Return 0 when a manager must be provisioned: either any of the given option
# refs is non-empty (the user asked for a specific version), or the manager is
# flagged required (a setup declared its environment, see later milestones).
#
# @param[in] name Manager name (any spelling).
# @param[in] ...  The option refs, positional in declared order (may be empty).
# ------------------------------------------------------------------------------
_knit_env_need_provision() {
    local nm
    _knit_name_normalize nm "$1"
    shift
    local ref
    for ref in "$@"; do
        [[ -n "${ref}" ]] && return 0
    done
    local required="_KNIT_ENV_${nm}_required"
    [[ -n "${!required:-}" ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_env_provision_one()
#
# Provision one manager at bootstrap time when it is needed: read each declared
# bootstrap option off the invocation arguments (in declared order), decide via
# _knit_env_need_provision, and on a yes call the provision verb with those refs
# positionally. A no-op when the manager is not needed.
#
# @param[in] nm Normalized (underscore) manager name.
# @param[in] ... The expanded bootstrap invocation arguments.
# ------------------------------------------------------------------------------
_knit_env_provision_one() {
    local nm="$1"
    shift
    local names=()
    _knit_env_option_names names "${nm}"
    local refs=()
    local name value
    for name in "${names[@]}"; do
        # A defaulted option is always present post-expansion, but tolerate a
        # missing one (knit_get_parameter returns non-zero) so the dispatcher is
        # safe to call directly too.
        value="$(knit_get_parameter "${name}" "$@")" || value=""
        refs+=("${value}")
    done
    if _knit_env_need_provision "${nm}" "${refs[@]}"; then
        local display="_KNIT_ENV_${nm}_display"
        knit_info "Bootstrapping %s..." "${!display}"
        local provision="_KNIT_ENV_${nm}_provision"
        "${!provision}" "${refs[@]}"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_env_provision_all()
#
# Provision every registered environment manager that is needed, in
# registration order. Called from the first-bootstrap body (after sqlite/jq so
# latest-release resolution and provenance metadata work). A no-op when no
# manager is registered.
#
# @param[in] ... The expanded bootstrap invocation arguments.
# ------------------------------------------------------------------------------
_knit_env_provision_all() {
    local nm
    for nm in "${_KNIT_ENV_MANAGERS[@]}"; do
        _knit_env_provision_one "${nm}" "$@"
    done
}

# ------------------------------------------------------------------------------
# @fn knit_env_ensure_provisioned()
#
# Ensure a manager's tool is present under .knit/<name>, provisioning it on
# demand when absent. This is the public entry point a setup's before-callback
# and a manager's own `knit <name>` wrapper use, since a setup may declare the
# manager's environment after bootstrap (which cannot be re-run). On-demand
# provisioning calls the provision verb with all options empty (latest).
#
# A no-op when the tool is already present. Fatal for an unknown manager, or
# when the experiment is not bootstrapped (there is no .knit to provision into).
#
# @param[in] name Manager name (any spelling).
# ------------------------------------------------------------------------------
knit_env_ensure_provisioned() {
    local name="$1"
    local nm
    _knit_name_normalize nm "${name}"
    if ! _knit_env_is_registered "${nm}"; then
        knit_fatal "Unknown environment manager \"%s\"." "${name}"
    fi
    local display_var="_KNIT_ENV_${nm}_display"
    local root="${_KNIT_PREFIX}/${!display_var}"
    [[ -d "${root}" ]] && return 0
    if ! _knit_is_bootstrapped; then
        knit_fatal "%s is required but the experiment is not bootstrapped. Run 'bootstrap' first." \
            "${!display_var}"
    fi
    knit_info "%s is required but not provisioned; downloading it now (one-time setup)..." \
        "${!display_var}"
    local names=()
    _knit_env_option_names names "${nm}"
    local empties=()
    local i
    for (( i = 0; i < ${#names[@]}; i++ )); do
        empties+=("")
    done
    local provision="_KNIT_ENV_${nm}_provision"
    "${!provision}" "${empties[@]}"
}
