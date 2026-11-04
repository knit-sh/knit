#!/usr/bin/env bash
# Integration test experiment 06_job_wait.
#
# Registers:
#   - a setup "env" (trivial; just produces a .activate.sh)
#   - a job "worker" that sleeps briefly and then completes normally
#   - a job "failer" whose body aborts with knit_fatal
#
# The test submits the job WITHOUT --wait, then blocks on `job wait --id`, which
# waits on the scheduler itself (squeue on Slurm, qstat on PBS, a PID probe
# locally) rather than busy-polling the database. When the job finishes, its
# compute-side after-callback has recorded the row as "completed", so `job wait`
# prints "completed" and exits 0.
#
# The "failer" job covers a blocking `submit --wait` on a job that fails: the
# body's knit_fatal exits before the after-callback runs, but the on-fatal
# recorder marks the row "failed" and `submit --wait` returns non-zero.

source knit.sh

knit_set_program_description "job wait status-blocking integration test experiment."

knit_register_setup "env" __env_setup_fn "Prepare a trivial environment."
__env_setup_fn() {
    # Declared so a non-empty .activate.sh is produced for the job to source.
    knit_setup_env_set KNIT_WAIT_CANARY "present"
}
knit_done

knit_register_job "worker" __worker_job_fn "Sleep briefly, then complete."
__worker_job_fn() {
    # Long enough that `job wait` must actually block on the scheduler, short
    # enough to keep the test quick.
    sleep 15
}
knit_done

knit_register_job "failer" __failer_job_fn "Abort with a fatal error."
__failer_job_fn() {
    # knit_fatal exits the process before the after-callback can record a terminal
    # state; the on-fatal recorder (installed by the job before-callback) must mark
    # the row "failed" so a blocking submit --wait returns non-zero.
    knit_fatal "intentional failure for the submit --wait test"
}
knit_done

knit "$@"
