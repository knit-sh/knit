#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# ---------- _knit_history_create_table ----------

@test "create table makes the __history__ table" {
    _knit_history_create_table
    local n
    n=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='__history__';")
    [ "$n" -eq 1 ]
}

@test "create table defines the schema columns in order" {
    _knit_history_create_table
    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" \
        "PRAGMA table_info('__history__');" | cut -d'|' -f2 | tr '\n' ',')
    [ "$names" = "id,command,invoked,resolved,start_time,end_time,exit_status," ]
}

@test "create table gives the timestamp columns REAL affinity" {
    _knit_history_create_table
    local start_type end_type
    start_type=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT type FROM pragma_table_info('__history__') WHERE name='start_time';")
    end_type=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT type FROM pragma_table_info('__history__') WHERE name='end_time';")
    [ "$start_type" = "REAL" ]
    [ "$end_type" = "REAL" ]
}

@test "create table gives exit_status INTEGER affinity" {
    _knit_history_create_table
    local exit_type
    exit_type=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT type FROM pragma_table_info('__history__') WHERE name='exit_status';")
    [ "$exit_type" = "INTEGER" ]
}

@test "create table is idempotent" {
    _knit_history_create_table
    _knit_history_create_table
    local n
    n=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='__history__';")
    [ "$n" -eq 1 ]
}

# ---------- _knit_history_ensure_table ----------

@test "ensure table creates the table on first use" {
    _knit_history_ensure_table
    local n
    n=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='__history__';")
    [ "$n" -eq 1 ]
    [ "${_KNIT_HISTORY_TABLE_ENSURED}" = "1" ]
}

@test "ensure table runs the create at most once per process" {
    _knit_history_ensure_table
    # Drop the table behind the guard's back; a second ensure must be a no-op
    # (the guard is set), so the table stays absent.
    sqlite3 "${_KNIT_DATABASE}" "DROP TABLE __history__;"
    _knit_history_ensure_table
    local n
    n=$(sqlite3 "${_KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='__history__';")
    [ "$n" -eq 0 ]
}
