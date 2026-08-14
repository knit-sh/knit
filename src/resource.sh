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
# @fn _knit_resource_make_readonly()
#
# Make a fetched instance tree read-only so consumers cannot mutate a shared
# input: `chmod -R a-w` clears the write bit for everyone while preserving the
# existing read and execute bits. Applied by the git and url backends and by the
# local backend's --copy path; a symlinked local instance is deliberately left
# alone (its target stays owned and writable by whoever staged it).
#
# @param dir Path to the instance tree (or file) to make read-only.
# ------------------------------------------------------------------------------
_knit_resource_make_readonly() {
    local dir="$1"
    chmod -R a-w "${dir}"
}

# ------------------------------------------------------------------------------
# @fn _knit_resource_cleanup_dir()
#
# Remove a partial or failed instance at <dir>, restoring write permission first
# so a read-only tree (see _knit_resource_make_readonly) can be deleted. A symlink
# instance is unlinked without touching its target. A no-op when <dir> is empty or
# does not exist, so it is safe to call unconditionally on any failure path.
#
# @param dir Path to the instance to remove.
# ------------------------------------------------------------------------------
_knit_resource_cleanup_dir() {
    local dir="$1"
    [[ -z "${dir}" ]] && return 0
    # A symlink instance: remove only the link, never follow it into the target.
    if [[ -L "${dir}" ]]; then
        rm -f "${dir}"
        return 0
    fi
    [[ -e "${dir}" ]] || return 0
    # Restore write so a read-only tree's own files and subdirectories can be
    # removed, then delete it.
    chmod -R u+w "${dir}" 2>/dev/null || true
    rm -rf "${dir}"
}

# ------------------------------------------------------------------------------
# @fn _knit_resource_source_identity()
#
# Build the source-identity string for a fetch and store it in the caller-named
# variable. The identity is the tuple that identifies where an instance came from,
# recorded on its row and compared on a same-name re-fetch to distinguish an
# idempotent skip (identical source) from a conflicting re-fetch (same name, a
# different source). It is derived from the backend method and the resolved
# parameters, per backend:
#   - git:   the repository url and the requested ref
#   - url:   the url and the uncompress flag
#   - local: the source path and the copy flag
# The commit a git ref resolves to is deliberately not part of the identity: a
# mutable ref (e.g. main) still identifies the same source between fetches.
#
# @param __knit_ret Name of the variable to hold the identity string.
# @param method     The backend method ("git", "url", or "local").
# @param ...        The fetch's arguments (read via knit_get_parameter).
# ------------------------------------------------------------------------------
_knit_resource_source_identity() {
    local -n __knit_ret=$1; shift
    local method="$1"; shift
    case "${method}" in
        git)
            local url ref
            url=$(knit_get_parameter "url" "$@") || url=""
            ref=$(knit_get_parameter "ref" "$@") || ref=""
            __knit_ret="git|url=${url}|ref=${ref}"
            ;;
        url)
            local url uncompress
            url=$(knit_get_parameter "url" "$@") || url=""
            uncompress=$(knit_get_parameter "uncompress" "$@") || uncompress="false"
            __knit_ret="url|url=${url}|uncompress=${uncompress}"
            ;;
        local)
            local path copy
            path=$(knit_get_parameter "path" "$@") || path=""
            copy=$(knit_get_parameter "copy" "$@") || copy="false"
            __knit_ret="local|path=${path}|copy=${copy}"
            ;;
        *)
            __knit_ret=""
            return 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_resource_sha256()
#
# Compute the sha256 of a fetched artifact and store the 64-hex digest (with no
# trailing filename) in the caller-named variable. A regular file is hashed
# directly. A directory is hashed recursively into one digest: every regular file
# under it is hashed together with its relative path (sha256sum prints
# "<hash>  <path>"), the lines are sorted for a stable order independent of
# readdir order, and the aggregate is hashed again — so both the tree structure
# and every file's content contribute. A symlink is followed (so a `local`
# symlink instance hashes its target). Returns non-zero (with a knit_error) when
# sha256sum is unavailable or a step fails.
#
# @param __knit_ret Name of the variable to hold the digest.
# @param path       Path to the file or directory to hash.
# ------------------------------------------------------------------------------
_knit_resource_sha256() {
    local -n __knit_ret=$1
    local path="$2"
    if ! command -v sha256sum >/dev/null 2>&1; then
        knit_error "sha256sum is required for checksum verification but was not found on PATH."
        return 1
    fi
    local out
    if [[ -d "${path}" ]]; then
        out=$( cd "${path}" && find . -type f -print0 | LC_ALL=C sort -z \
               | xargs -0 sha256sum | sha256sum ) || return 1
    else
        out=$(sha256sum "${path}") || return 1
    fi
    __knit_ret="${out%% *}"
}

# ------------------------------------------------------------------------------
# @fn _knit_resource_check_sha()
#
# Compare a computed digest against an expected knit_with_checksum pin, case-
# insensitively (sha256 hex is case-independent). On a mismatch it prints a
# knit_error naming what failed and returns 1, so the caller aborts the fetch and
# removes the partial instance; on a match it returns 0.
#
# @param expected The expected value (the knit_with_checksum pin).
# @param actual   The computed value.
# @param what     Short label for the artifact (for the error message).
# ------------------------------------------------------------------------------
_knit_resource_check_sha() {
    local expected="$1"
    local actual="$2"
    local what="$3"
    if [[ "${expected,,}" != "${actual,,}" ]]; then
        knit_error "Checksum mismatch for ${what}: expected \"${expected}\", got \"${actual}\"."
        return 1
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_resource_defaults_used()
#
# Test whether a fetch still uses the resource type's declared source defaults, so
# a knit_with_checksum pin still applies. The pin is authored against the default
# source; if the user overrides the source the artifact would legitimately hash
# differently, so the pin no longer holds. For each source-defining parameter of
# the backend (git: url + ref; url: url; local: path) it compares the effective
# value against the declared default; it returns 0 when every one matches
# (defaults in use), 1 otherwise. The uncompress/copy flags are not compared: they
# do not change the archive/file content the pin covers.
#
# @param cmd    The resource type's command (mangled name).
# @param method The backend method ("git", "url", or "local").
# @param ...    The fetch's expanded arguments (read via knit_get_parameter).
# ------------------------------------------------------------------------------
_knit_resource_defaults_used() {
    local cmd="$1"; shift
    local method="$1"; shift
    local -a params=()
    case "${method}" in
        git)   params=("url" "ref") ;;
        url)   params=("url") ;;
        local) params=("path") ;;
        *)     return 1 ;;
    esac
    local p val def
    for p in "${params[@]}"; do
        val=$(knit_get_parameter "${p}" "$@") || val=""
        _knit_param_default def "${cmd}" "${p}"
        [[ "${val}" == "${def}" ]] || return 1
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_fetch_git()
#
# Git backend: clone <url> into <dest>, check out <ref>, and print the resolved
# commit SHA (`git rev-parse HEAD`) to stdout so a mutable ref is pinned to the
# commit actually obtained. The clone and checkout write their progress to stderr
# (redirected here so stdout carries only the SHA), and the resulting tree is made
# read-only. Returns non-zero (leaving cleanup to the caller) if git is missing or
# any step fails.
#
# @param dest Directory to create and clone into (must not already exist).
# @param url  Repository URL to clone.
# @param ref  Ref (branch, tag, or commit) to check out.
# ------------------------------------------------------------------------------
_knit_fetch_git() {
    local dest="$1"
    local url="$2"
    local ref="$3"
    if ! command -v git >/dev/null 2>&1; then
        knit_error "git is required to fetch this resource but was not found on PATH."
        return 1
    fi
    git clone "${url}" "${dest}" 1>&2 || return 1
    git -C "${dest}" checkout --quiet "${ref}" 1>&2 || return 1
    local sha
    sha=$(git -C "${dest}" rev-parse HEAD) || return 1
    _knit_resource_make_readonly "${dest}"
    printf '%s\n' "${sha}"
}

# ------------------------------------------------------------------------------
# @fn _knit_fetch_url()
#
# URL backend: download <url> with curl into <dest>, optionally unpacking it. The
# artifact is saved under its URL basename; when <uncompress> is "true" it is
# extracted with `tar -xf` (auto-detecting gzip/bzip2/xz) and the archive is then
# removed, so the instance holds the unpacked tree. curl uses -f so an HTTP error
# fails the fetch. When <expected> is a non-empty knit_with_checksum pin the
# downloaded archive's sha256 is checked against it (before it is unpacked or
# removed) and a mismatch fails the fetch. The resulting instance is made
# read-only. Returns non-zero (leaving cleanup to the caller) on any failed step.
#
# @param dest       Directory to create and download into (must not already exist).
# @param url        URL of the artifact to download.
# @param uncompress "true" to unpack the downloaded archive, "false" to keep it.
# @param expected   Expected archive sha256 to verify, or "" to skip verification.
# ------------------------------------------------------------------------------
_knit_fetch_url() {
    local dest="$1"
    local url="$2"
    local uncompress="$3"
    local expected="$4"
    mkdir -p "${dest}" || return 1
    # Name the download after the URL's basename, ignoring any query string; fall
    # back to a generic name when the URL has no usable last component.
    local fname="${url%%\?*}"
    fname="${fname##*/}"
    [[ -z "${fname}" ]] && fname="download"
    local archive="${dest}/${fname}"
    curl -fL -o "${archive}" "${url}" 1>&2 || return 1
    # Verify the archive against the pin before unpacking or removing it.
    if [[ -n "${expected}" ]]; then
        local actual
        _knit_resource_sha256 actual "${archive}" || return 1
        _knit_resource_check_sha "${expected}" "${actual}" "url archive" || return 1
    fi
    if [[ "${uncompress}" == "true" ]]; then
        tar -xf "${archive}" -C "${dest}" 1>&2 || return 1
        rm -f "${archive}"
    fi
    _knit_resource_make_readonly "${dest}"
}

# ------------------------------------------------------------------------------
# @fn _knit_fetch_local()
#
# Local backend: materialize <dest> from a local source <src>. By default <dest>
# is a symlink to <src> (so a large already-staged dataset is not duplicated), left
# writable through its target. With <copy> = "true" the source is copied into a
# self-contained snapshot which is then made read-only. The source path is resolved
# to an absolute path first, so a symlink instance does not depend on the caller's
# working directory. When <expected> is a non-empty knit_with_checksum pin the
# instance's sha256 (of the file, or a recursive digest of a directory) is checked
# against it and a mismatch fails the fetch. Returns non-zero (leaving cleanup to
# the caller) if the source is missing or a step fails.
#
# @param dest     Path to create for the instance (must not already exist).
# @param src      Local source path (file or directory) to link or copy.
# @param copy     "true" to copy a read-only snapshot, "false" to symlink the source.
# @param expected Expected sha256 to verify, or "" to skip verification.
# ------------------------------------------------------------------------------
_knit_fetch_local() {
    local dest="$1"
    local src="$2"
    local copy="$3"
    local expected="$4"
    if [[ ! -e "${src}" ]]; then
        knit_error "Local source \"${src}\" does not exist."
        return 1
    fi
    src="$(realpath "${src}")" || return 1
    if [[ "${copy}" == "true" ]]; then
        cp -R "${src}" "${dest}" || return 1
        _knit_resource_make_readonly "${dest}"
    else
        ln -s "${src}" "${dest}" || return 1
    fi
    # Verify the materialized instance against the pin (a symlink is followed to
    # its target).
    if [[ -n "${expected}" ]]; then
        local actual
        _knit_resource_sha256 actual "${dest}" || return 1
        _knit_resource_check_sha "${expected}" "${actual}" "local source" || return 1
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_resource_fetch_body()
#
# Shared body registered for every resource type (the function every
# `fetch:<type>` command runs). It reads the type's declared download method from
# the per-command marker (_KNIT_CMD_<cmd>_fetch_method) and dispatches to the
# matching backend, materializing the instance at KNIT_RESOURCE_PREFIX (the target
# path the `knit fetch` dispatcher exports; it must not already exist, since each
# backend creates it). The git backend's resolved commit SHA is recorded as the
# "commit" output. On any backend failure the partial instance is removed and the
# body returns non-zero so the dispatcher aborts without recording a row.
#
# When the type declares knit_with_checksum and the pin still applies (the source
# defaults are unchanged), the dispatcher exports it as KNIT_RESOURCE_EXPECTED_-
# CHECKSUM; the body verifies it — the git commit SHA directly, and the url/local
# artifacts through their backends — unless the fetch bypassed it with
# --ignore-checksum (KNIT_IGNORE_CHECKSUM). A mismatch fails the fetch.
# ------------------------------------------------------------------------------
_knit_resource_fetch_body() {
    if [[ -z "${KNIT_RESOURCE_PREFIX:-}" ]]; then
        knit_fatal "Resource fetch commands must be invoked via \"knit fetch [OPTIONS] -- <resource> [OPTIONS]\", not directly."
    fi
    local dest="${KNIT_RESOURCE_PREFIX}"
    local cmd="${_KNIT_EXECUTING_COMMAND[-1]}"
    local method_var="_KNIT_CMD_${cmd}_fetch_method"
    local method="${!method_var:-}"

    # The knit_with_checksum pin to verify (empty = skip). The dispatcher exports
    # it only when it still applies; --ignore-checksum bypasses it here.
    local expected=""
    if [[ "${KNIT_IGNORE_CHECKSUM:-false}" != "true" ]]; then
        expected="${KNIT_RESOURCE_EXPECTED_CHECKSUM:-}"
    fi

    local ret=0
    case "${method}" in
        git)
            local url ref sha
            url=$(knit_get_parameter "url" "$@") || url=""
            ref=$(knit_get_parameter "ref" "$@") || ref=""
            if sha=$(_knit_fetch_git "${dest}" "${url}" "${ref}"); then
                knit_output "commit" "${sha}"
                # git's pin is the expected commit SHA the default ref resolves to.
                if [[ -n "${expected}" ]]; then
                    _knit_resource_check_sha "${expected}" "${sha}" "git commit" || ret=1
                fi
            else
                ret=1
            fi
            ;;
        url)
            local url uncompress
            url=$(knit_get_parameter "url" "$@") || url=""
            uncompress=$(knit_get_parameter "uncompress" "$@") || uncompress="false"
            _knit_fetch_url "${dest}" "${url}" "${uncompress}" "${expected}" || ret=1
            ;;
        local)
            local path copy
            path=$(knit_get_parameter "path" "$@") || path=""
            copy=$(knit_get_parameter "copy" "$@") || copy="false"
            _knit_fetch_local "${dest}" "${path}" "${copy}" "${expected}" || ret=1
            ;;
        *)
            knit_fatal "Resource \"$(_knit_command_demangle "${cmd}")\" has no download method."
            ;;
    esac

    if [[ "${ret}" -ne 0 ]]; then
        _knit_resource_cleanup_dir "${dest}"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_fetch()
#
# Body of the builtin `fetch` dispatcher command. It materializes a named resource
# instance at `<resource-root>/<name>` by dispatching to the requested resource
# type, mirroring `knit setup`:
#
# ```
# ./exp.sh fetch --name <name> [--ignore-checksum] -- <resource-type> [args...]
# ```
#
# The instance name is validated as a single path component and the type must be a
# registered resource type. Fetching is idempotent by name and serialized on a
# per-name lock under .knit: if the instance already exists with a matching source
# identity the fetch is a no-op that just reprints the path; if it exists with a
# different source it is fatal (remove it to re-fetch); otherwise the download body
# runs, the instance is recorded, and its type / source identity / row id are
# written to sidecar markers beside it. The resolved instance path is printed to
# stdout (all logging is on stderr). On a failed download the partial instance is
# removed and no row survives. When the type declares knit_with_checksum and the
# pin still applies (the source defaults are unchanged), it is exported as
# KNIT_RESOURCE_EXPECTED_CHECKSUM for the body to verify; `--ignore-checksum`
# (exported as KNIT_IGNORE_CHECKSUM) bypasses that verification.
# ------------------------------------------------------------------------------
_knit_fetch() {
    local name
    name=$(knit_get_parameter "name" "$@")
    local ignore_checksum
    ignore_checksum=$(knit_get_parameter "ignore-checksum" "$@") || ignore_checksum="false"

    # Extract the resource type and its arguments (everything after --).
    local args=("$@")
    local extra_index
    extra_index=$(knit_extra_index "${args[@]}")
    local extra=("${args[@]:extra_index}")
    if [[ ${#extra[@]} -eq 0 ]]; then
        knit_fatal "fetch requires a resource type (pass it after --)."
    fi
    local type="${extra[0]}"
    local resource_args=("${extra[@]:1}")

    # Validate the instance name (a single path component).
    _knit_validate_instance_name "${name}"

    # The type must be a registered resource type.
    if [[ ! -v _KNIT_RESOURCES["${type}"] ]]; then
        knit_fatal "Unknown resource type \"${type}\"."
    fi

    local subcmd
    subcmd=$(_knit_command_mangle "fetch:${type}")

    # Usability pre-check (login side): fail fast before touching the filesystem if
    # the resource type declares knit_usable_if predicates that do not hold.
    local usable_reason=""
    if ! _knit_command_check_usable usable_reason "${subcmd}"; then
        knit_fatal "Command \"fetch:${type}\" cannot run: ${usable_reason}"
    fi

    # Validate the resource type's own arguments (fatal on bad args).
    _knit_check_command_arguments "${subcmd}" "${resource_args[@]}"

    # Compute this fetch's source identity from the fully-expanded arguments (so
    # defaults are filled in), to compare against a prior fetch of the same name.
    local -a expanded
    readarray -d '' -t expanded \
        < <(_knit_expand_command_arguments "${subcmd}" "${resource_args[@]}")
    local method_var="_KNIT_CMD_${subcmd}_fetch_method"
    local method="${!method_var}"
    local identity
    _knit_resource_source_identity identity "${method}" "${expanded[@]}"

    # Decide whether a knit_with_checksum pin still applies to this fetch: only
    # when the type declares one and the source parameters hold their declared
    # defaults (an overridden source would legitimately hash differently). The
    # download body honors the --ignore-checksum bypass. An empty value means no
    # verification.
    local checksum_var="_KNIT_CMD_${subcmd}_checksum"
    local pin="${!checksum_var:-}"
    local expected_checksum=""
    if [[ -n "${pin}" ]] \
    && _knit_resource_defaults_used "${subcmd}" "${method}" "${expanded[@]}"; then
        expected_checksum="${pin}"
    fi

    # Resolve the instance directory and its sidecar markers under the resource
    # root (markers are siblings of the instance, since the instance is made
    # read-only and a symlinked local instance has no inside to write into).
    local root
    _knit_resource_root root
    local path="${root}/${name}"
    local type_marker="${root}/.${name}.resource.type"
    local id_marker="${root}/.${name}.resource.id"
    local source_marker="${root}/.${name}.resource.source"

    # Serialize concurrent fetches of the same name on a per-name lock under .knit,
    # so the first fetch downloads and records while the rest fall through to the
    # idempotent-skip path. A brace group (not a subshell) holds the lock fd for
    # the critical section, so a knit_fatal inside still terminates the process and
    # releases the lock as the fd closes on exit.
    local lock="${_KNIT_PREFIX}/fetch-${name}.lock"
    {
        flock 8 || knit_fatal "Could not acquire fetch lock \"${lock}\"."

        # Already present: idempotent-skip on a matching source, fatal on a conflict.
        if [[ -e "${path}" || -L "${path}" ]]; then
            local recorded_type="" recorded_source=""
            if [[ -f "${type_marker}" ]]; then
                IFS= read -r recorded_type < "${type_marker}" || recorded_type=""
            fi
            if [[ -f "${source_marker}" ]]; then
                IFS= read -r recorded_source < "${source_marker}" || recorded_source=""
            fi
            if [[ "${recorded_type}" == "${type}" && "${recorded_source}" == "${identity}" ]]; then
                printf '%s\n' "${path}"
                return 0
            fi
            knit_fatal "Resource \"${name}\" already exists at \"${path}\" with a different source; remove it to re-fetch."
        fi

        # Fresh fetch: the backend creates <path>, so only its parent must exist.
        mkdir -p "${root}"
        export KNIT_RESOURCE_PREFIX="${path}"
        export KNIT_IGNORE_CHECKSUM="${ignore_checksum}"
        export KNIT_RESOURCE_EXPECTED_CHECKSUM="${expected_checksum}"

        # Run the resource type's download body. Clear the last-recorded row id so
        # we only pick up an id the body itself recorded (empty when not
        # bootstrapped, though fetch requires bootstrap to reach here).
        local ret=0
        _KNIT_LAST_ROW_ID=""
        _knit_invoke_command "fetch" "${type}" "${resource_args[@]}" || ret=$?
        local body_row_id="${_KNIT_LAST_ROW_ID}"

        if [[ "${ret}" -ne 0 ]]; then
            _knit_resource_cleanup_dir "${path}"
            knit_fatal "Fetch of resource \"${name}\" failed; removed \"${path}\"."
        fi

        # Record the instance's type and source identity beside it so a later
        # knit_with_resource can validate the type and a re-fetch can detect a
        # conflicting source, both without a database read.
        printf '%s\n' "${type}" > "${type_marker}"
        printf '%s\n' "${identity}" > "${source_marker}"

        # When the body recorded a row (bootstrapped), keep its id in a sidecar (for
        # the used_by edge) and complete the row with the instance name and directory.
        if [[ -n "${body_row_id}" ]]; then
            printf '%s\n' "${body_row_id}" > "${id_marker}"
            _knit_db_update_row "resource:${type}" "${body_row_id}" \
                "name=${name}" "directory=${path}"
        fi

        printf '%s\n' "${path}"
    } 8>"${lock}"
}

# The `fetch` dispatcher: real invocation is `fetch --name <name> -- <type> [args]`,
# mirroring `knit setup`. Registering it here (at load time) means the `fetch`
# parent exists before any user knit_register_resource call, so a resource type's
# `fetch:<type>` command can nest under it.
knit_register "fetch" _knit_fetch "Fetch a resource instance"
_knit_is_builtin
knit_with_required "name:string" "Name for the resource instance"
knit_with_flag "ignore-checksum" "Skip knit_with_checksum verification for this fetch."
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
    # A failed fetch (bad download or a checksum mismatch) records no data row: the
    # dispatcher removes the partial instance, so a row would dangle.
    printf -v "_KNIT_CMD_${cmd}_no_record_on_failure" '%s' 'true'
    knit_with_table "resource:${type}"
    # Every instance records its name and on-disk directory (filled by the `knit
    # fetch` dispatcher after the download body runs), so the row identifies the
    # instance without reconstructing the path from the name.
    knit_with_output "name:string" "" "The resource instance name (from knit fetch --name)."
    knit_with_output "directory:string" "" "The instance's on-disk directory."
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
# resource type must name the ref it pins. Also declares the "commit" output, in
# which the fetch records the commit SHA the ref resolved to. Valid only on a
# resource type, at most one download decorator per type.
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
    knit_with_output "commit:string" "" \
        "The commit SHA the ref resolved to at fetch time (git rev-parse HEAD)."
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
# Valid only on a resource type, at most once. The pin is the sha256 of the
# downloaded archive (url), the sha256 of the local file or a recursive digest of
# a local directory (local), or the expected commit SHA the default ref resolves
# to (git). A mismatch fails the fetch and removes the partial instance.
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

# ------------------------------------------------------------------------------
# @fn _knit_resource_dep_before_cb()
#
# Before-callback installed by knit_with_resource on the consuming command, one
# per declared resource parameter. Before the command body runs it validates that
# the resource named by the parameter has been fetched and is of the required
# type, using only the on-disk sidecar markers (no database read):
#   - the parameter value (the instance name) missing → fatal;
#   - `<resource-root>/<name>` absent → fatal, printing the `knit fetch` command
#     to run;
#   - the `.<name>.resource.type` sidecar marker absent or not equal to the
#     declared type → fatal type-mismatch.
# The instance name is also validated as a single path component. Returning
# normally lets the command proceed; a fatal aborts it before the body runs.
#
# The declared parameter name and required type are bound at registration time
# and carried as the first two arguments; the trailing arguments are the
# command's own runtime arguments, scanned for the parameter value.
#
# @param param Normalized name of the resource parameter to read.
# @param type  Resource type the named instance must have been fetched as.
# ------------------------------------------------------------------------------
_knit_resource_dep_before_cb() {
    local param="$1"
    local type="$2"
    shift 2
    local name
    name=$(knit_get_parameter "${param}" "$@") || name=""
    if [[ -z "${name}" ]]; then
        local opt
        _knit_str_underscores_to_hyphens opt "${param}"
        knit_fatal "This command requires a resource of type \"${type}\" (parameter --${opt})."
    fi
    _knit_validate_instance_name "${name}"

    local root
    _knit_resource_root root
    local path="${root}/${name}"
    if [[ ! -e "${path}" && ! -L "${path}" ]]; then
        knit_fatal "Resource \"${name}\" (type \"${type}\") is not fetched. Fetch it first with: ./${KNIT_SCRIPT_NAME} fetch --name ${name} -- ${type} [args...]"
    fi

    local type_marker="${root}/.${name}.resource.type"
    local actual=""
    if [[ -f "${type_marker}" ]]; then
        IFS= read -r actual < "${type_marker}" || actual=""
    fi
    if [[ "${actual}" != "${type}" ]]; then
        knit_fatal "Resource \"${name}\" is of type \"${actual:-<unknown>}\", but a \"${type}\" resource is required."
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_resource_record_used_by_edge()
#
# Record a "used_by" provenance edge from a fetched resource instance to a
# consuming invocation. The edge's source is the instance (its row id read from
# the .<name>.resource.id sidecar, its node name "resource:<type>" from the
# .<name>.resource.type sidecar); its target is the consumer. Delegates the gated
# write to _knit_record_used_by_edge, so it records nothing when recording is
# disabled, on a suppressed rank, before bootstrap, when the target does not
# participate in the graph, or when the sidecar has no id (e.g. an instance
# fetched before provenance shipped).
#
# @param name        Resource instance name (as passed to `knit fetch --name`).
# @param target_cmd  Mangled command name of the consumer (the edge target).
# @param target_id   Resolved row id of the consumer (the edge target).
# ------------------------------------------------------------------------------
_knit_resource_record_used_by_edge() {
    local name="$1"
    local target_cmd="$2"
    local target_id="$3"
    local root
    _knit_resource_root root
    local id_file="${root}/.${name}.resource.id"
    [[ -f "${id_file}" ]] || return 0
    local resource_id=""
    IFS= read -r resource_id < "${id_file}" || resource_id=""
    local resource_type=""
    IFS= read -r resource_type < "${root}/.${name}.resource.type" 2>/dev/null || resource_type=""
    _knit_record_used_by_edge "${resource_id}" "resource:${resource_type}" \
        "${target_cmd}" "${target_id}"
}

# ------------------------------------------------------------------------------
# @fn _knit_resource_dep_after_cb()
#
# After-callback installed by knit_with_resource on the consuming command, one per
# declared resource parameter. It records a "used_by" edge from the fetched
# resource instance the command depends on to the command itself. It runs as an
# after-callback (not the before-callback that validates the instance) because the
# consumer's frame is on the executing stacks only from push time onward, so the
# consumer's resolved row id — the edge target — is available here but not in the
# before-callback (this mirrors _knit_setup_dep_after_cb).
#
# The declared parameter name and required type are bound at registration time and
# carried as the first two arguments; the trailing arguments are the command's own
# runtime arguments, scanned for the instance name. A missing name is silently
# skipped: the before-callback already fataled on it, so this is only reached with
# a valid instance.
#
# @param param Normalized name of the resource parameter to read.
# @param type  Resource type of the named instance (unused; kept for symmetry with
#              the before-callback's bound arguments).
# ------------------------------------------------------------------------------
_knit_resource_dep_after_cb() {
    local param="$1"
    shift 2
    local name
    name=$(knit_get_parameter "${param}" "$@") || name=""
    [[ -z "${name}" ]] && return 0
    [[ ${#_KNIT_EXECUTING_COMMAND[@]} -gt 0 ]] || return 0
    _knit_resource_record_used_by_edge "${name}" \
        "${_KNIT_EXECUTING_COMMAND[-1]}" "${_KNIT_EXECUTING_ROW_ID[-1]}"
}

# ------------------------------------------------------------------------------
# @fn knit_with_resource()
#
# Declare that the command currently being registered consumes a fetched resource
# instance, given as `"<param>:<type>"` (e.g. "training_dataset:image_dataset").
# Must be called between a knit_register* call and knit_done; a command may
# declare several resources. The `<type>` must be a resource type registered with
# knit_register_resource before this call.
#
# Under the hood this registers an ordinary required string parameter named
# `<param>` (so the CLI, knit_get_parameter, and the backing table all treat it
# as a plain value) whose value is the resource instance *name*. The command body
# turns that name into a path with knit_resource_path. A per-parameter marker
# (_KNIT_CMD_<cmd>_resource_<param>=<type>) records the declared type for
# validation and, later, for `describe` / `--help`. A before-callback validates
# the named instance (existence + recorded type) before the body runs, and an
# after-callback records a "used_by" provenance edge from the fetched instance to
# this command.
#
# Wrappers cannot declare knit_with_resource (they forward their arguments
# verbatim and take no parsed parameters). Every declared resource is required
# for now.
#
# Example:
# ```
# knit_register "train" _train "Train a model."
# knit_with_resource "training_dataset:image_dataset" "Training images."
# _train() {
#     local dir
#     dir="$(knit_resource_path "$(knit_get_parameter training_dataset "$@")")"
#     ...
# }
# knit_done
# ```
#
# @param spec        The dependency as "<param>:<type>".
# @param description One-line description of the resource parameter.
# ------------------------------------------------------------------------------
knit_with_resource() {
    if [[ ! -v _KNIT_CURRENT_COMMAND ]]; then
        knit_fatal "knit_with_resource must be called between a knit_register* call and knit_done."
    fi
    _knit_wrapper_reject_declaration "knit_with_resource"

    local spec="$1"
    local description="$2"
    if [[ "${spec}" != *:* ]]; then
        knit_fatal "knit_with_resource requires a \"<param>:<type>\" annotation; got \"${spec}\"."
    fi
    local param_name="${spec%%:*}"
    local type="${spec#*:}"
    if [[ -z "${param_name}" ]] || ! _knit_name_is_valid "${param_name}"; then
        knit_fatal "knit_with_resource: \"${param_name}\" is not a valid parameter name."
    fi
    if [[ -z "${type}" ]]; then
        knit_fatal "knit_with_resource requires a resource type after the colon; got \"${spec}\"."
    fi
    if [[ ! -v _KNIT_RESOURCES["${type}"] ]]; then
        knit_fatal "knit_with_resource references unknown resource type \"${type}\"; register it with knit_register_resource first."
    fi

    local cmd="${_KNIT_CURRENT_COMMAND}"
    local param
    param=$(_knit_name_normalize "${param_name}")

    # Record the declared type in a per-parameter marker, read by the validation
    # before-callback and (later) by describe / --help.
    printf -v "_KNIT_CMD_${cmd}_resource_${param}" '%s' "${type}"

    # Register the underlying required string parameter, the before-callback that
    # validates the named instance before the body runs, and the after-callback
    # that records the "used_by" provenance edge from the instance to this command.
    # All resources are required for now.
    [[ -z "${description}" ]] && description="Resource instance of type \"${type}\"."
    knit_with_required "${param_name}:string" "${description}"
    _knit_run_before _knit_resource_dep_before_cb "${param}" "${type}"
    _knit_run_after _knit_resource_dep_after_cb "${param}" "${type}"
}
