#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# Predicates used by the tests below. They branch on the demangled command name
# ($1) so a single function can serve several commands.
_ui_yes() { return 0; }
_ui_no() { return 1; }
_ui_records_arg() { _UI_SEEN_ARG="$1"; return 0; }
_ui_order() { _UI_ORDER+=("$1-first"); return 0; }
_ui_order_fail() { _UI_ORDER+=("second"); return 1; }
_ui_never() { _UI_ORDER+=("third"); return 0; }

# ---------- knit_usable_if: declaration ----------

@test "knit_usable_if records a predicate and description" {
    knit_register knit_empty "ui_one" "A command."
    knit_usable_if _ui_yes "needs a widget"
    knit_done
    [ "${_KNIT_CMD_ui_one_usable_pred[0]}" = "_ui_yes" ]
    [ "${_KNIT_CMD_ui_one_usable_desc[0]}" = "needs a widget" ]
}

@test "knit_usable_if is repeatable and appends in order" {
    knit_register knit_empty "ui_rep" "A command."
    knit_usable_if _ui_yes "first reason"
    knit_usable_if _ui_no "second reason"
    knit_done
    [ "${#_KNIT_CMD_ui_rep_usable_pred[@]}" -eq 2 ]
    [ "${_KNIT_CMD_ui_rep_usable_pred[0]}" = "_ui_yes" ]
    [ "${_KNIT_CMD_ui_rep_usable_pred[1]}" = "_ui_no" ]
    [ "${_KNIT_CMD_ui_rep_usable_desc[1]}" = "second reason" ]
}

@test "knit_usable_if does not declare storage for commands that skip it" {
    knit_register knit_empty "ui_none" "A command."
    knit_done
    [ ! -v _KNIT_CMD_ui_none_usable_pred ]
}

@test "knit_usable_if fails outside of knit_register" {
    run knit_usable_if _ui_yes "reason"
    [ "$status" -eq 1 ]
    [[ "$output" == *"after a call to \"knit_register\""* ]]
}

@test "knit_usable_if requires a predicate and a description" {
    knit_register knit_empty "ui_args" "A command."
    run knit_usable_if _ui_yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires a predicate and a description"* ]]
}

# ---------- _knit_command_check_usable ----------

@test "_knit_command_check_usable returns 0 when no predicate is declared" {
    knit_register knit_empty "ui_ck_none" "A command."
    knit_done
    local reason="untouched"
    _knit_command_check_usable reason "ui_ck_none"
    [ "$reason" = "untouched" ]
}

@test "_knit_command_check_usable returns 0 when all predicates pass" {
    knit_register knit_empty "ui_ck_pass" "A command."
    knit_usable_if _ui_yes "reason a"
    knit_usable_if _ui_yes "reason b"
    knit_done
    local reason=""
    _knit_command_check_usable reason "ui_ck_pass"
}

@test "_knit_command_check_usable returns 1 and sets the reason on failure" {
    knit_register knit_empty "ui_ck_fail" "A command."
    knit_usable_if _ui_no "cannot run yet"
    knit_done
    local reason=""
    run _knit_command_check_usable reason "ui_ck_fail"
    [ "$status" -eq 1 ]
    reason=""
    if _knit_command_check_usable reason "ui_ck_fail"; then :; fi
    [ "$reason" = "cannot run yet" ]
}

@test "_knit_command_check_usable stops at the first failing predicate" {
    knit_register knit_empty "ui_ck_order" "A command."
    knit_usable_if _ui_order "first reason"
    knit_usable_if _ui_order_fail "second reason"
    knit_usable_if _ui_never "third reason"
    knit_done
    _UI_ORDER=()
    local reason=""
    if _knit_command_check_usable reason "ui_ck_order"; then :; fi
    [ "$reason" = "second reason" ]
    [ "${#_UI_ORDER[@]}" -eq 2 ]
    [ "${_UI_ORDER[0]}" = "ui_ck_order-first" ]
    [ "${_UI_ORDER[1]}" = "second" ]
}

@test "_knit_command_check_usable passes the demangled command name to the predicate" {
    knit_register knit_empty "ui_ck_arg" "A parent command."
    knit_done
    knit_register knit_empty "ui_ck_arg:leaf" "A command."
    knit_usable_if _ui_records_arg "reason"
    knit_done
    _UI_SEEN_ARG=""
    _knit_command_check_usable reason "ui_ck_arg__1__leaf"
    [ "${_UI_SEEN_ARG}" = "ui_ck_arg:leaf" ]
}

@test "_knit_command_check_usable is fatal for a missing predicate function" {
    knit_register knit_empty "ui_ck_missing" "A command."
    knit_usable_if _ui_absent_predicate "reason"
    knit_done
    local reason=""
    run _knit_command_check_usable reason "ui_ck_missing"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a defined function"* ]]
}
