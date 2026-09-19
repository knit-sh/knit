#!/usr/bin/env bash
# Integration test experiment 32_remove_failed_kind.
#
# Exercises the composable per-kind `remove <kind> --failed` filter end to end on
# a real scheduler with a real MPI launcher. It reuses the exit-status recording
# of experiment 31, but the driver (test.sh) prunes failures ONE KIND AT A TIME
# and checks the isolation the top-level `remove --failed` cannot give:
#
#   - Plain command "boom" declares a table and records __exit_status__, so
#     `boom --code 5` keeps a failed row and `boom --code 0` a successful one.
#   - App "rank" records its exit status; in "fail" mode rank 0 returns non-zero,
#     so its per-app row (and the eager runs row) record a non-zero code.
#   - Job "runjob" launches the app with `knit run`, tolerating a failed run so
#     the job body itself succeeds (the job is NOT a failed job; the run is).
#
# The driver checks that `remove command --failed` erases only the failed plain
# command and leaves the failed run/app untouched, and that `remove run --failed`
# maps the failed app body up to its launch row (refused under the kept job,
# erased with --from-root).

source knit.sh

knit_set_program_description \
    "per-kind remove --failed integration test experiment."

# A plain command that records its exit status.
knit_register "boom" __boom_fn "Return the given exit code, recording it."
knit_with_table
knit_with_optional "code:integer" "0" "Exit code to return."
__boom_fn() {
    return "$(knit_get_parameter "code" "$@")"
}
knit_done

# An app that can fail, recording its exit status on its per-app row.
knit_register_app "rank" __rank_fn "A rank that can fail, recording its exit status."
knit_with_optional "mode:string" "ok" "ok = succeed; fail = rank 0 returns non-zero."
knit_with_output "size:integer" "0" "World size observed by rank 0."
__rank_fn() {
    local mode
    mode=$(knit_get_parameter "mode" "$@")
    knit_output "size" "${KNIT_MPI_SIZE}"
    [[ "${mode}" == "fail" ]] && return 7
    return 0
}
knit_done

# A job that launches the rank app, tolerating a failed run so the job completes
# (its body exits 0, so the job itself is not a failed job).
knit_register_job "runjob" __runjob_fn "Launch the rank app inside a job."
knit_with_optional "mode:string" "ok" "Mode forwarded to the rank app."
__runjob_fn() {
    local mode
    mode=$(knit_get_parameter "mode" "$@")
    knit run --procs 1 -- rank --mode "${mode}" || true
}
knit_done

knit "$@"
