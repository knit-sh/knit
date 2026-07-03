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

# Create a jobs table and insert one row with the given id/setup/job/state.
_seed_job() {
    local id="$1" setup="$2" job="$3" state="$4"
    sqlite3 "${__KNIT_DATABASE}" \
        "CREATE TABLE IF NOT EXISTS jobs (id TEXT, setup TEXT, job TEXT, state TEXT);"
    sqlite3 "${__KNIT_DATABASE}" \
        "INSERT INTO jobs (id, setup, job, state) VALUES ('${id}', '${setup}', '${job}', '${state}');"
}

# ---------- job command group ----------

@test "job command group is registered" {
    _knit_set_find _KNIT_COMMANDS "job"
}

@test "job --help lists the group description" {
    run _knit_invoke_command "job" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Inspect submitted jobs"* ]]
}

# ---------- job status ----------

@test "job status prints the state of a known job" {
    _seed_job "abc123" "" "montecarlo" "running"
    run _knit_job_status --id "abc123"
    [ "$status" -eq 0 ]
    [ "$output" = "running" ]
}

@test "job status fails for an unknown id" {
    _seed_job "abc123" "" "montecarlo" "running"
    run _knit_job_status --id "does-not-exist"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No job found"* ]]
}

@test "job status fails when not bootstrapped and not bootstrapping" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="false"
    run _knit_job_status --id "abc123"
    [ "$status" -ne 0 ]
}

@test "job status is a no-op when bootstrapping and not yet bootstrapped" {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/path"
    _KNIT_IS_BOOTSTRAPPING="true"
    run _knit_job_status --id "abc123"
    [ "$status" -eq 0 ]
}
