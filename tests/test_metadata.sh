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

    # Satisfy the bootstrap check — tests in this file work with a live DB
    _KNIT_IS_BOOTSTRAPPED="1"
}

teardown() {
    rm -f "${__KNIT_DATABASE}"
    _KNIT_IS_BOOTSTRAPPED=""
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

# ---------- bootstrap guard ----------

@test "metadata store fails when experiment is not bootstrapped and not bootstrapping" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="false"
    run _knit_metadata_store --key "k" --value "v"
    [ "$status" -ne 0 ]
}

@test "metadata store is a no-op when bootstrapping and experiment is not yet bootstrapped" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="true"
    run _knit_metadata_store --key "k" --value "v"
    [ "$status" -eq 0 ]
}

@test "metadata load fails when experiment is not bootstrapped and not bootstrapping" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="false"
    run _knit_metadata_load --key "k"
    [ "$status" -ne 0 ]
}

@test "metadata load is a no-op when bootstrapping and experiment is not yet bootstrapped" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="true"
    run _knit_metadata_load --key "k"
    [ "$status" -eq 0 ]
}

@test "metadata show fails when experiment is not bootstrapped and not bootstrapping" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="false"
    run _knit_metadata_show
    [ "$status" -ne 0 ]
}

@test "metadata show is a no-op when bootstrapping and experiment is not yet bootstrapped" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="true"
    run _knit_metadata_show
    [ "$status" -eq 0 ]
}
