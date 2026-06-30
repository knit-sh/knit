#!/usr/bin/env bats

setup() {
    if ! command -v sqlite3 &>/dev/null; then
        skip "sqlite3 not available"
    fi

    source knit.sh

    __KNIT_SQLITE_EXE="sqlite3"
    __KNIT_DATABASE="$(mktemp --suffix=.db)"
    __KNIT_TEST_TMPDIR="$(mktemp -d)"

    # Satisfy the bootstrap check — tests in this file work with a live DB
    _KNIT_IS_BOOTSTRAPPED="1"
}

teardown() {
    rm -f "${__KNIT_DATABASE}"
    rm -rf "${__KNIT_TEST_TMPDIR}"
    unset KNIT_JOB_PREFIX
    unset KNIT_SETUP_PREFIX
    _KNIT_IS_BOOTSTRAPPED=""
}

# ---------- submit command registration ----------

@test "submit command is registered" {
    _knit_set_find _KNIT_COMMANDS "submit"
}

@test "submit command uses the \"Jobs\" subcommand title" {
    [ "${_KNIT_CMD_submit_sucommand_title}" = "Jobs" ]
}

# ---------- knit_register_job ----------

@test "knit_register_job adds name to _KNIT_JOBS" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done
    [[ -v _KNIT_JOBS["myjob"] ]]
}

@test "knit_register_job registers submit:<name> command" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done
    _knit_set_find _KNIT_COMMANDS "submit__1__myjob"
}

@test "knit_register_job creates DB table named submit:<name>" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done
    local result
    result=$(sqlite3 "${__KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='submit:myjob';")
    [ "$result" -eq 1 ]
}

@test "knit_register_job installs before callback" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done
    local cmd
    cmd=$(__knit_command_mangle "submit:myjob")
    local cb_content
    eval "cb_content=\"\${_KNIT_CMD_${cmd}_before_cb[*]}\""
    [[ "${cb_content}" == *__knit_job_before_cb* ]]
}

@test "knit_register_job installs after callback" {
    _test_job_fn() { :; }
    knit_register_job "myjob" "_test_job_fn" "A test job."
    knit_done
    local cmd
    cmd=$(__knit_command_mangle "submit:myjob")
    local cb_content
    eval "cb_content=\"\${_KNIT_CMD_${cmd}_after_cb[*]}\""
    [[ "${cb_content}" == *__knit_job_after_cb* ]]
}

# ---------- __knit_job_before_cb ----------

@test "job before callback fails when KNIT_JOB_PREFIX is not set" {
    unset KNIT_JOB_PREFIX
    run __knit_job_before_cb
    [ "$status" -ne 0 ]
}

@test "job before callback sources .activate.sh when prefixes are set" {
    export KNIT_JOB_PREFIX="${__KNIT_TEST_TMPDIR}/job"
    export KNIT_SETUP_PREFIX="${__KNIT_TEST_TMPDIR}"
    printf 'export _KNIT_JOB_CANARY=activated\n' > "${KNIT_SETUP_PREFIX}/.activate.sh"
    __knit_job_before_cb
    [ "${_KNIT_JOB_CANARY}" = "activated" ]
    unset _KNIT_JOB_CANARY
}

# ---------- __knit_job_after_cb ----------

@test "job after callback is a no-op and succeeds" {
    run __knit_job_after_cb
    [ "$status" -eq 0 ]
}
