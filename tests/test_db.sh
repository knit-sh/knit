#!/usr/bin/env bats

setup() {
    if ! command -v sqlite3 &>/dev/null; then
        skip "sqlite3 not available"
    fi

    source knit.sh

    # Override the sqlite executable and database path for testing
    __KNIT_SQLITE_EXE="sqlite3"
    __KNIT_DATABASE="$(mktemp --suffix=.db)"
}

teardown() {
    rm -f "${__KNIT_DATABASE}"
}

# ---------- __knit_db_create_table ----------

@test "create table creates the table in the database" {
    __knit_db_create_table "runs" "id:uuid" "duration:real"
    local result
    result=$(sqlite3 "${__KNIT_DATABASE}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='runs';")
    [ "$result" -eq 1 ]
}

@test "create table stores correct column names and types" {
    __knit_db_create_table "runs" "id:uuid" "count:integer" "label:string"
    local names types
    names=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('runs');" | cut -d'|' -f2)
    types=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('runs');" | cut -d'|' -f3)
    [ "$(echo "$names" | sed -n '1p')" = "id" ]
    [ "$(echo "$types" | sed -n '1p')" = "TEXT" ]
    [ "$(echo "$names" | sed -n '2p')" = "count" ]
    [ "$(echo "$types" | sed -n '2p')" = "INTEGER" ]
    [ "$(echo "$names" | sed -n '3p')" = "label" ]
    [ "$(echo "$types" | sed -n '3p')" = "TEXT" ]
}

@test "create table fails if table already exists" {
    __knit_db_create_table "runs" "id:uuid"
    run __knit_db_create_table "runs" "id:uuid"
    [ "$status" -ne 0 ]
}

@test "create table fails with zero columns" {
    run __knit_db_create_table "runs"
    [ "$status" -ne 0 ]
}

@test "create table fails with malformed column spec" {
    run __knit_db_create_table "runs" "id"
    [ "$status" -ne 0 ]
}

@test "create table fails with unknown column type" {
    run __knit_db_create_table "runs" "id:unknowntype"
    [ "$status" -ne 0 ]
}

@test "create table normalizes hyphen in column name" {
    __knit_db_create_table "runs" "my-col:integer"
    local name
    name=$(sqlite3 "${__KNIT_DATABASE}" "PRAGMA table_info('runs');" | cut -d'|' -f2)
    [ "$name" = "my_col" ]
}

# ---------- __knit_db_check_table ----------

@test "check table returns 1 for absent table" {
    run __knit_db_check_table "absent" "id:uuid"
    [ "$status" -eq 1 ]
}

@test "check table returns 0 for exact match" {
    __knit_db_create_table "runs" "id:uuid" "count:integer"
    run __knit_db_check_table "runs" "id:uuid" "count:integer"
    [ "$status" -eq 0 ]
}

@test "check table returns 2 when expected has fewer columns than actual" {
    __knit_db_create_table "runs" "id:uuid" "count:integer"
    run __knit_db_check_table "runs" "id:uuid"
    [ "$status" -eq 2 ]
}

@test "check table returns 2 when expected has more columns than actual" {
    __knit_db_create_table "runs" "id:uuid"
    run __knit_db_check_table "runs" "id:uuid" "count:integer"
    [ "$status" -eq 2 ]
}

@test "check table returns 2 on column name mismatch" {
    __knit_db_create_table "runs" "id:uuid" "count:integer"
    run __knit_db_check_table "runs" "id:uuid" "amount:integer"
    [ "$status" -eq 2 ]
}

@test "check table returns 2 on column type mismatch" {
    __knit_db_create_table "runs" "id:uuid" "count:integer"
    run __knit_db_check_table "runs" "id:uuid" "count:real"
    [ "$status" -eq 2 ]
}

@test "check table returns 2 on column order mismatch" {
    __knit_db_create_table "runs" "id:uuid" "count:integer"
    run __knit_db_check_table "runs" "count:integer" "id:uuid"
    [ "$status" -eq 2 ]
}
