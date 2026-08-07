#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# Predicates: _gy highlights ("yes"), _gn does not ("no").
_gy() { return 0; }
_gn() { return 1; }

@test "knit_highlight_if outside a registration block is fatal" {
    run knit_highlight_if _gy
    [ "$status" -eq 1 ]
    [[ "$output" == *"should be used after a call to \"knit_register\""* ]]
}

@test "knit_highlight_if requires a predicate" {
    knit_register "hl_noarg" knit_empty "A command."
    run knit_highlight_if
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires a predicate"* ]]
    knit_done
}

@test "knit_highlight_if declares the _highlight_pred array lazily and appends" {
    knit_register "hl_lazy" knit_empty "A command."
    [ ! -v _KNIT_CMD_hl_lazy_highlight_pred ]
    knit_highlight_if _gy
    knit_highlight_if _gn
    knit_done
    [ -v _KNIT_CMD_hl_lazy_highlight_pred ]
    [ "${#_KNIT_CMD_hl_lazy_highlight_pred[@]}" -eq 2 ]
    [ "${_KNIT_CMD_hl_lazy_highlight_pred[0]}" = "_gy" ]
    [ "${_KNIT_CMD_hl_lazy_highlight_pred[1]}" = "_gn" ]
}

@test "_knit_command_highlighted is true when a predicate highlights" {
    knit_register "hl_on" knit_empty "A command."
    knit_highlight_if _gy
    knit_done
    _knit_command_highlighted "hl_on"
}

@test "_knit_command_highlighted is false when no predicate highlights" {
    knit_register "hl_off" knit_empty "A command."
    knit_highlight_if _gn
    knit_done
    run _knit_command_highlighted "hl_off"
    [ "$status" -ne 0 ]
}

@test "_knit_command_highlighted ORs multiple predicates" {
    knit_register "hl_or" knit_empty "A command."
    knit_highlight_if _gn
    knit_highlight_if _gy
    knit_done
    _knit_command_highlighted "hl_or"
}

@test "_knit_command_highlighted is false for a command with no predicates" {
    knit_register "hl_none" knit_empty "A command."
    knit_done
    run _knit_command_highlighted "hl_none"
    [ "$status" -ne 0 ]
}

@test "_knit_command_highlighted warns and does not highlight on a missing predicate" {
    knit_register "hl_missing" knit_empty "A command."
    knit_highlight_if _gn
    knit_done
    # Inject a bogus predicate directly (bypassing the decorator's checks).
    _KNIT_CMD_hl_missing_highlight_pred+=("_hl_no_such_pred")
    run _knit_command_highlighted "hl_missing"
    [ "$status" -ne 0 ]
    [[ "$output" == *"which is not a defined function"* ]]
}
