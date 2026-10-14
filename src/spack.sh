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
# @fn _knit_spack_latest_release()
#
# Resolve the latest release tag of a Spack repository via the GitHub API. Used
# when the user did not pin a ref: knit provisions the newest published release.
#
# @param[in] repo Repository name under the spack org ("spack" or "spack-packages").
# @return Prints the newest release tag; fatal if none can be resolved.
# ------------------------------------------------------------------------------
_knit_spack_latest_release() {
    local repo="$1"
    local url="https://api.github.com/repos/spack/${repo}/releases/latest"
    local tag
    tag="$(_knit_github_api "${url}" | _knit_jq -r '.tag_name // empty')"
    if [[ -z "${tag}" ]]; then
        knit_fatal "Could not resolve the latest ${repo} release from ${url}." \
            "If this is a rate-limited environment, set GITHUB_TOKEN."
    fi
    printf '%s' "${tag}"
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
# @fn _knit_spack_provision()
#
# Provision verb (knit_env_provision) for the Spack environment manager: resolve
# refs (latest release when empty) to exact commits, download and extract Spack
# and spack-packages with curl+tar, write a local-path repos.yaml, and record
# provenance metadata (requested refs and resolved commits). No git dependency.
#
# It removes any existing Spack roots first so it is safe to re-run (the generic
# update dispatcher removes only .knit/spack; spack-packages is this verb's own
# directory to clean). On first bootstrap both roots are absent and the removal
# is a no-op.
#
# The requested refs are stored under the metadata keys __spack_ref__ /
# __spack_packages_ref__ (the __<opt>_ref__ convention the generic update
# dispatcher reads).
#
# @param[in] spack_ref Spack ref (tag/branch/commit); empty uses the latest release.
# @param[in] packages_ref spack-packages ref; empty uses the latest release.
# ------------------------------------------------------------------------------
_knit_spack_provision() {
    local spack_ref="${1:-}"
    local packages_ref="${2:-}"

    rm -rf "${_KNIT_SPACK_ROOT}" "${_KNIT_SPACK_PACKAGES_ROOT}"

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
    spack_commit="$(_knit_github_resolve_commit spack spack "${spack_ref}")"
    packages_commit="$(_knit_github_resolve_commit spack spack-packages "${packages_ref}")"

    # The tarball sha256 is unused here (Spack provenance tracks the commit, not
    # the archive checksum); _knit_github_download requires the output nameref.
    # shellcheck disable=SC2034 # required-but-unused nameref outputs of _knit_github_download
    local spack_sha256 packages_sha256
    _knit_github_download spack_sha256 _knit_framed_run \
        spack spack "${_KNIT_SPACK_ROOT}" "${spack_commit}"
    _knit_github_download packages_sha256 _knit_framed_run \
        spack spack-packages "${_KNIT_SPACK_PACKAGES_ROOT}" "${packages_commit}"

    _knit_spack_write_repos_yaml

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
# @param[in] ... Specs to install.
# ------------------------------------------------------------------------------
_knit_spack_install() {
    (
        # shellcheck disable=SC1091
        source "${_KNIT_SPACK_ROOT}/share/spack/setup-env.sh"
        local spec
        for spec in "$@"; do
            knit_info "Installing package ${spec}..."
            _knit_framed_run "spack: install ${spec}" spack install "${spec}"
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
# @param[in] ... Arguments forwarded verbatim to spack (including --help).
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
# @fn _knit_spack_install_env()
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
# @param[in] env_dir Directory in which to create the Spack environment.
# @param[in] yaml    Path to the spack.yaml manifest describing the environment.
# @return 0 if the environment was created and installed, non-zero otherwise.
# ------------------------------------------------------------------------------
_knit_spack_install_env() {
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
# @fn _knit_spack_activation()
#
# Activate verb (knit_env_activate) for the Spack environment manager: print the
# shell lines that re-enter the Spack environment at <env_dir> — source Spack's
# setup-env.sh (which defines the "spack" shell function) and activate the
# directory environment. The generic layer both eval-s these in the setup's
# build shell and appends them to the setup's .activate.sh for dependent jobs.
#
# @param[in] env_dir Directory of the built Spack environment.
# ------------------------------------------------------------------------------
_knit_spack_activation() {
    local env_dir="$1"
    printf 'source %q\n' "${_KNIT_SPACK_ROOT}/share/spack/setup-env.sh"
    printf 'spack env activate -d %q\n' "${env_dir}"
}

# ------------------------------------------------------------------------------
# @fn _knit_spack_specs_to_manifest()
#
# Specs verb (knit_env_specs) for the Spack environment manager: synthesize a
# minimal spack.yaml (the given specs plus "view: true") from a spec list, for
# the knit_with_spack_specs sugar. Printed to stdout; the generic layer feeds it
# to knit_with_spack_env.
#
# @param[in] ... One or more Spack specs.
# ------------------------------------------------------------------------------
_knit_spack_specs_to_manifest() {
    local yaml spec
    yaml=$'spack:\n  specs:\n'
    for spec in "$@"; do
        yaml+="    - ${spec}"$'\n'
    done
    yaml+=$'  view: true\n'
    printf '%s' "${yaml}"
}

# ------------------------------------------------------------------------------
# Register Spack as an environment manager (src/env.sh). This generates the
# knit_with_spack_env / knit_with_spack_specs setup directives, declares the
# --spack / --spack-packages bootstrap options (via knit_extend bootstrap), and
# routes provisioning, update-mode re-provisioning, the freeze-on-built rule, and
# manifest/lockfile provenance through the generic layer.
# ------------------------------------------------------------------------------
knit_register_env_manager "spack" "Spack environments."
knit_env_provision _knit_spack_provision --options "spack:string,spack-packages:string"
knit_env_install   _knit_spack_install_env
knit_env_activate  _knit_spack_activation
knit_env_specs     _knit_spack_specs_to_manifest
knit_env_manifest  "spack.yaml"
knit_env_lockfile  "spack.lock"
knit_env_done

# ------------------------------------------------------------------------------
# Register the "knit spack" wrapper: forwards every argument verbatim to the
# knit-private Spack. Declaring a table logs each invocation's full command line
# (schema id, args) for provenance.
# ------------------------------------------------------------------------------
knit_register_wrapper "spack" "_knit_spack_exec" \
    "Run the knit-private Spack, forwarding all arguments verbatim."
_knit_is_builtin
knit_with_table
knit_done
