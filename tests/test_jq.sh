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

# ---------- __knit_preprocess_constraint ----------

@test "__knit_preprocess_constraint prefixes bare identifiers with dot" {
    run __knit_preprocess_constraint "x > 42"
    [ "$status" -eq 0 ]
    [ "$output" = ".x > 42" ]
}

@test "__knit_preprocess_constraint handles multiple identifiers" {
    run __knit_preprocess_constraint "x > 42 and z > 0"
    [ "$status" -eq 0 ]
    [ "$output" = ".x > 42 and .z > 0" ]
}

@test "__knit_preprocess_constraint leaves jq keywords unchanged" {
    run __knit_preprocess_constraint "x > 0 and y > 0"
    [ "$status" -eq 0 ]
    [ "$output" = ".x > 0 and .y > 0" ]
}

@test "__knit_preprocess_constraint leaves true/false/null unchanged" {
    run __knit_preprocess_constraint "flag == true"
    [ "$status" -eq 0 ]
    [ "$output" = ".flag == true" ]
}

@test "__knit_preprocess_constraint does not double-prefix already-dotted identifiers" {
    run __knit_preprocess_constraint ".x > 42"
    [ "$status" -eq 0 ]
    [ "$output" = ".x > 42" ]
}

@test "__knit_preprocess_constraint does not modify identifiers inside string literals" {
    run __knit_preprocess_constraint 'label == "foo"'
    [ "$status" -eq 0 ]
    [ "$output" = '.label == "foo"' ]
}
