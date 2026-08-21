#!/usr/bin/env bats

# Tests for resource checksum verification (M5): the sha256 helpers
# (_knit_sha256 / _knit_resource_check_sha), the "defaults still used"
# gate (_knit_resource_defaults_used), the url/local/git verification paths, and
# the dispatcher requirements — a mismatch is fatal, removes the partial instance,
# and leaves no row, while --ignore-checksum and an overridden source bypass the
# pin. git/curl are stubbed so no network is needed.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    _knit_create_metadata_table

    # Experiment root = the directory containing .knit; resources default to
    # <root>/resources and the per-name lock lives under .knit.
    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"

    # A single-file source and a directory source for the local backend.
    _FILE="${_KNIT_TEST_TMPDIR}/one.txt"
    printf 'hello\n' > "${_FILE}"
    _DIR="${_KNIT_TEST_TMPDIR}/tree"
    mkdir -p "${_DIR}/sub"
    printf 'a\n' > "${_DIR}/a"
    printf 'b\n' > "${_DIR}/sub/b"
}

teardown() {
    # A copied/downloaded instance is made read-only; restore write so rm works.
    if [[ -n "${_KNIT_TEST_TMPDIR:-}" && -e "${_KNIT_TEST_TMPDIR}" ]]; then
        chmod -R u+w "${_KNIT_TEST_TMPDIR}" 2>/dev/null || true
        rm -rf "${_KNIT_TEST_TMPDIR}"
    fi
    knit_test_db_teardown
}

_stub_git() {
    git() {
        if [[ "$1" == "clone" ]]; then
            mkdir -p "$3/.git"; printf 'readme\n' > "$3/README"; return 0
        fi
        if [[ "$1" == "-C" ]]; then
            case "$3" in
                rev-parse) printf '%s\n' "${STUB_SHA:-cafef00d}" ;;
                *) : ;;
            esac
            return 0
        fi
        return 0
    }
}

# ---------- _knit_sha256 ----------

@test "sha256 of a file matches sha256sum" {
    local got want
    _knit_sha256 got "${_FILE}"
    want=$(sha256sum "${_FILE}"); want="${want%% *}"
    [ "${got}" = "${want}" ]
}

@test "sha256 of a directory is stable and content-sensitive" {
    local first second
    _knit_sha256 first "${_DIR}"
    _knit_sha256 second "${_DIR}"
    [ -n "${first}" ]
    [ "${first}" = "${second}" ]
    printf 'changed\n' > "${_DIR}/sub/b"
    local third
    _knit_sha256 third "${_DIR}"
    [ "${first}" != "${third}" ]
}

@test "sha256 fails when sha256sum is unavailable" {
    command() {
        if [[ "$1" == "-v" && "$2" == "sha256sum" ]]; then return 1; fi
        builtin command "$@"
    }
    local got
    run _knit_sha256 got "${_FILE}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"sha256sum is required"* ]]
}

# ---------- _knit_resource_check_sha ----------

@test "check_sha matches case-insensitively and reports a mismatch" {
    run _knit_resource_check_sha "ABCD" "abcd" "thing"
    [ "${status}" -eq 0 ]
    run _knit_resource_check_sha "abcd" " effff" "thing"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Checksum mismatch for thing"* ]]
}

# ---------- _knit_resource_defaults_used ----------

@test "defaults_used is true only when the source is unchanged" {
    knit_register_resource "g" "d"
    knit_with_git "https://x/a.git" "main"
    knit_done
    local cmd; cmd=$(_knit_command_mangle "fetch:g")
    run _knit_resource_defaults_used "${cmd}" git --url "https://x/a.git" --ref "main"
    [ "${status}" -eq 0 ]
    run _knit_resource_defaults_used "${cmd}" git --url "https://x/other.git" --ref "main"
    [ "${status}" -ne 0 ]
    run _knit_resource_defaults_used "${cmd}" git --url "https://x/a.git" --ref "dev"
    [ "${status}" -ne 0 ]
}

# ---------- url backend verification ----------

_stub_curl_archive() {
    # curl writes a fixed archive body so its sha256 is deterministic.
    curl() {
        local out=""
        while [[ $# -gt 0 ]]; do
            case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
        done
        printf 'ARCHIVE\n' > "${out}"
    }
}

@test "url backend accepts a matching archive checksum and rejects a wrong one" {
    _stub_curl_archive
    local want; want=$(printf 'ARCHIVE\n' | sha256sum); want="${want%% *}"
    local dest="${_KNIT_TEST_TMPDIR}/inst"
    run _knit_fetch_url "${dest}" "https://x/data.bin" "false" "${want}"
    [ "${status}" -eq 0 ]

    chmod -R u+w "${dest}" 2>/dev/null || true; rm -rf "${dest}"
    run _knit_fetch_url "${dest}" "https://x/data.bin" "false" "deadbeef"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Checksum mismatch"* ]]
}

# ---------- local backend verification ----------

@test "local backend verifies a file checksum (match and mismatch)" {
    local want; want=$(sha256sum "${_FILE}"); want="${want%% *}"
    local dest="${_KNIT_TEST_TMPDIR}/inst"
    run _knit_fetch_local "${dest}" "${_FILE}" "false" "${want}"
    [ "${status}" -eq 0 ]
    rm -f "${dest}"
    run _knit_fetch_local "${dest}" "${_FILE}" "false" "deadbeef"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Checksum mismatch"* ]]
}

@test "local backend verifies a directory digest" {
    local want; _knit_sha256 want "${_DIR}"
    local dest="${_KNIT_TEST_TMPDIR}/inst"
    run _knit_fetch_local "${dest}" "${_DIR}" "true" "${want}"
    [ "${status}" -eq 0 ]
    chmod -R u+w "${dest}" 2>/dev/null || true; rm -rf "${dest}"
    run _knit_fetch_local "${dest}" "${_DIR}" "true" "deadbeef"
    [ "${status}" -ne 0 ]
}

# ---------- dispatcher: git commit double-check ----------

@test "fetch verifies the git commit against the pin" {
    _stub_git
    STUB_SHA="1234567890abcdef"
    knit_register_resource "code" "s"
    knit_with_git "https://x/a.git" "main"
    knit_with_checksum "1234567890abcdef"
    knit_done
    _knit_fetch --name ok -- code
    [ -d "${_KNIT_TEST_TMPDIR}/resources/ok" ]
}

@test "fetch fatals, cleans up, and records no row on a git checksum mismatch" {
    _stub_git
    STUB_SHA="1234567890abcdef"
    knit_register_resource "code" "s"
    knit_with_git "https://x/a.git" "main"
    knit_with_checksum "00000000deadbeef"
    knit_done
    run _knit_fetch --name bad -- code
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Checksum mismatch"* ]] || [[ "${output}" == *"failed"* ]]
    [ ! -e "${_KNIT_TEST_TMPDIR}/resources/bad" ]
    [ "$(_knit_sqlite3 'SELECT COUNT(*) FROM "resource:code";')" = "0" ]
}

# ---------- dispatcher: local, plus the bypass paths ----------

@test "fetch records no row on a local checksum mismatch" {
    knit_register_resource "ds" "d"
    knit_with_local "${_FILE}"
    knit_with_checksum "deadbeef"
    knit_done
    run _knit_fetch --name m -- ds
    [ "${status}" -ne 0 ]
    [ ! -e "${_KNIT_TEST_TMPDIR}/resources/m" ]
    [ "$(_knit_sqlite3 'SELECT COUNT(*) FROM "resource:ds";')" = "0" ]
}

@test "fetch succeeds when the local checksum matches" {
    local want; want=$(sha256sum "${_FILE}"); want="${want%% *}"
    knit_register_resource "ds" "d"
    knit_with_local "${_FILE}"
    knit_with_checksum "${want}"
    knit_done
    _knit_fetch --name good -- ds
    [ -e "${_KNIT_TEST_TMPDIR}/resources/good" ]
    [ "$(_knit_sqlite3 'SELECT COUNT(*) FROM "resource:ds";')" = "1" ]
}

@test "--ignore-checksum bypasses a mismatching pin" {
    knit_register_resource "ds" "d"
    knit_with_local "${_FILE}"
    knit_with_checksum "deadbeef"
    knit_done
    _knit_fetch --name skip --ignore-checksum true -- ds
    [ -e "${_KNIT_TEST_TMPDIR}/resources/skip" ]
}

@test "overriding the default source bypasses the pin" {
    local other="${_KNIT_TEST_TMPDIR}/other.txt"
    printf 'world\n' > "${other}"
    knit_register_resource "ds" "d"
    knit_with_local "${_FILE}"
    knit_with_checksum "deadbeef"
    knit_done
    # --path overrides the pinned default, so the pin no longer applies.
    _knit_fetch --name over -- ds --path "${other}"
    [ -e "${_KNIT_TEST_TMPDIR}/resources/over" ]
}
