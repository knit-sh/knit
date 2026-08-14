#!/usr/bin/env bats

# Tests for the `knit fetch` dispatcher (_knit_fetch): name validation, unknown
# type, idempotent skip, conflicting-source fatal, sidecar markers, the per-name
# lock, cleanup on a failed download, --ignore-checksum threading, and the
# recorded row (name / directory / commit). The local backend is used for the
# no-network cases; git is stubbed where a commit is needed. The dispatcher body
# is called directly (as tests/test_resource_fetch.sh calls the download body),
# with the bootstrapped test database so rows are recorded.

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

    # A real local source for the symlink backend.
    _SRC="${_KNIT_TEST_TMPDIR}/src"
    mkdir -p "${_SRC}"
    printf 'data\n' > "${_SRC}/file"
}

teardown() {
    if [[ -n "${_KNIT_TEST_TMPDIR:-}" && -e "${_KNIT_TEST_TMPDIR}" ]]; then
        chmod -R u+w "${_KNIT_TEST_TMPDIR}" 2>/dev/null || true
        rm -rf "${_KNIT_TEST_TMPDIR}"
    fi
    knit_test_db_teardown
}

# Register a local resource type "ds" whose default source is <_SRC>.
_register_local() {
    knit_register_resource "ds" "A local dataset."
    knit_with_local "${_SRC}"
    knit_done
}

# git stub: `git clone <url> <dest>` creates a tree; `git -C <dest> rev-parse`
# prints STUB_SHA. Mirrors tests/test_resource_fetch.sh.
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

# ---------- name / type validation ----------

@test "fetch validates the instance name" {
    _register_local
    run _knit_fetch --name "a/b" -- ds
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Invalid name"* ]]
}

@test "fetch rejects an unknown resource type" {
    _register_local
    run _knit_fetch --name good -- nope
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Unknown resource type"* ]]
}

@test "fetch requires a resource type after --" {
    _register_local
    run _knit_fetch --name good
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"requires a resource type"* ]]
}

# ---------- materialization + markers + printed path ----------

@test "fetch materializes the instance and prints its path" {
    _register_local
    run _knit_fetch --name ds1 -- ds
    [ "${status}" -eq 0 ]
    local path="${_KNIT_TEST_TMPDIR}/resources/ds1"
    [ "${output}" = "${path}" ]
    [ -L "${path}" ]
    [ "$(readlink "${path}")" = "${_SRC}" ]
}

@test "fetch writes type and source sidecar markers beside the instance" {
    _register_local
    _knit_fetch --name ds1 -- ds
    local root="${_KNIT_TEST_TMPDIR}/resources"
    [ -f "${root}/.ds1.resource.type" ]
    [ -f "${root}/.ds1.resource.source" ]
    [ "$(cat "${root}/.ds1.resource.type")" = "ds" ]
    [ "$(cat "${root}/.ds1.resource.source")" = "local|path=${_SRC}|copy=false" ]
}

@test "fetch takes a per-name lock file under .knit" {
    _register_local
    _knit_fetch --name ds1 -- ds
    [ -f "${_KNIT_PREFIX}/fetch-ds1.lock" ]
}

# ---------- idempotency / conflict ----------

@test "fetch is idempotent for a matching source" {
    _register_local
    _knit_fetch --name ds1 -- ds
    run _knit_fetch --name ds1 -- ds
    [ "${status}" -eq 0 ]
    [ "${output}" = "${_KNIT_TEST_TMPDIR}/resources/ds1" ]
}

@test "fetch fatals on a conflicting source for the same name" {
    _register_local
    _knit_fetch --name ds1 -- ds --path "${_SRC}"
    local other="${_KNIT_TEST_TMPDIR}/other"
    run _knit_fetch --name ds1 -- ds --path "${other}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"different source"* ]]
}

# ---------- failure cleanup ----------

@test "fetch cleans up and fatals when the download fails" {
    _register_local
    local missing="${_KNIT_TEST_TMPDIR}/missing"
    run _knit_fetch --name ds1 -- ds --path "${missing}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"failed"* ]]
    [ ! -e "${_KNIT_TEST_TMPDIR}/resources/ds1" ]
    # A failed download leaves no row (the partial instance is removed).
    [ "$(_knit_sqlite3 'SELECT COUNT(*) FROM "resource:ds";')" = "0" ]
}

# ---------- --ignore-checksum threading ----------

@test "fetch threads --ignore-checksum to the backend env" {
    _register_local
    _knit_fetch --name ds1 --ignore-checksum true -- ds
    [ "${KNIT_IGNORE_CHECKSUM}" = "true" ]
}

# ---------- recorded row ----------

@test "fetch records the row with name and directory" {
    _register_local
    _knit_fetch --name ds1 -- ds
    local path="${_KNIT_TEST_TMPDIR}/resources/ds1"
    [ "$(_knit_sqlite3 'SELECT name FROM "resource:ds";')" = "ds1" ]
    [ "$(_knit_sqlite3 'SELECT directory FROM "resource:ds";')" = "${path}" ]
    [ "$(_knit_sqlite3 'SELECT path FROM "resource:ds";')" = "${_SRC}" ]
    # The row id is mirrored to the .id sidecar for the used_by edge.
    [ -f "${_KNIT_TEST_TMPDIR}/resources/.ds1.resource.id" ]
}

@test "fetch records the resolved commit for a git resource" {
    _stub_git
    STUB_SHA="1234567890abcdef"
    knit_register_resource "code" "Some source."
    knit_with_git "https://example.org/x.git" "main"
    knit_done
    _knit_fetch --name src1 -- code
    [ "$(_knit_sqlite3 'SELECT "commit" FROM "resource:code";')" = "1234567890abcdef" ]
    [ "$(_knit_sqlite3 'SELECT name FROM "resource:code";')" = "src1" ]
}
