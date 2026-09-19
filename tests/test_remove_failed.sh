#!/usr/bin/env bats

# "remove --failed": erase every invocation with a non-zero recorded
# __exit_status__ (and, under --from-root, the jobs that contain them). See
# src/remove.sh (_knit_remove_failed_ids / _knit_remove_toplevel /
# _knit_remove_erase_selection).

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    _KNIT_DB_REGISTERED_TABLES=()
}

teardown() {
    knit_test_db_teardown
}

# Fixed framework roots so the report builder needs no metadata.
_stub_roots() {
    _knit_job_root()      { local -n __r=$1; __r=/ROOT/jobs; }
    _knit_setup_root()    { local -n __r=$1; __r=/ROOT/setups; }
    _knit_resource_root() { local -n __r=$1; __r=/ROOT/resources; }
    _knit_artifact_root() { local -n __r=$1; __r=/ROOT/artifacts; }
}

# ---------- _knit_remove_failed_ids ----------

@test "_knit_remove_failed_ids collects only non-zero-integer exit statuses" {
    _knit_sqlite3 "
        CREATE TABLE foo (id TEXT, __exit_status__ INTEGER);
        CREATE TABLE runs (id TEXT, app TEXT, __exit_status__ INTEGER);
        CREATE TABLE jobs (id TEXT, state TEXT);
        INSERT INTO foo VALUES ('F_ok',0),('F_fail',2),('F_null',NULL),('F_unknown','');
        INSERT INTO runs VALUES ('U_ok','a',0),('U_fail','a',7);
        INSERT INTO jobs VALUES ('J1','completed');
    "
    local -a got=()
    _knit_remove_failed_ids got
    local sorted
    sorted=$(printf '%s\n' "${got[@]}" | sort | tr '\n' ' ')
    # Only genuine non-zero integers: 0, NULL, the empty migration value, and the
    # column-less jobs table are all excluded.
    [ "${sorted}" = "F_fail U_fail " ]
}

@test "_knit_remove_failed_ids is empty when nothing failed" {
    _knit_sqlite3 "
        CREATE TABLE foo (id TEXT, __exit_status__ INTEGER);
        INSERT INTO foo VALUES ('F_ok',0),('F_null',NULL);
    "
    local -a got=(placeholder)
    _knit_remove_failed_ids got
    [ "${#got[@]}" -eq 0 ]
}

# ---------- remove --failed ----------

@test "remove --failed reports the failed rows and not the clean ones" {
    _stub_roots
    _knit_sqlite3 "
        CREATE TABLE foo (id TEXT, __exit_status__ INTEGER);
        INSERT INTO foo VALUES ('F_ok',0),('F_fail',2);
    "
    _KNIT_DB_REGISTERED_TABLES[foo]=foo
    printf -v "_KNIT_CMD_foo_type" '%s' command
    run _knit_invoke_command remove --failed --dry-run
    [ "$status" -eq 0 ]
    [[ "${output}" == *"F_fail"* ]]
    [[ "${output}" != *"F_ok"* ]]
}

@test "remove --failed with no failures reports nothing to erase" {
    _knit_sqlite3 "
        CREATE TABLE foo (id TEXT, __exit_status__ INTEGER);
        INSERT INTO foo VALUES ('F_ok',0),('F_null',NULL);
    "
    _KNIT_DB_REGISTERED_TABLES[foo]=foo
    printf -v "_KNIT_CMD_foo_type" '%s' command
    run _knit_invoke_command remove --failed
    [ "$status" -eq 0 ]
    [[ "${output}" == *"no failed invocations"* ]]
}

@test "remove without --failed and no subcommand guides the user" {
    run _knit_invoke_command remove
    [ "$status" -ne 0 ]
    [[ "${output}" == *"--failed"* ]]
}

@test "remove --failed actually deletes the failed row with --yes" {
    _stub_roots
    # The deletion transaction clears provenance edges too, so the table must
    # exist (it always does after bootstrap).
    _knit_prov_ensure_table
    _knit_sqlite3 "
        CREATE TABLE foo (id TEXT, __exit_status__ INTEGER);
        INSERT INTO foo VALUES ('F_ok',0),('F_fail',2);
    "
    _KNIT_DB_REGISTERED_TABLES[foo]=foo
    printf -v "_KNIT_CMD_foo_type" '%s' command
    run _knit_invoke_command remove --failed --yes
    [ "$status" -eq 0 ]
    # The failed row is gone; the successful one stays.
    [ "$(_knit_sqlite3 "SELECT COUNT(*) FROM foo WHERE id='F_fail';")" -eq 0 ]
    [ "$(_knit_sqlite3 "SELECT COUNT(*) FROM foo WHERE id='F_ok';")" -eq 1 ]
}

# ---------- transitive removal via --from-root ----------

@test "remove --failed --from-root erases the job that contains a failed run" {
    _stub_roots
    _knit_sqlite3 "
        CREATE TABLE jobs (id TEXT, name TEXT, \"group\" TEXT, state TEXT);
        CREATE TABLE runs (id TEXT, app TEXT, __exit_status__ INTEGER);
        CREATE TABLE __provenance__ (source_id TEXT, source_name TEXT,
            target_id TEXT, target_name TEXT, edge_type TEXT,
            start_time INTEGER, end_time INTEGER, alias TEXT);
        INSERT INTO jobs VALUES ('J1','myjob','g','completed');
        INSERT INTO runs VALUES ('U_fail','a',7);
        INSERT INTO __provenance__ VALUES ('J1','submit','U_fail','run','call',1,2,NULL);
    "
    _KNIT_DB_REGISTERED_TABLES[jobs]=submit
    _KNIT_DB_REGISTERED_TABLES[runs]=run
    run _knit_invoke_command remove --failed --from-root --dry-run
    [ "$status" -eq 0 ]
    [[ "${output}" == *"U_fail"* ]]
    [[ "${output}" == *"J1"* ]]
}

@test "remove --failed without --from-root refuses a failed run whose job is kept" {
    _stub_roots
    _knit_sqlite3 "
        CREATE TABLE jobs (id TEXT, name TEXT, \"group\" TEXT, state TEXT);
        CREATE TABLE runs (id TEXT, app TEXT, __exit_status__ INTEGER);
        CREATE TABLE __provenance__ (source_id TEXT, source_name TEXT,
            target_id TEXT, target_name TEXT, edge_type TEXT,
            start_time INTEGER, end_time INTEGER, alias TEXT);
        INSERT INTO jobs VALUES ('J1','myjob','g','completed');
        INSERT INTO runs VALUES ('U_fail','a',7);
        INSERT INTO __provenance__ VALUES ('J1','submit','U_fail','run','call',1,2,NULL);
    "
    _KNIT_DB_REGISTERED_TABLES[jobs]=submit
    _KNIT_DB_REGISTERED_TABLES[runs]=run
    run _knit_invoke_command remove --failed
    [ "$status" -ne 0 ]
    [[ "${output}" == *"--from-root"* ]]
}
