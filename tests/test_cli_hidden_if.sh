#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# Predicates: _hy hides ("yes"), _hn does not ("no").
_hy() { return 0; }
_hn() { return 1; }
_uy() { return 0; }
_un() { return 1; }

@test "knit_hidden_if outside a registration block is fatal" {
    run knit_hidden_if _hy
    [ "$status" -eq 1 ]
    [[ "$output" == *"should be used after a call to \"knit_register\""* ]]
}

@test "knit_hidden_if requires a predicate" {
    knit_register "hi_noarg" knit_empty "A command."
    run knit_hidden_if
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires a predicate"* ]]
    knit_done
}

@test "knit_hidden_if declares the _hidden_pred array lazily and appends" {
    knit_register "hi_lazy" knit_empty "A command."
    [ ! -v _KNIT_CMD_hi_lazy_hidden_pred ]
    knit_hidden_if _hy
    knit_hidden_if _hn
    knit_done
    [ -v _KNIT_CMD_hi_lazy_hidden_pred ]
    [ "${#_KNIT_CMD_hi_lazy_hidden_pred[@]}" -eq 2 ]
    [ "${_KNIT_CMD_hi_lazy_hidden_pred[0]}" = "_hy" ]
    [ "${_KNIT_CMD_hi_lazy_hidden_pred[1]}" = "_hn" ]
}

@test "_knit_command_hidden is true when a dynamic predicate hides" {
    knit_register "hi_dyn" knit_empty "A command."
    knit_hidden_if _hy
    knit_done
    _knit_command_hidden "hi_dyn"
}

@test "_knit_command_hidden is false when no dynamic predicate hides" {
    knit_register "hi_show" knit_empty "A command."
    knit_hidden_if _hn
    knit_done
    run _knit_command_hidden "hi_show"
    [ "$status" -ne 0 ]
}

@test "_knit_command_hidden ORs multiple predicates" {
    knit_register "hi_or" knit_empty "A command."
    knit_hidden_if _hn
    knit_hidden_if _hy
    knit_done
    _knit_command_hidden "hi_or"
}

@test "_knit_command_hidden is false for a command with no predicates" {
    knit_register "hi_none" knit_empty "A command."
    knit_done
    run _knit_command_hidden "hi_none"
    [ "$status" -ne 0 ]
}

@test "_knit_command_hidden is true for a statically hidden command" {
    knit_register "hi_static" knit_empty "A command."
    knit_hidden
    knit_done
    _knit_command_hidden "hi_static"
}

@test "_knit_command_hidden warns and does not hide on a missing predicate" {
    knit_register "hi_missing" knit_empty "A command."
    knit_hidden_if _hn
    knit_done
    # Inject a bogus predicate directly (bypassing the decorator's checks).
    _KNIT_CMD_hi_missing_hidden_pred+=("_hi_no_such_pred")
    run _knit_command_hidden "hi_missing"
    [ "$status" -ne 0 ]
    [[ "$output" == *"which is not a defined function"* ]]
}

@test "knit_hidden_if_not_usable hides an unusable command" {
    knit_register "hi_nu" knit_empty "A command."
    knit_usable_if _un "not ready"
    knit_hidden_if_not_usable
    knit_done
    _knit_command_hidden "hi_nu"
}

@test "knit_hidden_if_not_usable shows a usable command" {
    knit_register "hi_u" knit_empty "A command."
    knit_usable_if _uy "ready"
    knit_hidden_if_not_usable
    knit_done
    run _knit_command_hidden "hi_u"
    [ "$status" -ne 0 ]
}

@test "knit_hidden_if_not_usable shows a command with no usability predicates" {
    knit_register "hi_nu_none" knit_empty "A command."
    knit_hidden_if_not_usable
    knit_done
    run _knit_command_hidden "hi_nu_none"
    [ "$status" -ne 0 ]
}

@test "knit_hidden_if_not_usable appends the internal predicate" {
    knit_register "hi_nu_pred" knit_empty "A command."
    knit_hidden_if_not_usable
    knit_done
    [ "${_KNIT_CMD_hi_nu_pred_hidden_pred[0]}" = "_knit_hidden_if_not_usable_pred" ]
}

@test "knit_hidden_if after knit_hidden warns and is ignored" {
    knit_register "hi_static_first" knit_empty "A command."
    knit_hidden
    run knit_hidden_if _hy
    [ "$status" -eq 0 ]
    [[ "$output" == *"is meaningless"* ]]
    knit_done
    [ ! -v _KNIT_CMD_hi_static_first_hidden_pred ]
    # Still statically hidden.
    _knit_command_hidden "hi_static_first"
}

@test "knit_hidden after knit_hidden_if warns, sets the flag, and clears predicates" {
    knit_register "hi_shadow" knit_empty "A command."
    knit_hidden_if _hy
    [ -v _KNIT_CMD_hi_shadow_hidden_pred ]
    run knit_hidden
    [ "$status" -eq 0 ]
    [[ "$output" == *"shadows the previous knit_hidden_if"* ]]
    knit_hidden
    knit_done
    [ ! -v _KNIT_CMD_hi_shadow_hidden_pred ]
    [ "${_KNIT_CMD_hi_shadow_is_hidden}" = "true" ]
    _knit_command_hidden "hi_shadow"
}
