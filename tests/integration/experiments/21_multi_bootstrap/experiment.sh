#!/usr/bin/env bash
# Integration test experiment 21_multi_bootstrap.
#
# Registers just enough to record a real run before re-running bootstrap:
#   - a user setup "env" that exports a variable captured into .activate.sh
#   - a job "hello" that prints that variable and the compute-node hostname
#
# The test bootstraps, submits "hello" (recording a "jobs" row and creating a
# user setup), then re-runs bootstrap in update mode to change settings in place.

source knit.sh

knit_set_program_description "Re-runnable bootstrap (update mode) integration test experiment."

knit_register_setup "env" __env_setup_fn "Prepare a trivial environment."
__env_setup_fn() {
    # Exported so it is captured into <setup>/.activate.sh and visible to the job.
    export GREETING="hello-from-setup"
}
knit_done

knit_register_job "hello" __hello_job_fn "Print a greeting from a job."
__hello_job_fn() {
    printf 'job says: %s\n' "${GREETING}"
    printf 'hostname: %s\n' "$(hostname)"
}
knit_done

knit "$@"
