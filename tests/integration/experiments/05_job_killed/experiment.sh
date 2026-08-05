#!/usr/bin/env bash
# Integration test experiment 05_job_killed.
#
# Registers:
#   - a setup "env" (trivial; just produces a .activate.sh)
#   - a job "sleeper" that sleeps long enough to be cancelled while running
#
# The test submits the job WITHOUT --wait, waits until the jobs row
# reaches "running", then cancels the job through the scheduler. The scheduler
# sends the job a SIGTERM before killing it; knit's compute-side trap records the
# job as "killed" (M8) before the process dies.

source knit.sh

knit_set_program_description "Job-kill status-tracking integration test experiment."

knit_register_setup "env" __env_setup_fn "Prepare a trivial environment."
__env_setup_fn() {
    # Exported so a non-empty .activate.sh is produced for the job to source.
    export KNIT_KILLED_CANARY="present"
}
knit_done

knit_register_job "sleeper" __sleeper_job_fn "Sleep so the job can be cancelled."
__sleeper_job_fn() {
    # Sleep well past the time the test needs to observe "running" and cancel us.
    sleep 300
}
knit_done

knit "$@"
