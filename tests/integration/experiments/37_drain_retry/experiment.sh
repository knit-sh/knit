#!/usr/bin/env bash
# Integration test experiment 37_drain_retry.
#
# Registers one self-contained job used to exercise the retry path of the durable
# prepare/drain queue against the real cluster scheduler:
#   - "sim" only does arithmetic and records a result, so it always completes.
#
# The test simulates a mid-drain kill by setting a drained job's state to
# "killed" directly in the database (what a pilot killed at walltime leaves
# behind), then re-drains with --retry to show the job runs again to completion.

source knit.sh

knit_set_program_description "submit drain --retry integration test experiment."

knit_register_job "sim" __sim_job_fn "Run one trivial simulation."
knit_without_setup
knit_with_optional "n:integer"      "1"  "Number of steps to run."
knit_with_table
knit_with_output   "result:integer" "0"  "Twice the step count (a stand-in result)."
__sim_job_fn() {
    local n
    n=$(knit_get_parameter "n" "$@")
    knit_output "result" "$(( n * 2 ))"
    printf 'sim: n=%s result=%s\n' "${n}" "$(( n * 2 ))"
}
knit_done

knit "$@"
