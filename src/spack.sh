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

# ------------------------------------------------------------------------------
# @var _KNIT_SPACK_ENV_SOURCED
#
# Guard so Spack's setup-env.sh is sourced at most once per process. The wrapper
# runs in the caller's own shell (no subshell, no exec), so the first "knit
# spack" invocation sources setup-env.sh and sets this flag; subsequent
# invocations in the same script reuse the already-modified PATH and the spack
# shell function instead of paying the (slow) sourcing cost again. Empty means
# "not yet sourced".
# ------------------------------------------------------------------------------
declare -g _KNIT_SPACK_ENV_SOURCED
_KNIT_SPACK_ENV_SOURCED=""

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
# @fn _knit_spack_github_api()
#
# Fetch a GitHub REST API URL and print the response body. When GITHUB_TOKEN or
# GH_TOKEN is set, the request is authenticated: the anonymous api.github.com
# limit is 60 requests per hour per address, shared by every process behind that
# address, so continuous-integration runners exhaust it and knit sees an error
# body instead of JSON. An authenticated request uses the far higher per-token
# limit. curl also retries a few times so a transient network error does not
# abort a bootstrap, and "-f" makes an HTTP error status a clean failure (empty
# output) instead of a non-JSON body that would confuse the caller's parser.
#
# @param url The api.github.com URL to fetch.
# @return Prints the response body; non-zero on a hard failure or HTTP error.
# ------------------------------------------------------------------------------
_knit_spack_github_api() {
    local url="$1"
    local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    local -a args=(-fsSL --retry 3 --retry-delay 2)
    if [[ -n "${token}" ]]; then
        args+=(-H "Authorization: Bearer ${token}")
    fi
    curl "${args[@]}" "${url}"
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
    local url="https://api.github.com/repos/spack/${repo}/releases/latest"
    local tag
    tag="$(_knit_spack_github_api "${url}" | _knit_jq -r '.tag_name // empty')"
    if [[ -z "${tag}" ]]; then
        knit_fatal "Could not resolve the latest ${repo} release from ${url}." \
            "If this is a rate-limited environment, set GITHUB_TOKEN."
    fi
    printf '%s' "${tag}"
}

# ------------------------------------------------------------------------------
# @fn _knit_spack_resolve_commit()
#
# Resolve a ref (tag, branch, or commit SHA) to its exact commit SHA via the
# GitHub API. Resolving upstream gives a single download path (the archive URL
# takes a SHA) and the exact commit for provenance, without needing git.
#
# @param repo Repository name under the spack org ("spack" or "spack-packages").
# @param ref Tag, branch, or commit SHA to resolve.
# @return Prints the commit SHA; fatal if it cannot be resolved.
# ------------------------------------------------------------------------------
_knit_spack_resolve_commit() {
    local repo="$1"
    local ref="$2"
    local url="https://api.github.com/repos/spack/${repo}/commits/${ref}"
    local sha
    sha="$(_knit_spack_github_api "${url}" | _knit_jq -r '.sha // empty')"
    if [[ -z "${sha}" ]]; then
        knit_fatal "Could not resolve ${ref} to a commit in spack/${repo}" \
            "from ${url}. If this is a rate-limited environment, set GITHUB_TOKEN."
    fi
    printf '%s' "${sha}"
}

# ------------------------------------------------------------------------------
# @fn _knit_spack_download()
#
# Download a Spack repository at a specific commit as a tarball and extract it
# into the destination directory. Uses curl and tar (as the sqlite/jq
# provisioning does) so knit has no git dependency. GitHub serves any commit at
# archive/<sha>.tar.gz, whose single top-level "<repo>-<sha>/" directory is
# stripped so files land directly in the destination.
#
# @param repo Repository name under the spack org ("spack" or "spack-packages").
# @param dest Destination directory.
# @param sha Commit SHA to download.
# ------------------------------------------------------------------------------
_knit_spack_download() {
    local repo="$1"
    local dest="$2"
    local sha="$3"
    local url="https://github.com/spack/${repo}/archive/${sha}.tar.gz"
    local tarball="${_KNIT_PREFIX}/${repo}-${sha}.tar.gz"
    _knit_ensure_trace_file
    knit_trace "Downloading spack/${repo} at ${sha}..."
    if ! _knit_spack_framed_run "spack: download ${repo}" \
            curl -L -o "${tarball}" "${url}"; then
        knit_fatal "Could not download spack/${repo} at ${sha} from ${url}." \
            "See ${_KNIT_TRACE_FILE} for more information."
    fi
    knit_trace "Extracting spack/${repo}..."
    mkdir -p "${dest}"
    if ! _knit_spack_framed_run "spack: extract ${repo}" \
            tar -xzf "${tarball}" -C "${dest}" --strip-components=1; then
        knit_fatal "Could not extract spack/${repo} from ${tarball}." \
            "See ${_KNIT_TRACE_FILE} for more information."
    fi
    rm -f "${tarball}"
}

# ------------------------------------------------------------------------------
# @fn _knit_spack_write_repos_yaml()
#
# Write <spack-root>/etc/spack/repos.yaml pointing the builtin package repo at
# the already-extracted spack-packages tree by local filesystem path. The
# local-path form needs no git: a git-backed "destination" would make Spack
# treat the tree as a clone (which the tarball extraction is not) and reach for
# git at runtime. Reproducibility comes from the pinned commit downloaded into
# that tree, recorded in provenance metadata.
# ------------------------------------------------------------------------------
_knit_spack_write_repos_yaml() {
    local dir="${_KNIT_SPACK_ROOT}/etc/spack"
    mkdir -p "${dir}"
    cat > "${dir}/repos.yaml" <<EOF
repos:
  builtin: ${_KNIT_SPACK_PACKAGES_ROOT}/repos/spack_repo/builtin
EOF
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_spack()
#
# Provision a knit-private Spack: resolve refs (latest release when empty) to
# exact commits, download and extract Spack and spack-packages with curl+tar,
# write a local-path repos.yaml, and record provenance metadata (requested refs
# and resolved commits). No git dependency.
#
# @param spack_ref Spack ref (tag/branch/commit); empty uses the latest release.
# @param packages_ref spack-packages ref; empty uses the latest release.
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

    # Resolve refs to exact commits upstream: a tag/branch becomes a SHA so the
    # provisioning stays reproducible even after the ref moves, and the archive
    # URL (which takes a SHA) has a single code path for every ref kind.
    local spack_commit packages_commit
    spack_commit="$(_knit_spack_resolve_commit spack "${spack_ref}")"
    packages_commit="$(_knit_spack_resolve_commit spack-packages "${packages_ref}")"

    _knit_spack_download spack "${_KNIT_SPACK_ROOT}" "${spack_commit}"
    _knit_spack_download spack-packages "${_KNIT_SPACK_PACKAGES_ROOT}" \
        "${packages_commit}"

    _knit_spack_write_repos_yaml

    knit_trace "Storing spack provenance metadata..."
    knit metadata store --key "__spack_ref__"            --value "${spack_ref}"
    knit metadata store --key "__spack_commit__"         --value "${spack_commit}"
    knit metadata store --key "__spack_packages_ref__"   --value "${packages_ref}"
    knit metadata store --key "__spack_packages_commit__" --value "${packages_commit}"
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_spack_env_built()
#
# Return 0 when at least one setup instance has a built Spack environment,
# non-zero otherwise. A built environment is a "spack-env/spack.lock" lockfile
# under a setup instance directory (see _knit_setup_spack_env_before_cb). Used by
# update-mode Spack handling to freeze the Spack version once any environment has
# been concretized, for reproducibility. A missing setup root reports "none
# built".
# ------------------------------------------------------------------------------
_knit_bootstrap_spack_env_built() {
    local root
    _knit_setup_root root
    [[ -d "${root}" ]] || return 1
    local entry
    for entry in "${root}"/*/; do
        [[ -f "${entry}spack-env/spack.lock" ]] && return 0
    done
    return 1
}

# ------------------------------------------------------------------------------
# @fn _knit_bootstrap_update_spack()
#
# Update-mode handler for the Spack options (--spack, --spack-packages). Spack
# anchors reproducibility, so its version is frozen once an environment is built:
#
#   - Spack not provisioned yet: provision it now when a ref was typed or a
#     Spack-requiring setup is registered (the first-bootstrap condition). This
#     adds Spack that the first bootstrap did not.
#   - Spack already provisioned and a typed ref differs from the stored ref:
#       * no Spack environment is built anywhere -> re-provision at the new
#         ref(s) and update the stored ref/commit metadata;
#       * a Spack environment is built -> fatal, for reproducibility.
#   - A typed ref equal to the stored ref (or no ref typed) is a no-op.
#
# An untyped ref keeps its stored value across a re-provision, so changing only
# --spack does not silently move spack-packages to the latest release.
#
# @param spack_ref    Value typed for --spack (may be empty).
# @param packages_ref Value typed for --spack-packages (may be empty).
# @param ...          Raw argument tokens of this invocation (see
#                     _KNIT_INVOCATION_RAW_ARGS), used to tell a typed option
#                     from a defaulted one.
# @return 0 when Spack was provisioned or re-provisioned, 1 when nothing changed.
# ------------------------------------------------------------------------------
_knit_bootstrap_update_spack() {
    local spack_ref="$1"
    local packages_ref="$2"
    shift 2

    # Not provisioned yet: provision now under the same condition as first
    # bootstrap (a typed ref, or a registered Spack-requiring setup).
    if [[ ! -d "${_KNIT_SPACK_ROOT}" ]]; then
        _knit_bootstrap_need_spack "${spack_ref}" "${packages_ref}" || return 1
        knit_info "Bootstrapping spack..."
        _knit_bootstrap_spack "${spack_ref}" "${packages_ref}"
        return 0
    fi

    # Already provisioned: only a typed ref can change anything.
    local spack_typed="false" packages_typed="false"
    _knit_arg_was_provided "spack" "$@" && spack_typed="true"
    _knit_arg_was_provided "spack-packages" "$@" && packages_typed="true"
    [[ "${spack_typed}" == "false" && "${packages_typed}" == "false" ]] && return 1

    local stored_spack stored_packages
    _knit_metadata_get stored_spack "__spack_ref__"
    _knit_metadata_get stored_packages "__spack_packages_ref__"

    # Effective refs: a typed ref replaces the stored one; an untyped ref keeps
    # the stored value so a re-provision does not move an untouched repo to the
    # latest release.
    local eff_spack="${stored_spack}" eff_packages="${stored_packages}"
    local differs="false"
    if [[ "${spack_typed}" == "true" && "${spack_ref}" != "${stored_spack}" ]]; then
        eff_spack="${spack_ref}"
        differs="true"
    fi
    if [[ "${packages_typed}" == "true" && "${packages_ref}" != "${stored_packages}" ]]; then
        eff_packages="${packages_ref}"
        differs="true"
    fi

    # A typed ref equal to the stored ref is a no-op.
    [[ "${differs}" == "false" ]] && return 1

    # A different ref is refused once any setup has concretized an environment.
    if _knit_bootstrap_spack_env_built; then
        knit_fatal "Cannot change the Spack version: a Spack environment is already built under a setup.\nThe Spack version is frozen for reproducibility once an environment exists."
    fi

    knit_info "Re-provisioning spack..."
    rm -rf "${_KNIT_SPACK_ROOT}" "${_KNIT_SPACK_PACKAGES_ROOT}"
    _knit_bootstrap_spack "${eff_spack}" "${eff_packages}"
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_spack_ensure_provisioned()
#
# Ensure the knit-private Spack is present, provisioning it on demand when it is
# absent. Bootstrap provisions Spack only when a Spack-backed setup was declared
# at bootstrap time (or --spack was given). A setup that gains a knit_with_spack*
# directive *after* bootstrap would otherwise find no Spack and, since bootstrap
# cannot be re-run, force the user to delete and recreate .knit by hand. Instead
# this downloads Spack at first use — the latest release, as an empty --spack
# would — announced with a knit_info line so the one-time delay is not a mystery.
#
# A no-op when Spack is already provisioned. Fatal when the experiment is not
# bootstrapped: there is no .knit to provision into, and _knit_bootstrap_spack's
# provenance writes need the metadata table.
# ------------------------------------------------------------------------------
_knit_spack_ensure_provisioned() {
    [[ -d "${_KNIT_SPACK_ROOT}" ]] && return 0
    if ! _knit_is_bootstrapped; then
        knit_fatal "Spack is required but the experiment is not bootstrapped. Run 'bootstrap' first."
    fi
    knit_info "Spack is required but not provisioned; downloading it now (one-time setup)..."
    _knit_bootstrap_spack "" ""
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

# ------------------------------------------------------------------------------
# @fn _knit_spack_exec()
#
# Run the knit-private Spack, forwarding all arguments verbatim (this is the
# body of the "knit spack" wrapper). Fatal-with-hint if Spack has not been
# provisioned. Spack's setup-env.sh is sourced at most once per process (guarded
# by _KNIT_SPACK_ENV_SOURCED) so that a script calling "knit spack" repeatedly
# pays the sourcing cost only on the first call. Note: we deliberately do not
# 'exec spack' — that would replace the caller's shell and prevent any later
# "knit spack" from running; instead we call the (sourced) spack function and
# return its exit status.
#
# @param ... Arguments forwarded verbatim to spack (including --help).
# @return The exit status of spack.
# ------------------------------------------------------------------------------
_knit_spack_exec() {
    if [[ ! -d "${_KNIT_SPACK_ROOT}" ]]; then
        knit_fatal "Spack is not provisioned in %s. Run 'bootstrap --spack' (optionally with a ref) first." \
            "${_KNIT_SPACK_ROOT}"
    fi
    if [[ -z "${_KNIT_SPACK_ENV_SOURCED}" ]]; then
        # shellcheck disable=SC1091
        source "${_KNIT_SPACK_ROOT}/share/spack/setup-env.sh"
        _KNIT_SPACK_ENV_SOURCED="1"
    fi
    spack "$@"
}

# ------------------------------------------------------------------------------
# @fn _knit_spack_env_install()
#
# Create and install a Spack environment from a manifest. The environment is
# created as a directory ("anonymous") environment at <env-dir> from the given
# spack.yaml, then its specs are installed. Both steps run through
# _knit_spack_exec, so the knit-private Spack is used and setup-env.sh is sourced
# at most once per process. The (long-running) install is framed.
#
# When the profile declares Spack config, "${_KNIT_PREFIX}/spack-config.json"
# exists (the profile's `spack` object wrapped under a top-level `spack` key); it
# is merged into the environment with "spack config add -f" before
# concretization, so specs like "mpi"/"hdf5" resolve to the platform's vendor
# installs and provider preferences apply. The step is skipped when the file is
# absent.
#
# The install runs directly (its stdout/stderr inherit the caller's terminal) so
# Spack's own TTY-aware progress output is shown, rather than piped through a
# frame (which both hid it behind trace level and would defeat Spack's TTY
# detection). Every step is checked: on failure the function logs a knit_error
# and returns non-zero (it does NOT knit_fatal) so the setup dispatcher can
# remove the half-built setup directory and avoid recording it.
#
# @param env_dir Directory in which to create the Spack environment.
# @param yaml    Path to the spack.yaml manifest describing the environment.
# @return 0 if the environment was created and installed, non-zero otherwise.
# ------------------------------------------------------------------------------
_knit_spack_env_install() {
    local env_dir="$1"
    local yaml="$2"
    if ! _knit_spack_exec env create -d "${env_dir}" "${yaml}"; then
        knit_error "Could not create the Spack environment at %s from %s." \
            "${env_dir}" "${yaml}"
        return 1
    fi
    local cfg="${_KNIT_PREFIX}/spack-config.json"
    if [[ -f "${cfg}" ]]; then
        if ! _knit_spack_exec -e "${env_dir}" config add -f "${cfg}"; then
            knit_error "Could not add Spack config (%s) to the Spack environment at %s." \
                "${cfg}" "${env_dir}"
            return 1
        fi
    fi
    if ! _knit_spack_exec -e "${env_dir}" install; then
        knit_error "Spack failed to install the environment at %s." "${env_dir}"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Register the "knit spack" wrapper: forwards every argument verbatim to the
# knit-private Spack. Declaring a table logs each invocation's full command line
# (schema id, args) for provenance.
# ------------------------------------------------------------------------------
knit_register_wrapper "spack" "_knit_spack" \
    "Run the knit-private Spack, forwarding all arguments verbatim."
_knit_is_builtin
knit_with_table
# ------------------------------------------------------------------------------
# @fn _knit_spack()
#
# Body of the "knit spack" wrapper command.
#
# @param ... Arguments forwarded verbatim to spack.
# ------------------------------------------------------------------------------
_knit_spack() {
    _knit_spack_exec "$@"
}
knit_done
