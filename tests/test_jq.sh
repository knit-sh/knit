#!/usr/bin/env bats

setup() {
    if ! command -v jq &>/dev/null; then
        skip "jq not available in PATH"
    fi

    source knit.sh

    # Override the jq executable for testing
    __KNIT_JQ_EXE="jq"

    # Satisfy the bootstrap check
    _KNIT_IS_BOOTSTRAPPED="1"
}

teardown() {
    _KNIT_IS_BOOTSTRAPPED=""
}

# ---------- _knit_jq ----------

@test "_knit_jq evaluates a simple arithmetic expression" {
    run _knit_jq -n '1 + 1'
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "_knit_jq evaluates a boolean expression" {
    run _knit_jq -n '3 > 2'
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "_knit_jq returns non-zero on invalid jq expression" {
    run _knit_jq -n 'not_valid::jq'
    [ "$status" -ne 0 ]
}

# ---------- __knit_jq_platform ----------

@test "__knit_jq_platform returns a non-empty string" {
    run __knit_jq_platform
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "__knit_jq_platform output starts with jq-" {
    run __knit_jq_platform
    [ "$status" -eq 0 ]
    [[ "$output" == jq-* ]]
}
