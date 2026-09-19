#!/usr/bin/env bash
# Integration test experiment 31_exit_status.
#
# Exercises exit-status recording and `remove --failed` end to end on a real
# scheduler with a real MPI launcher:
#
#   - Plain command "boom" declares a table and is NOT no_record_on_failure, so
#     it gets a reserved __exit_status__ column. It returns the code given by
#     --code, so `boom --code 5` records a failed row (kept, not discarded) and
#     `boom --code 0` records a successful one.
#   - App "rank" also records its exit status. In "fail" mode rank 0 returns
#     non-zero; because the app does NOT opt out, the failed per-app row and the
#     eagerly-recorded runs row both survive and record their non-zero code.
#   - Job "runjob" launches the app with `knit run --procs 1 -- rank --mode M`,
#     tolerating a failed run so the job itself completes and the database can be
#     inspected afterwards.
#
# The driver (test.sh) submits the job in both modes, asserts __exit_status__ was
# recorded across the plain command, the runs table, and the per-app table, then
# prunes the failures with `remove --failed --from-root` and checks the clean
# work survives.

source knit.sh

knit_set_program_description \
    "exit-status recording + remove --failed integration test experiment."

# A plain command that records its exit status. Declaring a table (and not opting
# out of recording on failure) gives it the reserved __exit_status__ column.
knit_register "boom" __boom_fn "Return the given exit code, recording it."
knit_with_table
knit_with_optional "code:integer" "0" "Exit code to return."
__boom_fn() {
    return "$(knit_get_parameter "code" "$@")"
}
knit_done

# An app that can fail. It is NOT no_record_on_failure, so a failed rank keeps
# its per-app row (with __exit_status__) and the eager runs row keeps its own.
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

# A job that launches the rank app, tolerating a failed run so the job completes.
knit_register_job "runjob" __runjob_fn "Launch the rank app inside a job."
knit_with_optional "mode:string" "ok" "Mode forwarded to the rank app."
__runjob_fn() {
    local mode
    mode=$(knit_get_parameter "mode" "$@")
    knit run --procs 1 -- rank --mode "${mode}" || true
}
knit_done

knit "$@"
