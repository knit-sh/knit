#!/usr/bin/env bash
# Integration test experiment 22_artifacts.
#
# Exercises the results-and-artifacts feature end to end, through the job path on
# a live scheduler:
#
#   - Job "bundle" reads a file input, computes a value result, and produces two
#     artifacts, one bound each way:
#
#       * "lines"   — a value result (knit_with_output ... --result). It is not a
#         file, only the headline number the run was for; it is a column of the
#         "bundle" table and travels in the database, never in artifacts/.
#       * "dataset" — a file artifact bound with --link-from: the body writes a
#         "large" file in the job directory and references it in place through an
#         absolute-target symlink under artifacts/. This artifact is a result too.
#       * "figure"  — a file artifact bound with --copy-from: the body writes a
#         small file and snapshots it into artifacts/ for durability. It is an
#         artifact but not the headline result.
#
# Each artifact is one row in the framework-owned "artifacts" table (its
# artifacts-relative "path", "name", "type", content "checksum", and "result"
# flag), linked to the job body's row by a "produced" provenance edge — not a
# column of the "bundle" table. The recorded path is artifacts-relative, so no
# absolute machine path leaks, and the symlinked dataset is checksummed as if it
# were physically present.
#
# The "large" file the dataset links to lives in the job directory (on the shared
# filesystem), referenced by an absolute path so the symlink never dangles.

source knit.sh

knit_set_program_description "results-and-artifacts integration test experiment."

# --------------------------------------------------------------------------
# Job "bundle" — a value result plus two artifacts (one linked, one copied).
# knit_register_job already backs the job with a table named after it, so no
# knit_with_table call is needed here.
# --------------------------------------------------------------------------
knit_register_job "bundle" __bundle_job_fn "Produce a value result and two artifacts."
knit_with_required "input:file"          "Input data file (its line count is the result)."
knit_with_output   "lines:integer" "0"  "Line count of the input (the headline result)." --result
knit_with_artifact "dataset:file"        "Large dataset, referenced in place." --result
knit_with_artifact "figure:file"         "Small summary, copied in for durability."
__bundle_job_fn() {
    local input
    input=$(knit_get_parameter "input" "$@")

    local n
    n=$(wc -l < "${input}")

    # A "large" dataset written in the job directory (shared filesystem), then
    # referenced in place under artifacts/ through an absolute-target symlink.
    seq 1 "${n}" > "${PWD}/dataset.csv"
    knit_artifact "dataset" "dataset.csv" --link-from "${PWD}/dataset.csv"

    # A small summary copied into artifacts/ for durability.
    printf 'lines=%s\n' "${n}" > "${PWD}/summary.txt"
    knit_artifact "figure" "figure.txt" --copy-from "${PWD}/summary.txt"

    # The headline value result: a bare number, no file.
    knit_output "lines" "${n}"
}
knit_done

knit "$@"
