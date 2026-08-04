#!/usr/bin/env bash
# Integration test experiment 04_submit_mpi.
#
# Exercises the compile-and-communicate path of `knit run`: building a real MPI
# program against the cluster's MPI in a setup, then launching it across compute
# nodes so its ranks genuinely communicate. This is the piece the env-var shell
# app in 09_run_app cannot show (its "ranks" app never calls MPI_Init); 09 covers
# the run/launcher plumbing (placement, recording, provenance), so this stays
# focused on real compilation and real inter-rank communication.
#
#   - Setup "mpienv" compiles mpi_allreduce.c with the cluster's mpicc (OpenMPI
#     on Slurm, MPICH on PBS — the same MPI knit's launcher auto-detects) and
#     exports the resulting binary's absolute path. The launcher forwards that
#     path (like any setup env var) to every rank.
#
#   - App "allreduce" runs that compiled binary once per rank. The binary calls
#     MPI_Init and MPI_Allreduce(SUM) over its own rank id, so a correct global
#     sum on every rank proves the ranks actually exchanged data.
#
#   - Job "launch" is submitted on two nodes; its body calls
#     `knit run --procs 4 --procs-per-node 2 -- allreduce`, spreading 4 ranks two
#     per node across both allocated nodes so the collective crosses the node
#     boundary.

source /shared/knit/knit.sh

knit_set_program_description "MPI job submission integration test experiment."

knit_register_setup "mpienv" __mpienv_setup_fn \
    "Compile the MPI allreduce program with the cluster mpicc."
__mpienv_setup_fn() {
    # The .c source is copied next to this experiment by the driver; locate it
    # relative to the (realpath'd) experiment script rather than the cwd, since
    # the setup runs from inside its own setup directory.
    local src bin
    src="$(dirname "${KNIT_SCRIPT_PATH}")/mpi_allreduce.c"
    mkdir -p "${KNIT_SETUP_PREFIX}/bin"
    bin="${KNIT_SETUP_PREFIX}/bin/mpi_allreduce"
    mpicc -O2 -o "${bin}" "${src}"
    # Absolute path, baked from KNIT_SETUP_PREFIX; captured into .activate.sh and
    # forwarded to every rank by the launcher.
    export MPI_ALLREDUCE_BIN="${bin}"
}
knit_done

knit_register_app "allreduce" __allreduce_app_fn \
    "Run the compiled MPI allreduce program."
__allreduce_app_fn() {
    # Run the binary as a child of this per-rank worker: it inherits the
    # launcher's MPI/PMI wireup, so MPI_Init joins the real size-N job, and its
    # one output line flows through the launcher to the job's stdout.
    "${MPI_ALLREDUCE_BIN}"
}
knit_done

knit_register_job "launch" __launch_job_fn \
    "Launch the compiled MPI program across the allocation."
knit_with_setup "mpienv"
knit_with_optional "procs:integer" "4" "Total ranks to launch."
knit_with_optional "procs-per-node:integer" "2" "Ranks per node."
__launch_job_fn() {
    local procs ppn
    procs=$(knit_get_parameter "procs" "$@")
    ppn=$(knit_get_parameter "procs-per-node" "$@")
    knit run --procs "${procs}" --procs-per-node "${ppn}" -- allreduce
}
knit_done

knit "$@"
