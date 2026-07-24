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

# ---------- validation: no table ----------

@test "usable command with a table is fatal (decorator after table)" {
    knit_register knit_empty "ubb_tbl_a" "A command."
    knit_with_table
    knit_usable_before_bootstrap
    run knit_done
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot declare a table"* ]]
}

@test "usable command with a table is fatal (decorator before table)" {
    knit_register knit_empty "ubb_tbl_b" "A command."
    knit_usable_before_bootstrap
    knit_with_table
    run knit_done
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot declare a table"* ]]
}

# ---------- validation: no --when ----------

@test "usable command with a --when parameter is fatal (decorator after param)" {
    knit_register knit_empty "ubb_when_a" "A command."
    knit_with_optional "count:integer" "1" "How many."
    knit_with_flag "verbose" "Be verbose." --when "count > 1"
    knit_usable_before_bootstrap
    run knit_done
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot use --when"* ]]
}

@test "usable command with a --when parameter is fatal (decorator before param)" {
    knit_register knit_empty "ubb_when_b" "A command."
    knit_usable_before_bootstrap
    knit_with_flag "verbose" "Be verbose." --when "count > 1"
    knit_with_optional "count:integer" "1" "How many."
    run knit_done
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot use --when"* ]]
}

@test "usable command without a --when parameter is accepted" {
    knit_register knit_empty "ubb_when_ok" "A command."
    knit_with_optional "count:integer" "1" "How many."
    knit_with_flag "verbose" "Be verbose."
    knit_usable_before_bootstrap
    knit_done
    [ "${_KNIT_CMD_ubb_when_ok_usable_before_bootstrap}" = "true" ]
}

# ---------- validation: parent must be usable ----------

@test "usable child under a not-usable parent is fatal" {
    knit_register knit_empty "ubb_par_a" "Parent command."
    knit_done
    knit_register knit_empty "ubb_par_a:child" "Child command."
    knit_usable_before_bootstrap
    run knit_done
    [ "$status" -eq 1 ]
    [[ "$output" == *"its parent"* ]]
}

@test "usable child under a usable parent is accepted" {
    knit_register knit_empty "ubb_par_b" "Parent command."
    knit_usable_before_bootstrap
    knit_done
    knit_register knit_empty "ubb_par_b:child" "Child command."
    knit_usable_before_bootstrap
    knit_done
    [ "${_KNIT_CMD_ubb_par_b__1__child_usable_before_bootstrap}" = "true" ]
}

@test "a usable top-level command has no parent to validate" {
    knit_register knit_empty "ubb_toplevel" "A command."
    knit_usable_before_bootstrap
    knit_done
    [ "${_KNIT_CMD_ubb_toplevel_usable_before_bootstrap}" = "true" ]
}
