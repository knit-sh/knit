#!/usr/bin/env bats

setup() {
    if ! command -v sqlite3 &>/dev/null; then
        skip "sqlite3 not available"
    fi

    source knit.sh

    # Override the sqlite executable and database path for testing
    __KNIT_SQLITE_EXE="sqlite3"
    __KNIT_DATABASE="$(mktemp --suffix=.db)"

    # Satisfy the bootstrap check — tests in this file work with a live DB
    _KNIT_IS_BOOTSTRAPPED="1"
}

teardown() {
    rm -f "${__KNIT_DATABASE}"
    _KNIT_IS_BOOTSTRAPPED=""
}

# ---------- _knit_sql_escape ----------

@test "sql escape returns plain string unchanged" {
    local result
    result=$(_knit_sql_escape "hello")
    [ "$result" = "hello" ]
}

@test "sql escape doubles single quotes" {
    local result
    result=$(_knit_sql_escape "it's")
    [ "$result" = "it''s" ]
}

@test "sql escape handles multiple single quotes" {
    local result
    result=$(_knit_sql_escape "it's a 'test'")
    [ "$result" = "it''s a ''test''" ]
}

@test "sql escape handles string with no special characters" {
    local result
    result=$(_knit_sql_escape "hello world 123")
    [ "$result" = "hello world 123" ]
}

@test "sql escape handles empty string" {
    local result
    result=$(_knit_sql_escape "")
    [ -z "$result" ]
}

# ---------- _knit_sqlite3 ----------

@test "_knit_sqlite3 executes a query and returns output" {
    local result
    result=$(_knit_sqlite3 "SELECT 42;")
    [ "$result" = "42" ]
}

@test "_knit_sqlite3 returns empty output for empty result set" {
    _knit_sqlite3 "CREATE TABLE t (x TEXT);"
    local result
    result=$(_knit_sqlite3 "SELECT * FROM t;")
    [ -z "$result" ]
}

@test "_knit_sqlite3 returns multiple rows" {
    _knit_sqlite3 "CREATE TABLE t (x TEXT); INSERT INTO t VALUES ('a'), ('b');"
    local count
    count=$(_knit_sqlite3 "SELECT COUNT(*) FROM t;")
    [ "$count" -eq 2 ]
}

@test "_knit_sqlite3 fails on invalid SQL" {
    run _knit_sqlite3 "NOT VALID SQL;"
    [ "$status" -ne 0 ]
}
