#!/bin/bash

# doc-check: source-only
#
# Pilot jobs: a job that schedules smaller sub-jobs onto its own allocation,
# through an in-allocation knit-pilotd daemon instead of the machine scheduler.
#
# Source-only: a pilot starts the knit-pilotd daemon and submits real sub-jobs
# onto an allocation, which needs a scheduler (and, to pack, more than one node),
# so check-docs only syntax-checks this file. Behavior is validated live by the
# pilot integration test.

source knit.sh

knit_set_program_description "Pilot-job example: a campaign of worker sub-jobs."

# START worker
# A small, ordinary sub-job. Nothing marks it "for pilots only" — a pilot simply
# submits many of them. @without_setup keeps it self-contained (no --setup).
@job "worker" "A small sub-job."
@without_setup
@with_optional "seed:integer" "1" "This worker's PRNG seed."
_worker_job() {
    local seed
    seed=$(knit_get_parameter "seed" "$@")
    printf 'worker seed %s on %s\n' "${seed}" "$(hostname)"
}
@done
# END worker

# START campaign
# @with_pilot marks this job a pilot. Inside its body, `knit submit` targets the
# in-allocation daemon (started over the job's own nodes) instead of the machine
# scheduler, so the sub-jobs pack onto the allocation and run concurrently.
@job "campaign" "Run many worker sub-jobs on one allocation."
@with_pilot
@with_optional "count:integer" "4" "Number of worker sub-jobs to fan out."
_campaign_job() {
    local count seed ids=""
    count=$(knit_get_parameter "count" "$@")

    # Each `knit submit` queues a sub-job with the pilot daemon and returns at
    # once with its UUID; --nodes 1 asks for a one-node slice. Collect the UUIDs.
    for (( seed = 1; seed <= count; seed++ )); do
        ids+="${ids:+,}$(knit submit --nodes 1 -- worker --seed "${seed}")"
    done

    # Wait for the whole batch: `knit job wait --id` takes a comma-separated list
    # and blocks until every sub-job is terminal (non-zero if any failed/killed).
    knit job wait --id "${ids}"
}
@done
# END campaign

knit "$@"
