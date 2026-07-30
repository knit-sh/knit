#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_require_jq
    knit_test_db_setup

    # Use the system jq for the "knit jq" wrapper (knit_test_db_setup only wires
    # up sqlite). A real binary is needed since the wrapper forwards to it.
    _KNIT_JQ_EXE="jq"
}

teardown() {
    knit_test_db_teardown
}

# ---------- registration ----------

@test "knit jq is registered as a builtin wrapper" {
    _knit_set_find _KNIT_COMMANDS "jq"
    _knit_command_is_wrapper "jq"
}

@test "jq is not usable before bootstrap" {
    run _knit_command_is_usable_before_bootstrap "jq"
    [ "$status" -ne 0 ]
}

# ---------- knit jq passthrough ----------

@test "jq processes JSON from stdin" {
    run _knit_invoke_command "jq" -r '.a' <<<'{"a":"hello"}'
    [ "$status" -eq 0 ]
    [ "$output" = "hello" ]
}

@test "jq forwards flags verbatim (-n for a null input program)" {
    run _knit_invoke_command "jq" -n '1 + 2'
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

@test "jq returns jq's exit status on a bad program" {
    run _knit_invoke_command "jq" -n 'this is not valid'
    [ "$status" -ne 0 ]
}

@test "jq records no row and creates no 'jq' table" {
    _knit_invoke_command "jq" -n '1' >/dev/null
    run _knit_sqlite3 \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='jq';"
    [ "$output" = "0" ]
}
