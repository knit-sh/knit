#!/usr/bin/env bash
# Integration test experiment 29_queue_auto.
#
# Registers a single job "hello" that prints the compute-node hostname. The point
# of this experiment is the *submission*, not the job body: it is bootstrapped
# with a machine profile that declares two queues, and submitted with automatic
# queue selection (--queue auto / default_queue = auto). Knit picks the first
# declared queue whose node bounds accept the job and writes that concrete queue
# into the batch script's directives (see test.sh).

source knit.sh

knit_set_program_description "Automatic queue selection integration test experiment."

knit_register_job "hello" __hello_job_fn "Print the compute-node hostname."
__hello_job_fn() {
    printf 'hostname: %s\n' "$(hostname)"
}
knit_done

knit "$@"
