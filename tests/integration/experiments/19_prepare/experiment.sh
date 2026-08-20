#!/usr/bin/env bash
# Integration test experiment 19_prepare.
#
# Registers one self-contained job "sim" (no setup) used to exercise deferred
# submission: prepare, submit next, submit prepared, prepare from, and cancelling
# a prepared job with `job cancel`.
#
# "sim" only does arithmetic and records a result, so it runs fast on any
# scheduler. It takes --n and --label and records "result" = n * 2.

source knit.sh

knit_set_program_description \
    "Deferred submission (prepare) integration test experiment."

knit_register_job "sim" __sim_job_fn "Run one trivial simulation."
knit_without_setup
knit_with_optional "n:integer"      "10"  "Number of steps to run."
knit_with_optional "label:string"   "run" "A label recorded with the run."
knit_with_table
knit_with_output   "result:integer" "0"   "Twice the step count (a stand-in result)."
__sim_job_fn() {
    local n label
    n=$(knit_get_parameter "n" "$@")
    label=$(knit_get_parameter "label" "$@")
    knit_output "result" "$(( n * 2 ))"
    printf '%s: result=%s\n' "${label}" "$(( n * 2 ))"
}
knit_done

knit "$@"
