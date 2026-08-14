#!/usr/bin/env bats

# Tests for the resource download backends, the shared fetch body's dispatch,
# source identity, immutability (read-only), and cleanup on failure. git/curl/tar
# are stubbed so no network or real VCS is needed.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    _knit_create_metadata_table

    _KNIT_TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
    # A fetched instance is made read-only; restore write so rm can remove it.
    if [[ -n "${_KNIT_TEST_TMPDIR:-}" && -e "${_KNIT_TEST_TMPDIR}" ]]; then
        chmod -R u+w "${_KNIT_TEST_TMPDIR}" 2>/dev/null || true
        rm -rf "${_KNIT_TEST_TMPDIR}"
    fi
    knit_test_db_teardown
}

# True when no file under <dir> (or <dir> itself) carries a write bit.
_is_readonly_tree() {
    local dir="$1"
    local f perms
    while IFS= read -r f; do
        perms=$(stat -c '%A' "${f}")
        [[ "${perms}" == *w* ]] && return 1
    done < <(find "${dir}")
    return 0
}

# ---------- git stub ----------

_stub_git() {
    git() {
        if [[ "$1" == "clone" ]]; then
            # git clone <url> <dest>
            mkdir -p "$3/.git"
            printf 'readme\n' > "$3/README"
            return 0
        fi
        if [[ "$1" == "-C" ]]; then
            # git -C <dest> <verb> ...
            case "$3" in
                rev-parse) printf '%s\n' "${STUB_SHA:-cafef00dcafef00d}" ;;
                *) : ;;   # checkout
            esac
            return 0
        fi
        return 0
    }
}

# ---------- _knit_fetch_git ----------

@test "git backend clones, prints the resolved SHA, and is read-only" {
    _stub_git
    STUB_SHA="1234567890abcdef"
    local dest="${_KNIT_TEST_TMPDIR}/inst"
    run _knit_fetch_git "${dest}" "https://example.org/x.git" "main"
    [ "${status}" -eq 0 ]
    [ "${output}" = "1234567890abcdef" ]
    [ -f "${dest}/README" ]
    _is_readonly_tree "${dest}"
}

@test "git backend fails when git is missing" {
    # Shadow command -v so it reports git as absent, without touching PATH.
    command() {
        if [[ "$1" == "-v" && "$2" == "git" ]]; then return 1; fi
        builtin command "$@"
    }
    run _knit_fetch_git "${_KNIT_TEST_TMPDIR}/inst" "https://example.org/x.git" "main"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"git is required"* ]]
}

# ---------- _knit_fetch_url ----------

@test "url backend downloads the artifact and is read-only" {
    curl() {
        local out=""
        while [[ $# -gt 0 ]]; do
            case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
        done
        printf 'ARCHIVE\n' > "${out}"
    }
    local dest="${_KNIT_TEST_TMPDIR}/inst"
    run _knit_fetch_url "${dest}" "https://example.org/data.tar.gz" "false"
    [ "${status}" -eq 0 ]
    [ -f "${dest}/data.tar.gz" ]
    _is_readonly_tree "${dest}"
}

@test "url backend uncompresses and removes the archive" {
    curl() {
        local out=""
        while [[ $# -gt 0 ]]; do
            case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
        done
        printf 'ARCHIVE\n' > "${out}"
    }
    tar() {
        local dest=""
        while [[ $# -gt 0 ]]; do
            case "$1" in -C) dest="$2"; shift 2 ;; *) shift ;; esac
        done
        mkdir -p "${dest}/extracted"
        printf 'x\n' > "${dest}/extracted/f"
    }
    local dest="${_KNIT_TEST_TMPDIR}/inst"
    run _knit_fetch_url "${dest}" "https://example.org/data.tar.gz" "true"
    [ "${status}" -eq 0 ]
    [ -f "${dest}/extracted/f" ]
    [ ! -e "${dest}/data.tar.gz" ]
    _is_readonly_tree "${dest}"
}

@test "url backend fails when curl fails" {
    curl() { return 22; }
    local dest="${_KNIT_TEST_TMPDIR}/inst"
    run _knit_fetch_url "${dest}" "https://example.org/missing" "false"
    [ "${status}" -ne 0 ]
}

# ---------- _knit_fetch_local ----------

@test "local backend symlinks by default and stays writable" {
    local src="${_KNIT_TEST_TMPDIR}/src"
    mkdir -p "${src}"
    printf 'data\n' > "${src}/file"
    local dest="${_KNIT_TEST_TMPDIR}/inst"
    run _knit_fetch_local "${dest}" "${src}" "false"
    [ "${status}" -eq 0 ]
    [ -L "${dest}" ]
    [ "$(readlink "${dest}")" = "${src}" ]
    # The symlink target is left writable (not made read-only).
    [ -w "${src}/file" ]
}

@test "local backend copies a read-only snapshot with --copy" {
    local src="${_KNIT_TEST_TMPDIR}/src"
    mkdir -p "${src}"
    printf 'data\n' > "${src}/file"
    local dest="${_KNIT_TEST_TMPDIR}/inst"
    run _knit_fetch_local "${dest}" "${src}" "true"
    [ "${status}" -eq 0 ]
    [ ! -L "${dest}" ]
    [ -f "${dest}/file" ]
    _is_readonly_tree "${dest}"
}

@test "local backend fails when the source is missing" {
    run _knit_fetch_local "${_KNIT_TEST_TMPDIR}/inst" "${_KNIT_TEST_TMPDIR}/nope" "false"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"does not exist"* ]]
}

# ---------- _knit_resource_cleanup_dir ----------

@test "cleanup removes a read-only tree" {
    local dir="${_KNIT_TEST_TMPDIR}/inst"
    mkdir -p "${dir}/sub"
    printf 'x\n' > "${dir}/sub/f"
    _knit_resource_make_readonly "${dir}"
    _knit_resource_cleanup_dir "${dir}"
    [ ! -e "${dir}" ]
}

@test "cleanup unlinks a symlink without touching its target" {
    local src="${_KNIT_TEST_TMPDIR}/src"
    mkdir -p "${src}"
    printf 'data\n' > "${src}/file"
    local dir="${_KNIT_TEST_TMPDIR}/inst"
    ln -s "${src}" "${dir}"
    _knit_resource_cleanup_dir "${dir}"
    [ ! -e "${dir}" ]
    [ -f "${src}/file" ]
}

@test "cleanup is a no-op on a missing path" {
    run _knit_resource_cleanup_dir "${_KNIT_TEST_TMPDIR}/nope"
    [ "${status}" -eq 0 ]
}

# ---------- _knit_resource_source_identity ----------

@test "source identity for git uses url and ref" {
    local id
    _knit_resource_source_identity id "git" --url "https://x/a.git" --ref "main"
    [ "${id}" = "git|url=https://x/a.git|ref=main" ]
}

@test "source identity for url uses url and uncompress" {
    local id
    _knit_resource_source_identity id "url" --url "https://x/a.tgz" --uncompress "true"
    [ "${id}" = "url|url=https://x/a.tgz|uncompress=true" ]
}

@test "source identity for local uses path and copy" {
    local id
    _knit_resource_source_identity id "local" --path "/data/x" --copy "false"
    [ "${id}" = "local|path=/data/x|copy=false" ]
}

@test "source identity fails for an unknown method" {
    local id="preset"
    run _knit_resource_source_identity id "bogus"
    [ "${status}" -ne 0 ]
}

# ---------- _knit_resource_fetch_body dispatch ----------

# Register a resource type of the given backend and put its command on the
# executing stack with a fresh output map, so the body can be called directly.
_prep_body() {
    local backend="$1"
    case "${backend}" in
        git)   knit_register_resource "r" "d"; knit_with_git "https://x/a.git" "main"; knit_done ;;
        url)   knit_register_resource "r" "d"; knit_with_url "https://x/a.tgz"; knit_done ;;
        local) knit_register_resource "r" "d"; knit_with_local "/data/x"; knit_done ;;
    esac
    _BODY_CMD=$(_knit_command_mangle "fetch:r")
    _KNIT_EXECUTING_COMMAND=("${_BODY_CMD}")
    declare -gA "_KNIT_CMD_${_BODY_CMD}_output_value=()"
}

@test "fetch body dispatches to git and records the commit output" {
    _stub_git
    STUB_SHA="feedfacefeedface"
    _prep_body git
    export KNIT_RESOURCE_PREFIX="${_KNIT_TEST_TMPDIR}/inst"
    _knit_resource_fetch_body --url "https://x/a.git" --ref "main"
    [ -f "${KNIT_RESOURCE_PREFIX}/README" ]
    local -n _ov="_KNIT_CMD_${_BODY_CMD}_output_value"
    [ "${_ov[commit]}" = "feedfacefeedface" ]
}

@test "fetch body dispatches to local (symlink)" {
    local src="${_KNIT_TEST_TMPDIR}/src"
    mkdir -p "${src}"; printf 'd\n' > "${src}/f"
    _prep_body local
    export KNIT_RESOURCE_PREFIX="${_KNIT_TEST_TMPDIR}/inst"
    _knit_resource_fetch_body --path "${src}" --copy "false"
    [ -L "${KNIT_RESOURCE_PREFIX}" ]
}

@test "fetch body cleans up and fails when the backend fails" {
    curl() { return 22; }
    _prep_body url
    export KNIT_RESOURCE_PREFIX="${_KNIT_TEST_TMPDIR}/inst"
    run _knit_resource_fetch_body --url "https://x/missing" --uncompress "false"
    [ "${status}" -ne 0 ]
    [ ! -e "${KNIT_RESOURCE_PREFIX}" ]
}

@test "fetch body fatals when invoked without KNIT_RESOURCE_PREFIX" {
    _prep_body git
    unset KNIT_RESOURCE_PREFIX
    run _knit_resource_fetch_body --url "https://x/a.git" --ref "main"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"knit fetch"* ]]
}
