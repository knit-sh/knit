#!/usr/bin/env bash
# Integration test experiment 38_job_reconcile.
#
# Jobs exercising the reconcile path against the real cluster scheduler:
#   - "sim" only does arithmetic and records a result, so it always completes.
#   - "worker" is a small, setup-less pilot sub-job that just sleeps.
#   - "campaign" is a pilot (knit_with_pilot) that fans out worker sub-jobs
#     through the in-allocation daemon and waits on them.
#
# The test simulates a hard-kill by writing a job's state back to "running"
# directly in the database (what a SIGKILL before the kill trap leaves behind).
# Because the real .job.id is still present, `job reconcile` can query the
# scheduler for the job's true fate — directly for an ordinary job, and for a
# pilot sub-job by walking to its parent pilot (whose .job.id names a real
# scheduler job).

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

knit_register_job "worker" __worker_job_fn "A small pilot sub-job."
knit_without_setup
knit_with_optional "sleep:integer" "2" "Seconds to sleep."
__worker_job_fn() {
    local sleep_s
    sleep_s=$(knit_get_parameter "sleep" "$@")
    sleep "${sleep_s}"
    printf 'worker done (slept %ss)\n' "${sleep_s}"
}
knit_done

knit_register_job "campaign" __campaign_job_fn "Fan out worker sub-jobs on one allocation (pilot)."
knit_with_pilot
knit_with_optional "count:integer" "2" "Number of worker sub-jobs to fan out."
knit_with_optional "sleep:integer" "2" "Seconds each worker sleeps."
__campaign_job_fn() {
    local count sleep_s seed ids=""
    count=$(knit_get_parameter "count" "$@")
    sleep_s=$(knit_get_parameter "sleep" "$@")
    for (( seed = 1; seed <= count; seed++ )); do
        ids+="${ids:+,}$(knit submit --nodes 1 -- worker --sleep "${sleep_s}")"
    done
    knit job wait --id "${ids}"
}
knit_done

knit "$@"
