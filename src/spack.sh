#!/bin/bash

## @file spack.sh

# ------------------------------------------------------------------------------
# Root directory for the Spack installation.
# ------------------------------------------------------------------------------
declare -g _KNIT_SPACK_ROOT
_KNIT_SPACK_ROOT="${_KNIT_PREFIX}/spack"

# ------------------------------------------------------------------------------
# Root directory for the pre-cloned spack-packages repository (Spack >= 1.0
# keeps package recipes in a separate repo, referenced by repos.yaml).
# ------------------------------------------------------------------------------
declare -g _KNIT_SPACK_PACKAGES_ROOT
_KNIT_SPACK_PACKAGES_ROOT="${_KNIT_PREFIX}/spack-packages"

# ------------------------------------------------------------------------------
# @var _KNIT_SPACK_REQUIRED
#
# Set to a non-empty value at registration time (by knit_with_spack_env) when a
# setup declares a Spack environment, so bootstrap auto-provisions Spack even
# without an explicit --spack ref. Empty means "not required".
# ------------------------------------------------------------------------------
declare -g _KNIT_SPACK_REQUIRED
_KNIT_SPACK_REQUIRED=""

export SPACK_DISABLE_LOCAL_CONFIG=true
#export SPACK_USER_CACHE_PATH=/tmp/spack
export SPACK_USER_CONFIG_PATH="${_KNIT_PREFIX}/.spack"

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_need_spack()
#
# Decide whether Spack must be provisioned during bootstrap. Spack is needed
# when the user gave a non-empty --spack or --spack-packages ref, or when a
# registered setup declared a Spack environment (_KNIT_SPACK_REQUIRED).
#
# @param spack_ref Value of the --spack option (may be empty).
# @param packages_ref Value of the --spack-packages option (may be empty).
# @return 0 if Spack is needed, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_bootstrap_need_spack() {
    [[ -n "$1" || -n "$2" || -n "${_KNIT_SPACK_REQUIRED}" ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_spack_framed_run()
#
# Run a command with its combined stdout/stderr written to _KNIT_TRACE_FILE and,
# when KNIT_LOG_LEVEL is trace, also displayed live in a 10-line frame. Returns
# the exit status of the command.
#
# @param title Title shown on the frame's top border.
# @param ... Command and arguments to execute.
# ------------------------------------------------------------------------------
_knit_spack_framed_run() {
    local title="$1"
    shift
    _knit_ensure_trace_file
    "$@" 2>&1 | tee "${_KNIT_TRACE_FILE}" | \
        knit_framed 10 -1 --title "${title}" --log-level trace --cleanup
    local -a pipe_status=("${PIPESTATUS[@]}")
    return "${pipe_status[0]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_spack_latest_release()
#
# Resolve the latest release tag of a Spack repository via the GitHub API. Used
# when the user did not pin a ref: knit provisions the newest published release.
#
# @param repo Repository name under the spack org ("spack" or "spack-packages").
# @return Prints the newest release tag; fatal if none can be resolved.
# ------------------------------------------------------------------------------
_knit_spack_latest_release() {
    local repo="$1"
    local url="https://api.github.com/repos/spack/${repo}/releases"
    local tag
    tag="$(curl -s "${url}" | _knit_jq -r '.[0].tag_name // empty')"
    if [[ -z "${tag}" ]]; then
        knit_fatal "Could not resolve the latest ${repo} release from ${url}."
    fi
    printf '%s' "${tag}"
}

# ------------------------------------------------------------------------------
# @fn _knit_spack_clone()
#
# Shallow-clone a git repository at a specific ref. A tag or branch is cloned
# directly with --branch; a commit SHA (which --branch cannot take) falls back
# to init + shallow fetch + checkout of that commit.
#
# @param url Repository URL.
# @param dest Destination directory.
# @param ref Tag, branch, or commit SHA to check out.
# ------------------------------------------------------------------------------
_knit_spack_clone() {
    local url="$1"
    local dest="$2"
    local ref="$3"
    _knit_ensure_trace_file
    knit_trace "Cloning ${url} at ${ref}..."
    if _knit_spack_framed_run "spack: clone ${ref}" \
            git clone --depth 1 --branch "${ref}" "${url}" "${dest}"; then
        return 0
    fi
    # --branch only accepts tags/branches; fall back to fetching a commit SHA.
    knit_trace "Ref ${ref} is not a tag/branch; shallow-fetching it as a commit..."
    rm -rf "${dest}" > "${_KNIT_TRACE_FILE}" 2>&1
    git init "${dest}" > "${_KNIT_TRACE_FILE}" 2>&1
    git -C "${dest}" remote add origin "${url}" > "${_KNIT_TRACE_FILE}" 2>&1
    if ! _knit_spack_framed_run "spack: fetch ${ref}" \
            git -C "${dest}" fetch --depth 1 origin "${ref}"; then
        knit_fatal "Could not fetch ${ref} from ${url}. The remote may forbid" \
            "fetching arbitrary commits; use a tag or branch instead."
    fi
    git -C "${dest}" checkout FETCH_HEAD > "${_KNIT_TRACE_FILE}" 2>&1
}

# ------------------------------------------------------------------------------
# @fn _knit_spack_write_repos_yaml()
#
# Write <spack-root>/etc/spack/repos.yaml pointing the builtin package repo at
# the pre-cloned spack-packages destination, pinned to a specific commit so
# concretization is reproducible and needs no network on first use.
#
# @param commit Resolved spack-packages commit SHA to pin.
# ------------------------------------------------------------------------------
_knit_spack_write_repos_yaml() {
    local commit="$1"
    local dir="${_KNIT_SPACK_ROOT}/etc/spack"
    mkdir -p "${dir}"
    cat > "${dir}/repos.yaml" <<EOF
repos:
  builtin:
    git: https://github.com/spack/spack-packages.git
    destination: ${_KNIT_SPACK_PACKAGES_ROOT}
    commit: ${commit}
EOF
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_spack()
#
# Provision a knit-private Spack: resolve refs (latest release when empty),
# shallow-clone Spack and spack-packages, write a pinned repos.yaml, and record
# provenance metadata (requested refs and resolved commits).
#
# @param spack_ref Spack git ref (tag/branch/commit); empty uses the latest
#        release.
# @param packages_ref spack-packages git ref; empty uses the latest release.
# ------------------------------------------------------------------------------
_knit_bootstrap_spack() {
    local spack_ref="${1:-}"
    local packages_ref="${2:-}"

    if [[ -z "${spack_ref}" ]]; then
        knit_trace "Resolving latest spack release..."
        spack_ref="$(_knit_spack_latest_release spack)"
    fi
    if [[ -z "${packages_ref}" ]]; then
        knit_trace "Resolving latest spack-packages release..."
        packages_ref="$(_knit_spack_latest_release spack-packages)"
    fi

    _knit_spack_clone "https://github.com/spack/spack.git" \
        "${_KNIT_SPACK_ROOT}" "${spack_ref}"
    _knit_spack_clone "https://github.com/spack/spack-packages.git" \
        "${_KNIT_SPACK_PACKAGES_ROOT}" "${packages_ref}"

    # Resolve the checked-out refs to exact commits: a tag/branch is turned into
    # a SHA so the provisioning stays reproducible even after the ref moves.
    local spack_commit packages_commit
    spack_commit="$(git -C "${_KNIT_SPACK_ROOT}" rev-parse HEAD)"
    packages_commit="$(git -C "${_KNIT_SPACK_PACKAGES_ROOT}" rev-parse HEAD)"

    _knit_spack_write_repos_yaml "${packages_commit}"

    knit_trace "Storing spack provenance metadata..."
    knit metadata store --key "__spack_ref__"            --value "${spack_ref}"
    knit metadata store --key "__spack_commit__"         --value "${spack_commit}"
    knit metadata store --key "__spack_packages_ref__"   --value "${packages_ref}"
    knit metadata store --key "__spack_packages_commit__" --value "${packages_commit}"
}

# ------------------------------------------------------------------------------
# @fn _knit_spack_install()
#
# Install the specified specs using spack.
#
# @param ... Specs to install.
# ------------------------------------------------------------------------------
_knit_spack_install() {
    (
        # shellcheck disable=SC1091
        source "${_KNIT_SPACK_ROOT}/share/spack/setup-env.sh"
        local spec
        for spec in "$@"; do
            knit_info "Installing package ${spec}..."
            _knit_spack_framed_run "spack: install ${spec}" spack install "${spec}"
        done
    )
}
