#!/usr/bin/env bats

setup() {
    if ! command -v sqlite3 &>/dev/null; then
        skip "sqlite3 not available"
    fi

    source knit.sh

    # Override the sqlite executable and database path for testing
    __KNIT_SQLITE_EXE="sqlite3"
    __KNIT_DATABASE="$(mktemp --suffix=.db)"

    sqlite3 "${__KNIT_DATABASE}" \
        "CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT);"
}

teardown() {
    rm -f "${__KNIT_DATABASE}"
}

# ---------- __knit_sql_escape ----------

@test "sql escape returns plain string unchanged" {
    local result
    result=$(__knit_sql_escape "hello")
    [ "$result" = "hello" ]
}

@test "sql escape doubles single quotes" {
    local result
    result=$(__knit_sql_escape "it's")
    [ "$result" = "it''s" ]
}

@test "sql escape handles multiple single quotes" {
    local result
    result=$(__knit_sql_escape "it's a 'test'")
    [ "$result" = "it''s a ''test''" ]
}

@test "sql escape handles string with no special characters" {
    local result
    result=$(__knit_sql_escape "hello world 123")
    [ "$result" = "hello world 123" ]
}

@test "sql escape handles empty string" {
    local result
    result=$(__knit_sql_escape "")
    [ -z "$result" ]
}

# ---------- _knit_sqlite3 ----------

@test "_knit_sqlite3 executes a query and returns output" {
    local result
    result=$(_knit_sqlite3 "SELECT 42;")
    [ "$result" = "42" ]
}

@test "_knit_sqlite3 returns empty output for empty result set" {
    local result
    result=$(_knit_sqlite3 "SELECT * FROM metadata;")
    [ -z "$result" ]
}

@test "_knit_sqlite3 returns multiple rows" {
    _knit_sqlite3 "INSERT INTO metadata (key, value) VALUES ('a', '1'), ('b', '2');"
    local count
    count=$(_knit_sqlite3 "SELECT COUNT(*) FROM metadata;")
    [ "$count" -eq 2 ]
}

@test "_knit_sqlite3 fails on invalid SQL" {
    run _knit_sqlite3 "NOT VALID SQL;"
    [ "$status" -ne 0 ]
}

# ---------- _knit_metadata_store ----------

@test "metadata store inserts a key-value pair" {
    _knit_metadata_store --key "mykey" --value "myvalue"
    local result
    result=$(sqlite3 "${__KNIT_DATABASE}" "SELECT value FROM metadata WHERE key='mykey';")
    [ "$result" = "myvalue" ]
}

@test "metadata store handles values with spaces" {
    _knit_metadata_store --key "desc" --value "hello world"
    local result
    result=$(sqlite3 "${__KNIT_DATABASE}" "SELECT value FROM metadata WHERE key='desc';")
    [ "$result" = "hello world" ]
}

@test "metadata store handles values with single quotes" {
    _knit_metadata_store --key "desc" --value "it's here"
    local result
    result=$(sqlite3 "${__KNIT_DATABASE}" "SELECT value FROM metadata WHERE key='desc';")
    [ "$result" = "it's here" ]
}

@test "metadata store fails on duplicate key" {
    _knit_metadata_store --key "mykey" --value "first"
    run _knit_metadata_store --key "mykey" --value "second"
    [ "$status" -ne 0 ]
}

# ---------- _knit_metadata_load ----------

@test "metadata load returns the value for an existing key" {
    sqlite3 "${__KNIT_DATABASE}" "INSERT INTO metadata (key, value) VALUES ('k', 'v');"
    local result
    result=$(_knit_metadata_load --key "k")
    [ "$result" = "v" ]
}

@test "metadata load handles key with single quote" {
    sqlite3 "${__KNIT_DATABASE}" "INSERT INTO metadata (key, value) VALUES ('it''s', 'found');"
    local result
    result=$(_knit_metadata_load --key "it's")
    [ "$result" = "found" ]
}

@test "metadata load returns empty output for a missing key" {
    local result
    result=$(_knit_metadata_load --key "nonexistent")
    [ -z "$result" ]
}

# ---------- _knit_metadata_show ----------

@test "metadata show returns nothing for an empty table" {
    local result
    result=$(_knit_metadata_show)
    [ -z "$result" ]
}

@test "metadata show includes all stored keys and values" {
    sqlite3 "${__KNIT_DATABASE}" \
        "INSERT INTO metadata (key, value) VALUES ('alpha', '1'), ('beta', '2');"
    local result
    result=$(_knit_metadata_show)
    [[ "$result" == *"alpha"* ]]
    [[ "$result" == *"1"* ]]
    [[ "$result" == *"beta"* ]]
    [[ "$result" == *"2"* ]]
}
