#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# ---------- _KNIT_CMD_<cmd>_type ----------

@test "a plain command has type \"command\"" {
    knit_register "ty_plain" knit_empty "A command."
    knit_done
    [ "${_KNIT_CMD_ty_plain_type}" = "command" ]
}

@test "a wrapper has type \"wrapper\"" {
    knit_register_wrapper "ty_wrap" fn_ty_wrap "A wrapper."
    fn_ty_wrap() { :; }
    knit_done
    [ "${_KNIT_CMD_ty_wrap_type}" = "wrapper" ]
}

@test "a setup has type \"setup\"" {
    knit_register_setup "ty_setup" fn_ty_setup "A setup."
    fn_ty_setup() { :; }
    knit_done
    [ "${_KNIT_CMD_setup__1__ty_setup_type}" = "setup" ]
}

@test "a job has type \"job\"" {
    knit_register_job "ty_job" fn_ty_job "A job."
    fn_ty_job() { :; }
    knit_done
    [ "${_KNIT_CMD_submit__1__ty_job_type}" = "job" ]
}

@test "an app has type \"app\"" {
    knit_register_app "ty_app" fn_ty_app "An app."
    fn_ty_app() { :; }
    knit_done
    [ "${_KNIT_CMD_run__1__ty_app_type}" = "app" ]
}

@test "a resource has type \"resource\"" {
    knit_register_resource "ty_res" "A resource."
    knit_with_local "/tmp/ty-res-does-not-need-to-exist"
    knit_done
    [ "${_KNIT_CMD_fetch__1__ty_res_type}" = "resource" ]
}

# ---------- the kind predicates read the type field ----------

@test "the kind predicates agree with the type field" {
    knit_register_wrapper "ty_pw" fn_ty_pw "A wrapper."
    fn_ty_pw() { :; }
    knit_done
    knit_register_job "ty_pj" fn_ty_pj "A job."
    fn_ty_pj() { :; }
    knit_done
    knit_register_resource "ty_pr" "A resource."
    knit_with_local "/tmp/ty-pr"
    knit_done
    knit_register "ty_pc" knit_empty "A command."
    knit_done

    _knit_command_is_wrapper  "ty_pw"
    _knit_command_is_job      "submit__1__ty_pj"
    _knit_command_is_resource "fetch__1__ty_pr"

    # A plain command is none of these kinds.
    run _knit_command_is_wrapper  "ty_pc"
    [ "$status" -eq 1 ]
    run _knit_command_is_job      "ty_pc"
    [ "$status" -eq 1 ]
    run _knit_command_is_resource "ty_pc"
    [ "$status" -eq 1 ]
}
