#!/usr/bin/env bats

setup() {
    if ! command -v sqlite3 &>/dev/null; then
        skip "sqlite3 not available"
    fi

    source knit.sh

    # Override the sqlite executable and database path for testing
    _KNIT_SQLITE_EXE="sqlite3"
    _KNIT_DATABASE="$(mktemp --suffix=.db)"

    sqlite3 "${_KNIT_DATABASE}" \
        "CREATE TABLE runs (id TEXT, n INTEGER, label TEXT);"
    sqlite3 "${_KNIT_DATABASE}" \
        "INSERT INTO runs (id, n, label) VALUES ('c', 3, 'gamma'), ('a', 1, 'alpha'), ('b', 2, 'beta');"

    # Satisfy the bootstrap check — tests in this file work with a live DB
    _KNIT_IS_BOOTSTRAPPED="1"
}

teardown() {
    rm -f "${_KNIT_DATABASE}"
    _KNIT_IS_BOOTSTRAPPED=""
}

# Commands are exercised through the full invocation pipeline so that optional
# defaults (e.g. --select "*") and flag normalization are applied, as they are
# for a real "knit db query ..." call. The command names are mangled forms of
# "db:query" and "db:tables".
db_query() { _knit_invoke_command "db__1__query" "$@"; }
db_tables() { _knit_invoke_command "db__1__tables" "$@"; }

# ---------- db query: statement building ----------

@test "db query selects all columns by default" {
    run db_query --from runs
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"beta"* ]]
    [[ "$output" == *"gamma"* ]]
}

@test "db query restricts columns with --select" {
    run db_query --select label --from runs
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" != *"1"* ]]
}

@test "db query filters rows with --where" {
    run db_query --select label --from runs --where "n = 2"
    [ "$status" -eq 0 ]
    [ "$output" = "beta" ]
}

@test "db query orders rows with --order-by" {
    run db_query --select n --from runs --order-by "n DESC"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "3" ]
    [ "${lines[1]}" = "2" ]
    [ "${lines[2]}" = "1" ]
}

@test "db query caps rows with --limit" {
    run db_query --from runs --order-by "n ASC" --limit 1
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" == *"alpha"* ]]
}

@test "db query rejects a non-integer --limit" {
    run db_query --from runs --limit abc
    [ "$status" -ne 0 ]
    [[ "$output" == *"integer"* ]]
}

@test "db query prints a header row with --header" {
    run db_query --select label --from runs --header --where "n = 1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"label"* ]]
    [[ "$output" == *"alpha"* ]]
}

@test "db query aligns output with --column" {
    run db_query --select label --from runs --column --header --where "n = 1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"label"* ]]
    [[ "$output" == *"-----"* ]]
}

# ---------- db query: table names needing SQL quoting ----------

@test "db query accepts a table name containing a colon without manual quoting" {
    sqlite3 "${_KNIT_DATABASE}" \
        'CREATE TABLE "aaa:bbb" (id TEXT, v TEXT);'
    sqlite3 "${_KNIT_DATABASE}" \
        "INSERT INTO \"aaa:bbb\" (id, v) VALUES ('x', 'nested');"
    run db_query --from aaa:bbb
    [ "$status" -eq 0 ]
    [[ "$output" == *"nested"* ]]
}

# ---------- db query: --sql escape hatch ----------

@test "db query runs a raw statement given via --sql" {
    run db_query --sql "SELECT COUNT(*) FROM runs;"
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

@test "db query with --sql ignores the builder options" {
    run db_query --sql "SELECT label FROM runs WHERE n = 3;" --from bogus
    [ "$status" -eq 0 ]
    [ "$output" = "gamma" ]
}

# ---------- db query: errors ----------

@test "db query fails when neither --from nor --sql is given" {
    run db_query --select label
    [ "$status" -ne 0 ]
    [[ "$output" == *"--from"* ]]
}

# ---------- db tables ----------

@test "db tables lists the tables in the database" {
    run db_tables
    [ "$status" -eq 0 ]
    [[ "$output" == *"runs"* ]]
}

@test "db tables excludes internal sqlite tables" {
    sqlite3 "${_KNIT_DATABASE}" \
        "CREATE TABLE t2 (x INTEGER); CREATE INDEX i ON t2(x);"
    run db_tables
    [ "$status" -eq 0 ]
    [[ "$output" != *"sqlite_"* ]]
}

@test "db tables sorts the table names" {
    sqlite3 "${_KNIT_DATABASE}" "CREATE TABLE aardvark (x INTEGER);"
    run db_tables
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "aardvark" ]
    [ "${lines[1]}" = "runs" ]
}

# ---------- bootstrap guard ----------

@test "db query fails when not bootstrapped and not bootstrapping" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="false"
    run db_query --from runs
    [ "$status" -ne 0 ]
}

@test "db query is a no-op when bootstrapping and not yet bootstrapped" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="true"
    run db_query --from runs
    [ "$status" -eq 0 ]
}

@test "db tables fails when not bootstrapped and not bootstrapping" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="false"
    run db_tables
    [ "$status" -ne 0 ]
}

@test "db tables is a no-op when bootstrapping and not yet bootstrapped" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="true"
    run db_tables
    [ "$status" -eq 0 ]
}
