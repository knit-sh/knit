#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# ---------- _knit_sql_escape ----------

@test "sql escape returns plain string unchanged" {
    local result
    _knit_sql_escape result "hello"
    [ "$result" = "hello" ]
}

@test "sql escape doubles single quotes" {
    local result
    _knit_sql_escape result "it's"
    [ "$result" = "it''s" ]
}

@test "sql escape handles multiple single quotes" {
    local result
    _knit_sql_escape result "it's a 'test'"
    [ "$result" = "it''s a ''test''" ]
}

@test "sql escape handles string with no special characters" {
    local result
    _knit_sql_escape result "hello world 123"
    [ "$result" = "hello world 123" ]
}

@test "sql escape handles empty string" {
    local result
    _knit_sql_escape result ""
    [ -z "$result" ]
}

# ---------- _knit_sql_quote_identifier ----------

@test "sql quote identifier wraps a plain name in double quotes" {
    local result
    _knit_sql_quote_identifier result "runs"
    [ "$result" = '"runs"' ]
}

@test "sql quote identifier quotes a name containing a colon" {
    local result
    _knit_sql_quote_identifier result "aaa:bbb"
    [ "$result" = '"aaa:bbb"' ]
}

@test "sql quote identifier doubles embedded double quotes" {
    local result
    _knit_sql_quote_identifier result 'a"b'
    [ "$result" = '"a""b"' ]
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
