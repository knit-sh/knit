#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_require_sqlite
    knit_test_db_setup
}

teardown() {
    knit_test_db_teardown
}

# ---------- knit_usable_before_bootstrap ----------

@test "commands are not usable before bootstrap by default" {
    knit_register knit_empty "ubb_default" "A default command."
    knit_done
    [ "${_KNIT_CMD_ubb_default_usable_before_bootstrap}" = "false" ]
}

@test "knit_usable_before_bootstrap marks the command usable" {
    knit_register knit_empty "ubb_marked" "A usable command."
    knit_usable_before_bootstrap
    knit_done
    [ "${_KNIT_CMD_ubb_marked_usable_before_bootstrap}" = "true" ]
}

@test "knit_usable_before_bootstrap is idempotent" {
    knit_register knit_empty "ubb_twice" "A usable command."
    knit_usable_before_bootstrap
    knit_usable_before_bootstrap
    knit_done
    [ "${_KNIT_CMD_ubb_twice_usable_before_bootstrap}" = "true" ]
}

@test "knit_usable_before_bootstrap fails outside of knit_register" {
    run knit_usable_before_bootstrap
    [ "$status" -eq 1 ]
}

# ---------- _knit_command_is_usable_before_bootstrap ----------

@test "_knit_command_is_usable_before_bootstrap true for a marked command" {
    knit_register knit_empty "ubb_acc_yes" "A usable command."
    knit_usable_before_bootstrap
    knit_done
    _knit_command_is_usable_before_bootstrap "ubb_acc_yes"
}

@test "_knit_command_is_usable_before_bootstrap false for an unmarked command" {
    knit_register knit_empty "ubb_acc_no" "A default command."
    knit_done
    run _knit_command_is_usable_before_bootstrap "ubb_acc_no"
    [ "$status" -eq 1 ]
}

@test "_knit_command_is_usable_before_bootstrap false for an unknown command" {
    run _knit_command_is_usable_before_bootstrap "ubb_nonexistent"
    [ "$status" -eq 1 ]
}
