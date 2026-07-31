#!/bin/bash

## @file profile.sh

# ------------------------------------------------------------------------------
# GitHub repository serving the in-repo profile store, and the org/repo the
# shorthand form resolves against.
# ------------------------------------------------------------------------------
declare -g _KNIT_PROFILE_REPO
_KNIT_PROFILE_REPO="knit-sh/knit"

# ------------------------------------------------------------------------------
# Directory of admin-provided (site) profiles, tried before the GitHub store so a
# machine's own copy wins and resolves offline. Overridable for testing.
# ------------------------------------------------------------------------------
declare -g _KNIT_PROFILE_ADMIN_DIR
_KNIT_PROFILE_ADMIN_DIR="/etc/knit/profiles"

# ------------------------------------------------------------------------------
# @var _KNIT_PROFILE_LAST_HTTP
#
# HTTP status of the most recent _knit_profile_http_get call ("200" on success,
# the returned status otherwise, empty when curl itself failed). Used to build
# the enumerating "profile not found" error.
# ------------------------------------------------------------------------------
declare -g _KNIT_PROFILE_LAST_HTTP
_KNIT_PROFILE_LAST_HTTP=""

# ------------------------------------------------------------------------------
# @fn _knit_profile_http_get()
#
# Fetch a URL and, on HTTP 200, store the body in the named variable. Records
# the HTTP status in _KNIT_PROFILE_LAST_HTTP. Returns 0 only on HTTP 200.
#
# @param __knit_ret1 Name of the variable to hold the response body.
# @param url         URL to fetch.
# ------------------------------------------------------------------------------
_knit_profile_http_get() {
    local -n __knit_ret1=$1
    local __url="$2"
    local __body
    _KNIT_PROFILE_LAST_HTTP=""
    # -w appends the HTTP status on its own line so we can distinguish a 404 body
    # from a real profile without needing jq (unavailable before bootstrap).
    if ! __body="$(curl -sSL -w '\n%{http_code}' "${__url}" 2>/dev/null)"; then
        return 1
    fi
    _KNIT_PROFILE_LAST_HTTP="${__body##*$'\n'}"
    __knit_ret1="${__body%$'\n'*}"
    [[ "${_KNIT_PROFILE_LAST_HTTP}" == "200" ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_profile_latest_ref()
#
# Resolve the latest knit release tag via the GitHub API (mirrors
# _knit_spack_latest_release). Prints the tag; fatal if none can be resolved.
# ------------------------------------------------------------------------------
_knit_profile_latest_ref() {
    local url="https://api.github.com/repos/${_KNIT_PROFILE_REPO}/releases/latest"
    local tag
    tag="$(curl -s "${url}" | _knit_jq -r '.tag_name // empty')"
    if [[ -z "${tag}" ]]; then
        knit_fatal "Could not resolve the latest knit release from ${url}."
    fi
    printf '%s' "${tag}"
}

# ------------------------------------------------------------------------------
# @fn _knit_profile_github_url()
#
# Build the raw.githubusercontent.com URL for a profile path at a ref. Uses the
# raw host (not github.com/.../blob/...) so the response is the JSON itself, not
# an HTML page.
#
# @param path Profile path under src/profiles, e.g. "anl/improv".
# @param ref  Git ref (tag, branch, or SHA).
# ------------------------------------------------------------------------------
_knit_profile_github_url() {
    local path="$1"
    local ref="$2"
    printf 'https://raw.githubusercontent.com/%s/%s/src/profiles/%s.json' \
        "${_KNIT_PROFILE_REPO}" "${ref}" "${path}"
}

# ------------------------------------------------------------------------------
# @fn _knit_resolve_profile()
#
# Resolve a --profile <spec> to its JSON content and a canonical label, trying
# each source in order (first match wins):
#
#   1. URL                 (http:// or https://) fetched verbatim
#   2. local file          <spec> or <spec>.json on disk (the offline story)
#   3. admin profile       /etc/knit/profiles/<spec>.json
#   4. GitHub shorthand    <namespace>/<machine>[@<ref>]; bare ref defaults to
#                          the running knit version, @latest resolves via the
#                          releases API
#
# On success sets the JSON content and the resolved label (a URL, path, or
# "<namespace>/<machine>@<ref>"). If nothing resolves, fatal with a message
# enumerating every source that was tried.
#
# @param __knit_ret1 Name of the variable to hold the resolved JSON content.
# @param __knit_ret2 Name of the variable to hold the resolved label.
# @param spec        The --profile argument.
# ------------------------------------------------------------------------------
_knit_resolve_profile() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    local spec="$3"
    # __ref and __body keep the underscore prefix: __body is passed down as
    # _knit_profile_http_get's output nameref, and __ref would otherwise shadow
    # __knit_ret2 when a caller passes an output variable literally named "ref".
    local __ref __body
    local -a tried=()

    # 1. URL ---------------------------------------------------------------------
    if [[ "${spec}" == http://* || "${spec}" == https://* ]]; then
        if _knit_profile_http_get __body "${spec}"; then
            __knit_ret1="${__body}"
            __knit_ret2="${spec}"
            return 0
        fi
        knit_fatal "%s" "profile '${spec}' not found: URL ${spec} -> HTTP ${_KNIT_PROFILE_LAST_HTTP:-error}."
    fi

    # 2. local file --------------------------------------------------------------
    local -a candidates=("${spec}")
    [[ "${spec}" != *.json ]] && candidates+=("${spec}.json")
    local f
    for f in "${candidates[@]}"; do
        if [[ -f "${f}" ]]; then
            __knit_ret1="$(cat "${f}")"
            __knit_ret2="${f}"
            return 0
        fi
        tried+=("no file '${f}'")
    done

    # 3. admin profile -----------------------------------------------------------
    local admin="${_KNIT_PROFILE_ADMIN_DIR}/${spec%.json}.json"
    if [[ -f "${admin}" ]]; then
        __knit_ret1="$(cat "${admin}")"
        __knit_ret2="${admin}"
        return 0
    fi
    tried+=("not in ${_KNIT_PROFILE_ADMIN_DIR}/")

    # 4. GitHub shorthand --------------------------------------------------------
    if [[ "${spec}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(@[A-Za-z0-9._/-]+)?$ ]]; then
        local path="${spec%@*}"
        if [[ "${spec}" == *@* ]]; then
            __ref="${spec#*@}"
        else
            __ref="${KNIT_VERSION}"
        fi
        [[ "${__ref}" == "latest" ]] && __ref="$(_knit_profile_latest_ref)"
        local url
        url="$(_knit_profile_github_url "${path}" "${__ref}")"
        if _knit_profile_http_get __body "${url}"; then
            __knit_ret1="${__body}"
            __knit_ret2="${path}@${__ref}"
            return 0
        fi
        tried+=("${url} -> HTTP ${_KNIT_PROFILE_LAST_HTTP:-error}")
    else
        tried+=("not a <namespace>/<machine>[@<ref>] shorthand")
    fi

    local joined
    printf -v joined '%s; ' "${tried[@]}"
    knit_fatal "%s" "profile '${spec}' not found: not a URL; ${joined%; }."
}

# ------------------------------------------------------------------------------
# @fn _knit_profile_parse_index()
#
# Parse a profile index (a JSON array of "<namespace>/<machine>" strings) into
# one entry per line. Uses a jq-free extraction of quoted tokens so it works
# before bootstrap, when jq is not yet available.
#
# @param __knit_ret1 Name of the variable to hold the newline-separated list.
# @param body        The index.json content.
# ------------------------------------------------------------------------------
_knit_profile_parse_index() {
    local -n __knit_ret1=$1
    local body="$2"
    __knit_ret1="$(printf '%s' "${body}" \
        | grep -oE '"[^"]+"' | sed 's/^"//; s/"$//')"
}

# ------------------------------------------------------------------------------
# @fn knit_list_profiles()
#
# Print the name of each profile served by the in-repo store, one per line, in
# sorted order. Fetches the committed index at the running knit version.
# ------------------------------------------------------------------------------
knit_list_profiles() {
    local url body list
    url="$(_knit_profile_github_url "index" "${KNIT_VERSION}")"
    # The index lives at src/profiles/index.json; reuse the profile URL builder
    # by passing "index" as the path.
    if ! _knit_profile_http_get body "${url}"; then
        knit_error "%s" "Could not fetch the profile index from ${url} (HTTP ${_KNIT_PROFILE_LAST_HTTP:-error})."
        return 1
    fi
    _knit_profile_parse_index list "${body}"
    printf '%s\n' "${list}" | sort
}

# ------------------------------------------------------------------------------
# @fn knit_get_profile_field()
#
# Extract one field from the bootstrapped experiment's profile using a jq path
# expression. Reads the resolved profile JSON frozen at bootstrap in the
# "__profile_json__" metadata. Prints the field value (without enclosing quotes
# for strings) or an empty string when no profile is configured or the field is
# absent.
#
# @param jq_path jq path expression, e.g. '.scheduler.type'.
# ------------------------------------------------------------------------------
knit_get_profile_field() {
    local jq_path="$1"
    local json
    _knit_metadata_get json "__profile_json__"
    [[ -z "${json}" ]] && return 0
    printf '%s' "${json}" | _knit_jq -r "${jq_path} // empty"
}

# ------------------------------------------------------------------------------
# @fn _knit_load_profile()
#
# Extract all portable fields from a profile's JSON and store them in global
# variables. Called by bootstrap after jq is available, with the resolved JSON
# content (not a name).
#
# Sets (empty string when a field is absent):
#   _KNIT_PROFILE_SCHEDULER_TYPE
#   _KNIT_PROFILE_SCHEDULER_COMMAND
#   _KNIT_PROFILE_SCHEDULER_DEFAULT_QUEUE
#   _KNIT_PROFILE_SCHEDULER_DEFAULT_ARGS   (space-joined from JSON array)
#   _KNIT_PROFILE_LAUNCHER_TYPE
#   _KNIT_PROFILE_LAUNCHER_COMMAND
#   _KNIT_PROFILE_LAUNCHER_DEFAULT_ARGS    (space-joined from JSON array)
#   _KNIT_PROFILE_CORES_PER_NODE
#   _KNIT_PROFILE_GPUS_PER_NODE
#
# @param json The resolved profile JSON content.
# ------------------------------------------------------------------------------
_knit_load_profile() {
    local json="$1"

    _KNIT_PROFILE_SCHEDULER_TYPE=$(printf '%s' "${json}" \
        | _knit_jq -r '.scheduler.type // empty')
    _KNIT_PROFILE_SCHEDULER_COMMAND=$(printf '%s' "${json}" \
        | _knit_jq -r '.scheduler.command // empty')
    _KNIT_PROFILE_SCHEDULER_DEFAULT_QUEUE=$(printf '%s' "${json}" \
        | _knit_jq -r '.scheduler.default_queue // empty')
    _KNIT_PROFILE_SCHEDULER_DEFAULT_ARGS=$(printf '%s' "${json}" \
        | _knit_jq -r '(.scheduler.default_args // []) | join(" ")')
    _KNIT_PROFILE_LAUNCHER_TYPE=$(printf '%s' "${json}" \
        | _knit_jq -r '.launcher.type // empty')
    _KNIT_PROFILE_LAUNCHER_COMMAND=$(printf '%s' "${json}" \
        | _knit_jq -r '.launcher.command // empty')
    _KNIT_PROFILE_LAUNCHER_DEFAULT_ARGS=$(printf '%s' "${json}" \
        | _knit_jq -r '(.launcher.default_args // []) | join(" ")')
    _KNIT_PROFILE_CORES_PER_NODE=$(printf '%s' "${json}" \
        | _knit_jq -r '.hardware.cores_per_node // empty')
    _KNIT_PROFILE_GPUS_PER_NODE=$(printf '%s' "${json}" \
        | _knit_jq -r '.hardware.gpus_per_node // empty')

    knit_trace "Loaded profile: scheduler=${_KNIT_PROFILE_SCHEDULER_TYPE}" \
        "launcher=${_KNIT_PROFILE_LAUNCHER_TYPE}" \
        "queue=${_KNIT_PROFILE_SCHEDULER_DEFAULT_QUEUE}"
}

# ------------------------------------------------------------------------------
# Registration of the profile command group.
# ------------------------------------------------------------------------------
knit_register knit_empty profile "List and inspect machine profiles."
_knit_is_builtin
knit_usable_before_bootstrap
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_profile_list()
#
# Implementation of 'knit profile list'.
# ------------------------------------------------------------------------------
_knit_profile_list() {
    knit_list_profiles
}

knit_register _knit_profile_list "profile:list" \
    "List the machine profiles served by the knit repository."
_knit_is_builtin
knit_usable_before_bootstrap
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_profile_show()
#
# Implementation of 'knit profile show'. For a bootstrapped experiment, prints
# the profile frozen at bootstrap; otherwise resolves the given spec (URL /
# local file / /etc/knit / shorthand) and prints it.
# ------------------------------------------------------------------------------
_knit_profile_show() {
    local spec
    spec="$(knit_get_parameter "profile" "$@")"

    if _knit_is_bootstrapped; then
        local json
        _knit_metadata_get json "__profile_json__"
        if [[ -z "${json}" ]]; then
            knit_fatal "This experiment was bootstrapped without a profile."
        fi
        printf '%s' "${json}" | _knit_jq .
        return 0
    fi

    if [[ -z "${spec}" ]]; then
        knit_fatal "A profile spec is required (a URL, a file, or <namespace>/<machine>[@<ref>])."
    fi
    local resolved_json
    # shellcheck disable=SC2034 # required output arg of _knit_resolve_profile, unused here
    local resolved_ref
    _knit_resolve_profile resolved_json resolved_ref "${spec}"
    # jq is unavailable before bootstrap, so print the raw JSON.
    printf '%s\n' "${resolved_json}"
}

knit_register _knit_profile_show "profile:show" \
    "Show a machine profile (the bootstrapped one, or a given spec)."
_knit_is_builtin
knit_usable_before_bootstrap
knit_with_optional "profile:string" "" \
    "Profile spec to display: a URL, a file, or <namespace>/<machine>[@<ref>]. Ignored once bootstrapped."
knit_done
