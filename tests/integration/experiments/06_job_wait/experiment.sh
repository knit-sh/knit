#!/usr/bin/env bash
# Integration test experiment 06_job_wait.
#
# Registers:
#   - a setup "env" (trivial; just produces a .activate.sh)
#   - a job "worker" that sleeps briefly and then completes normally
#
# The test submits the job WITHOUT --wait, then blocks on `job wait --id`, which
# waits on the scheduler itself (squeue on Slurm, qstat on PBS, a PID probe
# locally) rather than busy-polling the database. When the job finishes, its
# compute-side after-callback has recorded the row as "completed", so `job wait`
# prints "completed" and exits 0.

source /shared/knit/knit.sh

knit_set_program_description "job wait status-blocking integration test experiment."

knit_register_setup "env" __env_setup_fn "Prepare a trivial environment."
__env_setup_fn() {
    # Exported so a non-empty .activate.sh is produced for the job to source.
    export KNIT_WAIT_CANARY="present"
}
knit_done

knit_register_job "worker" __worker_job_fn "Sleep briefly, then complete."
__worker_job_fn() {
    # Long enough that `job wait` must actually block on the scheduler, short
    # enough to keep the test quick.
    sleep 15
}
knit_done

knit "$@"
