#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
    _UE_MARKER="${BATS_TEST_TMPDIR}/ran"
    rm -f "${_UE_MARKER}"
}

teardown() {
    knit_test_db_teardown
}

# Predicates and a body that records (via a file marker so it survives the
# subshell that `run` spawns) whether it executed.
_ue_yes() { return 0; }
_ue_no() { return 1; }
_ue_body() { : > "${_UE_MARKER}"; }

@test "_knit_invoke_command runs the body of a usable command" {
    knit_register "ue_ok" _ue_body "A command."
    knit_usable_if _ue_yes "needs a widget"
    knit_done
    _knit_invoke_command "ue_ok"
    [ -f "${_UE_MARKER}" ]
}

@test "_knit_invoke_command fatals with the reason when a command is unusable" {
    knit_register "ue_bad" _ue_body "A command."
    knit_usable_if _ue_no "no widget available"
    knit_done
    run _knit_invoke_command "ue_bad"
    [ "$status" -eq 1 ]
    [[ "$output" == *'Command "ue_bad" cannot run: no widget available'* ]]
}

@test "_knit_invoke_command does not run the body of an unusable command" {
    knit_register "ue_norun" _ue_body "A command."
    knit_usable_if _ue_no "no widget"
    knit_done
    run _knit_invoke_command "ue_norun"
    [ "$status" -eq 1 ]
    [ ! -f "${_UE_MARKER}" ]
}

@test "_knit_invoke_command exempts --help from the usability guard" {
    knit_register "ue_help" _ue_body "A command."
    knit_usable_if _ue_no "no widget"
    knit_done
    run _knit_invoke_command "ue_help" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"ue_help"* ]]
    [[ "$output" != *"cannot run"* ]]
    [ ! -f "${_UE_MARKER}" ]
}

@test "the usability guard runs after the bootstrap guard" {
    # A command that is neither usable-before-bootstrap nor usable (failing
    # predicate), invoked while not bootstrapped, must report the bootstrap
    # requirement first — proving the bootstrap guard is evaluated before the
    # usability guard.
    knit_register "ue_order" _ue_body "A command."
    knit_usable_if _ue_no "no widget"
    knit_done
    local saved_prefix="${_KNIT_PREFIX}"
    _KNIT_IS_BOOTSTRAPPED=""
    _KNIT_PREFIX="${BATS_TEST_TMPDIR}/nonexistent-prefix"
    run _knit_invoke_command "ue_order"
    _KNIT_PREFIX="${saved_prefix}"
    _KNIT_IS_BOOTSTRAPPED="1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires bootstrap"* ]]
    [[ "$output" != *"cannot run"* ]]
}
