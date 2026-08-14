#!/bin/bash

## @file resource.sh

# ------------------------------------------------------------------------------
# @fn _knit_resource_root()
#
# Store the resolved resource root — the directory under which resource instances
# live — in the caller-named variable. Reads the verbatim __resource_path__ from
# the metadata table (falling back to "resources" when unset, for robustness) and
# resolves it against the experiment root via _knit_resolve_experiment_path.
# Mirrors _knit_setup_root / _knit_job_root.
#
# @param __knit_ret Name of the variable to hold the resolved resource root.
# ------------------------------------------------------------------------------
_knit_resource_root() {
    local -n __knit_ret=$1
    local stored
    _knit_metadata_get stored "__resource_path__"
    [[ -z "${stored}" ]] && stored="resources"
    local resolved
    _knit_resolve_experiment_path resolved "${stored}"
    __knit_ret="${resolved}"
}

# ------------------------------------------------------------------------------
# @fn knit_resource_path()
#
# Resolve a resource instance name into its absolute directory under the
# experiment's resource root: `<resource-root>/<name>` (see _knit_resource_root),
# and print it to stdout. This is how the body of a command that depends on a
# resource turns a resource parameter value (the instance name) into an on-disk
# path:
#
# ```
# train_dir="$(knit_resource_path "$(knit_get_parameter training_dataset "$@")")"
# ```
#
# The name is validated as a single path component first (fatal otherwise). Fatals
# when the named instance does not exist, since a body should never run against a
# resource that was never fetched. Called at most a handful of times per body (one
# per declared resource), so it returns via stdout rather than a nameref.
#
# @param name The resource instance name (as passed to `knit fetch --name`).
# ------------------------------------------------------------------------------
knit_resource_path() {
    local name="$1"
    _knit_validate_instance_name "${name}"
    local root
    _knit_resource_root root
    local path="${root}/${name}"
    if [[ ! -d "${path}" ]]; then
        knit_fatal "Resource \"${name}\" not found at \"${path}\". Fetch it first with: ./${KNIT_SCRIPT_NAME} fetch --name ${name} -- <resource-type> [args...]"
    fi
    printf '%s\n' "${path}"
}

# ------------------------------------------------------------------------------
# @var _KNIT_RESOURCES
#
# Associative array mapping registered resource type names to 1. Populated by
# knit_register_resource and consulted by the `knit fetch` dispatcher (to resolve
# a requested type) and by knit_with_resource (to validate a declared dependency's
# type). Declared global (-g) so it survives being sourced from within a function
# (as the bats tests do). Mirrors _KNIT_SETUPS.
# ------------------------------------------------------------------------------
declare -gA _KNIT_RESOURCES

# ------------------------------------------------------------------------------
# @fn _knit_resource_fetch_body()
#
# Shared body registered for every resource type (the function every
# `fetch:<type>` command runs). It dispatches on the type's declared download
# method to the matching backend. The download backends are implemented in a
# later milestone; for now this is a stub.
# ------------------------------------------------------------------------------
_knit_resource_fetch_body() {
    knit_fatal "Resource download is not yet implemented."
}

# ------------------------------------------------------------------------------
# @fn _knit_fetch()
#
# Body of the builtin `fetch` dispatcher command. It materializes a named resource
# instance under the resource root by dispatching to the requested resource type.
# The dispatcher logic is implemented in a later milestone; for now this is a stub.
# ------------------------------------------------------------------------------
_knit_fetch() {
    knit_fatal "knit fetch is not yet implemented."
}

# The `fetch` dispatcher: real invocation is `fetch --name <name> -- <type> [args]`,
# mirroring `knit setup`. Registering it here (at load time) means the `fetch`
# parent exists before any user knit_register_resource call, so a resource type's
# `fetch:<type>` command can nest under it.
knit_register "fetch" _knit_fetch "Fetch a resource instance"
_knit_is_builtin
knit_with_required "name:string" "Name for the resource instance"
knit_with_dispatch "resource" "User-provided resource type to fetch"
knit_with_subcommand_title "Resources"
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_command_is_resource()
#
# Test whether a command is a resource type, i.e. it was registered with
# knit_register_resource. Used by the resource declaration directives to reject
# use on any other kind of command.
#
# @param cmd Command (mangled name) to test.
# @return 0 if the command is a resource type, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_command_is_resource() {
    local var="_KNIT_CMD_${1}_is_resource"
    [[ "${!var:-}" == "true" ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_resource_require_registration()
#
# Fatal unless a resource type is currently being registered (i.e. this is called
# between knit_register_resource and knit_done). Shared by the download decorators
# and knit_with_checksum, which are valid only on a resource type.
#
# @param directive Name of the calling directive (for the error message).
# ------------------------------------------------------------------------------
_knit_resource_require_registration() {
    local directive="$1"
    if [[ ! -v _KNIT_CURRENT_COMMAND ]] \
    || ! _knit_command_is_resource "${_KNIT_CURRENT_COMMAND}"; then
        knit_fatal "${directive} is valid only for resources; it must be called between knit_register_resource and knit_done."
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_resource_set_method()
#
# Record the download method chosen by a download decorator in the current
# resource type's per-command marker (_KNIT_CMD_<cmd>_fetch_method), enforcing the
# "exactly one download decorator per resource type" rule: a second call (whether
# the same decorator twice or two different backends) is fatal. Mirrors the
# _KNIT_CMD_<cmd>_spack_env at-most-once marker pattern.
#
# @param method The backend name ("git", "url", or "local").
# ------------------------------------------------------------------------------
_knit_resource_set_method() {
    local method="$1"
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local marker_var="_KNIT_CMD_${cmd}_fetch_method"
    if [[ -n "${!marker_var:-}" ]]; then
        knit_fatal "A resource type may declare at most one download method (knit_with_git / knit_with_url / knit_with_local); \"${_KNIT_CURRENT_COMMAND_DEMANGLED}\" already declares \"${!marker_var}\"."
    fi
    printf -v "${marker_var}" '%s' "${method}"
}

# ------------------------------------------------------------------------------
# @fn _knit_resource_check_method()
#
# Done callback installed by knit_register_resource. Fatal if the resource type
# completed registration without declaring a download method, so a type must
# declare exactly one of knit_with_git / knit_with_url / knit_with_local.
#
# @param cmd The resource type's command (mangled name).
# ------------------------------------------------------------------------------
_knit_resource_check_method() {
    local cmd="$1"
    local marker_var="_KNIT_CMD_${cmd}_fetch_method"
    if [[ -z "${!marker_var:-}" ]]; then
        local demangled
        demangled=$(_knit_command_demangle "${cmd}")
        knit_fatal "Resource \"${demangled}\" declares no download method; add one of knit_with_git / knit_with_url / knit_with_local."
    fi
}

# ------------------------------------------------------------------------------
# @fn knit_register_resource()
#
# Register a resource type: a downloadable input artifact acquired through the
# `knit fetch` dispatcher. Unlike knit_register_setup there is no user body to
# supply — the type is backed by the shared _knit_resource_fetch_body, which
# dispatches on the declared download method. The type is backed by a database
# table named "resource:<type>" (via knit_with_table) and recorded in the resource
# registry so knit_with_resource can validate a declared dependency.
#
# A call to this function must be followed by exactly one download decorator
# (knit_with_git / knit_with_url / knit_with_local), an optional knit_with_checksum,
# and a call to knit_done. It must run before any knit_with_resource that
# references the type.
#
# @param type        Short name for the resource type (used as the dispatch target).
# @param description One-line description shown in `--help`.
#
# Example:
# ```
# knit_register_resource "julia_code" "Julia fractal source."
# knit_with_git "https://github.com/knit-sh/julia-fractal-example.git" "main"
# knit_done
# ```
# ------------------------------------------------------------------------------
knit_register_resource() {
    local type="$1"
    local description="$2"
    if ! _knit_name_is_valid "${type}"; then
        knit_fatal "Resource type \"${type}\" is not a valid name."
    fi
    knit_register "fetch:${type}" _knit_resource_fetch_body "${description}"
    local cmd="${_KNIT_CURRENT_COMMAND}"
    printf -v "_KNIT_CMD_${cmd}_is_resource" '%s' 'true'
    knit_with_table "resource:${type}"
    _KNIT_RESOURCES["${type}"]=1
    # Push the method check last so it runs first at knit_done (done callbacks run
    # in reverse order of installation): a type that declared no download method
    # then fatals before the table is set up.
    _knit_push_done_cb _knit_resource_check_method "${cmd}"
}

# ------------------------------------------------------------------------------
# @fn knit_with_git()
#
# Download decorator: acquire the resource type by cloning a git repository and
# checking out a ref. Declares the automatic parameters --url (default <url>) and
# --ref (default <ref>); both arguments are required at registration because a
# resource type must name the ref it pins. Valid only on a resource type, at most
# one download decorator per type.
#
# @param url The default git repository URL.
# @param ref The default git ref (branch, tag, or commit) to check out.
# ------------------------------------------------------------------------------
knit_with_git() {
    _knit_resource_require_registration "knit_with_git"
    local url="$1"
    local ref="$2"
    if [[ -z "${url}" ]]; then
        knit_fatal "knit_with_git requires a repository URL."
    fi
    if [[ -z "${ref}" ]]; then
        knit_fatal "knit_with_git requires a git ref (branch, tag, or commit)."
    fi
    _knit_resource_set_method "git"
    knit_with_optional "url:string" "${url}" "Git repository URL to clone."
    knit_with_optional "ref:string" "${ref}" "Git ref (branch, tag, or commit) to check out."
}

# ------------------------------------------------------------------------------
# @fn knit_with_url()
#
# Download decorator: acquire the resource type by downloading a URL with curl.
# Declares the automatic parameters --url (default <url>) and the --uncompress
# flag (unpack the archive after download). Valid only on a resource type, at most
# one download decorator per type.
#
# @param url The default URL of the artifact to download.
# ------------------------------------------------------------------------------
knit_with_url() {
    _knit_resource_require_registration "knit_with_url"
    local url="$1"
    if [[ -z "${url}" ]]; then
        knit_fatal "knit_with_url requires a URL."
    fi
    _knit_resource_set_method "url"
    knit_with_optional "url:string" "${url}" "URL of the artifact to download."
    knit_with_flag "uncompress" "Unpack the downloaded archive after download."
}

# ------------------------------------------------------------------------------
# @fn knit_with_local()
#
# Download decorator: acquire the resource type from a local path, by default as a
# symlink (so a large staged dataset is not duplicated) or, with --copy, as a
# self-contained read-only snapshot. Declares the automatic parameters --path
# (default <path>) and the --copy flag. Valid only on a resource type, at most one
# download decorator per type.
#
# @param path The default local source path to link or copy.
# ------------------------------------------------------------------------------
knit_with_local() {
    _knit_resource_require_registration "knit_with_local"
    local path="$1"
    if [[ -z "${path}" ]]; then
        knit_fatal "knit_with_local requires a source path."
    fi
    _knit_resource_set_method "local"
    knit_with_optional "path:string" "${path}" "Local source path to link or copy."
    knit_with_flag "copy" "Copy the source into a read-only snapshot instead of symlinking it."
}

# ------------------------------------------------------------------------------
# @fn knit_with_checksum()
#
# Declare an optional integrity pin for the resource type: a sha256 verified at
# fetch time, but only when the source defaults are used (an overridden source
# would legitimately hash differently) and not bypassed with --ignore-checksum.
# Valid only on a resource type, at most once. The verification itself is
# implemented in a later milestone; this records the pin.
#
# @param sha256 The expected sha256 (a commit SHA for the git backend).
# ------------------------------------------------------------------------------
knit_with_checksum() {
    _knit_resource_require_registration "knit_with_checksum"
    local sha256="$1"
    if [[ -z "${sha256}" ]]; then
        knit_fatal "knit_with_checksum requires a sha256 value."
    fi
    local cmd="${_KNIT_CURRENT_COMMAND}"
    local marker_var="_KNIT_CMD_${cmd}_checksum"
    if [[ -n "${!marker_var:-}" ]]; then
        knit_fatal "knit_with_checksum may be called at most once per resource."
    fi
    printf -v "${marker_var}" '%s' "${sha256}"
}
