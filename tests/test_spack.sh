#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit

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

@test "latest release resolves the tag from the GitHub releases/latest API" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    curl() { printf '%s' '{"tag_name":"v1.2.0"}'; }
    _knit_jq() { jq "$@"; }

    run _knit_spack_latest_release spack
    [ "$status" -eq 0 ]
    [ "$output" = "v1.2.0" ]
}

@test "latest release is fatal when the API returns no release" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    curl() { printf '%s' '{}'; }
    _knit_jq() { jq "$@"; }

    run _knit_spack_latest_release spack
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not resolve"* ]]
}

# ---------- _knit_spack_resolve_commit ----------

@test "resolve_commit returns the sha from the GitHub commits API" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    curl() { printf '%s' '{"sha":"deadbeef"}'; }
    _knit_jq() { jq "$@"; }

    run _knit_spack_resolve_commit spack "v1.0"
    [ "$status" -eq 0 ]
    [ "$output" = "deadbeef" ]
}

@test "resolve_commit is fatal when the API returns no sha" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    curl() { printf '%s' '{}'; }
    _knit_jq() { jq "$@"; }

    run _knit_spack_resolve_commit spack "nope"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not resolve"* ]]
}

# ---------- _knit_spack_download ----------

@test "download curls the archive tarball then extracts it stripping one level" {
    local -a titles=() cmds=()
    _knit_spack_framed_run() {
        titles+=("$1")
        shift
        cmds+=("$*")
        return 0
    }

    _knit_spack_download spack "${_KNIT_SPACK_ROOT}" "abc123"

    # First call downloads the archive/<sha>.tar.gz with curl.
    [[ "${cmds[0]}" == "curl -L -o "*"https://github.com/spack/spack/archive/abc123.tar.gz" ]]
    # Second call extracts into the destination, stripping the top-level dir.
    [[ "${cmds[1]}" == tar\ -xzf\ *" -C ${_KNIT_SPACK_ROOT} --strip-components=1" ]]
    # The destination is created before extraction.
    [ -d "${_KNIT_SPACK_ROOT}" ]
}

@test "download is fatal when the curl download fails" {
    _knit_spack_framed_run() { return 1; }

    run _knit_spack_download spack "${_KNIT_SPACK_ROOT}" "abc123"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not download"* ]]
}

# ---------- _knit_spack_write_repos_yaml ----------

@test "repos.yaml points the builtin repo at the local spack-packages path" {
    _knit_spack_write_repos_yaml

    local f="${_KNIT_SPACK_ROOT}/etc/spack/repos.yaml"
    [ -f "${f}" ]
    grep -q "builtin: ${_KNIT_SPACK_PACKAGES_ROOT}/repos/spack_repo/builtin" "${f}"
    # The local-path form uses no git so runtime never reaches for it.
    ! grep -q "git:" "${f}"
    ! grep -q "commit:" "${f}"
}

# ---------- _knit_bootstrap_spack (provenance + latest resolution) ----------

# Stub out downloading/repos.yaml and capture the metadata that gets stored.
_stub_provisioning() {
    _knit_spack_download() { :; }
    _knit_spack_write_repos_yaml() { :; }
    # _knit_spack_resolve_commit <repo> <ref>  ->  a per-repo fake commit.
    _knit_spack_resolve_commit() {
        case "$1" in
            spack-packages) printf 'pkgsha' ;;
            *)              printf 'spacksha' ;;
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

# ---------- _knit_spack_ensure_provisioned (on-demand provisioning) ----------

@test "ensure_provisioned is a no-op when spack is already present" {
    mkdir -p "${_KNIT_SPACK_ROOT}"
    _knit_bootstrap_spack() { printf 'PROVISIONED\n'; }
    run _knit_spack_ensure_provisioned
    [ "$status" -eq 0 ]
    [[ "$output" != *"PROVISIONED"* ]]
}

@test "ensure_provisioned provisions the latest release on demand when missing" {
    # setup() leaves _KNIT_SPACK_ROOT pointing at a non-existent directory.
    _knit_bootstrap_spack() { printf 'PROVISIONED %s|%s\n' "$1" "$2"; }
    run _knit_spack_ensure_provisioned
    [ "$status" -eq 0 ]
    [[ "$output" == *"downloading it now"* ]]
    # Called with empty refs, i.e. the latest release, like an empty --spack.
    [[ "$output" == *"PROVISIONED |"* ]]
}

@test "ensure_provisioned is fatal (does not provision) when not bootstrapped" {
    _knit_is_bootstrapped() { return 1; }
    _knit_bootstrap_spack() { printf 'SHOULD_NOT_RUN\n'; }
    run _knit_spack_ensure_provisioned
    [ "$status" -ne 0 ]
    [[ "$output" == *"not bootstrapped"* ]]
    [[ "$output" != *"SHOULD_NOT_RUN"* ]]
}

# ---------- knit spack wrapper (_knit_spack_exec) ----------

# Create a fake provisioned Spack whose setup-env.sh bumps a source counter and
# defines a 'spack' function that echoes its arguments, so tests can assert both
# verbatim forwarding and once-per-process sourcing.
_fake_spack_tree() {
    mkdir -p "${_KNIT_SPACK_ROOT}/share/spack"
    cat > "${_KNIT_SPACK_ROOT}/share/spack/setup-env.sh" <<'EOF'
SPACK_SOURCE_COUNT=$((SPACK_SOURCE_COUNT + 1))
spack() { printf 'spack:%s\n' "$*"; }
EOF
}

@test "knit spack is registered as a wrapper with a table" {
    _knit_command_is_wrapper "spack"
    [ -n "${_KNIT_CMD_spack_table:-}" ]
}

@test "spack_exec is fatal with a hint when spack is not provisioned" {
    # setup() points _KNIT_SPACK_ROOT at a directory that does not exist.
    run _knit_spack_exec find
    [ "$status" -ne 0 ]
    [[ "$output" == *"not provisioned"* ]]
    [[ "$output" == *"bootstrap --spack"* ]]
}

@test "spack_exec forwards its arguments verbatim to spack" {
    _fake_spack_tree
    run _knit_spack_exec install "hdf5@1.14" --fresh
    [ "$status" -eq 0 ]
    [ "$output" = "spack:install hdf5@1.14 --fresh" ]
}

@test "spack_exec forwards --help verbatim" {
    _fake_spack_tree
    run _knit_spack_exec --help
    [ "$status" -eq 0 ]
    [ "$output" = "spack:--help" ]
}

@test "spack_exec sources setup-env.sh only once per process" {
    _fake_spack_tree
    SPACK_SOURCE_COUNT=0
    _KNIT_SPACK_ENV_SOURCED=""
    # Call directly (not via 'run') so the guard flag and counter persist.
    _knit_spack_exec find >/dev/null
    _knit_spack_exec list >/dev/null
    _knit_spack_exec info pkg >/dev/null
    [ "${SPACK_SOURCE_COUNT}" -eq 1 ]
    [ "${_KNIT_SPACK_ENV_SOURCED}" = "1" ]
}

# ---------- _knit_spack_env_install ----------

@test "spack_env_install creates the env then installs its specs" {
    # Install runs directly through _knit_spack_exec (no frame), so the whole
    # env-install writes straight to the terminal.
    _knit_spack_exec() { printf 'exec:%s\n' "$*"; }
    run _knit_spack_env_install "/tmp/envdir" "/tmp/spack.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exec:env create -d /tmp/envdir /tmp/spack.yaml"* ]]
    [[ "$output" == *"exec:-e /tmp/envdir install"* ]]
}

@test "spack_env_install injects packages.yaml before install when present" {
    _knit_spack_exec() { printf 'exec:%s\n' "$*"; }
    printf 'packages:\n' > "${_KNIT_PREFIX}/packages.yaml"
    run _knit_spack_env_install "/tmp/envdir" "/tmp/spack.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exec:-e /tmp/envdir config add -f ${_KNIT_PREFIX}/packages.yaml"* ]]
    # config add must precede install.
    local add_line install_line
    add_line="$(printf '%s\n' "$output" | grep -n 'config add -f' | head -1 | cut -d: -f1)"
    install_line="$(printf '%s\n' "$output" | grep -n -- '-e /tmp/envdir install' | head -1 | cut -d: -f1)"
    [ "${add_line}" -lt "${install_line}" ]
}

@test "spack_env_install skips packages.yaml injection when absent" {
    _knit_spack_exec() { printf 'exec:%s\n' "$*"; }
    run _knit_spack_env_install "/tmp/envdir" "/tmp/spack.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" != *"config add -f"* ]]
}

@test "spack_env_install returns non-zero when 'env create' fails" {
    # Fail only the create step; a real Spack would not reach install.
    _knit_spack_exec() {
        [[ "$1" == "env" && "$2" == "create" ]] && return 3
        printf 'exec:%s\n' "$*"
    }
    run _knit_spack_env_install "/tmp/envdir" "/tmp/spack.yaml"
    [ "$status" -ne 0 ]
    # It must not proceed to install after a failed create.
    [[ "$output" != *"install"* ]]
}

@test "spack_env_install returns non-zero when 'install' fails" {
    _knit_spack_exec() {
        if [[ "$*" == *" install" ]]; then
            return 5
        fi
        printf 'exec:%s\n' "$*"
    }
    run _knit_spack_env_install "/tmp/envdir" "/tmp/spack.yaml"
    [ "$status" -ne 0 ]
    # The env was still created before the install failure.
    [[ "$output" == *"exec:env create -d /tmp/envdir /tmp/spack.yaml"* ]]
}
