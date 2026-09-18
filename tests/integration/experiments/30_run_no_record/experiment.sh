#!/usr/bin/env bash
# Integration test experiment 30_run_no_record.
#
# Exercises the interaction between `knit run` and an app that opts out of
# recording a failed invocation (knit_no_record_on_failure):
#
#   - App "boom" declares knit_no_record_on_failure. In "fail" mode its body
#     returns non-zero (a failed rank), so the launcher reports failure; in "ok"
#     mode it records an output and succeeds. Rank 0 records the per-app row only
#     on success.
#   - Job "run_boom" launches the app from inside a real job with
#     `knit run --procs 1 -- boom --mode <mode>`, tolerating a failed run so the
#     job itself completes and the driver can inspect the database afterwards.
#
# The driver submits the job twice. A failed run must leave NO runs-table row:
# the dispatcher records the runs row eagerly (before launch) so a failure leaves
# a trace by default, but when the launched app opted out and the run then fails,
# that row would join to nothing (the per-app row and the run -> run:<app> edge
# were never written), so the dispatcher removes it. A successful run must leave
# exactly one runs row joined to one per-app row.

source knit.sh

knit_set_program_description \
    "knit run + no_record_on_failure integration test experiment."

knit_register_app "boom" __boom_app_fn "An app that opts out of recording on failure."
knit_no_record_on_failure
knit_with_optional "mode:string" "ok" "ok = succeed and record; fail = return non-zero."
knit_with_output "observed:integer" "0" "World size observed by rank 0 (ok mode only)."
__boom_app_fn() {
    local mode
    mode=$(knit_get_parameter "mode" "$@")
    if [[ "${mode}" == "fail" ]]; then
        # A failed rank: return non-zero so the launcher reports failure and the
        # run dispatcher's failure-cleanup path runs.
        return 1
    fi
    knit_output "observed" "${KNIT_MPI_SIZE}"
}
knit_done

knit_register_job "run_boom" __run_boom_job_fn "Launch the boom app inside a job."
knit_with_optional "mode:string" "ok" "Mode forwarded to the boom app."
__run_boom_job_fn() {
    local mode
    mode=$(knit_get_parameter "mode" "$@")
    # Tolerate a failed run so the job completes and the database can be inspected;
    # the run dispatcher has already recorded (and, on failure, removed) its row.
    knit run --procs 1 -- boom --mode "${mode}" || true
}
knit_done

knit "$@"
