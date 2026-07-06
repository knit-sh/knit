#!/usr/bin/env bash
# Integration test experiment 08_job_hostnames.
#
# Registers a job "hosts" whose body reports the nodes the scheduler allocated to
# it, using knit_job_hostnames in each of its forms. The job is submitted across
# two nodes (submit --nodes 2), so on a real scheduler the reported list contains
# both allocated compute nodes — exercising the backend host discovery
# (PBS $PBS_NODEFILE / Slurm scontrol) as well as the deduplication, --json,
# --separator, and --raw formatting.
#
# The body prints each form inside "=== <name> ===" markers so the test driver
# can extract and compare the sections.

source /shared/knit/knit.sh

knit_set_program_description "Job hostname reporting integration test experiment."

knit_register_setup "env" __env_setup_fn "Prepare a trivial environment."
__env_setup_fn() {
    export HOSTS_MARKER="ok"
}
knit_done

knit_register_job "hosts" __hosts_job_fn "Report the job's allocated hostnames."
__hosts_job_fn() {
    printf '=== default ===\n'
    knit_job_hostnames
    printf '=== csv ===\n'
    knit_job_hostnames --separator '|'
    printf '=== json ===\n'
    knit_job_hostnames --json
    printf '=== raw ===\n'
    knit_job_hostnames --raw
    printf '=== select ===\n'
    knit_job_hostnames --select 1:1
    printf '=== end ===\n'
}
knit_done

knit "$@"
