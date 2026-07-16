#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    # Start from a clean run/job environment so nothing leaks between tests.
    unset KNIT_JOB_PREFIX KNIT_RUN_ID KNIT_SOURCE_ID KNIT_SOURCE_COMMAND
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
    unset KNIT_JOB_PREFIX KNIT_RUN_ID KNIT_SOURCE_ID KNIT_SOURCE_COMMAND
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
    # _knit_run builds the launcher argv (for the native_cmd column) and then
    # launches; stub both so the (over-specified for `none`) placement these tests
    # use to exercise recording is not rejected by the real backend.
    _knit_launch_cmdline() { local -n _argv="$3"; _argv=(launcher); }
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
        "SELECT id, app, procs, procs_per_node, hostnames FROM runs;"
    [ "$output" = "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa|myapp|4|2|nodeA,nodeB" ]
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

@test "dispatcher records the resolved launcher command in native_cmd" {
    _stub_dispatch
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"

    _knit_invoke_command run --procs 2 -- myapp --n 5

    # native_cmd is the launcher argv (from the stubbed cmdline) followed by the
    # per-rank worker re-entry (KNIT_SCRIPT_PATH _run -- <app> <args>).
    run sqlite3 "${_KNIT_DATABASE}" "SELECT native_cmd FROM runs;"
    [ "$output" = "launcher ./exp.sh _run -- myapp --n 5" ]
}

# ---------- per-app row: rank-0 recording under a fresh distinct id ----------

@test "rank 0 records the per-app row under a fresh distinct id" {
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    _knit_uuidv7() { printf '%s' "bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb"; }

    # Rank 0 re-enters the app command directly (as the worker does); the per-app
    # row now mints its own id rather than reusing the run UUID (the provenance
    # edge links them).
    _knit_invoke_command run myapp --n 7

    run sqlite3 "${_KNIT_DATABASE}" "SELECT id, n FROM myapp;"
    [ "$output" = "bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb|7" ]
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM myapp;")" != "${KNIT_RUN_ID}" ]
}

@test "non-root ranks record no per-app row" {
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    # A non-root rank sets the generic suppression flag (as the worker does).
    _KNIT_RECORDING_SUPPRESSED="1"

    _knit_invoke_command run myapp --n 7

    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM myapp;")" = "0" ]
}

# ---------- provenance edge: run -> run:<app> ----------

@test "rank 0 records the run -> run:<app> call edge from the exported context" {
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    # The dispatcher's launch subshell exports these; simulate rank 0 seeing them.
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    export KNIT_SOURCE_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    export KNIT_SOURCE_COMMAND="run"
    _knit_uuidv7() { printf '%s' "bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb"; }

    _knit_invoke_command run myapp --n 7

    # The edge's source is the run (from the env carriers); its target is the
    # per-app row id, joining the myapp row to the run.
    local target_id
    target_id="$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM myapp;")"
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT source_id,source_name,target_id,target_name,edge_type FROM __provenance__;")" \
        = "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa|run|${target_id}|run:myapp|call" ]
}

@test "non-root ranks record no provenance edge" {
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    export KNIT_SOURCE_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    export KNIT_SOURCE_COMMAND="run"
    _KNIT_RECORDING_SUPPRESSED="1"

    _knit_invoke_command run myapp --n 7

    # A suppressed rank records nothing, so the edge table is never even created;
    # ensure it exists before asserting it holds no edge.
    _knit_prov_ensure_table
    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM __provenance__;")" = "0" ]
}

@test "the runs row and the per-app row have distinct ids" {
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    # Use the real (random) uuid generator so each minted id genuinely differs:
    # the dispatcher's runs row and rank 0's per-app row now mint their own ids
    # (the provenance edge is what links them rather than a shared id). A
    # deterministic stub cannot be used here because
    # _knit_uuidv7 is invoked via command substitution (a subshell), so any
    # counter it increments would not persist between calls.
    knit_job_hostnames() { printf '%s\n' "nodeA" "nodeB"; }
    _knit_metadata_load() { printf '%s' ""; }
    _knit_launch_backend() { printf '%s' "none"; }
    _knit_launch_cmdline() { local -n _argv="$3"; _argv=(launcher); }
    _knit_launch_exec() { return 0; }

    # Dispatcher writes the runs row under its own id...
    _knit_invoke_command run --procs 2 -- myapp
    # ...and rank 0 writes the per-app row under a different id.
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    _knit_invoke_command run myapp --n 3

    local runs_id app_id
    runs_id="$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM runs;")"
    app_id="$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM myapp;")"
    knit_type_check "uuid" "${runs_id}"
    knit_type_check "uuid" "${app_id}"
    [ "${runs_id}" != "${app_id}" ]
}
