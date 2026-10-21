#!/usr/bin/env bash
# Integration test experiment 38_job_reconcile.
#
# Registers one self-contained job used to exercise the reconcile path against
# the real cluster scheduler:
#   - "sim" only does arithmetic and records a result, so it always completes.
#
# The test simulates a hard-kill by writing a completed job's state back to
# "running" directly in the database (what a SIGKILL before the kill trap leaves
# behind). Because the real .job.id is still present, `job reconcile` can query
# the scheduler for the job's true fate.

source knit.sh

knit_set_program_description "knit job reconcile integration test experiment."

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
