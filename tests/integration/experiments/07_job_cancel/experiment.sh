#!/usr/bin/env bash
# Integration test experiment 07_job_cancel.
#
# Registers:
#   - a setup "env" (trivial; just produces a .activate.sh)
#   - a job "sleeper" that sleeps long enough to be cancelled while running
#
# The test submits the job WITHOUT --wait, waits until the jobs row reaches
# "running", then cancels it with `knit job cancel --id <uuid>` (J9). That
# command asks the scheduler to terminate the job and records the jobs row as
# "killed"; the compute-side trap (M8) also records "killed" when it sees the
# scheduler's signal.

source /shared/knit/knit.sh

knit_set_program_description "job-cancel command integration test experiment."

knit_register_setup "env" __env_setup_fn "Prepare a trivial environment."
__env_setup_fn() {
    # Exported so a non-empty .activate.sh is produced for the job to source.
    export KNIT_CANCEL_CANARY="present"
}
knit_done

knit_register_job "sleeper" __sleeper_job_fn "Sleep so the job can be cancelled."
__sleeper_job_fn() {
    # Sleep well past the time the test needs to observe "running" and cancel us.
    sleep 300
}
knit_done

knit "$@"
