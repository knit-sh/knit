#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# ---------- knit_no_record_on_failure: marker ----------

@test "knit_no_record_on_failure marks the command" {
    knit_register "nrf_marked" knit_empty "A command."
    knit_no_record_on_failure
    knit_done
    [ "${_KNIT_CMD_nrf_marked_no_record_on_failure}" = "true" ]
}

@test "a command is not marked by default" {
    knit_register "nrf_plain" knit_empty "A command."
    knit_done
    [ -z "${_KNIT_CMD_nrf_plain_no_record_on_failure:-}" ]
}

@test "knit_no_record_on_failure is idempotent" {
    knit_register "nrf_twice" knit_empty "A command."
    knit_no_record_on_failure
    knit_no_record_on_failure
    knit_done
    [ "${_KNIT_CMD_nrf_twice_no_record_on_failure}" = "true" ]
}

@test "knit_no_record_on_failure fails outside of knit_register" {
    run knit_no_record_on_failure
    [ "$status" -eq 1 ]
    [[ "$output" == *"after a call to"* ]]
}

# ---------- knit_no_record_on_failure: kind rejection ----------

@test "knit_no_record_on_failure is allowed on a setup" {
    knit_register_setup "nrf_setup" fn_nrf_setup "A setup."
    fn_nrf_setup() { :; }
    knit_no_record_on_failure
    knit_done
    [ "${_KNIT_CMD_setup__1__nrf_setup_no_record_on_failure}" = "true" ]
}

@test "knit_no_record_on_failure is rejected on a job" {
    knit_register_job "nrf_job" fn_nrf_job "A job."
    fn_nrf_job() { :; }
    run knit_no_record_on_failure
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot be used with a job"* ]]
}

@test "knit_no_record_on_failure is rejected on a wrapper" {
    knit_register_wrapper "nrf_wrap" fn_nrf_wrap "A wrapper."
    fn_nrf_wrap() { :; }
    run knit_no_record_on_failure
    [ "$status" -eq 1 ]
    [[ "$output" == *"wrapper"* ]]
}

# ---------- knit_no_record_on_failure: recording behavior ----------

@test "no row is recorded when the body fails" {
    knit_register "nrf_fail" fn_nrf_fail "A command."
    knit_with_table
    knit_no_record_on_failure
    fn_nrf_fail() { return 1; }
    knit_done
    run _knit_invoke_command "nrf_fail"
    [ "$status" -ne 0 ]
    local n
    n=$(sqlite3 "${_KNIT_DATABASE}" "SELECT count(*) FROM 'nrf_fail';")
    [ "$n" -eq 0 ]
}

@test "a normal row is recorded when the body succeeds" {
    knit_register "nrf_ok" fn_nrf_ok "A command."
    knit_with_table
    knit_no_record_on_failure
    fn_nrf_ok() { :; }
    knit_done
    _knit_invoke_command "nrf_ok"
    local n
    n=$(sqlite3 "${_KNIT_DATABASE}" "SELECT count(*) FROM 'nrf_ok';")
    [ "$n" -eq 1 ]
}

@test "without the directive a failed body still records a row" {
    knit_register "nrf_default" fn_nrf_default "A command."
    knit_with_table
    fn_nrf_default() { return 1; }
    knit_done
    run _knit_invoke_command "nrf_default"
    [ "$status" -ne 0 ]
    local n
    n=$(sqlite3 "${_KNIT_DATABASE}" "SELECT count(*) FROM 'nrf_default';")
    [ "$n" -eq 1 ]
}

# ---------- _knit_command_is_job accessor ----------

@test "_knit_command_is_job true for a job, false for a plain command" {
    knit_register_job "nrf_isjob" fn_nrf_isjob "A job."
    fn_nrf_isjob() { :; }
    knit_done
    knit_register "nrf_notjob" knit_empty "A command."
    knit_done
    _knit_command_is_job "submit__1__nrf_isjob"
    run _knit_command_is_job "nrf_notjob"
    [ "$status" -eq 1 ]
}

# ---------- integration: resources use the decorator ----------

@test "knit_register_resource marks its fetch command via the decorator" {
    knit_register_resource "nrf_res" "A resource."
    knit_with_local "/tmp/nrf-does-not-need-to-exist"
    knit_done
    [ "${_KNIT_CMD_fetch__1__nrf_res_no_record_on_failure}" = "true" ]
}
