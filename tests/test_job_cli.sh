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

# ---------- job command group ----------

@test "job command group is registered" {
    _knit_set_find _KNIT_COMMANDS "job"
}

@test "job --help lists the group description" {
    run _knit_invoke_command "job" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Inspect submitted jobs"* ]]
}
