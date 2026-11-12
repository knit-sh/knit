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

    # Generate the per-manager setup directives knit_with_<nm>_env,
    # knit_with_<nm>_env_from, knit_with_<nm>_specs, and knit_with_<nm>_specs_from
    # as thin wrappers over the generic implementations.
    # eval is required to define functions whose names carry the manager name;
    # <nm> is a validated identifier (from _knit_name_is_valid) so the generated
    # text is safe. A hyphenated manager name yields underscore-named functions
    # (knit_with_my_tool_env), matching Knit's hyphen/underscore interchange.
    # shellcheck disable=SC2155 # simple generated definitions, no command substitution
    eval "knit_with_${nm}_env()        { _knit_env_with_env        ${nm} \"\$@\"; }"
    # shellcheck disable=SC2155
    eval "knit_with_${nm}_env_from()   { _knit_env_with_env_from   ${nm} \"\$@\"; }"
    # shellcheck disable=SC2155
    eval "knit_with_${nm}_specs()      { _knit_env_with_specs      ${nm} \"\$@\"; }"
    # shellcheck disable=SC2155
    eval "knit_with_${nm}_specs_from() { _knit_env_with_specs_from ${nm} \"\$@\"; }"

    # Give the directives their "@" shorthands. A plugin declares its manager
    # after knit.sh is fully sourced, so the shorthand layer already exists:
    # register now. A core manager's source file loads before src/shorthand.sh,
    # so knit_register_shorthand does not exist yet; the source-time generator
    # picks the manager up from the registry and registers them instead.
    if declare -F knit_register_shorthand >/dev/null 2>&1; then
        _knit_env_register_shorthands "${nm}"
    fi

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
# @fn _knit_env_register_shorthands()
#
# Register the "@with_<nm>_env", "@with_<nm>_env_from", "@with_<nm>_specs", and
# "@with_<nm>_specs_from" shorthands for a manager, each forwarding to the
# directive knit_env_done generated. KNIT_WITHOUT_SHORTHAND
# and collision rejection are handled by knit_register_shorthand. Called from
# knit_env_done for a plugin's manager (declared after the shorthand layer
# exists) and from the source-time shorthand generator for a core manager
# (declared before it).
#
# @param[in] nm Normalized (underscore) manager name.
# ------------------------------------------------------------------------------
_knit_env_register_shorthands() {
    local nm="$1"
    knit_register_shorthand "with_${nm}_env"        "knit_with_${nm}_env"
    knit_register_shorthand "with_${nm}_env_from"   "knit_with_${nm}_env_from"
    knit_register_shorthand "with_${nm}_specs"      "knit_with_${nm}_specs"
    knit_register_shorthand "with_${nm}_specs_from" "knit_with_${nm}_specs_from"
}

# ------------------------------------------------------------------------------
# @fn _knit_env_is_manager_shorthand()
#
# Return 0 when the token is the "with_<nm>_env", "with_<nm>_env_from",
# "with_<nm>_specs", or "with_<nm>_specs_from" shorthand of a registered
# environment manager. The source-time shorthand generator uses
# it so a KNIT_WITHOUT_SHORTHAND opt-out of such a token is recognised rather
# than warned about as an unknown token.
#
# @param[in] token Shorthand token (the part after "@").
# ------------------------------------------------------------------------------
_knit_env_is_manager_shorthand() {
    local token="$1"
    local nm
    for nm in "${_KNIT_ENV_MANAGERS[@]}"; do
        [[ "${token}" == "with_${nm}_env" \
        || "${token}" == "with_${nm}_env_from" \
        || "${token}" == "with_${nm}_specs" \
        || "${token}" == "with_${nm}_specs_from" ]] \
            && return 0
    done
    return 1
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

# ------------------------------------------------------------------------------
# @fn _knit_env_require_setup_context()
#
# Guard shared by the setup directives (knit_with_<nm>_env / _specs / _env_from /
# _specs_from): fatal unless a setup registration is currently open. Returns
# normally when the context is a setup.
#
# @param[in] directive Full directive name, used in the error message.
# ------------------------------------------------------------------------------
_knit_env_require_setup_context() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]] \
    || [[ "${_KNIT_CURRENT_COMMAND_DEMANGLED}" != setup:* ]]; then
        knit_fatal "%s is valid only for setups; it must be called between knit_register_setup and knit_done." "$1"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_env_record_contribution()
#
# Generic recorder shared by every setup environment directive. It (1) validates
# the A/B mode rule against what the setup has already declared for this manager,
# (2) appends the contribution to the per-command, per-manager contribution list,
# and (3) on the FIRST contribution for a manager, installs the build/activation
# callbacks, declares the __<nm>_manifest__ / __<nm>_lock__ provenance outputs and
# the --help note, and flags the manager required so bootstrap provisions it.
#
# A setup declares, per manager, EITHER world A (one complete manifest, mode
# "env") OR world B (an accumulating spec list, mode "specs"); the two cannot be
# mixed, and world A is exactly one contribution. The caller passes the mode its
# directive belongs to; a conflicting or duplicate world-A declaration is fatal.
#
# The contribution list `_KNIT_CMD_<cmd>_envcontrib_<nm>` holds two array elements
# per contribution — a tag then its payload — so a payload (such as an inline
# manifest) may carry spaces and newlines without any escaping. The mode is kept
# in the scalar `_KNIT_CMD_<cmd>_envmode_<nm>`.
#
# @param[in] nm       Normalized (underscore) manager name.
# @param[in] mode     "env" (world A, exclusive) or "specs" (world B, additive).
# @param[in] tag      Contribution tag (literal-spec / fn-spec / file-manifest /
#                  stdin-manifest / fn-manifest).
# @param[in] ...      One payload per remaining argument; each appended as its own
#                  contribution with the same tag (so knit_with_<nm>_specs can pass
#                  several specs at once).
# ------------------------------------------------------------------------------
_knit_env_record_contribution() {
    local nm="$1" mode="$2" tag="$3"
    shift 3
    local display_var="_KNIT_ENV_${nm}_display"
    local display="${!display_var}"
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local mode_var="_KNIT_CMD_${cmd}_envmode_${nm}"
    local existing="${!mode_var:-}"
    local contrib_var="_KNIT_CMD_${cmd}_envcontrib_${nm}"

    # Enforce the A/B rule. World A (one manifest) is exactly one contribution and
    # mutually exclusive with world B (a spec list).
    if [[ -n "${existing}" ]]; then
        if [[ "${existing}" != "${mode}" ]]; then
            knit_fatal "Setup \"%s\" cannot mix a complete %s manifest with %s specs; declare either one manifest (knit_with_%s_env / knit_with_%s_env_from) or any number of specs (knit_with_%s_specs / knit_with_%s_specs_from), not both." \
                "${_KNIT_CURRENT_COMMAND_DEMANGLED}" "${display}" "${display}" "${nm}" "${nm}" "${nm}" "${nm}"
        fi
        if [[ "${mode}" == "env" ]]; then
            knit_fatal "Setup \"%s\" may declare at most one complete %s manifest (knit_with_%s_env / knit_with_%s_env_from)." \
                "${_KNIT_CURRENT_COMMAND_DEMANGLED}" "${display}" "${nm}" "${nm}"
        fi
    fi

    # First contribution for this manager: set the mode, create the list, and
    # install the callbacks / outputs / note / required flag exactly once.
    if [[ -z "${existing}" ]]; then
        printf -v "${mode_var}" '%s' "${mode}"
        declare -ga "${contrib_var}=()"

        knit_run_before _knit_env_setup_before_cb "${nm}"
        knit_run_after  _knit_env_setup_after_cb  "${nm}"

        knit_with_output "__${nm}_manifest__:string" "" \
            "gzip+base64 of the environment's concrete manifest."
        knit_with_output "__${nm}_lock__:string" "" \
            "gzip+base64 of the environment's lockfile."

        # shellcheck disable=SC2178 # nameref to the command's notes array
        local -n _notes_ref="_KNIT_CMD_${cmd}_notes"
        _notes_ref+=("Builds a ${display} environment before the setup body runs.")

        printf -v "_KNIT_ENV_${nm}_required" '%s' '1'
    fi

    # Append one (tag, payload) pair per payload argument.
    # shellcheck disable=SC2178 # nameref to the command's contribution array
    local -n _contrib_ref="${contrib_var}"
    local payload
    for payload in "$@"; do
        _contrib_ref+=("${tag}" "${payload}")
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_env_with_env()
#
# Generic implementation of knit_with_<nm>_env: declare that the setup currently
# being registered needs a <nm> environment described by a complete manifest
# (world A). The manifest is a file (non-empty first argument, resolved absolute
# at registration and recorded with knit_bundle_auto_require) or, with no
# argument, a here-doc / stdin manifest consumed at registration. The stdin form
# fails fast on an interactive terminal (nothing to read) and rejects an empty
# manifest.
#
# Valid only inside a setup registration (fatal otherwise). World A is exactly one
# contribution per manager and mutually exclusive with the world-B spec
# directives (enforced by the shared recorder).
#
# @param[in] nm   Normalized (underscore) manager name (bound by the wrapper).
# @param[in] file Optional manifest path; if omitted, read from stdin.
# ------------------------------------------------------------------------------
_knit_env_with_env() {
    local nm="$1"
    shift
    _knit_env_require_setup_context "knit_with_${nm}_env"
    knit_reject_if_wrapper "knit_with_${nm}_env"

    local tag source
    if [[ -n "$1" ]]; then
        tag="file-manifest"
        source="$(realpath -m "$1" 2>/dev/null || printf '%s' "$1")"
        # The manifest is an input the bundle should carry. Record it verbatim
        # (the user's typed path); "knit bundle" validates it there.
        knit_bundle_auto_require "$1"
    else
        # No path given: the manifest must arrive on stdin. If stdin is an
        # interactive terminal there is nothing to read and "cat" would block
        # forever, so fail fast with guidance rather than hang.
        if _knit_stdin_is_terminal; then
            knit_fatal "knit_with_%s_env: no manifest provided. Give a manifest path, feed one on stdin (here-doc/here-string/pipe), or use knit_with_%s_specs." "${nm}" "${nm}"
        fi
        tag="stdin-manifest"
        source="$(cat)"
        if [[ -z "${source//[[:space:]]/}" ]]; then
            knit_fatal "knit_with_%s_env: the manifest read from stdin is empty." "${nm}"
        fi
    fi

    _knit_env_record_contribution "${nm}" "env" "${tag}" "${source}"
}

# ------------------------------------------------------------------------------
# @fn _knit_env_with_env_from()
#
# Generic implementation of knit_with_<nm>_env_from: the programmatic twin of
# knit_with_<nm>_env (world A). Instead of a file or an inline document, a user
# function produces the complete manifest at setup-invocation time. The function
# is called as `<fn> "$@"` with the setup's expanded invocation arguments, reads
# its parameters with knit_get_parameter, and prints the whole manifest
# (spack.yaml / pyproject.toml) on stdout; the document is then rendered for
# "{{parameter}}" and materialized.
#
# Valid only inside a setup registration (fatal otherwise). World A is exactly one
# contribution per manager and mutually exclusive with the world-B spec directives
# (enforced by the shared recorder). The function name is captured here and
# resolved when the setup runs; the function must be defined by then.
#
# @param[in] nm Normalized (underscore) manager name (bound by the wrapper).
# @param[in] fn Name of the manifest-generating function.
# ------------------------------------------------------------------------------
_knit_env_with_env_from() {
    local nm="$1"
    shift
    _knit_env_require_setup_context "knit_with_${nm}_env_from"
    if [[ -z "$1" ]]; then
        knit_fatal "knit_with_%s_env_from requires the name of a manifest-generating function." "${nm}"
    fi
    _knit_env_record_contribution "${nm}" "env" "fn-manifest" "$1"
}

# ------------------------------------------------------------------------------
# @fn _knit_env_with_specs()
#
# Generic implementation of knit_with_<nm>_specs: the common "just install these
# specs" case (world B). Each spec is appended to the setup's accumulating spec
# list; at build time the manager's specs verb synthesizes one manifest from the
# whole list, so provenance capture, activation, and auto-provisioning all apply
# identically. Valid only inside a setup registration; additive with other
# world-B directives and mutually exclusive with the world-A manifest directives
# (enforced by the shared recorder).
#
# @param[in] nm  Normalized (underscore) manager name (bound by the wrapper).
# @param[in] ... One or more specs.
# ------------------------------------------------------------------------------
_knit_env_with_specs() {
    local nm="$1"
    shift
    _knit_env_require_setup_context "knit_with_${nm}_specs"
    if [[ $# -eq 0 ]]; then
        knit_fatal "knit_with_%s_specs requires at least one spec." "${nm}"
    fi
    _knit_env_record_contribution "${nm}" "specs" "literal-spec" "$@"
}

# ------------------------------------------------------------------------------
# @fn _knit_env_with_specs_from()
#
# Generic implementation of knit_with_<nm>_specs_from: like knit_with_<nm>_specs
# (world B) but the specs are produced by a user function at setup-invocation time
# instead of being literal. The function is called as `<fn> "$@"` with the setup's
# expanded invocation arguments, reads its parameters with knit_get_parameter, and
# prints newline-separated specs on stdout; each non-blank line is rendered for
# "{{parameter}}" and appended to the setup's accumulating spec list. It composes
# freely with knit_with_<nm>_specs and other knit_with_<nm>_specs_from calls (any
# order), and is mutually exclusive with the world-A manifest directives.
#
# The function name is captured here and resolved when the setup runs; the
# function must be defined by then.
#
# @param[in] nm Normalized (underscore) manager name (bound by the wrapper).
# @param[in] fn Name of the spec-generating function.
# ------------------------------------------------------------------------------
_knit_env_with_specs_from() {
    local nm="$1"
    shift
    _knit_env_require_setup_context "knit_with_${nm}_specs_from"
    if [[ -z "$1" ]]; then
        knit_fatal "knit_with_%s_specs_from requires the name of a spec-generating function." "${nm}"
    fi
    _knit_env_record_contribution "${nm}" "specs" "fn-spec" "$1"
}

# ------------------------------------------------------------------------------
# @fn _knit_env_render_tokens()
#
# Render the "{{parameter-name}}" placeholders in a manifest (or spec) text,
# replacing each with the value of the named setup parameter. The parameter
# values are read with knit_get_parameter from the setup's expanded invocation
# arguments (passed as the trailing arguments). This is the one rendering point
# shared by the specs sugar, here-doc/stdin manifests, and file manifests.
#
# A token is "{{" + optional whitespace + a parameter name + optional whitespace
# + "}}". The name may use hyphens or underscores interchangeably (as everywhere
# in Knit). Substitution is textual and literal: the value is inserted verbatim,
# with no recursion over an inserted value and no shell evaluation. Text with no
# "{{" is returned unchanged by a cheap early check, so the common,
# non-parameterized case pays almost nothing.
#
# A token whose name does not resolve to a declared parameter of the setup
# (knit_get_parameter returns non-zero) is almost always a typo; it is fatal,
# naming the unresolved placeholder and the manager.
#
# @param[out] __knit_ret Name of the variable to hold the rendered text.
# @param[in] display Manager display name, used only in the fatal message.
# @param[in] text    The manifest/spec text that may contain "{{...}}" tokens.
# @param[in] ...     The setup's expanded invocation arguments.
# ------------------------------------------------------------------------------
_knit_env_render_tokens() {
    # shellcheck disable=SC2178 # scalar nameref output; the array use is in a sibling function sharing the name
    local -n __knit_ret=$1; shift
    local display="$1"; shift
    local text="$1"; shift
    # "$@" now holds the setup's invocation arguments.

    # Fast path: no placeholder at all, return the text verbatim.
    if [[ "${text}" != *"{{"* ]]; then
        # shellcheck disable=SC2178 # scalar nameref output; the array use is in a sibling function sharing the name
        __knit_ret="${text}"
        return 0
    fi

    local out="" rest="${text}"
    local name value
    # Walk the text, consuming one "{{ name }}" token per iteration: the literal
    # run before the token is appended as-is, then the token is replaced with its
    # resolved value.
    while [[ "${rest}" =~ \{\{[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*\}\} ]]; do
        name="${BASH_REMATCH[1]}"
        # Everything up to (not including) the match is literal.
        out+="${rest%%"${BASH_REMATCH[0]}"*}"
        if ! value="$(knit_get_parameter "${name}" "$@")"; then
            knit_fatal "unresolved placeholder {{%s}} in the %s manifest — it does not name a declared parameter of this setup." \
                "${name}" "${display}"
        fi
        out+="${value}"
        # Advance past the consumed literal run and the token.
        rest="${rest#*"${BASH_REMATCH[0]}"}"
    done
    out+="${rest}"
    # shellcheck disable=SC2178 # scalar nameref output; the array use is in a sibling function sharing the name
    __knit_ret="${out}"
}

# ------------------------------------------------------------------------------
# @fn _knit_env_resolve_manifest()
#
# Resolve the setup's contribution list for one manager into the concrete
# manifest text, at invocation time. World A (a single file / stdin / function
# manifest) yields the document verbatim (rendered); world B (a spec list) runs
# any spec-generating functions, collects every spec, and synthesizes one manifest
# via the manager's specs verb. "{{parameter}}" placeholders are rendered against
# the setup's invocation arguments throughout.
#
# @param[out] __knit_ret Name of the variable to hold the rendered manifest text.
# @param[in] nm      Normalized (underscore) manager name.
# @param[in] cmd     Mangled command name of the executing setup (holds the list).
# @param[in] ...     The setup's expanded invocation arguments.
# ------------------------------------------------------------------------------
_knit_env_resolve_manifest() {
    # shellcheck disable=SC2178 # scalar nameref output; the array use is in a sibling function sharing the name
    local -n __knit_ret=$1; shift
    local nm="$1" cmd="$2"; shift 2
    local display_var="_KNIT_ENV_${nm}_display"
    local display="${!display_var}"
    # shellcheck disable=SC2178 # nameref to the command's contribution array
    local -n _contrib_ref="_KNIT_CMD_${cmd}_envcontrib_${nm}"

    # __knit_rendered is passed DOWN as _knit_env_render_tokens' output nameref,
    # so it must not collide with a name the caller passes us as __knit_ret (the
    # before-cb passes "rendered"): a plain "rendered" here would be shadowed by
    # that nameref and the render would write nothing. Keep it __-prefixed.
    local collected=() __knit_rendered tag payload line
    local i
    for (( i = 0; i < ${#_contrib_ref[@]}; i += 2 )); do
        tag="${_contrib_ref[i]}"
        payload="${_contrib_ref[i+1]}"
        case "${tag}" in
            file-manifest|stdin-manifest|fn-manifest)
                # World A: exactly one entry (enforced at registration). Produce
                # the whole document, render "{{...}}", return it directly.
                local text
                if [[ "${tag}" == "file-manifest" ]]; then
                    text="$(cat "${payload}")"
                elif [[ "${tag}" == "stdin-manifest" ]]; then
                    text="${payload}"
                else
                    if ! text="$("${payload}" "$@")"; then
                        knit_error "The %s manifest function \"%s\" exited non-zero." \
                            "${display}" "${payload}"
                        return 1
                    fi
                fi
                _knit_env_render_tokens __knit_rendered "${display}" "${text}" "$@"
                # shellcheck disable=SC2178 # scalar nameref output; the array use is in a sibling function sharing the name
                __knit_ret="${__knit_rendered}"
                return 0
                ;;
            literal-spec)
                _knit_env_render_tokens __knit_rendered "${display}" "${payload}" "$@"
                collected+=("${__knit_rendered}")
                ;;
            fn-spec)
                # Run the spec-generating function; split its stdout into non-blank
                # lines, rendering "{{...}}" on each.
                local out
                if ! out="$("${payload}" "$@")"; then
                    knit_error "The %s spec function \"%s\" exited non-zero." \
                        "${display}" "${payload}"
                    return 1
                fi
                while IFS= read -r line; do
                    [[ -z "${line//[[:space:]]/}" ]] && continue
                    _knit_env_render_tokens __knit_rendered "${display}" "${line}" "$@"
                    collected+=("${__knit_rendered}")
                done <<< "${out}"
                ;;
            *)
                knit_fatal "internal error: unknown environment contribution tag \"%s\"." "${tag}"
                ;;
        esac
    done

    # World B: synthesize one manifest from the whole collected spec list.
    if [[ ${#collected[@]} -eq 0 ]]; then
        knit_fatal "Setup produced no %s specs; every spec function printed nothing and no literal spec was given." \
            "${display}"
    fi
    local specs_fn="_KNIT_ENV_${nm}_specs"
    # shellcheck disable=SC2178 # scalar nameref output; the array use is in a sibling function sharing the name
    __knit_ret="$("${!specs_fn}" "${collected[@]}")"
}

# ------------------------------------------------------------------------------
# @fn _knit_env_setup_before_cb()
#
# Before-callback installed by the first environment contribution. Runs as the
# setup's first step (before-cbs execute in the setup's own shell, so the
# activated environment persists into the setup body and the after-callbacks). It
# sources the platform, provisions the manager on demand, resolves the setup's
# contribution list into a concrete manifest, writes it to
# ${KNIT_SETUP_PREFIX}/<manifest>, builds the environment into
# ${KNIT_SETUP_PREFIX}/<nm>-env via the install verb, and activates it in the
# current shell (by eval-ing the activate verb's lines) so the body builds
# against the installed packages.
#
# On an install failure (or a spec/manifest function exiting non-zero) it returns
# non-zero WITHOUT activating: the non-zero status propagates so the setup body
# never runs and the setup dispatcher removes the half-built directory.
#
# The resolved specs/manifest may contain "{{parameter}}" placeholders; they are
# rendered against the setup's expanded invocation arguments (the trailing
# arguments) while the contribution list is resolved, so a spec or manifest can
# depend on a setup parameter. A file manifest is rendered on read (the file on
# disk is never modified).
#
# @param[in] nm  Normalized (underscore) manager name.
# @param[in] ... The setup's expanded invocation arguments, used to run spec /
#            manifest functions and resolve "{{parameter}}" placeholders.
# ------------------------------------------------------------------------------
_knit_env_setup_before_cb() {
    local nm="$1"
    shift
    local cmd="${_KNIT_EXECUTING_COMMAND[-1]}"
    local display_var="_KNIT_ENV_${nm}_display"
    local display="${!display_var}"
    local manifest_var="_KNIT_ENV_${nm}_manifest"
    local manifest="${!manifest_var}"
    local install_var="_KNIT_ENV_${nm}_install"
    local activate_var="_KNIT_ENV_${nm}_activate"
    local manifest_path="${KNIT_SETUP_PREFIX}/${manifest}"
    local env_dir="${KNIT_SETUP_PREFIX}/${nm}-env"
    # Source the platform first so the environment builds against platform
    # modules/environment. Idempotent with the generic setup before-callback.
    _knit_setup_source_platform
    # Provision on demand: a setup may have gained this directive after the
    # experiment was bootstrapped without the manager, and bootstrap cannot be
    # re-run.
    knit_env_ensure_provisioned "${display}"
    # Resolve the contribution list into the concrete manifest (world A: one
    # document; world B: a spec list synthesized into one manifest), rendering
    # "{{parameter}}" against the invocation arguments. A function exiting
    # non-zero aborts the setup before anything is built.
    local rendered
    if ! _knit_env_resolve_manifest rendered "${nm}" "${cmd}" "$@"; then
        return 1
    fi
    printf '%s\n' "${rendered}" > "${manifest_path}"
    # Abort the setup if the environment did not install: do not activate a
    # broken environment.
    if ! "${!install_var}" "${env_dir}" "${manifest_path}"; then
        knit_error "Failed to build the %s environment at %s." "${display}" "${env_dir}"
        return 1
    fi
    # Activate in the setup's own shell so the body sees the environment. The
    # activate verb prints the lines; eval applies them here.
    eval "$("${!activate_var}" "${env_dir}")"
}

# ------------------------------------------------------------------------------
# @fn _knit_env_setup_after_cb()
#
# After-callback installed by _knit_env_with_env, registered AFTER the generic
# _knit_setup_after_cb so it runs last and its appended block is authoritative
# when a job sources .activate.sh. It (1) appends the activate verb's lines to
# .activate.sh so a dependent job re-enters the exact environment, and (2)
# records the concrete manifest and lockfile as provenance outputs, gzip+base64.
#
# The provenance is emitted with knit_output: after-callbacks run while the
# command is still on the executing-command stack, so knit_output resolves and
# type-checks the outputs normally.
#
# The manifest is captured from <nm>-env/<manifest> (the install-placed copy,
# like Spack's concretized spack.yaml) and falls back to the materialized
# ${KNIT_SETUP_PREFIX}/<manifest>; the lockfile from <nm>-env/<lockfile>.
#
# @param[in] nm Normalized (underscore) manager name. Trailing arguments are the
#            setup's runtime arguments and are ignored.
# ------------------------------------------------------------------------------
_knit_env_setup_after_cb() {
    local nm="$1"
    local activate_var="_KNIT_ENV_${nm}_activate"
    local manifest_var="_KNIT_ENV_${nm}_manifest"
    local manifest="${!manifest_var}"
    local lockfile_var="_KNIT_ENV_${nm}_lockfile"
    local lockfile="${!lockfile_var}"
    local env_dir="${KNIT_SETUP_PREFIX}/${nm}-env"
    local activate="${KNIT_SETUP_PREFIX}/.activate.sh"
    {
        printf '\n# %s environment re-activation (added by knit_with_%s_env)\n' \
            "${nm}" "${nm}"
        "${!activate_var}" "${env_dir}"
    } >> "${activate}"
    local manifest_src="${env_dir}/${manifest}"
    [[ -f "${manifest_src}" ]] || manifest_src="${KNIT_SETUP_PREFIX}/${manifest}"
    if [[ -f "${manifest_src}" ]]; then
        knit_output "__${nm}_manifest__" "$(gzip -c "${manifest_src}" | base64 -w0)"
    fi
    if [[ -f "${env_dir}/${lockfile}" ]]; then
        knit_output "__${nm}_lock__" "$(gzip -c "${env_dir}/${lockfile}" | base64 -w0)"
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_env_env_built()
#
# Return 0 when at least one setup instance has a built environment for the given
# manager, non-zero otherwise. A built environment is a "<nm>-env/<lockfile>"
# file under a setup instance directory (see _knit_env_setup_before_cb). Used by
# the update-mode freeze rule: once any environment has been concretized, the
# manager's version is frozen for reproducibility. A missing setup root reports
# "none built". (Generalizes what was Spack's own env-built check.)
#
# @param[in] name Manager name (any spelling).
# ------------------------------------------------------------------------------
_knit_env_env_built() {
    local nm
    _knit_name_normalize nm "$1"
    local lockfile_var="_KNIT_ENV_${nm}_lockfile"
    local lockfile="${!lockfile_var}"
    local root
    _knit_setup_root root
    [[ -d "${root}" ]] || return 1
    local entry
    for entry in "${root}"/*/; do
        [[ -f "${entry}${nm}-env/${lockfile}" ]] && return 0
    done
    return 1
}

# ------------------------------------------------------------------------------
# @fn _knit_env_update_one()
#
# Update-mode handler for one manager (the generalization of what was Spack's own
# update-mode handler).
# The manager's version anchors reproducibility, so it is frozen once an
# environment is built:
#
#   - Tool not provisioned yet: provision now when a ref was typed or the manager
#     is required (the first-bootstrap condition).
#   - Already provisioned and a typed ref differs from the stored ref:
#       * no environment built anywhere -> re-provision at the effective ref(s)
#         (a typed ref replaces its stored value; an untyped one keeps the stored
#         value, so changing one knob does not move another to latest);
#       * an environment is built -> fatal, for reproducibility.
#   - A typed ref equal to the stored ref, or no typed ref -> no-op.
#
# Typed-ness is read from the raw invocation arguments (an option's value, when
# typed, is present there); the stored value of each option <opt> is the metadata
# key __<opt>_ref__ (normalized), which the provision verb must write. The
# re-provision removes .knit/<name> first; a manager owning extra directories
# cleans them in its own provision verb.
#
# @param[in] nm       Normalized (underscore) manager name.
# @param[in] raw_name Name of the array holding the raw invocation arguments.
# @return 0 when the manager was provisioned or re-provisioned, 1 when nothing
#         changed.
# ------------------------------------------------------------------------------
_knit_env_update_one() {
    local nm="$1"
    # shellcheck disable=SC2178 # nameref to the caller's raw-args array
    local -n __knit_raw="$2"
    local display_var="_KNIT_ENV_${nm}_display"
    local display="${!display_var}"
    local root="${_KNIT_PREFIX}/${display}"
    local provision="_KNIT_ENV_${nm}_provision"

    local names=()
    _knit_env_option_names names "${nm}"
    local name

    # Not provisioned yet: provision now under the same condition as first
    # bootstrap (a typed ref, or a required manager).
    if [[ ! -d "${root}" ]]; then
        local refs=()
        for name in "${names[@]}"; do
            refs+=("$(knit_get_parameter "${name}" "${__knit_raw[@]}" || true)")
        done
        _knit_env_need_provision "${nm}" "${refs[@]}" || return 1
        knit_info "Bootstrapping %s..." "${display}"
        "${!provision}" "${refs[@]}"
        return 0
    fi

    # Already provisioned: only a typed ref that differs changes anything. Build
    # the effective ref list (typed-and-different overrides, else keep stored).
    local eff=() differs="false" keyname typed_val stored
    for name in "${names[@]}"; do
        _knit_name_normalize keyname "${name}"
        _knit_metadata_get stored "__${keyname}_ref__"
        if _knit_arg_was_provided "${name}" "${__knit_raw[@]}"; then
            typed_val="$(knit_get_parameter "${name}" "${__knit_raw[@]}" || true)"
            if [[ "${typed_val}" != "${stored}" ]]; then
                eff+=("${typed_val}")
                differs="true"
                continue
            fi
        fi
        eff+=("${stored}")
    done
    [[ "${differs}" == "false" ]] && return 1

    # A changed ref is refused once any setup has concretized an environment.
    if _knit_env_env_built "${nm}"; then
        knit_fatal "Cannot change the %s version: an environment is already built under a setup.\nThe version is frozen for reproducibility once an environment exists." \
            "${display}"
    fi

    knit_info "Re-provisioning %s..." "${display}"
    rm -rf "${root}"
    "${!provision}" "${eff[@]}"
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_env_update_all()
#
# Update-mode dispatcher: run _knit_env_update_one for every registered manager,
# in registration order. Called from the bootstrap update body. Returns 0 when
# any manager was provisioned or re-provisioned, 1 when none changed.
#
# @param[in] raw_name Name of the array holding the raw invocation arguments.
# ------------------------------------------------------------------------------
_knit_env_update_all() {
    local raw_name="$1"
    local nm changed=1
    for nm in "${_KNIT_ENV_MANAGERS[@]}"; do
        _knit_env_update_one "${nm}" "${raw_name}" && changed=0
    done
    return "${changed}"
}
