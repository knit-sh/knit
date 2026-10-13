#!/bin/bash

## @file plugin.sh

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_CACHE_ROOT
#
# Root of the content-addressed plugin cache, shared across experiments and
# invocations. A plugin commit is fetched once into
# "<root>/<host>/<org>/<repo>/<commit>/" and every later import of that commit is
# an offline cache hit. Defaults under XDG_CACHE_HOME (falling back to ~/.cache);
# a test or a reproducer may override it.
# ------------------------------------------------------------------------------
declare -g _KNIT_PLUGIN_CACHE_ROOT
_KNIT_PLUGIN_CACHE_ROOT="${XDG_CACHE_HOME:-${HOME}/.cache}/knit/plugins"

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_REFS
#
# Map of canonical id ("<host>/<org>/<repo>") to the ref it was imported at,
# recorded the moment an import begins (before sourcing) so a transitive or
# cyclic re-import of the same id dedups instead of recursing. An empty value
# means the import pinned no ref (default branch). Used for dedup and for the
# version-conflict check.
# ------------------------------------------------------------------------------
declare -gA _KNIT_PLUGIN_REFS
_KNIT_PLUGIN_REFS=()

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_COMMITS
#
# Map of canonical id to the exact commit SHA its ref resolved to. Populated as
# each plugin is imported; the seed of the provenance recorded at bootstrap.
# ------------------------------------------------------------------------------
declare -gA _KNIT_PLUGIN_COMMITS
_KNIT_PLUGIN_COMMITS=()

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_LOCKFILE
#
# Path to the committed lockfile that pins every imported plugin (canonical id ->
# resolved commit + checksum). It lives next to the experiment script and ships
# in the experiment's VCS, so a fresh checkout resolves the exact commits before
# bootstrap, for both introspection and reproduction. A resolution prefers a
# lockfile pin over the ref; a mutable ref with no pin is resolved once and
# written back here. A test or reproducer may override the path.
# ------------------------------------------------------------------------------
declare -g _KNIT_PLUGIN_LOCKFILE
_KNIT_PLUGIN_LOCKFILE="$(dirname "${_KNIT_SCRIPT_PATH}")/knit-plugins.lock"

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_DEFERRED
#
# Labels ("<id>" or "<id>@<ref>") of plugins that could not be made available in
# the current invocation (offline, with no cached commit and no lockfile pin).
# Their import is deferred rather than fatal, and they are listed in the
# describe/--help footer so the gap is explicit rather than a silent truncation.
# ------------------------------------------------------------------------------
declare -ga _KNIT_PLUGIN_DEFERRED
_KNIT_PLUGIN_DEFERRED=()

# ------------------------------------------------------------------------------
# @var _KNIT_PLUGIN_CNF_INSTALLED
#
# "true" once the command_not_found_handle safety net has been installed (on the
# first deferral), so it is installed at most once. The net keeps a "set -e"
# experiment source loading when it calls a deferred plugin's missing knit_*/@*
# symbol at registration time.
# ------------------------------------------------------------------------------
declare -g _KNIT_PLUGIN_CNF_INSTALLED
_KNIT_PLUGIN_CNF_INSTALLED="false"

# ------------------------------------------------------------------------------
# @fn _knit_plugin_lock_get()
#
# Look up a plugin's pin in the lockfile. Sets the commit and checksum outputs to
# the recorded values (checksum may be empty) and returns 0 when the canonical id
# is pinned; returns 1 (clearing both outputs) when it is not pinned or the
# lockfile is absent. Blank lines and "#" comment lines are ignored.
#
# @param[out] commit_out   Nameref receiving the pinned commit SHA.
# @param[out] checksum_out Nameref receiving the pinned tarball checksum.
# @param[in]  id           Canonical id ("<host>/<org>/<repo>").
# ------------------------------------------------------------------------------
_knit_plugin_lock_get() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    local id="$3"
    __knit_ret1=""
    __knit_ret2=""
    [[ -f "${_KNIT_PLUGIN_LOCKFILE}" ]] || return 1
    local lid lcommit lsum
    while read -r lid lcommit lsum; do
        [[ -z "${lid}" || "${lid}" == \#* ]] && continue
        if [[ "${lid}" == "${id}" ]]; then
            __knit_ret1="${lcommit}"
            __knit_ret2="${lsum}"
            return 0
        fi
    done < "${_KNIT_PLUGIN_LOCKFILE}"
    return 1
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_lock_set()
#
# Record (or update) a plugin's pin in the lockfile, then rewrite the file with
# its entries sorted by canonical id for a stable, review-friendly diff. An empty
# checksum is written as a two-field line; a present checksum as three fields.
#
# @param[in] id       Canonical id ("<host>/<org>/<repo>").
# @param[in] commit   Resolved commit SHA.
# @param[in] checksum Tarball sha256 (may be empty).
# ------------------------------------------------------------------------------
_knit_plugin_lock_set() {
    local id="$1"
    local commit="$2"
    local checksum="$3"
    local -A entries=()
    if [[ -f "${_KNIT_PLUGIN_LOCKFILE}" ]]; then
        local lid lcommit lsum
        while read -r lid lcommit lsum; do
            [[ -z "${lid}" || "${lid}" == \#* ]] && continue
            if [[ -n "${lsum}" ]]; then
                entries["${lid}"]="${lcommit} ${lsum}"
            else
                entries["${lid}"]="${lcommit}"
            fi
        done < "${_KNIT_PLUGIN_LOCKFILE}"
    fi
    if [[ -n "${checksum}" ]]; then
        entries["${id}"]="${commit} ${checksum}"
    else
        entries["${id}"]="${commit}"
    fi
    mkdir -p "$(dirname "${_KNIT_PLUGIN_LOCKFILE}")"
    local -a keys
    mapfile -t keys < <(printf '%s\n' "${!entries[@]}" | sort)
    {
        printf '# knit-plugins.lock: pinned plugin versions '
        printf '(id commit checksum). Generated; commit to VCS.\n'
        local k
        for k in "${keys[@]}"; do
            printf '%s %s\n' "${k}" "${entries[${k}]}"
        done
    } > "${_KNIT_PLUGIN_LOCKFILE}"
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_defer()
#
# Record a plugin whose code is unavailable this invocation (offline, uncached,
# unpinned) so it shows in the describe/--help footer, and install the
# command_not_found safety net so the experiment source still loads when it calls
# the plugin's (now undefined) symbols under "set -e".
#
# @param[in] id  Canonical id ("<host>/<org>/<repo>").
# @param[in] ref Requested ref (may be empty).
# ------------------------------------------------------------------------------
_knit_plugin_defer() {
    local id="$1"
    local ref="$2"
    local label="${id}"
    [[ -n "${ref}" ]] && label="${id}@${ref}"
    _KNIT_PLUGIN_DEFERRED+=("${label}")
    knit_trace "Deferring plugin ${label} (not available offline)."
    _knit_plugin_install_cnf_net
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_install_cnf_net()
#
# Install, at most once, a command_not_found_handle that turns a call to an
# undefined knit_*/@* symbol into a no-op returning 0 (so a deferred plugin's
# decorators/commands do not abort a "set -e" experiment at registration time),
# while any other unknown command keeps the default "command not found" failure.
# ------------------------------------------------------------------------------
_knit_plugin_install_cnf_net() {
    [[ "${_KNIT_PLUGIN_CNF_INSTALLED}" == "true" ]] && return 0
    _KNIT_PLUGIN_CNF_INSTALLED="true"
    # shellcheck disable=SC2317 # invoked indirectly by bash as the not-found hook
    command_not_found_handle() {
        local missing="$1"
        if [[ "${missing}" == knit_* || "${missing}" == @* ]]; then
            knit_trace "Ignoring \"${missing}\" from a deferred plugin."
            return 0
        fi
        printf '%s: command not found\n' "${missing}" >&2
        return 127
    }
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_print_deferred_footer()
#
# Print, to standard error, the footer listing plugins deferred this invocation
# (empty list -> nothing). describe and --help call it after their output so a
# user sees which plugin commands/decorators are missing and how to get them,
# instead of a silently truncated command tree. Standard error is used so the
# footer never corrupts a machine-readable describe format or piped help text.
# ------------------------------------------------------------------------------
_knit_plugin_print_deferred_footer() {
    local n="${#_KNIT_PLUGIN_DEFERRED[@]}"
    (( n > 0 )) || return 0
    local verb="are" plural="s"
    if (( n == 1 )); then
        verb="is"
        plural=""
    fi
    {
        printf '\n%d imported plugin%s %s not available offline ' \
            "${n}" "${plural}" "${verb}"
        printf '(no cached commit, no lockfile pin):\n'
        local p
        for p in "${_KNIT_PLUGIN_DEFERRED[@]}"; do
            printf '  - %s\n' "${p}"
        done
        printf 'Their commands and decorators appear once fetched. Run with '
        # shellcheck disable=SC2016 # literal backticks in a user-facing message
        printf 'network access, commit knit-plugins.lock, or run `knit bootstrap`.\n'
    } >&2
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_parse_spec()
#
# Parse an import spec into its host, org, repo, and ref parts. Accepted forms:
#   - "[https://]<host>/<org>/<repo>[@<ref>]" — a full spec.
#   - "<org>/<repo>[@<ref>]"                  — host defaults to github.com.
#   - "<name>[@<ref>]"                        — the blessed-namespace shorthand,
#     expanding to github.com/knit-sh/knit-<name>.
# A missing ref is returned empty (the caller treats it as the default branch).
# Fatal on a malformed spec.
#
# @param[out] host_out Nameref receiving the host.
# @param[out] org_out  Nameref receiving the owner (org or user).
# @param[out] repo_out Nameref receiving the repository name.
# @param[out] ref_out  Nameref receiving the ref (empty when none was given).
# @param[in]  spec     The import spec as written by the user.
# ------------------------------------------------------------------------------
_knit_plugin_parse_spec() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    local -n __knit_ret3=$3
    local -n __knit_ret4=$4
    local spec="$5"

    # Drop an optional scheme; the host is carried by the path below.
    spec="${spec#https://}"
    spec="${spec#http://}"

    # Split off the ref at the first "@"; the path part never contains one. The
    # temporaries below are __-prefixed because a caller passes its output
    # variables named host/org/repo/ref, which the namerefs alias; a plain local
    # of the same name would shadow the nameref (nameref-shadow-collision).
    local path __knit_ref=""
    if [[ "${spec}" == *@* ]]; then
        path="${spec%%@*}"
        __knit_ref="${spec#*@}"
    else
        path="${spec}"
    fi
    path="${path%/}"
    if [[ -z "${path}" ]]; then
        knit_fatal "knit_import: empty plugin spec."
    fi

    local -a parts
    IFS='/' read -r -a parts <<< "${path}"
    local __knit_host __knit_org __knit_repo
    case "${#parts[@]}" in
        1)
            __knit_host="github.com"
            __knit_org="knit-sh"
            __knit_repo="knit-${parts[0]}"
            ;;
        2)
            __knit_host="github.com"
            __knit_org="${parts[0]}"
            __knit_repo="${parts[1]}"
            ;;
        3)
            __knit_host="${parts[0]}"
            __knit_org="${parts[1]}"
            __knit_repo="${parts[2]}"
            ;;
        *)
            knit_fatal "knit_import: malformed plugin spec \"$5\" \
(expected [host/]org/repo or a plugin name)."
            ;;
    esac
    if [[ -z "${__knit_org}" || -z "${__knit_repo}" ]]; then
        knit_fatal "knit_import: malformed plugin spec \"$5\"."
    fi

    __knit_ret1="${__knit_host}"
    __knit_ret2="${__knit_org}"
    __knit_ret3="${__knit_repo}"
    __knit_ret4="${__knit_ref}"
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_resolve_commit()
#
# Resolve a plugin ref to an exact commit SHA, honoring the lockfile. Precedence:
# a full 40-hex-character SHA resolves to itself with no network access; else a
# lockfile pin for this canonical id is authoritative (deterministic and
# offline-friendly); else the ref is resolved through the host API (an empty ref
# means the default branch, resolved as "HEAD") and the writeback flag is set so
# the caller records the fresh pin. When KNIT_OFFLINE=1 blocks a needed network
# resolution, the function returns 1 (the caller defers the import) rather than
# failing.
#
# @param[out] commit_out    Nameref receiving the resolved commit SHA.
# @param[out] writeback_out Nameref set to "true" when a fresh (unpinned,
#             network-resolved) commit should be written back to the lockfile.
# @param[in]  host          Repository host (only github.com is supported today).
# @param[in]  org           Repository owner.
# @param[in]  repo          Repository name.
# @param[in]  ref           Ref to resolve (empty for the default branch).
# @return 0 when resolved; 1 when it cannot be resolved offline (defer).
# ------------------------------------------------------------------------------
_knit_plugin_resolve_commit() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    local host="$3"
    local org="$4"
    local repo="$5"
    local ref="$6"
    __knit_ret2="false"

    if [[ "${ref}" =~ ^[0-9a-f]{40}$ ]]; then
        __knit_ret1="${ref}"
        return 0
    fi

    # A lockfile pin wins over the ref: it is the recorded source of truth, so a
    # fresh checkout resolves identically before any bootstrap, even for "@main".
    local __knit_commit __knit_sum
    if _knit_plugin_lock_get __knit_commit __knit_sum "${host}/${org}/${repo}"; then
        __knit_ret1="${__knit_commit}"
        return 0
    fi

    if [[ "${KNIT_OFFLINE:-}" == "1" ]]; then
        return 1
    fi

    __knit_commit="$(_knit_github_resolve_commit "${org}" "${repo}" "${ref:-HEAD}")"
    __knit_ret1="${__knit_commit}"
    __knit_ret2="true"
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_fetch()
#
# Fetch a plugin commit into the content-addressed cache. The tarball is
# downloaded and extracted into a temporary directory; its sha256 is verified
# against an expected digest when one was given; the tree is checked for a
# top-level plugin.sh; then it is published atomically into the cache directory.
# The computed sha256 is returned so the caller can record it in the lockfile.
# Fatal on download failure, checksum mismatch, or a missing plugin.sh.
#
# @param[out] sha256_out Nameref receiving the fetched tarball's sha256.
# @param[in]  host       Repository host.
# @param[in]  org        Repository owner.
# @param[in]  repo       Repository name.
# @param[in]  commit     Commit SHA to fetch.
# @param[in]  dest       Cache directory to publish the extracted tree into.
# @param[in]  expected   Expected tarball sha256 (empty to skip verification).
# ------------------------------------------------------------------------------
_knit_plugin_fetch() {
    local -n __knit_ret=$1
    local host="$2"
    local org="$3"
    local repo="$4"
    local commit="$5"
    local dest="$6"
    local expected="$7"

    local tmp
    tmp="$(mktemp -d)"
    local sha256
    _knit_github_download sha256 _knit_framed_run "${org}" "${repo}" "${tmp}" "${commit}"
    if [[ -n "${expected}" && "${sha256}" != "${expected}" ]]; then
        rm -rf "${tmp}"
        knit_fatal "Plugin ${host}/${org}/${repo}@${commit}: sha256 mismatch \
(expected ${expected}, got ${sha256})."
    fi
    if [[ ! -f "${tmp}/plugin.sh" ]]; then
        rm -rf "${tmp}"
        knit_fatal "Plugin ${host}/${org}/${repo}@${commit}: \
no plugin.sh at the repository root."
    fi
    mkdir -p "$(dirname "${dest}")"
    rm -rf "${dest}"
    mv "${tmp}" "${dest}"
    __knit_ret="${sha256}"
}

# ------------------------------------------------------------------------------
# @fn knit_import()
#
# Import a plugin: resolve its spec to an exact commit, ensure that commit's code
# is present in the content-addressed cache (sourcing from cache when present,
# fetching it otherwise), and source its plugin.sh so its commands and decorators
# become available. Call it at the top of the experiment, after "source knit.sh"
# and before any use of what the plugin provides.
#
# A plugin is sourced once per canonical id ("<host>/<org>/<repo>"); a repeated
# import of the same id dedups. Importing the same id at two different explicit
# refs is a fatal version conflict. A plugin's own plugin.sh may call knit_import
# for its dependencies; because sourcing is synchronous, a dependency is fully
# sourced before the dependent continues.
#
# Resolution prefers a lockfile pin, so a fresh checkout resolves deterministically
# even before bootstrap; a mutable ref resolved for the first time is written back
# to the lockfile. When the plugin's code cannot be obtained (offline, with no
# cached commit and no pin), the import is deferred rather than fatal: it is
# recorded for the describe/--help footer and a command_not_found safety net keeps
# the experiment source loading.
#
# @param[in] spec The import spec (see _knit_plugin_parse_spec for the forms).
# @param[in] --sha256 <hash> Optional hard pin: fail unless the fetched tarball
#            matches this sha256.
# @see KNIT_OFFLINE=1 forces cache-only resolution (never touch the network).
# ------------------------------------------------------------------------------
knit_import() {
    local spec="" expected_sha256=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sha256)
                expected_sha256="$2"
                shift 2
                ;;
            --sha256=*)
                expected_sha256="${1#--sha256=}"
                shift
                ;;
            *)
                if [[ -z "${spec}" ]]; then
                    spec="$1"
                    shift
                else
                    knit_fatal "knit_import: unexpected argument \"$1\"."
                fi
                ;;
        esac
    done
    if [[ -z "${spec}" ]]; then
        knit_fatal "knit_import requires a plugin spec."
    fi

    local host org repo ref
    _knit_plugin_parse_spec host org repo ref "${spec}"
    if [[ "${host}" != "github.com" ]]; then
        knit_fatal "knit_import: plugin host \"${host}\" is not supported yet \
(only github.com)."
    fi
    local id="${host}/${org}/${repo}"

    # Dedup / conflict by canonical id, before any network access. Two explicit
    # and different refs conflict; an unpinned import is compatible with any pin.
    if [[ -v _KNIT_PLUGIN_REFS["${id}"] ]]; then
        local existing="${_KNIT_PLUGIN_REFS[${id}]}"
        if [[ -z "${ref}" || -z "${existing}" || "${ref}" == "${existing}" ]]; then
            if [[ -z "${existing}" && -n "${ref}" ]]; then
                _KNIT_PLUGIN_REFS["${id}"]="${ref}"
            fi
            return 0
        fi
        knit_fatal "Plugin \"${id}\" imported twice with conflicting refs: \
\"${existing}\" and \"${ref}\"."
    fi
    # Record the pin before sourcing so a transitive/cyclic re-import dedups.
    _KNIT_PLUGIN_REFS["${id}"]="${ref}"

    # Resolve the commit (lockfile pin, SHA, or network). A failure means the ref
    # cannot be resolved offline: defer rather than abort.
    local commit writeback
    if ! _knit_plugin_resolve_commit commit writeback "${host}" "${org}" \
            "${repo}" "${ref}"; then
        _knit_plugin_defer "${id}" "${ref}"
        return 0
    fi
    _KNIT_PLUGIN_COMMITS["${id}"]="${commit}"

    local dir="${_KNIT_PLUGIN_CACHE_ROOT}/${host}/${org}/${repo}/${commit}"
    local checksum=""
    if [[ ! -f "${dir}/plugin.sh" ]]; then
        # The commit is known but not cached; offline we cannot fetch it. Defer.
        if [[ "${KNIT_OFFLINE:-}" == "1" ]]; then
            _knit_plugin_defer "${id}" "${ref}"
            return 0
        fi
        _knit_plugin_fetch checksum "${host}" "${org}" "${repo}" "${commit}" \
            "${dir}" "${expected_sha256}"
    fi
    if [[ ! -f "${dir}/plugin.sh" ]]; then
        knit_fatal "Plugin \"${id}\": no plugin.sh at ${dir}."
    fi

    # Freshly resolved a mutable ref (no prior pin): record it so a later run and
    # a fresh checkout resolve to the same commit.
    if [[ "${writeback}" == "true" ]]; then
        _knit_plugin_lock_set "${id}" "${commit}" "${checksum}"
    fi

    knit_trace "Sourcing plugin ${id}@${commit}."
    # shellcheck disable=SC1091 # plugin path is resolved at runtime
    source "${dir}/plugin.sh"
}
