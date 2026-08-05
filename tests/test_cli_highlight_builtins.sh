#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    _knit_create_metadata_table

    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_PREFIX}"

    # Setups resolve under <experiment-root>/setups (the __setup_path__ fallback).
    _KNIT_TEST_SETUP_ROOT="${_KNIT_TEST_TMPDIR}/setups"
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    knit_test_db_teardown
}

# ---------- bootstrap highlight predicate ----------

@test "_knit_highlight_if_not_bootstrapped highlights before bootstrap" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/absent"   # does not exist
    run _knit_highlight_if_not_bootstrapped "bootstrap"
    [ "$status" -eq 0 ]
}

@test "_knit_highlight_if_not_bootstrapped does not highlight once bootstrapped" {
    _KNIT_IS_BOOTSTRAPPED="1"
    run _knit_highlight_if_not_bootstrapped "bootstrap"
    [ "$status" -eq 1 ]
}

# ---------- setup highlight predicate ----------

@test "_knit_highlight_if_no_user_setup does not highlight before bootstrap" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/absent"
    run _knit_highlight_if_no_user_setup "setup"
    [ "$status" -eq 1 ]
}

@test "_knit_highlight_if_no_user_setup highlights when no setup exists" {
    _KNIT_IS_BOOTSTRAPPED="1"
    run _knit_highlight_if_no_user_setup "setup"
    [ "$status" -eq 0 ]
}

@test "_knit_highlight_if_no_user_setup highlights when only the default setup exists" {
    _KNIT_IS_BOOTSTRAPPED="1"
    mkdir -p "${_KNIT_TEST_SETUP_ROOT}/default"
    run _knit_highlight_if_no_user_setup "setup"
    [ "$status" -eq 0 ]
}

@test "_knit_highlight_if_no_user_setup does not highlight when a user setup exists" {
    _KNIT_IS_BOOTSTRAPPED="1"
    mkdir -p "${_KNIT_TEST_SETUP_ROOT}/default"
    mkdir -p "${_KNIT_TEST_SETUP_ROOT}/env"
    run _knit_highlight_if_no_user_setup "setup"
    [ "$status" -eq 1 ]
}

# ---------- wired into the builtin registrations ----------

@test "bootstrap declares its highlight predicate" {
    [ -v _KNIT_CMD_bootstrap_highlight_pred ]
    [ "${_KNIT_CMD_bootstrap_highlight_pred[0]}" = "_knit_highlight_if_not_bootstrapped" ]
}

@test "setup declares its highlight predicate" {
    [ -v _KNIT_CMD_setup_highlight_pred ]
    [ "${_KNIT_CMD_setup_highlight_pred[0]}" = "_knit_highlight_if_no_user_setup" ]
}
