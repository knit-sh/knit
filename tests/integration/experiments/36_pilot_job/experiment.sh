#!/usr/bin/env bash
# Integration test experiment 36_pilot_job.
#
# Exercises pilot jobs (knit_with_pilot) end to end on a live scheduler: a pilot
# job starts the in-allocation knit-pilotd daemon over its own nodes and submits
# sub-jobs that pack onto the allocation and run concurrently, each recorded as a
# normal knit job with a provenance edge back to the pilot.
#
#   - Job "worker" is a small, setup-less sub-job. It records the node subset the
#     pilot daemon assigned it (knit_job_hostnames, which reads the daemon's
#     KNIT_PILOT_HOSTFILE) and a start/end epoch around a short sleep, so the
#     driver can prove two workers ran at the same time. The worker bodies all run
#     on the pilot's launch node, so their epochs share one clock (no skew).
#
#   - Job "campaign" is a pilot (knit_with_pilot). Its body fans out `--count`
#     worker sub-jobs, each `knit submit --nodes 1 -- worker ...` (routed to the
#     daemon, not the batch scheduler), collecting the UUIDs, then waits on the
#     whole batch with `knit job wait --id`. `--sleep` is forwarded to each worker
#     so the kill test can make them outlast an external cancel.
#
# The worker lines are "WORKER seed=<s> assigned=<h,...> start=<t> end=<t>" so the
# driver can parse them field by field.

source knit.sh

knit_set_program_description "Pilot-job integration test experiment."

knit_register_job "worker" __worker_job_fn "A small pilot sub-job."
knit_without_setup
knit_with_optional "seed:integer"  "1" "This worker's seed (identifies it)."
knit_with_optional "sleep:integer" "3" "Seconds to sleep (for concurrency/kill)."
__worker_job_fn() {
    local seed sleep_s assigned start end
    seed=$(knit_get_parameter "seed" "$@")
    sleep_s=$(knit_get_parameter "sleep" "$@")
    # The node subset the daemon assigned this sub-job (from KNIT_PILOT_HOSTFILE).
    assigned=$(knit_job_hostnames --separator ,)
    start=$(date +%s)
    sleep "${sleep_s}"
    end=$(date +%s)
    printf 'WORKER seed=%s assigned=%s start=%s end=%s\n' \
        "${seed}" "${assigned}" "${start}" "${end}"
}
knit_done

knit_register_job "campaign" __campaign_job_fn "Run worker sub-jobs on one allocation (pilot)."
knit_with_pilot
knit_with_optional "count:integer" "4" "Number of worker sub-jobs to fan out."
knit_with_optional "sleep:integer" "3" "Seconds each worker sleeps."
__campaign_job_fn() {
    local count sleep_s seed ids=""
    count=$(knit_get_parameter "count" "$@")
    sleep_s=$(knit_get_parameter "sleep" "$@")
    # Each submit queues a sub-job with the pilot daemon (one node each) and
    # returns its UUID at once; collect them to wait on as a batch.
    for (( seed = 1; seed <= count; seed++ )); do
        ids+="${ids:+,}$(knit submit --nodes 1 -- worker --seed "${seed}" --sleep "${sleep_s}")"
    done
    # Block until every sub-job is terminal (non-zero if any failed/killed).
    knit job wait --id "${ids}"
}
knit_done

knit "$@"
