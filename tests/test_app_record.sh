#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    # Start from a clean run/job environment so nothing leaks between tests.
    unset KNIT_JOB_PREFIX KNIT_RUN_ID
    unset KNIT_MPI_RANK KNIT_MPI_SIZE KNIT_MPI_LOCAL_RANK
    _KNIT_RECORDING_SUPPRESSED=""
    KNIT_SCRIPT_PATH="./exp.sh"

    # Register a tiny app to record. Its before-callback requires KNIT_JOB_PREFIX,
    # which each test sets before invoking anything.
    _rec_app_fn() { :; }
    knit_register_app "myapp" "_rec_app_fn" "A recording test app."
    knit_with_optional "n:integer" "1" "Problem size."
    knit_done
}

teardown() {
    unset KNIT_JOB_PREFIX KNIT_RUN_ID
    _KNIT_RECORDING_SUPPRESSED=""
    knit_test_db_teardown
}

# The dispatcher launches through a stubbed launcher; the run's own recording
# happens in the parent process before the launch, so these stubs never interfere
# with the runs-table assertions.
_stub_dispatch() {
    knit_job_hostnames() { printf '%s\n' "nodeA" "nodeB"; }
    _knit_metadata_load() { printf '%s' ""; }
    _knit_launch_backend() { printf '%s' "none"; }
    _knit_launch_exec() { return 0; }
    _knit_uuidv7() { printf '%s' "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"; }
}

# ---------- runs row: resolved placement ----------

@test "dispatcher records the runs row with the app and resolved placement" {
    _stub_dispatch
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"

    _knit_invoke_command run --procs 4 --hostnames nodeA,nodeB -- myapp --n 5

    # The row id is the run UUID; app is the launched app; the placement columns
    # hold the RESOLVED values (procs 4 over 2 hosts => 2 per node).
    run sqlite3 "${_KNIT_DATABASE}" \
        "SELECT id, app, procs, procs_per_node, hostnames, job FROM runs;"
    [ "$output" = "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa|myapp|4|2|nodeA,nodeB|job-uuid" ]
}

@test "dispatcher overwrites empty as-requested placement with resolved values" {
    _stub_dispatch
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"

    # A bare run requests no placement; the row must still record what ran (one
    # rank per allocated node, as the per-node core count is unknown here).
    _knit_invoke_command run -- myapp

    run sqlite3 "${_KNIT_DATABASE}" "SELECT procs, hostnames FROM runs;"
    [ "$output" = "2|nodeA,nodeB" ]
}

@test "dispatcher records exactly one runs row" {
    _stub_dispatch
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"

    _knit_invoke_command run --procs 2 -- myapp

    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM runs;")" = "1" ]
}

# ---------- per-app row: rank-0 recording keyed by the run UUID ----------

@test "rank 0 records the per-app row under the run UUID" {
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"

    # Rank 0 re-enters the app command directly (as the worker does); the per-app
    # row's id is the run UUID, not the job UUID, so it joins the runs row.
    _knit_invoke_command run myapp --n 7

    run sqlite3 "${_KNIT_DATABASE}" "SELECT id, n FROM myapp;"
    [ "$output" = "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa|7" ]
}

@test "non-root ranks record no per-app row" {
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    # A non-root rank sets the generic suppression flag (as the worker does).
    _KNIT_RECORDING_SUPPRESSED="1"

    _knit_invoke_command run myapp --n 7

    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM myapp;")" = "0" ]
}

@test "the runs row and the per-app row share the run UUID" {
    _stub_dispatch
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"

    # Dispatcher writes the runs row under the (stubbed) run UUID...
    _knit_invoke_command run --procs 2 -- myapp
    # ...and rank 0 (KNIT_RUN_ID forwarded by the launcher) writes the per-app row
    # under the same UUID.
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    _knit_invoke_command run myapp --n 3

    local runs_id app_id
    runs_id="$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM runs;")"
    app_id="$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM myapp;")"
    [ "${runs_id}" = "${app_id}" ]
    [ "${runs_id}" = "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa" ]
}
