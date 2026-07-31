#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup

    _KNIT_JQ_EXE="jq"
    _KNIT_TEST_TMPDIR="$(mktemp -d)"

    _knit_create_metadata_table

    # Isolate the admin-profile lookup from the real /etc/knit.
    _KNIT_PROFILE_ADMIN_DIR="${_KNIT_TEST_TMPDIR}/etc"
    mkdir -p "${_KNIT_PROFILE_ADMIN_DIR}"

    # A minimal, valid profile used across the resolution tests.
    _SAMPLE_PROFILE='{"scheduler":{"type":"slurm"},"launcher":{"type":"openmpi"}}'
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    knit_test_db_teardown
}

# A stub for the network primitive: serves _STUB_BODY and records the requested
# URL both in _STUB_URL and in a file (so it survives bats 'run' subshells).
_stub_http_ok() {
    _STUB_BODY="${1:-${_SAMPLE_PROFILE}}"
    # shellcheck disable=SC2317 # invoked indirectly after redefinition
    _knit_profile_http_get() {
        local -n __r=$1
        _STUB_URL="$2"
        printf '%s' "$2" > "${_KNIT_TEST_TMPDIR}/last_url"
        _KNIT_PROFILE_LAST_HTTP="200"
        __r="${_STUB_BODY}"
        return 0
    }
}

_stub_http_fail() {
    # shellcheck disable=SC2317 # invoked indirectly after redefinition
    _knit_profile_http_get() {
        _STUB_URL="$2"
        printf '%s' "$2" > "${_KNIT_TEST_TMPDIR}/last_url"
        _KNIT_PROFILE_LAST_HTTP="404"
        return 1
    }
}

# ---------- _knit_resolve_profile : URL ----------

@test "resolve fetches a URL spec verbatim" {
    _stub_http_ok
    local json ref
    _knit_resolve_profile json ref "https://example.com/x.json"
    [ "${json}" = "${_SAMPLE_PROFILE}" ]
    [ "${ref}" = "https://example.com/x.json" ]
    [ "${_STUB_URL}" = "https://example.com/x.json" ]
}

@test "resolve fatals when a URL cannot be fetched" {
    _stub_http_fail
    run _knit_resolve_profile json ref "https://example.com/missing.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"HTTP 404"* ]]
}

# ---------- _knit_resolve_profile : local file ----------

@test "resolve reads an existing local file" {
    local f="${_KNIT_TEST_TMPDIR}/mymachine.json"
    printf '%s' "${_SAMPLE_PROFILE}" > "${f}"
    local json ref
    _knit_resolve_profile json ref "${f}"
    [ "${json}" = "${_SAMPLE_PROFILE}" ]
    [ "${ref}" = "${f}" ]
}

@test "resolve appends .json when looking for a local file" {
    local base="${_KNIT_TEST_TMPDIR}/mymachine"
    printf '%s' "${_SAMPLE_PROFILE}" > "${base}.json"
    local json ref
    _knit_resolve_profile json ref "${base}"
    [ "${json}" = "${_SAMPLE_PROFILE}" ]
    [ "${ref}" = "${base}.json" ]
}

# ---------- _knit_resolve_profile : admin /etc/knit ----------

@test "resolve reads an admin profile" {
    mkdir -p "${_KNIT_PROFILE_ADMIN_DIR}/ornl"
    printf '%s' "${_SAMPLE_PROFILE}" > "${_KNIT_PROFILE_ADMIN_DIR}/ornl/frontier.json"
    _stub_http_fail   # ensure GitHub is not what answered
    local json ref
    _knit_resolve_profile json ref "ornl/frontier"
    [ "${json}" = "${_SAMPLE_PROFILE}" ]
    [ "${ref}" = "${_KNIT_PROFILE_ADMIN_DIR}/ornl/frontier.json" ]
}

@test "an admin profile shadows the GitHub store" {
    mkdir -p "${_KNIT_PROFILE_ADMIN_DIR}/anl"
    printf '%s' '{"admin":true}' > "${_KNIT_PROFILE_ADMIN_DIR}/anl/improv.json"
    _stub_http_ok '{"github":true}'
    local json ref
    _knit_resolve_profile json ref "anl/improv"
    [ "${json}" = '{"admin":true}' ]
    [[ "${ref}" == *"/anl/improv.json" ]]
}

# ---------- _knit_resolve_profile : GitHub shorthand ----------

@test "resolve shorthand defaults the ref to the knit version" {
    _stub_http_ok
    local json ref
    _knit_resolve_profile json ref "anl/polaris"
    [ "${json}" = "${_SAMPLE_PROFILE}" ]
    [[ "${_STUB_URL}" == *"/${KNIT_VERSION}/src/profiles/anl/polaris.json" ]]
    [ "${ref}" = "anl/polaris@${KNIT_VERSION}" ]
}

@test "resolve shorthand honours an explicit @ref" {
    _stub_http_ok
    local json ref
    _knit_resolve_profile json ref "anl/polaris@v1.2.3"
    [[ "${_STUB_URL}" == *"/v1.2.3/src/profiles/anl/polaris.json" ]]
    [ "${ref}" = "anl/polaris@v1.2.3" ]
}

@test "resolve shorthand @latest resolves via the releases API" {
    _stub_http_ok
    # shellcheck disable=SC2317 # invoked indirectly after redefinition
    _knit_profile_latest_ref() { printf 'v9.9.9'; }
    local json ref
    _knit_resolve_profile json ref "anl/polaris@latest"
    [[ "${_STUB_URL}" == *"/v9.9.9/src/profiles/anl/polaris.json" ]]
    [ "${ref}" = "anl/polaris@v9.9.9" ]
}

# ---------- _knit_resolve_profile : not found ----------

@test "resolve fatals and enumerates the sources tried" {
    _stub_http_fail
    run _knit_resolve_profile json ref "anl/nope"
    [ "$status" -ne 0 ]
    [[ "$output" == *"anl/nope"* ]]
    [[ "$output" == *"no file"* ]]
    [[ "$output" == *"${_KNIT_PROFILE_ADMIN_DIR}"* ]]
    [[ "$output" == *"HTTP 404"* ]]
}

@test "resolve reports a non-shorthand spec that matched nothing" {
    _stub_http_fail
    run _knit_resolve_profile json ref "weird spec"
    [ "$status" -ne 0 ]
    [[ "$output" == *"shorthand"* ]]
}

# ---------- knit_get_profile_field ----------

@test "knit_get_profile_field reads the frozen profile JSON" {
    _knit_metadata_store --key "__profile_json__" \
        --value '{"scheduler":{"default_queue":"prod"}}'
    [ "$(knit_get_profile_field '.scheduler.default_queue')" = "prod" ]
}

@test "knit_get_profile_field is empty when no profile is configured" {
    [ -z "$(knit_get_profile_field '.scheduler.default_queue')" ]
}

@test "knit_get_profile_field is empty for an absent field" {
    _knit_metadata_store --key "__profile_json__" --value '{"scheduler":{}}'
    [ -z "$(knit_get_profile_field '.scheduler.default_queue')" ]
}

# ---------- index parsing / listing ----------

@test "_knit_profile_parse_index extracts one entry per line" {
    local out
    _knit_profile_parse_index out '["anl/aurora","anl/improv","ornl/frontier"]'
    [ "${out}" = $'anl/aurora\nanl/improv\nornl/frontier' ]
}

@test "knit_list_profiles fetches and sorts the index" {
    _stub_http_ok '["ornl/frontier","anl/improv","anl/aurora"]'
    run knit_list_profiles
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "anl/aurora" ]
    [ "${lines[1]}" = "anl/improv" ]
    [ "${lines[2]}" = "ornl/frontier" ]
    [[ "$(cat "${_KNIT_TEST_TMPDIR}/last_url")" == *"/src/profiles/index.json" ]]
}
