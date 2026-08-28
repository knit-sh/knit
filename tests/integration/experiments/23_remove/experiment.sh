#!/usr/bin/env bash
# Integration test experiment 23_remove.
#
# Builds one complete provenance lineage so the companion test.sh can exercise
# `knit remove` end to end against a real bootstrap and a live scheduler. The
# graph spans every entity kind remove can erase and every edge kind it walks:
#
#   resource "srcpkg"  --used_by--> setup "env" --used_by--> job "work"
#     job "work"  --call--> its body  --call--> a `knit run` of app "compute"
#     the job body  --produced--> artifact "result.txt"
#
#   - Resource "srcpkg" (local backend) is fetched from a directory built by
#     test.sh, so no host is contacted. The setup consumes it, so a used_by edge
#     runs from the resource to the setup.
#
#   - Setup "env" reads the fetched source and exports a marker. A job that
#     declares knit_with_setup "env" inherits that marker through .activate.sh,
#     so the launched app sees it on every rank. A used_by edge runs from the
#     setup to the job.
#
#   - Job "work" runs the "compute" app with `knit run` (the submit -> run
#     nesting) and then produces one file artifact from its body, so the body is
#     the source of a produced edge to the artifact.
#
#   - App "compute" is rank-aware: each rank prints its coordinates and the
#     forwarded marker; rank 0 records the world size it observed.
#
# This lineage is what lets test.sh check that `remove job` keeps the setup and
# resource (their used_by edges detach), that `remove setup` cascades to the job
# tree, and that `remove artifact --from-root` erases the whole lineage.

source knit.sh

knit_set_program_description "knit remove end-to-end integration test experiment."

# --------------------------------------------------------------------------
# Resource "srcpkg" — a local directory linked in by `knit fetch`. Its path
# comes from the environment (test.sh builds the directory in the work area).
# --------------------------------------------------------------------------
knit_register_resource "srcpkg" "A source package fetched from a local path."
knit_with_local "${RES_LOCAL_PATH}"
knit_done

# --------------------------------------------------------------------------
# Setup "env" — consumes the fetched source and exports a marker derived from
# it, so the marker travels resource -> setup -> job -> app.
# --------------------------------------------------------------------------
knit_register_setup "env" _env_setup "Read the fetched source and export a marker."
knit_with_resource "src:srcpkg" "Name of the fetched source package to read."
_env_setup() {
    local src
    src="$(knit_resource_path "$(knit_get_parameter src "$@")")"
    # Copy the source's marker into the setup prefix and export it so it lands
    # in .activate.sh and is inherited by any job that requires this setup.
    cp "${src}/marker.txt" "${KNIT_SETUP_PREFIX}/marker.txt"
    export REMOVE_MARKER
    REMOVE_MARKER="$(cat "${KNIT_SETUP_PREFIX}/marker.txt")"
}
knit_done

# --------------------------------------------------------------------------
# App "compute" — one rank of the launched app. Prints its coordinates and the
# forwarded marker; rank 0 records the observed world size.
# --------------------------------------------------------------------------
knit_register_app "compute" _compute_app "Print each rank's coordinates and the marker."
knit_with_output "size:integer" "0" "World size observed by rank 0."
_compute_app() {
    printf 'RANK=%s SIZE=%s MARKER=%s\n' \
        "${KNIT_MPI_RANK}" "${KNIT_MPI_SIZE}" "${REMOVE_MARKER:-<empty>}"
    knit_output "size" "${KNIT_MPI_SIZE}"
}
knit_done

# --------------------------------------------------------------------------
# Job "work" — requires the setup, launches the app with `knit run`, and then
# produces one file artifact from its body.
# --------------------------------------------------------------------------
knit_register_job "work" _work_job "Launch the compute app and produce an artifact."
knit_with_setup    "env"
knit_with_artifact "result:file" "The run's summary, copied in for durability."
_work_job() {
    knit run --procs 2 -- compute

    # Produce a file artifact from the job body (the source of the produced edge).
    printf 'marker=%s\n' "${REMOVE_MARKER:-<empty>}" > "${PWD}/result.txt"
    knit_artifact "result" "result.txt" --copy-from "${PWD}/result.txt"
}
knit_done

knit "$@"
