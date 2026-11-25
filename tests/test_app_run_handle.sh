#!/usr/bin/env bats

# Pre-mint + inject of the per-app row id: the `run` dispatcher mints the app row
# id up front and exports it (KNIT_RUN_APP_ROW_ID); the per-rank worker, on rank 0
# only, injects it as the app frame's row id so the per-app row records under that
# known id. The id stays distinct from the runs id and the run -> run:<app> edge
# is unchanged.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup
    # The `run` dispatcher's placement params carry enum constraints evaluated via jq.
    _KNIT_JQ_EXE="jq"

    # Clean run/job and launcher-native MPI environment so nothing leaks in.
    unset KNIT_JOB_PREFIX KNIT_RUN_ID KNIT_SOURCE_ID KNIT_SOURCE_COMMAND
    unset KNIT_MPI_RANK KNIT_MPI_SIZE KNIT_MPI_LOCAL_RANK KNIT_RUN_APP_ROW_ID
    unset OMPI_COMM_WORLD_RANK PMI_RANK SLURM_PROCID PALS_RANKID FLUX_TASK_RANK
    _KNIT_RECORDING_SUPPRESSED=""
    KNIT_SCRIPT_PATH="./exp.sh"
    _knit_prov_create_table

    _rh_app_fn() { :; }
    knit_register_app "myapp" "_rh_app_fn" "A run-handle test app."
    knit_with_optional "n:integer" "1" "Problem size."
    knit_done
}

teardown() {
    unset KNIT_JOB_PREFIX KNIT_RUN_ID KNIT_SOURCE_ID KNIT_SOURCE_COMMAND
    unset KNIT_RUN_APP_ROW_ID
    _KNIT_RECORDING_SUPPRESSED=""
    knit_test_db_teardown
}

# ---------- rank 0 adopts the injected id ----------

@test "rank 0 records the per-app row under the injected id" {
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    export KNIT_RUN_APP_ROW_ID="cccccccc-cccc-7ccc-8ccc-cccccccccccc"
    # Rank 0: no launcher-native rank vars set, so normalize resolves rank 0.

    _knit_run_worker -- myapp --n 7

    run sqlite3 "${_KNIT_DATABASE}" "SELECT id, n FROM myapp;"
    [ "$output" = "cccccccc-cccc-7ccc-8ccc-cccccccccccc|7" ]
}

@test "the run -> run:<app> edge target is the injected id" {
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    export KNIT_SOURCE_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    export KNIT_SOURCE_COMMAND="run"
    export KNIT_RUN_APP_ROW_ID="cccccccc-cccc-7ccc-8ccc-cccccccccccc"

    _knit_run_worker -- myapp --n 7

    # The edge still joins the run to the per-app row; its target is the injected
    # id, which stays distinct from the run (source) id.
    [ "$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT source_id,target_id,target_name,edge_type FROM __provenance__;")" \
        = "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa|cccccccc-cccc-7ccc-8ccc-cccccccccccc|run:myapp|call" ]
    [ "${KNIT_SOURCE_ID}" != "${KNIT_RUN_APP_ROW_ID}" ]
}

# ---------- non-root rank: no record, ignores the injected id ----------

@test "a non-root rank records no per-app row and ignores the injected id" {
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    export KNIT_RUN_APP_ROW_ID="cccccccc-cccc-7ccc-8ccc-cccccccccccc"
    # Rank 1 via a launcher-native variable.
    export OMPI_COMM_WORLD_RANK=1

    _knit_run_worker -- myapp --n 7

    [ "$(sqlite3 "${_KNIT_DATABASE}" "SELECT COUNT(*) FROM myapp;")" = "0" ]
}

# ---------- rank 0 without an injected id: fresh distinct id (compat) ----------

@test "rank 0 with no injected id mints a fresh distinct id" {
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    export KNIT_RUN_ID="aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    # KNIT_RUN_APP_ROW_ID intentionally unset (e.g. a direct, non-dispatched call).
    _knit_uuidv7() { printf '%s' "bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb"; }

    _knit_run_worker -- myapp --n 7

    run sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM myapp;"
    [ "$output" = "bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb" ]
    [ "$output" != "${KNIT_RUN_ID}" ]
}

# ---------- dispatcher exposes KNIT_LAST_RUN_UUID / KNIT_LAST_RUN_TABLE ----------

# Stub the dispatcher's launch chain, and have the launcher simulate rank 0: the
# dispatcher's subshell has already exported KNIT_RUN_APP_ROW_ID and the source
# context, and app_name / app_args are visible here by bash dynamic scoping (this
# runs from within _knit_run), so running the worker records the per-app row under
# the pre-minted id — exactly as a real rank 0 would.
_stub_dispatch_with_rank0() {
    knit_job_hostnames() { printf '%s\n' "nodeA"; }
    _knit_metadata_get() { local -n __r=$1; __r=''; }
    _knit_launch_backend() { local -n __r=$1; __r='none'; }
    _knit_launch_cmdline() { local -n _argv="$3"; _argv=(launcher); }
    _knit_launch_exec() { _knit_run_worker -- "${app_name}" "${app_args[@]}"; }
}

# Stub that reports a failed launch without recording any per-app row.
_stub_dispatch_failed() {
    knit_job_hostnames() { printf '%s\n' "nodeA"; }
    _knit_metadata_get() { local -n __r=$1; __r=''; }
    _knit_launch_backend() { local -n __r=$1; __r='none'; }
    _knit_launch_cmdline() { local -n _argv="$3"; _argv=(launcher); }
    _knit_launch_exec() { return 1; }
}

_register_optout_app() {
    _rh_optout_fn() { :; }
    knit_register_app "optout" "_rh_optout_fn" "An opt-out run-handle app."
    knit_no_record_on_failure
    knit_done
}

@test "a successful run exposes the per-app row as KNIT_LAST_RUN_UUID/TABLE" {
    _stub_dispatch_with_rank0
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    KNIT_LAST_RUN_UUID="stale"
    KNIT_LAST_RUN_TABLE="stale"

    _knit_invoke_command run --procs 1 -- myapp --n 5

    local app_id runs_id
    app_id="$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM myapp;")"
    runs_id="$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM runs;")"
    [ -n "${app_id}" ]
    # The handle names the real per-app row (recorded under the pre-minted id) in
    # the app's own table, and stays distinct from the runs row id.
    [ "${KNIT_LAST_RUN_UUID}" = "${app_id}" ]
    [ "${KNIT_LAST_RUN_TABLE}" = "myapp" ]
    [ "${KNIT_LAST_RUN_UUID}" != "${runs_id}" ]
}

@test "a failed non-opt-out run still exposes the per-app row handle" {
    _stub_dispatch_failed
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    KNIT_LAST_RUN_UUID="stale"
    KNIT_LAST_RUN_TABLE="stale"

    local st=0
    _knit_invoke_command run --procs 1 -- myapp --n 5 || st=$?
    [ "${st}" -eq 1 ]

    # myapp did not opt out: its row survives as the failure trace, so the handle
    # names it (a fresh uuid, distinct from the runs row id) in the app's table.
    knit_type_check "uuid" "${KNIT_LAST_RUN_UUID}"
    [ "${KNIT_LAST_RUN_TABLE}" = "myapp" ]
    local runs_id
    runs_id="$(sqlite3 "${_KNIT_DATABASE}" "SELECT id FROM runs;")"
    [ "${KNIT_LAST_RUN_UUID}" != "${runs_id}" ]
}

@test "an opt-out failed run empties KNIT_LAST_RUN_UUID/TABLE" {
    _stub_dispatch_failed
    _register_optout_app
    export KNIT_JOB_PREFIX="/some/where/jobs/job-uuid"
    KNIT_LAST_RUN_UUID="stale"
    KNIT_LAST_RUN_TABLE="stale"

    local st=0
    _knit_invoke_command run --procs 1 -- optout || st=$?
    [ "${st}" -eq 1 ]

    # The per-app row was removed with the runs row; leave no stale handle.
    [ -z "${KNIT_LAST_RUN_UUID}" ]
    [ -z "${KNIT_LAST_RUN_TABLE}" ]
}
