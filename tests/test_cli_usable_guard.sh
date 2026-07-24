#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup

    # A usable and a not-usable ordinary command, plus a not-usable wrapper.
    knit_register knit_empty "ubbg_usable" "A usable command."
    knit_usable_before_bootstrap
    knit_done
    knit_register knit_empty "ubbg_gated" "A gated command."
    knit_done
    ubbg_wrap_fn() { printf 'ran\n'; }
    knit_register_wrapper "ubbg_wrap" "ubbg_wrap_fn" "A gated wrapper."
    knit_done
}

teardown() {
    knit_test_db_teardown
}

_set_not_bootstrapped() {
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="/nonexistent/knit_ubbg_$$"
}

_set_bootstrapped() {
    _KNIT_IS_BOOTSTRAPPED="1"
}

# ---------- guard fires before bootstrap ----------

@test "before bootstrap a not-usable command is refused with the uniform message" {
    _set_not_bootstrapped
    run _knit_invoke_command "ubbg_gated"
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires bootstrap"* ]]
    [[ "$output" == *"ubbg_gated"* ]]
}

@test "before bootstrap a not-usable wrapper is refused with the uniform message" {
    _set_not_bootstrapped
    run _knit_invoke_command "ubbg_wrap" "arg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires bootstrap"* ]]
    [[ "$output" == *"ubbg_wrap"* ]]
    [[ "$output" != *"ran"* ]]
}

# ---------- guard lets usable commands through ----------

@test "before bootstrap a usable command runs" {
    _set_not_bootstrapped
    run _knit_invoke_command "ubbg_usable"
    [ "$status" -eq 0 ]
    [[ "$output" != *"requires bootstrap"* ]]
}

# ---------- guard is a no-op after bootstrap ----------

@test "after bootstrap a previously-gated command runs" {
    _set_bootstrapped
    run _knit_invoke_command "ubbg_gated"
    [ "$status" -eq 0 ]
    [[ "$output" != *"requires bootstrap"* ]]
}

@test "after bootstrap a previously-gated wrapper runs" {
    _set_bootstrapped
    run _knit_invoke_command "ubbg_wrap" "arg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ran"* ]]
}

# ---------- --help is never gated ----------

@test "before bootstrap --help on a not-usable command still renders" {
    _set_not_bootstrapped
    run _knit_invoke_command "ubbg_gated" "--help"
    [ "$status" -eq 0 ]
    [[ "$output" != *"requires bootstrap"* ]]
    [[ "$output" == *"A gated command."* ]]
}
