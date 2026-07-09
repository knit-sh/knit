#!/usr/bin/env bash
# Integration test experiment 09_run_app.
#
# Exercises `knit run` (the app / launcher layer) end to end inside a real job,
# on a live scheduler with a real MPI launcher (OpenMPI on Slurm, MPICH on PBS).
#
#   - Setup "env" exports a marker variable. The launcher must forward the job's
#     setup environment to every rank, including ranks placed on *remote* compute
#     nodes; the marker is how the driver proves that forwarding happened (this is
#     the live-cluster confirmation of the OpenMPI "-x" note in
#     launcher-milestones.md M11: forwarding works, so no -x fallback is needed).
#
#   - App "ranks" is a rank-aware shell app: each rank prints its normalized
#     KNIT_MPI_* coordinates, the host it ran on, and the forwarded marker, so
#     the driver can verify placement and forwarding. Rank 0 records a per-app
#     output (the world size it observed); every other rank's recording is
#     suppressed, so the per-app table gets exactly one row per run.
#
#   - Job "launch" is submitted with knit submit and calls
#     `knit run --procs N --procs-per-node P -- ranks` from its body (the
#     submit -> run nesting), spreading ranks across the allocation's nodes.
#
#   - Job "subset" restricts a run to a single allocated host via --hostnames,
#     to check host-subset placement.
#
# The rank lines use "RANK=<r> SIZE=<s> LOCAL=<l> HOST=<h> MARKER=<m>" so the
# driver can parse them field by field.

source /shared/knit/knit.sh

knit_set_program_description "knit run (app launch) integration test experiment."

knit_register_setup "env" __env_setup_fn "Export a marker for forwarding checks."
__env_setup_fn() {
    export RUN_APP_MARKER="forwarded-ok"
}
knit_done

knit_register_app "ranks" __ranks_app_fn "Print each rank's MPI coordinates."
knit_with_output "size:integer" "0" "World size observed by rank 0."
__ranks_app_fn() {
    printf 'RANK=%s SIZE=%s LOCAL=%s HOST=%s MARKER=%s\n' \
        "${KNIT_MPI_RANK}" "${KNIT_MPI_SIZE}" "${KNIT_MPI_LOCAL_RANK}" \
        "$(hostname)" "${RUN_APP_MARKER:-<empty>}"
    knit_output "size" "${KNIT_MPI_SIZE}"
}
knit_done

knit_register_job "launch" __launch_job_fn "Launch the ranks app across the allocation."
knit_with_setup "env"
knit_with_optional "procs:integer" "4" "Total ranks to launch."
knit_with_optional "procs-per-node:integer" "2" "Ranks per node."
knit_with_optional "launcher:string" "" \
    "Launcher backend to use (empty = auto-detect the MPI-native one)."
__launch_job_fn() {
    local procs ppn launcher
    procs=$(knit_get_parameter "procs" "$@")
    ppn=$(knit_get_parameter "procs-per-node" "$@")
    launcher=$(knit_get_parameter "launcher" "$@")
    knit run --procs "${procs}" --procs-per-node "${ppn}" \
        --launcher "${launcher}" -- ranks
}
knit_done

knit_register_job "subset" __subset_job_fn "Launch the ranks app on one allocated host."
knit_with_setup "env"
__subset_job_fn() {
    local host
    host=$(knit_job_hostnames | head -1)
    knit run --hostnames "${host}" --procs 2 -- ranks
}
knit_done

knit "$@"
