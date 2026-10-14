#!/usr/bin/env bats

# Tests for the M3 bootstrap update-mode handling of the environment-manager
# layer: _knit_env_env_built, _knit_env_update_one, and _knit_env_update_all.
# Exercised with a "fake" manager (one provisioning option "ver") whose provision
# verb is a stub recording its argv.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"
    _KNIT_DATABASE="${_KNIT_TEST_TMPDIR}/env.db"
    _knit_create_metadata_table
    knit metadata store --key __setup_path__ --value "${_KNIT_TEST_TMPDIR}/setups"
    knit metadata store --key __ver_ref__    --value v1

    # The fake manager's provision stub records its argv; other verbs are trivial.
    __prov_calls="${_KNIT_TEST_TMPDIR}/prov-calls"; : > "${__prov_calls}"
    _fake_provision() { printf '%s\n' "$*" >> "${__prov_calls}"; }
    _fake_install()  { :; }
    _fake_activate() { :; }
    _fake_specs()    { printf 'fake\n'; }

    knit_register_env_manager "fake" "A fake manager."
    knit_env_provision _fake_provision --options "ver:string"
    knit_env_install   _fake_install
    knit_env_activate  _fake_activate
    knit_env_specs     _fake_specs
    knit_env_manifest  "fake.yaml"
    knit_env_lockfile  "fake.lock"
    knit_env_done

    _KNIT_ENV_fake_required=""
    # The manager's tool dir (.knit/fake) is left absent; a test creates it to
    # mean "already provisioned".
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    knit_test_db_teardown
}

# A raw-args array passed by name to the update dispatcher.
_run_update_one() {
    local raw=("$@")
    _knit_env_update_one "fake" raw
}

# ---------- _knit_env_env_built ----------

@test "env-built is false with no setup root or no lockfile, true with one" {
    run _knit_env_env_built "fake"              # no setup root yet
    [ "$status" -ne 0 ]
    mkdir -p "${_KNIT_TEST_TMPDIR}/setups/default"   # a setup but no environment
    run _knit_env_env_built "fake"
    [ "$status" -ne 0 ]
    mkdir -p "${_KNIT_TEST_TMPDIR}/setups/lib/fake-env"
    : > "${_KNIT_TEST_TMPDIR}/setups/lib/fake-env/fake.lock"
    run _knit_env_env_built "fake"              # a built environment
    [ "$status" -eq 0 ]
}

# ---------- update mode: not provisioned ----------

@test "update provisions when absent and a ref is typed" {
    _run_update_one --ver v2
    [ -s "${__prov_calls}" ]
    grep -q "v2" "${__prov_calls}"
}

@test "update provisions when absent and the manager is required" {
    _KNIT_ENV_fake_required="1"
    _run_update_one
    [ -s "${__prov_calls}" ]
}

@test "update does not provision when absent, untyped and not required" {
    run _run_update_one
    [ "$status" -eq 1 ]
    [ ! -s "${__prov_calls}" ]
}

# ---------- update mode: already provisioned ----------

@test "update re-provisions when the ref changes and no environment is built" {
    mkdir -p "${_KNIT_PREFIX}/fake"             # already provisioned
    _run_update_one --ver v2
    grep -q "v2" "${__prov_calls}"
    # The tool dir was removed before re-provisioning.
}

@test "update keeps an untyped stored ref across a re-provision of another knob" {
    # A second option whose stored value must be preserved when untyped.
    knit metadata store --key __other_ref__ --value kept
    _KNIT_ENV_fake_options=("ver:string" "other:string")
    mkdir -p "${_KNIT_PREFIX}/fake"
    _run_update_one --ver v2
    # ver changed to v2, other kept its stored value.
    grep -q "v2 kept" "${__prov_calls}"
}

@test "update fatals changing the ref when an environment is built" {
    mkdir -p "${_KNIT_PREFIX}/fake"
    mkdir -p "${_KNIT_TEST_TMPDIR}/setups/lib/fake-env"
    : > "${_KNIT_TEST_TMPDIR}/setups/lib/fake-env/fake.lock"
    run _run_update_one --ver v2
    [ "$status" -ne 0 ]
    [[ "$output" == *"frozen"* ]]
    [ ! -s "${__prov_calls}" ]
}

@test "a typed ref equal to the stored one is a no-op" {
    mkdir -p "${_KNIT_PREFIX}/fake"
    run _run_update_one --ver v1
    [ "$status" -eq 1 ]
    [ ! -s "${__prov_calls}" ]
}

@test "an untyped ref on a provisioned manager is a no-op" {
    mkdir -p "${_KNIT_PREFIX}/fake"
    run _run_update_one
    [ "$status" -eq 1 ]
    [ ! -s "${__prov_calls}" ]
}

# ---------- _knit_env_update_all ----------

@test "update_all returns 0 and provisions a needed manager" {
    local raw=(--ver v2)
    run _knit_env_update_all raw
    [ "$status" -eq 0 ]
    grep -q "v2" "${__prov_calls}"
}

@test "update_all returns 1 when nothing changed" {
    mkdir -p "${_KNIT_PREFIX}/fake"
    local raw=()
    run _knit_env_update_all raw
    [ "$status" -eq 1 ]
}
