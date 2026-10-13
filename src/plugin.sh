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
# Resolve a plugin ref to an exact commit SHA. A full 40-hex-character SHA
# resolves to itself with no network access (so a SHA-pinned import works
# offline); an empty ref means the default branch (resolved as "HEAD"). Any other
# ref is resolved through the host API. Fatal when KNIT_OFFLINE=1 forces
# cache-only and the ref is not already a SHA.
#
# @param[out] commit_out Nameref receiving the resolved commit SHA.
# @param[in]  host       Repository host (only github.com is supported today).
# @param[in]  org        Repository owner.
# @param[in]  repo       Repository name.
# @param[in]  ref        Ref to resolve (empty for the default branch).
# ------------------------------------------------------------------------------
_knit_plugin_resolve_commit() {
    local -n __knit_ret=$1
    local host="$2"
    local org="$3"
    local repo="$4"
    local ref="$5"

    if [[ "${ref}" =~ ^[0-9a-f]{40}$ ]]; then
        __knit_ret="${ref}"
        return 0
    fi
    if [[ "${KNIT_OFFLINE:-}" == "1" ]]; then
        knit_fatal "Cannot resolve plugin ref \"${ref:-<default>}\" for \
${host}/${org}/${repo} while KNIT_OFFLINE=1 \
(pin a commit SHA or populate the lockfile)."
    fi
    # __-prefixed because a caller passes its output variable named "commit",
    # which __knit_ret aliases; a plain local "commit" would shadow it.
    local __knit_commit
    __knit_commit="$(_knit_github_resolve_commit "${org}" "${repo}" "${ref:-HEAD}")"
    __knit_ret="${__knit_commit}"
}

# ------------------------------------------------------------------------------
# @fn _knit_plugin_fetch()
#
# Fetch a plugin commit into the content-addressed cache. The tarball is
# downloaded and extracted into a temporary directory; its sha256 is verified
# against an expected digest when one was given; the tree is checked for a
# top-level plugin.sh; then it is published atomically into the cache directory.
# Fatal on download failure, checksum mismatch, or a missing plugin.sh.
#
# @param[in] host     Repository host.
# @param[in] org      Repository owner.
# @param[in] repo     Repository name.
# @param[in] commit   Commit SHA to fetch.
# @param[in] dest     Cache directory to publish the extracted tree into.
# @param[in] expected Expected tarball sha256 (empty to skip verification).
# ------------------------------------------------------------------------------
_knit_plugin_fetch() {
    local host="$1"
    local org="$2"
    local repo="$3"
    local commit="$4"
    local dest="$5"
    local expected="$6"

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

    local commit
    _knit_plugin_resolve_commit commit "${host}" "${org}" "${repo}" "${ref}"
    _KNIT_PLUGIN_COMMITS["${id}"]="${commit}"

    local dir="${_KNIT_PLUGIN_CACHE_ROOT}/${host}/${org}/${repo}/${commit}"
    if [[ ! -f "${dir}/plugin.sh" ]]; then
        if [[ "${KNIT_OFFLINE:-}" == "1" ]]; then
            knit_fatal "Plugin \"${id}@${commit}\" is not cached and KNIT_OFFLINE=1."
        fi
        _knit_plugin_fetch "${host}" "${org}" "${repo}" "${commit}" "${dir}" \
            "${expected_sha256}"
    fi
    if [[ ! -f "${dir}/plugin.sh" ]]; then
        knit_fatal "Plugin \"${id}\": no plugin.sh at ${dir}."
    fi

    knit_trace "Sourcing plugin ${id}@${commit}."
    # shellcheck disable=SC1091 # plugin path is resolved at runtime
    source "${dir}/plugin.sh"
}
