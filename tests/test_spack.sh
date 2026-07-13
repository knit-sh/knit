#!/usr/bin/env bats

setup() {
    source knit.sh

    __TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${__TEST_TMPDIR}/fake-knit"
    mkdir -p "${_KNIT_PREFIX}"
    _KNIT_SPACK_ROOT="${_KNIT_PREFIX}/spack"
    _KNIT_SPACK_PACKAGES_ROOT="${_KNIT_PREFIX}/spack-packages"
    _KNIT_SPACK_REQUIRED=""
    # The provisioning helpers assume a bootstrapped experiment (metadata store).
    _KNIT_IS_BOOTSTRAPPED="1"
}

teardown() {
    rm -rf "${__TEST_TMPDIR}"
    _KNIT_SPACK_REQUIRED=""
    _KNIT_IS_BOOTSTRAPPED=""
}

# ---------- _knit_bootstrap_need_spack (trigger matrix) ----------

@test "need_spack is false with empty refs and no declared spack env" {
    run _knit_bootstrap_need_spack "" ""
    [ "$status" -ne 0 ]
}

@test "need_spack is true when --spack ref is given" {
    run _knit_bootstrap_need_spack "v1.0.0" ""
    [ "$status" -eq 0 ]
}

@test "need_spack is true when --spack-packages ref is given" {
    run _knit_bootstrap_need_spack "" "v1.0.0"
    [ "$status" -eq 0 ]
}

@test "need_spack is true when a setup declared a spack env" {
    _KNIT_SPACK_REQUIRED="1"
    run _knit_bootstrap_need_spack "" ""
    [ "$status" -eq 0 ]
}

# ---------- _knit_spack_latest_release ----------

@test "latest release resolves the newest tag from the GitHub API" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    curl() { printf '%s' '[{"tag_name":"v1.2.0"},{"tag_name":"v1.1.0"}]'; }
    _knit_jq() { jq "$@"; }

    run _knit_spack_latest_release spack
    [ "$status" -eq 0 ]
    [ "$output" = "v1.2.0" ]
}

@test "latest release is fatal when the API returns no releases" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    curl() { printf '%s' '[]'; }
    _knit_jq() { jq "$@"; }

    run _knit_spack_latest_release spack
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not resolve"* ]]
}

# ---------- _knit_spack_clone ----------

@test "clone uses a shallow --branch clone for a tag or branch" {
    local captured=""
    _knit_spack_framed_run() { shift; captured="$*"; return 0; }

    _knit_spack_clone "https://example/repo.git" "${_KNIT_SPACK_ROOT}" "v1.0"

    [ "${captured}" = "git clone --depth 1 --branch v1.0 https://example/repo.git ${_KNIT_SPACK_ROOT}" ]
}

@test "clone falls back to init+fetch+checkout for a commit SHA" {
    local last_title=""
    _knit_spack_framed_run() {
        last_title="$1"
        shift
        # Simulate --branch rejecting a commit SHA, then a successful fetch.
        [[ "$1 $2" == "git clone" ]] && return 1
        return 0
    }
    git() { :; }   # init / remote add / checkout no-ops

    _knit_spack_clone "https://example/repo.git" "${_KNIT_SPACK_ROOT}" "abc123"

    [ "${last_title}" = "spack: fetch abc123" ]
}

@test "clone is fatal when a commit SHA cannot be fetched" {
    _knit_spack_framed_run() { return 1; }   # both clone and fetch fail
    git() { :; }

    run _knit_spack_clone "https://example/repo.git" "${_KNIT_SPACK_ROOT}" "abc123"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not fetch"* ]]
}

# ---------- _knit_spack_write_repos_yaml ----------

@test "repos.yaml pins the spack-packages destination and commit" {
    _knit_spack_write_repos_yaml "deadbeef"

    local f="${_KNIT_SPACK_ROOT}/etc/spack/repos.yaml"
    [ -f "${f}" ]
    grep -q "git: https://github.com/spack/spack-packages.git" "${f}"
    grep -q "destination: ${_KNIT_SPACK_PACKAGES_ROOT}" "${f}"
    grep -q "commit: deadbeef" "${f}"
}

# ---------- _knit_bootstrap_spack (provenance + latest resolution) ----------

# Stub out cloning/repos.yaml and capture the metadata that gets stored.
_stub_provisioning() {
    _knit_spack_clone() { :; }
    _knit_spack_write_repos_yaml() { :; }
    # git -C <dir> rev-parse HEAD  ->  a per-repo fake commit.
    git() {
        case "$2" in
            *spack-packages) printf 'pkgsha' ;;
            *)               printf 'spacksha' ;;
        esac
    }
    METALOG="${__TEST_TMPDIR}/meta"
    : > "${METALOG}"
    knit() {
        [[ "$1 $2" == "metadata store" ]] || return 0
        shift 2
        local key="" val=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --key)   key="$2";   shift 2 ;;
                --value) val="$2";   shift 2 ;;
                *)       shift ;;
            esac
        done
        printf '%s=%s\n' "${key}" "${val}" >> "${METALOG}"
    }
}

@test "bootstrap_spack resolves the latest release when refs are empty" {
    _stub_provisioning
    _knit_spack_latest_release() {
        case "$1" in
            spack)          printf 'v9.9.9' ;;
            spack-packages) printf 'v8.8.8' ;;
        esac
    }

    _knit_bootstrap_spack "" ""

    grep -q "__spack_ref__=v9.9.9" "${METALOG}"
    grep -q "__spack_commit__=spacksha" "${METALOG}"
    grep -q "__spack_packages_ref__=v8.8.8" "${METALOG}"
    grep -q "__spack_packages_commit__=pkgsha" "${METALOG}"
}

@test "bootstrap_spack uses explicit refs and skips latest resolution" {
    _stub_provisioning
    _knit_spack_latest_release() { printf 'SHOULD_NOT_BE_CALLED'; }

    _knit_bootstrap_spack "myref" "mypkgref"

    grep -q "__spack_ref__=myref" "${METALOG}"
    grep -q "__spack_packages_ref__=mypkgref" "${METALOG}"
    ! grep -q "SHOULD_NOT_BE_CALLED" "${METALOG}"
}
