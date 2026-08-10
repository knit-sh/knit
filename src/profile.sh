#!/bin/bash

## @file profile.sh

# ------------------------------------------------------------------------------
# GitHub repository serving the in-repo profile store, and the org/repo the
# shorthand form resolves against.
# ------------------------------------------------------------------------------
declare -g _KNIT_PROFILE_REPO
_KNIT_PROFILE_REPO="knit-sh/knit"

# ------------------------------------------------------------------------------
# @var _KNIT_PROFILE_DEFAULT_REF
#
# Git ref the GitHub shorthand (and the profile index) resolve against when no
# explicit @ref is given. This is the default branch, not the running knit
# version tag, because the profile store on the default branch carries the most
# up-to-date machine profiles.
# ------------------------------------------------------------------------------
declare -g _KNIT_PROFILE_DEFAULT_REF
_KNIT_PROFILE_DEFAULT_REF="main"

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
# @var _KNIT_MODULE_INIT_CANDIDATES
#
# Ordered list of environment-module init scripts searched (after an optional
# profile "module_init" override and the MODULESHOME-derived path) when
# materializing .knit/platform.sh. The first that exists is sourced to make the
# `module` shell function available. Overridable for testing.
# ------------------------------------------------------------------------------
declare -ga _KNIT_MODULE_INIT_CANDIDATES
_KNIT_MODULE_INIT_CANDIDATES=(
    "/etc/profile.d/lmod.sh"
    "/usr/share/lmod/lmod/init/bash"
    "/etc/profile.d/modules.sh"
)

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
#   4. GitHub shorthand    <namespace>/<machine>[/<variant>...][@<ref>]; the
#                          path may be two or more segments (e.g.
#                          nersc/perlmutter/cpu). A bare ref defaults to the
#                          default branch (most up-to-date profiles); @latest
#                          resolves via the releases API
#
# On success sets the JSON content and the resolved label (a URL, path, or
# "<path>@<ref>"). If nothing resolves, fatal with a message enumerating every
# source that was tried.
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
    if [[ "${spec}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+(@[A-Za-z0-9._/-]+)?$ ]]; then
        local path="${spec%@*}"
        if [[ "${spec}" == *@* ]]; then
            __ref="${spec#*@}"
        else
            __ref="${_KNIT_PROFILE_DEFAULT_REF}"
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
        tried+=("not a <namespace>/<machine>[/<variant>...][@<ref>] shorthand")
    fi

    local joined
    printf -v joined '%s; ' "${tried[@]}"
    knit_fatal "%s" "profile '${spec}' not found: not a URL; ${joined%; }."
}

# ------------------------------------------------------------------------------
# @fn _knit_profile_parse_index()
#
# Parse a profile index into one "<name><TAB><description><TAB><hidden>" line per
# entry. The index is a JSON array of one-line objects, e.g.
# `{ "name": "anl/aurora", "description": "...", "hidden": true }` (see
# gen-profile-index.sh). Extraction is jq-free (a single sed) so it works before
# bootstrap, when jq is not yet available; it relies on the description
# containing no literal '"', which the generator guarantees for shipped
# descriptions.
#
# @param __knit_ret1 Name of the variable to hold the newline-separated list.
# @param body        The index.json content.
# ------------------------------------------------------------------------------
_knit_profile_parse_index() {
    local -n __knit_ret1=$1
    local body="$2"
    local tab=$'\t'
    __knit_ret1="$(printf '%s' "${body}" | sed -n -E \
        "s/.*\"name\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*\"description\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*\"hidden\"[[:space:]]*:[[:space:]]*(true|false).*/\\1${tab}\\2${tab}\\3/p")"
}

# ------------------------------------------------------------------------------
# @fn _knit_profile_admin_entries()
#
# List the admin-provided profiles under _KNIT_PROFILE_ADMIN_DIR as
# "<name><TAB><description><TAB><hidden>" lines, one per profile, where <name> is
# the path relative to the admin directory minus the .json suffix and <hidden> is
# "true" when the profile sets "_hide": true (mirroring the GitHub index's hidden
# field). Empty when the directory is absent.
#
# Every profile is listed, including hidden ones; knit_list_profiles does the
# filtering. Both the hidden check and the description read are jq-free (a
# grep/sed for the marker) so listing keeps working before bootstrap.
#
# @param __knit_ret1 Name of the variable to hold the newline-separated entries.
# ------------------------------------------------------------------------------
_knit_profile_admin_entries() {
    local -n __knit_ret1=$1
    __knit_ret1=""
    [[ -d "${_KNIT_PROFILE_ADMIN_DIR}" ]] || return 0
    local f name desc hidden out=""
    local tab=$'\t'
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        if _knit_profile_is_hidden "${f}"; then hidden="true"; else hidden="false"; fi
        name="${f#"${_KNIT_PROFILE_ADMIN_DIR}"/}"
        _knit_profile_file_description desc "${f}"
        out+="${name%.json}${tab}${desc}${tab}${hidden}"$'\n'
    done < <(find "${_KNIT_PROFILE_ADMIN_DIR}" -type f -name '*.json' 2>/dev/null | sort)
    __knit_ret1="${out%$'\n'}"
}

# ------------------------------------------------------------------------------
# @fn _knit_profile_file_description()
#
# Extract a profile file's `description` field jq-free, so `knit profile list`
# can show it before bootstrap (jq may be absent). Uses a sed for the first
# `"description": "..."` occurrence; relies on the value containing no literal
# '"'. The result is empty when the field is absent.
#
# @param __knit_ret1 Name of the variable to hold the description.
# @param file        Path to the profile JSON file.
# ------------------------------------------------------------------------------
_knit_profile_file_description() {
    local -n __knit_ret1=$1
    local file="$2"
    __knit_ret1="$(sed -n -E \
        's/.*"description"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' \
        "${file}" 2>/dev/null | head -1)"
}

# ------------------------------------------------------------------------------
# @fn _knit_profile_is_hidden()
#
# Return success when the profile file names its `_hide` field as true. Uses a
# jq-free grep so it works before bootstrap (jq may be absent), tolerating the
# usual JSON spacing around the colon.
#
# @param file Path to the profile JSON file.
# ------------------------------------------------------------------------------
_knit_profile_is_hidden() {
    local file="$1"
    grep -Eq '"_hide"[[:space:]]*:[[:space:]]*true' "${file}" 2>/dev/null
}

# ------------------------------------------------------------------------------
# @fn knit_list_profiles()
#
# Print the union of the profiles known to knit, one per line in sorted order,
# laid out like a command's parameters in "--help": a name column, a "[source]"
# annotation, then the profile's description word-wrapped with a hanging indent
# under the annotation column. The source is the committed in-repo index (fetched
# from the default branch) or the admin store under _KNIT_PROFILE_ADMIN_DIR; an
# admin profile that shares a name with a repo one shadows it (§4.5) and is
# marked accordingly (its description wins). The repo index is fetched
# best-effort so an offline, admin-only machine still lists its own profiles.
#
# Hidden profiles (JSON "_hide": true) are omitted by default. When show_hidden
# is "true" they are included and annotated ", hidden" after the source.
#
# Wrapping reuses _knit_terminal_width / _knit_help_render_entry (the same
# helpers "--help" uses), so alignment, wrap-around, and the pipe/redirect
# single-line fallback all match option listings.
#
# @param show_hidden "true" to also list hidden profiles (default "false").
# ------------------------------------------------------------------------------
knit_list_profiles() {
    local show_hidden="${1:-false}"
    local github="" admin=""

    local url body
    url="$(_knit_profile_github_url "index" "${_KNIT_PROFILE_DEFAULT_REF}")"
    # The index lives at src/profiles/index.json; reuse the profile URL builder
    # by passing "index" as the path.
    if _knit_profile_http_get body "${url}"; then
        _knit_profile_parse_index github "${body}"
    else
        knit_warning "%s" "Could not fetch the profile index from ${url} (HTTP ${_KNIT_PROFILE_LAST_HTTP:-error}); listing admin profiles only."
    fi
    _knit_profile_admin_entries admin

    # Both lists are "<name><TAB><description><TAB><hidden>" lines. Build name ->
    # source, description, and hidden maps; an admin entry overrides a github
    # entry of the same name (the admin profile is the effective one when it
    # shadows).
    local -A is_github=() is_admin=() descr=() is_hidden=()
    local name d h
    while IFS=$'\t' read -r name d h; do
        [[ -n "${name}" ]] || continue
        is_github["${name}"]=1
        descr["${name}"]="${d}"
        is_hidden["${name}"]="${h}"
    done <<< "${github}"
    while IFS=$'\t' read -r name d h; do
        [[ -n "${name}" ]] || continue
        is_admin["${name}"]=1
        descr["${name}"]="${d}"
        is_hidden["${name}"]="${h}"
    done <<< "${admin}"

    # Names to list: all of them, or only the non-hidden ones by default.
    local all n
    all=""
    while IFS= read -r n; do
        [[ -n "${n}" ]] || continue
        if [[ "${show_hidden}" != "true" && "${is_hidden[${n}]:-false}" == "true" ]]; then
            continue
        fi
        all+="${n}"$'\n'
    done < <(printf '%s\n' "${!is_github[@]}" "${!is_admin[@]}" | grep -v '^$' | sort -u)
    all="${all%$'\n'}"
    [[ -z "${all}" ]] && return 0

    # Name-column width, so annotations and descriptions align across rows.
    local max_name=0
    while IFS= read -r n; do
        [[ -n "${n}" ]] || continue
        (( ${#n} > max_name )) && max_name=${#n}
    done <<< "${all}"

    local width
    _knit_terminal_width width
    local indent=$((2 + max_name + 2))

    local label head
    while IFS= read -r n; do
        [[ -n "${n}" ]] || continue
        if [[ -n "${is_admin[${n}]:-}" && -n "${is_github[${n}]:-}" ]]; then
            label="admin (shadows github)"
        elif [[ -n "${is_admin[${n}]:-}" ]]; then
            label="admin"
        else
            label="github"
        fi
        [[ "${is_hidden[${n}]:-false}" == "true" ]] && label+=", hidden"
        printf -v head "  %-${max_name}s  [%s] " "${n}" "${label}"
        _knit_help_render_entry "${width}" "${head}" "${#head}" "${indent}" \
            "${descr[${n}]:-}"
    done <<< "${all}"
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
# @fn _knit_resolve_module_init()
#
# Resolve the environment-module init script to source when materializing the
# platform (§5.2), trying in order: an explicit profile "module_init" override;
# the MODULESHOME-derived path and the standard candidate list
# (_KNIT_MODULE_INIT_CANDIDATES); finally, if `module` is already a function or
# command in this environment, no init line is needed (empty result). Returns
# non-zero when none applies, so the caller can fatal.
#
# @param __knit_ret1 Name of the variable to hold the resolved init path (empty
#                    when `module` is already available and no script is needed).
# @param json        The resolved profile JSON content.
# ------------------------------------------------------------------------------
_knit_resolve_module_init() {
    local -n __knit_ret1=$1
    local json="$2"

    local override
    override="$(printf '%s' "${json}" | _knit_jq -r '.module_init // empty')"
    if [[ -n "${override}" ]]; then
        __knit_ret1="${override}"
        return 0
    fi

    local -a candidates=()
    [[ -n "${MODULESHOME:-}" ]] && candidates+=("${MODULESHOME}/init/bash")
    candidates+=("${_KNIT_MODULE_INIT_CANDIDATES[@]}")

    local c
    for c in "${candidates[@]}"; do
        if [[ -f "${c}" ]]; then
            __knit_ret1="${c}"
            return 0
        fi
    done

    # Last resort: `module` is already available in this environment; emit no
    # init line and rely on the inherited environment.
    if declare -F module >/dev/null 2>&1 || command -v module >/dev/null 2>&1; then
        __knit_ret1=""
        return 0
    fi

    return 1
}

# ------------------------------------------------------------------------------
# @fn _knit_render_platform_sh()
#
# Render the platform shell fragment (§5.3) to a file: an optional module-init
# source line, an optional `module purge`, a single `module load` of the
# profile's modules, and one `export KEY=VALUE` per environment entry. The file
# is left absent (not created) when the profile has neither `modules` nor
# `environment`. Fatal when `modules` is present but no module init resolves.
#
# @param json    The resolved profile JSON content.
# @param outfile Path of the platform.sh file to write.
# ------------------------------------------------------------------------------
_knit_render_platform_sh() {
    local json="$1"
    local outfile="$2"

    local modules has_env
    modules="$(printf '%s' "${json}" | _knit_jq -r '(.modules // []) | join(" ")')"
    has_env="$(printf '%s' "${json}" | _knit_jq -r '(.environment // {}) | length')"

    # Nothing to render -> leave the file absent so consumers treat it as a no-op.
    if [[ -z "${modules}" && "${has_env}" == "0" ]]; then
        return 0
    fi

    local -a lines=("# knit platform environment (generated at bootstrap)")

    if [[ -n "${modules}" ]]; then
        local init purge
        # Resolve the init before opening the file so a failure fatals cleanly
        # without leaving a partial platform.sh behind.
        if ! _knit_resolve_module_init init "${json}"; then
            knit_fatal "%s" "profile lists modules (${modules}) but no 'module' init script was found; set \"module_init\" in the profile."
        fi
        [[ -n "${init}" ]] && lines+=("source ${init}")
        purge="$(printf '%s' "${json}" | _knit_jq -r '.module_purge // false')"
        [[ "${purge}" == "true" ]] && lines+=("module purge")
        lines+=("module load ${modules}")
    fi

    if [[ "${has_env}" != "0" ]]; then
        local key val line
        while IFS=$'\t' read -r key val; do
            [[ -z "${key}" ]] && continue
            # %q shell-quotes the value; platform.sh is sourced by bash.
            printf -v line 'export %s=%q' "${key}" "${val}"
            lines+=("${line}")
        done < <(printf '%s' "${json}" \
            | _knit_jq -r '.environment | to_entries[] | .key + "\t" + (.value|tostring)')
    fi

    printf '%s\n' "${lines[@]}" > "${outfile}"
}

# ------------------------------------------------------------------------------
# @fn _knit_render_packages_yaml()
#
# Render the profile's `spack.externals` (§6.2) to a Spack config fragment: a
# single top-level `packages:` map with one entry per external name, each
# carrying its externals list (spec, optional prefix, optional modules) and
# `buildable` (default true). The externals live under a `spack` object so other
# package managers can have their own sibling section later. The file is left
# absent when the profile declares no Spack externals.
#
# @param json    The resolved profile JSON content.
# @param outfile Path of the packages.yaml file to write.
# ------------------------------------------------------------------------------
_knit_render_packages_yaml() {
    local json="$1"
    local outfile="$2"

    local count
    count="$(printf '%s' "${json}" | _knit_jq -r '(.spack.externals // []) | length')"
    if [[ "${count}" == "0" ]]; then
        return 0
    fi

    printf '%s' "${json}" | _knit_jq -r '
        "packages:",
        ( .spack.externals | group_by(.name)[] |
          "  " + .[0].name + ":",
          "    externals:",
          ( .[] |
            "    - spec: \"" + .spec + "\"",
            ( if .prefix then "      prefix: " + .prefix else empty end),
            ( if .modules then "      modules: [" + (.modules | join(", ")) + "]" else empty end)
          ),
          "    buildable: " + ((.[0] | if has("buildable") then .buildable else true end) | tostring)
        )
    ' > "${outfile}"
}

# ------------------------------------------------------------------------------
# @fn _knit_render_platform_files()
#
# Materialize the profile's platform artifacts under _KNIT_PREFIX:
# platform.sh (modules + environment, §5.3) and packages.yaml (externals,
# §6.2). Either file is left absent when the profile omits the corresponding
# fields. Called by bootstrap after the profile is resolved.
#
# @param json The resolved profile JSON content.
# ------------------------------------------------------------------------------
_knit_render_platform_files() {
    local json="$1"
    _knit_render_platform_sh   "${json}" "${_KNIT_PREFIX}/platform.sh"
    _knit_render_packages_yaml "${json}" "${_KNIT_PREFIX}/packages.yaml"
}

# ------------------------------------------------------------------------------
# Registration of the profile command group.
# ------------------------------------------------------------------------------
knit_register profile knit_empty "List and inspect machine profiles."
_knit_is_builtin
knit_usable_before_bootstrap
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_profile_list()
#
# Implementation of 'knit profile list'.
# ------------------------------------------------------------------------------
_knit_profile_list() {
    local hidden
    hidden="$(knit_get_parameter "hidden" "$@")"
    knit_list_profiles "${hidden}"
}

knit_register "profile:list" _knit_profile_list \
    "List the machine profiles served by the knit repository."
knit_with_flag "hidden" "Also list profiles marked hidden (\"_hide\": true)."
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

knit_register "profile:show" _knit_profile_show \
    "Show a machine profile (the bootstrapped one, or a given spec)."
_knit_is_builtin
knit_usable_before_bootstrap
knit_with_optional "profile:string" "" \
    "Profile spec to display: a URL, a file, or <namespace>/<machine>[@<ref>]. Ignored once bootstrapped."
knit_done
