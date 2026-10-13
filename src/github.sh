#!/bin/bash

## @file github.sh

# ------------------------------------------------------------------------------
# @fn _knit_github_api()
#
# Fetch a GitHub REST API URL and print the response body. When GITHUB_TOKEN or
# GH_TOKEN is set, the request is authenticated: the anonymous api.github.com
# limit is 60 requests per hour per address, shared by every process behind that
# address, so continuous-integration runners exhaust it and knit sees an error
# body instead of JSON. An authenticated request uses the far higher per-token
# limit. curl also retries a few times so a transient network error does not
# abort the caller, and "-f" makes an HTTP error status a clean failure (empty
# output) instead of a non-JSON body that would confuse the caller's parser.
#
# @param[in] url The api.github.com URL to fetch.
# @return Prints the response body; non-zero on a hard failure or HTTP error.
# ------------------------------------------------------------------------------
_knit_github_api() {
    local url="$1"
    local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    local -a args=(-fsSL --retry 3 --retry-delay 2)
    if [[ -n "${token}" ]]; then
        args+=(-H "Authorization: Bearer ${token}")
    fi
    curl "${args[@]}" "${url}"
}

# ------------------------------------------------------------------------------
# @fn _knit_github_resolve_commit()
#
# Resolve a ref (tag, branch, or commit SHA) to its exact commit SHA via the
# GitHub API. Resolving upstream gives a single download path (the archive URL
# takes a SHA) and the exact commit for provenance, without needing git.
#
# @param[in] org Repository owner (organization or user).
# @param[in] repo Repository name under that owner.
# @param[in] ref Tag, branch, or commit SHA to resolve.
# @return Prints the commit SHA; fatal if it cannot be resolved.
# ------------------------------------------------------------------------------
_knit_github_resolve_commit() {
    local org="$1"
    local repo="$2"
    local ref="$3"
    local url="https://api.github.com/repos/${org}/${repo}/commits/${ref}"
    local sha
    sha="$(_knit_github_api "${url}" | _knit_jq -r '.sha // empty')"
    if [[ -z "${sha}" ]]; then
        knit_fatal "Could not resolve ${ref} to a commit in ${org}/${repo}" \
            "from ${url}. If this is a rate-limited environment, set GITHUB_TOKEN."
    fi
    printf '%s' "${sha}"
}

# ------------------------------------------------------------------------------
# @fn _knit_github_download()
#
# Download a GitHub repository at a specific commit as a tarball, compute the
# tarball's sha256, and extract it into the destination directory. Uses curl and
# tar (as the sqlite/jq provisioning does) so knit has no git dependency. GitHub
# serves any commit at archive/<sha>.tar.gz, whose single top-level
# "<repo>-<sha>/" directory is stripped so files land directly in the
# destination.
#
# The download and extraction run through a caller-supplied framing callback (a
# function taking a title then a command, e.g. _knit_framed_run) so this
# helper stays decoupled from any particular progress display.
#
# @param[out] sha256_out Nameref that receives the tarball's sha256 hex digest.
# @param[in] framed_run Name of the framing callback (title + command to run).
# @param[in] org Repository owner (organization or user).
# @param[in] repo Repository name under that owner.
# @param[in] dest Destination directory.
# @param[in] sha Commit SHA to download.
# ------------------------------------------------------------------------------
_knit_github_download() {
    local -n __knit_ret=$1
    shift
    local framed_run="$1"
    local org="$2"
    local repo="$3"
    local dest="$4"
    local sha="$5"
    local url="https://github.com/${org}/${repo}/archive/${sha}.tar.gz"
    local tarball
    tarball="$(mktemp)"
    _knit_ensure_trace_file
    knit_trace "Downloading ${org}/${repo} at ${sha}..."
    if ! "${framed_run}" "download ${org}/${repo}" \
            curl -L -o "${tarball}" "${url}"; then
        rm -f "${tarball}"
        knit_fatal "Could not download ${org}/${repo} at ${sha} from ${url}." \
            "See ${_KNIT_TRACE_FILE} for more information."
    fi
    local digest
    digest="$(sha256sum "${tarball}")"
    __knit_ret="${digest%% *}"
    knit_trace "Extracting ${org}/${repo}..."
    mkdir -p "${dest}"
    if ! "${framed_run}" "extract ${org}/${repo}" \
            tar -xzf "${tarball}" -C "${dest}" --strip-components=1; then
        rm -f "${tarball}"
        knit_fatal "Could not extract ${org}/${repo} from ${tarball}." \
            "See ${_KNIT_TRACE_FILE} for more information."
    fi
    rm -f "${tarball}"
}
