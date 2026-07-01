#!/usr/bin/env bash
# Integration test experiment 03_submit_basic.
#
# Registers:
#   - a setup "env" that exports a variable captured into .activate.sh
#   - a job "hello" that prints that variable and the compute-node hostname
#
# The job is submitted with `knit submit`, which generates a batch script and
# dispatches it to whichever scheduler knit detects (Slurm here). On the compute
# node the job re-hydrates the setup environment (via the before-callback) and
# runs its body.

source /shared/knit/knit.sh

knit_set_program_description "Basic job submission integration test experiment."

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
