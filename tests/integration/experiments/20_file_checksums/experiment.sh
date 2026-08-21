#!/usr/bin/env bash
# Integration test experiment 20_file_checksums.
#
# Exercises the file/directory checksum feature end to end, across both the
# single-process (job) path and the app (knit run) path, on a live scheduler:
#
#   - Job "process" is a single-process job with a checksummed "file" input and
#     three outputs: a checksummed "file", a checksummed "directory" (hashed
#     recursively), and a "directory" declared --no-checksum (path recorded, no
#     checksum column). Its input is hashed before the body runs; its outputs are
#     hashed after the body returns. All land in the "process" table.
#
#   - App "transform" has a checksummed "file" input and a checksummed "file"
#     output. Its input is hashed once by the run dispatcher before any rank is
#     launched (never on a rank); its output's checksum is filled by the
#     dispatcher after the launcher returns, off every rank's measured duration.
#
#   - Job "launch" calls `knit run --procs 2 -- transform --input <path>` from
#     its body, so the app runs under a real MPI launcher inside the allocation.
#
# Input paths are absolute (the compute-side body runs with cwd = the job
# directory), so the input file on the shared filesystem resolves on every node.

source knit.sh

knit_set_program_description "file/directory checksum integration test experiment."

# --------------------------------------------------------------------------
# Job "process" — single-process file/directory checksums.
# knit_register_job already backs the job with a table named after it, so no
# knit_with_table call is needed here.
# --------------------------------------------------------------------------
knit_register_job "process" __process_job_fn "Process a file into checksummed outputs."
knit_with_required "input:file"           "Input data file (existence + sha256 recorded)."
knit_with_output   "result:file"      ""  "The written result file (path + sha256 recorded)."
knit_with_output   "tree:directory"   ""  "A directory tree, hashed recursively."
knit_with_output   "scratch:directory" "" "Scratch tree, recorded by path only." --no-checksum
__process_job_fn() {
    local input
    input=$(knit_get_parameter "input" "$@")

    # A checksummed file output: real content so the recorded digest is meaningful.
    wc -l < "${input}" > result.txt
    knit_output "result" "result.txt"

    # A checksummed directory output: nested files, hashed recursively over both
    # tree structure and content.
    mkdir -p tree/sub
    printf 'one\n' > tree/a.txt
    printf 'two\n' > tree/sub/b.txt
    knit_output "tree" "tree"

    # A --no-checksum directory output: its path is recorded, no checksum column.
    mkdir -p scratch
    printf 'volatile\n' > scratch/tmp.txt
    knit_output "scratch" "scratch"
}
knit_done

# --------------------------------------------------------------------------
# App "transform" — file checksums handled by the dispatcher, not the ranks.
# knit_register_app already backs the app with a table named after it.
# --------------------------------------------------------------------------
knit_register_app "transform" __transform_app_fn "Transform a file on rank 0."
knit_with_required "input:file"      "Input data file (hashed once by the dispatcher)."
knit_with_output   "out:file"    ""  "The written output (checksum filled post-launch)."
__transform_app_fn() {
    local input
    input=$(knit_get_parameter "input" "$@")
    # Every rank reads the input; only rank 0 writes and records the output row.
    if [[ "${KNIT_MPI_RANK}" == "0" ]]; then
        printf 'size=%s bytes=%s\n' "${KNIT_MPI_SIZE}" "$(wc -c < "${input}")" \
            > transform-out.txt
        knit_output "out" "transform-out.txt"
    fi
}
knit_done

# --------------------------------------------------------------------------
# Job "launch" — dispatch the transform app via knit run.
# --------------------------------------------------------------------------
knit_register_job "launch" __launch_job_fn "Launch the transform app via knit run."
knit_with_required "input:path" "Input file path forwarded to the transform app."
__launch_job_fn() {
    local input
    input=$(knit_get_parameter "input" "$@")
    knit run --procs 2 -- transform --input "${input}"
}
knit_done

knit "$@"
